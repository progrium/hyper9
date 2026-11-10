// The host as oracle for h86 (tools/x86check): runs one instruction at a
// time on the real CPU in 32-bit mode and reports the registers, flags,
// and memory it leaves. Built as an i386 Linux program; x86check.zig
// feeds it cases on stdin and compares T0's results with its answers.
//
// A case: 16 code bytes, 8 registers, EFLAGS, the 1 KiB data window at
// 0x50000e00 (the window crosses a page boundary at 0x50001000), and the
// x87, MMX, and SSE state as an FXSAVE image. The answer: a signal number
// (0 if none), 8 registers, EFLAGS, the window, the exception vector
// (the signal's trap number), and the FXSAVE image after (or, after a
// signal, the one the kernel saved when it was raised).
#define _GNU_SOURCE
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <ucontext.h>
#include <unistd.h>

#define CODE 0x40000000u
#define DATA 0x50000000u
#define WIN 0x50000e00u
#define WINLEN 1024

struct cas {
    uint8_t code[16];
    uint32_t r[8];
    uint32_t fl;
    uint8_t win[WINLEN];
    uint8_t fx[512];
};
struct ans {
    uint32_t sig;
    uint32_t r[8];
    uint32_t fl;
    uint8_t win[WINLEN];
    uint32_t trap;
    uint8_t fx[512];
};

// The guest's registers on the way in and out, and the host's stack.
uint32_t g_in[9], g_out[9], host_esp;
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
    // The kernel's i386 fpstate: the legacy 112 bytes, then FXSAVE's.
    if (uc->uc_mcontext.fpregs) memcpy(g_fxo, (char *)uc->uc_mcontext.fpregs + 112, 512);
    siglongjmp(jb, 1);
}

void run_guest(void);
__asm__(
    ".globl run_guest\n"
    "run_guest:\n"
    "  pushal\n"
    "  movl %esp, host_esp\n"
    "  fxrstor g_fx\n"
    "  movl g_in+32, %eax\n"
    "  pushl %eax\n"
    "  popfl\n"
    "  movl g_in+0, %eax\n"
    "  movl g_in+4, %ecx\n"
    "  movl g_in+8, %edx\n"
    "  movl g_in+12, %ebx\n"
    "  movl g_in+20, %ebp\n"
    "  movl g_in+24, %esi\n"
    "  movl g_in+28, %edi\n"
    "  movl g_in+16, %esp\n"
    "  jmp *0x40000ff0\n" // CODE: the instruction, then a jump to back
    ".globl back\n"
    "back:\n"
    "  fxsave g_fxo\n"
    "  fninit\n"
    "  ldmxcsr host_mxcsr\n"
    "  movl %esp, g_out+16\n"
    "  movl host_esp, %esp\n"
    "  movl %eax, g_out+0\n"
    "  pushfl\n"
    "  popl %eax\n"
    "  movl %eax, g_out+32\n"
    "  movl %ecx, g_out+4\n"
    "  movl %edx, g_out+8\n"
    "  movl %ebx, g_out+12\n"
    "  movl %ebp, g_out+20\n"
    "  movl %esi, g_out+24\n"
    "  movl %edi, g_out+28\n"
    "  cld\n"
    "  popal\n"
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
    *(uint32_t *)(CODE + 0xff0) = CODE;
    struct cas c;
    struct ans a;
    while (fread(&c, sizeof c, 1, stdin) == 1) {
        uint8_t *code = (uint8_t *)CODE;
        memcpy(code, c.code, 16);
        // After the instruction (padded with NOPs): jmp back.
        int n = 16;
        code[n] = 0xe9;
        *(int32_t *)(code + n + 1) = (int32_t)((uint32_t)back - (CODE + n + 5));
        memset((void *)DATA, 0, 0x2000);
        memcpy((void *)WIN, c.win, WINLEN);
        memcpy(g_in, c.r, 32);
        g_in[8] = c.fl;
        sig = 0;
        trapno = 0;
        memcpy(g_fx, c.fx, 512);
        memset(g_fxo, 0, 512);
        if (sigsetjmp(jb, 1) == 0) run_guest();
        __asm__ volatile("fninit; ldmxcsr host_mxcsr");
        a.sig = sig;
        a.trap = sig ? trapno : 0;
        memcpy(a.fx, g_fxo, 512);
        if (sig) {
            memcpy(a.r, c.r, 32);
            a.fl = c.fl;
        } else {
            memcpy(a.r, g_out, 32);
            a.fl = g_out[8];
        }
        memcpy(a.win, (void *)WIN, WINLEN);
        fwrite(&a, sizeof a, 1, stdout);
        fflush(stdout);
    }
    return 0;
}
