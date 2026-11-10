// The guest side of the compute benchmarks (tests/bench.zig): _start
// calls the program's compute() and exits with its checksum in hex as the
// exit message, which the bench compares with the same C run natively.
// Text only: programs keep their data on the stack (16 MB).

typedef unsigned int u32;
typedef unsigned long size_t_;

extern u32 compute(void);

static const char hex[] = "0123456789abcdef";

char *bench_run(char *buf) {
    u32 v = compute();
    for (int i = 7; i >= 0; i--) {
        buf[i] = hex[v & 15];
        v >>= 4;
    }
    buf[8] = 0;
    return buf;
}

// What the compiler may call for loops it recognizes.
void *memset(void *d, int c, __SIZE_TYPE__ n) {
    unsigned char *p = d;
    while (n--) *p++ = (unsigned char)c;
    return d;
}

void *memcpy(void *d, const void *s, __SIZE_TYPE__ n) {
    unsigned char *p = d;
    const unsigned char *q = s;
    while (n--) *p++ = *q++;
    return d;
}

// exits(buf): EXITS is 8, its argument a word above the return PC slot.
#if defined(__aarch64__)
__asm__(
    ".section .text.start,\"ax\"\n"
    ".global _start\n"
    "_start:\n"
    "  mov x9, sp\n"
    "  and x9, x9, #~15\n"
    "  sub sp, x9, #96\n"
    "  add x0, sp, #48\n"
    "  bl bench_run\n"
    "  str x0, [sp, #8]\n"
    "  mov x0, #8\n"
    "  svc #0\n");
#elif defined(__i386__)
__asm__(
    ".section .text.start,\"ax\"\n"
    ".global _start\n"
    "_start:\n"
    "  andl $-16, %esp\n"
    "  subl $64, %esp\n"
    "  leal 32(%esp), %eax\n"
    "  movl %eax, (%esp)\n"
    "  call bench_run\n"
    "  movl %eax, 4(%esp)\n"
    "  movl $8, %eax\n"
    "  int $64\n");
#else
#error "start.c: arm64 or 386"
#endif
