/*
 * Readiness for Linux processes (design/0050-linux-net.md): h9_poll asks
 * each fd's channel whether a read or write would block, and sleeps
 * until one wouldn't or the timeout passes. Pipes and other qio queues
 * wake pollers from qio's own wakeups (h9_qwake, a hook in kern/qio.c),
 * the console from its reader thread, and host sockets from the watcher
 * in hostsock-*.c. Every wake bumps one generation number and wakes
 * every poller, which then asks its channels again; edge-triggered epoll
 * uses the generation to tell a new event from an old one.
 *
 * Also #ε, eventfd and epoll instances: an eventfd is a counter,
 * readable when it's not zero; an epoll fd is an identity for the
 * interest list, which the Linux layer keeps (src/linux/sys.zig).
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "tsleep.h"
#include "ip.h"
#include "devip.h"
#include "netcheck.h"
#include "hostsock.h"

extern Queue*	h9_pipeq(Chan*, int);		/* kern/devpipe.c */
extern int	h9_ip_sfd(Chan*, int*);		/* kern/devip.c */
extern long	h9_ip_ctl(Chan*, char*);	/* kern/devip.c */
extern int	h9_cons_poll(ulong);		/* src/kern.zig */

/* Swaps the error strings after a caught error, as proc.c's syserr does. */
static int
syserr(void)
{
	char *p;

	p = up->syserrstr;
	up->syserrstr = up->errstr;
	up->errstr = p;
	return -1;
}

enum {
	LPOLLIN = 1,
	LPOLLPRI = 2,
	LPOLLOUT = 4,
	LPOLLERR = 8,
	LPOLLHUP = 0x10,
	LPOLLNVAL = 0x20,
	LPOLLRDNORM = 0x40,
	LPOLLWRNORM = 0x100,
	LPOLLRDHUP = 0x2000,

	Epsilon = 0x3B5,	/* #ε */
};

typedef struct Poller Poller;
struct Poller
{
	Rendez	r;
	ulong	gen;
	Poller	*next;
};

static ulong pollgen;
static int npollers;
static Lock plk;
static Poller *pollers;

ulong
h9_pollgen(void)
{
	return __atomic_load_n(&pollgen, __ATOMIC_SEQ_CST);
}

/* Something may have become ready: wake every poller. */
void
h9_pollwake(void)
{
	Poller *p;

	__atomic_add_fetch(&pollgen, 1, __ATOMIC_SEQ_CST);
	if(__atomic_load_n(&npollers, __ATOMIC_SEQ_CST) == 0)
		return;
	lock(&plk);
	for(p = pollers; p != nil; p = p->next)
		wakeup(&p->r);
	unlock(&plk);
}

/* h9: called by qio after a queue changes (kern/qio.c). */
void
h9_qwake(Queue *q)
{
	USED(q);
	h9_pollwake();
}

static int
genchanged(void *a)
{
	return h9_pollgen() != ((Poller*)a)->gen;
}

/*
 * Sleeps until the generation moves past gen, ms passes (0: forever) or
 * a note arrives (an error, as for any sleep). Returns whether it was
 * the timeout.
 */
static int
pollwait(ulong gen, ulong ms)
{
	Poller w, **l;
	uvlong start;

	memset(&w, 0, sizeof w);
	w.gen = gen;
	lock(&plk);
	w.next = pollers;
	pollers = &w;
	__atomic_add_fetch(&npollers, 1, __ATOMIC_SEQ_CST);
	unlock(&plk);
	if(waserror()){
		lock(&plk);
		for(l = &pollers; *l != nil; l = &(*l)->next)
			if(*l == &w){
				*l = w.next;
				break;
			}
		__atomic_sub_fetch(&npollers, 1, __ATOMIC_SEQ_CST);
		unlock(&plk);
		nexterror();
	}
	start = h9_tnow();
	if(ms == 0)
		sleep(&w.r, genchanged, &w);
	else
		tsleep(&w.r, genchanged, &w, ms);
	poperror();
	lock(&plk);
	for(l = &pollers; *l != nil; l = &(*l)->next)
		if(*l == &w){
			*l = w.next;
			break;
		}
	__atomic_sub_fetch(&npollers, 1, __ATOMIC_SEQ_CST);
	unlock(&plk);
	return ms != 0 && !genchanged(&w) && h9_tnow() - start >= (uvlong)ms * 1000000;
}

/* #ε */
enum {
	Qedir,
	Qeventfd,
	Qeventsem,
	Qepoll,
	Qinst,	/* an open instance */
};

typedef struct Evfd Evfd;
struct Evfd
{
	Lock	lk;
	uvlong	count;
	int	sem;
	int	epoll;
};

static Dirtab evdir[] = {
	".",		{Qedir, 0, QTDIR},	0,	DMDIR|0555,
	"eventfd",	{Qeventfd},		0,	0666,
	"eventsem",	{Qeventsem},		0,	0666,
	"epoll",	{Qepoll},		0,	0666,
};

static ulong evid;

static int
evready(Chan *c, int ev)
{
	Evfd *e;
	int r;

	e = c->aux;
	if(e == nil || e->epoll)
		return 0;
	r = 0;
	lock(&e->lk);
	if(e->count > 0)
		r |= LPOLLIN;
	if(e->count < ~0ULL - 1)
		r |= LPOLLOUT;
	unlock(&e->lk);
	return r & ev;
}

static Chan*
evattach(char *spec)
{
	return devattach(Epsilon, spec);
}

static Walkqid*
evwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, evdir, nelem(evdir), devgen);
}

static int
evstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, evdir, nelem(evdir), devgen);
}

static Chan*
evopen(Chan *c, int omode)
{
	Evfd *e;
	int t;

	t = c->qid.path;
	if(t == Qedir)
		return devopen(c, omode, evdir, nelem(evdir), devgen);
	if(t != Qeventfd && t != Qeventsem && t != Qepoll)
		error(Eperm);
	e = mallocz(sizeof *e, 1);
	if(e == nil)
		error(Enomem);
	e->sem = t == Qeventsem;
	e->epoll = t == Qepoll;
	c->aux = e;
	c->qid.path = Qinst | (__atomic_add_fetch(&evid, 1, __ATOMIC_SEQ_CST) << 4);
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
evclose(Chan *c)
{
	if((c->flag & COPEN) && c->aux != nil){
		free(c->aux);
		c->aux = nil;
	}
}

static int
evhas(void *a)
{
	Evfd *e;

	e = a;
	return e->count > 0;
}

static long
evread(Chan *c, void *va, long n, vlong off)
{
	Evfd *e;
	uvlong v;
	uchar *p;
	ulong g;

	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, evdir, nelem(evdir), devgen);
	e = c->aux;
	if(e == nil || e->epoll)
		error(Eperm);
	if(n < 8)
		error(Ebadarg);
	for(;;){
		g = h9_pollgen();
		lock(&e->lk);
		if(e->count > 0){
			if(e->sem){
				v = 1;
				e->count--;
			}else{
				v = e->count;
				e->count = 0;
			}
			unlock(&e->lk);
			break;
		}
		unlock(&e->lk);
		pollwait(g, 0);
	}
	h9_pollwake();	/* a writer waiting for room */
	p = va;
	p[0] = v; p[1] = v>>8; p[2] = v>>16; p[3] = v>>24;
	p[4] = v>>32; p[5] = v>>40; p[6] = v>>48; p[7] = v>>56;
	USED(off);
	return 8;
}

static long
evwrite(Chan *c, void *va, long n, vlong off)
{
	Evfd *e;
	uvlong v;
	uchar *p;
	ulong g;

	USED(off);
	e = c->aux;
	if(e == nil || e->epoll)
		error(Eperm);
	if(n < 8)
		error(Ebadarg);
	p = va;
	v = (uvlong)p[0] | (uvlong)p[1]<<8 | (uvlong)p[2]<<16 | (uvlong)p[3]<<24 |
		(uvlong)p[4]<<32 | (uvlong)p[5]<<40 | (uvlong)p[6]<<48 | (uvlong)p[7]<<56;
	if(v == ~0ULL)
		error(Ebadarg);
	for(;;){
		g = h9_pollgen();
		lock(&e->lk);
		if(e->count + v >= e->count && e->count + v < ~0ULL){
			e->count += v;
			unlock(&e->lk);
			break;
		}
		unlock(&e->lk);
		pollwait(g, 0);
	}
	h9_pollwake();
	return 8;
}

Dev evdevtab = {
	Epsilon,
	"eventfd",

	devreset,
	devinit,
	devshutdown,
	evattach,
	evwalk,
	evstat,
	evopen,
	devcreate,
	evclose,
	evread,
	devbread,
	evwrite,
	devbwrite,
	devremove,
	devwstat,
};

/*
 * Remote conversations: a Linux socket on a /net mounted from another
 * machine, such as a host h9's served with --serve-net. Its data file
 * is devmnt's, which can't say whether a read would block, so a kproc
 * reads ahead into a ring the socket calls and readiness answer from,
 * and a non-blocking connect runs in a kproc of its own. The Linux layer
 * attaches each conversation it opens (h9_linux_rattach) and detaches
 * it when the description's last fd closes (h9_linux_rclose).
 */
enum {
	Rbufsz = 64*1024,

	RCidle = 0,	/* not connected or announced yet */
	RCconnecting,	/* a connect kproc runs */
	RCopen,		/* connected (or a bound UDP socket): the reader runs */
	RClisten,	/* announced: accept opens listen */
	RCclosed,
};

typedef struct Rconv Rconv;
struct Rconv
{
	Lock	lk;
	Rconv	*next;
	Chan	*data;	/* the fds' channel, the key; a reference of ours */
	Chan	*ctl;	/* the conversation's ctl; a reference of ours */
	int	id;	/* the Linux layer's: 1<<30 | proto<<12 | conversation */
	int	udp;
	int	state;
	int	err;	/* SO_ERROR: a Linux errno, until read */
	int	rerr;	/* the reader's error: a Linux errno */
	int	eof;
	int	refs;	/* the table's, and each kproc's */
	Proc	*rk;	/* the reader, to interrupt at close */
	Proc	*lk2;	/* the listener, to interrupt at close */
	Chan	*dir;	/* the conversation's directory, for listen */
	Chan	*call;	/* a call the listener took, for accept */
	int	lgone;	/* the listener has exited */
	Rendez	room;
	uchar	*buf;	/* the ring: UDP keeps each message as 2 bytes of length and its bytes */
	int	rp;
	int	n;
	char	cmsg[128];	/* the connect message for the connect kproc */
};

static Lock rclk;
static Rconv *rconvs;

/* A Linux errno for a kernel error string from a remote conversation. */
static int
rerrno(char *e)
{
	if(strstr(e, "refused") != nil)
		return 111;	/* ECONNREFUSED */
	if(strstr(e, "reset") != nil || strstr(e, "hungup") != nil || strstr(e, "hangup") != nil)
		return 104;	/* ECONNRESET */
	if(strstr(e, "timed out") != nil || strstr(e, "timeout") != nil)
		return 110;	/* ETIMEDOUT */
	if(strstr(e, "permission") != nil || strstr(e, "denied") != nil)
		return 13;	/* EACCES */
	if(strstr(e, "network") != nil && strstr(e, "unreachable") != nil)
		return 101;	/* ENETUNREACH */
	if(strstr(e, "unreachable") != nil || strstr(e, "no route") != nil)
		return 113;	/* EHOSTUNREACH */
	if(strstr(e, "in use") != nil)
		return 98;	/* EADDRINUSE */
	if(strstr(e, "interrupted") != nil)
		return 4;	/* EINTR */
	return 5;	/* EIO */
}

/* The Rconv for channel c, with a reference; nil if there's none. */
static Rconv*
rget(Chan *c)
{
	Rconv *r;

	lock(&rclk);
	for(r = rconvs; r != nil; r = r->next)
		if(r->data == c){
			lock(&r->lk);
			r->refs++;
			unlock(&r->lk);
			break;
		}
	unlock(&rclk);
	return r;
}

static Rconv*
rgetfd(int fd)
{
	Chan *c;
	Rconv *r;

	if(waserror())
		return nil;
	c = fdtochan(fd, -1, 0, 1);
	poperror();
	r = nil;
	if(devtab[c->type]->dc == 'M')
		r = rget(c);
	cclose(c);
	return r;
}

static void
rput(Rconv *r)
{
	int last;

	lock(&r->lk);
	last = --r->refs == 0;
	unlock(&r->lk);
	if(!last)
		return;
	if(r->ctl != nil)
		cclose(r->ctl);
	if(r->dir != nil)
		cclose(r->dir);
	if(r->call != nil)
		cclose(r->call);
	cclose(r->data);
	free(r->buf);
	free(r);
}

static int
hasroom(void *a)
{
	Rconv *r;

	r = a;
	return r->state == RCclosed || r->n + (r->udp ? 2 : 0) < Rbufsz;
}

/* The kproc: reads the conversation's data into the ring until it ends. */
static void
rreader(void *a)
{
	Rconv *r;
	uchar *tmp;
	long n, i, room;
	int err;

	r = a;
	h9_kprocdetach();
	tmp = smalloc(Rbufsz);
	err = 0;
	for(;;){
		if(waserror()){
			if(r->state != RCclosed)
				err = rerrno(up->errstr);
			break;
		}
		room = Rbufsz - (r->udp ? 2 : 0);
		lock(&r->lk);
		if(!r->udp && Rbufsz - r->n < room)
			room = Rbufsz - r->n;
		unlock(&r->lk);
		if(room <= 0)
			room = 1;
		n = devtab[r->data->type]->read(r->data, tmp, room, 0);
		poperror();
		if(n <= 0)
			break;
		/* Waits until the whole read fits. */
		while(!hasroom(r) || r->n + n + (r->udp ? 2 : 0) > Rbufsz){
			if(r->state == RCclosed)
				break;
			if(waserror())
				break;
			tsleep(&r->room, hasroom, r, 100);
			poperror();
		}
		if(r->state == RCclosed)
			break;
		lock(&r->lk);
		if(r->udp){
			r->buf[(r->rp + r->n) % Rbufsz] = n >> 8;
			r->buf[(r->rp + r->n + 1) % Rbufsz] = n;
			r->n += 2;
		}
		for(i = 0; i < n; i++)
			r->buf[(r->rp + r->n + i) % Rbufsz] = tmp[i];
		r->n += n;
		unlock(&r->lk);
		h9_pollwake();
	}
	free(tmp);
	lock(&r->lk);
	if(err != 0)
		r->rerr = err;
	r->eof = 1;
	r->rk = nil;
	unlock(&r->lk);
	h9_pollwake();
	rput(r);
	pexit("", 0);
}

static void
rstartreader(Rconv *r)
{
	Proc *kp;

	lock(&r->lk);
	r->state = RCopen;
	r->refs++;
	unlock(&r->lk);
	kp = kproc("rconv", rreader, r);
	lock(&r->lk);
	if(!r->eof)
		r->rk = kp;
	if(r->state == RCclosed && r->rk != nil)
		procinterrupt(r->rk);
	unlock(&r->lk);
}

/* Writes msg to the conversation's ctl. */
static void
rctl(Rconv *r, char *msg)
{
	if(r->ctl == nil)
		error("no ctl for a remote conversation");
	devtab[r->ctl->type]->write(r->ctl, msg, strlen(msg), 0);
}

/*
 * The conversation's directory, walked in the 9front view's /net as the
 * Linux layer opened it, for its listen file.
 */
static Chan*
rconvdir(Rconv *r)
{
	Chan *c;
	char num[16], *names[3];

	snprint(num, sizeof num, "%d", r->id & 0xfff);
	names[0] = "net";
	names[1] = r->udp ? "udp" : "tcp";
	names[2] = num;
	c = namec("#/", Atodir, 0, 0);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	if(walk(&c, names, 3, 0, nil) < 0)
		error(Enonexist);
	poperror();
	return c;
}

static int
nocall(void *a)
{
	Rconv *r;

	r = a;
	return r->state == RCclosed || r->call == nil;
}

/*
 * The kproc for a listening socket: opens listen, which waits in the
 * server until a call comes, and keeps the call for accept, one at a
 * time, so readiness can say one is waiting.
 */
static void
rlistener(void *a)
{
	Rconv *r;
	Chan *c;
	char *names[1];

	r = a;
	names[0] = "listen";
	for(;;){
		while(!nocall(r)){
			if(waserror())
				break;
			tsleep(&r->room, nocall, r, 100);
			poperror();
		}
		if(r->state == RCclosed)
			break;
		c = nil;
		if(waserror()){
			if(c != nil)
				cclose(c);
			if(r->state != RCclosed){
				lock(&r->lk);
				r->err = rerrno(up->errstr);
				unlock(&r->lk);
				h9_pollwake();
			}
			break;
		}
		c = cclone(r->dir);
		if(walk(&c, names, 1, 1, nil) < 0)
			error(Enonexist);
		c = devtab[c->type]->open(c, ORDWR);
		poperror();
		lock(&r->lk);
		if(r->state == RCclosed){
			unlock(&r->lk);
			cclose(c);
			break;
		}
		r->call = c;
		unlock(&r->lk);
		h9_pollwake();
	}
	lock(&r->lk);
	r->lk2 = nil;
	r->lgone = 1;
	unlock(&r->lk);
	rput(r);
	pexit("", 0);
}

/*
 * accept on a listening remote conversation: a new fd for the waiting
 * call's ctl, -EAGAIN if none waits yet, or -errno.
 */
int
h9_linux_raccept(int fd, int cloexec)
{
	Rconv *r;
	Chan *c;
	int nfd;

	r = rgetfd(fd);
	if(r == nil)
		return -9;	/* EBADF */
	lock(&r->lk);
	c = r->call;
	if(c == nil){
		nfd = r->state == RClisten ? -11 : -22;	/* EAGAIN, EINVAL */
		unlock(&r->lk);
		rput(r);
		return nfd;
	}
	r->call = nil;
	unlock(&r->lk);
	wakeup(&r->room);
	nfd = newfd(c, cloexec ? OCEXEC : 0);
	if(nfd < 0){
		cclose(c);
		nfd = -24;	/* EMFILE */
	}
	rput(r);
	return nfd;
}

/* The kproc for a non-blocking connect. */
static void
rconnector(void *a)
{
	Rconv *r;

	r = a;
	h9_kprocdetach();
	if(waserror()){
		lock(&r->lk);
		r->err = rerrno(up->errstr);
		if(r->state == RCconnecting)
			r->state = RCidle;
		unlock(&r->lk);
	}else{
		rctl(r, r->cmsg);
		poperror();
		if(r->state == RCconnecting)
			rstartreader(r);
	}
	h9_pollwake();
	rput(r);
	pexit("", 0);
}

/*
 * Attaches the conversation open on datafd (and ctlfd, -1 if none) to a
 * Rconv. open: it's connected already, as an accepted call is.
 */
int
h9_linux_rattach(int datafd, int ctlfd, int id, int udp, int open)
{
	Rconv *r;
	Chan *d, *c;

	if(waserror())
		return syserr();
	d = fdtochan(datafd, -1, 0, 1);
	if((r = rget(d)) != nil){
		rput(r);
		cclose(d);
		poperror();
		return 0;
	}
	c = nil;
	if(ctlfd >= 0 && !waserror()){
		c = fdtochan(ctlfd, -1, 0, 1);
		poperror();
	}
	r = mallocz(sizeof *r, 1);
	if(r != nil && (r->buf = mallocz(Rbufsz, 0)) == nil){
		free(r);
		r = nil;
	}
	if(r == nil){
		cclose(d);
		if(c != nil)
			cclose(c);
		error(Enomem);
	}
	r->data = d;
	r->ctl = c;
	r->id = id;
	r->udp = udp;
	r->refs = 1;
	lock(&rclk);
	r->next = rconvs;
	rconvs = r;
	unlock(&rclk);
	poperror();
	if(open)
		rstartreader(r);
	return 0;
}

/* The Linux layer's id for fd's remote conversation, or -1. */
int
h9_linux_rconvid(int fd)
{
	Rconv *r;
	int id;

	r = rgetfd(fd);
	if(r == nil)
		return -1;
	id = r->id;
	rput(r);
	return id;
}

/*
 * fd is closing: if it's the last of its description, hangs up its
 * remote conversation and lets it go.
 */
void
h9_linux_rclose(int fd)
{
	Chan *c;
	Rconv *r, **l;

	if(waserror())
		return;
	c = fdtochan(fd, -1, 0, 1);
	poperror();
	r = nil;
	if(devtab[c->type]->dc == 'M')
		r = rget(c);
	/* the fd's, ours, fdtochan's, and rget's doesn't count */
	if(r == nil || c->ref.ref > 3){
		if(r != nil)
			rput(r);
		cclose(c);
		return;
	}
	cclose(c);
	lock(&rclk);
	for(l = &rconvs; *l != nil; l = &(*l)->next)
		if(*l == r){
			*l = r->next;
			break;
		}
	unlock(&rclk);
	lock(&r->lk);
	r->state = RCclosed;
	unlock(&r->lk);
	/* devip on an h9 takes shutdown, and 9front's takes hangup */
	if(!waserror()){
		rctl(r, "shutdown rdwr");
		poperror();
	}else if(!waserror()){
		rctl(r, "hangup");
		poperror();
	}
	lock(&r->lk);
	if(r->rk != nil)
		procinterrupt(r->rk);
	if(r->lk2 != nil)
		procinterrupt(r->lk2);
	unlock(&r->lk);
	wakeup(&r->room);
	rput(r);	/* rget's */
	rput(r);	/* the table's */
}

/* The poll bits ready on remote conversation r. */
static int
rready(Rconv *r, int ev)
{
	int b;

	lock(&r->lk);
	switch(r->state){
	case RCidle:
		b = r->err ? LPOLLERR|LPOLLOUT : LPOLLOUT;
		break;
	case RCconnecting:
		b = 0;
		break;
	case RClisten:
		b = r->call != nil ? LPOLLIN : 0;
		if(r->err)
			b |= LPOLLERR;
		break;
	default:
		b = LPOLLOUT;
		if(r->n > 0)
			b |= LPOLLIN;
		if(r->eof && r->n == 0)
			b |= LPOLLIN | LPOLLRDHUP | (r->rerr ? LPOLLERR : LPOLLHUP);
		break;
	}
	unlock(&r->lk);
	return b & ev;
}

/* recv on remote conversation r: never waits; the Linux layer polls first. */
static long
rrecv(Rconv *r, uchar *buf, long n, int peek)
{
	long m, i, got;

	lock(&r->lk);
	if(r->n == 0){
		unlock(&r->lk);
		if(r->state == RCopen && r->eof)
			return r->rerr ? -r->rerr : 0;
		if(r->state == RCidle && !r->udp)
			return -107;	/* ENOTCONN */
		return -11;	/* EAGAIN */
	}
	if(r->udp){
		m = r->buf[r->rp] << 8 | r->buf[(r->rp + 1) % Rbufsz];
		got = m < n ? m : n;
		for(i = 0; i < got; i++)
			buf[i] = r->buf[(r->rp + 2 + i) % Rbufsz];
		if(!peek){
			r->rp = (r->rp + 2 + m) % Rbufsz;
			r->n -= 2 + m;
		}
		unlock(&r->lk);
		if(!peek)
			wakeup(&r->room);
		return m;	/* the whole message's length, for MSG_TRUNC */
	}
	got = r->n < n ? r->n : n;
	for(i = 0; i < got; i++)
		buf[i] = r->buf[(r->rp + i) % Rbufsz];
	if(!peek){
		r->rp = (r->rp + got) % Rbufsz;
		r->n -= got;
	}
	unlock(&r->lk);
	if(!peek)
		wakeup(&r->room);
	return got;
}

/* send on remote conversation r: waits for the server. */
static long
rsend(Rconv *r, void *buf, long n)
{
	long w;

	if(r->state == RCconnecting)
		return -11;	/* EAGAIN */
	if(r->state != RCopen)
		return r->udp ? -89 : -32;	/* EDESTADDRREQ, EPIPE */
	if(waserror()){
		w = rerrno(up->errstr);
		return w == 104 ? -32 : -w;	/* a reset write: EPIPE */
	}
	w = devtab[r->data->type]->write(r->data, buf, n, 0);
	poperror();
	return w;
}

/* A control message for remote conversation r, as devip's ctl takes it. */
static void
rsockctl(Rconv *r, char *msg)
{
	Proc *kp;

	if(strncmp(msg, "nbconnect ", 10) == 0){
		lock(&r->lk);
		if(r->state != RCidle){
			unlock(&r->lk);
			error("already connected");
		}
		snprint(r->cmsg, sizeof r->cmsg, "connect %s", msg+10);
		r->state = RCconnecting;
		r->err = 0;
		r->refs++;
		unlock(&r->lk);
		kproc("rconnect", rconnector, r);
		return;
	}
	rctl(r, msg);
	if(strncmp(msg, "connect ", 8) == 0){
		if(r->state == RCidle)
			rstartreader(r);
	}else if(strncmp(msg, "announce ", 9) == 0){
		if(r->udp){
			if(r->state == RCidle)
				rstartreader(r);
		}else if(r->state == RCidle){
			r->dir = rconvdir(r);
			lock(&r->lk);
			r->state = RClisten;
			r->refs++;
			unlock(&r->lk);
			kp = kproc("rlisten", rlistener, r);
			lock(&r->lk);
			if(!r->lgone)
				r->lk2 = kp;
			unlock(&r->lk);
		}
	}
}

/*
 * The poll bits ready on c now, of those in ev (plus errors and hangups,
 * which are always reported). *sfd is set to a host socket to watch
 * when none is.
 */
static int
chanready(Chan *c, int ev, int *sfd)
{
	Queue *rq, *wq;
	Rconv *rc;
	int r, dc, s, udp;

	*sfd = -1;
	dc = devtab[c->type]->dc;
	ev |= LPOLLERR | LPOLLHUP;
	switch(dc){
	case '|':
		if((c->qid.type & QTDIR) || (rq = h9_pipeq(c, 0)) == nil)
			return (LPOLLIN|LPOLLOUT) & ev;
		wq = h9_pipeq(c, 1);
		r = 0;
		if(qcanread(rq))
			r |= LPOLLIN;
		else if(qisclosed(rq))
			r |= LPOLLIN | LPOLLHUP | LPOLLRDHUP;
		if(qisclosed(wq))
			r |= LPOLLERR;
		else if(!qfull(wq))
			r |= LPOLLOUT;
		return r & ev;
	case 'y':
		r = LPOLLOUT;
		/* Asking starts a host read, as a read would; its input wakes us. */
		if(c->qid.path != 1 /* Qcons */ || (ev & LPOLLIN) == 0 || h9_cons_poll(c->dev))
			r |= LPOLLIN;
		return r & ev;
	case 'I':
		s = h9_ip_sfd(c, &udp);
		if(s < 0)
			return (LPOLLIN|LPOLLOUT) & ev;	/* not a conversation, or no socket yet */
		r = h9so_ready(s, ev);
		if(r == 0)
			*sfd = s;
		return r;
	case Epsilon:
		return evready(c, ev);
	case 'M':
		if((rc = rget(c)) != nil){
			r = rready(rc, ev);
			rput(rc);
			return r;
		}
		break;
	}
	/* Files, devmnt and the rest: ready, so a read blocks as it would. */
	return (LPOLLIN|LPOLLOUT) & ev;
}

/* Linux's struct pollfd. */
typedef struct Lpollfd Lpollfd;
struct Lpollfd
{
	int	fd;
	short	events;
	short	revents;
};

/*
 * Fills in revents for each of fds and returns how many are ready,
 * sleeping until one is when none is, for up to ms (-1: forever, 0:
 * don't sleep). *gen (if not nil) gets the generation the answer is
 * for. With once, it returns 0 after the first wake instead of asking
 * again, for epoll's edge-triggered fds. -1 with the error string set
 * when a note interrupts it.
 */
int
h9_poll(Lpollfd *fds, int n, long ms, ulong *gen, int once)
{
	Chan *c;
	int i, ready, sfd;
	ulong g;
	uvlong deadline, now;
	char owner;

	deadline = ms > 0 ? h9_tnow() + (uvlong)ms * 1000000 : 0;
	if(waserror()){
		h9so_unwatch(&owner);
		return syserr();
	}
	for(;;){
		g = h9_pollgen();
		ready = 0;
		for(i = 0; i < n; i++){
			fds[i].revents = 0;
			if(fds[i].fd < 0)
				continue;
			if(waserror()){
				fds[i].revents = LPOLLNVAL;
				ready++;
				continue;
			}
			c = fdtochan(fds[i].fd, -1, 0, 1);
			poperror();
			fds[i].revents = chanready(c, fds[i].events & 0xffff, &sfd);
			if(fds[i].revents & LPOLLIN)
				fds[i].revents |= fds[i].events & LPOLLRDNORM;
			if(fds[i].revents & LPOLLOUT)
				fds[i].revents |= fds[i].events & LPOLLWRNORM;
			if(fds[i].revents == 0 && sfd >= 0 && ms != 0){
				h9so_watchinit();
				h9so_watch(sfd, fds[i].events, &owner);
			}
			cclose(c);
			if(fds[i].revents != 0)
				ready++;
		}
		if(ready > 0 || ms == 0)
			break;
		if(ms > 0){
			now = h9_tnow();
			if(now >= deadline)
				break;
			if(pollwait(g, (deadline - now + 999999) / 1000000))
				break;
		}else
			pollwait(g, 0);
		h9so_unwatch(&owner);
		if(once){
			ready = 0;
			break;
		}
	}
	h9so_unwatch(&owner);
	poperror();
	if(gen != nil)
		*gen = g;
	return ready;
}

/* The poll bits ready on fd now, without sleeping; -1 if it's not open. */
int
h9_fdready(int fd, int events)
{
	Lpollfd p;

	p.fd = fd;
	p.events = events;
	if(h9_poll(&p, 1, 0, nil, 0) < 0)
		return -1;
	if(p.revents & LPOLLNVAL)
		return -1;
	return p.revents;
}

/*
 * Linux socket calls that devip's files can't express: recv and send
 * with flags, SO_ERROR, and control messages on the conversation behind
 * fd. They return -errno (Linux's) or set the error string and return
 * -1 as the other leaves do.
 */
static int
sockof(int fd, int *udp)
{
	Chan *c;
	int s;

	c = fdtochan(fd, -1, 0, 1);
	if(devtab[c->type]->dc != 'I'){
		cclose(c);
		error("not a socket");
	}
	s = h9_ip_sfd(c, udp);
	cclose(c);
	return s;
}

/*
 * recvfrom on a socket fd's host socket: the count or -errno. raddr
 * (16 bytes) and rport get the source if raddr isn't nil.
 */
long
h9_linux_sockrecv(int fd, void *buf, long n, int peek, int dontwait, uchar *raddr, ushort *rport)
{
	int s;

	Rconv *r;
	long m;

	if((r = rgetfd(fd)) != nil){
		m = rrecv(r, buf, n, peek);
		rput(r);
		return m;
	}
	if(waserror())
		return -9;	/* EBADF */
	s = sockof(fd, nil);
	poperror();
	if(s < 0)
		return -107;	/* ENOTCONN */
	return h9so_recvfrom(s, buf, n, peek, dontwait, raddr, rport);
}

/*
 * sendto on a socket fd's host socket, to raddr!rport if raddr isn't nil,
 * after the policy's check, as devip's connect does.
 */
long
h9_linux_socksend(int fd, void *buf, long n, int dontwait, uchar *raddr, ushort rport)
{
	int s, udp;

	Rconv *r;
	long m;

	if((r = rgetfd(fd)) != nil){
		m = raddr != nil ? -106 : rsend(r, buf, n);	/* EISCONN: one peer */
		rput(r);
		return m;
	}
	udp = 0;
	if(waserror())
		return -9;
	s = sockof(fd, &udp);
	poperror();
	if(s < 0)
		return raddr != nil ? -89 : -107;	/* EDESTADDRREQ, ENOTCONN */
	if(raddr != nil && h9_net_check(H9_NETCONNECT, udp ? S_UDP : S_TCP, raddr, rport) < 0)
		return -13;	/* EACCES */
	return h9so_sendto(s, buf, n, dontwait, raddr, rport);
}

/*
 * Bytes queued in the pipe that a write on pipe end fd goes into, for
 * SCM_RIGHTS (src/linux/sys.zig); -1 if fd isn't a pipe's data file.
 */
long
h9_linux_pipequeued(int fd)
{
	Chan *c;
	Queue *q;
	long n;

	if(waserror())
		return -1;
	c = fdtochan(fd, -1, 0, 1);
	n = -1;
	if(devtab[c->type]->dc == '|' && (c->qid.type & QTDIR) == 0 && (q = h9_pipeq(c, 1)) != nil)
		n = qlen(q);
	cclose(c);
	poperror();
	return n;
}

int
h9_linux_soerror(int fd)
{
	Rconv *r;
	int s;

	if((r = rgetfd(fd)) != nil){
		lock(&r->lk);
		s = r->err;
		r->err = 0;
		unlock(&r->lk);
		rput(r);
		return s;
	}
	if(waserror())
		return 9;
	s = sockof(fd, nil);
	poperror();
	return h9so_soerror(s);
}

int
h9_linux_sockctl(int fd, char *msg)
{
	Chan *c;
	Rconv *r;

	if(waserror())
		return syserr();
	c = fdtochan(fd, -1, 0, 1);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	if(devtab[c->type]->dc == 'M' && (r = rget(c)) != nil){
		if(waserror()){
			rput(r);
			nexterror();
		}
		rsockctl(r, msg);
		poperror();
		rput(r);
	}else if(devtab[c->type]->dc != 'I')
		error("not a socket");
	else
		h9_ip_ctl(c, msg);
	poperror();
	cclose(c);
	poperror();
	return 0;
}
