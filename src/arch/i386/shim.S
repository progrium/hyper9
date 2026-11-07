// The guest kernel shim for the v86 backend (src/vmm/v86.zig,
// design/0012-browser-host.md). The backend loads it at guest-physical
// SHIM and starts it in real mode, as a boot sector would be.
//
// Boot: protected mode, the GDT, IDT and TSS, FXSR, then paging with a
// page directory the backend wrote at BOOTPD, which maps the low 1 MiB at
// 0 and at KZERO. It moves to KZERO and halts. Every address space the
// backend makes maps the same page table at KZERO, supervisor only.
//
// Trap entry, on any vector: push the rest of a 9front 386 Ureg on the
// kernel stack (vector, error code, segment registers, then PUSHAL) and
// halt. A page fault also leaves CR2 at CR2SLOT. With interrupts off, the
// halt ends v86's main_loop, and the backend reads the Ureg at ESP.
//
// Resume: the backend writes a Ureg at the top of the kernel stack, points
// ESP at it and EIP at `restore`, and runs.
//
// No instruction here uses an absolute relocation: every address is the
// base plus a label's offset from `start`, which the assembler resolves.

#define SHIM	0x1000
#define KZERO	0xF0000000
#define IDT	0x6000
#define KSTACK	0x8000		/* top; the stack is the page below */
#define BOOTPD	0xA000
#define CR2SLOT	0x500
#define FXAREA	0x6800		/* 512 bytes, after the IDT */

#define P(l)	(SHIM + ((l) - start))		/* physical */
#define V(l)	(KZERO + SHIM + ((l) - start))	/* virtual, after boot */

	.text
	.code16
	.globl start
start:
	jmp boot
	// Offsets of the entry points the backend uses, from `start`.
	.balign 4
	.long restore - start
	.long fxsave - start
	.long fxrstor - start
boot:
	cli
	xorw %ax, %ax
	movw %ax, %ds
	lgdtl P(gdtr16)
	movl %cr0, %eax
	orl $1, %eax
	movl %eax, %cr0
	ljmpl $0x10, $P(pm32)

	.code32
pm32:
	movw $0x08, %ax
	movw %ax, %ds
	movw %ax, %es
	movw %ax, %fs
	movw %ax, %gs
	movw %ax, %ss
	movl $KSTACK, %esp

	// The IDT: 256 interrupt gates, vector i to stubs + 16*i. INT $64 is
	// a trap gate reachable from ring 3; the rest only from hardware.
	xorl %ecx, %ecx
1:
	movl %ecx, %eax
	shll $4, %eax
	addl $V(stubs), %eax
	movl %ecx, %edi
	shll $3, %edi
	addl $IDT, %edi
	movw %ax, (%edi)
	movw $0x10, 2(%edi)
	movb $0, 4(%edi)
	movb $0x8E, 5(%edi)
	cmpl $64, %ecx
	jne 2f
	movb $0xEE, 5(%edi)
2:
	shrl $16, %eax
	movw %ax, 6(%edi)
	incl %ecx
	cmpl $256, %ecx
	jne 1b

	// The TSS descriptor's base, and the ring 0 stack.
	movl $V(tss), %eax
	movw %ax, P(gdt) + 0x28 + 2
	shrl $16, %eax
	movb %al, P(gdt) + 0x28 + 4
	movb %ah, P(gdt) + 0x28 + 7
	movl $(KZERO + KSTACK), P(tss) + 4
	movl $0x08, P(tss) + 8

	// FXSR and unmasked SSE exceptions (CR4.OSFXSR, OSXMMEXCPT); x87
	// errors through #MF (CR0.NE).
	movl %cr4, %eax
	orl $((1 << 9) | (1 << 10)), %eax
	movl %eax, %cr4

	movl $BOOTPD, %eax
	movl %eax, %cr3
	movl %cr0, %eax
	orl $0x80000020, %eax
	movl %eax, %cr0
	ljmpl $0x10, $V(high)

high:
	lgdtl V(gdtr)
	lidtl V(idtr)
	movl $(KZERO + KSTACK), %esp
	movw $0x28, %ax
	ltrw %ax
	hlt
	jmp high

	// Resume: ESP points at a Ureg.
restore:
	popal
	popl %gs
	popl %fs
	popl %es
	popl %ds
	addl $8, %esp
	iretl

trapcommon:
	pushl %ds
	pushl %es
	pushl %fs
	pushl %gs
	pushal
	movl %cr2, %eax
	movl %eax, KZERO + CR2SLOT
	hlt
	jmp trapcommon

	// fxsave and fxrstor of the area at FXAREA, for the backend's
	// context switches, entered like `restore` and ending in a halt.
fxsave:
	fxsave KZERO + FXAREA
	hlt
	jmp fxsave
fxrstor:
	fxrstor KZERO + FXAREA
	hlt
	jmp fxrstor

	// Vectors that push an error code: 8, 10-14 and 17.
	.balign 16
stubs:
	.set i, 0
	.rept 256
	.balign 16
	.if i == 8 || (i >= 10 && i <= 14) || i == 17
	pushl $i
	.else
	pushl $0
	pushl $i
	.endif
	jmp trapcommon
	.set i, i + 1
	.endr

	.balign 8
gdt:
	.quad 0
	.quad 0x00CF92000000FFFF	// 0x08 KDSEG
	.quad 0x00CF9A000000FFFF	// 0x10 KESEG
	.quad 0x00CFF2000000FFFF	// 0x18 UDSEG (0x1b)
	.quad 0x00CFFA000000FFFF	// 0x20 UESEG (0x23)
	.quad 0x0000890000000067	// 0x28 TSS, base set at boot
gdtend:
	.balign 4
	.word 0
gdtr16:
	.word gdtend - gdt - 1
	.long P(gdt)
	.word 0
gdtr:
	.word gdtend - gdt - 1
	.long V(gdt)
	.word 0
idtr:
	.word 256*8 - 1
	.long KZERO + IDT
	.balign 16
tss:
	.fill 104, 1, 0
end:
