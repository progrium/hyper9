#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <errno.h>
#include <unistd.h>

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#include "ip.h"

#include "devip.h"

#undef listen
#undef accept
#undef bind

/* h9: whether the host has IPv6 sockets, probed once (-1: not yet). */
static int hasv6 = -1;

static int
family(unsigned char *addr)
{
	static uchar zero[16];
	int fd;

	if(isv4(addr))
		return AF_INET;
	/* h9: the wildcard address listens on IPv4 when the host has no IPv6. */
	if(memcmp(addr, zero, 16) == 0){
		if(hasv6 < 0){
			fd = socket(AF_INET6, SOCK_STREAM, 0);
			hasv6 = fd >= 0;
			if(fd >= 0)
				close(fd);
		}
		if(!hasv6)
			return AF_INET;
	}
	return AF_INET6;
}

static int
addrlen(struct sockaddr_storage *ss)
{
	switch(ss->ss_family){
	case AF_INET:
		return sizeof(struct sockaddr_in);
	case AF_INET6:
		return sizeof(struct sockaddr_in6);
	}
	return 0;
}

void
osipinit(void)
{
	char buf[1024];
	gethostname(buf, sizeof(buf));
	kstrdup(&sysname, buf);

}

int
so_socket(int type, unsigned char *addr)
{
	int fd, one;

	switch(type) {
	default:
		error("bad protocol type");
	case S_TCP:
		type = SOCK_STREAM;
		break;
	case S_UDP:
		type = SOCK_DGRAM;
		break;
	}

	fd = socket(family(addr), type, 0);
	if(fd < 0)
		oserror();

	one = 1;
	if(setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (char*)&one, sizeof(one)) > 0){
		oserrstr();
		print("setsockopt: %r");
	}

	return fd;
}

void
so_connect(int fd, unsigned char *raddr, unsigned short rport)
{
	struct sockaddr_storage ss;

	memset(&ss, 0, sizeof(ss));

	ss.ss_family = family(raddr);

	switch(ss.ss_family){
	case AF_INET:
		hnputs(&((struct sockaddr_in*)&ss)->sin_port, rport);
		v6tov4((unsigned char*)&((struct sockaddr_in*)&ss)->sin_addr.s_addr, raddr);
		break;
	case AF_INET6:
		hnputs(&((struct sockaddr_in6*)&ss)->sin6_port, rport);
		memcpy(&((struct sockaddr_in6*)&ss)->sin6_addr.s6_addr, raddr, sizeof(struct in6_addr));
		break;
	}

	if(connect(fd, (struct sockaddr*)&ss, addrlen(&ss)) < 0)
		oserror();
}

void
so_getsockname(int fd, unsigned char *laddr, unsigned short *lport)
{
	socklen_t len;
	struct sockaddr_storage ss;

	len = sizeof(ss);
	if(getsockname(fd, (struct sockaddr*)&ss, &len) < 0)
		oserror();

	switch(ss.ss_family){
	case AF_INET:
		v4tov6(laddr, (unsigned char*)&((struct sockaddr_in*)&ss)->sin_addr.s_addr);
		*lport = nhgets(&((struct sockaddr_in*)&ss)->sin_port);
		break;
	case AF_INET6:
		memcpy(laddr, &((struct sockaddr_in6*)&ss)->sin6_addr.s6_addr, sizeof(struct in6_addr));
		*lport = nhgets(&((struct sockaddr_in6*)&ss)->sin6_port);
		break;
	default:
		error("not AF_INET or AF_INET6");
	}
}

void
so_listen(int fd)
{
	if(listen(fd, 5) < 0)
		oserror();
}

int
so_accept(int fd, unsigned char *raddr, unsigned short *rport)
{
	int nfd;
	socklen_t len;
	struct sockaddr_storage ss;

	len = sizeof(ss);
	nfd = accept(fd, (struct sockaddr*)&ss, &len);
	if(nfd < 0)
		oserror();

	switch(ss.ss_family){
	case AF_INET:
		v4tov6(raddr, (unsigned char*)&((struct sockaddr_in*)&ss)->sin_addr.s_addr);
		*rport = nhgets(&((struct sockaddr_in*)&ss)->sin_port);
		break;
	case AF_INET6:
		memcpy(raddr, &((struct sockaddr_in6*)&ss)->sin6_addr.s6_addr, sizeof(struct in6_addr));
		*rport = nhgets(&((struct sockaddr_in6*)&ss)->sin6_port);
		break;
	default:
		error("not AF_INET or AF_INET6");
	}
	return nfd;
}

#ifdef __APPLE__
/*
 * h9: whether binding loopback's port would fail as in use. A wildcard bind
 * here has SO_REUSEADDR, which BSD lets
 * overlap a socket bound to one address (a container's published
 * 127.0.0.1 port), where Linux refuses it. The guest would then listen
 * on a port its own connects can't reach.
 */
static int
loopbackinuse(int fd, int fam, unsigned short port)
{
	struct sockaddr_storage ss;
	int fams[2], i, n, p, one, type, inuse;
	socklen_t tl;

	if(port == 0)
		return 0;
	tl = sizeof type;
	if(getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &tl) < 0)
		return 0;
	n = 0;
	fams[n++] = AF_INET;
	if(fam == AF_INET6)
		fams[n++] = AF_INET6;
	inuse = 0;
	one = 1;
	for(i = 0; i < n && !inuse; i++){
		p = socket(fams[i], type, 0);
		if(p < 0)
			continue;
		setsockopt(p, SOL_SOCKET, SO_REUSEADDR, (char*)&one, sizeof one);
		memset(&ss, 0, sizeof ss);
		ss.ss_family = fams[i];
		if(fams[i] == AF_INET){
			((struct sockaddr_in*)&ss)->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
			hnputs(&((struct sockaddr_in*)&ss)->sin_port, port);
		}else{
			((struct sockaddr_in6*)&ss)->sin6_addr = in6addr_loopback;
			hnputs(&((struct sockaddr_in6*)&ss)->sin6_port, port);
		}
		if(bind(p, (struct sockaddr*)&ss, addrlen(&ss)) < 0 && errno == EADDRINUSE)
			inuse = 1;
		close(p);
	}
	return inuse;
}
#endif

void
so_bind(int fd, int su, unsigned short port, unsigned char *addr)
{
	int i, one;
	struct sockaddr_storage ss;

	one = 1;
	if(setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (char*)&one, sizeof(one)) < 0){
		oserrstr();
		print("setsockopt: %r");
	}

	if(su) {
		for(i = 600; i < 1024; i++) {
			memset(&ss, 0, sizeof(ss));
			ss.ss_family = family(addr);

			switch(ss.ss_family){
			case AF_INET:
				((struct sockaddr_in*)&ss)->sin_port = i;
				break;
			case AF_INET6:
				((struct sockaddr_in6*)&ss)->sin6_port = i;
				break;
			}

			if(bind(fd, (struct sockaddr*)&ss, addrlen(&ss)) >= 0)	
				return;
		}
		oserror();
	}

	memset(&ss, 0, sizeof(ss));
	ss.ss_family = family(addr);

	/* h9: bind the address asked for (zero is any), not always any */
	switch(ss.ss_family){
	case AF_INET:
		hnputs(&((struct sockaddr_in*)&ss)->sin_port, port);
		v6tov4((unsigned char*)&((struct sockaddr_in*)&ss)->sin_addr.s_addr, addr);
		break;
	case AF_INET6:
		hnputs(&((struct sockaddr_in6*)&ss)->sin6_port, port);
		memcpy(&((struct sockaddr_in6*)&ss)->sin6_addr.s6_addr, addr, sizeof(struct in6_addr));
		break;
	}

#ifdef __APPLE__
	if(!su && loopbackinuse(fd, ss.ss_family, port)){
		errno = EADDRINUSE;
		oserror();
	}
#endif
	if(bind(fd, (struct sockaddr*)&ss, addrlen(&ss)) < 0)
		oserror();
}

int
so_gethostbyname(char *host, char **hostv, int n)
{
	char buf[INET6_ADDRSTRLEN];
	struct addrinfo *r, *p;
	int i;

	r = NULL;
	if(getaddrinfo(host, NULL, NULL, &r))
		return 0;
	for(i = 0, p = r; i < n && p != NULL; p = p->ai_next){
		switch (p->ai_family) {
		default:
			continue;
		case AF_INET:
			inet_ntop(AF_INET, &((struct sockaddr_in*)p->ai_addr)->sin_addr, buf, sizeof(buf));
			break;
		case AF_INET6:
			inet_ntop(AF_INET6, &((struct sockaddr_in6*)p->ai_addr)->sin6_addr, buf, sizeof(buf));
			break;
		}
		hostv[i++] = strdup(buf);
	}
	freeaddrinfo(r);
	return i;
}

int
so_getservbyname(char *service, char *net, char *port)
{
	struct servent *s;

	s = getservbyname(service, net);
	if(s == 0)
		return -1;

	sprint(port, "%d", nhgets(&s->s_port));
	return 0;
}

int
so_send(int fd, void *d, int n, int f)
{
	return send(fd, d, n, f);
}

int
so_recv(int fd, void *d, int n, int f)
{
	return recv(fd, d, n, f);
}
