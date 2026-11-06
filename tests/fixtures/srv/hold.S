// Posts a pipe end as /srv/m, waits while another machine looks for it,
// then opens it (tests/backends.zig, design/0008-devsrv.md).

#include "lib.S"

	add x1, sp, #64
	SYS 21			// pipe
	CHECK 0
	ldr w2, [sp, #64]
	add w2, w2, #'0'
	strb w2, [sp, #80]
	adr x1, path
	mov x2, #1		// OWRITE
	mov x3, #0x180		// 0600
	SYS 22			// create
	CHECK 1
	mov x1, x0
	add x2, sp, #80
	mov x3, #1
	mov x4, #-1
	SYS 51			// post fds[0]
	CHECK 2
	mov x1, #3000
	SYS 17			// sleep
	adr x1, path
	mov x2, #2		// ORDWR
	SYS 14			// open
	CHECK 3
	b ok
path:	.asciz "/srv/m"
	.balign 4
