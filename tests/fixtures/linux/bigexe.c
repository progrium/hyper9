/*
 * A static program 170 MB on disk, nearly all of it a read-only blob it
 * touches only at its two ends, for the [cow-fork] case: exec fills an
 * executable's pages from the file as they're touched (elf.load), so it
 * runs under --memory 64m, where copying it in at exec couldn't. It also
 * checks an initialized global and a zero one, whose pages elf.load
 * copies (a segment's last file page holds the start of the bss).
 *
 * `bigexe share N` runs N copies of itself at once (`touch`), each of
 * which reads every page of the blob and waits: they share its pages
 * through the page cache (pagecache.zig), so they fit in a --memory
 * that holds one copy of it.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

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

/* Reads every page of the blob, says so on `ready`, and waits for
 * `go`'s end. */
static int touch(int ready, int go)
{
	const volatile unsigned char *b = big, *e = big_end;
	unsigned long n = (unsigned long)(e - b), sum = 0;
	for (unsigned long i = 0; i < n; i += 4096)
		sum += b[i];
	sum += e[-1];
	/* 'A' first, 'B' last, and 'Z' on every other page read. */
	unsigned long pages = (n + 4095) / 4096;
	if (sum != 0x41 + (pages - 1) * 0x5a + 0x42)
		return 2;
	if (write(ready, "r", 1) != 1)
		return 3;
	char c;
	while (read(go, &c, 1) > 0)
		;
	return 0;
}

static int share(const char *self, int n)
{
	int ready[2], go[2];
	if (pipe(ready) != 0 || pipe(go) != 0)
		return 1;
	for (int i = 0; i < n; i++) {
		pid_t c = fork();
		if (c < 0)
			return 1;
		if (c == 0) {
			char rs[16], gs[16];
			close(ready[0]);
			close(go[1]);
			snprintf(rs, sizeof rs, "%d", ready[1]);
			snprintf(gs, sizeof gs, "%d", go[0]);
			execl(self, self, "touch", rs, gs, (char *)0);
			_exit(4);
		}
	}
	close(ready[1]);
	close(go[0]);
	int got = 0;
	char c;
	while (got < n && read(ready[0], &c, 1) == 1)
		got++;
	close(go[1]);
	int ok = got == n;
	for (int i = 0; i < n; i++) {
		int st;
		if (wait(&st) < 0 || !WIFEXITED(st) || WEXITSTATUS(st) != 0) {
			printf("FAIL share: a copy ended with status %#x\n", st);
			ok = 0;
		}
	}
	if (!ok)
		return 1;
	printf("ok share %d\n", n);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc == 4 && !strcmp(argv[1], "touch"))
		return touch(atoi(argv[2]), atoi(argv[3]));
	if (argc == 3 && !strcmp(argv[1], "share"))
		return share(argv[0], atoi(argv[2]));
	/* volatile, so the compiler reads the blob rather than folding it. */
	const volatile unsigned char *b = big, *e = big_end;
	unsigned long n = (unsigned long)(e - b);

	printf("size %lu first %c mid %c last %c data %d bss %d\n", n, b[0], b[n / 2], e[-1], data, bss);
	return 0;
}
