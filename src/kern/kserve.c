/*
 * kserve: h9's 9P2000 server in the kernel (design/epoch-0/kernel-serve.md).
 * serve's per-connection path (src/machine.zig) hands it a channel that
 * reads and writes whole 9P2000 messages, a #ℓ conversation's data, and
 * it answers them from kernel channels directly, in place of an exportfs
 * guest process.
 *
 * A fid holds a Chan. Twalk clones the fid's channel and walks it with
 * chan.c's walk(), one name at a time, so the walk crosses mounts as
 * namec's does and each Rwalk qid is the one a stat there would give (the
 * mounted directory's, for a mount point). An unopened fid's channel is
 * left before a mount point, as walk() leaves it, so .. back across a
 * mount is walk()'s own. Topen, Tstat and Twstat cross the mount point
 * as namec's Aopen and Aaccess do, and Tcreate finds a union's MCREATE
 * member with chan.c's createdir, as namec's Acreate does. Reads of a
 * directory go through sysfile.c's kread (h9_chanread), so unions and
 * mount points read as through read(2).
 *
 * Each connection has a reader kproc, which parses messages and hands
 * them to workers: up to Nworker kprocs (coroutines on the web host),
 * started as requests need them and kept until the connection ends, so a
 * request that blocks holds up only its worker. Past that, requests wait
 * in a queue of up to Maxqueue, and past that the reader stops reading.
 * Tflush is answered by the reader: a request still queued is dropped and
 * Rflush sent at once; one a worker is running is interrupted, as a note
 * interrupts a system call, and its Rflush follows the worker's reply.
 *
 * The workers run as the process that started serving (serve's server
 * Proc): its namespace, its user, a record in its machine
 * (h9_kprocshare), and its plan and pages (h9_kern_locals), so devfs's
 * checks, the write policy and --read-deny apply as to exportfs's system
 * calls. Their slash is the attach root, marked (h9_fs_markroot) under
 * --serve-root so walkl's h9_fs_atroot stops .. there. A connection's
 * source of namespaces is an interface (Ksource), for namespace-kernel's
 * namespaces by attach name; serve's is the server Proc's.
 *
 * kserve parses untrusted input in the kernel: convM2S bounds-checks
 * each message, and a message it can't parse ends the connection.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "tsleep.h"

/* proc.c */
extern void	*h9_kprocsrc(void);
extern void	h9_kprocput(void*);
extern int	h9_kprocshare(void*, char*);
extern void	h9_kprocunshare(void);
/* linux.c */
extern void	h9_fs_markroot(Chan*, int);
/* sysfile.c */
extern long	h9_chanread(Chan*, uchar*, long, vlong*);
extern long	h9_chanstat(Chan*, uchar*, long);
/* chan.c */
extern Chan	*cunique(Chan*);
extern Chan	*createdir(Chan*, Mhead*);
/* src/kern.zig: the calling thread's plan, pages and CPUs */
extern void	h9_kern_locals(int save, uintptr *slots);

enum {
	Maxmsg		= 8192+IOHDRSZ,	/* as exportfs's */
	Nworker		= 32,		/* requests run at once, per connection */
	Maxqueue	= 64,		/* requests waiting for a worker */
	Maxfid		= 4096,		/* fids per connection */
	Nfidhash	= 64,
};

typedef struct Kns Kns;
typedef struct Kfid Kfid;
typedef struct Kreq Kreq;
typedef struct Kworker Kworker;
typedef struct Kconn Kconn;
typedef struct Kserver Kserver;

/*
 * A namespace a fid is served from: a Pgrp and the root .. stops at. A
 * named source's (h9_kserve_kns) calls put(arg) when its last fid goes.
 */
struct Kns
{
	Ref	ref;
	Pgrp	*pg;
	Chan	*slash;
	void	(*put)(void*);
	void	*arg;
};

struct Kfid
{
	Kfid	*next;
	u32int	fid;
	int	ref;		/* the table's, and each request's; under the conn's lk */
	Chan	*c;		/* under lk: a walk or open replaces it */
	Chan	*wc;		/* once open, the channel it was walked to, or nil */
	int	open;
	int	mode;		/* the open mode */
	Kns	*ns;
};

struct Kreq
{
	Kreq	*next;
	Fcall	f;
	uchar	*buf;		/* the message f points into */
	int	flushed;	/* a Tflush interrupted it */
	int	done;		/* its reply is going; no more interrupts */
	ushort	ftag[8];	/* the flushes' tags, answered after it */
	int	nftag;
};

struct Kworker
{
	Kworker	*next;		/* on the conn's list */
	Kworker	*inext;		/* on the idle list */
	Kconn	*k;
	Proc	*p;		/* set by the worker; nil once it's leaving */
	Rendez	r;
	Kreq	*req;		/* handed to it while idle */
	Kreq	*cur;		/* the request it's running */
	uchar	*out;		/* reply buffer */
	uchar	*data;		/* read buffer */
};

struct Kconn
{
	Lock	lk;
	Ref	ref;		/* the reader's, each worker's */
	Kconn	*next;		/* on the server's list; under the server's lk */
	Kserver	*s;
	Chan	*c;		/* the connection */
	QLock	wlk;		/* serializes replies */
	u32int	msize;
	int	dead;		/* the connection is ending; under lk */

	Proc	*reader;	/* under lk; nil once it's leaving */
	Rendez	rr;		/* the reader waits here while the queue is full */
	Kworker	*workers;
	Kworker	*idle;
	int	nworker;
	Kreq	*qhead, **qtail;
	int	nqueue;

	Kfid	*fids[Nfidhash];
	int	nfid;

	char	*aname;	/* the attach name the host fixed, or nil */
};

/* Where attaches get their namespace (design/epoch-0/kernel-serve.md, Namespaces). */
typedef struct Ksource Ksource;
struct Ksource
{
	Kns	*(*lookup)(Kserver*, char *aname);
};

struct Kserver
{
	Lock	lk;
	Kconn	*conns;
	int	nconn;
	int	closing;
	int	readonly;
	Kns	*ns;		/* the plan's namespace */
	Ksource	*src;
	Kns	*(*named)(char*);	/* a named source's lookup */
	void	*hp;		/* the starter's record, for the workers' */
	uintptr	locals[4];
	char	user[KNAMELEN];
	void	(*ended)(void*);
	void	*arg;
	Rendez	r;
};

static char Enofid[] = "unknown fid";
static char Efidinuse[] = "fid in use";
static char Etoomanyfids[] = "too many fids";
static char Eopen[] = "fid already open";
static char Enotopen[] = "fid not open";
static char Ebadmsg[] = "unexpected 9P message";
static char Enoauth[] = "kserve: authentication not required";
static char Ereadonly[] = "file system read only";	/* exportfs -R's */

static void	kconnput(Kconn*);

/* The source with only the plan's namespace: every attach gets it. */
static Kns*
planlookup(Kserver *s, char *aname)
{
	USED(aname);
	incref(&s->ns->ref);
	return s->ns;
}

static Ksource plansource = { planlookup };

/* Named namespaces (namespace-kernel): the attach name picks one. */
static Kns*
namedlookup(Kserver *s, char *aname)
{
	return s->named(aname);
}

static Ksource namedsource = { namedlookup };

static void
nsput(Kns *ns)
{
	if(ns == nil || decref(&ns->ref) != 0)
		return;
	closepgrp(ns->pg);
	cclose(ns->slash);
	if(ns->put != nil)
		ns->put(ns->arg);
	free(ns);
}

/*
 * The calling kproc becomes one of the server's: its machine, user,
 * plan and pages, no fds, and the server's namespace.
 */
static void
kpinit(Kserver *s, char *text)
{
	Fgrp *f;

	h9_kern_locals(0, s->locals);
	h9_kprocshare(s->hp, text);
	strecpy(up->user, up->user+sizeof up->user, s->user);
	f = up->fgrp;
	up->fgrp = dupfgrp(nil);
	if(f != nil)
		closefgrp(f);
}

/* Runs the calling worker in ns, if it isn't already. */
static void
usens(Kns *ns)
{
	Pgrp *pg;
	Chan *c;

	if(up->pgrp != ns->pg){
		pg = up->pgrp;
		incref(&ns->pg->ref);
		up->pgrp = ns->pg;
		if(pg != nil)
			closepgrp(pg);
	}
	if(up->slash != ns->slash){
		c = up->slash;
		incref(&ns->slash->ref);
		up->slash = ns->slash;
		if(c != nil)
			cclose(c);
		c = up->dot;
		incref(&ns->slash->ref);
		up->dot = ns->slash;
		if(c != nil)
			cclose(c);
	}
}

/* Leaves the server's state, before pexit. */
static void
kpexit(void)
{
	h9_kprocunshare();
	if(up->pgrp != nil){
		closepgrp(up->pgrp);
		up->pgrp = nil;
	}
	if(up->fgrp != nil){
		closefgrp(up->fgrp);
		up->fgrp = nil;
	}
	pexit("", 0);
}

/* Fids. The table is under the connection's lk. */

static Kfid**
fidslot(Kconn *k, u32int fid)
{
	Kfid **l;

	for(l = &k->fids[fid%Nfidhash]; *l != nil; l = &(*l)->next)
		if((*l)->fid == fid)
			break;
	return l;
}

/* The fid, referenced, or an error. */
static Kfid*
fidget(Kconn *k, u32int fid)
{
	Kfid *f;

	lock(&k->lk);
	f = *fidslot(k, fid);
	if(f != nil)
		f->ref++;
	unlock(&k->lk);
	if(f == nil)
		error(Enofid);
	return f;
}

static void
fidput(Kconn *k, Kfid *f)
{
	int last;

	lock(&k->lk);
	last = --f->ref == 0;
	unlock(&k->lk);
	if(!last)
		return;
	if(f->c != nil)
		cclose(f->c);
	if(f->wc != nil)
		cclose(f->wc);
	nsput(f->ns);
	free(f);
}

/* Adds a fid for c in ns, taking c's reference. */
static void
fidnew(Kconn *k, u32int fid, Chan *c, Kns *ns)
{
	Kfid *f, **l;

	f = mallocz(sizeof *f, 1);
	if(f == nil){
		cclose(c);
		error(Enomem);
	}
	f->fid = fid;
	f->c = c;
	f->ref = 1;
	incref(&ns->ref);
	f->ns = ns;
	lock(&k->lk);
	l = fidslot(k, fid);
	if(*l != nil || k->nfid >= Maxfid){
		unlock(&k->lk);
		f->ref = 0;
		cclose(c);
		nsput(ns);
		free(f);
		error(*l != nil ? Efidinuse : Etoomanyfids);
	}
	*l = f;
	k->nfid++;
	unlock(&k->lk);
}

/* Takes the fid out of the table; the caller's reference keeps it. */
static void
fiddel(Kconn *k, Kfid *f)
{
	Kfid **l;
	int had;

	lock(&k->lk);
	l = fidslot(k, f->fid);
	had = *l == f;
	if(had){
		*l = f->next;
		k->nfid--;
	}
	unlock(&k->lk);
	if(had)
		fidput(k, f);
}

/* The fid's channel, referenced. */
static Chan*
fidchan(Kconn *k, Kfid *f)
{
	Chan *c;

	lock(&k->lk);
	c = f->c;
	incref(&c->ref);
	unlock(&k->lk);
	return c;
}

/*
 * The channel a walk from the fid starts at, referenced: its own, or
 * once it's open, the one it was walked to. 9P2000 doesn't walk an open
 * fid, but 9P2000.L does (dotl's translator passes such walks on), and
 * exportfs allowed it.
 */
static Chan*
fidwalkchan(Kconn *k, Kfid *f)
{
	Chan *c;

	lock(&k->lk);
	c = f->open ? f->wc : f->c;
	if(c != nil)
		incref(&c->ref);
	unlock(&k->lk);
	if(c == nil)
		error(Eopen);
	return c;
}

/* Replaces the fid's channel with c, and its walked one with wc, taking their references. */
static void
fidset(Kconn *k, Kfid *f, Chan *c, Chan *wc, int open, int mode)
{
	Chan *o, *ow;

	lock(&k->lk);
	o = f->c;
	ow = f->wc;
	f->c = c;
	f->wc = wc;
	f->open = open;
	f->mode = mode;
	unlock(&k->lk);
	cclose(o);
	if(ow != nil)
		cclose(ow);
}

/*
 * The channel a stat or open of c sees: what's mounted on c, with c's
 * name, as namec's domount gives it, or c. Referenced; with mp, the
 * mount's head too, or nil.
 */
static Chan*
crossmount(Chan *c, Mhead **mp)
{
	Chan *nc;
	Mhead *m;

	nc = nil;
	m = nil;
	if(mp != nil)
		*mp = nil;
	if(!findmount(&nc, &m, c->type, c->dev, c->qid)){
		incref(&c->ref);
		return c;
	}
	if(waserror()){
		cclose(nc);
		putmhead(m);
		nexterror();
	}
	nc = cunique(nc);
	poperror();
	pathclose(nc->path);
	nc->path = c->path;
	incref(&c->path->ref);
	nc->ismtpt = 1;
	if(mp != nil)
		*mp = m;
	else
		putmhead(m);
	return nc;
}

/* The qid a stat of c gives. */
static Qid
statqid(Chan *c)
{
	Chan *nc;
	Mhead *m;
	Qid q;

	nc = nil;
	m = nil;
	if(!findmount(&nc, &m, c->type, c->dev, c->qid))
		return c->qid;
	q = nc->qid;
	cclose(nc);
	putmhead(m);
	return q;
}

static int
writemode(int mode)
{
	return (mode&3) == OWRITE || (mode&3) == ORDWR || (mode&(OTRUNC|ORCLOSE)) != 0;
}

static void
checkname(char *name)
{
	if(name[0] == '\0' || strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
		error(Ebadarg);
	validname(name, 0);
}

/* The requests. Each runs under waserror; an error is the Rerror. */

static void
rattach(Kconn *k, Fcall *t, Fcall *r)
{
	Kns *ns;
	Chan *c;

	if(t->afid != NOFID)
		error(Enoauth);
	/* A connection the host gave an attach name attaches only to that. */
	if(k->aname != nil){
		if(t->aname[0] != '\0' && strcmp(t->aname, k->aname) != 0)
			error("no such namespace");
		ns = k->s->src->lookup(k->s, k->aname);
	} else
		ns = k->s->src->lookup(k->s, t->aname);
	if(ns == nil)
		error("no such namespace");
	if(waserror()){
		nsput(ns);
		nexterror();
	}
	usens(ns);
	c = cclone(ns->slash);
	r->qid = statqid(c);
	fidnew(k, t->fid, c, ns);
	poperror();
	nsput(ns);
}

static void
rwalk(Kconn *k, Fcall *t, Fcall *r)
{
	Kfid *f;
	Chan *c;
	char *name;
	int i;

	if(t->nwname > MAXWELEM)
		error(Etoolong);
	f = fidget(k, t->fid);
	if(waserror()){
		fidput(k, f);
		nexterror();
	}
	if(t->newfid != t->fid){
		lock(&k->lk);
		i = *fidslot(k, t->newfid) != nil;
		unlock(&k->lk);
		if(i)
			error(Efidinuse);
	}
	if(f->open && t->newfid == t->fid)
		error(Eopen);
	usens(f->ns);
	c = fidwalkchan(k, f);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	r->nwqid = 0;
	for(i = 0; i < t->nwname; i++){
		name = t->wname[i];
		if(strcmp(name, ".") == 0){
			r->wqid[i] = statqid(c);
			r->nwqid++;
			continue;
		}
		if(strcmp(name, "..") != 0 && (name[0] == '\0' || strchr(name, '/') != nil)){
			if(i == 0)
				error(Enonexist);
			break;
		}
		if(walk(&c, &name, 1, 0, nil) < 0){
			if(i == 0)
				error(up->errstr);
			break;
		}
		r->wqid[i] = statqid(c);
		r->nwqid++;
	}
	poperror();
	if(r->nwqid < t->nwname)
		cclose(c);
	else if(t->newfid == t->fid)
		fidset(k, f, c, nil, 0, 0);
	else
		fidnew(k, t->newfid, c, f->ns);
	poperror();
	fidput(k, f);
}

static void
ropen(Kconn *k, Fcall *t, Fcall *r)
{
	Kfid *f;
	Chan *c, *wc;
	Mhead *m, *um;
	int mode;

	mode = t->mode;
	openmode(mode);
	if(k->s->readonly && writemode(mode))
		error(Ereadonly);
	f = fidget(k, t->fid);
	if(waserror()){
		fidput(k, f);
		nexterror();
	}
	if(f->open)
		error(Eopen);
	usens(f->ns);
	wc = fidchan(k, f);
	if(waserror()){
		cclose(wc);
		nexterror();
	}
	c = crossmount(wc, &m);
	poperror();
	if(waserror()){
		cclose(wc);
		nexterror();
	}
	/* As namec's Aopen: our own copy, with a union's head kept for reads. */
	if(waserror()){
		cclose(c);
		putmhead(m);
		nexterror();
	}
	c = cunique(c);
	if(m != nil){
		um = m;
		rlock(&um->lock);
		if(um->mount != nil && um->mount->next != nil){
			c->umh = um;
			m = nil;
		}
		runlock(&um->lock);
	}
	poperror();
	putmhead(m);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	c = devtab[c->type]->open(c, mode&~OCEXEC);
	if(mode & ORCLOSE)
		c->flag |= CRCLOSE;
	poperror();
	poperror();
	r->qid = c->qid;
	r->iounit = c->iounit;
	if(r->iounit == 0 || r->iounit > k->msize-IOHDRSZ)
		r->iounit = k->msize-IOHDRSZ;
	fidset(k, f, c, wc, 1, mode);
	poperror();
	fidput(k, f);
}

static void
rcreate(Kconn *k, Fcall *t, Fcall *r)
{
	Kfid *f;
	Chan *c, *cnew, *wc;
	char *name;
	Mhead *m;
	int mode;

	mode = t->mode;
	openmode(mode);
	if(k->s->readonly)
		error(Ereadonly);
	checkname(t->name);
	f = fidget(k, t->fid);
	if(waserror()){
		fidput(k, f);
		nexterror();
	}
	if(f->open)
		error(Eopen);
	usens(f->ns);
	c = fidchan(k, f);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	if((c->qid.type & QTDIR) == 0)
		error(Enotdir);
	/* As namec's Acreate: in a union, its MCREATE member. */
	m = nil;
	cnew = nil;
	if(waserror()){
		putmhead(m);
		if(cnew != nil)
			cclose(cnew);
		nexterror();
	}
	if(findmount(&cnew, &m, c->type, c->dev, c->qid))
		cnew = createdir(cnew, m);
	else{
		cnew = c;
		incref(&cnew->ref);
	}
	cnew = cunique(cnew);
	pathclose(cnew->path);
	cnew->path = c->path;
	incref(&cnew->path->ref);
	cnew = devtab[cnew->type]->create(cnew, t->name, mode&~(OEXCL|OCEXEC), t->perm);
	if(mode & ORCLOSE)
		cnew->flag |= CRCLOSE;
	poperror();
	putmhead(m);
	poperror();
	/* The new file, unopened, for walks from the fid (fidwalkchan). */
	wc = cclone(c);
	name = t->name;
	if(walk(&wc, &name, 1, 0, nil) < 0){
		cclose(wc);
		wc = nil;
	}
	cclose(c);
	/* Its name, for a stat: the walked file's, when the walk found it. */
	if(wc != nil){
		pathclose(cnew->path);
		cnew->path = wc->path;
		incref(&wc->path->ref);
	}
	r->qid = cnew->qid;
	r->iounit = cnew->iounit;
	if(r->iounit == 0 || r->iounit > k->msize-IOHDRSZ)
		r->iounit = k->msize-IOHDRSZ;
	fidset(k, f, cnew, wc, 1, mode);
	poperror();
	fidput(k, f);
}

static void
rread(Kconn *k, Kworker *w, Fcall *t, Fcall *r)
{
	Kfid *f;
	Chan *c;
	long n;
	vlong off;

	f = fidget(k, t->fid);
	if(waserror()){
		fidput(k, f);
		nexterror();
	}
	if(!f->open)
		error(Enotopen);
	if((f->mode&3) == OWRITE)
		error(Eperm);
	usens(f->ns);
	n = t->count;
	if(n > k->msize-IOHDRSZ)
		n = k->msize-IOHDRSZ;
	off = t->offset;
	if(off < 0)
		error(Enegoff);
	c = fidchan(k, f);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	if(c->qid.type & QTDIR)
		n = h9_chanread(c, w->data, n, &off);
	else
		n = devtab[c->type]->read(c, w->data, n, off);
	poperror();
	cclose(c);
	r->count = n;
	r->data = (char*)w->data;
	poperror();
	fidput(k, f);
}

static void
rwrite(Kconn *k, Fcall *t, Fcall *r)
{
	Kfid *f;
	Chan *c;

	f = fidget(k, t->fid);
	if(waserror()){
		fidput(k, f);
		nexterror();
	}
	if(!f->open)
		error(Enotopen);
	if((f->mode&3) != OWRITE && (f->mode&3) != ORDWR)
		error(Eperm);
	if(t->offset < 0)
		error(Enegoff);
	usens(f->ns);
	c = fidchan(k, f);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	if(c->qid.type & QTDIR)
		error(Eisdir);
	r->count = devtab[c->type]->write(c, t->data, t->count, t->offset);
	poperror();
	cclose(c);
	poperror();
	fidput(k, f);
}

static void
rclunk(Kconn *k, Fcall *t)
{
	Kfid *f;

	f = fidget(k, t->fid);
	fiddel(k, f);
	/* The last reference closes the channel, removing it under ORCLOSE. */
	if(!waserror()){
		usens(f->ns);
		fidput(k, f);
		poperror();
	}
}

static void
rremove(Kconn *k, Fcall *t)
{
	Kfid *f;
	Chan *c, *wc;

	f = fidget(k, t->fid);
	/* Tremove clunks the fid, whether or not the remove succeeds. */
	fiddel(k, f);
	if(waserror()){
		fidput(k, f);
		nexterror();
	}
	if(k->s->readonly)
		error(Ereadonly);
	usens(f->ns);
	wc = fidchan(k, f);
	if(waserror()){
		cclose(wc);
		nexterror();
	}
	c = f->open ? wc : crossmount(wc, nil);
	if(c != wc){
		cclose(wc);
		wc = c;
	}
	/* As remove(2): not a mount point. */
	if(c->ismtpt)
		error(Eismtpt);
	poperror();
	c = cunique(c);
	if(waserror()){
		c->type = 0;	/* as sysremove: remove clunked it */
		cclose(c);
		nexterror();
	}
	devtab[c->type]->remove(c);
	c->type = 0;
	cclose(c);
	poperror();
	poperror();
	fidput(k, f);
}

static void
rstat(Kconn *k, Kworker *w, Fcall *t, Fcall *r)
{
	Kfid *f;
	Chan *c, *wc;
	long n;

	f = fidget(k, t->fid);
	if(waserror()){
		fidput(k, f);
		nexterror();
	}
	usens(f->ns);
	wc = fidchan(k, f);
	if(waserror()){
		cclose(wc);
		nexterror();
	}
	c = f->open ? wc : crossmount(wc, nil);
	if(c != wc)
		cclose(wc);
	poperror();
	if(waserror()){
		cclose(c);
		nexterror();
	}
	n = h9_chanstat(c, w->data, k->msize-IOHDRSZ);
	if(n <= BIT16SZ)
		error(Eshortstat);
	poperror();
	cclose(c);
	r->stat = w->data;
	r->nstat = n;
	poperror();
	fidput(k, f);
}

static void
rwstat(Kconn *k, Fcall *t)
{
	Kfid *f;
	Chan *c, *wc;
	uchar *p;
	int nlen;

	if(k->s->readonly)
		error(Ereadonly);
	if(statcheck(t->stat, t->nstat) < 0)
		error(Ebadstat);
	f = fidget(k, t->fid);
	if(waserror()){
		fidput(k, f);
		nexterror();
	}
	usens(f->ns);
	wc = fidchan(k, f);
	if(waserror()){
		cclose(wc);
		nexterror();
	}
	c = f->open ? wc : crossmount(wc, nil);
	if(c != wc)
		cclose(wc);
	poperror();
	if(waserror()){
		cclose(c);
		nexterror();
	}
	/* As wstat(2): a mount point isn't renamed. */
	p = t->stat + BIT16SZ+BIT16SZ+BIT32SZ+QIDSZ+BIT32SZ+BIT32SZ+BIT32SZ+BIT64SZ;
	nlen = GBIT16(p);
	if(c->ismtpt && nlen != 0)
		error(Eismtpt);
	devtab[c->type]->wstat(c, t->stat, t->nstat);
	poperror();
	cclose(c);
	poperror();
	fidput(k, f);
}

/* Writes one reply. Errors end the connection. */
static void
reply(Kconn *k, Fcall *r, uchar *buf)
{
	uint n;

	n = convS2M(r, buf, k->msize);
	if(n == 0){
		/* too big for msize: an error instead */
		r->type = Rerror;
		r->ename = "reply too big";
		n = convS2M(r, buf, k->msize);
	}
	qlock(&k->wlk);
	if(!k->dead && !waserror()){
		devtab[k->c->type]->write(k->c, buf, n, 0);
		poperror();
	}
	qunlock(&k->wlk);
}

static void
rflushed(Kconn *k, Kreq *q, uchar *buf)
{
	Fcall r;
	int i;

	for(i = 0; i < q->nftag; i++){
		memset(&r, 0, sizeof r);
		r.type = Rflush;
		r.tag = q->ftag[i];
		reply(k, &r, buf);
	}
}

/* Runs a request on worker w and replies. */
static void
run(Kconn *k, Kworker *w, Kreq *q)
{
	Fcall *t, r;
	char ebuf[ERRMAX];

	t = &q->f;
	memset(&r, 0, sizeof r);
	r.type = t->type+1;
	r.tag = t->tag;
	r.fid = t->fid;
	if(waserror()){
		kstrcpy(ebuf, up->errstr, sizeof ebuf);
		memset(&r, 0, sizeof r);
		r.type = Rerror;
		r.tag = t->tag;
		r.ename = ebuf;
	}else{
		switch(t->type){
		case Tattach:	rattach(k, t, &r); break;
		case Twalk:	rwalk(k, t, &r); break;
		case Topen:	ropen(k, t, &r); break;
		case Tcreate:	rcreate(k, t, &r); break;
		case Tread:	rread(k, w, t, &r); break;
		case Twrite:	rwrite(k, t, &r); break;
		case Tclunk:	rclunk(k, t); break;
		case Tremove:	rremove(k, t); break;
		case Tstat:	rstat(k, w, t, &r); break;
		case Twstat:	rwstat(k, t); break;
		default:	error(Ebadmsg);
		}
		poperror();
	}
	/*
	 * Out of reach of a Tflush's interrupt before the reply goes, but
	 * still found by one, whose Rflush then follows the reply.
	 */
	lock(&k->lk);
	q->done = 1;
	unlock(&k->lk);
	up->notepending = 0;
	reply(k, &r, w->out);
	lock(&k->lk);
	w->cur = nil;
	unlock(&k->lk);
	rflushed(k, q, w->out);
}

static void
freereq(Kreq *q)
{
	if(q == nil)
		return;
	free(q->buf);
	free(q);
}

static int
haswork(void *a)
{
	Kworker *w;

	w = a;
	return w->req != nil || w->k->dead;
}

/* Takes the next request for w, marking it running, or nil once dead. */
static Kreq*
nextreq(Kconn *k, Kworker *w)
{
	Kreq *q;

	for(;;){
		lock(&k->lk);
		q = w->req;
		w->req = nil;
		if(q == nil && (q = k->qhead) != nil){
			k->qhead = q->next;
			if(k->qhead == nil)
				k->qtail = &k->qhead;
			k->nqueue--;
			wakeup(&k->rr);
		}
		if(q != nil){
			w->cur = q;
			up->notepending = 0;
			unlock(&k->lk);
			return q;
		}
		if(k->dead){
			unlock(&k->lk);
			return nil;
		}
		w->inext = k->idle;
		k->idle = w;
		unlock(&k->lk);
		if(!waserror()){
			sleep(&w->r, haswork, w);
			poperror();
		}
		up->notepending = 0;
		/* A wake for shutdown leaves it on the idle list; take it off. */
		lock(&k->lk);
		{
			Kworker **l;

			for(l = &k->idle; *l != nil; l = &(*l)->inext)
				if(*l == w){
					*l = w->inext;
					break;
				}
		}
		unlock(&k->lk);
	}
}

static void
worker(void *a)
{
	Kworker *w, **l;
	Kconn *k;
	Kreq *q;

	w = a;
	k = w->k;
	kpinit(k->s, "kserve");
	lock(&k->lk);
	w->p = up;
	unlock(&k->lk);
	while((q = nextreq(k, w)) != nil){
		run(k, w, q);
		freereq(q);
	}
	lock(&k->lk);
	w->p = nil;
	for(l = &k->workers; *l != nil; l = &(*l)->next)
		if(*l == w){
			*l = w->next;
			break;
		}
	k->nworker--;
	unlock(&k->lk);
	free(w->out);
	free(w->data);
	free(w);
	kconnput(k);
	kpexit();
}

/* Hands q to a worker, or queues it. Called with k->lk held. */
static void
dispatch(Kconn *k, Kreq *q)
{
	Kworker *w;

	if((w = k->idle) != nil){
		k->idle = w->inext;
		w->req = q;
		unlock(&k->lk);
		wakeup(&w->r);
		lock(&k->lk);
		return;
	}
	if(k->nworker < Nworker){
		w = mallocz(sizeof *w, 1);
		if(w != nil){
			w->out = malloc(k->msize);
			w->data = malloc(k->msize);
		}
		if(w != nil && w->out != nil && w->data != nil){
			w->k = k;
			w->req = q;
			w->next = k->workers;
			k->workers = w;
			k->nworker++;
			incref(&k->ref);
			unlock(&k->lk);
			kproc("kserve", worker, w);
			lock(&k->lk);
			return;
		}
		if(w != nil){
			free(w->out);
			free(w->data);
			free(w);
		}
	}
	q->next = nil;
	*k->qtail = q;
	k->qtail = &q->next;
	k->nqueue++;
}

/*
 * Tflush, on the reader: a queued request is dropped and answered at
 * once; a running one is interrupted and answered after its reply; an
 * unknown one (already answered) at once.
 */
static void
flush(Kconn *k, Fcall *t, uchar *buf)
{
	Kreq **l, *q, *wq;
	Kworker *w;
	Fcall r;

	lock(&k->lk);
	for(l = &k->qhead; (q = *l) != nil; l = &q->next)
		if(q->f.tag == t->oldtag){
			*l = q->next;
			if(k->qtail == &q->next)
				k->qtail = l;
			k->nqueue--;
			break;
		}
	if(q == nil)
		for(w = k->workers; w != nil; w = w->next){
			wq = w->cur != nil ? w->cur : w->req;
			if(wq != nil && wq->f.tag == t->oldtag && wq->nftag < nelem(wq->ftag)){
				wq->ftag[wq->nftag++] = t->tag;
				if(w->cur == wq && !wq->done && !wq->flushed && w->p != nil){
					wq->flushed = 1;
					procinterrupt(w->p);
				}
				unlock(&k->lk);
				return;
			}
		}
	unlock(&k->lk);
	if(q != nil)
		freereq(q);
	memset(&r, 0, sizeof r);
	r.type = Rflush;
	r.tag = t->tag;
	reply(k, &r, buf);
}

/* Clunks every fid, for Tversion and the end of the connection. */
static void
clunkall(Kconn *k)
{
	Kfid *f;
	int i;

	for(i = 0; i < Nfidhash; i++){
		for(;;){
			lock(&k->lk);
			f = k->fids[i];
			if(f != nil){
				k->fids[i] = f->next;
				k->nfid--;
			}
			unlock(&k->lk);
			if(f == nil)
				break;
			if(!waserror()){
				usens(f->ns);
				fidput(k, f);
				poperror();
			}
		}
	}
}

static void
version(Kconn *k, Fcall *t, uchar *buf)
{
	Fcall r;

	clunkall(k);
	memset(&r, 0, sizeof r);
	r.type = Rversion;
	r.tag = t->tag;
	r.msize = t->msize;
	if(r.msize > Maxmsg)
		r.msize = Maxmsg;
	if(r.msize < 256)
		r.msize = 256;
	r.version = strncmp(t->version, "9P2000", 6) == 0 ? "9P2000" : "unknown";
	/* The workers' buffers are Maxmsg; only replies shrink. */
	k->msize = r.msize;
	reply(k, &r, buf);
}

/* Reads into buf until it holds n bytes; 0 at EOF. */
static int
readn(Kconn *k, uchar *buf, long n, long *have, long cap)
{
	long m;

	while(*have < n){
		m = devtab[k->c->type]->read(k->c, buf+*have, cap-*have, 0);
		if(m <= 0)
			return 0;
		*have += m;
	}
	return 1;
}

static int
fullqueue(void *a)
{
	Kconn *k;

	k = a;
	return k->nqueue < Maxqueue || k->dead;
}

/* Ends the connection: no more replies, and every worker interrupted. */
static void
hangup(Kconn *k)
{
	Kworker *w;

	lock(&k->lk);
	k->dead = 1;
	for(w = k->workers; w != nil; w = w->next){
		if(w->p != nil)
			procinterrupt(w->p);
		wakeup(&w->r);
	}
	if(k->reader != nil && k->reader != up)
		procinterrupt(k->reader);
	unlock(&k->lk);
}

static void
reader(void *a)
{
	Kconn *k;
	Kreq *q;
	uchar *buf, *rbuf;
	long have, size;
	Fcall t;

	k = a;
	kpinit(k->s, "kserve");
	lock(&k->lk);
	k->reader = up;
	unlock(&k->lk);
	buf = smalloc(2*Maxmsg);
	rbuf = smalloc(Maxmsg);
	have = 0;
	for(;;){
		if(waserror()){
			/* A stray interrupt reads on; a hangup or a closing server ends it. */
			if(strcmp(up->errstr, Eintr) == 0 && !k->dead && !k->s->closing){
				up->notepending = 0;
				continue;
			}
			break;
		}
		if(k->dead || !readn(k, buf, BIT32SZ, &have, 2*Maxmsg)){
			poperror();
			break;
		}
		size = GBIT32(buf);
		if(size < BIT32SZ+BIT8SZ+BIT16SZ || size > Maxmsg || !readn(k, buf, size, &have, 2*Maxmsg)){
			poperror();
			break;
		}
		/*
		 * Parsed in a copy of its own, since convM2S rewrites the strings
		 * in place and the Fcall points into it.
		 */
		q = mallocz(sizeof *q, 1);
		if(q != nil)
			q->buf = malloc(size);
		if(q == nil || q->buf == nil){
			freereq(q);
			error(Enomem);
		}
		memmove(q->buf, buf, size);
		have -= size;
		memmove(buf, buf+size, have);
		if(convM2S(q->buf, size, &q->f) != size){
			freereq(q);
			poperror();
			break;
		}
		switch(q->f.type){
		case Tversion:
			version(k, &q->f, rbuf);
			freereq(q);
			break;
		case Tflush:
			flush(k, &q->f, rbuf);
			freereq(q);
			break;
		case Tauth:
			memset(&t, 0, sizeof t);
			t.type = Rerror;
			t.tag = q->f.tag;
			t.ename = Enoauth;
			freereq(q);
			reply(k, &t, rbuf);
			break;
		default:
			lock(&k->lk);
			dispatch(k, q);
			unlock(&k->lk);
			/* Backpressure: past Maxqueue waiting, read no more. */
			sleep(&k->rr, fullqueue, k);
			break;
		}
		poperror();
	}
	free(buf);
	free(rbuf);
	hangup(k);
	lock(&k->lk);
	k->reader = nil;
	unlock(&k->lk);
	kconnput(k);
	kpexit();
}

/* The connection's last reference: its fids, its channel, its slot. */
static void
kconnput(Kconn *k)
{
	Kserver *s;
	Kconn **l;
	Kreq *q;

	if(decref(&k->ref) != 0)
		return;
	while((q = k->qhead) != nil){
		k->qhead = q->next;
		freereq(q);
	}
	clunkall(k);
	cclose(k->c);
	free(k->aname);
	s = k->s;
	lock(&s->lk);
	for(l = &s->conns; *l != nil; l = &(*l)->next)
		if(*l == k){
			*l = k->next;
			break;
		}
	s->nconn--;
	unlock(&s->lk);
	free(k);
	if(s->ended != nil)
		s->ended(s->arg);
}

/*
 * Starts serving the calling process's namespace: read-only if readonly,
 * from root (a path in it, "/" for all of it), with .. stopping there.
 * ended(arg) is called as each connection ends, on a kernel thread.
 * Returns the server, or nil with the error string set.
 */
void*
h9_kserve_new(int readonly, char *root, void (*ended)(void*), void *arg)
{
	Kserver *s;
	Kns *ns;
	Chan *c;

	s = nil;
	ns = nil;
	c = nil;
	if(waserror()){
		if(c != nil)
			cclose(c);
		free(ns);
		if(s != nil)
			h9_kprocput(s->hp);
		free(s);
		return nil;
	}
	s = smalloc(sizeof *s);
	ns = smalloc(sizeof *ns);
	s->hp = h9_kprocsrc();
	if(s->hp == nil)
		error("kserve: not an h9 process");
	c = namec(root, Atodir, 0, 0);
	if(strcmp(root, "/") != 0){
		Chan *r;

		r = cclone(c);
		cclose(c);
		c = r;
		h9_fs_markroot(c, 0);
	}
	poperror();
	ns->ref.ref = 1;
	ns->pg = up->pgrp;
	incref(&ns->pg->ref);
	ns->slash = c;
	s->ns = ns;
	s->src = &plansource;
	s->readonly = readonly;
	s->ended = ended;
	s->arg = arg;
	h9_kern_locals(1, s->locals);
	strecpy(s->user, s->user+sizeof s->user, up->user);
	return s;
}

/*
 * A Kns for a named source: pg and slash, referenced, with put(arg)
 * called when its last fid is clunked.
 */
void*
h9_kserve_kns(Pgrp *pg, Chan *slash, void (*put)(void*), void *arg)
{
	Kns *ns;

	ns = mallocz(sizeof *ns, 1);
	if(ns == nil)
		return nil;
	ns->ref.ref = 1;
	incref(&pg->ref);
	ns->pg = pg;
	incref(&slash->ref);
	ns->slash = slash;
	ns->put = put;
	ns->arg = arg;
	return ns;
}

/*
 * Starts a server of named namespaces (design/epoch-0/namespace-kernel.md,
 * Serving): each Tattach gets lookup(aname)'s Kns (h9_kserve_kns), or
 * fails with "no such namespace" for nil. Otherwise as h9_kserve_new.
 */
void*
h9_kserve_newnamed(void *(*lookup)(char*), void (*ended)(void*), void *arg)
{
	Kserver *s;

	s = mallocz(sizeof *s, 1);
	if(s == nil){
		kstrcpy(up->errstr, Enomem, ERRMAX);
		return nil;
	}
	s->hp = h9_kprocsrc();
	if(s->hp == nil){
		free(s);
		kstrcpy(up->errstr, "kserve: not an h9 process", ERRMAX);
		return nil;
	}
	s->src = &namedsource;
	s->named = (Kns*(*)(char*))lookup;
	s->ended = ended;
	s->arg = arg;
	h9_kern_locals(1, s->locals);
	strecpy(s->user, s->user+sizeof s->user, up->user);
	return s;
}

static int	kconnstart(Kserver*, int, char*);

/* Serves connection fd of the calling process. Returns 0, or -1 with the error string set. */
int
h9_kserve_conn(void *v, int fd)
{
	return kconnstart(v, fd, nil);
}

/*
 * As h9_kserve_conn, with every attach on the connection to aname
 * (design/epoch-0/namespace-kernel.md, Security): a Tattach naming another fails.
 */
int
h9_kserve_connas(void *v, int fd, char *aname)
{
	return kconnstart(v, fd, aname);
}

static int
kconnstart(Kserver *s, int fd, char *aname)
{
	Kconn *k;
	Chan *c;

	if(waserror())
		return -1;
	c = fdtochan(fd, ORDWR, 1, 1);
	k = mallocz(sizeof *k, 1);
	if(k == nil){
		cclose(c);
		error(Enomem);
	}
	if(aname != nil && (k->aname = strdup(aname)) == nil){
		free(k);
		cclose(c);
		error(Enomem);
	}
	poperror();
	k->s = s;
	k->c = c;
	k->msize = Maxmsg;
	k->qtail = &k->qhead;
	k->ref.ref = 1;	/* the reader's */
	lock(&s->lk);
	k->next = s->conns;
	s->conns = k;
	s->nconn++;
	unlock(&s->lk);
	kproc("kserve", reader, k);
	return 0;
}

/* Connections still being served. */
int
h9_kserve_nconn(void *v)
{
	Kserver *s;

	s = v;
	return s->nconn;
}

/*
 * Ends every connection and waits for them, then frees the server.
 * Called by the process that made it.
 */
void
h9_kserve_close(void *v)
{
	Kserver *s;
	Kconn *k;
	int n;

	s = v;
	s->closing = 1;
	for(;;){
		lock(&s->lk);
		n = s->nconn;
		for(k = s->conns; k != nil; k = k->next)
			hangup(k);
		unlock(&s->lk);
		if(n == 0)
			break;
		if(!waserror()){
			tsleep(&s->r, return0, nil, 20);
			poperror();
		}
		up->notepending = 0;
	}
	nsput(s->ns);
	h9_kprocput(s->hp);
	free(s);
}
