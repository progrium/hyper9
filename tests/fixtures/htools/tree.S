// #H within one machine (tests/backends.zig, design/guest-tools.md):
// the test-only script is on /bin after the root's directories and reads
// back as an rc script, #H/bin lists, and every write, create, remove,
// truncating open and wstat fails with "permission denied".

#include "lib.S"

.macro DENIED step		// die at `step` unless the call failed with Eperm
	mov x28, #\step
	cmn x0, #1
	b.ne die
	bl denied
.endm

	adr x1, onbin
	mov x2, #0		// OREAD
	SYS 14			// open, through the /bin union
	CHECK 0
	mov x19, x0
	mov x1, x19
	add x2, sp, #96
	mov x3, #9
	mov x4, #0
	SYS 50			// pread
	CHECK 1
	mov x28, #1
	cmp x0, #9
	b.ne die
	ldr x2, [sp, #96]
	adr x3, magic
	ldr x3, [x3]
	cmp x2, x3		// "#!/bin/r"
	b.ne die
	ldrb w2, [sp, #104]
	cmp w2, #'c'
	b.ne die

	adr x1, inh
	mov x2, #1		// OWRITE
	SYS 14
	DENIED 2
	adr x1, inh
	mov x2, #2		// ORDWR
	SYS 14
	DENIED 3
	adr x1, inh
	mov x2, #0x10		// OREAD|OTRUNC
	SYS 14
	DENIED 4
	adr x1, inh
	mov x2, #0x40		// OREAD|ORCLOSE
	SYS 14
	DENIED 5
	adr x1, newf
	mov x2, #1
	mov x3, #0x1a4		// 0644
	SYS 22			// create
	DENIED 6
	adr x1, inh
	SYS 25			// remove
	DENIED 7

	adr x1, inh
	add x2, sp, #256
	mov x3, #128
	SYS 42			// stat
	CHECK 8
	mov x20, x0
	mov x28, #8
	cmp x20, #2
	b.le die
	adr x1, inh
	add x2, sp, #256
	mov x3, x20
	SYS 44			// wstat, of the same stat
	DENIED 9

	adr x1, hbin
	mov x2, #0
	SYS 14
	CHECK 10
	mov x1, x0
	add x2, sp, #96
	mov x3, #128
	mov x4, #0
	SYS 50			// a directory read lists something
	CHECK 11
	mov x28, #11
	cmp x0, #0
	b.le die
	b ok

denied:				// die unless the error string starts "permission denied"
	mov x21, x30
	add x1, sp, #384
	mov x2, #64
	SYS 41			// errstr
	add x1, sp, #384
	adr x2, eperm
1:	ldrb w3, [x1], #1
	ldrb w4, [x2], #1
	cbz w4, 2f		// the error may name the file after it
	cmp w3, w4
	b.ne die
	b 1b
2:	mov x30, x21
	ret

	.balign 8
magic:	.ascii "#!/bin/r"
onbin:	.asciz "/bin/h9-guest-test"
inh:	.asciz "#H/bin/h9-guest-test"
newf:	.asciz "#H/bin/new"
hbin:	.asciz "#H/bin"
eperm:	.asciz "permission denied"
	.balign 4
