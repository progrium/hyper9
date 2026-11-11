/*
 * tls386: what 32-bit Wine needs from i386 Linux's segments
 * (design/linux-i386.md, "TLS"). libc has TLS entry 6 for %gs, so
 * set_thread_area with entry -1 gives 7; %fs loaded with it reads its own
 * base while %gs keeps libc's; a new base reaches a loaded %fs; a signal
 * handler's return keeps %fs; and IRET and far RET return at ring 3, as
 * Wine's syscall return does. Prints "ok tls386", or what went wrong.
 * On other architectures it prints "ok tls386" and does nothing.
 */

#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>

#if defined(__i386__)
struct user_desc {
	unsigned int entry_number, base_addr, limit;
	unsigned int seg_32bit : 1, contents : 2, read_exec_only : 1, limit_in_pages : 1, seg_not_present : 1, useable : 1;
};

static unsigned int a[4] = { 0xa11a, 1, 2, 3 }, b[4] = { 0xb22b, 4, 5, 6 };
static volatile int handled;

static void onusr1(int sig) { handled = sig; }

static unsigned int fs0(void) {
	unsigned int v;
	__asm__ volatile("movl %%fs:0, %0" : "=r"(v));
	return v;
}

static int fail(const char *what) {
	printf("FAIL tls386: %s\n", what);
	return 1;
}

int main(void) {
	struct user_desc d = { .entry_number = -1, .base_addr = (unsigned int)a, .limit = 0xfff, .seg_32bit = 1 };
	unsigned short gs, fs;

	if (syscall(SYS_set_thread_area, &d) != 0) return fail("set_thread_area -1");
	if (d.entry_number != 7) {
		printf("FAIL tls386: entry %u, not 7\n", d.entry_number);
		return 1;
	}
	fs = d.entry_number << 3 | 3;
	__asm__ volatile("movw %0, %%fs" : : "r"(fs));
	if (fs0() != 0xa11a) return fail("%fs doesn't read entry 7's base");
	__asm__ volatile("movw %%gs, %0" : "=r"(gs));
	if (gs != (6 << 3 | 3)) return fail("%gs isn't libc's entry 6");
	if (getpid() <= 0) return fail("libc's TLS"); /* errno through %gs */

	/* Wine sets each thread's base again on the entry it was given. */
	d.base_addr = (unsigned int)b;
	if (syscall(SYS_set_thread_area, &d) != 0) return fail("set_thread_area 7");
	__asm__ volatile("movw %0, %%fs" : : "r"(fs));
	if (fs0() != 0xb22b) return fail("%fs doesn't read entry 7's new base");

	struct user_desc g = { .entry_number = 7 };
	if (syscall(SYS_get_thread_area, &g) != 0 || g.base_addr != (unsigned int)b) return fail("get_thread_area 7");
	struct user_desc e = { .entry_number = -1, .base_addr = (unsigned int)a, .limit = 0xfff, .seg_32bit = 1 };
	if (syscall(SYS_set_thread_area, &e) != 0 || e.entry_number != 8) return fail("the third entry");
	struct user_desc f = { .entry_number = -1 };
	if (syscall(SYS_set_thread_area, &f) == 0) return fail("a fourth entry");

	signal(SIGUSR1, onusr1);
	kill(getpid(), SIGUSR1);
	unsigned short after;
	__asm__ volatile("movw %%fs, %0" : "=r"(after));
	if (!handled || after != fs || fs0() != 0xb22b) return fail("%fs after a signal handler");

	/* IRET to the same privilege: EIP, CS and EFLAGS from the stack. */
	unsigned int got = 0;
	__asm__ volatile(
		"pushfl\n\t"
		"orl $1, (%%esp)\n\t"     /* CF set by the IRET */
		"pushl %%cs\n\t"
		"pushl $1f\n\t"
		"clc\n\t"
		"iret\n"
		"1:\n\t"
		"setc %b0\n\t"
		: "+q"(got) : : "cc", "memory");
	if (got != 1) return fail("IRET");
	got = 0;
	__asm__ volatile(
		"pushl %%cs\n\t"
		"pushl $1f\n\t"
		"lret\n"
		"1:\n\t"
		"movl $1, %0\n\t"
		: "=r"(got) : : "memory");
	if (got != 1) return fail("far RET");
	printf("ok tls386\n");
	return 0;
}
#else
int main(void) {
	printf("ok tls386\n");
	return 0;
}
#endif
