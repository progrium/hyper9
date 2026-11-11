/*
 * tsleep: sleep with a timeout, with 9front's contract (port/proc.c),
 * built only on drawterm's public sleep and wakeup. drawterm has no timers
 * and no tsleep. See design/semaphores.md.
 *
 * One timer kproc per kernel, started from h9_proc_boot, keeps a list of
 * deadlines sorted by host monotonic time, and waits on a host condition
 * variable (glue.c, glue-win32.c) until the earliest one or until an
 * earlier one is added. tsleep puts a timer on its own stack into the
 * list and sleeps until the timer has fired or its condition is true. At
 * the deadline the timer kproc marks the timer fired and calls wakeup on
 * its Rendez, as 9front's twakeup does.
 *
 * The list is guarded by the host lock (h9_tlock), which the timer kproc
 * holds while it calls wakeup. tsleep always takes the timer out under
 * that lock before it returns, including when a note interrupts it, so no
 * timer is touched after its stack frame is gone. Lock order: the host
 * lock, then a Rendez's lock; nothing takes them the other way round.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "tsleep.h"

typedef struct Timer Timer;
struct Timer
{
	Timer	*next;
	uvlong	when;		/* host monotonic ns */
	Rendez	*r;
	int	(*fn)(void*);
	void	*arg;
	int	fired;		/* set by the timer kproc, under the host lock */
	int	queued;		/* in the list; under the host lock */
};

static Timer *timers;	/* sorted by when; under the host lock */
static int ntimers;	/* for the unit test */

/* sleep's condition: the timer has fired, or the caller's is true. */
static int
tfn(void *v)
{
	Timer *t;

	t = v;
	return __atomic_load_n(&t->fired, __ATOMIC_SEQ_CST) || t->fn(t->arg);
}

static void
tadd(Timer *t)
{
	Timer **l;

	h9_tlock();
	for(l = &timers; *l != nil && (*l)->when <= t->when; l = &(*l)->next)
		;
	t->next = *l;
	*l = t;
	t->queued = 1;
	ntimers++;
	/* A new earliest deadline: the kproc waits for a later one. */
	if(timers == t)
		h9_tsignal();
	h9_tunlock();
}

static void
tdel(Timer *t)
{
	Timer **l;

	h9_tlock();
	if(t->queued){
		for(l = &timers; *l != nil; l = &(*l)->next)
			if(*l == t){
				*l = t->next;
				break;
			}
		t->queued = 0;
		ntimers--;
	}
	h9_tunlock();
}

/* The timer kproc. */
static void
timerproc(void *v)
{
	Timer *t;
	uvlong now;

	USED(v);
	h9_tlock();
	for(;;){
		now = h9_tnow();
		while((t = timers) != nil && t->when <= now){
			timers = t->next;
			t->queued = 0;
			ntimers--;
			__atomic_store_n(&t->fired, 1, __ATOMIC_SEQ_CST);
			wakeup(t->r);
		}
		h9_twait(timers != nil ? timers->when : 0);
	}
}

void
h9_tsleepinit(void)
{
	h9_tinit();
	kproc("timer", timerproc, nil);
}

/*
 * Sleeps on r until fn(arg) is true or ms milliseconds have passed, as
 * 9front's tsleep. Like sleep, it raises "interrupted" if a note arrives.
 */
void
tsleep(Rendez *r, int (*fn)(void*), void *arg, ulong ms)
{
	Timer t;

	memset(&t, 0, sizeof t);
	t.when = h9_tnow() + (uvlong)ms*1000000ULL;
	t.r = r;
	t.fn = fn;
	t.arg = arg;
	tadd(&t);
	if(waserror()){
		tdel(&t);
		nexterror();
	}
	sleep(r, tfn, &t);
	tdel(&t);
	poperror();
}

/*
 * For the unit test in src/kern.zig: a flag to sleep on, the number of
 * timers in the list, and the host monotonic clock.
 */
typedef struct Tflag Tflag;
struct Tflag
{
	Rendez	r;
	int	set;
};

static int
isset(void *v)
{
	return __atomic_load_n(&((Tflag*)v)->set, __ATOMIC_SEQ_CST);
}

void*
h9_tflag_new(void)
{
	return mallocz(sizeof(Tflag), 1);
}

void
h9_tflag_free(void *f)
{
	free(f);
}

void
h9_tflag_set(void *v)
{
	Tflag *f;

	f = v;
	__atomic_store_n(&f->set, 1, __ATOMIC_SEQ_CST);
	wakeup(&f->r);
}

/* tsleep on the flag: 1 if it was set, 0 if not (a timeout), -1 if interrupted. */
int
h9_tflag_sleep(void *v, ulong ms)
{
	Tflag *f;

	f = v;
	if(waserror()){
		char *p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	tsleep(&f->r, isset, f, ms);
	poperror();
	return isset(f);
}

int
h9_ntimers(void)
{
	int n;

	h9_tlock();
	n = ntimers;
	h9_tunlock();
	return n;
}

uvlong
h9_kern_nanomono(void)
{
	return h9_tnow();
}
