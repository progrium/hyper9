/*
 * devip's host socket layer on the web host (design/browser-host.md),
 * built instead of devip-posix.c. There's no socket API in a browser, and
 * the policy masks #I there, but devip.c links against these.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "devip.h"

static char Enonet[] = "no network on the web host";

void
osipinit(void)
{
	kstrdup(&sysname, "h9");
}

int
so_socket(int type, unsigned char *addr)
{
	USED(type, addr);
	error(Enonet);
	return -1;
}

void
so_connect(int fd, unsigned char *raddr, unsigned short rport)
{
	USED(fd, raddr, rport);
	error(Enonet);
}

void
so_getsockname(int fd, unsigned char *laddr, unsigned short *lport)
{
	USED(fd, laddr, lport);
	error(Enonet);
}

void
so_listen(int fd)
{
	USED(fd);
	error(Enonet);
}

int
so_accept(int fd, unsigned char *raddr, unsigned short *rport)
{
	USED(fd, raddr, rport);
	error(Enonet);
	return -1;
}

void
so_bind(int fd, int su, unsigned short port, unsigned char *addr)
{
	USED(fd, su, port, addr);
	error(Enonet);
}

int
so_gethostbyname(char *host, char **hostv, int n)
{
	USED(host, hostv, n);
	return 0;
}

int
so_getservbyname(char *service, char *net, char *port)
{
	USED(service, net, port);
	return -1;
}

int
so_send(int fd, void *d, int n, int f)
{
	USED(fd, d, n, f);
	error(Enonet);
	return -1;
}

int
so_recv(int fd, void *d, int n, int f)
{
	USED(fd, d, n, f);
	error(Enonet);
	return -1;
}
