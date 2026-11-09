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
 * The poll bits ready on c now, of those in ev (plus errors and hangups,
 * which are always reported). *sfd is set to a host socket to watch
 * when none is.
 */
static int
chanready(Chan *c, int ev, int *sfd)
{
	Queue *rq, *wq;
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
	int s;

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

	if(waserror())
		return syserr();
	c = fdtochan(fd, -1, 0, 1);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	if(devtab[c->type]->dc != 'I')
		error("not a socket");
	h9_ip_ctl(c, msg);
	poperror();
	cclose(c);
	poperror();
	return 0;
}
