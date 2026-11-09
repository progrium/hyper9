// Binds #| on /mnt/temp and /mnt/wsys, as rio does, in a root tree that
// has neither: the namespace builder makes them in the root's overlay
// (tests/backends.zig, design/0015-gfx.md).

#include "lib.S"

	adr x1, pipe
	adr x2, temp
	mov x3, #0		// MREPL
	SYS 2			// bind
	CHECK 0
	adr x1, data
	mov x2, #2		// ORDWR
	SYS 14			// open
	CHECK 1
	adr x1, pipe
	adr x2, wsys
	mov x3, #0		// MREPL
	SYS 2			// bind
	CHECK 2
	b ok
pipe:	.asciz "#|"
temp:	.asciz "/mnt/temp"
data:	.asciz "/mnt/temp/data"
wsys:	.asciz "/mnt/wsys"
	.balign 4
