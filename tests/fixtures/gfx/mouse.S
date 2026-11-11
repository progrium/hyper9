// Opens /dev/mouse and writes what one read of it returns to stdout
// (tests/backends.zig, design/gfx.md). The test acts on the window
// until the run ends: it moves the mouse and holds a button. The mouse
// moves only once there's a screen, so it opens that first.

#include "lib.S"

	adr x1, new
	add x2, sp, #128
	mov x3, #256
	SYS 42			// stat /dev/draw/new: the screen opens
	CHECK 3
	adr x1, mouse
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
mouse:	.asciz "/dev/mouse"
new:	.asciz "/dev/draw/new"
	.balign 4
