/* Copy-on-write fork and demand-loaded file pages (design/cow-fork.md):
 * each case named on the command line prints "ok NAME" or
 * "FAIL NAME: why", and the exit status is 1 if any failed.
 *
 *   big       a fork of a process with 600 MB of written heap (run under
 *             --memory 1g, where copying it at fork couldn't)
 *   isolate   after fork, a read() into a buffer, a write from another
 *             thread, and a futex word change stay in their process
 *   oom       a child's writes that need more memory than there is: it
 *             gets SIGSEGV, and the parent goes on (run under a small
 *             --memory)
 *   dontneed  MADV_DONTNEED after fork zeroes the range in one process
 *   filemap   a private mapping of a 200 MB file costs only the chunks
 *             touched, as VmRSS shows, in the parent and after fork
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/futex.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int failed;

#define CHECK(name, cond) do { if (!(cond)) { printf("FAIL %s: %s (errno %d %s)\n", name, #cond, errno, strerror(errno)); fflush(stdout); failed = 1; return; } } while (0)
/* In a child: report and exit with status 1. */
#define CCHECK(name, cond) do { if (!(cond)) { printf("FAIL %s (child): %s (errno %d %s)\n", name, #cond, errno, strerror(errno)); fflush(stdout); _exit(1); } } while (0)

enum { MB = 1 << 20 };

static void msleep(long ms) {
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000 };
	nanosleep(&ts, NULL);
}

/* VmRSS from /proc/self/status, in kB, or -1. */
static long vmrss(void) {
	char buf[4096];
	int fd = open("/proc/self/status", O_RDONLY);
	if (fd < 0)
		return -1;
	ssize_t n = read(fd, buf, sizeof buf - 1);
	close(fd);
	if (n <= 0)
		return -1;
	buf[n] = 0;
	char *p = strstr(buf, "VmRSS:");
	return p ? strtol(p + 6, NULL, 10) : -1;
}

static int child_status(pid_t c) {
	int st;
	if (waitpid(c, &st, 0) != c)
		return -1;
	return st;
}

/* 600 MB written, then fork: each side writes a few pages and sees only
 * its own writes. */
static void big(void) {
	const size_t n = 600 * (size_t)MB;
	unsigned char *h = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK("big", h != MAP_FAILED);
	for (size_t off = 0; off < n; off += 4096)
		h[off] = (unsigned char)(off / MB) | 1, h[off + 4095] = 0x5a;
	pid_t c = fork();
	CHECK("big", c >= 0);
	if (c == 0) {
		for (size_t off = 0; off < n; off += MB)
			CCHECK("big", h[off] == ((unsigned char)(off / MB) | 1) && h[off + 4095] == 0x5a);
		for (size_t i = 0; i < 16; i++)
			h[i * 37 * MB] = 0xc0;
		for (size_t i = 0; i < 16; i++)
			CCHECK("big", h[i * 37 * MB] == 0xc0 && h[i * 37 * MB + 4095] == 0x5a);
		_exit(0);
	}
	for (size_t i = 0; i < 16; i++)
		h[i * 37 * MB + 4096] = 0xd0;
	int st = child_status(c);
	CHECK("big", WIFEXITED(st) && WEXITSTATUS(st) == 0);
	for (size_t off = 0; off < n; off += 4096) {
		unsigned char want = (unsigned char)(off / MB) | 1;
		if (off % (37 * MB) == 4096 && off / (37 * MB) < 16)
			want = 0xd0;
		CHECK("big", h[off] == want && h[off + 4095] == 0x5a);
	}
	/* The pages are the parent's alone now: writing all of them copies
	 * nothing. */
	memset(h, 0x11, n);
	CHECK("big", h[n - 1] == 0x11);
	munmap(h, n);
	printf("ok big\n");
}

/* After fork, a read() into a buffer, another thread's write, and a
 * futex word change each stay in the process that made them. Each is in
 * a chunk of its own, inside a mapping, so the first thing to write it
 * after fork is the case's own access, not libc's. */
static char *rbuf_parent, *rbuf_child;
static volatile int *shared_word;
static atomic_int *fword;
static int cmd[2], ack[2];

static void *writer(void *a) {
	(void)a;
	char x;
	if (read(cmd[0], &x, 1) != 1)
		return NULL;
	*shared_word = 2;
	write(ack[1], "k", 1);
	return NULL;
}

static void *waiter(void *a) {
	(void)a;
	while (atomic_load(fword) == 0)
		syscall(SYS_futex, fword, FUTEX_WAIT, 0, NULL, NULL, 0);
	return NULL;
}

static void isolate(void) {
	int go[2], done[2], pp[2], cp[2];
	char *iso = mmap(NULL, 6 * MB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK("isolate", iso != MAP_FAILED);
	rbuf_parent = iso + 1 * MB;
	rbuf_child = iso + 2 * MB;
	shared_word = (volatile int *)(iso + 3 * MB);
	fword = (atomic_int *)(iso + 4 * MB);
	strcpy(rbuf_parent, "original");
	strcpy(rbuf_child, "original");
	*shared_word = 1;
	atomic_store(fword, 0);
	CHECK("isolate", pipe(cmd) == 0 && pipe(ack) == 0 && pipe(go) == 0 && pipe(done) == 0 && pipe(pp) == 0 && pipe(cp) == 0);
	pthread_t t;
	CHECK("isolate", pthread_create(&t, NULL, writer, NULL) == 0);
	pid_t c = fork();
	CHECK("isolate", c >= 0);
	char x;
	if (c == 0) {
		/* A read into the child's buffer, which the parent shares
		 * until a write. */
		CCHECK("isolate", write(cp[1], "from child", 11) == 11);
		CCHECK("isolate", read(cp[0], rbuf_child, 64) == 11);
		CCHECK("isolate", strcmp(rbuf_child, "from child") == 0);
		/* A futex the child's threads wait and wake on: its word is
		 * the child's own, and a wake isn't lost. */
		pthread_t w;
		CCHECK("isolate", pthread_create(&w, NULL, waiter, NULL) == 0);
		msleep(20);
		atomic_store(fword, 1);
		syscall(SYS_futex, fword, FUTEX_WAKE, 1, NULL, NULL, 0);
		CCHECK("isolate", pthread_join(w, NULL) == 0);
		/* Wait for the parent's read and its thread's write. */
		CCHECK("isolate", read(go[0], &x, 1) == 1);
		CCHECK("isolate", strcmp(rbuf_parent, "original") == 0);
		CCHECK("isolate", *shared_word == 1);
		write(done[1], "d", 1);
		_exit(0);
	}
	CHECK("isolate", write(pp[1], "from parent", 12) == 12);
	CHECK("isolate", read(pp[0], rbuf_parent, 64) == 12);
	write(cmd[1], "w", 1);
	CHECK("isolate", read(ack[0], &x, 1) == 1);
	CHECK("isolate", *shared_word == 2);
	write(go[1], "g", 1);
	CHECK("isolate", read(done[0], &x, 1) == 1);
	int st = child_status(c);
	CHECK("isolate", WIFEXITED(st) && WEXITSTATUS(st) == 0);
	CHECK("isolate", strcmp(rbuf_child, "original") == 0);
	CHECK("isolate", strcmp(rbuf_parent, "from parent") == 0);
	CHECK("isolate", atomic_load(fword) == 0);
	pthread_join(t, NULL);
	munmap(iso, 6 * MB);
	printf("ok isolate\n");
}

/* A child that writes all of a heap its parent shares, under a --memory
 * that holds only one copy, runs out at a write and gets SIGSEGV; the
 * parent's pages are as they were, and it goes on. */
static void oom(int mb) {
	const size_t n = (size_t)mb * MB;
	unsigned char *h = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK("oom", h != MAP_FAILED);
	for (size_t off = 0; off < n; off += 4096)
		h[off] = 0x77;
	pid_t c = fork();
	CHECK("oom", c >= 0);
	if (c == 0) {
		for (size_t off = 0; off < n; off += 4096)
			h[off] = 0x88;
		_exit(0);
	}
	int st = child_status(c);
	CHECK("oom", WIFSIGNALED(st) && WTERMSIG(st) == SIGSEGV);
	for (size_t off = 0; off < n; off += 4096)
		CHECK("oom", h[off] == 0x77);
	for (size_t off = 0; off < n; off += 4096)
		h[off] = 0x99;
	c = fork();
	CHECK("oom", c >= 0);
	if (c == 0)
		_exit(h[n - 4096] == 0x99 ? 0 : 1);
	st = child_status(c);
	CHECK("oom", WIFEXITED(st) && WEXITSTATUS(st) == 0);
	munmap(h, n);
	printf("ok oom\n");
}

/* MADV_DONTNEED after fork, of whole chunks and of a page, zeroes the
 * range in the process that asked only. */
static void dontneed(void) {
	const size_t n = 4 * MB;
	unsigned char *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	unsigned char *q = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK("dontneed", p != MAP_FAILED && q != MAP_FAILED);
	memset(p, 0xab, n);
	memset(q, 0xcd, n);
	pid_t c = fork();
	CHECK("dontneed", c >= 0);
	if (c == 0) {
		CCHECK("dontneed", madvise(p, n, MADV_DONTNEED) == 0);
		for (size_t i = 0; i < n; i += 512)
			CCHECK("dontneed", p[i] == 0);
		CCHECK("dontneed", madvise(q + MB + 8192, 4096, MADV_DONTNEED) == 0);
		for (size_t i = 0; i < n; i += 512)
			CCHECK("dontneed", q[i] == (i >= MB + 8192 && i < MB + 12288 ? 0 : 0xcd));
		_exit(0);
	}
	int st = child_status(c);
	CHECK("dontneed", WIFEXITED(st) && WEXITSTATUS(st) == 0);
	for (size_t i = 0; i < n; i++)
		CHECK("dontneed", p[i] == 0xab && q[i] == 0xcd);
	printf("ok dontneed\n");
}

/* A 200 MB file mapped private: touching three of its chunks costs about
 * three chunks, and a child after fork reads one the parent never
 * loaded. */
static void filemap(void) {
	const size_t n = 200 * (size_t)MB;
	const char *path = "/tmp/cowfork.dat";
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	CHECK("filemap", fd >= 0);
	CHECK("filemap", ftruncate(fd, n) == 0);
	for (size_t i = 0; i < 200; i++) {
		unsigned char b = (unsigned char)i | 0x80;
		CHECK("filemap", pwrite(fd, &b, 1, i * MB + 123) == 1);
	}
	long before = vmrss();
	const volatile unsigned char *m = mmap(NULL, n, PROT_READ, MAP_PRIVATE, fd, 0);
	CHECK("filemap", m != MAP_FAILED);
	close(fd);
	unlink(path);
	CHECK("filemap", m[123] == 0x80 && m[100 * MB + 123] == (100 | 0x80) && m[199 * MB + 123] == (199 | 0x80));
	CHECK("filemap", m[5 * MB] == 0);
	long after = vmrss();
	CHECK("filemap", before > 0 && after > 0);
	/* Four chunks touched, which is 4 MB, with room to spare. */
	if (after - before > 16 * 1024) {
		printf("FAIL filemap: VmRSS grew %ld kB\n", after - before);
		failed = 1;
		return;
	}
	pid_t c = fork();
	CHECK("filemap", c >= 0);
	if (c == 0) {
		CCHECK("filemap", m[50 * MB + 123] == (50 | 0x80) && m[100 * MB + 123] == (100 | 0x80));
		_exit(0);
	}
	int st = child_status(c);
	CHECK("filemap", WIFEXITED(st) && WEXITSTATUS(st) == 0);
	munmap((void *)m, n);
	printf("ok filemap\n");
}

int main(int argc, char **argv) {
	setvbuf(stdout, NULL, _IOLBF, 0);
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (!strcmp(a, "big"))
			big();
		else if (!strncmp(a, "oom", 3))
			oom(a[3] == '=' ? atoi(a + 4) : 160);
		else if (!strcmp(a, "isolate"))
			isolate();
		else if (!strcmp(a, "dontneed"))
			dontneed();
		else if (!strcmp(a, "filemap"))
			filemap();
		else {
			printf("FAIL %s: no such case\n", a);
			failed = 1;
		}
	}
	return failed;
}
