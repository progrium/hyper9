/*
 * For "an RFMEM process can use pages another one just grew" in
 * tests/integration.zig. The parent grows the shared data segment with
 * sbrk and hands the new memory to an rfork(RFPROC|RFMEM) child that's
 * spinning in user mode, with no syscall in between, as a libthread
 * proc does with a block another proc's malloc just got. The child
 * writes to it. On a backend that maps new pages into an address space
 * only when its process next enters the kernel, the child's write
 * faults ("sys: trap: fault write").
 *
 * rfgrow [rounds [bytes]]: each round grows the segment by `bytes`
 * (default 1MB, more than the headroom the break keeps), so every
 * round maps new pages. 64 rounds of 1MB also check that a process can
 * have more than 64MB of data.
 */
#include <u.h>
#include <libc.h>

uchar*	block;
long	round;
long	done;

void
main(int argc, char **argv)
{
	long i, n, rounds;
	uchar *p;
	vlong t;

	rounds = 64;
	n = 1<<20;
	if(argc > 1)
		rounds = atol(argv[1]);
	if(argc > 2)
		n = atol(argv[2]);
	switch(rfork(RFPROC|RFMEM)){
	case -1:
		sysfatal("rfork: %r");
	case 0:
		for(i = 1; i <= rounds; i++){
			while(*(volatile long*)&round != i)
				;
			p = *(uchar* volatile*)&block;
			/* first and last page of the new memory */
			p[0] = i;
			p[n-1] = i;
			*(volatile long*)&done = i;
		}
		exits(nil);
	}
	for(i = 1; i <= rounds; i++){
		p = sbrk(n);
		if(p == (void*)-1)
			sysfatal("sbrk round %ld (%ld MB): %r", i, i*n>>20);
		*(uchar* volatile*)&block = p;
		*(volatile long*)&round = i;
		/* nsec is a syscall, which is fine here: only the child
		 * must stay in user mode. A child that faulted is gone. */
		t = nsec();
		while(*(volatile long*)&done != i)
			if(nsec() - t > 10*1000000000LL)
				sysfatal("round %ld: the child didn't answer", i);
		if(p[0] != (uchar)i || p[n-1] != (uchar)i)
			sysfatal("round %ld: child's write not seen", i);
	}
	free(wait());
	print("%ld rounds\n", rounds);
	exits(nil);
}
