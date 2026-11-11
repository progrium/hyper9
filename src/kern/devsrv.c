/*
 * #s: service registry (design/devsrv.md), ported from 9front's
 * port/devsrv.c at the pinned release.
 *
 * A file server posts a channel by creating a name here and writing the
 * number of an open fd into it; opening the name returns another
 * reference to that channel. Opening clone makes a child board, whose
 * open fd is its lease: closing it closes the board and every service on
 * it. Boards nest, and #s/id1/id2 walks to one.
 *
 * Changes from 9front's:
 *	- Each machine has its own root board (Srvmach, hung off Hmach), found
 *	  through the calling process's h9 record when attaching, so machines
 *	  in one host process can't see each other's services. The lock, the
 *	  path counter and the all-boards list are per machine too. A board
 *	  is the root when it has no parent.
 *	- The machine's services are closed by its last process, before it
 *	  ends (h9_srvmachclose, from proc.c), as closing a lease does; the
 *	  structures go with the machine (h9_srvmachfree).
 *	- ccloseq is cclose: drawterm's cclose runs from any kernel thread.
 *	- Posting is split from the fd: srvwrite turns the fd into a channel,
 *	  and post does the rest, which h9_srvpost offers without a guest fd.
 *	- Plan 9 C's anonymous struct members are named.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"

#define SRVTYPE(x)	(((uint)x)&0x3)
#define SRVPATH(x)	(((uvlong)x)>>2)
#define SRVQID(x, t)	((((uvlong)x)<<2)|((t)&0x3))

typedef struct Link Link;
typedef struct Srv Srv;
typedef struct Board Board;
typedef struct Srvmach Srvmach;

struct Link
{
	void 	*link;
	char 	*name;
	char	*owner;
	ulong	perm;
	ulong 	path;
};

struct Srv
{
	Link	l;	/* first, so a Srv is a Link */
	Chan	*chan;
};

struct Board
{
	Link	l;	/* first, so a Board is a Link */
	Ref	ref;

	int 	closed;
	Srv 	*srv;
	Srvmach	*sm;

	/* tree linkage */
	Board 	*parent;	/* nil for the machine's root */
	Board 	*child;

	/* all boards list */
	Board	*prev;
	Board	*next;
};

/* One machine's registry. */
struct Srvmach
{
	RWLock	lk;
	ulong	path;
	Board	root;
};

enum{
	Qsrv,
	Qclone,
	Qlease,
};

/* drawterm's ulong is 32 bits, so not 9front's ~0UL */
#define Nopath	((ulong)~0)

static char clone[] = "clone";

static int
isroot(Board *b)
{
	return b->parent == nil;
}

static void*
lookup(Link *l, char *name, ulong qidpath)
{
	Link *lp;

	if(qidpath != Nopath){
		assert(SRVTYPE(qidpath) == Qsrv);
		qidpath = SRVPATH(qidpath);
	}
	for(lp = l; lp != nil; lp = lp->link){
		if(qidpath != Nopath && lp->path == qidpath)
			return lp;
		if(name != nil && strcmp(lp->name, name) == 0)
			return lp;
	}
	return nil;
}

static void*
linkremove(Link **l, char *name, ulong qidpath)
{
	Link *lp;
	Link **last;

	if(qidpath != Nopath){
		assert(SRVTYPE(qidpath) == Qsrv);
		qidpath = SRVPATH(qidpath);
	}
	last = l;
	for(lp = *l; lp != nil; lp = lp->link){
		if(qidpath != Nopath && lp->path == qidpath)
			break;
		if(name != nil && strcmp(lp->name, name) == 0)
			break;
		last = (Link**)&lp->link;
	}
	if(lp == nil)
		return nil;

	*last = lp->link;
	lp->link = nil;
	return lp;
}

static void
freelink(Link *l)
{
	free(l->name);
	free(l->owner);
	free(l);
}

/* always called with b->sm->lk wlock'ed */
static void
boardclunk(Board *b)
{
	Board *ch;

	/* the root is not ref-counted nor clunkable */
	if(isroot(b))
		return;

	if(decref(&b->ref))
		return;

	/*
	 * All boards must be walkable from root. So a board
	 * is allowed to sit at zero references as long as it
	 * still has active children. For leaf nodes we then
	 * have to walk up the tree to clear now empty parents.
	 */
	while(b->closed && b->child == nil){
		assert(b->srv == nil);
		assert(b->parent != nil);

		/* unlink from parent board */
		ch = linkremove((Link**)&b->parent->child, b->l.name, Nopath);
		assert(ch == b);

		/* unlink from all boards list */
		ch->prev->next = ch->next;
		ch->next->prev = ch->prev;

		b = ch->parent;
		freelink(&ch->l);
	}
}

/*
 * The calling process's machine's registry, made on first use. Errors
 * if the caller isn't an h9 process.
 */
static Srvmach*
machsrv(void)
{
	Hmach *m;
	Srvmach *sm;

	m = h9_uphproc()->mach;
	lock(&m->lk);
	sm = m->srv;
	if(sm == nil){
		sm = mallocz(sizeof *sm, 1);
		if(sm == nil){
			unlock(&m->lk);
			error(Enomem);
		}
		sm->root.next = &sm->root;
		sm->root.prev = &sm->root;
		sm->root.sm = sm;
		sm->root.l.path = sm->path++;
		sm->root.l.perm = 0777;
		sm->root.l.name = strdup("#s");
		sm->root.l.owner = strdup(eve);
		if(sm->root.l.name == nil || sm->root.l.owner == nil){
			free(sm->root.l.name);
			free(sm->root.l.owner);
			free(sm);
			unlock(&m->lk);
			error(Enomem);
		}
		m->srv = sm;
	}
	unlock(&m->lk);
	return sm;
}

static int
srvgen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Srv *sp;
	Board *b, *ch;
	Srvmach *sm;
	Qid q;

	USED(tab, ntab);
	if(name != nil && strlen(name) >= sizeof(up->genbuf))
		return -1;

	b = c->aux;
	sm = b->sm;
	sp = nil;
	ch = nil;
	mkqid(&q, ~0L, 0, QTFILE);
	rlock(&sm->lk);
	if(waserror()){
		runlock(&sm->lk);
		nexterror();
	}
	switch(s){
	case -2: /* dot */
		ch = b;
		goto Child;
	case DEVDOTDOT:
		ch = b->parent;
		if(ch == nil)
			ch = &sm->root;
		goto Child;
	}
	if(name != nil){
		if(strcmp(name, clone) == 0)
			goto Clone;

		sp = lookup((Link*)b->srv, name, Nopath);
		if(sp == nil)
			ch = lookup((Link*)b->child, name, Nopath);
	} else {
		if(s == 0)
			goto Clone;
		s--;
		for(sp = b->srv; sp != nil && s > 0; sp = sp->l.link)
			s--;
		for(ch = b->child; ch != nil && s > 0; ch = ch->l.link)
			s--;
	}
	if(sp != nil){
		kstrcpy(up->genbuf, sp->l.name, sizeof up->genbuf);
		q.path = SRVQID(sp->l.path, Qsrv);
		devdir(c, q, up->genbuf, 0, sp->l.owner, sp->l.perm, dp);
	} else if(ch != nil){
Child:
		if(name != nil || s == DEVDOTDOT){
			devpermcheck(ch->l.owner, ch->l.perm, OEXEC);
			c->aux = ch;
		}
		kstrcpy(up->genbuf, ch->l.name, sizeof up->genbuf);
		q.path = SRVQID(ch->l.path, Qsrv);
		q.type = QTDIR;
		devdir(c, q, up->genbuf, 0, ch->l.owner, ch->l.perm|DMDIR, dp);
	} else if(0){
Clone:
		q.path = SRVQID(SRVPATH(c->qid.path), Qclone);
		devdir(c, q, clone, 0, eve, 0444, dp);
	} else {
		runlock(&sm->lk);
		poperror();
		return -1;
	}

	runlock(&sm->lk);
	poperror();
	return 1;
}

static Chan*
srvattach(char *spec)
{
	Chan *c;
	Srvmach *sm;

	sm = machsrv();
	c = devattach('s', spec);
	c->aux = &sm->root;
	return c;
}

static Walkqid*
srvwalk(Chan *c, Chan *nc, char **name, int nname)
{
	Board *b;
	Walkqid *wq;

	wq = devwalk(c, nc, name, nname, 0, 0, srvgen);
	if(wq == nil || wq->clone == nil)
		return wq;

	b = wq->clone->aux;
	if(isroot(b))
		return wq;

	incref(&b->ref);
	return wq;
}

static int
srvstat(Chan *c, uchar *db, int n)
{
	Dir d;

	/* devstat cheats for dir stats, we care about our dir perms */
	if(c->qid.type == QTDIR){
		srvgen(c, nil, nil, 0, -2, &d);
		n = convD2M(&d, db, n);
		if(n == 0)
			error(Ebadarg);
		return n;
	}

	return devstat(c, db, n, 0, 0, srvgen);
}

static Chan*
srvopen(Chan *c, int omode)
{
	Board *b, *ch;
	Srvmach *sm;
	Srv *sp;
	Chan *nc;
	char buf[64];
	int mode;

	if(omode&OTRUNC)
		error(Eexist);
	if(omode&ORCLOSE)
		error(Eperm);
	mode = openmode(omode);

	b = c->aux;
	sm = b->sm;
	if(SRVTYPE(c->qid.path) == Qclone){
		wlock(&sm->lk);
		if(waserror()){
			wunlock(&sm->lk);
			nexterror();
		}
		if(b->closed)
			error(Eshutdown);
		ch = smalloc(sizeof *ch);
		ch->ref.ref = 1;
		ch->l.perm = 0770;
		ch->sm = sm;
		do {
			ch->l.path = sm->path++;
			snprint(buf, sizeof buf, "%ld", ch->l.path);
		} while(lookup((Link*)b->srv, buf, Nopath) != nil);
		kstrdup(&ch->l.name, buf);
		kstrdup(&ch->l.owner, up->user);

		/* link to all boards list */
		ch->next = &sm->root;
		ch->prev = sm->root.prev;
		ch->next->prev = ch;
		ch->prev->next = ch;

		/* link to parent board */
		ch->parent = b;
		ch->l.link = b->child;
		b->child = ch;

		c->aux = ch;
		c->qid.path = SRVQID(ch->l.path, Qlease);
		c->mode = mode;
		boardclunk(b);
		wunlock(&sm->lk);
		poperror();
		return c;
	}

	rlock(&sm->lk);
	if(waserror()){
		runlock(&sm->lk);
		nexterror();
	}
	if(c->qid.type == QTDIR){
		if(omode != OREAD)
			error(Eisdir);
		devpermcheck(b->l.owner, b->l.perm, omode);
		c->mode = mode;
		c->flag |= COPEN;
		c->offset = 0;
		runlock(&sm->lk);
		poperror();
		return c;
	}
	if(b->closed)
		error(Eshutdown);

	sp = lookup((Link*)b->srv, nil, c->qid.path);
	if(sp == nil)
		error(Eshutdown);
	nc = sp->chan;
	if(nc == nil)
		error(Eshutdown);
	if(mode != nc->mode && nc->mode != ORDWR)
		error(Eperm);
	devpermcheck(sp->l.owner, sp->l.perm, omode);

	incref(&nc->ref);

	runlock(&sm->lk);
	poperror();

	cclose(c);
	return nc;
}

static Chan*
srvcreate(Chan *c, char *name, int omode, ulong perm)
{
	Board *b;
	Srvmach *sm;
	Srv *sp;

	if(openmode(omode) != OWRITE)
		error(Eperm);

	if(strlen(name) >= sizeof(up->genbuf))
		error(Etoolong);

	if(strcmp(name, clone) == 0)
		error(Eexist);

	sp = smalloc(sizeof *sp);
	kstrdup(&sp->l.name, name);
	kstrdup(&sp->l.owner, up->user);

	b = c->aux;
	sm = b->sm;
	wlock(&sm->lk);
	if(waserror()){
		wunlock(&sm->lk);
		freelink(&sp->l);
		nexterror();
	}
	if(b->closed)
		error(Eshutdown);
	devpermcheck(b->l.owner, b->l.perm, OWRITE);
	if(lookup((Link*)b->srv, name, Nopath) != nil)
		error(Eexist);
	if(lookup((Link*)b->child, name, Nopath) != nil)
		error(Eexist);

	sp->l.perm = perm&0777;
	sp->l.path = sm->path++;

	c->qid.path = SRVQID(sp->l.path, Qsrv);
	c->qid.type = QTFILE;

	sp->l.link = b->srv;
	b->srv = sp;

	wunlock(&sm->lk);
	poperror();

	c->flag |= COPEN;
	c->mode = OWRITE;

	return c;
}

static void
srvremove(Chan *c)
{
	Board *b;
	Srvmach *sm;
	Srv *sp;

	b = c->aux;
	sm = b->sm;
	wlock(&sm->lk);
	if(waserror()){
		boardclunk(b);
		wunlock(&sm->lk);
		nexterror();
	}
	if(c->qid.type == QTDIR)
		error(Eperm);
	switch(SRVTYPE(c->qid.path)){
	case Qlease:
	case Qclone:
		error(Eperm);
	}

	sp = lookup((Link*)b->srv, nil, c->qid.path);
	if(sp == nil)
		error(Enonexist);

	if(strcmp(sp->l.owner, up->user) != 0 && !iseve())
		error(Eperm);

	linkremove((Link**)&b->srv, nil, c->qid.path);

	boardclunk(b);
	wunlock(&sm->lk);
	poperror();

	if(sp->chan != nil)
		cclose(sp->chan);
	freelink(&sp->l);
}

static int
srvwstat(Chan *c, uchar *dp, int n)
{
	Board *b, *s;
	Srvmach *sm;
	char *strs;
	Dir d;
	Link *lp;

	switch(SRVTYPE(c->qid.path)){
	case Qlease:
	case Qclone:
		error(Eperm);
	}
	b = c->aux;
	sm = b->sm;
	if(c->qid.type == QTDIR && isroot(b))
		error(Eperm);

	strs = smalloc(n);
	if(waserror()){
		free(strs);
		nexterror();
	}
	n = convM2D(dp, n, &d, strs);
	if(n == 0)
		error(Eshortstat);

	wlock(&sm->lk);
	if(waserror()){
		wunlock(&sm->lk);
		nexterror();
	}
	if(b->closed)
		error(Eshutdown);

	if(c->qid.type == QTDIR)
		lp = &b->l;
	else
		lp = lookup((Link*)b->srv, nil, c->qid.path);
	if(lp == nil)
		error(Enonexist);

	if(strcmp(lp->owner, up->user) != 0 && !iseve())
		error(Eperm);

	if(d.name != nil && *d.name && strcmp(lp->name, d.name) != 0) {
		if(strchr(d.name, '/') != nil)
			error(Ebadchar);
		if(strlen(d.name) >= sizeof(up->genbuf))
			error(Etoolong);

		/* Ensure new name doesn't conflict with old names */
		if(strcmp(d.name, clone) == 0)
			error(Eexist);
		if(c->qid.type == QTDIR)
			s = b->parent;
		else
			s = b;
		if(lookup((Link*)s->srv, d.name, Nopath) != nil)
			error(Eexist);
		if(lookup((Link*)s->child, d.name, Nopath) != nil)
			error(Eexist);
		kstrdup(&lp->name, d.name);
	}
	if(d.uid != nil && *d.uid)
		kstrdup(&lp->owner, d.uid);
	if(d.mode != Nopath)
		lp->perm = d.mode & 0777;

	wunlock(&sm->lk);
	poperror();

	free(strs);
	poperror();

	return n;
}

static void
srvclose(Chan *c)
{
	Srv *sp, *link;
	Board *b;
	Srvmach *sm;

	if((c->flag & CRCLOSE) != 0 && SRVTYPE(c->qid.path) != Qlease){
		/*
		 * in theory we need to override any changes in removability
		 * since open, but since all that's checked is the owner,
	 	 * which is immutable, all is well.
	 	 */
		if(waserror())
			return;
		srvremove(c);
		poperror();
		return;
	}

	b = c->aux;
	if(isroot(b))
		return;
	sm = b->sm;

	wlock(&sm->lk);
	if(SRVTYPE(c->qid.path) != Qlease){
		boardclunk(b);
		wunlock(&sm->lk);
		return;
	}

	/* free later after releasing the lock */
	sp = b->srv;
	b->srv = nil;
	b->closed++;
	boardclunk(b);
	wunlock(&sm->lk);

	for(; sp != nil; sp = link){
		link = sp->l.link;
		if(sp->chan != nil)
			cclose(sp->chan);
		freelink(&sp->l);
	}
}

static long
srvread(Chan *c, void *va, long n, vlong off)
{
	Board *b;
	Srvmach *sm;

	if(SRVTYPE(c->qid.path) == Qlease){
		b = c->aux;
		sm = b->sm;
		rlock(&sm->lk);
		if(waserror()){
			runlock(&sm->lk);
			nexterror();
		}
		n = readstr((ulong)off, va, n, b->l.name);
		runlock(&sm->lk);
		poperror();
		return n;
	}
	isdir(c);
	return devdirread(c, va, n, 0, 0, srvgen);
}

/*
 * The rest of 9front's srvwrite after fdtochan: holds c1 in the entry,
 * found by name or by qid path as lookup does. Consumes the reference to
 * c1, even on error.
 */
static void
post(Board *b, char *name, ulong qidpath, Chan *c1, char *srvname)
{
	Srvmach *sm;
	Srv *sp;

	sm = b->sm;
	wlock(&sm->lk);
	if(waserror()) {
		wunlock(&sm->lk);
		cclose(c1);
		nexterror();
	}
	if(b->closed)
		error(Eshutdown);
	if(c1->qid.type & QTAUTH)
		error("cannot post auth file in srv");
	sp = lookup((Link*)b->srv, name, qidpath);
	if(sp == nil)
		error(Enonexist);

	if(sp->chan != nil)
		error(Ebadusefd);

	sp->chan = c1;

	if(c1->srvname == nil && srvname != nil)
		kstrdup(&c1->srvname, srvname);

	wunlock(&sm->lk);
	poperror();
}

static long
srvwrite(Chan *c, void *va, long n, vlong off)
{
	Chan *c1;
	int fd;
	char buf[32];

	USED(off);
	if(SRVTYPE(c->qid.path) == Qlease)
		error(Eperm);

	if(n >= sizeof buf)
		error(Etoobig);
	memmove(buf, va, n);	/* so we can NUL-terminate */
	buf[n] = 0;
	fd = strtoul(buf, 0, 0);

	c1 = fdtochan(fd, -1, 0, 1);	/* error check and inc ref */
	post(c->aux, nil, c->qid.path, c1, c->path != nil ? c->path->s : nil);
	return n;
}

/*
 * Posts c as name on board b (a #s chan's aux) without a guest fd, as
 * a write of an fd into a created entry does. Makes the entry, owned by
 * the caller with mode perm, if it doesn't exist. Takes over the
 * caller's reference to c, even on error. Raises kernel errors.
 */
void
h9_srvpost(void *v, char *name, Chan *c, ulong perm)
{
	Board *b;
	Srvmach *sm;
	Srv *sp;
	char *srvname, *err;

	b = v;
	sm = b->sm;
	if(waserror()){
		cclose(c);
		nexterror();
	}
	if(strlen(name) >= sizeof(up->genbuf))
		error(Etoolong);
	if(strcmp(name, clone) == 0 || strchr(name, '/') != nil)
		error(Ebadchar);
	srvname = smprint("/srv/%s", name);
	if(srvname == nil)
		error(Enomem);
	sp = smalloc(sizeof *sp);
	kstrdup(&sp->l.name, name);
	kstrdup(&sp->l.owner, up->user);
	sp->l.perm = perm&0777;

	wlock(&sm->lk);
	err = nil;
	if(b->closed)
		err = Eshutdown;
	else if(lookup((Link*)b->child, name, Nopath) != nil
	|| lookup((Link*)b->srv, name, Nopath) != nil)
		err = Eexist;
	if(err != nil){
		wunlock(&sm->lk);
		freelink(&sp->l);
		free(srvname);
		error(err);
	}
	sp->l.path = sm->path++;
	sp->l.link = b->srv;
	b->srv = sp;
	wunlock(&sm->lk);
	poperror();

	if(waserror()){
		free(srvname);
		nexterror();
	}
	post(b, name, Nopath, c, srvname);
	poperror();
	free(srvname);
}

/*
 * Closes every service posted in machine m's registry and every board,
 * as closing each lease would. Called by the machine's last process
 * before it ends (proc.c), so that what the channels hold goes while the
 * machine is still there. Nothing can attach afterwards.
 */
void
h9_srvmachclose(Hmach *m)
{
	Srvmach *sm;
	Board *b;
	Srv *sp, *list, *link;

	lock(&m->lk);
	sm = m->srv;
	unlock(&m->lk);
	if(sm == nil)
		return;

	list = nil;
	wlock(&sm->lk);
	b = &sm->root;
	do {
		b->closed++;
		while((sp = b->srv) != nil){
			b->srv = sp->l.link;
			sp->l.link = list;
			list = sp;
		}
		b = b->next;
	} while(b != &sm->root);
	wunlock(&sm->lk);

	for(sp = list; sp != nil; sp = link){
		link = sp->l.link;
		if(sp->chan != nil)
			cclose(sp->chan);
		freelink(&sp->l);
	}
}

/*
 * Frees machine m's registry when the machine goes (proc.c), after
 * h9_srvmachclose. No chan on it is left: every one was in a process's
 * groups or posted on a board.
 */
void
h9_srvmachfree(Hmach *m)
{
	Srvmach *sm;
	Board *b, *next;

	sm = m->srv;
	if(sm == nil)
		return;
	m->srv = nil;
	for(b = sm->root.next; b != &sm->root; b = next){
		next = b->next;
		free(b->l.name);
		free(b->l.owner);
		free(b);
	}
	free(sm->root.l.name);
	free(sm->root.l.owner);
	free(sm);
}

Dev srvdevtab = {
	's',
	"srv",

	devreset,
	devinit,
	devshutdown,
	srvattach,
	srvwalk,
	srvstat,
	srvopen,
	srvcreate,
	srvclose,
	srvread,
	devbread,
	srvwrite,
	devbwrite,
	srvremove,
	srvwstat,
};
