// Looks a name up over UDP as a Linux program's resolver does, then
// connects by address. Writes argv[1] (a "connect ADDR!53" message) to a
// new #I/udp conversation's ctl, sends an A query for the name argv[2]
// on its data file, and reads the answer: a nonzero rcode exits with
// "rcode N". Then writes argv[3] to a new #I/tcp conversation's ctl, and
// exits cleanly if that connect succeeds, or with its error.
// See tests/engines.zig, "[linux-dns]".

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

	adr x1, udpclone
	mov x2, #2                  // ORDWR
	SYS 14                      // open
	CHECK 0
	mov x19, x0
	ldr x1, [sp, #528]          // argv[1]
	bl strlen
	mov x3, x0
	mov x1, x19
	ldr x2, [sp, #528]
	movn x4, #0
	SYS 51                      // pwrite
	FAILS_OK_NEXT 1
	// "#I/udp/" N "/data" at sp+64.
	adr x7, udpdir
	ldr x8, [x7]
	str x8, [sp, #64]
	mov x1, x19
	add x2, sp, #71
	mov x3, #16
	mov x4, #0
	SYS 50                      // pread: the conversation's number
	CHECK 2
	add x9, sp, #71
	add x9, x9, x0
	adr x7, data
	ldr x8, [x7]
	str x8, [x9]
	add x1, sp, #64
	mov x2, #2
	SYS 14
	CHECK 3
	mov x20, x0
	// The query at sp+128: id 0x1234, RD, one question.
	LI x8, 0x010000013412
	str x8, [sp, #128]
	str wzr, [sp, #136]
	ldr x12, [sp, #536]         // argv[2]
	add x10, sp, #140           // the label's length byte
	add x9, x10, #1
	mov x11, #0
1:	ldrb w3, [x12], #1
	cbz w3, 3f
	cmp w3, #'.'
	b.eq 2f
	strb w3, [x9], #1
	add x11, x11, #1
	b 1b
2:	strb w11, [x10]
	mov x10, x9
	add x9, x9, #1
	mov x11, #0
	b 1b
3:	strb w11, [x10]
	strb wzr, [x9], #1          // the root
	mov w3, #1
	strb wzr, [x9], #1          // type A
	strb w3, [x9], #1
	strb wzr, [x9], #1          // class IN
	strb w3, [x9], #1
	add x2, sp, #128
	sub x3, x9, x2
	mov x1, x20
	movn x4, #0
	SYS 51
	CHECK 4
	mov x1, x20
	add x2, sp, #128
	mov x3, #300
	movn x4, #0
	SYS 50                      // the answer
	CHECK 5
	ldrb w3, [sp, #131]
	and w3, w3, #0xf
	cbz w3, 4f
	// exits("rcode N")
	adr x7, rcode
	ldr x8, [x7]
	str x8, [sp, #448]
	add w3, w3, #'0'
	strb w3, [sp, #454]
	strb wzr, [sp, #455]
	add x1, sp, #448
	SYS 8
4:	adr x1, tcpclone
	mov x2, #2
	SYS 14
	CHECK 6
	mov x19, x0
	ldr x1, [sp, #544]          // argv[3]
	bl strlen
	mov x3, x0
	mov x1, x19
	ldr x2, [sp, #544]
	movn x4, #0
	SYS 51
	FAILS_OK 7

strlen:                         // x0 = strlen(x1)
	mov x0, #0
5:	ldrb w3, [x1, x0]
	cbz w3, 6f
	add x0, x0, #1
	b 5b
6:	ret

udpclone: .asciz "#I/udp/clone"
tcpclone: .asciz "#I/tcp/clone"
	.balign 8
udpdir:	.ascii "#I/udp/\0"
data:	.ascii "/data\0\0\0"
rcode:	.ascii "rcode \0\0"
	.balign 4
