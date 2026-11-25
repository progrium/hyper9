// Creates the file named by argv[1] and writes "up\n" to it, for the
// .fd mount cases (tests/backends.zig, design/fd-mounts.md).

#include "lib.S"

	ldr x1, [sp, #528]	// argv[1]
	mov x2, #1		// OWRITE
	mov x3, #0x1b4		// 0664
	SYS 22			// create
	CHECK 0
	mov x19, x0
	mov x1, x19
	adr x2, data
	mov x3, #3
	mov x4, #-1
	SYS 51			// pwrite
	CHECK 1
	mov x1, x19
	SYS 4			// close
	CHECK 2
	b ok
data:	.ascii "up\n"
	.balign 4
