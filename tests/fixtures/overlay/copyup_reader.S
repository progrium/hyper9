// Opens f in an ephemeral cwd, and an rfork child writes it, copying it
// up; the parent's open fd still reads the old contents
// (tests/backends.zig, design/ephemeral-writes.md). A new open sees
// the child's write.

#include "lib.S"

	adr x1, path
	mov x2, #0		// OREAD
	SYS 14			// open
	CHECK 0
	mov x19, x0
	mov x1, #16		// RFPROC
	SYS 19			// rfork
	CHECK 1
	cbz x0, child
	add x1, sp, #256
	mov x2, #128
	SYS 47			// await
	CHECK 2
	mov x1, x19
	add x2, sp, #384
	mov x3, #3
	mov x4, #0
	SYS 50			// pread
	CHECK 3
	mov x28, #4
	add x6, sp, #384
	ldrb w5, [x6]
	cmp w5, #'o'
	b.ne die
	ldrb w5, [x6, #1]
	cmp w5, #'l'
	b.ne die
	ldrb w5, [x6, #2]
	cmp w5, #'d'
	b.ne die
	// A new open sees the child's write.
	adr x1, path
	mov x2, #0		// OREAD
	SYS 14			// open
	CHECK 7
	mov x1, x0
	add x2, sp, #384
	mov x3, #3
	mov x4, #0
	SYS 50			// pread
	CHECK 8
	mov x28, #9
	ldrb w5, [sp, #384]
	cmp w5, #'N'
	b.ne die
	b ok
child:
	adr x1, path
	mov x2, #2		// ORDWR
	SYS 14			// open
	CHECK 5
	mov x1, x0
	adr x2, new
	mov x3, #3
	mov x4, #0
	SYS 51			// pwrite
	CHECK 6
	b ok
path:	.asciz "/mnt/term/cwd/f"
new:	.asciz "NEW"
	.balign 4
