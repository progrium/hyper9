/*
 * h9's replacement for drawterm's main.c and cpu.c: boots drawterm's kern
 * without a cpu connection. The screen is src/kern/gfx.c with a GUI
 * backend, or src/kern/nogfx.c without one (design/0015-gfx.md). See SPEC.md,
 * "Kernel: drawterm kern/ and the Zig seam".
 */

#include "u.h"

#if !defined(WINDOWS) && !defined(H9_WEB)
#include <pthread.h>
#include <time.h>
#endif

#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#include "user.h"

#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "screen.h"
#include "tsleep.h"

#if !defined(WINDOWS) && !defined(H9_WEB)
#include <pwd.h>
#endif

char *argv0;
extern ulong kerndate;

/* Compose sequences only matter for GUI keyboard input. */
long latin1(Rune *k, int n) { USED(k, n); return -1; }

/* devtls's in-kernel factotum path, unused: a guest runs its own factotum and posts it in /srv (design/0008-devsrv.md). */
void *auth_allocrpc(int afd) { USED(afd); werrstr("no factotum"); return nil; }
void auth_freerpc(void *rpc) { USED(rpc); }
int auth_rpc(void *rpc, char *verb, void *a, int n) { USED(rpc, verb, a, n); return -1; }

#if defined(WINDOWS) || defined(H9_WEB)
extern char *h9_hostuser(void);	/* glue-win32.c, os-wasm.c */
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

/*
 * fauth(fd, aname), as 9front's sysfauth (port/auth.c): sends Tauth over
 * the 9P channel on fd with devmnt's mntauth, and returns a new fd, close
 * on exec, on the auth channel; or -1 with the error string set, which is
 * the server's ("authentication not required", say) when it refuses.
 * design/0008-devsrv.md.
 */
int
h9_fauth(int fd, char *aname)
{
	Chan *c, *ac;

	if(waserror()){
		char *p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	aname = validnamedup(aname, 1);
	if(waserror()){
		free(aname);
		nexterror();
	}
	c = fdtochan(fd, ORDWR, 0, 1);
	if(waserror()){
		cclose(c);
		nexterror();
	}

	ac = mntauth(c, aname);
	/* at this point ac is responsible for keeping c alive */
	poperror();	/* c */
	cclose(c);
	poperror();	/* aname */
	free(aname);

	if(waserror()){
		cclose(ac);
		nexterror();
	}
	/* always mark it close on exec */
	fd = newfd(ac, OCEXEC);
	if(fd < 0)
		error(Enofd);
	poperror();	/* ac */
	poperror();
	up->notepending = 0;
	return fd;
}

#if !defined(WINDOWS) && !defined(H9_WEB)
/*
 * The host side of tsleep's timer kproc (tsleep.c): a lock, and a wait on
 * a condition variable until a deadline on the monotonic clock. The
 * Windows version is in glue-win32.c, and the web host's in os-wasm.c.
 */
static pthread_mutex_t tmu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t tcond;

void
h9_tinit(void)
{
	pthread_condattr_t a;

	pthread_condattr_init(&a);
#ifndef __APPLE__
	/* macOS has no clock attribute; its relative wait is on a monotonic clock. */
	pthread_condattr_setclock(&a, CLOCK_MONOTONIC);
#endif
	pthread_cond_init(&tcond, &a);
	pthread_condattr_destroy(&a);
}

uvlong
h9_tnow(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uvlong)ts.tv_sec*1000000000ULL + ts.tv_nsec;
}

void
h9_tlock(void)
{
	pthread_mutex_lock(&tmu);
}

void
h9_tunlock(void)
{
	pthread_mutex_unlock(&tmu);
}

void
h9_tsignal(void)
{
	pthread_cond_signal(&tcond);
}

void
h9_twait(uvlong when)
{
	struct timespec ts;
	uvlong now;

	if(when == 0){
		pthread_cond_wait(&tcond, &tmu);
		return;
	}
	now = h9_tnow();
	if(when <= now)
		return;
#ifdef __APPLE__
	when -= now;
	ts.tv_sec = when / 1000000000ULL;
	ts.tv_nsec = when % 1000000000ULL;
	pthread_cond_timedwait_relative_np(&tcond, &tmu, &ts);
#else
	ts.tv_sec = when / 1000000000ULL;
	ts.tv_nsec = when % 1000000000ULL;
	pthread_cond_timedwait(&tcond, &tmu, &ts);
#endif
}
#endif
