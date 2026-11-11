// Opens /dev/kbd and writes what one read of it returns to stdout
// (tests/backends.zig, design/gfx.md). The test types into the window
// until the run ends.

#include "lib.S"

	adr x1, kbd
	mov x2, #0		// OREAD
	SYS 14			// open
	CHECK 0
	mov x1, x0
	add x2, sp, #64
	mov x3, #64
	mov x4, #-1
	SYS 50			// pread
	CHECK 1
	mov x3, x0
	mov x1, #1
	add x2, sp, #64
	mov x4, #-1
	SYS 51			// pwrite to stdout
	CHECK 2
	b ok
kbd:	.asciz "/dev/kbd"
	.balign 4
