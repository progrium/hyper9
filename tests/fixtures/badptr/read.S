// pread into an unmapped buffer is a bad address in a syscall, which
// kills the process (design/kernel-port.md): the kernel checks the
// buffer against the address space before it reads.

#include "lib.S"

	mov x1, #0
	mov x2, #0x1000
	mov x3, #16
	mov x4, #0
	SYS 50
	b ok
