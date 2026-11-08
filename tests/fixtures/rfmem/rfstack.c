/*
 * For "rfork with RFMEM shares data and bss but not the stack" in
 * tests/integration.zig (design/0095-native-backend.md). An rfork(RFPROC|RFMEM)
 * child writes a data word, a bss word and a local on its stack; the
 * parent sees the first two and not the third.
 */
#include <u.h>
#include <libc.h>

long	data = 1;
long	bss;

void
main(void)
{
	long local;

	local = 1;
	switch(rfork(RFPROC|RFMEM)){
	case -1:
		sysfatal("rfork: %r");
	case 0:
		data = 2;
		bss = 3;
		local = 4;
		exits(nil);
	}
	waitpid();
	print("%ld %ld %ld\n", data, bss, local);
	exits(nil);
}
