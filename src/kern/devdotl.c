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
 *			reads give N
 *	dotl/N/data	9P2000, for devmnt
 *	dotl/N/status	the dialect: negotiating, 9P2000, 9P2000.L, or
 *			Hungup and why
 *
 * A kproc per conversation reads the server connection and feeds the
 * translator, so replies are read whether or not devmnt is reading:
 * many of devmnt's requests are answered by the translator itself, and
 * one request can take several round trips. A guest reading data sleeps
 * until the translator has bytes for it, so a note interrupts it.
 *
 * The translator is called through leaves (src/dotl/kern.zig, DESIGN.md
 * seam rule 3) that take and return bytes and never raise. A QLock per
 * conversation serializes them; another keeps writes to the server in
 * the order the translator queued them.
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

/* proc.c */
extern void	h9_kprocdetach(void);

/* Implemented in Zig (src/dotl/kern.zig). */
extern void	*h9_dotl_new(void *mach, char *err);
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
	void *tr;

	lock(&cv->lk);
	if(--cv->refs > 0){
		unlock(&cv->lk);
		return;
	}
	srv = cv->srv;
	tr = cv->tr;
	cv->srv = nil;
	cv->tr = nil;
	cv->kp = nil;
	cv->inuse = 0;
	unlock(&cv->lk);
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

/* The kproc: reads the server connection into the translator. */
static void
reader(void *a)
{
	char err[ERRMAX];
	uchar *buf;
	Conv *cv;
	long n;
	int r;

	cv = a;
	h9_kprocdetach();
	buf = smalloc(Bufsize);
	for(;;){
		if(waserror()){
			lock(&cv->lk);
			r = cv->closing;
			unlock(&cv->lk);
			if(r)
				break;
			/* a stray interrupt: read on */
			if(strcmp(up->errstr, Eintr) == 0){
				up->notepending = 0;
				continue;
			}
			hangup(cv, up->errstr);
			break;
		}
		n = devtab[cv->srv->type]->read(cv->srv, buf, Bufsize, 0);
		poperror();
		if(n <= 0){
			hangup(cv, Ehungup);
			break;
		}
		trlock(cv);
		r = h9_dotl_fromserver(cv->tr, buf, n, err);
		trunlock(cv);
		if(r < 0){
			hangup(cv, err);
			break;
		}
		flushserver(cv);
		wakeup(&cv->r);
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

/* ctl's "fd N": the caller's fd N becomes the server connection. */
static void
start(Conv *cv, int fd)
{
	char err[ERRMAX];
	Proc *kp;
	Chan *c;
	void *tr;

	if(cv->started)
		error("already connected");
	c = fdtochan(fd, ORDWR, 1, 1);
	tr = h9_dotl_new(cv->mach, err);
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

	cb = parsecmd(a, n);
	if(waserror()){
		free(cb);
		nexterror();
	}
	if(cb->nf == 2 && strcmp(cb->f[0], "fd") == 0)
		start(cv, atoi(cb->f[1]));
	else
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
