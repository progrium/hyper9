/*
 * #ι: metadata indexes for 9P roots and mounts (design/mount-index.md).
 * A conversation puts the index layer (src/rootindex/layer.zig) between
 * devmnt and a server connection: devmnt mounts the conversation's data
 * file, and the layer answers walks, stats, and directory reads from
 * the index and sends the rest to the server, both ways in 9P2000.
 * h9 puts it above #ℓ's conversation for a root or a namespace-file
 * mount, so the server may speak 9P2000.L too.
 *
 * Laid out like #ℓ, but bound nowhere: only h9 makes conversations.
 *
 *	hidx/clone	opening it makes a conversation and opens its ctl
 *	hidx/N/ctl	server KEY: use the server's /.h9index, cached
 *			under KEY; index ID: use the index the machine
 *			gave as ID; then fd N: the caller's fd N is the
 *			server connection, which starts it; reads give N
 *	hidx/N/data	9P2000, for devmnt
 *	hidx/N/status	the index and what it's done: see the layer's
 *			status
 *
 * A kproc per conversation reads the server connection and feeds the
 * layer, so replies are read whether or not devmnt is reading: the
 * layer's own requests at the first attach (finding and validating the
 * index) happen while devmnt waits for its Rattach. A guest reading data
 * sleeps until the layer has bytes for it, so a note interrupts it.
 *
 * The layer is called through leaves (src/rootindex/kern.zig, SPEC.md
 * seam rule 3) that take and return bytes and never raise. A QLock per
 * conversation serializes them; another keeps writes to the server in
 * the order the layer queued them.
 *
 * The conversation ends when the last of its ctl and data is closed: the
 * kproc is interrupted, and the server connection closed.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"

/* proc.c */
extern void	h9_kprocdetach(void);

/* Implemented in Zig (src/rootindex/kern.zig). */
extern void	*h9_hidx_new(void *mach, int mode, char *arg, char *err);
extern void	h9_hidx_free(void *t);
extern int	h9_hidx_frommount(void *t, void *buf, long n, char *err);
extern int	h9_hidx_fromserver(void *t, void *buf, long n, char *err);
extern long	h9_hidx_takeserver(void *t, void *buf, long n);
extern long	h9_hidx_takemount(void *t, void *buf, long n);
extern int	h9_hidx_mountready(void *t);
extern int	h9_hidx_status(void *t, char *buf, int n);

enum {
	Hidxdc		= 0x3b9,	/* ι */
	Maxconv		= 256,
	Bufsize		= 64*1024,
	Statussize	= 4096,

	Qtopdir		= 1,
	Qhidxdir,
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
	int	ready;		/* the layer has bytes for devmnt; under tl */
	int	closing;	/* the last open is gone; under lk */
	char	err[ERRMAX];

	Chan	*srv;		/* the server connection */
	void	*tr;		/* the layer */
	Proc	*kp;		/* the reader, until it exits; under lk */
	int	kpgone;		/* the reader has exited; under lk */
	int	mode;		/* 0 none, 1 server, 2 index */
	char	*arg;		/* server's key, or index's number */

	QLock	tl;		/* the layer: see trlock */
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
			cv->mode = 0;
			cv->arg = nil;
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
 * The layer is used under tl. Unlocking notes whether it has bytes for
 * devmnt, for readable, which runs under a Rendez's spin lock and so
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
	cv->ready = h9_hidx_mountready(cv->tr);
	qunlock(&cv->tl);
}

/* Drops a reference; the last frees the conversation. */
static void
convdecref(Conv *cv)
{
	Chan *srv;
	char *arg;
	void *tr;

	lock(&cv->lk);
	if(--cv->refs > 0){
		unlock(&cv->lk);
		return;
	}
	srv = cv->srv;
	tr = cv->tr;
	arg = cv->arg;
	cv->srv = nil;
	cv->tr = nil;
	cv->kp = nil;
	cv->arg = nil;
	cv->inuse = 0;
	unlock(&cv->lk);
	free(arg);
	if(tr != nil)
		h9_hidx_free(tr);
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
 * Writes what the layer has for the server, in order. A failed write
 * hangs the conversation up.
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
		n = h9_hidx_takeserver(cv->tr, buf, Bufsize);
		trunlock(cv);
		if(n <= 0)
			break;
		devtab[cv->srv->type]->write(cv->srv, buf, n, 0);
	}
	poperror();
	qunlock(&cv->wl);
	free(buf);
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

/* The kproc: reads the server connection into the layer. */
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
			if(closing(cv))
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
		r = h9_hidx_fromserver(cv->tr, buf, n, err);
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

/*
 * Conversation n's status, for h9 itself, which reads it after #ι is
 * masked; -1 for none.
 */
int
h9_hidx_convstatus(int n, char *buf, int len)
{
	Conv *cv;
	int k;

	if(len <= 0)
		return -1;
	cv = lookup(n);
	if(cv == nil)
		return -1;
	lock(&cv->lk);
	if(!cv->started || cv->hungup || cv->closing){
		unlock(&cv->lk);
		return -1;
	}
	cv->refs++;
	unlock(&cv->lk);
	trlock(cv);
	k = h9_hidx_status(cv->tr, buf, len);
	trunlock(cv);
	convdecref(cv);
	return k;
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
	for(;;){
		sleep(&cv->r, readable, cv);
		trlock(cv);
		r = h9_hidx_takemount(cv->tr, va, n);
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
	r = h9_hidx_frommount(cv->tr, va, n, err);
	trunlock(cv);
	if(r < 0)
		error(err);
	flushserver(cv);
	/* the layer may have answered itself */
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

	tr = h9_hidx_new(cv->mach, cv->mode, cv->arg != nil ? cv->arg : "", err);
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
	kp = kproc("hidx", reader, cv);
	/* The reader may have exited already; see hidxclose. */
	lock(&cv->lk);
	if(!cv->kpgone){
		cv->kp = kp;
		if(cv->closing)
			procinterrupt(kp);
	}
	unlock(&cv->lk);
}

static void
setarg(Conv *cv, int mode, char *a, long n)
{
	char *arg;

	if(cv->started)
		error("already connected");
	while(n > 0 && (a[n-1] == '\n' || a[n-1] == ' '))
		n--;
	arg = smalloc(n+1);
	memmove(arg, a, n);
	arg[n] = 0;
	lock(&cv->lk);
	free(cv->arg);
	cv->arg = arg;
	cv->mode = mode;
	unlock(&cv->lk);
}

static void
ctlwrite(Conv *cv, char *a, long n)
{
	Cmdbuf *cb;

	/* server KEY: the key may hold spaces, so it's the rest of the line */
	if(n > 7 && strncmp(a, "server ", 7) == 0){
		setarg(cv, 1, a+7, n-7);
		return;
	}
	cb = parsecmd(a, n);
	if(waserror()){
		free(cb);
		nexterror();
	}
	if(cb->nf == 2 && strcmp(cb->f[0], "fd") == 0){
		if(cv->started)
			error("already connected");
		start(cv, fdtochan(atoi(cb->f[1]), ORDWR, 1, 1));
	}else if(cb->nf == 2 && strcmp(cb->f[0], "index") == 0){
		setarg(cv, 2, cb->f[1], strlen(cb->f[1]));
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
	devdir(c, q, "#\xce\xb9", 0, eve, DMDIR|0555, dp);
}

static void
hidxdir(Chan *c, Dir *dp)
{
	Qid q;

	mkqid(&q, Qhidxdir, 0, QTDIR);
	devdir(c, q, "hidx", 0, eve, DMDIR|0555, dp);
}

static int
hidxgen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
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
			hidxdir(c, dp);
			return 1;
		}
		return -1;
	case Qhidxdir:
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
			hidxdir(c, dp);
			return 1;
		}
		return convfile(c, CONV(c->qid), Qctl + s, dp);
	default:
		return convfile(c, CONV(c->qid), TYPE(c->qid), dp);
	}
}

static Chan*
hidxattach(char *spec)
{
	Chan *c;

	if(*spec != 0)
		error(Ebadspec);
	c = devattach(Hidxdc, spec);
	mkqid(&c->qid, Qtopdir, 0, QTDIR);
	return c;
}

static Walkqid*
hidxwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, hidxgen);
}

static int
hidxstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, hidxgen);
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
hidxopen(Chan *c, int omode)
{
	Conv *cv;

	switch(TYPE(c->qid)){
	case Qtopdir:
	case Qhidxdir:
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
hidxclose(Chan *c)
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
hidxread(Chan *c, void *va, long n, vlong off)
{
	char buf[32], *s;
	Conv *cv;
	long r;
	int k;

	switch(TYPE(c->qid)){
	case Qtopdir:
	case Qhidxdir:
	case Qconvdir:
		return devdirread(c, va, n, nil, 0, hidxgen);
	case Qctl:
		snprint(buf, sizeof buf, "%d", CONV(c->qid));
		return readstr(off, va, n, buf);
	case Qstatus:
		cv = chanconv(c);
		s = smalloc(Statussize);
		if(waserror()){
			free(s);
			nexterror();
		}
		lock(&cv->lk);
		if(cv->hungup){
			snprint(s, Statussize, "Hungup %s\n", cv->err);
			unlock(&cv->lk);
		}else if(!cv->started){
			unlock(&cv->lk);
			snprint(s, Statussize, "Idle\n");
		}else{
			unlock(&cv->lk);
			trlock(cv);
			k = h9_hidx_status(cv->tr, s, Statussize - 1);
			trunlock(cv);
			s[k] = 0;
		}
		r = readstr(off, va, n, s);
		poperror();
		free(s);
		return r;
	case Qdata:
		return dataread(&convs[CONV(c->qid)], va, n);
	}
	error(Egreg);
	return -1;
}

static long
hidxwrite(Chan *c, void *va, long n, vlong off)
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

Dev hidxdevtab = {
	Hidxdc,
	"hidx",

	devreset,
	devinit,
	devshutdown,
	hidxattach,
	hidxwalk,
	hidxstat,
	hidxopen,
	devcreate,
	hidxclose,
	hidxread,
	devbread,
	hidxwrite,
	devbwrite,
	devremove,
	devwstat,
};
