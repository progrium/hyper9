/*
 * drawterm's OS layer for the web host (design/browser-host.md),
 * built instead of kern/posix.c. Kernel processes are coroutines
 * (src/web/coro.c): blocking parks one and hands the event loop back to
 * the JS host. Everything runs on one thread, so a contended spin lock is
 * a bug, and lock() in libc/lock.c still works since nothing preempts it.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include <errno.h>
#include <string.h>

#include "../web/coro.h"

#define IMPORT(n) __attribute__((import_module("h9"), import_name(#n)))

IMPORT(now_ms) double js_now_ms(void);
IMPORT(mono_ms) double js_mono_ms(void);
IMPORT(random) void js_random(void *p, int n);

/*
 * The kernel process stack: the integration suite's deepest use at a park
 * (149 KiB, in a guest process's syscall path, Debug build), doubled and
 * rounded up (SPEC.md).
 */
enum { KSTACK = 320*1024 };

typedef struct Oproc Oproc;
struct Oproc
{
	int nsleep;
	int nwakeup;
	H9coro *coro;
};

Proc*
_getproc(void)
{
	return h9_coro_self()->proc;
}

void
_setproc(Proc *p)
{
	H9coro *c;

	c = h9_coro_self();
	c->proc = p;
	if(p != nil)
		((Oproc*)p->oproc)->coro = c;
}

void
osinit(void)
{
}

void
osnewproc(Proc *p)
{
	Oproc *op;

	op = (Oproc*)p->oproc;
	op->nsleep = 0;
	op->nwakeup = 0;
	op->coro = nil;
}

void
osmsleep(int ms)
{
	h9_coro_sleep(ms);
}

void
osyield(void)
{
	h9_coro_yield();
}

void
oserrstr(void)
{
	char *p;

	if((p = strerror(errno)) != nil)
		strecpy(up->errstr, up->errstr+ERRMAX, p);
	else
		snprint(up->errstr, ERRMAX, "wasi error %d", errno);
}

void
oserror(void)
{
	oserrstr();
	nexterror();
}

static void
tramp(void *vp)
{
	Proc *p;

	p = vp;
	_setproc(p);
	(*p->fn)(p->arg);
	pexit("", 0);
}

void
osproc(Proc *p)
{
	if(h9_coro_spawn(p->text, tramp, p, KSTACK) == nil)
		panic("osproc: no memory for a stack");
}

void
osexit(void)
{
	h9_coro_self()->proc = nil;
	h9_coro_exit();
}

void
procsleep(void)
{
	Oproc *op;

	op = (Oproc*)up->oproc;
	op->nsleep++;
	while(op->nsleep > op->nwakeup)
		h9_coro_park(-1);
}

void
procwakeup(Proc *p)
{
	Oproc *op;

	op = (Oproc*)p->oproc;
	op->nwakeup++;
	if(op->nwakeup == op->nsleep && op->coro != nil)
		h9_coro_unpark(op->coro);
}

void
randominit(void)
{
}

ulong
randomread(void *v, ulong n)
{
	uchar *p;
	ulong m;

	/* crypto.getRandomValues takes at most 64 KiB at a time. */
	for(p = v, m = n; m > 0; ){
		int k = m > 65536 ? 65536 : m;
		js_random(p, k);
		p += k;
		m -= k;
	}
	return n;
}

long
seconds(void)
{
	return (long)(js_now_ms() / 1000);
}

ulong
ticks(void)
{
	return (ulong)js_mono_ms();
}

long
showfilewrite(char *a, int n)
{
	USED(a, n);
	error("not implemented");
	return -1;
}

void
setterm(int raw)
{
	USED(raw);
}

/* No __builtin_return_address on wasm. */
uintptr
getcallerpc(void *a)
{
	USED(a);
	return 0;
}

/* glue.c's host user: there's no passwd database. */
char*
h9_hostuser(void)
{
	return "glenda";
}

/*
 * The host side of tsleep's timer kproc (tsleep.c), as glue.c has it for
 * POSIX: one waiter at a time, the timer kproc.
 */
static H9coro *twaiter;
static int tsignalled;

void
h9_tinit(void)
{
}

uvlong
h9_tnow(void)
{
	return (uvlong)(js_mono_ms() * 1000000.0);
}

void
h9_tlock(void)
{
}

void
h9_tunlock(void)
{
}

void
h9_tsignal(void)
{
	tsignalled = 1;
	if(twaiter != nil)
		h9_coro_unpark(twaiter);
}

void
h9_twait(uvlong when)
{
	uvlong now;

	if(tsignalled){
		tsignalled = 0;
		return;
	}
	twaiter = h9_coro_self();
	if(when == 0)
		h9_coro_park(-1);
	else{
		now = h9_tnow();
		if(when > now)
			h9_coro_park((long)((when - now + 999999) / 1000000));
	}
	twaiter = nil;
	tsignalled = 0;
}
