/*
 * The host-socket calls (hostsock.h) on the web host
 * (design/0012-browser-host.md), built instead of hostsock-posix.c.
 * There's no socket API in a browser and the policy masks #I there, so
 * these fail or do nothing, as devip-wasm.c's so_ calls do.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hostsock.h"

static char Enonet[] = "no network on the web host";

int
h9so_socket(int type, unsigned char *addr, int *opts)
{
	USED(type, addr, opts);
	error(Enonet);
	return -1;
}

int
h9so_connect_nb(int fd, unsigned char *raddr, unsigned short rport)
{
	USED(fd, raddr, rport);
	error(Enonet);
	return -1;
}

void
h9so_close(int fd)
{
	USED(fd);
}

void
h9so_shutdown(int fd, char *how)
{
	USED(fd, how);
	error(Enonet);
}

void
h9so_setopt(int fd, int *opts, char *name, int val)
{
	USED(fd, opts, name, val);
	error(Enonet);
}

int
h9so_hasv6(void)
{
	return 1;	/* no host sockets to ask; socket calls fail later */
}

int
h9so_ready(int fd, int events)
{
	USED(fd, events);
	return 0;
}

int
h9so_soerror(int fd)
{
	USED(fd);
	return 0;
}

long
h9so_recvfrom(int fd, void *buf, long n, int peek, int dontwait, unsigned char *raddr, unsigned short *rport)
{
	USED(fd, buf, n, peek, dontwait, raddr, rport);
	return -100;	/* Linux's ENETDOWN */
}

long
h9so_sendto(int fd, void *buf, long n, int dontwait, unsigned char *raddr, unsigned short rport)
{
	USED(fd, buf, n, dontwait, raddr, rport);
	return -100;
}

void
h9so_watchinit(void)
{
}

void
h9so_watch(int fd, int events, void *owner)
{
	USED(fd, events, owner);
}

void
h9so_unwatch(void *owner)
{
	USED(owner);
}

int
h9so_linuxerrno(int hosterr)
{
	return hosterr;
}

int
h9so_ifaddrs(H9ifaddr *a, int max)
{
	USED(a);
	USED(max);
	return 0;	/* the Linux layer lists loopback alone */
}
