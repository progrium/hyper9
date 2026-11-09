/*
 * h9: host-socket calls for devip's h9 additions and the Linux socket
 * calls on Windows (src/kern/hostsock.h). The watcher selects with a
 * short timeout instead of a wake pipe.
 */

#define _WIN32_WINNT 0x0600
#define FD_SETSIZE 1024
#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>

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
#undef select

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
	switch(which){
	case H9optnodelay:
		setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (char*)&val, sizeof val);
		break;
	case H9optkeepalive:
		setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, (char*)&val, sizeof val);
		break;
	case H9optreuseaddr:
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (char*)&val, sizeof val);
		break;
	case H9optrcvbuf:
		setsockopt(fd, SOL_SOCKET, SO_RCVBUF, (char*)&val, sizeof val);
		break;
	case H9optsndbuf:
		setsockopt(fd, SOL_SOCKET, SO_SNDBUF, (char*)&val, sizeof val);
		break;
	case H9optv6only:	/* fails, harmlessly, on an IPv4 socket */
		setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, (char*)&val, sizeof val);
		break;
	}
	/* Windows sets keepalive timing per socket with an ioctl; left as advice. */
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
	SOCKET s;

	if(has < 0){
		s = socket(AF_INET6, SOCK_STREAM, 0);
		has = s != INVALID_SOCKET;
		if(has)
			closesocket(s);
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
	u_long on, off;
	int r, e, len;

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
	on = 1;
	off = 0;
	ioctlsocket(fd, FIONBIO, &on);
	r = connect(fd, (struct sockaddr*)&ss, len);
	e = WSAGetLastError();
	ioctlsocket(fd, FIONBIO, &off);
	if(r == 0)
		return 0;
	if(e == WSAEWOULDBLOCK || e == WSAEINPROGRESS)
		return 1;
	oserror();
	return -1;
}

void
h9so_close(int fd)
{
	closesocket(fd);
}

void
h9so_shutdown(int fd, char *how)
{
	int h;

	if(strcmp(how, "rd") == 0)
		h = SD_RECEIVE;
	else if(strcmp(how, "wr") == 0)
		h = SD_SEND;
	else if(strcmp(how, "rdwr") == 0)
		h = SD_BOTH;
	else
		error("bad args to shutdown");
	if(shutdown(fd, h) != 0)
		oserror();
}

int
h9so_ready(int fd, int events)
{
	WSAPOLLFD p;
	int r, n;
	char c;
	u_long on, off;

	if(fd < 0)
		return 0;
	p.fd = fd;
	p.events = 0;
	if(events & (LPOLLIN|LPOLLRDHUP))
		p.events |= POLLRDNORM;
	if(events & LPOLLOUT)
		p.events |= POLLWRNORM;
	p.revents = 0;
	if(WSAPoll(&p, 1, 0) <= 0)
		return 0;
	r = 0;
	if(p.revents & POLLRDNORM)
		r |= LPOLLIN;
	if(p.revents & POLLWRNORM)
		r |= LPOLLOUT;
	if(p.revents & POLLERR)
		r |= LPOLLERR;
	if(p.revents & POLLHUP)
		r |= LPOLLHUP | LPOLLIN;
	if((events & LPOLLRDHUP) && (r & LPOLLIN)){
		on = 1;
		off = 0;
		ioctlsocket(fd, FIONBIO, &on);
		n = recv(fd, &c, 1, MSG_PEEK);
		ioctlsocket(fd, FIONBIO, &off);
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
	case WSAEWOULDBLOCK: return 11;
	case WSAEINTR: return 4;
	case WSAEBADF: case WSAENOTSOCK: return 9;
	case WSAEINVAL: return 22;
	case WSAEINPROGRESS: return 115;
	case WSAEALREADY: return 114;
	case WSAENOTCONN: return 107;
	case WSAEISCONN: return 106;
	case WSAECONNREFUSED: return 111;
	case WSAECONNRESET: return 104;
	case WSAECONNABORTED: return 103;
	case WSAETIMEDOUT: return 110;
	case WSAENETUNREACH: return 101;
	case WSAENETDOWN: return 100;
	case WSAEHOSTUNREACH: return 113;
	case WSAEADDRINUSE: return 98;
	case WSAEADDRNOTAVAIL: return 99;
	case WSAEMSGSIZE: return 90;
	case WSAENOBUFS: return 105;
	case WSAEACCES: return 13;
	case WSAESHUTDOWN: return 32;
	}
	return 5;
}

int
h9so_soerror(int fd)
{
	int e, len;

	if(fd < 0)
		return 0;
	e = 0;
	len = sizeof e;
	if(getsockopt(fd, SOL_SOCKET, SO_ERROR, (char*)&e, &len) != 0)
		return h9so_linuxerrno(WSAGetLastError());
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

/* Windows has no MSG_DONTWAIT: the socket is non-blocking for the call. */
long
h9so_recvfrom(int fd, void *buf, long n, int peek, int dontwait, unsigned char *raddr, unsigned short *rport)
{
	struct sockaddr_storage ss;
	int len, e;
	long r;
	u_long on, off;

	on = 1;
	off = 0;
	len = sizeof ss;
	memset(&ss, 0, sizeof ss);
	if(dontwait)
		ioctlsocket(fd, FIONBIO, &on);
	r = recvfrom(fd, buf, n, peek ? MSG_PEEK : 0, (struct sockaddr*)&ss, &len);
	e = WSAGetLastError();
	if(dontwait)
		ioctlsocket(fd, FIONBIO, &off);
	if(r < 0)
		return -h9so_linuxerrno(e);
	if(raddr != nil)
		fromss(&ss, raddr, rport);
	return r;
}

long
h9so_sendto(int fd, void *buf, long n, int dontwait, unsigned char *raddr, unsigned short rport)
{
	struct sockaddr_storage ss, me;
	int len, mlen, e;
	long r;
	u_long on, off;

	on = 1;
	off = 0;
	if(dontwait)
		ioctlsocket(fd, FIONBIO, &on);
	if(raddr == nil)
		r = send(fd, buf, n, 0);
	else{
		mlen = sizeof me;
		memset(&me, 0, sizeof me);
		getsockname(fd, (struct sockaddr*)&me, &mlen);
		memset(&ss, 0, sizeof ss);
		if(me.ss_family != AF_INET6 && isv4(raddr)){
			struct sockaddr_in *s4 = (struct sockaddr_in*)&ss;
			s4->sin_family = AF_INET;
			hnputs(&s4->sin_port, rport);
			v6tov4((uchar*)&s4->sin_addr.s_addr, raddr);
			len = sizeof *s4;
		}else{
			struct sockaddr_in6 *s6 = (struct sockaddr_in6*)&ss;
			s6->sin6_family = AF_INET6;
			hnputs(&s6->sin6_port, rport);
			memcpy(&s6->sin6_addr.s6_addr, raddr, 16);
			len = sizeof *s6;
		}
		r = sendto(fd, buf, n, 0, (struct sockaddr*)&ss, len);
	}
	e = WSAGetLastError();
	if(dontwait)
		ioctlsocket(fd, FIONBIO, &off);
	if(r < 0)
		return -h9so_linuxerrno(e);
	return r;
}

enum { Nwatch = 1024 };

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
static int wstarted;

static void
watcher(void *v)
{
	WSAPOLLFD *p;
	void **own;
	int i, j, n, fired;

	USED(v);
	h9_kprocdetach();
	p = malloc(sizeof(*p) * Nwatch);
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
		if(n == 0){
			osmsleep(10);
			continue;
		}
		if(WSAPoll(p, n, 10) <= 0)
			continue;
		fired = 0;
		lock(&wlk);
		for(i = 0; i < n; i++){
			if(p[i].revents == 0)
				continue;
			fired = 1;
			for(j = 0; j < nwatch; j++)
				if(watches[j].fd == (int)p[i].fd && watches[j].owner == own[i]){
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
	lock(&wlk);
	if(wstarted){
		unlock(&wlk);
		return;
	}
	wstarted = 1;
	unlock(&wlk);
	kproc("hostpoll", watcher, nil);
}

void
h9so_watch(int fd, int events, void *owner)
{
	short ev;

	ev = 0;
	if(events & (LPOLLIN|LPOLLRDHUP))
		ev |= POLLRDNORM;
	if(events & LPOLLOUT)
		ev |= POLLWRNORM;
	lock(&wlk);
	if(nwatch < Nwatch){
		watches[nwatch].fd = fd;
		watches[nwatch].events = ev;
		watches[nwatch].owner = owner;
		nwatch++;
	}
	unlock(&wlk);
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

int
h9so_ifaddrs(H9ifaddr *a, int max)
{
	USED(a);
	USED(max);
	return 0;	/* the Linux layer lists loopback alone */
}
