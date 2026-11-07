/*
 * Coroutines on JSPI: see coro.h and design/0012-browser-host.md.
 *
 * wasm globals aren't per stack, so a park saves and restores everything
 * that's per thread on native hosts: the shadow stack pointer, errno and
 * h9's Zig threadlocals. drawterm's up lives in the coroutine itself
 * (os-wasm.c's _getproc). A longjmp unwinds only within one coroutine's
 * stack, since kern's error labels never cross a kernel process.
 *
 * wasm has no guard pages, so each stack has a canary at its low end, and
 * a park and a coroutine's exit also compare the stack pointer with the
 * low end. Either check failing panics the machine with the coroutine's
 * name instead of letting it corrupt the memory below.
 */

#include <errno.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "coro.h"

#define IMPORT(n) __attribute__((import_module("h9"), import_name(#n)))
#define EXPORT(n) __attribute__((export_name(#n)))

/* JS host imports (h9-web.js). park and yield are Suspending. */
IMPORT(park) int js_park(int id, int ms);
IMPORT(unpark) void js_unpark(int id);
IMPORT(start) void js_start(H9coro *c);
IMPORT(yield) void js_yield(void);
IMPORT(sleep) void js_sleep(int ms);
IMPORT(panic) void js_panic(char *msg, int n);

uintptr_t h9_get_sp(void);
void h9_set_sp(uintptr_t);
/* src/kern.zig: saves or restores h9's per-thread state. */
void h9_web_locals(int save, void **slots);

enum {
	Canary = 0xC0DEC0DEu,
	/* Room a park needs below its own frame, for the check itself. */
	Slack = 256,
};

/* The first coroutine runs _start on the linker's stack. */
extern unsigned char __stack_low[], __stack_high[];
static H9coro maincoro = { .id = 0, .name = "main" };
static H9coro *cur;
static H9coro *freelist;
static int nextid = 1;

H9coro*
h9_coro_self(void)
{
	if(cur == NULL){
		maincoro.lo = __stack_low;
		maincoro.hi = __stack_high;
		maincoro.size = maincoro.hi - maincoro.lo;
		*(uint32_t*)maincoro.lo = Canary;
		cur = &maincoro;
	}
	return cur;
}

void
h9_coro_panic(char *msg)
{
	js_panic(msg, strlen(msg));
	__builtin_trap();
}

static void
check(H9coro *c)
{
	char buf[96];
	uintptr_t sp;
	unsigned long depth;

	sp = h9_get_sp();
	if(*(uint32_t*)c->lo == Canary && sp >= (uintptr_t)c->lo + Slack && sp <= (uintptr_t)c->hi){
		depth = (uintptr_t)c->hi - sp;
		if(depth > c->maxdepth)
			c->maxdepth = depth;
		return;
	}
	snprintf(buf, sizeof buf, "kernel stack overflow in %s", c->name);
	h9_coro_panic(buf);
}

/* The deepest stack use of any coroutine so far, at a park. */
static unsigned long maxdepth;

EXPORT(h9_coro_maxdepth) unsigned long
h9_coro_maxdepth(void)
{
	return maxdepth;
}

/*
 * Before and after any Suspending import: saves what's per thread, and
 * once the import returns, with the stack pointer already set back with
 * h9_set_sp, restores it. park, yield and sleep do the same inline.
 */
void
h9_coro_save(H9coro *me)
{
	check(me);
	if(me->maxdepth > maxdepth)
		maxdepth = me->maxdepth;
	me->err = errno;
	h9_web_locals(1, me->zls);
}

void
h9_coro_restore(H9coro *me)
{
	cur = me;
	h9_web_locals(0, me->zls);
	errno = me->err;
}

int
h9_coro_park(long ms)
{
	H9coro *me;
	uintptr_t sp;
	int r;

	me = h9_coro_self();
	check(me);
	if(me->maxdepth > maxdepth)
		maxdepth = me->maxdepth;
	sp = h9_get_sp();
	me->err = errno;
	h9_web_locals(1, me->zls);
	r = js_park(me->id, ms < 0 ? -1 : (int)(ms > 0x7fffffff ? 0x7fffffff : ms));
	h9_set_sp(sp);
	cur = me;
	h9_web_locals(0, me->zls);
	errno = me->err;
	return r;
}

void
h9_coro_unpark(H9coro *c)
{
	js_unpark(c->id);
}

/* Lets every other coroutine, and the event loop, run. */
void
h9_coro_yield(void)
{
	H9coro *me;
	uintptr_t sp;

	me = h9_coro_self();
	check(me);
	sp = h9_get_sp();
	me->err = errno;
	h9_web_locals(1, me->zls);
	js_yield();
	h9_set_sp(sp);
	cur = me;
	h9_web_locals(0, me->zls);
	errno = me->err;
}

void
h9_coro_sleep(long ms)
{
	H9coro *me;
	uintptr_t sp;

	me = h9_coro_self();
	check(me);
	sp = h9_get_sp();
	me->err = errno;
	h9_web_locals(1, me->zls);
	js_sleep(ms < 0 ? 0 : (int)ms);
	h9_set_sp(sp);
	cur = me;
	h9_web_locals(0, me->zls);
	errno = me->err;
}

/*
 * Starts fn(arg) on a new coroutine, once the caller next parks or
 * yields: the JS host runs it from the event loop. Stacks are reused
 * once their coroutine has ended, since wasm memory never shrinks.
 */
H9coro*
h9_coro_spawn(char *name, void (*fn)(void*), void *arg, unsigned long stk)
{
	static unsigned long override = 1;
	H9coro *c, **l;
	char *s;

	/* H9_TEST_KSTACK sets every stack's size, for the overflow case. */
	if(override == 1){
		s = getenv("H9_TEST_KSTACK");
		override = s != NULL ? strtoul(s, NULL, 0) : 0;
	}
	if(override >= 4096)
		stk = override;
	stk = (stk + 15) & ~15UL;
	c = NULL;
	for(l = &freelist; *l != NULL; l = &(*l)->next)
		if((*l)->size >= stk){
			c = *l;
			*l = c->next;
			break;
		}
	if(c == NULL){
		c = calloc(1, sizeof *c);
		if(c == NULL)
			return NULL;
		c->lo = aligned_alloc(16, stk);
		if(c->lo == NULL){
			free(c);
			return NULL;
		}
		c->size = stk;
		c->hi = c->lo + stk;
		c->id = nextid++;
	}
	snprintf(c->name, sizeof c->name, "%s", name);
	c->fn = fn;
	c->arg = arg;
	c->proc = NULL;
	c->err = 0;
	memset(c->zls, 0, sizeof c->zls);
	c->done = 0;
	c->maxdepth = 0;
	c->next = NULL;
	*(uint32_t*)c->lo = Canary;
	js_start(c);
	return c;
}

/* Ends the calling coroutine, from any depth. */
void
h9_coro_exit(void)
{
	H9coro *me;

	me = h9_coro_self();
	if(me->exitjb == NULL)
		h9_coro_panic("h9_coro_exit outside a coroutine");
	longjmp(*(jmp_buf*)me->exitjb, 1);
}

/* Runs on c's own stack, which h9_coro_entry has switched to. */
static __attribute__((noinline)) void
run(H9coro *c)
{
	jmp_buf jb;

	c->exitjb = &jb;
	if(setjmp(jb) == 0)
		c->fn(c->arg);
	check(c);
	c->exitjb = NULL;
	c->done = 1;
	/*
	 * Nothing runs on this stack after the return, and nothing else runs
	 * until it, so it can go on the free list now.
	 */
	c->next = freelist;
	freelist = c;
}

/*
 * Called by the JS host, through WebAssembly.promising, on a new wasm
 * stack. It has no frame of its own on the shadow stack, whose pointer
 * holds whatever the last coroutine to run left there until it's set.
 */
EXPORT(h9_coro_entry) void
h9_coro_entry(H9coro *c)
{
	h9_set_sp((uintptr_t)c->hi);
	cur = c;
	h9_web_locals(0, c->zls);
	run(c);
}

/* The coroutine's name, for the JS host's diagnostics. */
EXPORT(h9_coro_name) char*
h9_coro_name(H9coro *c)
{
	return c->name;
}
