// stat into an unmapped buffer is a bad address in a syscall
// (design/kernel-port.md).

#include "lib.S"

	adr x1, slash
	mov x2, #0x1000
	mov x3, #128
	SYS 42
	b ok
slash:	.asciz "/"
