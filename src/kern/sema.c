/*
 * rendezvous and semaphores. See design/semaphores.md.
 *
 * The semaphore code is 9front's (port/sysproc.c at the pinned release),
 * ported closely, races and comments included, since it was checked with
 * spin. It differs in two ways:
 *
 * - The wait lists live in a kernel-wide table of hashed buckets, each with
 *   its own lock, rather than in the segment, keyed by the host address of
 *   the semaphore word. Every address space sharing a segment maps the
 *   same host pages, and a segment's pages never move (src/segment.zig),
 *   so the host address names the same semaphore in every sharer, as
 *   9front's (segment, address) pair does. Machines never share guest
 *   pages, so one table serves them all.
 * - The value is a 32-bit word (Plan 9's long) in host memory that backs
 *   guest memory, changed with host atomics. That memory is what the
 *   guest's own loads, stores and exclusives see.
 *
 * The callers (src/syscall.zig) have checked the address: it's aligned,
 * mapped and writable, and stays valid while the caller is blocked.
 *
 * rendezvous is 9front's sysrendezvous on drawterm's Rgrp and Proc fields,
 * so drawterm's procinterrupt pulls a process out of it as before. Unlike
 * drawterm's _sysrendezvous it checks for a pending note before it sleeps:
 * a note that arrives after the call starts but before the process is on
 * the hash list would otherwise not wake it.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "tsleep.h"

#define coherence()	__atomic_thread_fence(__ATOMIC_SEQ_CST)

/* A word the guest also changes: only ever accessed atomically. */
static int
cmpswap(long *addr, long old, long new)
{
	return __atomic_compare_exchange_n(addr, &old, new, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}

static long
semvalue(long *addr)
{
	return __atomic_load_n(addr, __ATOMIC_SEQ_CST);
}

typedef struct Sema Sema;
typedef struct Semq Semq;

struct Sema
{
	Rendez	r;
	long	*addr;
	int	waiting;
	Sema	*next;
	Sema	*prev;
};

/* A bucket: a circular list of waiters, with head as its sentinel. */
struct Semq
{
	Lock	lk;
	Sema	head;
};

enum
{
	NSEMQ	= 64,
};

static Semq semtab[NSEMQ];

/* Called once at boot, from h9_proc_boot (proc.c). */
void
h9_semainit(void)
{
	int i;

	for(i = 0; i < NSEMQ; i++)
		semtab[i].head.next = semtab[i].head.prev = &semtab[i].head;
}

static Semq*
semq(long *a)
{
	uintptr h;

	h = (uintptr)a >> 2;
	h ^= h >> 6;
	return &semtab[h % NSEMQ];
}

static int
waiting(Sema *p)
{
	return __atomic_load_n(&p->waiting, __ATOMIC_SEQ_CST);
}

static void
setwaiting(Sema *p, int v)
{
	__atomic_store_n(&p->waiting, v, __ATOMIC_SEQ_CST);
}

/*
 * The implementation of semaphores is complicated by needing
 * to avoid rescheduling in syssemrelease, so that it is safe
 * to call from real-time processes.  This means syssemrelease
 * cannot acquire any qlocks, only spin locks.
 *
 * Semacquire and semrelease must both manipulate the semaphore
 * wait list.  Lock-free linked lists only exist in theory, not
 * in practice, so the wait list is protected by a spin lock.
 *
 * The semaphore value *addr is stored in user memory, so it
 * cannot be read or written while holding spin locks.
 *
 * Thus, we can access the list only when holding the lock, and
 * we can access the semaphore only when not holding the lock.
 * This makes things interesting.  Note that sleep's condition function
 * is called while holding two locks - r and up->rlock - so it cannot
 * access the semaphore value either.
 *
 * An acquirer announces its intention to try for the semaphore
 * by putting a Sema structure onto the wait list and then
 * setting Sema.waiting.  After one last check of semaphore,
 * the acquirer sleeps until Sema.waiting==0.  A releaser of n
 * must wake up n acquirers who have Sema.waiting set.  It does
 * this by clearing Sema.waiting and then calling wakeup.
 *
 * There are three interesting races here.

 * The first is that in this particular sleep/wakeup usage, a single
 * wakeup can rouse a process from two consecutive sleeps!
 * The ordering is:
 *
 * 	(a) set Sema.waiting = 1
 * 	(a) call sleep
 * 	(b) set Sema.waiting = 0
 * 	(a) check Sema.waiting inside sleep, return w/o sleeping
 * 	(a) try for semaphore, fail
 * 	(a) set Sema.waiting = 1
 * 	(a) call sleep
 * 	(b) call wakeup(a)
 * 	(a) wake up again
 *
 * This is okay - semacquire will just go around the loop
 * again.  It does mean that at the top of the for(;;) loop in
 * semacquire, phore.waiting might already be set to 1.
 *
 * The second is that a releaser might wake an acquirer who is
 * interrupted before he can acquire the lock.  Since
 * release(n) issues only n wakeup calls -- only n can be used
 * anyway -- if the interrupted process is not going to use his
 * wakeup call he must pass it on to another acquirer.
 *
 * The third race is similar to the second but more subtle.  An
 * acquirer sets waiting=1 and then does a final canacquire()
 * before going to sleep.  The opposite order would result in
 * missing wakeups that happen between canacquire and
 * waiting=1.  (In fact, the whole point of Sema.waiting is to
 * avoid missing wakeups between canacquire() and sleep().) But
 * there can be spurious wakeups between a successful
 * canacquire() and the following semdequeue().  This wakeup is
 * not useful to the acquirer, since he has already acquired
 * the semaphore.  Like in the previous case, though, the
 * acquirer must pass the wakeup call along.
 *
 * This is all rather subtle.  The code below has been verified
 * with the spin model /sys/src/9/port/semaphore.p.  The
 * original code anticipated the second race but not the first
 * or third, which were caught only with spin.  The first race
 * is mentioned in /sys/doc/sleep.ps, but I'd forgotten about it.
 * It was lucky that my abstract model of sleep/wakeup still managed
 * to preserve that behavior.
 *
 * I remain slightly concerned about memory coherence
 * outside of locks.  The spin model does not take
 * queued processor writes into account so we have to
 * think hard.  The only variables accessed outside locks
 * are the semaphore value itself and the boolean flag
 * Sema.waiting.  The value is only accessed with cmpswap,
 * whose job description includes doing the right thing as
 * far as memory coherence across processors.  That leaves
 * Sema.waiting.  To handle it, we call coherence() before each
 * read and after each write.		- rsc
 */

/* Add semaphore p with addr a to its bucket's list. */
static void
semqueue(long *a, Sema *p)
{
	Semq *q;

	memset(p, 0, sizeof *p);
	p->addr = a;
	q = semq(a);
	lock(&q->lk);
	p->next = &q->head;
	p->prev = q->head.prev;
	p->next->prev = p;
	p->prev->next = p;
	unlock(&q->lk);
}

/* Remove semaphore p from its bucket's list. */
static void
semdequeue(Sema *p)
{
	Semq *q;

	q = semq(p->addr);
	lock(&q->lk);
	p->next->prev = p->prev;
	p->prev->next = p->next;
	unlock(&q->lk);
}

/* Wake up n waiters with addr a. */
static void
semwakeup(long *a, long n)
{
	Semq *q;
	Sema *p;

	q = semq(a);
	lock(&q->lk);
	for(p=q->head.next; p!=&q->head && n>0; p=p->next){
		if(p->addr == a && waiting(p)){
			setwaiting(p, 0);
			coherence();
			wakeup(&p->r);
			n--;
		}
	}
	unlock(&q->lk);
}

/* Add delta to semaphore and wake up waiters as appropriate. */
static long
semrelease(long *addr, long delta)
{
	long value;

	/* Wraps as 9front's does, without C's signed overflow. */
	do
		value = semvalue(addr);
	while(!cmpswap(addr, value, (long)((unsigned)value+(unsigned)delta)));
	semwakeup(addr, delta);
	return (long)((unsigned)value+(unsigned)delta);
}

/* Try to acquire semaphore using compare-and-swap */
static int
canacquire(long *addr)
{
	long value;

	while((value=semvalue(addr)) > 0)
		if(cmpswap(addr, value, value-1))
			return 1;
	return 0;
}

/* Should we wake up? */
static int
semawoke(void *p)
{
	coherence();
	return !waiting((Sema*)p);
}

/* Acquire semaphore (subtract 1). */
static int
semacquire(long *addr, int block)
{
	int acquired;
	Sema phore;

	if(canacquire(addr))
		return 1;
	if(!block)
		return 0;
	semqueue(addr, &phore);
	if(acquired = !waserror()){
		for(;;){
			setwaiting(&phore, 1);
			coherence();
			if(canacquire(addr))
				break;
			sleep(&phore.r, semawoke, &phore);
		}
		poperror();
	}
	semdequeue(&phore);
	coherence();	/* not strictly necessary due to lock in semdequeue */
	if(!waiting(&phore))
		semwakeup(addr, 1);
	if(!acquired)
		nexterror();
	return 1;
}

/*
 * Acquire semaphore or time-out. The deadline is taken from the monotonic
 * clock once, so spurious wakeups don't stretch the timeout.
 */
static int
tsemacquire(long *addr, ulong ms)
{
	int timedout, acquired;
	uvlong deadline, now;
	Sema phore;

	if(canacquire(addr))
		return 1;
	if(ms == 0)
		return 0;
	timedout = 0;
	deadline = h9_tnow() + (uvlong)ms*1000000ULL;
	semqueue(addr, &phore);
	if(acquired = !waserror()){
		for(;;){
			setwaiting(&phore, 1);
			coherence();
			if(canacquire(addr))
				break;
			tsleep(&phore.r, semawoke, &phore, ms);
			now = h9_tnow();
			if(now >= deadline){
				timedout = 1;
				break;
			}
			ms = (deadline - now + 999999) / 1000000;
		}
		poperror();
	}
	semdequeue(&phore);
	coherence();	/* not strictly necessary due to lock in semdequeue */
	if(!waiting(&phore))
		semwakeup(addr, 1);
	if(!acquired)
		nexterror();
	return !timedout;
}

/*
 * The sys*-style wrappers: each runs waserror, and on an error leaves the
 * message for errstr and returns -1. After a successful call the note
 * that interrupts calls is cleared, as drawterm's sys* wrappers do; the
 * note itself is still queued for delivery (proc.c).
 */
static int
syserr(void)
{
	char *p;

	p = up->syserrstr;
	up->syserrstr = up->errstr;
	up->errstr = p;
	return -1;
}

int
h9_semacquire(long *addr, int block)
{
	int r;

	if(waserror())
		return syserr();
	if(semvalue(addr) < 0)
		error(Ebadarg);
	r = semacquire(addr, block);
	poperror();
	up->notepending = 0;
	return r;
}

int
h9_tsemacquire(long *addr, ulong ms)
{
	int r;

	if(waserror())
		return syserr();
	if(semvalue(addr) < 0)
		error(Ebadarg);
	r = tsemacquire(addr, ms);
	poperror();
	up->notepending = 0;
	return r;
}

/* Returns the new value, or -1 with the error string set. */
int
h9_semrelease(long *addr, long count, long *value)
{
	if(waserror())
		return syserr();
	/* count == 0 is a no-op, not a release */
	if(count < 0 || semvalue(addr) < 0)
		error(Ebadarg);
	*value = semrelease(addr, count);
	poperror();
	return 0;
}

/*
 * 9front's sysrendezvous. Returns the other process's value, or ~0 if a
 * note interrupted the wait.
 */
uintptr
h9_rendezvous(uintptr tag, uintptr new)
{
	uintptr val;
	Proc *p, **l;

	l = &REND(up->rgrp, tag);

	lock(&up->rgrp->ref.lk);
	for(p = *l; p != nil; p = p->rendhash) {
		if((uintptr)p->rendtag == tag) {
			*l = p->rendhash;
			val = (uintptr)p->rendval;
			p->rendval = (void*)new;
			unlock(&up->rgrp->ref.lk);

			procwakeup(p);

			return val;
		}
		l = &p->rendhash;
	}

	/* Going to sleep here */
	up->rendtag = (void*)tag;
	up->rendval = (void*)new;
	up->rendhash = *l;
	*l = up;
	up->state = Rendezvous;
	/*
	 * procinterrupt sets notepending and then reads state; this sets
	 * state and then reads notepending. With a fence between each write
	 * and read, one of them sees the other's write: either procinterrupt
	 * finds this process on the list, or this sees the note.
	 */
	coherence();
	if(up->notepending){
		for(l = &REND(up->rgrp, tag); *l != nil; l = &(*l)->rendhash)
			if(*l == up){
				/* Still waiting: give up, without sleeping. */
				*l = up->rendhash;
				up->rendval = (void*)~(uintptr)0;
				up->state = Running;
				unlock(&up->rgrp->ref.lk);
				up->notepending = 0;
				return ~(uintptr)0;
			}
		/*
		 * Already taken off by a partner or by procinterrupt, under
		 * this lock; either calls procwakeup, so sleep for it.
		 */
	}
	unlock(&up->rgrp->ref.lk);

	procsleep();

	up->state = Running;
	/* As drawterm's sys* wrappers do after every call that returns. */
	up->notepending = 0;
	return (uintptr)up->rendval;
}
