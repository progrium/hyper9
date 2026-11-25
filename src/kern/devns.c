/*
 * #N: the namespace kernel's namespaces (design/epoch-0/namespace-kernel.md).
 *
 *	/ns/clone	open: a new namespace, empty, whose ctl the fid is
 *	/ns/N/ctl	write: newns lines run in N; read: N's id
 *	/ns/N/ns	read: N's mount table, in newns syntax
 *
 * A namespace is a Pgrp, a root (slash), and a dot. An empty one's root
 * is a fresh bare #O, so the host can make mount points with Tcreate;
 * `copy P` as the first line makes it a copy of P's mount table, root
 * and dot instead. #N and #s are masked in every namespace but 0, the
 * control namespace, and a copy of 0 has /ns and /srv unmounted, so a
 * task handed its namespace can't reach the others or the host's board.
 *
 * Each ctl line runs on a kernel process of its own (ctlproc), in N:
 * its Pgrp, slash and dot, as the process that booted the namespace
 * kernel's machine. bind, mount, unmount and cd go to the Zig leaf
 * h9_ns_ctl (src/nskernel.zig), which parses them with src/newns.zig and
 * makes the kernel's system calls, and dials mounts; copy, empty, clear,
 * board, hold and free are done here. Lines of one namespace run one at
 * a time, under its ctl QLock. A line runs on a process of its own
 * because the sys* wrappers the Zig leaf calls must be a process's
 * outermost kernel call, and a device write isn't.
 *
 * Lifetime: a namespace holds a reference for each open ctl, each
 * attach kserve serves from it (h9_ns_lookup's Kns), and `hold`. The
 * last one going frees it: its Pgrp, root, dot, and board's lease, which
 * closes the board and what was posted there. Namespace 0 is never freed.
 * Ids are never reused.
 *
 * Boards: namespace 0's /srv is #s's root board, the host's. A `srv!NAME`
 * dial opens NAME there, whatever N can see. `board` gives N a board of
 * its own: a child board of the host's (#s/clone), whose lease N holds,
 * bound at N's /srv. The kernel attaches it in namespace 0, so N's mask
 * doesn't refuse it.
 *
 * Mounts' dial strings are recorded by their devmnt channel's dev
 * (h9_ns_dialed), so `ns` prints the dial string a ctl line mounted, and
 * the lines replay.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"

/* proc.c */
extern void	*h9_kprocsrc(void);
extern int	h9_kprocshare(void*, char*);
extern void	h9_kprocunshare(void);
extern void	h9_fgrpclose(Fgrp*);
/* devoverlay.c */
extern int	h9_overlay_new(Chan*);
extern void	h9_overlay_drop(int);
extern int	h9_overlay_nsunion(Chan*, char*, char*, int);
/* devsrv.c */
extern void	h9_srvpost(void*, char*, Chan*, ulong);
/* kserve.c */
extern void	*h9_kserve_kns(Pgrp*, Chan*, void (*)(void*), void*);
/* src/nskernel.zig: runs one bind, mount, unmount or cd line in the calling process's namespace */
extern int	h9_ns_ctl(void *ns, char *line, long n, char *err);

enum
{
	Qtop,
	Qclone,
	Qdir,
	Qctl,
	Qns,

	Maxctl	= 8192,		/* bytes in one ctl write */
};

#define QTYPE(p)	((int)((p)&7))
#define QNS(p)		((ulong)((p)>>3))
#define QPATH(id, t)	(((uvlong)(id)<<3)|(t))

typedef struct Dial Dial;
typedef struct Ns Ns;
typedef struct Ctl Ctl;

/* A mount's dial string, by its devmnt channel's dev. */
struct Dial
{
	Dial	*next;
	ulong	dev;
	char	*s;
};

struct Ns
{
	Ns	*next;
	ulong	id;
	int	ref;		/* under nslock */
	int	hold;		/* under nslock */
	int	used;		/* a line has run, so copy is too late; under ctl */
	QLock	ctl;		/* one line at a time */
	Lock	lk;		/* pg, slash, dot, board, dials */
	Pgrp	*pg;
	Chan	*slash;
	Chan	*dot;
	Chan	*board;		/* the lease on N's own board, or nil */
	Dial	*dials;
};

/* A ctl line handed to ctlproc. */
struct Ctl
{
	Ref	ref;		/* the writer's and ctlproc's */
	Ns	*ns;
	char	*line;
	int	done;
	Rendez	r;
	char	err[ERRMAX];
	int	failed;
};

static Lock	nslock;
static Ns	*nslist;
static ulong	nsnext;
static Ns	*ns0;
static void	*nssrc;		/* the booting process's record, for ctlproc's */

static char	Enons[] = "no such namespace";
static char	nsuser[KNAMELEN];	/* the booting process's user, ctlproc's */

static void	nsput(Ns*);

static Ns*
nsget(ulong id)
{
	Ns *n;

	lock(&nslock);
	for(n = nslist; n != nil; n = n->next)
		if(n->id == id && n->ref > 0)
			break;
	if(n != nil)
		n->ref++;
	unlock(&nslock);
	return n;
}

static void
dialsfree(Dial *d)
{
	Dial *e;

	for(; d != nil; d = e){
		e = d->next;
		free(d->s);
		free(d);
	}
}

static void
nsfree(Ns *n)
{
	closepgrp(n->pg);
	cclose(n->slash);
	cclose(n->dot);
	if(n->board != nil)
		cclose(n->board);
	dialsfree(n->dials);
	free(n);
}

static void
nsput(Ns *n)
{
	Ns **l;

	lock(&nslock);
	if(--n->ref > 0 || n == ns0){
		unlock(&nslock);
		return;
	}
	for(l = &nslist; *l != nil; l = &(*l)->next)
		if(*l == n){
			*l = n->next;
			break;
		}
	unlock(&nslock);
	nsfree(n);
}

/* What the calling process's namespace was, while it runs in another. */
typedef struct Saved Saved;
struct Saved
{
	Pgrp	*pg;
	Chan	*slash;
	Chan	*dot;
};

/* Runs the calling process in n, with references to n's groups. */
static void
nsenter(Ns *n, Saved *s)
{
	s->pg = up->pgrp;
	s->slash = up->slash;
	s->dot = up->dot;
	lock(&n->lk);
	incref(&n->pg->ref);
	up->pgrp = n->pg;
	incref(&n->slash->ref);
	up->slash = n->slash;
	incref(&n->dot->ref);
	up->dot = n->dot;
	unlock(&n->lk);
}

/* Puts the caller's namespace back; with keepdot, a cd made in n stays n's. */
static void
nsleave(Ns *n, Saved *s, int keepdot)
{
	Chan *old;

	old = nil;
	if(keepdot){
		lock(&n->lk);
		if(up->dot != n->dot){
			old = n->dot;
			incref(&up->dot->ref);
			n->dot = up->dot;
		}
		unlock(&n->lk);
	}
	if(old != nil)
		cclose(old);
	closepgrp(up->pgrp);
	cclose(up->slash);
	cclose(up->dot);
	up->pgrp = s->pg;
	up->slash = s->slash;
	up->dot = s->dot;
}

/* A fresh bare #O, as a root: its path is /. */
static Chan*
freshroot(void)
{
	Chan *c;
	char buf[32];
	int id;

	id = h9_overlay_new(nil);
	if(id < 0)
		error(up->errstr);
	snprint(buf, sizeof buf, "#O%d", id);
	if(waserror()){
		h9_overlay_drop(id);
		nexterror();
	}
	c = namec(buf, Atodir, 0, 0);
	poperror();
	/* The chan holds the instance now; it goes with the last one. */
	h9_overlay_drop(id);
	pathclose(c->path);
	c->path = newpath("/");
	return c;
}

static Ns*
nsnew(void)
{
	Ns *n;
	Chan *c;

	c = freshroot();
	n = mallocz(sizeof *n, 1);
	if(n == nil){
		cclose(c);
		error(Enomem);
	}
	n->pg = newpgrp();
	n->slash = c;
	incref(&c->ref);
	n->dot = c;
	n->ref = 1;
	lock(&nslock);
	n->id = nsnext++;
	n->next = nslist;
	nslist = n;
	unlock(&nslock);
	if(n->id != 0)
		devmask(n->pg, 0, "Ns");
	return n;
}

/* Mounts the device attach dev on path in the calling process's namespace, made if missing. */
static void
mountdev(char *dev, char *path, int flag)
{
	Chan *c0, *c1;

	if(!waserror()){
		cclose(namec(path, Acreate, OREAD, DMDIR|0775));
		poperror();
	}
	c0 = namec(dev, Atodir, 0, 0);
	if(waserror()){
		cclose(c0);
		nexterror();
	}
	c1 = namec(path, Amount, 0, 0);
	if(waserror()){
		cclose(c1);
		nexterror();
	}
	cmount(c0, c1, flag, nil);
	poperror();
	cclose(c1);
	poperror();
	cclose(c0);
}

/*
 * Makes namespace 0, the control namespace (design/epoch-0/namespace-kernel.md):
 * a bare #O with the namespaces at /ns, the host's board at /srv, and a
 * fresh #O at /tmp. Called once, by the namespace kernel's first process,
 * whose record ctlproc's processes share. Returns 0, or -1 with the
 * error string set.
 */
int
h9_ns_init(void)
{
	Saved s;
	char buf[32];
	int id;

	if(waserror()){
		char *p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	if(ns0 != nil)
		error("namespace kernel already booted");
	nssrc = h9_kprocsrc();
	if(nssrc == nil)
		error("devns: not an h9 process");
	kstrcpy(nsuser, up->user, sizeof nsuser);
	ns0 = nsnew();
	nsenter(ns0, &s);
	if(waserror()){
		nsleave(ns0, &s, 0);
		nexterror();
	}
	mountdev("#N", "/ns", MREPL);
	mountdev("#s", "/srv", MREPL);
	id = h9_overlay_new(nil);
	if(id < 0)
		error(up->errstr);
	snprint(buf, sizeof buf, "#O%d", id);
	if(waserror()){
		h9_overlay_drop(id);
		nexterror();
	}
	mountdev(buf, "/tmp", MREPL|MCREATE);
	poperror();
	h9_overlay_drop(id);
	poperror();
	nsleave(ns0, &s, 0);
	poperror();
	return 0;
}

/*
 * kserve's named source (src/kern/kserve.c): the attach name is a
 * namespace's id, and the empty name is 0.
 */
static void
knsput(void *a)
{
	nsput(a);
}

void*
h9_ns_lookup(char *aname)
{
	Ns *n;
	ulong id;
	char *e;
	void *k;

	if(aname == nil || *aname == '\0')
		id = 0;
	else {
		id = strtoul(aname, &e, 10);
		if(*e != '\0' || (aname[0] == '0' && aname[1] != '\0'))
			return nil;
	}
	n = nsget(id);
	if(n == nil)
		return nil;
	lock(&n->lk);
	k = h9_kserve_kns(n->pg, n->slash, knsput, n);
	unlock(&n->lk);
	if(k == nil)
		nsput(n);
	return k;
}

/* The device. */

static int
nsgen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Qid q;
	Ns *n;
	ulong id;
	int t;
	char buf[32];

	USED(tab, ntab, name);
	t = QTYPE(c->qid.path);
	if(s == DEVDOTDOT){
		mkqid(&q, QPATH(0, Qtop), 0, QTDIR);
		devdir(c, q, "#N", 0, eve, DMDIR|0555, dp);
		return 1;
	}
	if(t == Qtop){
		if(s == 0){
			mkqid(&q, QPATH(0, Qclone), 0, QTFILE);
			devdir(c, q, "clone", 0, eve, 0666, dp);
			return 1;
		}
		s--;
		lock(&nslock);
		for(n = nslist; n != nil; n = n->next)
			if(n->ref > 0 && s-- == 0)
				break;
		id = n != nil ? n->id : 0;
		unlock(&nslock);
		if(n == nil)
			return -1;
		snprint(buf, sizeof buf, "%lud", id);
		mkqid(&q, QPATH(id, Qdir), 0, QTDIR);
		devdir(c, q, buf, 0, eve, DMDIR|0555, dp);
		return 1;
	}
	id = QNS(c->qid.path);
	switch(s){
	case 0:
		mkqid(&q, QPATH(id, Qctl), 0, QTFILE);
		devdir(c, q, "ctl", 0, eve, 0666, dp);
		return 1;
	case 1:
		mkqid(&q, QPATH(id, Qns), 0, QTFILE);
		devdir(c, q, "ns", 0, eve, 0444, dp);
		return 1;
	}
	return -1;
}

static Chan*
nsattach(char *spec)
{
	Chan *c;

	c = devattach('N', spec);
	mkqid(&c->qid, QPATH(0, Qtop), 0, QTDIR);
	return c;
}

static Walkqid*
nswalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, nsgen);
}

static int
nsstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, nsgen);
}

static Chan*
nsopen(Chan *c, int omode)
{
	Ns *n;
	int t;

	t = QTYPE(c->qid.path);
	switch(t){
	case Qtop:
	case Qdir:
		if(omode != OREAD)
			error(Eisdir);
		break;
	case Qclone:
		n = nsnew();
		c->aux = n;
		mkqid(&c->qid, QPATH(n->id, Qctl), 0, QTFILE);
		break;
	case Qctl:
	case Qns:
		n = nsget(QNS(c->qid.path));
		if(n == nil)
			error(Enons);
		c->aux = n;
		if(t == Qns && omode != OREAD){
			nsput(n);
			c->aux = nil;
			error(Eperm);
		}
		break;
	}
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
nsclose(Chan *c)
{
	if((c->flag & COPEN) == 0 || c->aux == nil)
		return;
	nsput(c->aux);
	c->aux = nil;
}

/* The mount flags as newns writes them. */
static char*
flagstr(int flag, char *buf)
{
	char *p;

	p = buf;
	if(flag & (MBEFORE|MAFTER|MCREATE|MCACHE)){
		*p++ = '-';
		if(flag & MBEFORE)
			*p++ = 'b';
		if(flag & MAFTER)
			*p++ = 'a';
		if(flag & MCREATE)
			*p++ = 'c';
		if(flag & MCACHE)
			*p++ = 'C';
	}
	*p = '\0';
	return buf;
}

/* A devmnt channel's dial string, or nil. Called with n->lk. */
static char*
dialof(Ns *n, Chan *to)
{
	Dial *d;

	for(d = n->dials; d != nil; d = d->next)
		if(d->dev == to->dev)
			return d->s;
	return nil;
}

/* N's mount table as newns lines, then its cd. */
static char*
nstext(Ns *n)
{
	Mount *f;
	char *buf, *p, *e, *dial, flag[8];
	long size;
	int m;

	size = 4096;
	buf = smalloc(size);
Again:
	p = buf;
	e = buf+size;
	lock(&n->lk);
	rlock(&n->pg->ns);
	for(f = n->pg->mntorder; f != nil; f = f->order){
		if(e-p < 2*KNAMELEN+64){
			runlock(&n->pg->ns);
			unlock(&n->lk);
			size *= 2;
			free(buf);
			buf = smalloc(size);
			goto Again;
		}
		flagstr(f->mflag, flag);
		if(devtab[f->to->type]->dc == 'M'){
			dial = dialof(n, f->to);
			if(dial == nil)
				dial = f->to->mchan->srvname != nil ? f->to->mchan->srvname : chanpath(f->to->mchan);
			if(*f->spec)
				m = snprint(p, e-p, "mount %s %q %q %q\n", flag, dial, chanpath(f->umh->from), f->spec);
			else
				m = snprint(p, e-p, "mount %s %q %q\n", flag, dial, chanpath(f->umh->from));
		} else if((m = h9_overlay_nsunion(f->to, chanpath(f->umh->from), p, e-p)) < 0)
			m = snprint(p, e-p, "bind %s %q %q\n", flag, chanpath(f->to), chanpath(f->umh->from));
		if(m >= e-p-1){
			runlock(&n->pg->ns);
			unlock(&n->lk);
			size *= 2;
			free(buf);
			buf = smalloc(size);
			goto Again;
		}
		p += m;
	}
	runlock(&n->pg->ns);
	if(e-p < KNAMELEN+16){
		unlock(&n->lk);
		size *= 2;
		free(buf);
		buf = smalloc(size);
		goto Again;
	}
	snprint(p, e-p, "cd %q\n", chanpath(n->dot));
	unlock(&n->lk);
	return buf;
}

static long
nsread(Chan *c, void *va, long n, vlong off)
{
	Ns *ns;
	char buf[32], *s;

	switch(QTYPE(c->qid.path)){
	case Qtop:
	case Qdir:
		return devdirread(c, va, n, nil, 0, nsgen);
	case Qctl:
		ns = c->aux;
		snprint(buf, sizeof buf, "%lud", ns->id);
		return readstr((ulong)off, va, n, buf);
	case Qns:
		s = nstext(c->aux);
		if(waserror()){
			free(s);
			nexterror();
		}
		n = readstr((ulong)off, va, n, s);
		poperror();
		free(s);
		return n;
	}
	error(Egreg);
	return 0;
}

/*
 * Records the dial string of the mount a ctl line just made in ns: the
 * devmnt channel in its mount table with no record yet. Called by the Zig
 * leaf, in ns.
 */
void
h9_ns_dialed(void *v, char *dial)
{
	Ns *n;
	Mount *f;
	Dial *d, *nd;

	n = v;
	nd = mallocz(sizeof *nd, 1);
	if(nd == nil)
		return;
	nd->s = strdup(dial);
	if(nd->s == nil){
		free(nd);
		return;
	}
	lock(&n->lk);
	rlock(&n->pg->ns);
	for(f = n->pg->mntorder; f != nil; f = f->order){
		if(devtab[f->to->type]->dc != 'M')
			continue;
		for(d = n->dials; d != nil; d = d->next)
			if(d->dev == f->to->dev)
				break;
		if(d == nil){
			nd->dev = f->to->dev;
			nd->next = n->dials;
			n->dials = nd;
			nd = nil;
			break;
		}
	}
	runlock(&n->pg->ns);
	unlock(&n->lk);
	if(nd != nil){
		free(nd->s);
		free(nd);
	}
}

/*
 * Opens NAME on the host's board, namespace 0's /srv, for a srv!NAME
 * dial. Returns an fd in the calling process, or -1 with the error
 * string set.
 */
int
h9_ns_hostsrv(char *name)
{
	Saved s;
	Chan *c;
	char *path;
	int fd;

	if(waserror()){
		char *p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	if(*name == '\0' || strchr(name, '/') != nil || strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
		error("bad srv name");
	path = smprint("#s/%s", name);
	if(path == nil)
		error(Enomem);
	nsenter(ns0, &s);
	if(waserror()){
		nsleave(ns0, &s, 0);
		free(path);
		nexterror();
	}
	c = namec(path, Aopen, ORDWR, 0);
	poperror();
	nsleave(ns0, &s, 0);
	free(path);
	fd = newfd(c, 0);
	if(fd < 0){
		cclose(c);
		error(Enofd);
	}
	poperror();
	return fd;
}

/*
 * post NAME DIAL: posts fd, a 9P2000 connection the Zig leaf dialed, as
 * NAME on ns's board: the host's for namespace 0, or the one `board`
 * gave it. The fd stays the caller's. Returns 0, or -1 with the error
 * string set.
 */
int
h9_ns_srvpost(void *v, char *name, int fd)
{
	Ns *n;
	Saved s;
	Chan *c, *b;

	n = v;
	c = nil;
	b = nil;
	if(waserror()){
		char *p;

		if(c != nil)
			cclose(c);
		if(b != nil)
			cclose(b);
		p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	c = fdtochan(fd, ORDWR, 0, 1);
	if(n == ns0){
		nsenter(ns0, &s);
		if(waserror()){
			nsleave(ns0, &s, 0);
			nexterror();
		}
		b = namec("#s", Atodir, 0, 0);
		poperror();
		nsleave(ns0, &s, 0);
	} else {
		lock(&n->lk);
		b = n->board;
		if(b != nil)
			incref(&b->ref);
		unlock(&n->lk);
		if(b == nil)
			error("post: no board; write board first");
	}
	h9_srvpost(b->aux, name, c, 0666);
	c = nil;
	cclose(b);
	b = nil;
	poperror();
	return 0;
}

/* clear: empties n's mount table in place, so its attaches see it too. */
static void
nsclear(Ns *n)
{
	Pgrp *pg;
	Mhead *f;
	Mount *m;
	int i;

	pg = n->pg;
	wlock(&pg->ns);
	for(i = 0; i < MNTHASH; i++)
		while((f = pg->mnthash[i]) != nil){
			pg->mnthash[i] = f->hash;
			wlock(&f->lock);
			m = f->mount;
			f->mount = nil;
			wunlock(&f->lock);
			mountfree(m);
			putmhead(f);
		}
	pg->mntorder = nil;
	pg->mntordertail = &pg->mntorder;
	wunlock(&pg->ns);
	lock(&n->lk);
	dialsfree(n->dials);
	n->dials = nil;
	unlock(&n->lk);
}

/* Unmounts everything on path in the calling process's namespace, if anything is. */
static void
unmountall(char *path)
{
	Chan *c;

	if(waserror())
		return;
	c = namec(path, Amount, 0, 0);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	cunmount(c, nil);
	poperror();
	cclose(c);
	poperror();
}

/* copy P: n's mount table, root and dot become copies of P's. */
static void
nscopy(Ns *n, ulong pid)
{
	Ns *p;
	Saved s;
	Dial *d, *nd, **l;
	Chan *slash, *dot;

	p = nsget(pid);
	if(p == nil)
		error(Enons);
	if(waserror()){
		nsput(p);
		nexterror();
	}
	pgrpcpy(n->pg, p->pg, RFNAMEG);
	/* pgrpcpy copied P's mask too: n's own stands. */
	devmask(n->pg, 0, "Ns");
	lock(&p->lk);
	slash = p->slash;
	incref(&slash->ref);
	dot = p->dot;
	incref(&dot->ref);
	l = &nd;
	nd = nil;
	for(d = p->dials; d != nil; d = d->next){
		*l = mallocz(sizeof **l, 1);
		if(*l == nil)
			break;
		(*l)->dev = d->dev;
		(*l)->s = strdup(d->s);
		if((*l)->s == nil){
			free(*l);
			*l = nil;
			break;
		}
		l = &(*l)->next;
	}
	unlock(&p->lk);
	lock(&n->lk);
	cclose(n->slash);
	n->slash = slash;
	cclose(n->dot);
	n->dot = dot;
	dialsfree(n->dials);
	n->dials = nd;
	unlock(&n->lk);
	if(p == ns0){
		/* The control namespace's /ns and host's board stay its own. */
		nsenter(n, &s);
		unmountall("/ns");
		unmountall("/srv");
		nsleave(n, &s, 0);
	}
	poperror();
	nsput(p);
}

/* board: a fresh, empty board of n's own at its /srv. */
static void
nsboard(Ns *n)
{
	Saved s;
	Chan *lease, *dir, *mnt;
	char name[32], *path;
	long m;

	if(n == ns0)
		error("namespace 0's board is the host's");
	nsenter(ns0, &s);
	if(waserror()){
		nsleave(ns0, &s, 0);
		nexterror();
	}
	lease = namec("#s/clone", Aopen, ORDWR, 0);
	if(waserror()){
		cclose(lease);
		nexterror();
	}
	m = devtab[lease->type]->read(lease, name, sizeof name - 1, 0);
	if(m <= 0)
		error("board: no lease name");
	name[m] = '\0';
	path = smprint("#s/%s", name);
	if(path == nil)
		error(Enomem);
	if(waserror()){
		free(path);
		nexterror();
	}
	dir = namec(path, Atodir, 0, 0);
	poperror();
	free(path);
	poperror();
	poperror();
	nsleave(ns0, &s, 0);

	if(waserror()){
		cclose(dir);
		cclose(lease);
		nexterror();
	}
	nsenter(n, &s);
	if(waserror()){
		nsleave(n, &s, 0);
		nexterror();
	}
	if(!waserror()){
		cclose(namec("/srv", Acreate, OREAD, DMDIR|0775));
		poperror();
	}
	mnt = namec("/srv", Amount, 0, 0);
	if(waserror()){
		cclose(mnt);
		nexterror();
	}
	cmount(dir, mnt, MREPL, nil);
	poperror();
	cclose(mnt);
	poperror();
	nsleave(n, &s, 0);
	poperror();
	cclose(dir);
	lock(&n->lk);
	if(n->board != nil){
		/* the old board closes with its lease */
		dir = n->board;
		n->board = lease;
		unlock(&n->lk);
		cclose(dir);
	} else {
		n->board = lease;
		unlock(&n->lk);
	}
}

static void
ctlput(Ctl *x)
{
	if(decref(&x->ref) != 0)
		return;
	nsput(x->ns);
	free(x->line);
	free(x);
}

/* The lines devns.c runs itself; the rest go to the Zig leaf. */
static int
isnsline(char *cmd)
{
	static char *cmds[] = { "copy", "empty", "clear", "board", "hold", "free" };
	int i;

	for(i = 0; i < nelem(cmds); i++)
		if(strcmp(cmd, cmds[i]) == 0)
			return 1;
	return 0;
}

/* Runs one line in its namespace, on a process of its own. */
static void
ctlproc(void *a)
{
	Ctl *x;
	Ns *n;
	Fgrp *f;
	Saved s;
	char cmd[16], *arg;
	int m;

	x = a;
	n = x->ns;
	h9_kprocshare(nssrc, "nsctl");
	f = up->fgrp;
	up->fgrp = dupfgrp(nil);
	if(f != nil)
		h9_fgrpclose(f);
	strecpy(up->user, up->user+sizeof up->user, nsuser);
	m = strcspn(x->line, " \t");
	if(m >= sizeof cmd)
		m = sizeof cmd - 1;
	memmove(cmd, x->line, m);
	cmd[m] = '\0';
	arg = x->line + strcspn(x->line, " \t");
	while(*arg == ' ' || *arg == '\t')
		arg++;
	if(!isnsline(cmd)){
		/*
		 * bind, mount, unmount, cd, post: the Zig leaf, in n. Its
		 * system calls must be the process's outermost kernel call,
		 * so this isn't under waserror.
		 */
		nsenter(n, &s);
		if(h9_ns_ctl(n, x->line, strlen(x->line), x->err) < 0)
			x->failed = 1;
		nsleave(n, &s, 1);
	} else if(waserror()){
		kstrcpy(x->err, up->errstr, sizeof x->err);
		x->failed = 1;
	} else {
		if(strcmp(cmd, "copy") == 0){
			char *e;
			ulong pid;

			if(n->used)
				error("copy must be the first line");
			pid = strtoul(arg, &e, 10);
			while(*e == ' ' || *e == '\t')
				e++;
			if(*arg == '\0' || *e != '\0')
				error(Ebadctl);
			nscopy(n, pid);
		} else if(strcmp(cmd, "empty") == 0){
			if(n->used)
				error("empty must be the first line");
		} else if(strcmp(cmd, "clear") == 0){
			nsclear(n);
		} else if(strcmp(cmd, "board") == 0){
			nsboard(n);
		} else if(strcmp(cmd, "hold") == 0){
			lock(&nslock);
			if(!n->hold){
				n->hold = 1;
				n->ref++;
			}
			unlock(&nslock);
		} else if(strcmp(cmd, "free") == 0){
			int had;

			if(n == ns0)
				error("namespace 0 can't be freed");
			lock(&nslock);
			had = n->hold;
			n->hold = 0;
			unlock(&nslock);
			if(had)
				nsput(n);
		}
		poperror();
	}
	n->used = 1;
	x->done = 1;
	wakeup(&x->r);
	ctlput(x);
	h9_kprocunshare();
	pexit("", 0);
}

static int
ctldone(void *a)
{
	return ((Ctl*)a)->done;
}

/* Runs line in n, raising its error. */
static void
runctl(Ns *n, char *line)
{
	Ctl *x;

	x = mallocz(sizeof *x, 1);
	if(x == nil)
		error(Enomem);
	x->line = strdup(line);
	if(x->line == nil){
		free(x);
		error(Enomem);
	}
	x->ns = n;
	lock(&nslock);
	n->ref++;
	unlock(&nslock);
	x->ref.ref = 2;
	kproc("nsctl", ctlproc, x);
	if(waserror()){
		ctlput(x);
		nexterror();
	}
	sleep(&x->r, ctldone, x);
	poperror();
	if(x->failed){
		char err[ERRMAX];

		kstrcpy(err, x->err, sizeof err);
		ctlput(x);
		error(err);
	}
	ctlput(x);
}

static long
nswrite(Chan *c, void *va, long n, vlong off)
{
	Ns *ns;
	char *buf, *p, *e;

	USED(off);
	if(QTYPE(c->qid.path) != Qctl)
		error(Eperm);
	if(n > Maxctl)
		error(Etoobig);
	ns = c->aux;
	buf = smalloc(n+1);
	memmove(buf, va, n);
	buf[n] = '\0';
	qlock(&ns->ctl);
	if(waserror()){
		qunlock(&ns->ctl);
		free(buf);
		nexterror();
	}
	for(p = buf; *p != '\0'; p = e){
		e = strchr(p, '\n');
		if(e != nil)
			*e++ = '\0';
		else
			e = p+strlen(p);
		while(*p == ' ' || *p == '\t')
			p++;
		if(*p == '\0' || *p == '#')
			continue;
		runctl(ns, p);
	}
	poperror();
	qunlock(&ns->ctl);
	free(buf);
	return n;
}

Dev nsdevtab = {
	'N',
	"ns",

	devreset,
	devinit,
	devshutdown,
	nsattach,
	nswalk,
	nsstat,
	nsopen,
	devcreate,
	nsclose,
	nsread,
	devbread,
	nswrite,
	devbwrite,
	devremove,
	devwstat,
};

/*
 * Connections for the namespace kernel's serving process
 * (src/nskernel.zig): posted from any thread, a host thread's or a
 * stream's, and taken by the server, which sleeps here.
 */
typedef struct Nsreq Nsreq;
struct Nsreq
{
	Nsreq	*next;
	int	kind;
	long	arg;
	char	*aname;
};

static struct
{
	Lock	lk;
	Nsreq	*head, **tail;
	Rendez	r;
} reqs;

/* Posts a connection: kind and arg are the server's, aname its attach name. Returns 0, or -1 out of memory. */
int
h9_ns_post(int kind, long arg, char *aname)
{
	Nsreq *q;

	q = malloc(sizeof *q);
	if(q == nil)
		return -1;
	q->aname = strdup(aname != nil ? aname : "");
	if(q->aname == nil){
		free(q);
		return -1;
	}
	q->kind = kind;
	q->arg = arg;
	q->next = nil;
	lock(&reqs.lk);
	if(reqs.tail == nil)
		reqs.tail = &reqs.head;
	*reqs.tail = q;
	reqs.tail = &q->next;
	unlock(&reqs.lk);
	wakeup(&reqs.r);
	return 0;
}

static int
havereq(void *a)
{
	USED(a);
	return reqs.head != nil;
}

/*
 * The next connection posted, its attach name copied to aname (n
 * bytes). Sleeps until there is one. Returns 0, or -1 if interrupted.
 */
int
h9_ns_next(int *kind, long *arg, char *aname, int n)
{
	Nsreq *q;

	if(waserror())
		return -1;
	sleep(&reqs.r, havereq, nil);
	poperror();
	lock(&reqs.lk);
	q = reqs.head;
	reqs.head = q->next;
	if(reqs.head == nil)
		reqs.tail = &reqs.head;
	unlock(&reqs.lk);
	*kind = q->kind;
	*arg = q->arg;
	strecpy(aname, aname+n, q->aname);
	free(q->aname);
	free(q);
	return 0;
}
