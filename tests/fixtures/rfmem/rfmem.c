/*
 * For "RFMEM processes see each other's writes" in tests/integration.zig
 * (design/0012-browser-host.md). A parent and an rfork(RFPROC|RFMEM)
 * child spin on words in their shared data segment, without a syscall,
 * so each sees the other's write only through shared memory, and only
 * once preemption lets the other run.
 */
#include <u.h>
#include <libc.h>

enum { Rounds = 100 };

long	ping;
long	pong;

void
main(void)
{
	int i;

	switch(rfork(RFPROC|RFMEM)){
	case -1:
		sysfatal("rfork: %r");
	case 0:
		for(i = 1; i <= Rounds; i++){
			while(*(volatile long*)&ping != i)
				;
			*(volatile long*)&pong = i;
		}
		exits(nil);
	}
	for(i = 1; i <= Rounds; i++){
		*(volatile long*)&ping = i;
		while(*(volatile long*)&pong != i)
			;
	}
	free(wait());
	print("%ld %ld\n", ping, pong);
	exits(nil);
}
