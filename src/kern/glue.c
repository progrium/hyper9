/*
 * h9's replacement for drawterm's main.c, cpu.c and GUI backend: boots
 * drawterm's kern without a window or a cpu connection. See DESIGN.md,
 * "Kernel: drawterm kern/ and the Zig seam".
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#include "user.h"

#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "screen.h"

#ifndef WINDOWS
#include <pwd.h>
#endif

char *argv0;
extern ulong kerndate;

/* No GUI until --gfx (design/gfx.md): devdraw, devmouse and snarf see no screen. */
Memimage *gscreen;
void screeninit(void) {}
void screensize(Rectangle r, ulong chan) { USED(r, chan); }
Memdata *attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen) { return nil; }
void flushmemscreen(Rectangle r) { USED(r); }
void getcolor(ulong i, ulong *r, ulong *g, ulong *b) { *r = *g = *b = 0; }
void setcolor(ulong i, ulong r, ulong g, ulong b) { USED(i, r, g, b); }
void setcursor(void) {}
void mouseset(Point p) { USED(p); }
char *clipread(void) { return nil; }
int clipwrite(char *s) { USED(s); return 0; }

/* Compose sequences only matter for GUI keyboard input. */
long latin1(Rune *k, int n) { USED(k, n); return -1; }

/* devtls's factotum path; there's no factotum until devsrv (design/devsrv.md). */
void *auth_allocrpc(int afd) { USED(afd); werrstr("no factotum"); return nil; }
void auth_freerpc(void *rpc) { USED(rpc); }
int auth_rpc(void *rpc, char *verb, void *a, int n) { USED(rpc, verb, a, n); return -1; }

#ifdef WINDOWS
extern char *h9_hostuser(void);	/* glue-win32.c */
#define hostuser h9_hostuser
#else
static char*
hostuser(void)
{
	static char user[64];
	struct passwd *pw;

	pw = getpwuid(getuid());
	if(pw == nil)
		return "none";
	strecpy(user, user+sizeof user, pw->pw_name);
	return user;
}
#endif


/*
 * Boots the kernel. The calling thread becomes the kernel's first Proc for
 * good, so callers use a private thread (src/kern.zig). Machines' processes
 * are made later with h9_kern_spawn (proc.c). Returns 0, or -1 with the error
 * string set.
 */
extern void h9_proc_boot(void);	/* proc.c */

int
h9_kern_boot(void)
{
	kerndate = seconds();
	eve = hostuser();

	osinit();
	procinit0();
	printinit();
	chandevreset();
	chandevinit();
	/* After chandevinit: devip sets sysname to the host name. */
	kstrdup(&sysname, "h9");
	quotefmtinstall();
	h9_proc_boot();
	return 0;
}

/* Parks the boot thread for good once the kernel is up. */
void
h9_kern_park(void)
{
	for(;;)
		procsleep();
}

/* The host user, which is hostowner. */
char*
h9_kern_user(void)
{
	return eve;
}

/* The calling Proc's pid. */
ulong
h9_kern_pid(void)
{
	return up->pid;
}

/* Masks the devices whose letters are in devs from future attaches. */
void
h9_kern_devmask(char *devs)
{
	devmask(up->pgrp, 0, devs);
}

/* The calling Proc, and interrupting one (for timeouts). */
void*
h9_kern_self(void)
{
	return up;
}

void
h9_kern_interrupt(void *p)
{
	procinterrupt(p);
}

/*
 * sleep(ms): drawterm has no tsleep, so this sleeps in short slices and
 * stops early when the Proc is interrupted. Returns 0, or -1 with
 * "interrupted" as the error string.
 */
int
h9_kern_sleep(long ms)
{
	long slice;

	if(ms <= 0){
		osyield();
		return 0;
	}
	while(ms > 0){
		if(up->notepending){
			up->notepending = 0;
			kstrcpy(up->syserrstr, Eintr, ERRMAX);
			return -1;
		}
		slice = ms < 20 ? ms : 20;
		osmsleep(slice);
		ms -= slice;
	}
	return 0;
}

/* The current Proc's error string, for the Zig side. */
char*
h9_kern_errstr(void)
{
	return up->nerrlab ? up->errstr : up->syserrstr;
}

/*
 * fd2path: drawterm's _sysfd2path passes an uninitialised
 * length and has no sys* wrapper.
 */
int
h9_fd2path(int fd, char *buf, uint nbuf)
{
	Chan *c;

	if(waserror()){
		char *p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	c = fdtochan(fd, -1, 0, 1);
	snprint(buf, nbuf, "%s", chanpath(c));
	cclose(c);
	poperror();
	return 0;
}
