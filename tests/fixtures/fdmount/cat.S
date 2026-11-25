// Copies the file named by argv[1] to fd 1, for the .fd mount cases
// (tests/engines.zig, design/epoch-0/fd-mounts.md).

#include "lib.S"

	ldr x1, [sp, #528]	// argv[1]
	mov x2, #0		// OREAD
	SYS 14			// open
	CHECK 0
	mov x19, x0
1:	mov x1, x19
	add x2, sp, #64
	mov x3, #256
	mov x4, #-1
	SYS 50			// pread
	CHECK 1
	cbz x0, 2f
	mov x3, x0
	mov x1, #1
	add x2, sp, #64
	mov x4, #-1
	SYS 51			// pwrite
	CHECK 2
	b 1b
2:	b ok
