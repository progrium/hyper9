// Shared prologue for the segattach engine fixtures (tests/engines.zig),
// arm64. Each fixture includes this, then continues at `main`.
//
// The program starts at the a.out's entry with 512 bytes of frame. `call`
// stores x1-x4 as the syscall's arguments at sp+8 on and traps, so `SYS n`
// makes syscall n with arguments in x1-x4 and its result in x0. x28 holds
// the step the program is at: `die` exits with it as a letter ("a" for
// step 0), and `errexit` exits with the error string of the last call.
// `ok` exits cleanly.

.macro LI r, v                  // a 48-bit constant
	movz \r, #((\v) & 0xffff)
	movk \r, #(((\v) >> 16) & 0xffff), lsl #16
	movk \r, #(((\v) >> 32) & 0xffff), lsl #32
.endm
.macro SYS n
	mov x0, #\n
	bl call
.endm
.macro CHECK step               // die at `step` if the call failed
	mov x28, #\step
	cmn x0, #1
	b.eq die
.endm
.macro FAILS step               // die at `step` unless the call failed; exit with its error
	mov x28, #\step
	cmn x0, #1
	b.ne die
	b errexit
.endm

.text
_start:
	sub sp, sp, #512
	b main
call:
	str x1, [sp, #8]
	str x2, [sp, #16]
	str x3, [sp, #24]
	str x4, [sp, #32]
	svc #0
	ret
die:                            // exits("a" + step)
	add x1, sp, #448
	add x2, x28, #'a'
	strb w2, [x1]
	strb wzr, [x1, #1]
	SYS 8
errexit:                        // exits(errstr)
	add x1, sp, #448
	mov x2, #64
	SYS 41
	add x1, sp, #448
	SYS 8
ok:                             // exits(nil)
	mov x1, #0
	SYS 8
shared:	.asciz "shared"
memory:	.asciz "memory"
	.balign 4
main:
