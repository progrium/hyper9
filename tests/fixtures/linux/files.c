/* What databases need of files (design/0018-linux-personality.md): each
 * case named on the command line prints "ok NAME" or "FAIL NAME: why".
 * They work in the directory given by $DIR, or /tmp. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <grp.h>
#include <semaphore.h>
#include <signal.h>
#include <sys/auxv.h>
#include <sys/file.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/epoll.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int failed;

#define CHECK(name, cond) do { if (!(cond)) { printf("FAIL %s: %s (errno %d %s)\n", name, #cond, errno, strerror(errno)); failed = 1; return; } } while (0)

static char path[256];

static int fresh(const char *name) {
	const char *d = getenv("DIR");
	snprintf(path, sizeof path, "%s/%s", d ? d : "/tmp", name);
	unlink(path);
	return open(path, O_RDWR | O_CREAT, 0644);
}

static int setlk(int fd, int cmd, short type, off_t start, off_t len) {
	struct flock l = {.l_type = type, .l_whence = SEEK_SET, .l_start = start, .l_len = len};
	return fcntl(fd, cmd, &l);
}

/* The child's exit status says what it saw: 0 for what was expected. */
static int child_status(pid_t c) {
	int st;
	if (waitpid(c, &st, 0) != c || !WIFEXITED(st))
		return -1;
	return WEXITSTATUS(st);
}

static void posix_locks(void) {
	int fd = fresh("locks");
	CHECK("posix_locks", fd >= 0 && write(fd, "0123456789", 10) == 10);
	CHECK("posix_locks", setlk(fd, F_SETLK, F_WRLCK, 0, 5) == 0);
	CHECK("posix_locks", setlk(fd, F_SETLK, F_RDLCK, 5, 5) == 0);
	pid_t parent = getpid();
	pid_t c = fork();
	if (c == 0) {
		int f = open(path, O_RDWR);
		/* A write lock over the parent's conflicts; a read lock over its read lock doesn't. */
		if (setlk(f, F_SETLK, F_WRLCK, 2, 1) == 0 || errno != EAGAIN) _exit(1);
		if (setlk(f, F_SETLK, F_RDLCK, 6, 2) != 0) _exit(2);
		struct flock l = {.l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 0};
		if (fcntl(f, F_GETLK, &l) != 0 || l.l_type != F_WRLCK || l.l_pid != parent || l.l_start != 0 || l.l_len != 5) _exit(3);
		/* Waits for the parent to close an fd of the file, which drops its locks. */
		if (setlk(f, F_SETLKW, F_WRLCK, 0, 5) != 0) _exit(4);
		_exit(0);
	}
	usleep(200000);
	/* Closing any fd of the file releases this process's locks. */
	int other = open(path, O_RDONLY);
	close(other);
	CHECK("posix_locks", child_status(c) == 0);
	/* The child's locks went with it. */
	CHECK("posix_locks", setlk(fd, F_SETLK, F_WRLCK, 0, 0) == 0);
	close(fd);
	printf("ok posix_locks\n");
}

static void ofd_flock(void) {
	int a = fresh("ofd");
	int b = open(path, O_RDWR);
	CHECK("ofd_flock", a >= 0 && b >= 0);
	/* OFD locks belong to the open file, so two opens in one process conflict. */
	struct flock l = {.l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 1};
	CHECK("ofd_flock", fcntl(a, F_OFD_SETLK, &l) == 0);
	CHECK("ofd_flock", fcntl(b, F_OFD_SETLK, &l) < 0 && errno == EAGAIN);
	l.l_type = F_UNLCK;
	CHECK("ofd_flock", fcntl(a, F_OFD_SETLK, &l) == 0);
	/* flock: shared twice, then exclusive refused; a dup shares the lock. */
	CHECK("ofd_flock", flock(a, LOCK_SH) == 0 && flock(b, LOCK_SH) == 0);
	CHECK("ofd_flock", flock(a, LOCK_EX | LOCK_NB) < 0 && errno == EWOULDBLOCK);
	CHECK("ofd_flock", flock(b, LOCK_UN) == 0 && flock(a, LOCK_EX | LOCK_NB) == 0);
	int d = dup(a);
	close(a);
	CHECK("ofd_flock", flock(b, LOCK_SH | LOCK_NB) < 0 && errno == EWOULDBLOCK);
	close(d);
	CHECK("ofd_flock", flock(b, LOCK_EX | LOCK_NB) == 0);
	close(b);
	printf("ok ofd_flock\n");
}

/* A flock goes with the last fd of its open file, even when that's a
 * child's close-on-exec copy that exec closes after the parent closed its
 * own (Zig's cache locks, held while it spawns clang). */
static void flock_exec(void) {
	int fd = fresh("flexec");
	int p[2];
	CHECK("flock_exec", fd >= 0 && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && pipe(p) == 0);
	CHECK("flock_exec", flock(fd, LOCK_EX) == 0);
	pid_t c = fork();
	if (c == 0) {
		char b;
		close(p[1]);
		if (read(p[0], &b, 1) != 1) _exit(2);
		execl("/bin/true", "true", (char *)0);
		_exit(3);
	}
	close(p[0]);
	close(fd);
	CHECK("flock_exec", write(p[1], "x", 1) == 1);
	int st;
	CHECK("flock_exec", waitpid(c, &st, 0) == c && WIFEXITED(st) && WEXITSTATUS(st) == 0);
	close(p[1]);
	int g = open(path, O_RDWR);
	CHECK("flock_exec", g >= 0 && flock(g, LOCK_EX | LOCK_NB) == 0);
	close(g);
	printf("ok flock_exec\n");
}

static void shared_map(void) {
	int fd = fresh("shm");
	/* SQLite's -shm: grown by writing its last byte, then mapped at an offset. */
	CHECK("shared_map", fd >= 0 && pwrite(fd, "", 1, 65535) == 1);
	char *m = mmap(0, 32768, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 32768);
	CHECK("shared_map", m != MAP_FAILED);
	strcpy(m, "parent");
	pid_t c = fork();
	if (c == 0) {
		/* A fresh mapping in the child sees the parent's store, and the parent sees the child's. */
		int f = open(path, O_RDWR);
		char *n = mmap(0, 65536, PROT_READ | PROT_WRITE, MAP_SHARED, f, 0);
		if (n == MAP_FAILED || strcmp(n + 32768, "parent") != 0) _exit(1);
		strcpy(n + 32768 + 100, "child");
		/* read() sees what's mapped, and a pwrite reaches the mappings. */
		char b[8] = {0};
		if (pread(f, b, 6, 32768) != 6 || strcmp(b, "parent") != 0) _exit(2);
		if (pwrite(f, "pw", 2, 32768 + 200) != 2) _exit(3);
		_exit(0);
	}
	CHECK("shared_map", child_status(c) == 0);
	CHECK("shared_map", strcmp(m + 100, "child") == 0 && memcmp(m + 200, "pw", 2) == 0);
	CHECK("shared_map", munmap(m, 32768) == 0);
	close(fd);
	/* With every mapping gone, the file holds what they stored. */
	fd = open(path, O_RDONLY);
	char b[8] = {0};
	CHECK("shared_map", pread(fd, b, 5, 32768 + 100) == 5 && strcmp(b, "child") == 0);
	/* A writable shared mapping needs an fd open for reading and writing. */
	CHECK("shared_map", mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) == MAP_FAILED && errno == EACCES);
	close(fd);
	printf("ok shared_map\n");
}

/* Shared file mappings placed by MAP_FIXED anywhere, beside private
 * pages in the same MiB, as Wine maps its shared user data page at
 * 0x7ffe0000: they see the file's other mappings and its writes. */
static void fixed_shared(void) {
	int fd = fresh("fixed");
	CHECK("fixed_shared", fd >= 0 && ftruncate(fd, (2 << 20) + 16384) == 0);
	char *w = mmap(0, (2 << 20) + 16384, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	char *area = mmap(0, 4 << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK("fixed_shared", w != MAP_FAILED && area != MAP_FAILED);
	char *base = (char *)(((unsigned long)area + (1 << 20) - 1) & ~((1UL << 20) - 1));
	strcpy(base, "private");
	/* Two pages at file offset 4096, at base + 12 KiB. */
	char *fix = mmap(base + 0x3000, 8192, PROT_READ, MAP_SHARED | MAP_FIXED, fd, 4096);
	CHECK("fixed_shared", fix == base + 0x3000);
	strcpy(w + 4096, "one");
	strcpy(w + 8192, "two");
	CHECK("fixed_shared", strcmp(fix, "one") == 0 && strcmp(fix + 4096, "two") == 0 && strcmp(base, "private") == 0);
	CHECK("fixed_shared", pwrite(fd, "pw", 2, 8192 + 100) == 2 && memcmp(fix + 4096 + 100, "pw", 2) == 0);
	/* Three pages that cross a MiB in memory and a MiB of the file. */
	char *x = mmap(base + 0xff000, 0x3000, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0xfe000);
	CHECK("fixed_shared", x == base + 0xff000);
	strcpy(x + 0x2000, "across");
	CHECK("fixed_shared", strcmp(w + 0x100000, "across") == 0);
	strcpy(w + 0xfe000, "before");
	CHECK("fixed_shared", strcmp(x, "before") == 0);
	/* Across fork: the child's stores reach the parent's mappings, and its private page is its own. */
	pid_t c = fork();
	if (c == 0) {
		if (strcmp(fix, "one") != 0 || strcmp(x + 0x2000, "across") != 0) _exit(1);
		strcpy(w + 4096, "child");
		strcpy(x + 0x1000, "kid");
		strcpy(base, "kid");
		_exit(0);
	}
	CHECK("fixed_shared", child_status(c) == 0);
	CHECK("fixed_shared", strcmp(fix, "child") == 0 && strcmp(w + 0xff000, "kid") == 0 && strcmp(base, "private") == 0);
	/* Unmapping one page leaves the other, and its place is private memory again. */
	CHECK("fixed_shared", munmap(fix, 4096) == 0 && strcmp(fix + 4096, "two") == 0);
	CHECK("fixed_shared", mmap(fix, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == fix);
	strcpy(fix, "anon");
	CHECK("fixed_shared", strcmp(w + 4096, "child") == 0);
	CHECK("fixed_shared", munmap(fix, 8192) == 0 && munmap(x, 0x3000) == 0 && munmap(area, 4 << 20) == 0);
	CHECK("fixed_shared", munmap(w, (2 << 20) + 16384) == 0);
	/* The file kept the stores. */
	char b[8] = {0};
	CHECK("fixed_shared", pread(fd, b, 6, 0x100000) == 6 && strcmp(b, "across") == 0);
	close(fd);
	printf("ok fixed_shared\n");
}

/* A private mapping of a file mapped shared sees later writes to it
 * until a page is written, as on Linux: Wine reads wineserver's session
 * memory through one. */
static void private_sees(void) {
	int fd = fresh("cow");
	CHECK("private_sees", fd >= 0 && ftruncate(fd, 8192) == 0);
	char *w = mmap(0, 8192, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	char *r = mmap(0, 8192, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
	CHECK("private_sees", w != MAP_FAILED && r != MAP_FAILED);
	strcpy(w, "first");
	CHECK("private_sees", strcmp(r, "first") == 0);
	strcpy(r + 4096, "mine");
	strcpy(w + 4096, "theirs");
	strcpy(w, "second");
	CHECK("private_sees", strcmp(r, "second") == 0 && strcmp(r + 4096, "mine") == 0);
	/* A child sees the file through the pages neither wrote, and its write is its own. */
	pid_t c = fork();
	if (c == 0) {
		if (strcmp(r, "second") != 0 || strcmp(r + 4096, "mine") != 0) _exit(1);
		strcpy(r, "child");
		if (strcmp(w, "second") != 0) _exit(2);
		_exit(0);
	}
	CHECK("private_sees", child_status(c) == 0 && strcmp(r, "second") == 0);
	/* A read() into the mapping writes the process's own copy, not the file. */
	CHECK("private_sees", pwrite(fd, "zz", 2, 100) == 2 && pread(fd, r, 2, 100) == 2);
	strcpy(w, "third");
	CHECK("private_sees", memcmp(r, "zz", 2) == 0 && strcmp(w, "third") == 0);
	CHECK("private_sees", munmap(r, 8192) == 0 && munmap(w, 8192) == 0);
	char b[8] = {0};
	CHECK("private_sees", pread(fd, b, 5, 0) == 5 && strcmp(b, "third") == 0);
	close(fd);
	printf("ok private_sees\n");
}

/* arch_prctl's GS base, where 64-bit Wine keeps the Windows TEB. */
static void gs_base(void) {
#if defined(__x86_64__)
	static long slot[2] = {1234, 5678};
	long got = 0;
	unsigned long base = 0;
	CHECK("gs_base", syscall(SYS_arch_prctl, 0x1001, slot) == 0);
	getpid();
	__asm__ volatile("movq %%gs:8, %0" : "=r"(got));
	CHECK("gs_base", got == 5678);
	CHECK("gs_base", syscall(SYS_arch_prctl, 0x1004, &base) == 0 && base == (unsigned long)slot);
	pid_t c = fork();
	if (c == 0) {
		long v = 0;
		__asm__ volatile("movq %%gs:0, %0" : "=r"(v));
		_exit(v == 1234 ? 0 : 1);
	}
	CHECK("gs_base", child_status(c) == 0);
#endif
	printf("ok gs_base\n");
}

static void fsync_rusage(void) {
	int fd = fresh("sync");
	CHECK("fsync_rusage", fd >= 0 && write(fd, "x", 1) == 1 && fsync(fd) == 0 && fdatasync(fd) == 0);
	close(fd);
	pid_t c = fork();
	if (c == 0) {
		struct timespec t0, t;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		volatile unsigned long x = 0;
		do {
			for (int i = 0; i < 100000; i++) x += i;
			clock_gettime(CLOCK_MONOTONIC, &t);
		} while ((t.tv_sec - t0.tv_sec) * 1000 + (t.tv_nsec - t0.tv_nsec) / 1000000 < 300);
		_exit(0);
	}
	int st;
	struct rusage ru;
	CHECK("fsync_rusage", wait4(c, &st, 0, &ru) == c);
	CHECK("fsync_rusage", ru.ru_utime.tv_sec * 1000000 + ru.ru_utime.tv_usec + ru.ru_stime.tv_sec * 1000000 + ru.ru_stime.tv_usec > 0);
	struct rusage ch;
	CHECK("fsync_rusage", getrusage(RUSAGE_CHILDREN, &ch) == 0 && ch.ru_utime.tv_sec * 1000000 + ch.ru_utime.tv_usec + ch.ru_stime.tv_sec * 1000000 + ch.ru_stime.tv_usec > 0);
	struct rusage self;
	CHECK("fsync_rusage", getrusage(RUSAGE_SELF, &self) == 0 && self.ru_maxrss > 0);
	printf("ok fsync_rusage\n");
}

static void dir_sync(void) {
	/* PostgreSQL's durable_rename: write, fsync, rename, fsync the directory. */
	const char *d = getenv("DIR");
	if (!d) d = "/tmp";
	int fd = fresh("dsync.tmp");
	char tmp[256];
	snprintf(tmp, sizeof tmp, "%s", path);
	snprintf(path, sizeof path, "%s/dsync", d);
	CHECK("dir_sync", fd >= 0 && write(fd, "x", 1) == 1 && fsync(fd) == 0 && rename(tmp, path) == 0);
	close(fd);
	int dfd = open(d, O_RDONLY | O_DIRECTORY);
	CHECK("dir_sync", dfd >= 0);
	CHECK("dir_sync", fsync(dfd) == 0 && fdatasync(dfd) == 0 && syncfs(dfd) == 0);
	close(dfd);
	sync();
	CHECK("dir_sync", syncfs(-1) < 0 && errno == EBADF);
	CHECK("dir_sync", fsync(dfd) < 0 && errno == EBADF);
	unlink(path);
	printf("ok dir_sync\n");
}

static void read_cache(void) {
	int fd = fresh("cache");
	char page[4096];
	for (int i = 0; i < 64; i++) {
		memset(page, 'a' + i % 26, sizeof page);
		CHECK("read_cache", write(fd, page, sizeof page) == sizeof page);
	}
	/* Page-by-page reads, then a write through another fd: the next read sees it. */
	char b[4096];
	for (int i = 0; i < 64; i++)
		CHECK("read_cache", pread(fd, b, sizeof b, i * 4096) == 4096 && b[0] == 'a' + i % 26 && b[4095] == b[0]);
	int w = open(path, O_WRONLY);
	CHECK("read_cache", pwrite(w, "ZZ", 2, 4096 * 3 + 10) == 2);
	CHECK("read_cache", pread(fd, b, 4, 4096 * 3 + 9) == 4 && memcmp(b, "dZZd", 4) == 0);
	/* A read past the end, and a truncate. */
	CHECK("read_cache", pread(fd, b, 100, 64 * 4096 - 50) == 50);
	CHECK("read_cache", ftruncate(w, 4096) == 0 && pread(fd, b, 10, 8192) == 0);
	close(w);
	close(fd);
	printf("ok read_cache\n");
}

static void falloc(void) {
	/* PostgreSQL grows relations with posix_fallocate. */
	int fd = fresh("falloc");
	struct stat st;
	CHECK("falloc", fd >= 0 && write(fd, "abc", 3) == 3);
	CHECK("falloc", posix_fallocate(fd, 0, 65536) == 0 && fstat(fd, &st) == 0 && st.st_size == 65536);
	CHECK("falloc", fallocate(fd, FALLOC_FL_KEEP_SIZE, 0, 1 << 20) == 0 && fstat(fd, &st) == 0 && st.st_size == 65536);
	CHECK("falloc", fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, 0, 4096) < 0 && errno == EOPNOTSUPP);
	char b[4];
	CHECK("falloc", pread(fd, b, 4, 0) == 4 && memcmp(b, "abc", 4) == 0);
	/* A lock from SEEK_END is relative to that length. */
	struct flock l = {.l_type = F_WRLCK, .l_whence = SEEK_END, .l_start = -1, .l_len = 1};
	CHECK("falloc", fcntl(fd, F_SETLK, &l) == 0);
	l.l_whence = SEEK_SET;
	l.l_start = 0;
	l.l_len = 0;
	CHECK("falloc", fcntl(fd, F_GETLK, &l) == 0 && l.l_type == F_UNLCK);
	close(fd);
	printf("ok falloc\n");
}

/* Redis's AOF moves its rewrite from its dir into appendonlydir, over an
 * existing file. In a host tree it's the host's rename; in an overlay
 * (/tmp) it's a move in memory, which Zig's cache needs for directories
 * too: each entry is made in tmp/ and renamed into o/. */
static void rename_across(void) {
	const char *d = getenv("DIR");
	char a[300], b[300], f[300], g[300], s[300], t[300], u[300];
	snprintf(a, sizeof a, "%s/ra", d ? d : "/tmp");
	snprintf(b, sizeof b, "%s/rb", d ? d : "/tmp");
	snprintf(f, sizeof f, "%s/f", a);
	snprintf(g, sizeof g, "%s/g", b);
	snprintf(s, sizeof s, "%s/sub", a);
	snprintf(t, sizeof t, "%s/sub", b);
	snprintf(u, sizeof u, "%s/sub/in", b);
	mkdir(a, 0755);
	mkdir(b, 0755);
	int fd = open(f, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	CHECK("rename_across", fd >= 0 && write(fd, "new", 3) == 3 && close(fd) == 0);
	fd = open(g, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	CHECK("rename_across", fd >= 0 && write(fd, "old!", 4) == 4 && close(fd) == 0);
	char buf[8] = {0};
	CHECK("rename_across", rename(f, g) == 0 && access(f, F_OK) < 0);
	fd = open(g, O_RDONLY);
	CHECK("rename_across", fd >= 0 && read(fd, buf, sizeof buf) == 3 && memcmp(buf, "new", 3) == 0);
	close(fd);
	CHECK("rename_across", rename(g, f) == 0 && unlink(f) == 0);
	/* A directory with a file in it, and not into itself. */
	CHECK("rename_across", mkdir(s, 0755) == 0);
	snprintf(f, sizeof f, "%s/in", s);
	fd = open(f, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	CHECK("rename_across", fd >= 0 && close(fd) == 0);
	CHECK("rename_across", rename(s, t) == 0 && access(s, F_OK) < 0 && access(u, F_OK) == 0);
	snprintf(g, sizeof g, "%s/sub/x", b);
	CHECK("rename_across", rename(b, g) < 0 && errno == EINVAL);
	CHECK("rename_across", unlink(u) == 0 && rmdir(t) == 0);
	/* Zig's cache: renameat from tmp/'s fd into o/'s, then ftruncate and
	 * fchmod of the output it still has open. */
	int da = open(a, O_RDONLY | O_DIRECTORY), db = open(b, O_RDONLY | O_DIRECTORY);
	CHECK("rename_across", da >= 0 && db >= 0);
	fd = openat(da, "out", O_RDWR | O_CREAT | O_TRUNC, 0644);
	CHECK("rename_across", fd >= 0 && write(fd, "0123456789", 10) == 10);
	CHECK("rename_across", renameat(da, "out", db, "out") == 0 && faccessat(db, "out", F_OK, 0) == 0);
	struct stat st;
	CHECK("rename_across", ftruncate(fd, 4) == 0 && fchmod(fd, 0755) == 0 && fstat(fd, &st) == 0 && st.st_size == 4);
	CHECK("rename_across", fstatat(db, "out", &st, 0) == 0 && st.st_size == 4 && (st.st_mode & 0777) == 0755);
	close(fd);
	CHECK("rename_across", unlinkat(db, "out", 0) == 0);
	close(da);
	close(db);
	CHECK("rename_across", rmdir(a) == 0 && rmdir(b) == 0);
	printf("ok rename_across\n");
}

/* On arm64, EL0 reads of the ID registers are emulated, as Linux does and
 * HWCAP_CPUID says: Zig and LLVM read them to pick the host CPU. */
static void id_regs(void) {
#if defined(__aarch64__)
	CHECK("id_regs", (getauxval(AT_HWCAP) & (1 << 11)) != 0);
	unsigned long midr, mpidr, isar0, pfr0;
	__asm__ volatile("mrs %0, midr_el1" : "=r"(midr));
	__asm__ volatile("mrs %0, mpidr_el1" : "=r"(mpidr));
	__asm__ volatile("mrs %0, id_aa64isar0_el1" : "=r"(isar0));
	__asm__ volatile("mrs %0, id_aa64pfr0_el1" : "=r"(pfr0));
	/* HVF's trap is emulated with Armv8.0's values; the emulator's CPU
	 * answers for itself. Either way MIDR is an Armv8 part with
	 * architecture 0xf, and MPIDR has its RES1 bit. */
	(void)isar0;
	(void)pfr0;
	CHECK("id_regs", (midr >> 16 & 0xf) == 0xf && (mpidr & 0x80000000) != 0);
#endif
	printf("ok id_regs\n");
}

/* MADV_FREE is EINVAL, as before Linux 4.5, and DONTNEED still zeroes. */
static void madv_free(void) {
	char *m = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK("madv_free", m != MAP_FAILED);
	m[0] = 1;
	CHECK("madv_free", madvise(m, 4096, 8 /* MADV_FREE */) < 0 && errno == EINVAL);
	CHECK("madv_free", m[0] == 1 && madvise(m, 4096, MADV_DONTNEED) == 0 && m[0] == 0);
	munmap(m, 4096);
	printf("ok madv_free\n");
}

static void sysv_shm(void) {
	/* PostgreSQL's interlock: a keyed segment, attached, its attach count read. */
	int id = shmget(0x5a5a0001, 100, IPC_CREAT | IPC_EXCL | 0600);
	CHECK("sysv_shm", id >= 0);
	CHECK("sysv_shm", shmget(0x5a5a0001, 100, IPC_CREAT | IPC_EXCL | 0600) < 0 && errno == EEXIST);
	CHECK("sysv_shm", shmget(0x5a5a0001, 50, 0) == id);
	char *m = shmat(id, 0, 0);
	CHECK("sysv_shm", m != (void *)-1);
	strcpy(m, "parent");
	struct shmid_ds ds;
	CHECK("sysv_shm", shmctl(id, IPC_STAT, &ds) == 0 && ds.shm_nattch == 1 && ds.shm_segsz == 100 && ds.shm_perm.uid == geteuid());
	pid_t c = fork();
	if (c == 0) {
		/* The child has it attached too, and a fresh attach sees the same store. */
		struct shmid_ds d;
		if (shmctl(id, IPC_STAT, &d) != 0 || d.shm_nattch != 2) _exit(1);
		char *n = shmat(id, 0, 0);
		if (n == (void *)-1 || strcmp(n, "parent") != 0) _exit(2);
		strcpy(n + 50, "child");
		_exit(0);
	}
	CHECK("sysv_shm", child_status(c) == 0 && strcmp(m + 50, "child") == 0);
	CHECK("sysv_shm", shmctl(id, IPC_RMID, 0) == 0);
	/* Removed, it stays until detached. */
	CHECK("sysv_shm", strcmp(m, "parent") == 0 && shmdt(m) == 0);
	CHECK("sysv_shm", shmctl(id, IPC_STAT, &ds) < 0 && errno == EINVAL);
	printf("ok sysv_shm\n");
}

static void map_exit(void) {
	/* A child exits with a file still mapped shared and written: its
	 * exit writes the pages back (PostgreSQL's dynamic shared memory in
	 * /dev/shm). */
	int fd = fresh("map_exit");
	CHECK("map_exit", fd >= 0 && ftruncate(fd, 8192) == 0);
	pid_t c = fork();
	if (c == 0) {
		char *m = mmap(0, 8192, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		if (m == MAP_FAILED) _exit(1);
		strcpy(m, "child");
		_exit(0);
	}
	CHECK("map_exit", child_status(c) == 0);
	char b[8] = {0};
	CHECK("map_exit", pread(fd, b, 6, 0) == 6 && strcmp(b, "child") == 0);
	close(fd);
	unlink(path);
	printf("ok map_exit\n");
}

static void shared_sem(void) {
	/* Process-shared semaphores in a MAP_SHARED mapping, as PostgreSQL's,
	 * with pages the parent never touched before the fork. */
	size_t len = 4 << 20;
	char *m = mmap(0, len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	CHECK("shared_sem", m != MAP_FAILED);
	sem_t *s = (sem_t *)(m + len - 4096);
	pid_t c = fork();
	if (c == 0) {
		/* The parent sets the semaphore up after the fork. */
		usleep(100000);
		if (sem_wait(s) != 0) _exit(1);
		if (strcmp(m + 2 * 1048576, "data") != 0) _exit(2);
		strcpy(m + 3 * 1048576, "reply");
		sem_post(s + 1);
		_exit(0);
	}
	CHECK("shared_sem", sem_init(s, 1, 0) == 0 && sem_init(s + 1, 1, 0) == 0);
	strcpy(m + 2 * 1048576, "data");
	CHECK("shared_sem", sem_post(s) == 0 && sem_wait(s + 1) == 0);
	CHECK("shared_sem", strcmp(m + 3 * 1048576, "reply") == 0);
	CHECK("shared_sem", child_status(c) == 0);
	printf("ok shared_sem\n");
}

static void signal_fd(void) {
	sigset_t set;
	sigemptyset(&set);
	sigaddset(&set, SIGURG);
	sigaddset(&set, SIGUSR1);
	CHECK("signal_fd", sigprocmask(SIG_BLOCK, &set, 0) == 0);
	int fd = signalfd(-1, &set, SFD_NONBLOCK | SFD_CLOEXEC);
	CHECK("signal_fd", fd >= 0);
	struct signalfd_siginfo si;
	CHECK("signal_fd", read(fd, &si, sizeof si) < 0 && errno == EAGAIN);
	/* PostgreSQL's latch: a signal to itself wakes epoll through the fd. */
	kill(getpid(), SIGURG);
	int ep = epoll_create1(0);
	struct epoll_event ev = {.events = EPOLLIN, .data.u32 = 7}, out;
	CHECK("signal_fd", epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev) == 0);
	CHECK("signal_fd", epoll_wait(ep, &out, 1, 2000) == 1 && out.data.u32 == 7);
	CHECK("signal_fd", read(fd, &si, sizeof si) == sizeof si && si.ssi_signo == SIGURG);
	CHECK("signal_fd", epoll_wait(ep, &out, 1, 0) == 0);
	/* From another process, while a blocking epoll_wait waits. */
	pid_t parent = getpid();
	pid_t c = fork();
	if (c == 0) {
		usleep(100000);
		kill(parent, SIGUSR1);
		_exit(0);
	}
	CHECK("signal_fd", epoll_wait(ep, &out, 1, 5000) == 1);
	CHECK("signal_fd", read(fd, &si, sizeof si) == sizeof si && si.ssi_signo == SIGUSR1);
	CHECK("signal_fd", child_status(c) == 0);
	close(ep);
	close(fd);
	sigprocmask(SIG_UNBLOCK, &set, 0);
	printf("ok signal_fd\n");
}

static volatile int alarms;
static void on_alarm(int s) { (void)s; alarms++; }

static void itimer(void) {
	signal(SIGALRM, on_alarm);
	/* A one-shot timer interrupts a sleep, and getitimer counts down. */
	struct itimerval v = {.it_value = {.tv_usec = 200000}}, cur;
	CHECK("itimer", setitimer(ITIMER_REAL, &v, 0) == 0);
	CHECK("itimer", getitimer(ITIMER_REAL, &cur) == 0 && cur.it_value.tv_sec == 0 && cur.it_value.tv_usec > 0 && cur.it_value.tv_usec <= 200000);
	struct timespec t0, t1, ts = {.tv_sec = 5};
	clock_gettime(CLOCK_MONOTONIC, &t0);
	CHECK("itimer", nanosleep(&ts, 0) < 0 && errno == EINTR && alarms == 1);
	clock_gettime(CLOCK_MONOTONIC, &t1);
	long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
	CHECK("itimer", ms >= 150 && ms < 2000);
	/* An interval timer repeats until cleared. */
	struct itimerval r = {.it_interval = {.tv_usec = 50000}, .it_value = {.tv_usec = 50000}};
	CHECK("itimer", setitimer(ITIMER_REAL, &r, 0) == 0);
	while (alarms < 4) pause();
	struct itimerval z = {0};
	CHECK("itimer", setitimer(ITIMER_REAL, &z, &cur) == 0 && cur.it_interval.tv_usec == 50000);
	/* alarm cancels and reports what was left. */
	CHECK("itimer", alarm(100) == 0 && alarm(0) >= 99);
	signal(SIGALRM, SIG_DFL);
	printf("ok itimer\n");
}

static void creds(void) {
	/* As su does: root drops to another user, who can't come back. */
	pid_t c = fork();
	if (c == 0) {
		gid_t g[2] = {70, 71};
		if (getuid() != 0 || geteuid() != 0) _exit(1);
		if (setgroups(2, g) != 0 || setgid(70) != 0 || setuid(70) != 0) _exit(2);
		if (getuid() != 70 || geteuid() != 70 || getgid() != 70 || getegid() != 70) _exit(3);
		gid_t got[4];
		if (getgroups(4, got) != 2 || got[1] != 71) _exit(4);
		if (setuid(0) == 0 || errno != EPERM || setgroups(0, 0) == 0) _exit(5);
		/* A file it makes is its own. */
		int fd = fresh("creds");
		struct stat st;
		if (fd < 0 || fstat(fd, &st) != 0 || st.st_uid != 70) _exit(6);
		_exit(0);
	}
	CHECK("creds", child_status(c) == 0);
	CHECK("creds", getuid() == 0);
	printf("ok creds\n");
}

static void many_fds(void) {
	/* Past 100 fds, as zig does compiling musl: nothing on stderr, which
	 * Plan 9 would warn on, and zig build takes for a failed compile. */
	int p[2], fds[250], n = 0, saved = dup(2);
	CHECK("many_fds", saved >= 0 && pipe(p) == 0 && dup2(p[1], 2) == 2);
	while (n < 250 && (fds[n] = dup(p[1])) >= 0) n++;
	int top = n ? fds[n - 1] : -1;
	for (int i = 0; i < n; i++) close(fds[i]);
	dup2(saved, 2);
	close(saved);
	close(p[1]);
	char b[256];
	ssize_t r = read(p[0], b, sizeof b);
	close(p[0]);
	CHECK("many_fds", n == 250 && top > 200);
	if (r > 0) fprintf(stderr, "%.*s", (int)r, b);
	CHECK("many_fds", r == 0);
	printf("ok many_fds\n");
}

/* WebKit's shared memory: shm_open, unlink, then ftruncate and mmap
 * the open file; and memfd_create, which does the same in one call.
 * The file is gone from the directory but still sized, stat-able, and
 * mappable through its fd, and a fork sees writes through the map. */
static void unlinked(void) {
	int fd = fresh("unl");
	struct stat st;
	CHECK("unlinked", fd >= 0 && unlink(path) == 0 && access(path, F_OK) != 0);
	CHECK("unlinked", ftruncate(fd, 8192) == 0 && fstat(fd, &st) == 0 && st.st_size == 8192);
	char *m = mmap(0, 8192, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	CHECK("unlinked", m != MAP_FAILED);
	strcpy(m + 4096, "gone");
	char b[8] = {0};
	CHECK("unlinked", pread(fd, b, 4, 4096) == 4 && !strcmp(b, "gone"));
	CHECK("unlinked", munmap(m, 8192) == 0 && close(fd) == 0);

	fd = memfd_create("h9test", MFD_CLOEXEC | MFD_ALLOW_SEALING);
	CHECK("unlinked", fd >= 0 && (fcntl(fd, F_GETFD) & FD_CLOEXEC));
	CHECK("unlinked", ftruncate(fd, 4096) == 0 && fstat(fd, &st) == 0 && st.st_size == 4096);
	CHECK("unlinked", fcntl(fd, F_ADD_SEALS, F_SEAL_SHRINK) == 0);
	m = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	CHECK("unlinked", m != MAP_FAILED);
	pid_t c = fork();
	if (c == 0) { strcpy(m, "child"); _exit(0); }
	CHECK("unlinked", child_status(c) == 0 && !strcmp(m, "child"));
	munmap(m, 4096), close(fd);
	printf("ok unlinked\n");
}

/* WebKit's out-of-line IPC messages: the sender fills a memfd (or an
 * unlinked shm_open file), passes it with SCM_RIGHTS, and unmaps and
 * closes its copy before the receiver maps it. The data stays with the
 * file, which only the passed fd still names. */
static int pass_fd(int s, int fd) {
	char d = 'm', cb[CMSG_SPACE(sizeof(int))] = {0};
	struct iovec v = {&d, 1};
	struct msghdr h = {.msg_iov = &v, .msg_iovlen = 1, .msg_control = cb, .msg_controllen = sizeof cb};
	struct cmsghdr *c = CMSG_FIRSTHDR(&h);
	c->cmsg_level = SOL_SOCKET, c->cmsg_type = SCM_RIGHTS, c->cmsg_len = CMSG_LEN(sizeof(int));
	memcpy(CMSG_DATA(c), &fd, sizeof fd);
	return sendmsg(s, &h, 0);
}

static int take_fd(int s) {
	char d, cb[CMSG_SPACE(sizeof(int))];
	struct iovec v = {&d, 1};
	struct msghdr h = {.msg_iov = &v, .msg_iovlen = 1, .msg_control = cb, .msg_controllen = sizeof cb};
	int fd = -1;
	if (recvmsg(s, &h, 0) != 1 || CMSG_FIRSTHDR(&h) == NULL) return -1;
	memcpy(&fd, CMSG_DATA(CMSG_FIRSTHDR(&h)), sizeof fd);
	return fd;
}

static void shm_pass(void) {
	int sv[2];
	CHECK("shm_pass", socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv) == 0);
	pid_t c = fork();
	if (c == 0) {
		close(sv[0]);
		for (int k = 0; k < 2; k++) {
			int fd = take_fd(sv[1]);
			struct stat st;
			if (fd < 0 || fstat(fd, &st) != 0 || st.st_size != 11656) _exit(1);
			char *m = mmap(0, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
			if (m == MAP_FAILED) _exit(2);
			if (strcmp(m + 8000, k ? "via shm_open" : "via memfd") != 0) _exit(3 + k);
			munmap(m, st.st_size), close(fd);
		}
		_exit(0);
	}
	close(sv[1]);
	for (int k = 0; k < 2; k++) {
		int fd;
		if (k == 0) fd = memfd_create("h9test", MFD_CLOEXEC);
		else {
			char name[32];
			snprintf(name, sizeof name, "/h9test.%d", getpid());
			fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
			shm_unlink(name);
		}
		CHECK("shm_pass", fd >= 0 && ftruncate(fd, 11656) == 0);
		char *m = mmap(0, 11656, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		CHECK("shm_pass", m != MAP_FAILED);
		strcpy(m + 8000, k ? "via shm_open" : "via memfd");
		CHECK("shm_pass", pass_fd(sv[0], fd) == 1);
		CHECK("shm_pass", munmap(m, 11656) == 0 && close(fd) == 0);
	}
	CHECK("shm_pass", child_status(c) == 0);
	close(sv[0]);
	printf("ok shm_pass\n");
}

/* Private file mappings are read from the file as pages are first
 * touched, so the file must still be readable after the fd is closed,
 * and each page must come from its own offset after splits, moves,
 * forks, and MADV_DONTNEED. Pages straddle h9's 1 MiB chunks. */
static int stamp_ok(const char *p, int i) {
	char want[16];
	snprintf(want, sizeof want, "page %d", i);
	return strcmp(p, want) == 0;
}

static void lazy_map(void) {
	enum { NP = 3 * 256 + 3 };
	const size_t size = (size_t)NP * 4096 - 4000;
	int fd = fresh("lazy");
	CHECK("lazy_map", fd >= 0);
	char *buf = calloc(1, (size_t)NP * 4096);
	for (int i = 0; i < NP; i++) snprintf(buf + (size_t)i * 4096, 16, "page %d", i);
	CHECK("lazy_map", pwrite(fd, buf, size, 0) == (ssize_t)size);
	free(buf);
	/* From page 1 on, so file offsets and chunk offsets differ. */
	char *m = mmap(0, size - 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 4096);
	CHECK("lazy_map", m != MAP_FAILED && close(fd) == 0);
	CHECK("lazy_map", stamp_ok(m + 300 * 4096, 301) && stamp_ok(m, 1));
	/* The tail of the last page, past the end of the file, reads zero. */
	char *last = m + (size_t)(NP - 2) * 4096;
	CHECK("lazy_map", stamp_ok(last, NP - 1) && last[95] == 0 && last[4095] == 0);
	/* A written page goes back to the file's after MADV_DONTNEED. */
	strcpy(m + 600 * 4096, "mine");
	CHECK("lazy_map", madvise(m + 600 * 4096, 4096, MADV_DONTNEED) == 0 && stamp_ok(m + 600 * 4096, 601));
	strcpy(m + 2 * 4096, "kept");
	pid_t c = fork();
	if (c == 0) {
		if (!stamp_ok(m + 700 * 4096, 701) || strcmp(m + 2 * 4096, "kept") != 0) _exit(1);
		_exit(0);
	}
	CHECK("lazy_map", child_status(c) == 0);
	/* Unmapping the start leaves the rest reading from the file. */
	CHECK("lazy_map", munmap(m, 400 * 4096) == 0 && stamp_ok(m + 500 * 4096, 501));
	CHECK("lazy_map", mprotect(m + 450 * 4096, 4096, PROT_READ) == 0 && stamp_ok(m + 450 * 4096, 451) && stamp_ok(m + 451 * 4096, 452));
	CHECK("lazy_map", munmap(m + 400 * 4096, size - 4096 - 400 * 4096) == 0);

	/* mremap moves a mapping with its file offset: a grown mapping reads
	 * on into the file, and a page zeroed before the move stays zero. */
	fd = open(path, O_RDONLY);
	CHECK("lazy_map", fd >= 0);
	char *r = mmap(0, 3 * 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK("lazy_map", r != MAP_FAILED);
	char *f = mmap(r, 2 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_FIXED, fd, 5 * 4096);
	CHECK("lazy_map", f == r && close(fd) == 0);
	memset(f, 0, 4096);
	char *g = mremap(f, 2 * 4096, 300 * 4096, MREMAP_MAYMOVE);
	CHECK("lazy_map", g != MAP_FAILED && g != f);
	char zero[4096] = {0};
	CHECK("lazy_map", memcmp(g, zero, 4096) == 0 && stamp_ok(g + 4096, 6) && stamp_ok(g + 299 * 4096, 304));
	munmap(g, 300 * 4096), munmap(r + 2 * 4096, 4096);
	unlink(path);
	printf("ok lazy_map\n");
}

/* MADV_DONTNEED on a page of the program's own writable data segment,
 * which the file backs, leaves the file's bytes: Bun's standalone
 * executables (Claude Code) hand back the pages of their embedded
 * sources in such a segment and read them again later. */
static char image_page[2 * 4096] __attribute__((aligned(4096))) = {[0] = 'i', [4095] = 'm', [4096] = 'g'};

static void image_dontneed(void) {
	volatile char *p = image_page;
	CHECK("image_dontneed", madvise(image_page, sizeof image_page, MADV_DONTNEED) == 0);
	CHECK("image_dontneed", p[0] == 'i' && p[4095] == 'm' && p[4096] == 'g');
	printf("ok image_dontneed\n");
}

/* A path through /proc/self/fd/N, for a directory opened O_PATH, walks
 * on from that directory, as Claude Code makes its temp directories. */
static void proc_fd_dir(void) {
	char dir[64], via[96], file[96];
	snprintf(dir, sizeof dir, "/tmp/procfd.%d", (int)getpid());
	CHECK("proc_fd_dir", mkdir(dir, 0700) == 0);
	int d = open(dir, O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	CHECK("proc_fd_dir", d >= 0);
	snprintf(via, sizeof via, "/proc/self/fd/%d/sub", d);
	CHECK("proc_fd_dir", mkdir(via, 0700) == 0);
	snprintf(via, sizeof via, "/proc/self/fd/%d/sub/f", d);
	int f = open(via, O_WRONLY | O_CREAT | O_EXCL, 0600);
	CHECK("proc_fd_dir", f >= 0 && write(f, "hi", 2) == 2 && close(f) == 0);
	snprintf(file, sizeof file, "%s/sub/f", dir);
	struct stat st;
	CHECK("proc_fd_dir", stat(file, &st) == 0 && st.st_size == 2);
	CHECK("proc_fd_dir", unlink(via) == 0 && stat(file, &st) < 0 && errno == ENOENT);
	snprintf(via, sizeof via, "/proc/self/fd/%d/sub", d);
	CHECK("proc_fd_dir", rmdir(via) == 0 && close(d) == 0 && rmdir(dir) == 0);
	printf("ok proc_fd_dir\n");
}

int main(int argc, char **argv) {
	setvbuf(stdout, 0, _IONBF, 0);
	for (int i = 1; i < argc; i++) {
		const char *n = argv[i];
		int all = strcmp(n, "all") == 0;
		if (all || !strcmp(n, "posix_locks")) posix_locks();
		if (all || !strcmp(n, "ofd_flock")) ofd_flock();
		if (all || !strcmp(n, "flock_exec")) flock_exec();
		if (all || !strcmp(n, "shared_map")) shared_map();
		if (all || !strcmp(n, "fixed_shared")) fixed_shared();
		if (all || !strcmp(n, "private_sees")) private_sees();
		if (all || !strcmp(n, "gs_base")) gs_base();
		if (all || !strcmp(n, "fsync_rusage")) fsync_rusage();
		if (all || !strcmp(n, "dir_sync")) dir_sync();
		if (all || !strcmp(n, "read_cache")) read_cache();
		if (all || !strcmp(n, "falloc")) falloc();
		if (all || !strcmp(n, "rename_across")) rename_across();
		if (all || !strcmp(n, "madv_free")) madv_free();
		if (all || !strcmp(n, "id_regs")) id_regs();
		if (all || !strcmp(n, "sysv_shm")) sysv_shm();
		if (all || !strcmp(n, "map_exit")) map_exit();
		if (all || !strcmp(n, "shared_sem")) shared_sem();
		if (all || !strcmp(n, "signal_fd")) signal_fd();
		if (all || !strcmp(n, "itimer")) itimer();
		if (all || !strcmp(n, "creds")) creds();
		if (all || !strcmp(n, "many_fds")) many_fds();
		if (all || !strcmp(n, "unlinked")) unlinked();
		if (all || !strcmp(n, "shm_pass")) shm_pass();
		if (all || !strcmp(n, "lazy_map")) lazy_map();
		if (all || !strcmp(n, "image_dontneed")) image_dontneed();
		if (all || !strcmp(n, "proc_fd_dir")) proc_fd_dir();
	}
	return failed;
}
