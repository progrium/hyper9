/*
 * The host side of 9P roots (design/ninep-roots.md): connecting a unix
 * socket root, and the user name devmnt sends in a root's attach.
 *
 * A unix socket root is connected by h9 on the host and wrapped as a
 * channel with devlfd's lfdchan, as drawterm wraps the host's stdio.
 * Windows has AF_UNIX, but a winsock handle doesn't go through
 * devlfd-win32's ReadFile and WriteFile, so it isn't supported there.
 */

#if !defined(WINDOWS) && !defined(H9_WEB)
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>
#endif

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#undef connect
#undef socket
#undef close

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
