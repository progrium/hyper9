// With guest_tools false (--no-guest-tools), the test-only script isn't on
// /bin and #H can't be attached; exits with the attach's error
// (tests/backends.zig, design/0032-guest-tools.md).

#include "lib.S"

.macro MUSTFAIL step
	mov x28, #\step
	cmn x0, #1
	b.ne die
.endm

	adr x1, onbin
	mov x2, #0
	SYS 14
	MUSTFAIL 0
	adr x1, hbin
	mov x2, #0
	SYS 14
	FAILS 1

onbin:	.asciz "/bin/h9-guest-test"
hbin:	.asciz "#H/bin"
	.balign 4
