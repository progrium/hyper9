/*
 * h9: host-socket calls for devip's h9 additions and the Linux socket
 * calls (design/0050-linux-net.md, src/kern/hostsock.h), and the watcher
 * that wakes pollers when a socket they wait on becomes ready.
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#include "ip.h"

#include "devip.h"
#include "hostsock.h"

#undef listen
#undef accept
#undef bind
#undef connect
#undef shutdown
#undef send
#undef recv
#undef pipe
#undef read
#undef write
#undef close

/* Linux's poll bits; the host's are the same but for POLLRDHUP. */
enum {
	LPOLLIN = 1,
	LPOLLOUT = 4,
	LPOLLERR = 8,
	LPOLLHUP = 0x10,
	LPOLLRDHUP = 0x2000,
};

extern void h9_pollwake(void);

static void
applyopt(int fd, int which, int val)
{
	int r;

	r = 0;
	switch(which){
	case H9optnodelay:
		r = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &val, sizeof val);
		break;
	case H9optkeepalive:
		r = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &val, sizeof val);
		break;
	case H9optkeepidle:
#ifdef TCP_KEEPIDLE
		r = setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &val, sizeof val);
#elif defined(TCP_KEEPALIVE)
		r = setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &val, sizeof val);
#endif
		break;
	case H9optkeepintvl:
#ifdef TCP_KEEPINTVL
		r = setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &val, sizeof val);
#endif
		break;
	case H9optkeepcnt:
#ifdef TCP_KEEPCNT
		r = setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &val, sizeof val);
#endif
		break;
	case H9optreuseaddr:
		r = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &val, sizeof val);
		break;
	case H9optrcvbuf:
		r = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &val, sizeof val);
		break;
	case H9optsndbuf:
		r = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &val, sizeof val);
		break;
	case H9optv6only:	/* fails, harmlessly, on an IPv4 socket */
		r = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &val, sizeof val);
		break;
	}
	USED(r);	/* an option the host refuses is only advice */
}

int
h9so_socket(int type, unsigned char *addr, int *opts)
{
	int fd, i;

	fd = so_socket(type, addr);
	for(i = 0; i < H9nopt; i++)
		if(opts[i] & H9optset)
			applyopt(fd, i, opts[i] & ~H9optset);
	return fd;
}

static char *optnames[H9nopt] = {
	[H9optnodelay] "nodelay",
	[H9optkeepalive] "keepalive",
	[H9optkeepidle] "keepidle",
	[H9optkeepintvl] "keepintvl",
	[H9optkeepcnt] "keepcnt",
	[H9optreuseaddr] "reuseaddr",
	[H9optrcvbuf] "rcvbuf",
	[H9optsndbuf] "sndbuf",
	[H9optv6only] "v6only",
};

int
h9so_hasv6(void)
{
	static int has = -1;
	int fd;

	if(has < 0){
		fd = socket(AF_INET6, SOCK_STREAM, 0);
		has = fd >= 0;
		if(fd >= 0)
			close(fd);
	}
	return has;
}

void
h9so_setopt(int fd, int *opts, char *name, int val)
{
	int i;

	for(i = 0; i < H9nopt; i++)
		if(strcmp(optnames[i], name) == 0)
			break;
	if(i == H9nopt)
		error("unknown socket option");
	opts[i] = (val & ~H9optset) | H9optset;
	if(fd >= 0)
		applyopt(fd, i, val);
}

int
h9so_connect_nb(int fd, unsigned char *raddr, unsigned short rport)
{
	struct sockaddr_storage ss;
	int fl, r, e;
	socklen_t len;

	memset(&ss, 0, sizeof(ss));
	if(isv4(raddr)){
		struct sockaddr_in *s4 = (struct sockaddr_in*)&ss;
		s4->sin_family = AF_INET;
		hnputs(&s4->sin_port, rport);
		v6tov4((uchar*)&s4->sin_addr.s_addr, raddr);
		len = sizeof *s4;
	}else{
		struct sockaddr_in6 *s6 = (struct sockaddr_in6*)&ss;
		s6->sin6_family = AF_INET6;
		hnputs(&s6->sin6_port, rport);
		memcpy(&s6->sin6_addr.s6_addr, raddr, sizeof(struct in6_addr));
		len = sizeof *s6;
	}
	/*
	 * Non-blocking for the connect only: the host carries on with it
	 * after the socket goes back to blocking, and reports it writable
	 * when it's done, so devip's blocking reads and writes still work.
	 */
	fl = fcntl(fd, F_GETFL);
	fcntl(fd, F_SETFL, fl | O_NONBLOCK);
	r = connect(fd, (struct sockaddr*)&ss, len);
	e = errno;
	fcntl(fd, F_SETFL, fl);
	if(r == 0)
		return 0;
	if(e == EINPROGRESS || e == EINTR)
		return 1;
	errno = e;
	oserror();
	return -1;
}

void
h9so_shutdown(int fd, char *how)
{
	int h;

	if(strcmp(how, "rd") == 0)
		h = SHUT_RD;
	else if(strcmp(how, "wr") == 0)
		h = SHUT_WR;
	else if(strcmp(how, "rdwr") == 0)
		h = SHUT_RDWR;
	else
		error("bad args to shutdown");
	if(shutdown(fd, h) < 0)
		oserror();
}

int
h9so_ready(int fd, int events)
{
	struct pollfd p;
	int r, n;
	char c;

	if(fd < 0)
		return 0;
	p.fd = fd;
	p.events = 0;
	if(events & (LPOLLIN|LPOLLRDHUP))
		p.events |= POLLIN;
	if(events & LPOLLOUT)
		p.events |= POLLOUT;
	p.revents = 0;
	if(poll(&p, 1, 0) <= 0)
		return 0;
	r = 0;
	if(p.revents & POLLIN)
		r |= LPOLLIN;
	if(p.revents & POLLOUT)
		r |= LPOLLOUT;
	if(p.revents & POLLERR)
		r |= LPOLLERR;
	if(p.revents & POLLHUP)
		r |= LPOLLHUP | LPOLLIN;
	if(p.revents & POLLNVAL)
		r |= LPOLLHUP;
	/* The peer's half-close: readable with nothing to read. */
	if((events & LPOLLRDHUP) && (r & LPOLLIN)){
		n = recv(fd, &c, 1, MSG_PEEK|MSG_DONTWAIT);
		if(n == 0)
			r |= LPOLLRDHUP;
	}
	return r & (events | LPOLLERR | LPOLLHUP);
}

int
h9so_linuxerrno(int e)
{
	switch(e){
	case 0: return 0;
	case EAGAIN: return 11;
#if EWOULDBLOCK != EAGAIN
	case EWOULDBLOCK: return 11;
#endif
	case EINTR: return 4;
	case EBADF: return 9;
	case EINVAL: return 22;
	case EPIPE: return 32;
	case EINPROGRESS: return 115;
	case EALREADY: return 114;
	case ENOTCONN: return 107;
	case EISCONN: return 106;
	case ECONNREFUSED: return 111;
	case ECONNRESET: return 104;
	case ECONNABORTED: return 103;
	case ETIMEDOUT: return 110;
	case ENETUNREACH: return 101;
	case ENETDOWN: return 100;
	case EHOSTUNREACH: return 113;
	case EADDRINUSE: return 98;
	case EADDRNOTAVAIL: return 99;
	case EMSGSIZE: return 90;
	case ENOBUFS: return 105;
	case EACCES: return 13;
	case EPERM: return 1;
	}
	return 5;	/* EIO */
}

int
h9so_soerror(int fd)
{
	int e;
	socklen_t len;

	if(fd < 0)
		return 0;
	e = 0;
	len = sizeof e;
	if(getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &len) < 0)
		return h9so_linuxerrno(errno);
	return h9so_linuxerrno(e);
}

static void
fromss(struct sockaddr_storage *ss, unsigned char *raddr, unsigned short *rport)
{
	switch(ss->ss_family){
	case AF_INET:
		v4tov6(raddr, (unsigned char*)&((struct sockaddr_in*)ss)->sin_addr.s_addr);
		*rport = nhgets(&((struct sockaddr_in*)ss)->sin_port);
		break;
	case AF_INET6:
		memcpy(raddr, &((struct sockaddr_in6*)ss)->sin6_addr.s6_addr, 16);
		*rport = nhgets(&((struct sockaddr_in6*)ss)->sin6_port);
		break;
	default:
		memset(raddr, 0, 16);
		*rport = 0;
	}
}

static socklen_t
toss(struct sockaddr_storage *ss, int fam, unsigned char *raddr, unsigned short rport)
{
	memset(ss, 0, sizeof *ss);
	if(fam == AF_INET){
		struct sockaddr_in *s4 = (struct sockaddr_in*)ss;
		s4->sin_family = AF_INET;
		hnputs(&s4->sin_port, rport);
		v6tov4((uchar*)&s4->sin_addr.s_addr, raddr);
		return sizeof *s4;
	}else{
		struct sockaddr_in6 *s6 = (struct sockaddr_in6*)ss;
		s6->sin6_family = AF_INET6;
		hnputs(&s6->sin6_port, rport);
		memcpy(&s6->sin6_addr.s6_addr, raddr, 16);
		return sizeof *s6;
	}
}

long
h9so_recvfrom(int fd, void *buf, long n, int peek, int dontwait, unsigned char *raddr, unsigned short *rport)
{
	struct sockaddr_storage ss;
	socklen_t len;
	long r;

	len = sizeof ss;
	memset(&ss, 0, sizeof ss);
	r = recvfrom(fd, buf, n, (peek ? MSG_PEEK : 0) | (dontwait ? MSG_DONTWAIT : 0), (struct sockaddr*)&ss, &len);
	if(r < 0)
		return -h9so_linuxerrno(errno);
	if(raddr != nil)
		fromss(&ss, raddr, rport);
	return r;
}

long
h9so_sendto(int fd, void *buf, long n, int dontwait, unsigned char *raddr, unsigned short rport)
{
	struct sockaddr_storage ss, me;
	socklen_t len, mlen;
	long r;
	int fl;

#ifdef MSG_NOSIGNAL
	fl = MSG_NOSIGNAL;
#else
	fl = 0;
#endif
	if(dontwait)
		fl |= MSG_DONTWAIT;
	if(raddr == nil)
		r = send(fd, buf, n, fl);
	else{
		/* The socket's own family decides the address's form. */
		mlen = sizeof me;
		memset(&me, 0, sizeof me);
		getsockname(fd, (struct sockaddr*)&me, &mlen);
		len = toss(&ss, me.ss_family == AF_INET6 ? AF_INET6 : (isv4(raddr) ? AF_INET : AF_INET6), raddr, rport);
		r = sendto(fd, buf, n, fl, (struct sockaddr*)&ss, len);
	}
	if(r < 0)
		return -h9so_linuxerrno(errno);
	return r;
}

/*
 * The watcher: a kproc that polls the sockets pollers are waiting on,
 * plus a pipe that says the list changed. When one is ready it drops
 * that socket from the list (its poller will ask again) and wakes every
 * poller. Pollers add their sockets before they sleep and drop them when
 * they wake.
 */
enum { Nwatch = 4096 };

typedef struct Watch Watch;
struct Watch
{
	int	fd;
	short	events;
	void	*owner;
};

static Lock wlk;
static Watch watches[Nwatch];
static int nwatch;
static int wpipe[2] = {-1, -1};
static int wstarted;

static void
kick(void)
{
	char c;

	c = 0;
	if(wpipe[1] >= 0)
		if(write(wpipe[1], &c, 1) < 0){}	/* lib.h's USED drops its argument */
}

static void
watcher(void *v)
{
	struct pollfd *p;
	void **own;
	int i, n, fired;
	char buf[64];

	USED(v);
	h9_kprocdetach();
	p = malloc(sizeof(*p) * (Nwatch+1));
	own = malloc(sizeof(*own) * Nwatch);
	for(;;){
		lock(&wlk);
		n = nwatch;
		for(i = 0; i < n; i++){
			p[i].fd = watches[i].fd;
			p[i].events = watches[i].events;
			p[i].revents = 0;
			own[i] = watches[i].owner;
		}
		unlock(&wlk);
		p[n].fd = wpipe[0];
		p[n].events = POLLIN;
		p[n].revents = 0;
		if(poll(p, n+1, -1) < 0)
			continue;
		if(p[n].revents & POLLIN)
			if(read(wpipe[0], buf, sizeof buf) < 0){}
		fired = 0;
		lock(&wlk);
		for(i = 0; i < n; i++){
			int j;
			if(p[i].revents == 0)
				continue;
			fired = 1;
			/* Drop it, so a level-triggered socket doesn't spin us. */
			for(j = 0; j < nwatch; j++)
				if(watches[j].fd == p[i].fd && watches[j].owner == own[i]){
					watches[j] = watches[--nwatch];
					break;
				}
		}
		unlock(&wlk);
		if(fired)
			h9_pollwake();
	}
}

void
h9so_watchinit(void)
{
	int fl;

	lock(&wlk);
	if(wstarted){
		unlock(&wlk);
		return;
	}
	wstarted = 1;
	unlock(&wlk);
	if(pipe(wpipe) < 0)
		panic("h9so_watchinit: pipe");
	fl = fcntl(wpipe[1], F_GETFL);
	fcntl(wpipe[1], F_SETFL, fl | O_NONBLOCK);
	fcntl(wpipe[0], F_SETFD, FD_CLOEXEC);
	fcntl(wpipe[1], F_SETFD, FD_CLOEXEC);
	kproc("hostpoll", watcher, nil);
}

void
h9so_watch(int fd, int events, void *owner)
{
	short ev;

	ev = 0;
	if(events & (LPOLLIN|LPOLLRDHUP))
		ev |= POLLIN;
	if(events & LPOLLOUT)
		ev |= POLLOUT;
	lock(&wlk);
	if(nwatch < Nwatch){
		watches[nwatch].fd = fd;
		watches[nwatch].events = ev;
		watches[nwatch].owner = owner;
		nwatch++;
	}
	unlock(&wlk);
	kick();
}

void
h9so_unwatch(void *owner)
{
	int i;

	lock(&wlk);
	for(i = 0; i < nwatch; )
		if(watches[i].owner == owner)
			watches[i] = watches[--nwatch];
		else
			i++;
	unlock(&wlk);
}
