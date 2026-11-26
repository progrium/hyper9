// h9 arm64 guest shim. Runs at EL1 from the TTBR1 half of the address space.
//
// SP_EL1 points at this vCPU's shared page, which starts with a Plan 9 Ureg.
// Any exception saves the interrupted state there, records why it happened,
// and rings the doorbell: a store to a page whose IPA the host never mapped,
// which the hypervisor hands to userspace. The host advances the PC past the
// store, so the shim then reloads the (possibly edited) Ureg and ERETs.
// If the host set the shared page's flush word (the vCPU switched address
// spaces, or pages were unmapped), it flushes the TLB and I-cache first.
//
// A vCPU's first run starts at `enter` (vectors + 0x800) at EL1, which
// always flushes and then loads the Ureg the same way.
//
// Keep in sync with src/engine/hvf.zig (shared page layout and kernel VAs).

.equ UREG_SP,     248
.equ UREG_PC,     256
.equ UREG_PSR,    264
.equ UREG_TYPE,   272
.equ SHARED_FAR,  280
.equ SHARED_WHY,  288
.equ SHARED_FLUSH, 296

.equ WHY_EL0,     1   // synchronous exception from EL0: syscall or fault
.equ WHY_EL1,     2   // exception inside the shim itself
.equ WHY_IRQ,     3   // asynchronous exception taken from EL0

.macro vector why
	.balign 128
	stp x0, x1, [sp, #0]
	mov x0, #\why
	b save
.endm

.text
.globl vectors
.balign 2048
vectors:
	// Current EL with SP_EL0
	vector WHY_EL1
	vector WHY_EL1
	vector WHY_EL1
	vector WHY_EL1
	// Current EL with SP_ELx
	vector WHY_EL1
	vector WHY_EL1
	vector WHY_EL1
	vector WHY_EL1
	// Lower EL, AArch64
	vector WHY_EL0
	vector WHY_IRQ
	vector WHY_IRQ
	vector WHY_EL1
	// Lower EL, AArch32 (never used)
	vector WHY_EL1
	vector WHY_EL1
	vector WHY_EL1
	vector WHY_EL1

	// vectors + 0x800: first entry.
	.balign 2048
enter:
	mov x1, #1
	str x1, [sp, #SHARED_FLUSH]
	b restore

save:
	stp x2, x3, [sp, #16]
	stp x4, x5, [sp, #32]
	stp x6, x7, [sp, #48]
	stp x8, x9, [sp, #64]
	stp x10, x11, [sp, #80]
	stp x12, x13, [sp, #96]
	stp x14, x15, [sp, #112]
	stp x16, x17, [sp, #128]
	stp x18, x19, [sp, #144]
	stp x20, x21, [sp, #160]
	stp x22, x23, [sp, #176]
	stp x24, x25, [sp, #192]
	stp x26, x27, [sp, #208]
	stp x28, x29, [sp, #224]
	str x30, [sp, #240]
	mrs x1, sp_el0
	str x1, [sp, #UREG_SP]
	mrs x1, elr_el1
	str x1, [sp, #UREG_PC]
	mrs x1, spsr_el1
	str x1, [sp, #UREG_PSR]
	mrs x1, esr_el1
	str x1, [sp, #UREG_TYPE]
	mrs x1, far_el1
	str x1, [sp, #SHARED_FAR]
	str x0, [sp, #SHARED_WHY]

	// Doorbell page: the page after the shim.
	adr x1, vectors
	add x1, x1, #0x1000
	str x0, [x1]

restore:
	ldr x1, [sp, #SHARED_FLUSH]
	cbz x1, 1f
	str xzr, [sp, #SHARED_FLUSH]
	dsb ish
	tlbi vmalle1is
	dsb ish
	ic ialluis
	dsb ish
	isb
1:
	ldr x1, [sp, #UREG_SP]
	msr sp_el0, x1
	ldr x1, [sp, #UREG_PC]
	msr elr_el1, x1
	ldr x1, [sp, #UREG_PSR]
	msr spsr_el1, x1
	ldp x2, x3, [sp, #16]
	ldp x4, x5, [sp, #32]
	ldp x6, x7, [sp, #48]
	ldp x8, x9, [sp, #64]
	ldp x10, x11, [sp, #80]
	ldp x12, x13, [sp, #96]
	ldp x14, x15, [sp, #112]
	ldp x16, x17, [sp, #128]
	ldp x18, x19, [sp, #144]
	ldp x20, x21, [sp, #160]
	ldp x22, x23, [sp, #176]
	ldp x24, x25, [sp, #192]
	ldp x26, x27, [sp, #208]
	ldp x28, x29, [sp, #224]
	ldr x30, [sp, #240]
	ldp x0, x1, [sp, #0]
	eret
