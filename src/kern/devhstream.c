/*
 * #ℏ: host streams (design/0021-websocket-9p.md). A WebSocket that h9
 * connects on the host becomes a channel devmnt can mount, and the guest
 * can open WebSockets of its own through /net/ws.
 *
 * It's devhcons's design applied to a connection: reads and writes are
 * leaf calls into Zig (src/hstream.zig, SPEC.md seam rule 3), a host
 * thread per stream reads frames and queues their payloads, and a guest
 * read sleeps here until the queue has bytes, so a note or a teardown
 * interrupts it with Eintr. Leaves never raise kernel errors: they return
 * -1 with the error in an ERRMAX buffer, and this file raises it.
 *
 * Host-made streams (a ws:// root, a namespace file's mount) aren't in
 * any tree: the namespace builder gets a channel for one from
 * h9_hstream_fd, never through an attach spec, so no path names it.
 *
 * Attached with no spec, the device serves the calling machine's
 * conversations, laid out like devip's protocol directories, which the
 * namespace builder binds after #I on /net:
 *
 *	ws/clone		opening it makes a conversation and opens its ctl
 *	ws/N/ctl		header, connect and hangup; reads give N
 *	ws/N/data		binary messages out, payload bytes in, as a stream
 *	ws/N/text		text messages, one per write and per read
 *	ws/N/remote		the URL
 *	ws/N/status		Idle, Connecting, Established [proto], Closed code reason
 *
 * Closing the last fd on a conversation's ctl, data and text hangs it up.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"

/* Implemented in Zig (src/hstream.zig). */
extern long	h9_hstream_clone(void *mach, char *err);
extern long	h9_hstream_conv(void *mach, int n);
extern int	h9_hstream_convs(void *mach, int *out, int max);
extern int	h9_hstream_convno(ulong id);
extern void	h9_hstream_incref(ulong id);
extern void	h9_hstream_decref(ulong id);
extern long	h9_hstream_ctl(ulong id, void *buf, long n, char *err);
extern int	h9_hstream_connecting(ulong id);
extern int	h9_hstream_result(ulong id, char *err);
extern void	h9_hstream_hangup(ulong id);
extern long	h9_hstream_read(ulong id, int kind, void *buf, long n, char *err);
extern int	h9_hstream_ready(ulong id, int kind);
extern long	h9_hstream_write(ulong id, int kind, void *buf, long n, char *err);
extern int	h9_hstream_info(ulong id, int what, char *buf, int n);

enum {
	Hsdc		= 0x210F,	/* ℏ */
	Maxstream	= 256,		/* src/hstream.zig's max_streams */
	Maxconv		= 32,		/* and max_convs */
	Wouldblock	= -2,
	Kdata		= 0,
	Ktext		= 1,

	Qtopdir		= 1,
	Qwsdir,
	Qclone,
	Qconvdir,
	Qctl,
	Qdata,
	Qtext,
	Qremote,
	Qstatus,
	Qhost,		/* a host-made stream's channel */
};

#define TYPE(q)		((ulong)(q).path & 0x1f)
#define CONV(q)		((int)(((ulong)(q).path >> 5) - 1))
#define QID(n, t)	((((ulong)(n)+1) << 5) | (t))
#define STREAM(c)	((ulong)(uintptr)(c)->aux)

typedef struct Hs Hs;
struct Hs
{
	Lock	lk;
	int	busy[2];	/* a reader of data or text has its turn */
	Rendez	r[2];		/* that reader, waiting for bytes */
	Rendez	cr;		/* a connect, waiting for the handshake */
};

static Hs hs[Maxstream];

static Hs*
slot(ulong id)
{
	return &hs[id % Maxstream];
}

/* Called by a stream's thread (not a Proc) when it queues or ends. */
void
h9_hstream_wake(ulong id)
{
	Hs *h;

	h = slot(id);
	wakeup(&h->r[Kdata]);
	wakeup(&h->r[Ktext]);
	wakeup(&h->cr);
}

typedef struct Want Want;
struct Want
{
	ulong	id;
	int	kind;
};

static int
readable(void *a)
{
	Want *w;

	w = a;
	return h9_hstream_ready(w->id, w->kind);
}

static int
connected(void *a)
{
	return !h9_hstream_connecting((ulong)(uintptr)a);
}

/* As devhcons's: a Rendez holds one sleeper, so readers take turns. */
static void
taketurn(Hs *h, int kind)
{
	for(;;){
		lock(&h->lk);
		if(!h->busy[kind]){
			h->busy[kind] = 1;
			unlock(&h->lk);
			return;
		}
		unlock(&h->lk);
		if(up->notepending){
			up->notepending = 0;
			error(Eintr);
		}
		osmsleep(5);
	}
}

static void
giveturn(Hs *h, int kind)
{
	lock(&h->lk);
	h->busy[kind] = 0;
	unlock(&h->lk);
}

static long
streamread(ulong id, int kind, void *va, long n)
{
	char err[ERRMAX];
	Want w;
	Hs *h;
	long r;

	h = slot(id);
	taketurn(h, kind);
	if(waserror()){
		giveturn(h, kind);
		nexterror();
	}
	w.id = id;
	w.kind = kind;
	while((r = h9_hstream_read(id, kind, va, n, err)) == Wouldblock)
		sleep(&h->r[kind], readable, &w);
	poperror();
	giveturn(h, kind);
	if(r < 0)
		error(err);
	return r;
}

static long
streamwrite(ulong id, int kind, void *va, long n)
{
	char err[ERRMAX];
	long r;

	r = h9_hstream_write(id, kind, va, n, err);
	if(r < 0)
		error(err);
	return r;
}

/*
 * Waits for stream id's connect: a note interrupts it and hangs the
 * stream up. Then raises the connect's error, if it failed.
 */
static void
waitconnect(ulong id)
{
	char err[ERRMAX];

	if(waserror()){
		h9_hstream_hangup(id);
		nexterror();
	}
	sleep(&slot(id)->cr, connected, (void*)(uintptr)id);
	poperror();
	if(h9_hstream_result(id, err) < 0)
		error(err);
}

/*
 * For the namespace builder (src/machine.zig): waits for a host-made
 * stream to connect. 0 when connected, or -1 with the error string set.
 */
int
h9_hstream_wait(ulong id)
{
	char *p;

	if(waserror()){
		p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	waitconnect(id);
	poperror();
	return 0;
}

/*
 * Makes a channel for host-made stream id and returns a new fd on it, or
 * -1 with the error string set. The channel holds the stream.
 */
int
h9_hstream_fd(ulong id)
{
	Chan *c;
	char *p;
	int fd;

	if(waserror()){
		p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	c = devattach(Hsdc, "");
	c->qid.path = Qhost;
	c->qid.type = QTFILE;
	c->aux = (void*)(uintptr)id;
	c->mode = ORDWR;
	c->flag |= COPEN;
	h9_hstream_incref(id);
	fd = newfd(c, 0);
	if(fd < 0){
		cclose(c);
		error(Enofd);
	}
	poperror();
	return fd;
}

static void*
upmach(void)
{
	return h9_uphproc()->mach;
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
	[Qctl] = 	"ctl",
	[Qdata] = 	"data",
	[Qtext] = 	"text",
	[Qremote] = "remote",
	[Qstatus] = "status",
	};
	Qid q;

	if(t < Qctl || t > Qstatus)
		return -1;
	mkqid(&q, QID(n, t), 0, QTFILE);
	devdir(c, q, names[t], 0, eve, t >= Qremote ? 0444 : 0666, dp);
	return 1;
}

static void
topdir(Chan *c, Dir *dp)
{
	Qid q;

	mkqid(&q, Qtopdir, 0, QTDIR);
	devdir(c, q, "#\xe2\x84\x8f", 0, eve, DMDIR|0555, dp);
}

static void
wsdir(Chan *c, Dir *dp)
{
	Qid q;

	mkqid(&q, Qwsdir, 0, QTDIR);
	devdir(c, q, "ws", 0, eve, DMDIR|0555, dp);
}

static int
hsgen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	int convs[Maxconv], nc;
	Qid q;

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
			wsdir(c, dp);
			return 1;
		}
		return -1;
	case Qwsdir:
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
		nc = h9_hstream_convs(upmach(), convs, Maxconv);
		if(s < nc){
			convdir(c, convs[s], dp);
			return 1;
		}
		return -1;
	case Qclone:
		mkqid(&q, Qclone, 0, QTFILE);
		devdir(c, q, "clone", 0, eve, 0666, dp);
		return 1;
	case Qconvdir:
		if(s == DEVDOTDOT){
			wsdir(c, dp);
			return 1;
		}
		return convfile(c, CONV(c->qid), Qctl + s, dp);
	case Qhost:
		mkqid(&q, Qhost, 0, QTFILE);
		devdir(c, q, "hstream", 0, eve, 0660, dp);
		return 1;
	default:
		return convfile(c, CONV(c->qid), TYPE(c->qid), dp);
	}
}

static Chan*
hsattach(char *spec)
{
	Chan *c;

	/* Host-made streams are never reached by a spec. */
	if(*spec != 0)
		error(Ebadspec);
	c = devattach(Hsdc, spec);
	mkqid(&c->qid, Qtopdir, 0, QTDIR);
	return c;
}

static Walkqid*
hswalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, hsgen);
}

static int
hsstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, hsgen);
}

/* The conversation a chan names, in the caller's machine; or an error. */
static ulong
convid(Chan *c)
{
	long id;

	id = h9_hstream_conv(upmach(), CONV(c->qid));
	if(id < 0)
		error(Ehungup);
	return id;
}

static Chan*
hsopen(Chan *c, int omode)
{
	char err[ERRMAX];
	long id;
	int n;

	switch(TYPE(c->qid)){
	case Qtopdir:
	case Qwsdir:
	case Qconvdir:
	case Qremote:
	case Qstatus:
		if((omode&3) != OREAD)
			error(Eperm);
		break;
	case Qclone:
		id = h9_hstream_clone(upmach(), err);
		if(id < 0)
			error(err);
		n = h9_hstream_convno(id);
		c->qid.path = QID(n, Qctl);
		c->aux = (void*)(uintptr)id;
		break;
	case Qctl:
	case Qdata:
	case Qtext:
		id = convid(c);
		h9_hstream_incref(id);
		c->aux = (void*)(uintptr)id;
		break;
	case Qhost:
		error(Eperm);
	}
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
hsclose(Chan *c)
{
	if((c->flag&COPEN) == 0)
		return;
	switch(TYPE(c->qid)){
	case Qctl:
	case Qdata:
	case Qtext:
	case Qhost:
		h9_hstream_decref(STREAM(c));
		break;
	}
}

static long
hsread(Chan *c, void *va, long n, vlong off)
{
	char buf[256];
	long id;

	switch(TYPE(c->qid)){
	case Qtopdir:
	case Qwsdir:
	case Qconvdir:
		return devdirread(c, va, n, nil, 0, hsgen);
	case Qctl:
		snprint(buf, sizeof buf, "%d", CONV(c->qid));
		return readstr(off, va, n, buf);
	case Qremote:
	case Qstatus:
		id = convid(c);
		buf[h9_hstream_info(id, TYPE(c->qid) == Qremote ? 0 : 1, buf, sizeof buf - 1)] = 0;
		return readstr(off, va, n, buf);
	case Qdata:
	case Qhost:
		return streamread(STREAM(c), Kdata, va, n);
	case Qtext:
		return streamread(STREAM(c), Ktext, va, n);
	}
	error(Egreg);
	return -1;
}

static long
hswrite(Chan *c, void *va, long n, vlong off)
{
	char err[ERRMAX];
	ulong id;
	long r;

	USED(off);
	switch(TYPE(c->qid)){
	case Qctl:
		id = STREAM(c);
		r = h9_hstream_ctl(id, va, n, err);
		if(r < 0)
			error(err);
		if(r == 1)
			waitconnect(id);
		return n;
	case Qdata:
	case Qhost:
		return streamwrite(STREAM(c), Kdata, va, n);
	case Qtext:
		return streamwrite(STREAM(c), Ktext, va, n);
	}
	error(Eperm);
	return -1;
}

Dev hstreamdevtab = {
	Hsdc,
	"hstream",

	devreset,
	devinit,
	devshutdown,
	hsattach,
	hswalk,
	hsstat,
	hsopen,
	devcreate,
	hsclose,
	hsread,
	devbread,
	hswrite,
	devbwrite,
	devremove,
	devwstat,
};
