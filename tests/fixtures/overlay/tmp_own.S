// Writes /tmp/f, waits while another machine looks for it, then reads it
// back (tests/backends.zig, design/ephemeral-writes.md).

#include "lib.S"

	adr x1, path
	mov x2, #1		// OWRITE
	mov x3, #0x1b4	// 0664
	SYS 22			// create
	CHECK 0
	mov x19, x0
	mov x1, x19
	adr x2, data
	mov x3, #1
	mov x4, #0
	SYS 51			// pwrite
	CHECK 1
	mov x1, x19
	SYS 4			// close
	CHECK 2
	mov x1, #3000
	SYS 17			// sleep
	adr x1, path
	mov x2, #0		// OREAD
	SYS 14			// open
	CHECK 3
	b ok
path:	.asciz "/tmp/f"
data:	.asciz "a"
	.balign 4
