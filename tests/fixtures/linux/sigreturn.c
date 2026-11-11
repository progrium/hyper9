/* rt_sigreturn takes only what a user program may set
 * (design/linux-personality.md, "Signals"): a handler rewrites its
 * frame to ask for kernel privilege (EL1h with interrupts masked on arm64,
 * the kernel's code and stack selectors on amd64 and 386), and the
 * program must
 * come back at user level with its own selectors. */
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

static volatile int handled;

static void onusr1(int s, siginfo_t *si, void *p) {
	(void)s; (void)si;
	ucontext_t *uc = p;
#if defined(__aarch64__)
	uc->uc_mcontext.pstate = 0x3c5; /* EL1h, DAIF set */
#elif defined(__x86_64__)
	/* REG_CSGSFS holds cs, gs, fs and ss, 16 bits each. */
	uc->uc_mcontext.gregs[REG_CSGSFS] = 0x0010000000000008ull;
	uc->uc_mcontext.gregs[REG_EFL] |= 3 << 12; /* IOPL 3 */
#elif defined(__i386__)
	uc->uc_mcontext.gregs[REG_CS] = 0x08;
	uc->uc_mcontext.gregs[REG_SS] = 0x10;
	uc->uc_mcontext.gregs[REG_EFL] |= 3 << 12; /* IOPL 3 */
#endif
	handled = 1;
}

int main(void) {
	unsigned long before = 0, after = 0, gs0 = 0, gs1 = 0;
#if defined(__x86_64__) || defined(__i386__)
	__asm__ volatile("mov %%cs, %0" : "=r"(before));
#endif
#if defined(__i386__)
	__asm__ volatile("mov %%gs, %0" : "=r"(gs0));
#endif
	struct sigaction sa = {0};
	sa.sa_sigaction = onusr1;
	sa.sa_flags = SA_SIGINFO;
	sigaction(SIGUSR1, &sa, 0);
	kill(getpid(), SIGUSR1);
#if defined(__x86_64__)
	__asm__ volatile("mov %%cs, %0" : "=r"(after));
	unsigned long fl;
	__asm__ volatile("pushfq; pop %0" : "=r"(fl));
	if ((fl >> 12 & 3) != 0) printf("iopl %lu\n", fl >> 12 & 3);
#elif defined(__i386__)
	__asm__ volatile("mov %%cs, %0" : "=r"(after));
	__asm__ volatile("mov %%gs, %0" : "=r"(gs1));
	unsigned long fl;
	__asm__ volatile("pushfl; pop %0" : "=r"(fl));
	if ((fl >> 12 & 3) != 0) printf("iopl %lu\n", fl >> 12 & 3);
	if (gs0 != gs1) printf("gs %#lx, not %#lx\n", gs1, gs0);
#endif
	printf("handled %d, selectors %s\n", handled, before == after ? "kept" : "changed");
	return 0;
}
