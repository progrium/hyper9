/*
 * #ℓ: 9P2000.L translation (design/0022-dotl.md). A conversation puts
 * the translator (src/dotl/client.zig) between devmnt and a server
 * connection: devmnt mounts the conversation's data file and speaks
 * 9P2000, and the translator speaks 9P2000.L to the server, or passes
 * 9P2000 through when that's what the server speaks.
 *
 * Laid out like devip's protocol directories, under /net with the
 * namespace builder's bind -a '#ℓ' /net:
 *
 *	dotl/clone	opening it makes a conversation and opens its ctl
 *	dotl/N/ctl	fd N: the caller's fd N is the server connection;
 *			dial ADDR[,ADDR...]: dial the first that answers
 *			(tcp!, or unix! for h9's own root dials), and
 *			again on a drop if the server speaks 9P2000.L.Z;
 *			version 9P2000.L: don't offer .L.Z;
 *			serve N: the server side, for a 9P2000.L client
 *			on fd N, with an exportfs on data;
 *			reads give N
 *	dotl/N/data	9P2000, for devmnt
 *	dotl/N/status	the dialect: negotiating, 9P2000, 9P2000.L,
 *			9P2000.L.Z, or Hungup and why; "reconnects N"
 *			follows once the connection has been resumed
 *
 * A kproc per conversation reads the server connection and feeds the
 * translator, so replies are read whether or not devmnt is reading:
 * many of devmnt's requests are answered by the translator itself, and
 * one request can take several round trips. A guest reading data sleeps
 * until the translator has bytes for it, so a note interrupts it.
 *
 * The translator is called through leaves (src/dotl/kern.zig, SPEC.md
 * seam rule 3) that take and return bytes and never raise. A QLock per
 * conversation serializes them; another keeps writes to the server in
 * the order the translator queued them.
 *
 * A dialed conversation reconnects: when the connection drops, or a
 * 9P2000.L.Z server answers ENOTLEADER, the reader dials the addresses
 * again, round the list, for up to 120 seconds (ZeroFS's retry horizon),
 * and the translator resumes on the new connection. It dials TCP through
 * #I with the dialer's plan, so --net and --net-allow apply as to the
 * first dial, in a namespace of its own (with the dialer's device mask),
 * since one shared with the guest's would hold its own mount.
 *
 * The conversation ends when the last of its ctl and data is closed: the
 * kproc is interrupted, and the server connection closed. A server
 * connection whose read can't be interrupted (a host fd through devlfd)
 * keeps the kproc until the server closes it.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"
#include "tsleep.h"

/* proc.c */
extern void	h9_kprocdetach(void);

/* src/kern.zig: the calling thread's sandbox plan. */
extern void	*h9_plan_get(void);
extern Chan	*h9_unixchan(char *path);
extern void	h9_plan_set(void *plan);

/* Implemented in Zig (src/dotl/kern.zig). */
extern void	*h9_dotl_new(void *mach, int mode, char *err);
extern int	h9_dotl_canreconnect(void *t);
extern int	h9_dotl_wantreconnect(void *t);
extern int	h9_dotl_reconnect(void *t, char *err);
extern void	h9_dotl_free(void *t);
extern int	h9_dotl_frommount(void *t, void *buf, long n, char *err);
extern int	h9_dotl_fromserver(void *t, void *buf, long n, char *err);
extern long	h9_dotl_takeserver(void *t, void *buf, long n);
extern long	h9_dotl_takemount(void *t, void *buf, long n);
extern int	h9_dotl_mountready(void *t);
extern int	h9_dotl_status(void *t, char *buf, int n);

enum {
	Dotldc		= 0x2113,	/* ℓ */
	Maxconv		= 256,
	Bufsize		= 64*1024,

	Qtopdir		= 1,
	Qdotldir,
	Qclone,
	Qconvdir,
	Qctl,
	Qdata,
	Qstatus,
};

#define TYPE(q)		((ulong)(q).path & 0x1f)
#define CONV(q)		((int)(((ulong)(q).path >> 5) - 1))
#define QID(n, t)	((((ulong)(n)+1) << 5) | (t))

typedef struct Conv Conv;
struct Conv
{
	Lock	lk;
	int	inuse;
	void	*mach;		/* the machine it belongs to */
	int	opens;		/* opens of ctl and data; under lk */
	int	refs;		/* opens, and the kproc; under lk */
	int	started;
	int	hungup;		/* under lk */
	int	ready;		/* the translator has bytes for devmnt; under tl */
	int	closing;	/* the last open is gone; under lk */
	char	err[ERRMAX];

	Chan	*srv;		/* the server connection */
	void	*tr;		/* the translator */
	Proc	*kp;		/* the reader, until it exits; under lk */
	int	kpgone;		/* the reader has exited; under lk */
	int	nolz;		/* ctl's version 9P2000.L */
	int	serving;	/* ctl's serve: the server side */
	char	*addrs;		/* dial's addresses, to redial */
	int	at;		/* which of them was dialed last */
	void	*plan;		/* the dialer's plan, for redials */
	Pgrp	*pg;		/* the reader's namespace, until it takes it */

	QLock	tl;		/* the translator: see trlock */
	QLock	wl;		/* writes to the server */
	QLock	rl;		/* a reader of data has its turn */
	Rendez	r;		/* that reader, waiting for bytes */
};

static Lock convlk;
static Conv convs[Maxconv];

static void*
upmach(void)
{
	return h9_uphproc()->mach;
}

/* The conversation numbered n in the caller's machine; or nil. */
static Conv*
lookup(int n)
{
	Conv *cv;

	if(n < 0 || n >= Maxconv)
		return nil;
	cv = &convs[n];
	if(!cv->inuse || cv->mach != upmach())
		return nil;
	return cv;
}

/*
 * Conversations are numbered across machines, so a number names one
 * conversation in one machine; another machine's are hidden from it.
 */
static Conv*
newconv(void)
{
	Conv *cv;
	int i;

	lock(&convlk);
	for(i = 0; i < Maxconv; i++){
		cv = &convs[i];
		lock(&cv->lk);
		if(!cv->inuse && cv->refs == 0){
			cv->inuse = 1;
			cv->mach = upmach();
			cv->opens = 1;
			cv->refs = 1;
			cv->started = 0;
			cv->hungup = 0;
			cv->ready = 0;
			cv->closing = 0;
			cv->err[0] = 0;
			cv->srv = nil;
			cv->tr = nil;
			cv->kp = nil;
			cv->kpgone = 0;
			cv->nolz = 0;
			cv->serving = 0;
			cv->addrs = nil;
			cv->plan = nil;
			cv->pg = nil;
			unlock(&cv->lk);
			unlock(&convlk);
			return cv;
		}
		unlock(&cv->lk);
	}
	unlock(&convlk);
	error("no free devices");
	return nil;
}

/*
 * The translator is used under tl. Unlocking notes whether it has bytes
 * for devmnt, for readable, which runs under a Rendez's spin lock and so
 * can't take tl itself.
 */
static void
trlock(Conv *cv)
{
	qlock(&cv->tl);
}

static void
trunlock(Conv *cv)
{
	cv->ready = h9_dotl_mountready(cv->tr);
	qunlock(&cv->tl);
}

/* Drops a reference; the last frees the conversation. */
static void
convdecref(Conv *cv)
{
	Chan *srv;
	Pgrp *pg;
	char *addrs;
	void *tr;

	lock(&cv->lk);
	if(--cv->refs > 0){
		unlock(&cv->lk);
		return;
	}
	srv = cv->srv;
	tr = cv->tr;
	addrs = cv->addrs;
	pg = cv->pg;
	cv->srv = nil;
	cv->tr = nil;
	cv->kp = nil;
	cv->addrs = nil;
	cv->pg = nil;
	cv->inuse = 0;
	unlock(&cv->lk);
	free(addrs);
	if(pg != nil)
		closepgrp(pg);
	if(tr != nil)
		h9_dotl_free(tr);
	if(srv != nil)
		cclose(srv);
}

static int
convno(Conv *cv)
{
	return cv - convs;
}

/* Marks the conversation hung up with err, and wakes its reader. */
static void
hangup(Conv *cv, char *err)
{
	lock(&cv->lk);
	if(!cv->hungup){
		cv->hungup = 1;
		strecpy(cv->err, cv->err+sizeof cv->err, err);
	}
	unlock(&cv->lk);
	wakeup(&cv->r);
}

/*
 * Writes what the translator has for the server, in order. A failed
 * write hangs the conversation up.
 */
static void
flushserver(Conv *cv)
{
	uchar *buf;
	long n;

	buf = smalloc(Bufsize);
	qlock(&cv->wl);
	if(waserror()){
		qunlock(&cv->wl);
		free(buf);
		hangup(cv, up->errstr);
		return;
	}
	for(;;){
		trlock(cv);
		n = h9_dotl_takeserver(cv->tr, buf, Bufsize);
		trunlock(cv);
		if(n <= 0)
			break;
		devtab[cv->srv->type]->write(cv->srv, buf, n, 0);
	}
	poperror();
	qunlock(&cv->wl);
	free(buf);
}

/*
 * TCP dials through #I, as dial(2) does through /net: cs translates the
 * address, and each translation is tried in turn. Raises the last error.
 */
static Chan*
dialone(char *ipport)
{
	char buf[32], cmd[160];
	Chan *ctl, *data;
	long n;

	ctl = namec("#I/tcp/clone", Aopen, ORDWR, 0);
	if(waserror()){
		cclose(ctl);
		nexterror();
	}
	n = devtab[ctl->type]->read(ctl, buf, sizeof buf - 1, 0);
	if(n <= 0)
		error(Ehungup);
	buf[n] = 0;
	while(n > 0 && (buf[n-1] == '\n' || buf[n-1] == ' '))
		buf[--n] = 0;
	snprint(cmd, sizeof cmd, "connect %s", ipport);
	devtab[ctl->type]->write(ctl, cmd, strlen(cmd), 0);
	snprint(cmd, sizeof cmd, "#I/tcp/%s/data", buf);
	data = namec(cmd, Aopen, ORDWR, 0);
	poperror();
	cclose(ctl);
	return data;
}

static Chan*
dialaddr(char *addr)
{
	char buf[256], err[ERRMAX];
	Chan *cs, *c;
	vlong off;
	char *sp;
	long n;

	/*
	 * A host unix socket, only for a dial h9 makes itself (a root's),
	 * which runs with no plan: a guest has no way to the host's sockets.
	 */
	if(strncmp(addr, "unix!", 5) == 0){
		if(h9_plan_get() != nil)
			error("dial: unix sockets are for roots");
		return h9_unixchan(addr+5);
	}
	if(strncmp(addr, "tcp!", 4) != 0 && strncmp(addr, "net!", 4) != 0)
		error("dial: only tcp addresses");
	cs = namec("#I/cs", Aopen, ORDWR, 0);
	if(waserror()){
		cclose(cs);
		nexterror();
	}
	devtab[cs->type]->write(cs, addr, strlen(addr), 0);
	strecpy(err, err+sizeof err, "dial: no address");
	c = nil;
	/* cs answers one "/net/tcp/clone ip!port" line per read */
	for(off = 0; c == nil; off += n){
		n = devtab[cs->type]->read(cs, buf, sizeof buf - 1, off);
		if(n <= 0)
			error(err);
		buf[n] = 0;
		if(n > 0 && buf[n-1] == '\n')
			buf[n-1] = 0;
		if((sp = strchr(buf, ' ')) == nil)
			continue;
		if(waserror()){
			strecpy(err, err+sizeof err, up->errstr);
			continue;
		}
		c = dialone(sp+1);
		poperror();
	}
	poperror();
	cclose(cs);
	return c;
}

/*
 * Dials the first of a comma-separated list that answers, starting at
 * address *at and going round, and sets *at to it.
 */
static Chan*
dialany(char *addrs, int *at)
{
	char err[ERRMAX], *list, *f[16];
	Chan *c;
	int i, nf;

	list = smalloc(strlen(addrs)+1);
	strcpy(list, addrs);
	if(waserror()){
		free(list);
		nexterror();
	}
	nf = getfields(list, f, nelem(f), 1, ",");
	strecpy(err, err+sizeof err, "dial: no address");
	c = nil;
	if(nf > 0)
		*at %= nf;
	for(i = 0; i < nf && c == nil; i++){
		if(waserror()){
			strecpy(err, err+sizeof err, up->errstr);
			continue;
		}
		c = dialaddr(f[(*at+i)%nf]);
		poperror();
		if(c != nil)
			*at = (*at+i)%nf;
	}
	if(c == nil)
		error(err);
	poperror();
	free(list);
	return c;
}

static int
closing(Conv *cv)
{
	int r;

	lock(&cv->lk);
	r = cv->closing;
	unlock(&cv->lk);
	return r;
}

/*
 * After a drop, dials again and resumes the translator on the new
 * connection, if the conversation was dialed and the server speaks
 * 9P2000.L.Z. Tries round the addresses for 120 seconds, a second apart,
 * starting with the one that dropped, or with the next when the server
 * said it isn't the leader (`next`). Returns 1 when resumed. Raises
 * nothing.
 */
static int
redial(Conv *cv, int next)
{
	char err[ERRMAX];
	uvlong deadline;
	Chan *c, *old;
	char *p;
	int r, n;

	if(cv->addrs == nil)
		return 0;
	trlock(cv);
	r = h9_dotl_canreconnect(cv->tr);
	trunlock(cv);
	if(!r)
		return 0;
	deadline = h9_tnow() + 120ULL*1000000000ULL;
	if(next){
		n = 1;
		for(p = cv->addrs; *p != 0; p++)
			if(*p == ',')
				n++;
		/* Back to the first, or behind one address: give it a second. */
		if(++cv->at >= n){
			cv->at = 0;
			if(waserror())
				return 0;
			tsleep(&up->sleep, return0, nil, 1000);
			poperror();
		}
	}
	for(;;){
		if(closing(cv))
			return 0;
		c = nil;
		if(!waserror()){
			c = dialany(cv->addrs, &cv->at);
			poperror();
		}
		if(c != nil)
			break;
		up->notepending = 0;
		if(h9_tnow() > deadline)
			return 0;
		if(waserror())
			return 0;
		tsleep(&up->sleep, return0, nil, 1000);
		poperror();
	}
	/* Writes to the old connection are done with. */
	qlock(&cv->wl);
	old = cv->srv;
	cv->srv = c;
	trlock(cv);
	r = h9_dotl_reconnect(cv->tr, err);
	trunlock(cv);
	qunlock(&cv->wl);
	cclose(old);
	if(r < 0)
		return 0;
	flushserver(cv);
	return 1;
}

/* The kproc: reads the server connection into the translator. */
static void
reader(void *a)
{
	char err[ERRMAX];
	uchar *buf;
	Conv *cv;
	uvlong now, firstnl, lastnl;
	long n;
	int r, want;

	cv = a;
	firstnl = lastnl = 0;
	h9_kprocdetach();
	/* A dialed conversation redials in a namespace of its own. */
	lock(&cv->lk);
	if(cv->pg != nil){
		up->pgrp = cv->pg;
		cv->pg = nil;
	}
	unlock(&cv->lk);
	h9_plan_set(cv->plan);
	buf = smalloc(Bufsize);
	for(;;){
		if(waserror()){
			if(closing(cv))
				break;
			/* a stray interrupt: read on */
			if(strcmp(up->errstr, Eintr) == 0){
				up->notepending = 0;
				continue;
			}
			strecpy(err, err+sizeof err, up->errstr);
			if(redial(cv, 0))
				continue;
			hangup(cv, err);
			break;
		}
		n = devtab[cv->srv->type]->read(cv->srv, buf, Bufsize, 0);
		poperror();
		if(n <= 0){
			if(!closing(cv) && redial(cv, 0))
				continue;
			hangup(cv, Ehungup);
			break;
		}
		trlock(cv);
		r = h9_dotl_fromserver(cv->tr, buf, n, err);
		want = h9_dotl_wantreconnect(cv->tr);
		trunlock(cv);
		if(r < 0){
			hangup(cv, err);
			break;
		}
		flushserver(cv);
		wakeup(&cv->r);
		/*
		 * ENOTLEADER: drop this connection for the next address, for
		 * 120 seconds of them with no 10 second gap.
		 */
		if(!want)
			continue;
		now = h9_tnow();
		if(now > lastnl + 10ULL*1000000000ULL)
			firstnl = now;
		lastnl = now;
		if(now > firstnl + 120ULL*1000000000ULL || !redial(cv, 1)){
			hangup(cv, "server is not the leader");
			break;
		}
	}
	free(buf);
	hangup(cv, Ehungup);
	lock(&cv->lk);
	cv->kp = nil;
	cv->kpgone = 1;
	unlock(&cv->lk);
	convdecref(cv);
	pexit("", 0);
}

static int
readable(void *a)
{
	Conv *cv;

	cv = a;
	return cv->hungup || cv->ready;
}

static long
dataread(Conv *cv, void *va, long n)
{
	long r;

	qlock(&cv->rl);
	if(waserror()){
		qunlock(&cv->rl);
		nexterror();
	}
	if(!cv->started)
		error("no server connection");
	/*
	 * A wakeup doesn't mean devmnt has bytes: the reader wakes after
	 * every server reply, and most go back to the server as requests.
	 */
	for(;;){
		sleep(&cv->r, readable, cv);
		trlock(cv);
		r = h9_dotl_takemount(cv->tr, va, n);
		trunlock(cv);
		if(r > 0)
			break;
		if(cv->hungup)
			error(cv->err);
	}
	poperror();
	qunlock(&cv->rl);
	return r;
}

static long
datawrite(Conv *cv, void *va, long n)
{
	char err[ERRMAX];
	int r;

	if(!cv->started)
		error("no server connection");
	if(cv->hungup)
		error(cv->err);
	trlock(cv);
	r = h9_dotl_frommount(cv->tr, va, n, err);
	trunlock(cv);
	if(r < 0)
		error(err);
	flushserver(cv);
	/* the translator may have answered itself */
	wakeup(&cv->r);
	return n;
}

/* Starts the conversation on server connection c, which it takes. */
static void
start(Conv *cv, Chan *c)
{
	char err[ERRMAX];
	Proc *kp;
	void *tr;

	tr = h9_dotl_new(cv->mach, cv->serving ? 2 : !cv->nolz, err);
	if(tr == nil){
		cclose(c);
		error(err);
	}
	lock(&cv->lk);
	cv->srv = c;
	cv->tr = tr;
	cv->started = 1;
	cv->refs++;	/* the kproc's */
	unlock(&cv->lk);
	flushserver(cv);
	kp = kproc("dotl", reader, cv);
	/* The reader may have exited already; see dotlclose. */
	lock(&cv->lk);
	if(!cv->kpgone){
		cv->kp = kp;
		if(cv->closing)
			procinterrupt(kp);
	}
	unlock(&cv->lk);
}

static void
ctlwrite(Conv *cv, char *a, long n)
{
	Cmdbuf *cb;
	char *addrs;
	Pgrp *pg;
	Chan *c;

	cb = parsecmd(a, n);
	if(waserror()){
		free(cb);
		nexterror();
	}
	if(cb->nf == 2 && strcmp(cb->f[0], "fd") == 0){
		if(cv->started)
			error("already connected");
		start(cv, fdtochan(atoi(cb->f[1]), ORDWR, 1, 1));
	}else if(cb->nf == 2 && strcmp(cb->f[0], "serve") == 0){
		if(cv->started)
			error("already connected");
		cv->serving = 1;
		start(cv, fdtochan(atoi(cb->f[1]), ORDWR, 1, 1));
	}else if(cb->nf == 2 && strcmp(cb->f[0], "dial") == 0){
		if(cv->started)
			error("already connected");
		cv->at = 0;
		c = dialany(cb->f[1], &cv->at);
		pg = newpgrp();
		if(up->pgrp != nil)
			memmove(pg->devmask, up->pgrp->devmask, sizeof pg->devmask);
		addrs = smalloc(strlen(cb->f[1])+1);
		strcpy(addrs, cb->f[1]);
		lock(&cv->lk);
		cv->addrs = addrs;
		cv->plan = h9_plan_get();
		cv->pg = pg;
		unlock(&cv->lk);
		start(cv, c);
	}else if(cb->nf == 2 && strcmp(cb->f[0], "version") == 0){
		if(cv->started)
			error("already connected");
		if(strcmp(cb->f[1], "9P2000.L") == 0)
			cv->nolz = 1;
		else if(strcmp(cb->f[1], "9P2000.L.Z") == 0)
			cv->nolz = 0;
		else
			error("version: 9P2000.L or 9P2000.L.Z");
	}else
		error(Ebadctl);
	poperror();
	free(cb);
}

static void
convdir(Chan *c, int n, Dir *dp)
{
	Qid q;

	snprint(up->genbuf, sizeof up->genbuf, "%d", n);
	mkqid(&q, QID(n, Qconvdir), 0, QTDIR);
	devdir(c, q, up->genbuf, 0, eve, DMDIR|0555, dp);
}

static int
convfile(Chan *c, int n, int t, Dir *dp)
{
	static char *names[] = {
	[Qctl] =	"ctl",
	[Qdata] =	"data",
	[Qstatus] =	"status",
	};
	Qid q;

	if(t < Qctl || t > Qstatus)
		return -1;
	mkqid(&q, QID(n, t), 0, QTFILE);
	devdir(c, q, names[t], 0, eve, t == Qstatus ? 0444 : 0666, dp);
	return 1;
}

static void
topdir(Chan *c, Dir *dp)
{
	Qid q;

	mkqid(&q, Qtopdir, 0, QTDIR);
	devdir(c, q, "#\xe2\x84\x93", 0, eve, DMDIR|0555, dp);
}

static void
dotldir(Chan *c, Dir *dp)
{
	Qid q;

	mkqid(&q, Qdotldir, 0, QTDIR);
	devdir(c, q, "dotl", 0, eve, DMDIR|0555, dp);
}

static int
dotlgen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Qid q;
	int i;

	USED(name);
	USED(tab);
	USED(ntab);
	switch(TYPE(c->qid)){
	case Qtopdir:
		if(s == DEVDOTDOT){
			topdir(c, dp);
			return 1;
		}
		if(s == 0){
			dotldir(c, dp);
			return 1;
		}
		return -1;
	case Qdotldir:
		if(s == DEVDOTDOT){
			topdir(c, dp);
			return 1;
		}
		if(s == 0){
			mkqid(&q, Qclone, 0, QTFILE);
			devdir(c, q, "clone", 0, eve, 0666, dp);
			return 1;
		}
		s--;
		for(i = 0; i < Maxconv; i++){
			if(lookup(i) == nil)
				continue;
			if(s-- == 0){
				convdir(c, i, dp);
				return 1;
			}
		}
		return -1;
	case Qclone:
		mkqid(&q, Qclone, 0, QTFILE);
		devdir(c, q, "clone", 0, eve, 0666, dp);
		return 1;
	case Qconvdir:
		if(s == DEVDOTDOT){
			dotldir(c, dp);
			return 1;
		}
		return convfile(c, CONV(c->qid), Qctl + s, dp);
	default:
		return convfile(c, CONV(c->qid), TYPE(c->qid), dp);
	}
}

static Chan*
dotlattach(char *spec)
{
	Chan *c;

	if(*spec != 0)
		error(Ebadspec);
	c = devattach(Dotldc, spec);
	mkqid(&c->qid, Qtopdir, 0, QTDIR);
	return c;
}

static Walkqid*
dotlwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, dotlgen);
}

static int
dotlstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, dotlgen);
}

/* The conversation a chan names; or an error. */
static Conv*
chanconv(Chan *c)
{
	Conv *cv;

	cv = lookup(CONV(c->qid));
	if(cv == nil)
		error(Ehungup);
	return cv;
}

static Chan*
dotlopen(Chan *c, int omode)
{
	Conv *cv;

	switch(TYPE(c->qid)){
	case Qtopdir:
	case Qdotldir:
	case Qconvdir:
	case Qstatus:
		if((omode&3) != OREAD)
			error(Eperm);
		break;
	case Qclone:
		cv = newconv();
		c->qid.path = QID(convno(cv), Qctl);
		break;
	case Qctl:
	case Qdata:
		cv = chanconv(c);
		lock(&cv->lk);
		if(cv->closing){
			unlock(&cv->lk);
			error(Ehungup);
		}
		cv->opens++;
		cv->refs++;
		unlock(&cv->lk);
		break;
	}
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
dotlclose(Chan *c)
{
	Conv *cv;
	Proc *kp;

	if((c->flag&COPEN) == 0)
		return;
	switch(TYPE(c->qid)){
	case Qctl:
	case Qdata:
		cv = &convs[CONV(c->qid)];
		/*
		 * Interrupted under lk: the reader clears kp under lk before it
		 * exits, so kp is never a Proc that's gone.
		 */
		lock(&cv->lk);
		if(--cv->opens == 0){
			cv->closing = 1;
			cv->inuse = 0;
			if((kp = cv->kp) != nil)
				procinterrupt(kp);
		}
		unlock(&cv->lk);
		convdecref(cv);
		break;
	}
}

static long
dotlread(Chan *c, void *va, long n, vlong off)
{
	char buf[ERRMAX+32];
	Conv *cv;
	int k;

	switch(TYPE(c->qid)){
	case Qtopdir:
	case Qdotldir:
	case Qconvdir:
		return devdirread(c, va, n, nil, 0, dotlgen);
	case Qctl:
		snprint(buf, sizeof buf, "%d", CONV(c->qid));
		return readstr(off, va, n, buf);
	case Qstatus:
		cv = chanconv(c);
		lock(&cv->lk);
		if(cv->hungup){
			snprint(buf, sizeof buf, "Hungup %s\n", cv->err);
			unlock(&cv->lk);
		}else if(!cv->started){
			unlock(&cv->lk);
			snprint(buf, sizeof buf, "Idle\n");
		}else{
			unlock(&cv->lk);
			trlock(cv);
			k = h9_dotl_status(cv->tr, buf, sizeof buf - 2);
			trunlock(cv);
			buf[k++] = '\n';
			buf[k] = 0;
		}
		return readstr(off, va, n, buf);
	case Qdata:
		return dataread(&convs[CONV(c->qid)], va, n);
	}
	error(Egreg);
	return -1;
}

static long
dotlwrite(Chan *c, void *va, long n, vlong off)
{
	USED(off);
	switch(TYPE(c->qid)){
	case Qctl:
		ctlwrite(&convs[CONV(c->qid)], va, n);
		return n;
	case Qdata:
		return datawrite(&convs[CONV(c->qid)], va, n);
	}
	error(Eperm);
	return -1;
}

Dev dotldevtab = {
	Dotldc,
	"dotl",

	devreset,
	devinit,
	devshutdown,
	dotlattach,
	dotlwalk,
	dotlstat,
	dotlopen,
	devcreate,
	dotlclose,
	dotlread,
	devbread,
	dotlwrite,
	devbwrite,
	devremove,
	devwstat,
};
