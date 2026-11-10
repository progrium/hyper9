// The host as oracle for hx64 (tools/x86check, long mode): runs one
// instruction at a time natively on the real CPU in 64-bit mode and
// reports the registers, flags, and memory it leaves. Built as an x86-64
// Linux program; x86check.zig's `gen64` and `cmp64` feed it cases on stdin
// and compare T0's results with its answers.
//
// A case: 16 code bytes, 16 registers, RFLAGS, the GS base, the 1 KiB
// data window at 0x50000e00 (crossing a page boundary at 0x50001000), the
// x87, MMX, and SSE state as a 64-bit FXSAVE image, and 16 bytes the
// oracle ignores (the generator's notes for the comparison). The answer:
// a signal number (0 if none), the exception vector (the signal's trap
// number), 16 registers, RFLAGS, the window, and the FXSAVE image after
// (or, after a signal, the one the kernel saved when it was raised).
//
// The guest runs with the host's FS base (musl's TLS), so cases use GS
// for segment overrides: arch_prctl sets its base for each case, and
// nothing on the host uses it.
#define _GNU_SOURCE
#include <asm/prctl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <unistd.h>

#define CODE 0x40000000ul
#define DATA 0x50000000ul
#define WIN 0x50000e00ul
#define WINLEN 1024

struct cas {
    uint8_t code[16];
    uint64_t r[16];
    uint64_t fl;
    uint64_t gs_base;
    uint8_t win[WINLEN];
    uint8_t fx[512];
    uint8_t notes[16];
};
struct ans {
    uint32_t sig;
    uint32_t trap;
    uint64_t r[16];
    uint64_t fl;
    uint8_t win[WINLEN];
    uint8_t fx[512];
};

// The guest's registers and RFLAGS on the way in and out, and the host's
// stack pointer.
uint64_t g_in[17], g_out[17], host_rsp;
// The guest's FXSAVE image in and out, and the host's MXCSR.
uint8_t g_fx[512] __attribute__((aligned(16))), g_fxo[512] __attribute__((aligned(16)));
uint32_t host_mxcsr = 0x1f80;
static sigjmp_buf jb;
static volatile int sig, trapno;

static void onsig(int s, siginfo_t *si, void *ctx) {
    (void)si;
    ucontext_t *uc = ctx;
    sig = s;
    trapno = uc->uc_mcontext.gregs[REG_TRAPNO];
    // x86-64's fpstate is the FXSAVE image itself.
    if (uc->uc_mcontext.fpregs) memcpy(g_fxo, uc->uc_mcontext.fpregs, 512);
    siglongjmp(jb, 1);
}

void run_guest(void);
__asm__(
    ".globl run_guest\n"
    "run_guest:\n"
    "  pushq %rbx\n"
    "  pushq %rbp\n"
    "  pushq %r12\n"
    "  pushq %r13\n"
    "  pushq %r14\n"
    "  pushq %r15\n"
    "  movq %rsp, host_rsp(%rip)\n"
    "  fxrstor64 g_fx(%rip)\n"
    "  pushq g_in+128(%rip)\n"
    "  popfq\n"
    "  movq g_in+0(%rip), %rax\n"
    "  movq g_in+8(%rip), %rcx\n"
    "  movq g_in+16(%rip), %rdx\n"
    "  movq g_in+24(%rip), %rbx\n"
    "  movq g_in+40(%rip), %rbp\n"
    "  movq g_in+48(%rip), %rsi\n"
    "  movq g_in+56(%rip), %rdi\n"
    "  movq g_in+64(%rip), %r8\n"
    "  movq g_in+72(%rip), %r9\n"
    "  movq g_in+80(%rip), %r10\n"
    "  movq g_in+88(%rip), %r11\n"
    "  movq g_in+96(%rip), %r12\n"
    "  movq g_in+104(%rip), %r13\n"
    "  movq g_in+112(%rip), %r14\n"
    "  movq g_in+120(%rip), %r15\n"
    "  movq g_in+32(%rip), %rsp\n"
    "  jmp *0x40000ff0\n" // CODE: the instruction, NOPs, then a jump back
    ".globl back\n"
    "back:\n"
    "  fxsave64 g_fxo(%rip)\n"
    "  fninit\n"
    "  ldmxcsr host_mxcsr(%rip)\n"
    "  movq %rsp, g_out+32(%rip)\n"
    "  movq host_rsp(%rip), %rsp\n"
    "  movq %rax, g_out+0(%rip)\n"
    "  pushfq\n"
    "  popq %rax\n"
    "  movq %rax, g_out+128(%rip)\n"
    "  movq %rcx, g_out+8(%rip)\n"
    "  movq %rdx, g_out+16(%rip)\n"
    "  movq %rbx, g_out+24(%rip)\n"
    "  movq %rbp, g_out+40(%rip)\n"
    "  movq %rsi, g_out+48(%rip)\n"
    "  movq %rdi, g_out+56(%rip)\n"
    "  movq %r8, g_out+64(%rip)\n"
    "  movq %r9, g_out+72(%rip)\n"
    "  movq %r10, g_out+80(%rip)\n"
    "  movq %r11, g_out+88(%rip)\n"
    "  movq %r12, g_out+96(%rip)\n"
    "  movq %r13, g_out+104(%rip)\n"
    "  movq %r14, g_out+112(%rip)\n"
    "  movq %r15, g_out+120(%rip)\n"
    "  cld\n"
    "  popq %r15\n"
    "  popq %r14\n"
    "  popq %r13\n"
    "  popq %r12\n"
    "  popq %rbp\n"
    "  popq %rbx\n"
    "  ret\n");
extern char back[];

int main(void) {
    if (mmap((void *)CODE, 0x1000, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == MAP_FAILED) return 1;
    if (mmap((void *)DATA, 0x2000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == MAP_FAILED) return 1;
    static char altstack[65536];
    stack_t ss = {.ss_sp = altstack, .ss_size = sizeof altstack};
    sigaltstack(&ss, 0);
    struct sigaction sa = {0};
    sa.sa_sigaction = onsig;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    sigaction(SIGSEGV, &sa, 0);
    sigaction(SIGFPE, &sa, 0);
    sigaction(SIGILL, &sa, 0);
    sigaction(SIGBUS, &sa, 0);
    sigaction(SIGTRAP, &sa, 0);
    *(uint64_t *)(CODE + 0xff0) = CODE;
    struct cas c;
    struct ans a;
    while (fread(&c, sizeof c, 1, stdin) == 1) {
        uint8_t *code = (uint8_t *)CODE;
        memcpy(code, c.code, 16);
        // After the instruction (padded with NOPs): jmp *back(%rip).
        code[16] = 0xff;
        code[17] = 0x25;
        memset(code + 18, 0, 4);
        *(uint64_t *)(code + 22) = (uint64_t)back;
        memset((void *)DATA, 0, 0x2000);
        memcpy((void *)WIN, c.win, WINLEN);
        memcpy(g_in, c.r, 128);
        g_in[16] = c.fl;
        syscall(SYS_arch_prctl, ARCH_SET_GS, c.gs_base);
        sig = 0;
        trapno = 0;
        memcpy(g_fx, c.fx, 512);
        memset(g_fxo, 0, 512);
        if (sigsetjmp(jb, 1) == 0) run_guest();
        __asm__ volatile("fninit; ldmxcsr host_mxcsr(%rip)");
        a.sig = sig;
        a.trap = sig ? trapno : 0;
        memcpy(a.fx, g_fxo, 512);
        if (sig) {
            memcpy(a.r, c.r, 128);
            a.fl = c.fl;
        } else {
            memcpy(a.r, g_out, 128);
            a.fl = g_out[16];
        }
        memcpy(a.win, (void *)WIN, WINLEN);
        fwrite(&a, sizeof a, 1, stdout);
        fflush(stdout);
    }
    return 0;
}
