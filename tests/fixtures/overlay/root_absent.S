// Opens /f, which only another machine has written: it fails, and the
// program exits with the error (tests/backends.zig).

#include "lib.S"

	adr x1, path
	mov x2, #0		// OREAD
	SYS 14			// open
	FAILS 0
path:	.asciz "/f"
	.balign 4
