// Posts an fd on a host file opened ORCLOSE as /srv/f, closes its own fds
// and exits. The file goes only when the machine closes what's posted on
// its /srv as it ends (tests/backends.zig, design/0008-devsrv.md).

#include "lib.S"

	adr x1, file
	mov x2, #0x41		// OWRITE|ORCLOSE
	mov x3, #0x1a4		// 0644
	SYS 22			// create
	CHECK 0
	mov x19, x0
	add w2, w19, #'0'
	strb w2, [sp, #80]
	adr x1, srv
	mov x2, #1		// OWRITE
	mov x3, #0x180		// 0600
	SYS 22
	CHECK 1
	mov x20, x0
	mov x1, x20
	add x2, sp, #80
	mov x3, #1
	mov x4, #-1
	SYS 51			// post it
	CHECK 2
	mov x1, x20
	SYS 4
	CHECK 3
	mov x1, x19
	SYS 4			// the posted chan keeps the file
	CHECK 4
	adr x1, file
	mov x2, #0		// OREAD
	SYS 14
	CHECK 5
	b ok
file:	.asciz "/mnt/term/cwd/f"
srv:	.asciz "/srv/f"
	.balign 4
