/*
 * The host side of 9P roots (design/epoch-0/ninep-roots.md): connecting a unix
 * socket root, and the user name devmnt sends in a root's attach.
 *
 * A unix socket root is connected by h9 on the host and wrapped as a
 * channel with devlfd's lfdchan, as drawterm wraps the host's stdio.
 * Windows has AF_UNIX, but a winsock handle doesn't go through
 * devlfd-win32's ReadFile and WriteFile, so it isn't supported there.
 *
 * An embedder's descriptors (design/fd-mounts.md) come in already
 * duplicated by h9 (Machine.connectUrl), and are wrapped the same way.
 */

#if defined(WINDOWS)
#include <windows.h>
#elif !defined(H9_WEB)
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>
#include <poll.h>
#include <fcntl.h>
#include <errno.h>
#endif

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#undef connect
#undef socket
#undef close

long	_sysclose(int);

/*
 * Connects to the unix-domain socket at the host path `path` and returns
 * a devlfd channel for it. Raises errors.
 */
Chan*
h9_unixchan(char *path)
{
#if defined(WINDOWS) || defined(H9_WEB)
	USED(path);
	error("unix socket roots need a POSIX host");
	return nil;
#else
	struct sockaddr_un sa;
	int s;

	memset(&sa, 0, sizeof sa);
	sa.sun_family = AF_UNIX;
	if(strlen(path) >= sizeof sa.sun_path)
		error("socket path too long");
	strcpy(sa.sun_path, path);
	s = socket(AF_UNIX, SOCK_STREAM, 0);
	if(s < 0)
		oserror();
	if(connect(s, (struct sockaddr*)&sa, sizeof sa) < 0){
		close(s);
		oserror();
	}
	/* closing the channel closes s (devlfd's lfdclose) */
	return lfdchan((void*)(uintptr)s);
#endif
}

/*
 * Connects to the unix-domain socket at the host path `path` and returns
 * a new fd on a devlfd channel for it; or -1 with the error string set.
 */
int
h9_unixdial(char *path)
{
	Chan *c;
	int fd;

	if(waserror()){
		char *p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	c = h9_unixchan(path);
	fd = newfd(c, 0);
	if(fd < 0){
		cclose(c);
		error(Enofd);
	}
	poperror();
	return fd;
}

/*
 * Wraps host descriptors rd and wr, which the channels take, as devlfd
 * channels, and returns new fds on them in *rfd and *wfd; wr may be the
 * same as rd, for a socket or a duplex pipe, and then *wfd is -1. Or -1
 * with the error string set, and the descriptors closed.
 */
int
h9_hostfddial(void *rd, void *wr, int *rfd, int *wfd)
{
	Chan *volatile rc, *volatile wc;

	*rfd = *wfd = -1;
	rc = wc = nil;
	if(waserror()){
		char *p = up->syserrstr;
		if(rc != nil)
			cclose(rc);
		if(wc != nil)
			cclose(wc);
		if(*rfd >= 0)
			_sysclose(*rfd);
		*rfd = *wfd = -1;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
#if defined(H9_WEB)
	USED(rd);
	USED(wr);
	error("host descriptors need a native host");
#else
	/* closing a channel closes its descriptor (devlfd's lfdclose) */
	rc = lfdchan(rd);
	if(wr != rd)
		wc = lfdchan(wr);
	if((*rfd = newfd(rc, 0)) < 0)
		error(Enofd);
	rc = nil;
	if(wc != nil){
		if((*wfd = newfd(wc, 0)) < 0)
			error(Enofd);
		wc = nil;
	}
#endif
	poperror();
	return 0;
}

/*
 * A wait for a host descriptor to be readable that can be woken, so a
 * #ℓ conversation's reader on a descriptor h9 doesn't own the other end
 * of (an embedder's, design/fd-mounts.md) ends with the conversation,
 * rather than blocking in the host's read until the other end writes or
 * closes. Closing h9's copy wouldn't wake that read, and shutting the
 * stream down would end the embedder's too.
 *
 * On POSIX it polls the descriptor with a pipe beside it, which wake
 * writes. Windows can't poll a pipe handle, so it peeks it, sleeping a
 * little longer each time it finds nothing, up to Hwaitmax ms.
 */
enum { Hwaitmax = 8 };

typedef struct Hostwait Hostwait;
struct Hostwait
{
	void	*fd;
	volatile int	woken;
#if !defined(WINDOWS) && !defined(H9_WEB)
	int	p[2];
#endif
};

void*
h9_hostwait_new(void *fd)
{
#if defined(H9_WEB)
	USED(fd);
	return nil;
#else
	Hostwait *w;

	w = mallocz(sizeof *w, 1);
	if(w == nil)
		return nil;
	w->fd = fd;
#if !defined(WINDOWS)
	if(pipe(w->p) < 0){
		free(w);
		return nil;
	}
	fcntl(w->p[0], F_SETFD, FD_CLOEXEC);
	fcntl(w->p[1], F_SETFD, FD_CLOEXEC);
	fcntl(w->p[1], F_SETFL, fcntl(w->p[1], F_GETFL) | O_NONBLOCK);
#endif
	return w;
#endif
}

/*
 * Returns 1 when the descriptor has bytes, has hung up, or can't be
 * waited on (the read says which), and 0 once woken.
 */
int
h9_hostwait(void *a)
{
	Hostwait *w;

	w = a;
	if(w == nil)
		return 1;
#if defined(H9_WEB)
	return 1;
#elif defined(WINDOWS)
	{
		DWORD avail, ms;

		ms = 0;
		for(;;){
			if(w->woken)
				return 0;
			avail = 0;
			if(!PeekNamedPipe((HANDLE)w->fd, NULL, 0, NULL, &avail, NULL) || avail > 0)
				return 1;
			Sleep(ms);
			if(ms < Hwaitmax)
				ms = ms == 0 ? 1 : ms*2;
		}
	}
#else
	{
		struct pollfd p[2];

		for(;;){
			if(w->woken)
				return 0;
			p[0].fd = (int)(uintptr)w->fd;
			p[0].events = POLLIN;
			p[0].revents = 0;
			p[1].fd = w->p[0];
			p[1].events = POLLIN;
			p[1].revents = 0;
			if(poll(p, 2, -1) < 0){
				if(errno == EINTR)
					continue;
				return 1;
			}
			if(w->woken || (p[1].revents & POLLIN))
				return 0;
			if(p[0].revents)
				return 1;
		}
	}
#endif
}

void
h9_hostwait_wake(void *a)
{
	Hostwait *w;

	w = a;
	if(w == nil)
		return;
	w->woken = 1;
#if !defined(WINDOWS) && !defined(H9_WEB)
	{
		char c = 0;
		if(write(w->p[1], &c, 1) < 0){}
	}
#endif
}

void
h9_hostwait_free(void *a)
{
	Hostwait *w;

	w = a;
	if(w == nil)
		return;
#if !defined(WINDOWS) && !defined(H9_WEB)
	close(w->p[0]);
	close(w->p[1]);
#endif
	free(w);
}

/*
 * The calling process's user, which devmnt sends as the attach uname, and
 * setting it. Names longer than the kernel's KNAMELEN are cut short.
 */
char*
h9_kern_upuser(void)
{
	return up->user;
}

void
h9_kern_setuser(char *name)
{
	strecpy(up->user, up->user+sizeof up->user, name);
}
