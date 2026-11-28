/* A signal handler that uses AVX gives the code it interrupted its vector
 * registers back (design/epoch-0/linux-personality.md, "Signals"): the
 * program fills YMM3, raises SIGUSR1 with a bare syscall so the compiler
 * can't save it, and the handler zeroes YMM3. rt_sigreturn must bring
 * back all 256 bits, not just the low 128 that FXSAVE's image holds.
 * Where the CPU or h9 doesn't offer AVX (KVM hides it), there's nothing
 * to check. */
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>

#if defined(__x86_64__)
#include <cpuid.h>

static volatile int handled;

__attribute__((target("avx"))) static void onusr1(int s) {
	(void)s;
	__asm__ volatile("vpxor %%xmm3, %%xmm3, %%xmm3" ::: "xmm3");
	handled++;
}

static int avx(void) {
	unsigned a, b, c, d;
	if (!__get_cpuid(1, &a, &b, &c, &d)) return 0;
	if (!(c & (1u << 27)) || !(c & (1u << 28))) return 0;
	unsigned lo, hi;
	__asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
	return (lo & 6) == 6;
}

__attribute__((target("avx"))) static int check(long pid) {
	unsigned char in[32], out[32];
	for (int i = 0; i < 32; i++) in[i] = (unsigned char)(i * 7 + 1);
	for (int round = 0; round < 100; round++) {
		long ret;
		__asm__ volatile(
			"vmovdqu (%[in]), %%ymm3\n"
			"syscall\n"
			"vmovdqu %%ymm3, (%[out])\n"
			: "=a"(ret)
			: "a"((long)SYS_kill), "D"(pid), "S"((long)SIGUSR1), [in] "r"(in), [out] "r"(out)
			: "rcx", "r11", "memory", "xmm3");
		if (ret != 0) return printf("kill: %ld\n", ret), 1;
		if (memcmp(in, out, 32) != 0) {
			printf("round %d: YMM3 changed by the handler:", round);
			for (int i = 0; i < 32; i++) printf(" %02x", out[i]);
			printf("\n");
			return 1;
		}
	}
	return 0;
}

int main(void) {
	if (!avx()) return printf("ok\n"), 0;
	signal(SIGUSR1, onusr1);
	if (check(getpid())) return 1;
	printf(handled == 100 ? "ok\n" : "handled %d\n", handled);
	return 0;
}
#else
int main(void) { printf("ok\n"); return 0; }
#endif
