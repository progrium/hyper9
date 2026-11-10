/* Threads (design/0049-linux-threads.md): each case named on the command
 * line prints "ok NAME" or "FAIL NAME: why". "all" runs the ones that
 * return; exit_main, exit_thread and exec_thread end the process. */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int failed;

#define CHECK(name, cond) do { if (!(cond)) { printf("FAIL %s: %s (errno %d %s)\n", name, #cond, errno, strerror(errno)); failed = 1; return; } } while (0)

static long ms_since(struct timespec *t0) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (t.tv_sec - t0->tv_sec) * 1000 + (t.tv_nsec - t0->tv_nsec) / 1000000;
}

/* 8 threads add to a counter under a mutex; join waits on each one's
 * CLONE_CHILD_CLEARTID word. */
enum { NT = 8, NADD = 20000 };
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static long counter;
static pid_t tids[NT];

static void *adder(void *a) {
	tids[(intptr_t)a] = gettid();
	for (int i = 0; i < NADD; i++) {
		pthread_mutex_lock(&mu);
		counter++;
		pthread_mutex_unlock(&mu);
		if (i % 1000 == 0) sched_yield();
	}
	return (void *)((intptr_t)a + 100);
}

static void mutex8(void) {
	pthread_t t[NT];
	counter = 0;
	for (intptr_t i = 0; i < NT; i++) CHECK("mutex", pthread_create(&t[i], 0, adder, (void *)i) == 0);
	for (intptr_t i = 0; i < NT; i++) {
		void *r;
		CHECK("mutex", pthread_join(t[i], &r) == 0);
		CHECK("mutex", r == (void *)(i + 100));
	}
	CHECK("mutex", counter == (long)NT * NADD);
	pid_t pid = getpid();
	for (int i = 0; i < NT; i++) {
		CHECK("mutex", tids[i] != pid && tids[i] > 0);
		for (int k = 0; k < i; k++) CHECK("mutex", tids[i] != tids[k]);
	}
	CHECK("mutex", gettid() == pid);
	printf("ok mutex\n");
}

/* A condition variable passes 1000 items through a one-slot queue. */
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int slot, full, done_items;

static void *producer(void *a) {
	(void)a;
	for (int i = 1; i <= 1000; i++) {
		pthread_mutex_lock(&mu);
		while (full) pthread_cond_wait(&cv, &mu);
		slot = i;
		full = 1;
		pthread_cond_broadcast(&cv);
		pthread_mutex_unlock(&mu);
	}
	return 0;
}

static void condvar(void) {
	pthread_t t;
	long sum = 0;
	full = 0;
	CHECK("condvar", pthread_create(&t, 0, producer, 0) == 0);
	for (int i = 0; i < 1000; i++) {
		pthread_mutex_lock(&mu);
		while (!full) pthread_cond_wait(&cv, &mu);
		sum += slot;
		full = 0;
		pthread_cond_broadcast(&cv);
		pthread_mutex_unlock(&mu);
	}
	CHECK("condvar", pthread_join(t, 0) == 0);
	CHECK("condvar", sum == 1000 * 1001 / 2);
	printf("ok condvar\n");
}

/* A timed wait times out; a thread's TLS is its own. */
static __thread int tlsv = 7;

static void *tlsfn(void *a) {
	tlsv = (int)(intptr_t)a;
	usleep(20000);
	return (void *)(intptr_t)tlsv;
}

static void timed_tls(void) {
	struct timespec ts, t0;
	clock_gettime(CLOCK_REALTIME, &ts);
	ts.tv_nsec += 100 * 1000000;
	if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
	clock_gettime(CLOCK_MONOTONIC, &t0);
	pthread_mutex_lock(&mu);
	int r = pthread_cond_timedwait(&cv, &mu, &ts);
	pthread_mutex_unlock(&mu);
	CHECK("timed_tls", r == ETIMEDOUT);
	CHECK("timed_tls", ms_since(&t0) >= 90);
	pthread_t a, b;
	CHECK("timed_tls", pthread_create(&a, 0, tlsfn, (void *)11) == 0);
	CHECK("timed_tls", pthread_create(&b, 0, tlsfn, (void *)22) == 0);
	void *ra, *rb;
	pthread_join(a, &ra);
	pthread_join(b, &rb);
	CHECK("timed_tls", ra == (void *)11 && rb == (void *)22 && tlsv == 7);
	printf("ok timed_tls\n");
}

/* A thread blocked in a futex wait takes a signal sent to it, and a busy
 * one (no syscalls) is interrupted too. */
static volatile sig_atomic_t got;
static void on_usr1(int s) { (void)s; got = 1; }

static void *waiter(void *a) {
	(void)a;
	while (!got) pause();
	return 0;
}

static void *spinner(void *a) {
	(void)a;
	while (!got) ;
	return 0;
}

static void tgkill_case(const char *name, void *(*fn)(void *)) {
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_usr1;
	sigaction(SIGUSR1, &sa, 0);
	got = 0;
	pthread_t t;
	CHECK(name, pthread_create(&t, 0, fn, 0) == 0);
	usleep(50000);
	CHECK(name, pthread_kill(t, SIGUSR1) == 0);
	CHECK(name, pthread_join(t, 0) == 0);
	CHECK(name, got == 1);
	printf("ok %s\n", name);
}

/* A thread spins on a flag that another sets after a syscall: on the
 * emulator, only time-slicing lets the second run. */
static atomic_int flag;

static void *setter(void *a) {
	(void)a;
	usleep(10000);
	atomic_store(&flag, 1);
	return 0;
}

static void *flagspin(void *a) {
	(void)a;
	while (!atomic_load(&flag)) ;
	return 0;
}

static void spin(void) {
	pthread_t a, b;
	atomic_store(&flag, 0);
	CHECK("spin", pthread_create(&a, 0, flagspin, 0) == 0);
	CHECK("spin", pthread_create(&b, 0, setter, 0) == 0);
	pthread_join(b, 0);
	pthread_join(a, 0);
	printf("ok spin\n");
}

/* Readers read a page in a loop while the main thread unmaps it, and
 * another process fills memory it allocates with 'B': after munmap
 * returns, a read faults (SIGSEGV, caught) and never sees the other
 * process's data in pages the host reused. */
static volatile char *volatile page_p;
static atomic_int stop_readers, bad_reads, readers_up;
static __thread sigjmp_buf jb;
static __thread volatile int in_read;

static void on_segv(int s) {
	(void)s;
	if (in_read) siglongjmp(jb, 1);
	_exit(99);
}

static void *reader(void *a) {
	(void)a;
	atomic_fetch_add(&readers_up, 1);
	while (!atomic_load(&stop_readers)) {
		volatile char *p = page_p;
		if (p == 0) continue;
		if (sigsetjmp(jb, 1) == 0) {
			in_read = 1;
			char c = p[100];
			in_read = 0;
			if (c != 'A' && c != 0) atomic_fetch_add(&bad_reads, 1);
		} else in_read = 0;
	}
	return 0;
}

static void munmap_case(void) {
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_segv;
	sa.sa_flags = SA_NODEFER;
	sigaction(SIGSEGV, &sa, 0);
	atomic_store(&stop_readers, 0);
	atomic_store(&readers_up, 0);
	pthread_t t[3];
	for (int i = 0; i < 3; i++) CHECK("munmap", pthread_create(&t[i], 0, reader, 0) == 0);
	while (atomic_load(&readers_up) < 3) sched_yield();
	pid_t other = fork();
	if (other == 0) {
		for (;;) {
			char *q = mmap(0, 65536, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
			if (q == MAP_FAILED) _exit(1);
			memset(q, 'B', 65536);
			munmap(q, 65536);
		}
	}
	for (int round = 0; round < 200; round++) {
		char *p = mmap(0, 65536, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		CHECK("munmap", p != MAP_FAILED);
		memset(p, 'A', 65536);
		page_p = p;
		sched_yield();
		CHECK("munmap", munmap(p, 65536) == 0);
		page_p = 0;
		sched_yield();
	}
	kill(other, SIGKILL);
	waitpid(other, 0, 0);
	atomic_store(&stop_readers, 1);
	for (int i = 0; i < 3; i++) pthread_join(t[i], 0);
	CHECK("munmap", atomic_load(&bad_reads) == 0);
	signal(SIGSEGV, SIG_DFL);
	printf("ok munmap\n");
}

/* Another thread's mprotect in the same 1 MiB chunk remaps the chunk's
 * pages, unmapping them for a moment: a store from this thread that
 * faults in that window must be retried, not a SIGSEGV, and a read(2)
 * into the chunk must not fail with EFAULT. */
static char *race_buf;
static atomic_int race_stop, race_efault;

static void *race_storer(void *a) {
	(void)a;
	unsigned n = 0;
	while (!atomic_load(&race_stop)) race_buf[8192 + (n++ % 4096)] = (char)n;
	return 0;
}

static void *race_reader(void *a) {
	int fd = *(int *)a;
	while (!atomic_load(&race_stop))
		if (read(fd, race_buf, 4096) != 4096) atomic_fetch_add(&race_efault, 1);
	return 0;
}

static void remap_race(void) {
	enum { MB = 1 << 20 };
	char *r = mmap(0, 3 * MB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK("remap_race", r != MAP_FAILED);
	char *chunk = (char *)(((uintptr_t)r + MB - 1) & ~(uintptr_t)(MB - 1));
	race_buf = chunk;
	memset(chunk, 1, MB);
	int fd = open("/dev/zero", O_RDONLY);
	CHECK("remap_race", fd >= 0);
	atomic_store(&race_stop, 0);
	pthread_t s, rd;
	CHECK("remap_race", pthread_create(&s, 0, race_storer, 0) == 0);
	CHECK("remap_race", pthread_create(&rd, 0, race_reader, &fd) == 0);
	for (int i = 0; i < 20000; i++) {
		CHECK("remap_race", mprotect(chunk + MB / 2, 65536, i & 1 ? PROT_READ | PROT_WRITE : PROT_READ) == 0);
	}
	atomic_store(&race_stop, 1);
	pthread_join(s, 0);
	pthread_join(rd, 0);
	close(fd);
	CHECK("remap_race", atomic_load(&race_efault) == 0);
	munmap(r, 3 * MB);
	printf("ok remap_race\n");
}

/* Threads that fault pages in while others unmap: one thread's munmap
 * flushes the stub's queued mappings, other threads' faults included,
 * and a thread whose mapping was in that flush mustn't run before it's
 * done, or it faults again on a page h9 has mapped, which is SIGSEGV. */
static void *faulter(void *a) {
	(void)a;
	for (int i = 0; i < 1000; i++) {
		char *p = mmap(0, 1 << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED) return (void *)1;
		for (int j = 0; j < 16; j++) p[j * 65536 + (i % 16) * 4096] = 1;
		munmap(p, 1 << 20);
	}
	return 0;
}

static void fault_race(void) {
	for (int round = 0; round < 5; round++) {
		pthread_t t[4];
		void *r;
		int bad = 0;
		for (int i = 0; i < 4; i++) CHECK("fault_race", pthread_create(&t[i], 0, faulter, 0) == 0);
		for (int i = 0; i < 4; i++) bad |= pthread_join(t[i], &r) != 0 || r != 0;
		CHECK("fault_race", !bad);
	}
	printf("ok fault_race\n");
}

/* fork from a thread: the child has one thread, and the parent waits. */
static void *forker(void *a) {
	(void)a;
	pid_t c = fork();
	if (c == 0) _exit(gettid() == getpid() ? 4 : 5);
	int st;
	if (waitpid(c, &st, 0) != c) return (void *)1;
	return (void *)(intptr_t)(WIFEXITED(st) ? WEXITSTATUS(st) : 6);
}

static void fork_thread(void) {
	pthread_t t;
	void *r;
	CHECK("fork_thread", pthread_create(&t, 0, forker, 0) == 0);
	CHECK("fork_thread", pthread_join(t, &r) == 0);
	CHECK("fork_thread", r == (void *)4);
	printf("ok fork_thread\n");
}

/* Ends the process from main while threads block and spin: exit(5). */
static void *sleeper(void *a) {
	(void)a;
	for (;;) pause();
}

static void exit_main(void) {
	pthread_t t;
	pthread_create(&t, 0, sleeper, 0);
	pthread_create(&t, 0, spinner, 0);
	usleep(20000);
	printf("exiting\n");
	exit(5);
}

/* Ends the process from a thread: exit(7) while main waits in join. */
static void *exiter(void *a) {
	(void)a;
	usleep(20000);
	exit(7);
}

static void exit_thread(void) {
	pthread_t t, u;
	pthread_create(&u, 0, sleeper, 0);
	pthread_create(&t, 0, exiter, 0);
	pthread_join(t, 0);
	printf("FAIL exit_thread: join returned\n");
}

/* execve from a thread other than the leader: the new image runs, with
 * the leader's pid. */
static pid_t leader;

static void *execer(void *a) {
	char **argv = a;
	char pid[32];
	snprintf(pid, sizeof pid, "%d", (int)leader);
	char *args[] = {argv[0], "exec_check", pid, 0};
	execv(argv[0], args);
	printf("FAIL exec_thread: execv: %s\n", strerror(errno));
	exit(1);
}

static void exec_thread(char **argv) {
	pthread_t t, u;
	leader = getpid();
	pthread_create(&u, 0, sleeper, 0);
	pthread_create(&t, 0, execer, argv);
	for (;;) pause();
}

/* The main thread returns with pthread_exit while another runs on: the
 * process lives until the last thread exits, with its status. */
static void *late(void *a) {
	(void)a;
	usleep(50000);
	printf("ok leader_exit\n");
	exit(0);
}

static void leader_exit(void) {
	pthread_t t;
	pthread_create(&t, 0, late, 0);
	pthread_exit(0);
}

/* /proc as htop and btop read it: a thread group shows once in /proc,
 * its threads are under /proc/PID/task, and /proc/PID/statm reads. */
static pthread_mutex_t pt_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pt_cv = PTHREAD_COND_INITIALIZER;
static int pt_up, pt_done;
static pid_t pt_tids[2];

static void *pt_thread(void *a) {
	pthread_mutex_lock(&pt_mu);
	pt_tids[pt_up++] = gettid();
	pthread_cond_broadcast(&pt_cv);
	while (!pt_done) pthread_cond_wait(&pt_cv, &pt_mu);
	pthread_mutex_unlock(&pt_mu);
	return a;
}

static int listed(const char *dir, pid_t pid) {
	DIR *d = opendir(dir);
	struct dirent *e;
	int n = 0;
	if (d == NULL) return -1;
	while ((e = readdir(d)) != NULL)
		if (atoi(e->d_name) == pid) n++;
	closedir(d);
	return n;
}

static void proc_threads(void) {
	pthread_t t[2];
	char path[64];
	long size, rss;
	FILE *f;
	for (int i = 0; i < 2; i++) pthread_create(&t[i], 0, pt_thread, 0);
	pthread_mutex_lock(&pt_mu);
	while (pt_up < 2) pthread_cond_wait(&pt_cv, &pt_mu);
	pthread_mutex_unlock(&pt_mu);
	int me = listed("/proc", getpid()), t0 = listed("/proc", pt_tids[0]), t1 = listed("/proc", pt_tids[1]);
	snprintf(path, sizeof path, "/proc/%d/task", getpid());
	int tm = listed(path, getpid()), tt0 = listed(path, pt_tids[0]), tt1 = listed(path, pt_tids[1]);
	snprintf(path, sizeof path, "/proc/%d/task/%d/stat", getpid(), pt_tids[1]);
	int tstat = access(path, R_OK) == 0;
	f = fopen("/proc/self/statm", "r");
	int statm = f != NULL && fscanf(f, "%ld %ld", &size, &rss) == 2 && size > 0;
	if (f != NULL) fclose(f);
	pthread_mutex_lock(&pt_mu);
	pt_done = 1;
	pthread_cond_broadcast(&pt_cv);
	pthread_mutex_unlock(&pt_mu);
	for (int i = 0; i < 2; i++) pthread_join(t[i], 0);
	CHECK("proc_threads", me == 1 && t0 == 0 && t1 == 0);
	CHECK("proc_threads", tm == 1 && tt0 == 1 && tt1 == 1);
	CHECK("proc_threads", tstat);
	CHECK("proc_threads", statm);
	printf("ok proc_threads\n");
}

/* /proc/meminfo counts a process's memory once, not once per thread:
 * WebKit's memory monitor reads MemAvailable, and a count per thread
 * makes a few threads look like memory pressure. */
static long mem_free_kb(void) {
	FILE *f = fopen("/proc/meminfo", "r");
	char k[64];
	long v, r = -1;
	if (f == NULL) return -1;
	while (fscanf(f, "%63s %ld kB", k, &v) == 2)
		if (!strcmp(k, "MemFree:")) r = v;
	fclose(f);
	return r;
}

static int mi_up, mi_done;

static void *mi_thread(void *a) {
	pthread_mutex_lock(&pt_mu);
	mi_up++;
	pthread_cond_broadcast(&pt_cv);
	while (!mi_done) pthread_cond_wait(&pt_cv, &pt_mu);
	pthread_mutex_unlock(&pt_mu);
	return a;
}

static void meminfo_threads(void) {
	enum { MB = 1 << 20, TOUCH = 64 * MB, N = 6 };
	char *m = mmap(0, TOUCH, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK("meminfo_threads", m != MAP_FAILED);
	for (long i = 0; i < TOUCH; i += 4096) m[i] = 1;
	long before = mem_free_kb();
	pthread_t t[N];
	for (int i = 0; i < N; i++) pthread_create(&t[i], 0, mi_thread, 0);
	pthread_mutex_lock(&pt_mu);
	while (mi_up < N) pthread_cond_wait(&pt_cv, &pt_mu);
	long during = mem_free_kb();
	mi_done = 1;
	pthread_cond_broadcast(&pt_cv);
	pthread_mutex_unlock(&pt_mu);
	for (int i = 0; i < N; i++) pthread_join(t[i], 0);
	munmap(m, TOUCH);
	CHECK("meminfo_threads", before > 0 && during > 0);
	/* Thread stacks cost a little; another copy of the 64 MiB per thread
	 * would cost 384 MiB. */
	CHECK("meminfo_threads", before - during < 32 * 1024);
	printf("ok meminfo_threads\n");
}

int main(int argc, char **argv) {
	setvbuf(stdout, 0, _IONBF, 0);
	for (int i = 1; i < argc; i++) {
		const char *n = argv[i];
		int all = strcmp(n, "all") == 0;
		if (all || !strcmp(n, "mutex")) mutex8();
		if (all || !strcmp(n, "condvar")) condvar();
		if (all || !strcmp(n, "timed_tls")) timed_tls();
		if (all || !strcmp(n, "fork_thread")) fork_thread();
		if (all || !strcmp(n, "tgkill_wait")) tgkill_case("tgkill_wait", waiter);
		if (all || !strcmp(n, "tgkill_busy")) tgkill_case("tgkill_busy", spinner);
		if (all || !strcmp(n, "spin")) spin();
		if (all || !strcmp(n, "munmap")) munmap_case();
		if (all || !strcmp(n, "remap_race")) remap_race();
		if (all || !strcmp(n, "fault_race")) fault_race();
		if (all || !strcmp(n, "proc_threads")) proc_threads();
		if (all || !strcmp(n, "meminfo_threads")) meminfo_threads();
		if (!strcmp(n, "exit_main")) exit_main();
		if (!strcmp(n, "exit_thread")) exit_thread();
		if (!strcmp(n, "exec_thread")) exec_thread(argv);
		if (!strcmp(n, "leader_exit")) leader_exit();
		if (!strcmp(n, "exec_check")) {
			int ok = i + 1 < argc && atoi(argv[i + 1]) == getpid();
			printf(ok ? "ok exec_thread\n" : "FAIL exec_thread: pid %d, not %s\n", getpid(), i + 1 < argc ? argv[i + 1] : "?");
			return ok ? 0 : 1;
		}
	}
	return failed;
}
