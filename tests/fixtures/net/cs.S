// Asks #I/cs to translate argv[1], then connects to the first address
// it returned, as libc's dial does. Exits cleanly if the connect
// succeeds, or with the error of the call that failed.
// See tests/engines.zig, "[5]".

#include "lib.S"

.macro FAILS_OK step            // exit with the call's error if it failed, else cleanly
	mov x28, #\step
	cmn x0, #1
	b.eq errexit
	b ok
.endm
.macro FAILS_OK_NEXT step       // exit with the call's error if it failed
	mov x28, #\step
	cmn x0, #1
	b.eq errexit
.endm

	adr x1, cs
	mov x2, #2                  // ORDWR
	SYS 14                      // open
	CHECK 0
	mov x19, x0
	ldr x20, [sp, #528]         // argv[1]
	mov x21, x20
1:	ldrb w3, [x21], #1
	cbnz w3, 1b
	sub x3, x21, x20
	sub x3, x3, #1
	mov x1, x19
	mov x2, x20
	movn x4, #0
	SYS 51                      // pwrite
	FAILS_OK_NEXT 1
	// Read "/net/tcp/clone addr!port\n..." into sp+256, after "connect".
	mov x1, x19
	add x2, sp, #264
	mov x3, #160
	mov x4, #0
	SYS 50                      // pread
	CHECK 2
	add x5, sp, #264
	strb wzr, [x5, x0]
	// Find the space after the clone file's name.
2:	ldrb w3, [x5], #1
	mov x28, #3
	cbz w3, die
	cmp w3, #' '
	b.ne 2b
	// x5 is the address; end it at the first newline.
	mov x6, x5
3:	ldrb w3, [x6]
	cbz w3, 4f
	cmp w3, #'\n'
	b.eq 4f
	add x6, x6, #1
	b 3b
4:	strb wzr, [x6]
	// "connect " just before it.
	sub x20, x5, #8
	adr x7, connect
	ldr x8, [x7]
	str x8, [x20]
	sub x22, x6, x20            // length
	adr x1, clone
	mov x2, #2
	SYS 14
	CHECK 4
	mov x1, x0
	mov x2, x20
	mov x3, x22
	movn x4, #0
	SYS 51
	FAILS_OK 5

cs:	.asciz "#I/cs"
clone:	.asciz "#I/tcp/clone"
connect: .ascii "connect "
	.balign 4
