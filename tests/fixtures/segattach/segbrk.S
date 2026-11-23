// segbrk grows a memory segment to 3 pages, shrinks it to 1 and grows it
// back, zeroed; segbrk with 0 returns the base. Growing it into a shared
// segment above fails (step 7). A child blocked on a pipe shares the
// shared segment, so shrinking that fails with "device or object already
// in use", the exit string.

#include "lib.S"

	mov x1, #0
	adr x2, memory
	LI x3, 0x100000000
	mov x4, #0x1000
	SYS 30
	CHECK 0
	mov x19, x0
	mov x1, x19
	add x2, x19, #0x3000
	SYS 12
	CHECK 1
	add x21, x19, #0x2000
	mov x2, #5
	str x2, [x21, #0xff8]
	mov x1, x19
	add x2, x19, #0x1000
	SYS 12
	CHECK 2
	mov x1, x19
	mov x2, #0
	SYS 12
	mov x28, #3
	cmp x0, x19
	b.ne die
	mov x1, x19
	add x2, x19, #0x3000
	SYS 12
	CHECK 4
	ldr x2, [x21, #0xff8]
	mov x28, #5
	cbnz x2, die
	mov x1, #0
	adr x2, shared
	LI x3, 0x100010000
	mov x4, #0x2000
	SYS 30
	CHECK 6
	mov x20, x0
	mov x1, x19
	add x2, x19, #0x11000
	SYS 12
	mov x28, #7
	cmn x0, #1
	b.ne die
	add x1, sp, #128
	SYS 21
	CHECK 8
	mov x1, #0x10
	SYS 19
	CHECK 9
	cbnz x0, 1f
	ldrsw x1, [sp, #128]
	add x2, sp, #160
	mov x3, #8
	mov x4, #-1
	SYS 50
	b ok
1:	mov x1, x20
	add x2, x20, #0x1000
	SYS 12
	mov x28, #10
	cmn x0, #1
	b.ne die
	add x1, sp, #384
	mov x2, #64
	SYS 41
	ldrsw x1, [sp, #132]
	SYS 4
	add x1, sp, #160
	mov x2, #64
	SYS 47
	add x1, sp, #384
	SYS 8
