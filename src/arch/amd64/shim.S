// h9 amd64 guest shim. Runs in ring 0 from the kernel half of the address
// space (PML4 entry 511), in long mode the host set up (src/vmm/x86.zig).
//
// Each vCPU has a shared page: a Plan 9 Ureg at its start, the vCPU's GDT
// and TSS, and at its top the stack exceptions switch to (IST1). While the
// shim runs, GS points at the shared page; SWAPGS swaps it out for user
// mode, where KERNEL_GS_BASE holds it.
//
// SYSCALL enters at `syscall_entry` (0x200), and exceptions 0-31 at
// `vectors` (0, 16 bytes each). The
// shim saves the user state into the Ureg, records why it came, and rings
// the doorbell, an OUT that the hypervisor hands to the host. When the host
// runs the vCPU again it continues at `restore`, which loads the (possibly
// edited) Ureg and returns to user mode with IRETQ, loading the shared
// page's next-CR3 word first if the host set it.
//
// A vCPU's first run starts at `restore` too.
//
// Keep in sync with src/vmm/x86.zig (offsets, shared page layout).

.equ U_AX,     0
.equ U_BX,     8
.equ U_CX,     16
.equ U_DX,     24
.equ U_SI,     32
.equ U_DI,     40
.equ U_BP,     48
.equ U_R8,     56
.equ U_R9,     64
.equ U_R10,    72
.equ U_R11,    80
.equ U_R12,    88
.equ U_R13,    96
.equ U_R14,    104
.equ U_R15,    112
.equ U_TYPE,   128
.equ U_ERROR,  136
.equ U_PC,     144
.equ U_CS,     152
.equ U_FLAGS,  160
.equ U_SP,     168
.equ U_SS,     176
.equ S_FAR,    184
.equ S_WHY,    192
.equ S_NEXTCR3, 200
.equ S_SELF,   208
.equ STACK_TOP, 0x1000

.equ WHY_SYSCALL, 1
.equ WHY_TRAP,    2
.equ WHY_SHIM,    3

.equ DOORBELL, 0x99
.equ VECTOR_SYSCALL, 64
.equ UESEL, 0x2b
.equ UDSEL, 0x23
// User RFLAGS bits a Ureg may set: CF, PF, AF, ZF, SF, DF and OF. IF and
// the always-one bit are added.
.equ USER_FLAGS, 0xcd5
.equ FLAGS_SET,  0x202

.macro save_gprs
	movq %rax, %gs:U_AX
	movq %rbx, %gs:U_BX
	movq %rcx, %gs:U_CX
	movq %rdx, %gs:U_DX
	movq %rsi, %gs:U_SI
	movq %rdi, %gs:U_DI
	movq %rbp, %gs:U_BP
	movq %r8, %gs:U_R8
	movq %r9, %gs:U_R9
	movq %r10, %gs:U_R10
	movq %r11, %gs:U_R11
	movq %r12, %gs:U_R12
	movq %r13, %gs:U_R13
	movq %r14, %gs:U_R14
	movq %r15, %gs:U_R15
.endm

// Exceptions with an error code: #DF, #TS, #NP, #SS, #GP, #PF, #AC, #CP,
// #VC and #SX. The others push a zero in its place.
.macro vector n
	.balign 16
	.if (\n == 8) || (\n == 10) || (\n == 11) || (\n == 12) || (\n == 13) || (\n == 14) || (\n == 17) || (\n == 21) || (\n == 29) || (\n == 30)
	.else
	pushq $0
	.endif
	pushq $\n
	jmp trap
.endm

.code64
.text
.globl vectors
vectors:
	.irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
	vector \n
	.endr

	.org 0x200
syscall_entry:
	swapgs
	save_gprs
	movq %rsp, %gs:U_SP
	movq %rcx, %gs:U_PC
	movq %r11, %gs:U_FLAGS
	movq $UESEL, %gs:U_CS
	movq $UDSEL, %gs:U_SS
	movq $VECTOR_SYSCALL, %gs:U_TYPE
	movq $WHY_SYSCALL, %gs:S_WHY

	jmp doorbell

// On IST1: the vector, the error code, then the CPU's frame (RIP, CS,
// RFLAGS, RSP, SS).
trap:
	testb $3, 24(%rsp)
	jz shim_trap
	swapgs
	save_gprs
	movq 0(%rsp), %rax
	movq %rax, %gs:U_TYPE
	movq 8(%rsp), %rax
	movq %rax, %gs:U_ERROR
	movq 16(%rsp), %rax
	movq %rax, %gs:U_PC
	movq 24(%rsp), %rax
	movq %rax, %gs:U_CS
	movq 32(%rsp), %rax
	movq %rax, %gs:U_FLAGS
	movq 40(%rsp), %rax
	movq %rax, %gs:U_SP
	movq 48(%rsp), %rax
	movq %rax, %gs:U_SS
	movq %cr2, %rax
	movq %rax, %gs:S_FAR
	movq $WHY_TRAP, %gs:S_WHY
	jmp doorbell

// An exception in the shim itself, which is a bug: GS may be either
// base, but IST1 is in the shared page, so its base is the stack's page.
// Report the vector and the PC, and stop.
shim_trap:
	movq %rsp, %rax
	andq $-4096, %rax
	movq 0(%rsp), %rbx
	movq %rbx, U_TYPE(%rax)
	movq 16(%rsp), %rbx
	movq %rbx, U_PC(%rax)
	movq %cr2, %rbx
	movq %rbx, S_FAR(%rax)
	movq $WHY_SHIM, S_WHY(%rax)
	outb %al, $DOORBELL
2:
	hlt
	jmp 2b
// The doorbell, at a fixed offset: the host tells from a vCPU's PC
// whether it was stopped saving a Ureg (below it) or loading one (past it).
	.org 0x600
doorbell:
	outb %al, $DOORBELL

restore:
	movq %gs:S_NEXTCR3, %rax
	testq %rax, %rax
	jz 1f
	movq %rax, %cr3
	movq $0, %gs:S_NEXTCR3
1:
	movq %gs:S_SELF, %rsp
	addq $STACK_TOP, %rsp
	pushq $UDSEL
	pushq %gs:U_SP
	movq %gs:U_FLAGS, %rax
	andq $USER_FLAGS, %rax
	orq $FLAGS_SET, %rax
	pushq %rax
	pushq $UESEL
	pushq %gs:U_PC
	movq %gs:U_BX, %rbx
	movq %gs:U_CX, %rcx
	movq %gs:U_DX, %rdx
	movq %gs:U_SI, %rsi
	movq %gs:U_DI, %rdi
	movq %gs:U_BP, %rbp
	movq %gs:U_R8, %r8
	movq %gs:U_R9, %r9
	movq %gs:U_R10, %r10
	movq %gs:U_R11, %r11
	movq %gs:U_R12, %r12
	movq %gs:U_R13, %r13
	movq %gs:U_R14, %r14
	movq %gs:U_R15, %r15
	movq %gs:U_AX, %rax
	swapgs
	iretq
