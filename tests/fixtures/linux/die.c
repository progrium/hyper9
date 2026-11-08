/* Dies the way its argument says: "term" by SIGTERM to itself, "segv" by a
 * fault, "handled" catches the fault in a SIGSEGV handler and exits 4. */
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
	}
	return 1;
}
