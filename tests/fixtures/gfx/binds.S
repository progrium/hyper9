// The window's files are in /dev (tests/backends.zig, design/0015-gfx.md):
// stats /dev/draw/new, /dev/mouse, /dev/cursor and /dev/kbd, which it
// does without opening the screen.

#include "lib.S"

.macro STATS step, name
	adr x1, \name
	add x2, sp, #64
	mov x3, #256
	SYS 42			// stat
	CHECK \step
.endm

	STATS 0, draw
	STATS 1, mouse
	STATS 2, cursor
	STATS 3, kbd
	b ok
draw:	.asciz "/dev/draw/new"
mouse:	.asciz "/dev/mouse"
cursor:	.asciz "/dev/cursor"
kbd:	.asciz "/dev/kbd"
	.balign 4
