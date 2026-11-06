// Opens /srv/m, which only another machine has posted: it fails, and the
// program exits with the error (tests/backends.zig).

#include "lib.S"

	adr x1, path
	mov x2, #2		// ORDWR
	SYS 14			// open
	FAILS 0
path:	.asciz "/srv/m"
	.balign 4
