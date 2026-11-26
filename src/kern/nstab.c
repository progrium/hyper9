/*
 * The namespace kernel's device table and the stubs for what it leaves
 * out (design/epoch-0/namespace-kernel.md, What's in the build). The build
 * compiles this in place of devtab.c, devcons.c, and the files the stubs
 * stand for.
 */
#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#include "devx.h"

extern Dev rootdevtab;
extern Dev pipedevtab;
extern Dev mntdevtab;
extern Dev overlaydevtab;
extern Dev srvdevtab;
extern Dev hstreamdevtab;
extern Dev dotldevtab;
extern Dev nsdevtab;
#ifndef H9_WEB
extern Dev lfddevtab;
#endif
#ifdef H9_NSKERNEL_HOSTFS
extern Dev fsdevtab;
#endif

Dev *devtab[] = {
	&rootdevtab,
	&pipedevtab,
	&mntdevtab,
	&overlaydevtab,
	&srvdevtab,
	&hstreamdevtab,
	&dotldevtab,
	&nsdevtab,
#ifndef H9_WEB
	&lfddevtab,
#endif
#ifdef H9_NSKERNEL_HOSTFS
	&fsdevtab,
#endif
	0
};

/* Their optional operations (design/file-interface.md, src/kern/devx.h). */
extern Devx overlaydevx;
#ifdef H9_NSKERNEL_HOSTFS
extern Devx fsdevx;
#endif

Devx *devxtab[] = {
	&overlaydevx,
#ifdef H9_NSKERNEL_HOSTFS
	&fsdevx,
#endif
	0
};

/* devcons.c's, without the console. */

char	*sysname;
vlong	fasthz = 1000;

int
return0(void *v)
{
	USED(v);
	return 0;
}

void
printinit(void)
{
}

int
readstr(ulong off, char *buf, ulong n, char *str)
{
	int size;

	size = strlen(str);
	if(off >= size)
		return 0;
	if(off+n > size)
		n = size-off;
	memmove(buf, str+off, n);
	return n;
}

/* The kernel's messages go to the host's standard error. */
extern int h9_ns_log(char*, int);	/* src/nskernel.zig */

void
panic(char *fmt, ...)
{
	va_list arg;
	char buf[PRINTSIZE];
	int n;

	strcpy(buf, "h9ns: panic: ");
	va_start(arg, fmt);
	n = vseprint(buf+strlen(buf), buf+sizeof(buf)-1, fmt, arg) - buf;
	va_end(arg);
	buf[n++] = '\n';
	h9_ns_log(buf, n);
	abort();
}

int
print(char *fmt, ...)
{
	va_list arg;
	char buf[PRINTSIZE];
	int n;

	va_start(arg, fmt);
	n = vseprint(buf, buf+sizeof(buf), fmt, arg) - buf;
	va_end(arg);
	return h9_ns_log(buf, n);
}

int
iprint(char *fmt, ...)
{
	va_list arg;
	char buf[PRINTSIZE];
	int n;

	va_start(arg, fmt);
	n = vseprint(buf, buf+sizeof(buf), fmt, arg) - buf;
	va_end(arg);
	return h9_ns_log(buf, n);
}

int
pprint(char *fmt, ...)
{
	va_list arg;
	char buf[PRINTSIZE];
	int n;

	va_start(arg, fmt);
	n = vseprint(buf, buf+sizeof(buf), fmt, arg) - buf;
	va_end(arg);
	return h9_ns_log(buf, n);
}

/* devenv.c's environment groups: the namespace kernel has no environment. */
void *h9_egrpnew(void) { return nil; }
void *h9_egrpcopy(void *e) { USED(e); return nil; }
void h9_egrpincref(void *e) { USED(e); }
void h9_egrpclose(void *e) { USED(e); }

/* sema.c's: no guest semaphores. */
void h9_semainit(void) {}

/* linux.c's: no Linux processes, so no Linux view, links, or chroots. */
int h9_linux_inview(void) { return 0; }
int h9_fs_linkwalk(void) { return 0; }
int h9_fs_atroot(Chan *c) { USED(c); return 0; }
void h9_fs_markroot(Chan *c, int lx) { USED(c, lx); }

/* devhidx.c's: no mount indexes. */
int h9_hidx_wide(Chan *c) { USED(c); return 0; }

/* linuxnet.zig's: no Linux sockets to wake. */
void h9_qwake(Queue *q) { USED(q); }

#ifndef H9_NSKERNEL_HOSTFS
/* devfs's and fscheck.zig's: no host tree under an overlay. */
void h9_fs_anchor(Chan *c) { USED(c); }

void h9_fs_mkfifo(Chan *c, char *name, ulong perm) { USED(c, name, perm); error(Eperm); }
int h9_fs_isfifo(Chan *c) { USED(c); return 0; }

int h9_fs_chanisfifo(Chan *c) { USED(c); return 0; }
#endif
