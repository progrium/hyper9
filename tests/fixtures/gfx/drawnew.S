// Reads /dev/draw/new and writes the 144 bytes of screen information to
// stdout (tests/backends.zig, design/gfx.md).

#include "lib.S"

	adr x1, new
	mov x2, #2		// ORDWR
	SYS 14			// open
	CHECK 0
	mov x1, x0
	add x2, sp, #64
	mov x3, #144
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
new:	.asciz "/dev/draw/new"
	.balign 4
