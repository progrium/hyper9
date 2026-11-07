// /dev/snarf (tests/backends.zig, design/0015-gfx.md): writes what it
// reads to stdout, then "|", then writes "guest" to it, and writes what
// it reads back to stdout.

#include "lib.S"

.macro READ step
	adr x1, snarf
	mov x2, #0		// OREAD
	SYS 14			// open
	CHECK \step
	mov x20, x0
	mov x1, x20
	add x2, sp, #64
	mov x3, #64
	mov x4, #0
	SYS 50			// pread
	CHECK \step + 1
	mov x3, x0
	mov x1, #1
	add x2, sp, #64
	mov x4, #-1
	SYS 51			// pwrite to stdout
	mov x1, x20
	SYS 4			// close
.endm

	READ 0
	mov x1, #1
	adr x2, bar
	mov x3, #1
	mov x4, #-1
	SYS 51
	adr x1, snarf
	mov x2, #1		// OWRITE
	SYS 14			// open
	CHECK 2
	mov x20, x0
	mov x1, x20
	adr x2, guest
	mov x3, #5
	mov x4, #-1
	SYS 51			// pwrite "guest"
	CHECK 3
	mov x1, x20
	SYS 4			// close: the clipboard gets it
	CHECK 4
	READ 5
	b ok
snarf:	.asciz "/dev/snarf"
bar:	.asciz "|"
guest:	.asciz "guest"
	.balign 4
