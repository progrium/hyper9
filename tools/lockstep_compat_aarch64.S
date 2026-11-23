// The musl aarch64 libunicorn.a from PyPI calls this outline-atomics helper
// from libgcc, which Zig's compiler-rt doesn't provide.
// __aarch64_cas16_sync(expected x0:x1, desired x2:x3, ptr x4) -> old x0:x1
	.text
	.globl __aarch64_cas16_sync
	.type __aarch64_cas16_sync, %function
__aarch64_cas16_sync:
	mov x16, x0
	mov x17, x1
1:	ldaxp x0, x1, [x4]
	cmp x0, x16
	ccmp x1, x17, #0, eq
	b.ne 2f
	stlxp w15, x2, x3, [x4]
	cbnz w15, 1b
	dmb ish
	ret
2:	stlxp w15, x0, x1, [x4]
	cbnz w15, 1b
	dmb ish
	ret
