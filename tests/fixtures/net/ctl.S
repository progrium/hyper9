// Writes argv[2] to the file argv[1] (a ctl file, or #I/cs), as rc's
// echo would. Exits cleanly if the write succeeds, or with its error.
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

	ldr x1, [sp, #528]          // argv[1]
	mov x2, #2                  // ORDWR
	SYS 14                      // open
	CHECK 0
	mov x19, x0
	ldr x20, [sp, #536]         // argv[2]
	mov x21, x20
1:	ldrb w3, [x21], #1
	cbnz w3, 1b
	sub x3, x21, x20
	sub x3, x3, #1
	mov x1, x19
	mov x2, x20
	movn x4, #0                 // offset -1
	SYS 51                      // pwrite
	FAILS_OK 1
