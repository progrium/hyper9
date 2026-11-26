/*
 * drawterm's OS layer for the web host (design/epoch-0/browser-host.md),
 * built instead of kern/posix.c. Kernel processes are tasks on the web
 * host's one executor (src/kern/sched/web.zig): blocking parks one, and
 * the executor runs another. Everything runs on one thread, so a
 * contended spin lock is a bug, and lock() in libc/lock.c still works
 * since nothing preempts it.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include <errno.h>
#include <string.h>

typedef struct Htask Htask;
/* src/kern/sched/web.zig */
Htask*	h9_task_self(void);
Htask*	h9_task_spawn(char *name, void (*fn)(void*), void *arg);
int	h9_task_park(long ms);	/* 1 if unparked, 0 if the time ran out; ms < 0 waits */
void	h9_task_unpark(Htask*);
void	h9_task_yield(void);
void	h9_task_sleep(long ms);
void	h9_task_exit(void);
void*	h9_task_getproc(void);
void	h9_task_setproc(void*);

#define IMPORT(n) __attribute__((import_module("h9"), import_name(#n)))

IMPORT(now_ms) double js_now_ms(void);
IMPORT(mono_ms) double js_mono_ms(void);
IMPORT(random) void js_random(void *p, int n);

typedef struct Oproc Oproc;
struct Oproc
{
	int nsleep;
	int nwakeup;
	Htask *task;
};

Proc*
_getproc(void)
{
	return h9_task_getproc();
}

void
_setproc(Proc *p)
{
	h9_task_setproc(p);
	if(p != nil)
		((Oproc*)p->oproc)->task = h9_task_self();
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
	op->task = nil;
}

void
osmsleep(int ms)
{
	h9_task_sleep(ms);
}

void
osyield(void)
{
	h9_task_yield();
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
	if(h9_task_spawn(p->text, tramp, p) == nil)
		panic("osproc: no memory for a stack");
}

void
osexit(void)
{
	h9_task_setproc(nil);
	h9_task_exit();
}

void
procsleep(void)
{
	Oproc *op;

	op = (Oproc*)up->oproc;
	op->nsleep++;
	while(op->nsleep > op->nwakeup)
		h9_task_park(-1);
}

void
procwakeup(Proc *p)
{
	Oproc *op;

	op = (Oproc*)p->oproc;
	op->nwakeup++;
	if(op->nwakeup == op->nsleep && op->task != nil)
		h9_task_unpark(op->task);
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
static Htask *twaiter;
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
		h9_task_unpark(twaiter);
}

void
h9_twait(uvlong when)
{
	uvlong now;

	if(tsignalled){
		tsignalled = 0;
		return;
	}
	twaiter = h9_task_self();
	if(when == 0)
		h9_task_park(-1);
	else{
		now = h9_tnow();
		if(when > now)
			h9_task_park((long)((when - now + 999999) / 1000000));
	}
	twaiter = nil;
	tsignalled = 0;
}
