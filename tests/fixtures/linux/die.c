/* Dies the way its argument says: "term" by SIGTERM to itself, "segv" by a
 * fault, "handled" catches the fault in a SIGSEGV handler and exits 4.
 * "ill" runs an instruction no CPU has (UD2 on x86, UDF on arm64), which
 * is SIGILL, and "illhandled" catches it in a SIGILL handler and exits 5.
 * On arm64, "sve" runs an SVE instruction under a SIGILL handler, as
 * OpenSSL probes for SVE, and exits 5 when it's SIGILL. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void onsegv(int s, siginfo_t *si, void *uc) {
	(void)s; (void)uc;
	printf("caught SIGSEGV at %p\n", si->si_addr);
	fflush(stdout);
	_exit(4);
}

static void onill(int s, siginfo_t *si, void *uc) {
	(void)s; (void)uc;
	printf("caught SIGILL code %d\n", si->si_code);
	fflush(stdout);
	_exit(5);
}

static void ud2(void) {
#if defined(__x86_64__) || defined(__i386__)
	__asm__ volatile("ud2");
#elif defined(__aarch64__)
	__asm__ volatile(".inst 0x00000000"); /* udf #0 */
#endif
}

static void sve(void) {
#if defined(__aarch64__)
	__asm__ volatile(".inst 0x04a03000"); /* eor z0.d, z0.d, z0.d */
#endif
}

int main(int argc, char **argv) {
	const char *how = argc > 1 ? argv[1] : "term";
	if (strcmp(how, "term") == 0) {
		kill(getpid(), SIGTERM);
		pause();
	} else if (strcmp(how, "segv") == 0) {
		*(volatile int *)16 = 1;
	} else if (strcmp(how, "handled") == 0) {
		struct sigaction sa = {0};
		sa.sa_sigaction = onsegv;
		sa.sa_flags = SA_SIGINFO;
		sigaction(SIGSEGV, &sa, 0);
		*(volatile int *)32 = 1;
	} else if (strcmp(how, "ill") == 0) {
		ud2();
	} else if (strcmp(how, "illhandled") == 0) {
		struct sigaction sa = {0};
		sa.sa_sigaction = onill;
		sa.sa_flags = SA_SIGINFO;
		sigaction(SIGILL, &sa, 0);
		ud2();
	} else if (strcmp(how, "sve") == 0) {
		struct sigaction sa = {0};
		sa.sa_sigaction = onill;
		sa.sa_flags = SA_SIGINFO;
		sigaction(SIGILL, &sa, 0);
		sve();
	}
	return 1;
}
