// A draw client (tests/backends.zig, design/gfx.md): opens
// /dev/draw/new, opens its client's data file, and fills (10,10)-(60,60)
// of the screen, image 0, with red, as libdraw would: 'b' allocates a
// 1x1 replicated opaque red image, 'd' draws it through itself as the
// mask, 'v' flushes.

#include "lib.S"

	adr x1, new
	mov x2, #2		// ORDWR
	SYS 14			// open /dev/draw/new
	CHECK 0
	mov x19, x0
	mov x1, x19
	add x2, sp, #64
	mov x3, #144
	mov x4, #-1
	SYS 50			// pread the screen information
	CHECK 1

	// "/dev/draw/" then the client id, the first 12-byte field with its
	// spaces skipped, then "/data".
	add x5, sp, #256
	adr x6, dir
1:	ldrb w7, [x6], #1
	cbz w7, 2f
	strb w7, [x5], #1
	b 1b
2:	add x6, sp, #64
	add x8, x6, #12
3:	cmp x6, x8
	b.eq 4f
	ldrb w7, [x6], #1
	cmp w7, #' '
	b.eq 3b
	strb w7, [x5], #1
	b 3b
4:	adr x6, data
5:	ldrb w7, [x6], #1
	strb w7, [x5], #1
	cbnz w7, 5b

	add x1, sp, #256
	mov x2, #2		// ORDWR
	SYS 14			// open /dev/draw/n/data
	CHECK 2
	mov x1, x0
	adr x2, msg
	mov x3, #(msgend - msg)
	mov x4, #-1
	SYS 51			// pwrite the messages
	CHECK 3
	b ok
new:	.asciz "/dev/draw/new"
dir:	.asciz "/dev/draw/"
data:	.asciz "/data"
	.balign 4
msg:
	// b id screenid refresh chan repl R clipR rrggbbaa
	.byte 'b'
	.word 1, 0
	.byte 0
	.word 0x08182848	// RGBA32: its alpha makes it an opaque mask too
	.byte 1
	.word 0, 0, 1, 1
	.word -0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF
	.word 0xFF0000FF	// red
	// d dstid srcid maskid dstR srcp maskp
	.byte 'd'
	.word 0, 1, 1
	.word 10, 10, 60, 60
	.word 0, 0, 0, 0
	// v: flush
	.byte 'v'
msgend:
	.balign 4
