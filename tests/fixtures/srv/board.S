// devsrv within one machine (tests/backends.zig, design/0008-devsrv.md):
// posting a pipe end, refusing a second post and a second create, reading
// what's written to the pipe through /srv, an ORCLOSE entry going with its
// fd, and a clone board whose entries go when its lease is closed.

#include "lib.S"

.macro MUSTFAIL step		// die at `step` unless the call failed; go on
	mov x28, #\step
	cmn x0, #1
	b.ne die
.endm
.macro POST fd			// write the fd number in [sp, #80] to fd
	mov x1, \fd
	add x2, sp, #80
	mov x3, #1
	mov x4, #-1
	SYS 51			// pwrite
.endm

	add x1, sp, #64		// int fds[2]
	SYS 21			// pipe
	CHECK 0
	ldr w2, [sp, #64]
	add w2, w2, #'0'
	strb w2, [sp, #80]	// fds[0], as a digit

	adr x1, srvx
	mov x2, #1		// OWRITE
	mov x3, #0x180		// 0600
	SYS 22			// create
	CHECK 1
	mov x19, x0
	POST x19
	CHECK 2
	POST x19		// a second post is refused
	MUSTFAIL 3
	adr x1, srvx
	mov x2, #1
	mov x3, #0x180
	SYS 22			// a second create too
	MUSTFAIL 4

	adr x1, srvx
	mov x2, #2		// ORDWR
	SYS 14			// open
	CHECK 5
	mov x20, x0
	ldr w1, [sp, #68]	// fds[1]
	adr x2, hi
	mov x3, #2
	mov x4, #-1
	SYS 51			// pwrite
	CHECK 6
	mov x1, x20
	add x2, sp, #96
	mov x3, #16
	mov x4, #-1
	SYS 50			// pread, through /srv/x
	CHECK 7
	mov x28, #8
	cmp x0, #2
	b.ne die
	ldrh w2, [sp, #96]
	mov w3, #0x6968		// "hi"
	cmp w2, w3
	b.ne die

	adr x1, srvz
	mov x2, #0x41		// OWRITE|ORCLOSE
	mov x3, #0x180
	SYS 22
	CHECK 9
	mov x21, x0
	POST x21
	CHECK 10
	mov x1, x21
	SYS 4			// close: the entry goes
	CHECK 11
	adr x1, srvz
	mov x2, #0
	SYS 14
	MUSTFAIL 12

	adr x1, clone
	mov x2, #0		// OREAD
	SYS 14
	CHECK 13
	mov x22, x0
	// "/srv/" then the board's name, at sp+128
	mov w2, #'/'
	strb w2, [sp, #128]
	mov w2, #'s'
	strb w2, [sp, #129]
	mov w2, #'r'
	strb w2, [sp, #130]
	mov w2, #'v'
	strb w2, [sp, #131]
	mov w2, #'/'
	strb w2, [sp, #132]
	mov x1, x22
	add x2, sp, #133
	mov x3, #16
	mov x4, #-1
	SYS 50			// read the lease: the board's name
	CHECK 14
	add x3, sp, #133
	add x3, x3, x0
	mov w2, #'/'
	strb w2, [x3]
	mov w2, #'y'
	strb w2, [x3, #1]
	strb wzr, [x3, #2]
	add x1, sp, #128
	mov x2, #1
	mov x3, #0x180
	SYS 22			// create /srv/<board>/y
	CHECK 15
	mov x23, x0
	POST x23
	CHECK 16
	add x1, sp, #128
	mov x2, #2
	SYS 14			// open /srv/<board>/y
	CHECK 17
	mov x1, x0
	SYS 4
	mov x1, x22
	SYS 4			// close the lease
	CHECK 18
	add x1, sp, #128
	mov x2, #2
	SYS 14			// the board and its entry are gone
	MUSTFAIL 19
	b ok
srvx:	.asciz "/srv/x"
srvz:	.asciz "/srv/z"
clone:	.asciz "/srv/clone"
hi:	.asciz "hi"
	.balign 4
