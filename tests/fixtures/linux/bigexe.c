/*
 * A static program 170 MB on disk, nearly all of it a read-only blob it
 * touches only at its two ends, for the [cow-fork] case: exec fills an
 * executable's pages from the file as they're touched (elf.load), so it
 * runs under --memory 64m, where copying it in at exec couldn't. It also
 * checks an initialized global and a zero one, whose pages elf.load
 * copies (a segment's last file page holds the start of the bss).
 */
#include <stdio.h>

__asm__(".section .rodata\n"
	".globl big\n"
	"big:\n"
	".byte 0x41\n"
	".fill 178257918, 1, 0x5a\n"
	".byte 0x42\n"
	".globl big_end\n"
	"big_end:\n"
	".previous\n");

extern const unsigned char big[], big_end[];

int data = 7;
int bss;

int main(void)
{
	/* volatile, so the compiler reads the blob rather than folding it. */
	const volatile unsigned char *b = big, *e = big_end;
	unsigned long n = (unsigned long)(e - b);

	printf("size %lu first %c mid %c last %c data %d bss %d\n", n, b[0], b[n / 2], e[-1], data, bss);
	return 0;
}
