/* Readiness and sockets (design/epoch-0/linux-net.md): each case named on
 * the command line prints "ok NAME" or "FAIL NAME: why". "all" runs the
 * ones that need no network; the socket cases need --net=enable. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/un.h>
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

static void poll_pipe(void) {
	int p[2];
	CHECK("poll_pipe", pipe(p) == 0);
	struct pollfd f = {p[0], POLLIN, 0};
	CHECK("poll_pipe", poll(&f, 1, 0) == 0);
	pid_t c = fork();
	if (c == 0) { usleep(100000); write(p[1], "x", 1); _exit(0); }
	struct timespec t0;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	CHECK("poll_pipe", poll(&f, 1, 5000) == 1 && (f.revents & POLLIN));
	CHECK("poll_pipe", ms_since(&t0) < 4000);
	waitpid(c, 0, 0);
	close(p[1]);
	char b;
	read(p[0], &b, 1);
	CHECK("poll_pipe", poll(&f, 1, 1000) == 1 && (f.revents & POLLHUP));
	/* select sees it the same way */
	close(p[0]);
	printf("ok poll_pipe\n");
}

/* poll on a pipe, a pty, and an eventfd at once (design/file-interface.md):
 * none is ready, and a write to each from a child, in turn, ends a poll
 * that waits on all three, with that one ready alone. */
static void poll_ready(void) {
	int p[2];
	CHECK("poll_ready", pipe(p) == 0);
	int m = posix_openpt(O_RDWR | O_NOCTTY);
	CHECK("poll_ready", m >= 0 && grantpt(m) == 0 && unlockpt(m) == 0);
	int s = open(ptsname(m), O_RDWR | O_NOCTTY);
	CHECK("poll_ready", s >= 0);
	int e = eventfd(0, 0);
	CHECK("poll_ready", e >= 0);
	struct pollfd f[3] = {{p[0], POLLIN, 0}, {m, POLLIN, 0}, {e, POLLIN, 0}};
	CHECK("poll_ready", poll(f, 3, 0) == 0);
	pid_t c = fork();
	if (c == 0) {
		uint64_t one = 1;
		usleep(100000);
		write(p[1], "x", 1);
		usleep(100000);
		write(s, "y", 1);
		usleep(100000);
		write(e, &one, sizeof one);
		_exit(0);
	}
	for (int i = 0; i < 3; i++) {
		struct timespec t0;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		CHECK("poll_ready", poll(f, 3, 5000) == 1 && (f[i].revents & POLLIN));
		CHECK("poll_ready", ms_since(&t0) < 4000);
		char b[8];
		CHECK("poll_ready", read(f[i].fd, b, i == 2 ? 8 : 1) > 0);
		CHECK("poll_ready", poll(f, 3, 0) == 0);
	}
	waitpid(c, 0, 0);
	close(p[0]);
	close(p[1]);
	close(s);
	close(m);
	close(e);
	printf("ok poll_ready\n");
}

/* An O_NONBLOCK write to a pipe nobody reads takes what fits and comes
 * back, then is EAGAIN, and EPIPE once the read end is closed: it never
 * waits for the reader (Go's TestClosedPipeRaceWrite). */
static void pipe_full(void) {
	static char big[4 << 20];
	int p[2];
	CHECK("pipe_full", pipe2(p, O_NONBLOCK | O_CLOEXEC) == 0);
	ssize_t n = write(p[1], big, sizeof big);
	CHECK("pipe_full", n > 0 && n < (ssize_t)sizeof big);
	CHECK("pipe_full", write(p[1], big, 1) == -1 && errno == EAGAIN);
	struct pollfd pf = {.fd = p[1], .events = POLLOUT};
	CHECK("pipe_full", poll(&pf, 1, 0) == 0);
	char b[4096];
	ssize_t got = 0, r;
	while ((r = read(p[0], b, sizeof b)) > 0) got += r;
	CHECK("pipe_full", r == -1 && errno == EAGAIN && got == n);
	CHECK("pipe_full", write(p[1], big, 100) == 100);
	close(p[0]);
	CHECK("pipe_full", write(p[1], big, 1) == -1 && errno == EPIPE);
	close(p[1]);
	printf("ok pipe_full\n");
}

/* splice: a file at an offset into a pipe, a socket into a pipe without
 * waiting, and the pipe on into a file; and the errors Linux gives. */
static void splice_pipe(void) {
	char fpath[] = "/tmp/splice.XXXXXX", gpath[] = "/tmp/splice.XXXXXX";
	int f = mkstemp(fpath), g = mkstemp(gpath);
	CHECK("splice_pipe", f >= 0 && g >= 0);
	unlink(fpath);
	unlink(gpath);
	CHECK("splice_pipe", write(f, "hello splice", 12) == 12);
	int p[2], s[2];
	CHECK("splice_pipe", pipe(p) == 0 && socketpair(AF_UNIX, SOCK_STREAM, 0, s) == 0);
	loff_t off = 6;
	CHECK("splice_pipe", splice(f, &off, p[1], 0, 100, 0) == 6 && off == 12);
	char b[64] = {0};
	CHECK("splice_pipe", read(p[0], b, sizeof b) == 6 && memcmp(b, "splice", 6) == 0);
	/* The file's own offset didn't move: it's still past the write. */
	CHECK("splice_pipe", lseek(f, 0, SEEK_CUR) == 12);
	loff_t o2 = 0;
	CHECK("splice_pipe", splice(p[0], 0, g, &o2, 10, SPLICE_F_NONBLOCK) == -1 && errno == EAGAIN);
	CHECK("splice_pipe", splice(s[0], 0, p[1], 0, 64, SPLICE_F_NONBLOCK) == -1 && errno == EAGAIN);
	CHECK("splice_pipe", write(s[1], "abc", 3) == 3);
	CHECK("splice_pipe", splice(s[0], 0, p[1], 0, 64, SPLICE_F_NONBLOCK) == 3);
	CHECK("splice_pipe", splice(p[0], 0, g, &o2, 64, 0) == 3 && o2 == 3);
	memset(b, 0, sizeof b);
	CHECK("splice_pipe", pread(g, b, sizeof b, 0) == 3 && memcmp(b, "abc", 3) == 0);
	/* Into the file at its own offset. */
	CHECK("splice_pipe", write(p[1], "de", 2) == 2);
	CHECK("splice_pipe", lseek(g, 3, SEEK_SET) == 3 && splice(p[0], 0, g, 0, 64, 0) == 2 && lseek(g, 0, SEEK_CUR) == 5);
	CHECK("splice_pipe", splice(f, 0, g, 0, 1, 0) == -1 && errno == EINVAL);
	CHECK("splice_pipe", splice(f, &off, p[1], 0, 1, 0) == 0 /* at the end of f */);
	off = 0;
	CHECK("splice_pipe", splice(p[0], &off, g, 0, 1, 0) == -1 && errno == ESPIPE);
	close(s[1]);
	CHECK("splice_pipe", splice(s[0], 0, p[1], 0, 64, SPLICE_F_NONBLOCK) == 0);
	close(s[0]);
	close(p[0]);
	close(p[1]);
	close(f);
	close(g);
	printf("ok splice_pipe\n");
}

/* readv from a pipe returns what's there, not waiting to fill the
 * second buffer once the first is full (Zig's test runner). */
static void readv_pipe(void) {
	int p[2];
	CHECK("readv_pipe", pipe(p) == 0);
	CHECK("readv_pipe", write(p[1], "12345678", 8) == 8);
	char a[8], b[64];
	struct iovec v[2] = {{a, sizeof a}, {b, sizeof b}};
	alarm(10);
	CHECK("readv_pipe", readv(p[0], v, 2) == 8 && memcmp(a, "12345678", 8) == 0);
	alarm(0);
	close(p[0]);
	close(p[1]);
	printf("ok readv_pipe\n");
}

static void nonblock_pipe(void) {
	int p[2];
	CHECK("nonblock_pipe", pipe2(p, O_NONBLOCK) == 0);
	char b[4];
	CHECK("nonblock_pipe", read(p[0], b, 4) < 0 && errno == EAGAIN);
	write(p[1], "ab", 2);
	CHECK("nonblock_pipe", read(p[0], b, 4) == 2);
	fd_set r;
	FD_ZERO(&r);
	FD_SET(p[0], &r);
	struct timeval tv = {0, 0};
	CHECK("nonblock_pipe", select(p[0] + 1, &r, 0, 0, &tv) == 0);
	write(p[1], "c", 1);
	FD_SET(p[0], &r);
	CHECK("nonblock_pipe", select(p[0] + 1, &r, 0, 0, &tv) == 1 && FD_ISSET(p[0], &r));
	close(p[0]);
	close(p[1]);
	printf("ok nonblock_pipe\n");
}

static void epoll_et(void) {
	int p[2];
	CHECK("epoll_et", pipe2(p, O_NONBLOCK) == 0);
	int ep = epoll_create1(EPOLL_CLOEXEC);
	CHECK("epoll_et", ep >= 0);
	struct epoll_event ev = {.events = EPOLLIN | EPOLLET, .data.u64 = 42};
	CHECK("epoll_et", epoll_ctl(ep, EPOLL_CTL_ADD, p[0], &ev) == 0);
	struct epoll_event out[4];
	CHECK("epoll_et", epoll_wait(ep, out, 4, 0) == 0);
	write(p[1], "a", 1);
	CHECK("epoll_et", epoll_wait(ep, out, 4, 1000) == 1 && out[0].data.u64 == 42 && (out[0].events & EPOLLIN));
	/* Edge-triggered: still readable, but no new edge. */
	CHECK("epoll_et", epoll_wait(ep, out, 4, 100) == 0);
	write(p[1], "b", 1);
	CHECK("epoll_et", epoll_wait(ep, out, 4, 1000) == 1);
	/* Level-triggered reports until drained. */
	ev.events = EPOLLIN;
	CHECK("epoll_et", epoll_ctl(ep, EPOLL_CTL_MOD, p[0], &ev) == 0);
	CHECK("epoll_et", epoll_wait(ep, out, 4, 0) == 1);
	CHECK("epoll_et", epoll_wait(ep, out, 4, 0) == 1);
	char b[4];
	read(p[0], b, 4);
	CHECK("epoll_et", epoll_wait(ep, out, 4, 0) == 0);
	/* A wait that a writer ends. */
	pid_t c = fork();
	if (c == 0) { usleep(100000); write(p[1], "z", 1); _exit(0); }
	CHECK("epoll_et", epoll_wait(ep, out, 4, 5000) == 1);
	waitpid(c, 0, 0);
	close(ep);
	close(p[0]);
	close(p[1]);
	printf("ok epoll_et\n");
}

static void eventfd_epoll(void) {
	int e = eventfd(0, EFD_NONBLOCK);
	CHECK("eventfd", e >= 0);
	uint64_t v;
	CHECK("eventfd", read(e, &v, 8) < 0 && errno == EAGAIN);
	int ep = epoll_create1(0);
	struct epoll_event ev = {.events = EPOLLIN, .data.fd = e};
	CHECK("eventfd", epoll_ctl(ep, EPOLL_CTL_ADD, e, &ev) == 0);
	pid_t c = fork();
	if (c == 0) { usleep(100000); uint64_t one = 3; write(e, &one, 8); _exit(0); }
	struct epoll_event out;
	CHECK("eventfd", epoll_wait(ep, &out, 1, 5000) == 1 && out.data.fd == e);
	waitpid(c, 0, 0);
	v = 1;
	write(e, &v, 8);
	CHECK("eventfd", read(e, &v, 8) == 8 && v == 4);
	int s = eventfd(2, EFD_SEMAPHORE);
	CHECK("eventfd", read(s, &v, 8) == 8 && v == 1);
	CHECK("eventfd", read(s, &v, 8) == 8 && v == 1);
	printf("ok eventfd\n");
}

/* tokio's I/O driver (mio's waker): an eventfd under EPOLLET that's never
 * drained, so after its first report it stays readable and only a new
 * write is a new event. Another thread writes it each time the waiter
 * has seen the last write; a write that lands while the waiter is
 * between asking and sleeping must still end the wait (#276). A lost one
 * shows as a timeout, or, when an unrelated wake rescues it, as a run
 * that takes far longer than the fraction of a second it needs. */
static int ew_ep;
static atomic_int ew_seen, ew_sent, ew_lost;
enum { ew_n = 5000 };

static void *ew_waiter(void *a) {
	(void)a;
	struct epoll_event out;
	while (atomic_load(&ew_seen) < ew_n) {
		int r = epoll_wait(ew_ep, &out, 1, 2000);
		if (r == 0) { atomic_store(&ew_lost, 1); atomic_store(&ew_seen, ew_n); break; }
		if (r < 0 && errno != EINTR) { atomic_store(&ew_lost, 2); atomic_store(&ew_seen, ew_n); break; }
		if (r > 0) atomic_store(&ew_seen, atomic_load(&ew_sent));
	}
	return 0;
}

static void eventfd_waker(void) {
	int e = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
	CHECK("eventfd_waker", e >= 0);
	ew_ep = epoll_create1(EPOLL_CLOEXEC);
	struct epoll_event ev = {.events = EPOLLIN | EPOLLET, .data.fd = e};
	CHECK("eventfd_waker", epoll_ctl(ew_ep, EPOLL_CTL_ADD, e, &ev) == 0);
	pthread_t t;
	CHECK("eventfd_waker", pthread_create(&t, 0, ew_waiter, 0) == 0);
	uint64_t one = 1;
	unsigned seed = 1;
	struct timespec t0;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (int i = 1; i <= ew_n && atomic_load(&ew_lost) == 0; i++) {
		if (ms_since(&t0) > 20000) { atomic_store(&ew_lost, 3); atomic_store(&ew_seen, ew_n); break; }
		atomic_store(&ew_sent, i);
		/* Vary when the write lands in the waiter's next epoll_wait. */
		for (volatile int k = rand_r(&seed) % 4000; k > 0; k--)
			;
		if (write(e, &one, 8) != 8) break;
		while (atomic_load(&ew_seen) < i) sched_yield();
	}
	/* A waiter still in epoll_wait after a give-up takes the next write. */
	write(e, &one, 8);
	pthread_join(t, 0);
	close(ew_ep);
	close(e);
	CHECK("eventfd_waker", atomic_load(&ew_lost) == 0 /* 1: timed out, 3: too slow */);
	printf("ok eventfd_waker\n");
}

/* fcntl(F_DUPFD_CLOEXEC) in several threads at once, as tokio does for
 * its signal pipe while building a runtime in each, beside epoll and
 * eventfd fds the other threads open: each dup takes a free fd without
 * replacing one another thread just got, and keeps the original's
 * O_NONBLOCK (#276). */
static int df_sock;
static atomic_int df_bad;

static void *df_thread(void *a) {
	(void)a;
	for (int i = 0; i < 2000 && atomic_load(&df_bad) == 0; i++) {
		int ep = epoll_create1(EPOLL_CLOEXEC);
		int e = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
		int d = fcntl(df_sock, F_DUPFD_CLOEXEC, 3);
		struct epoll_event ev = {.events = EPOLLIN | EPOLLET};
		if (ep < 0 || e < 0 || d < 3 || epoll_ctl(ep, EPOLL_CTL_ADD, e, &ev) != 0)
			atomic_store(&df_bad, 1);
		else if (!(fcntl(d, F_GETFL) & O_NONBLOCK) || !(fcntl(d, F_GETFD) & FD_CLOEXEC))
			atomic_store(&df_bad, 2);
		close(d);
		close(e);
		close(ep);
	}
	return 0;
}

static void dupfd_threads(void) {
	int sv[2];
	CHECK("dupfd_threads", socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, sv) == 0);
	df_sock = sv[0];
	pthread_t t[4];
	for (int i = 0; i < 4; i++) CHECK("dupfd_threads", pthread_create(&t[i], 0, df_thread, 0) == 0);
	for (int i = 0; i < 4; i++) pthread_join(t[i], 0);
	close(sv[0]);
	close(sv[1]);
	CHECK("dupfd_threads", atomic_load(&df_bad) == 0 /* 1: an fd was replaced, 2: a dup lost its flags */);
	printf("ok dupfd_threads\n");
}

/* tokio's runtimes each read their own dup of one nonblocking signal
 * pipe until EAGAIN. Each byte goes to one of them; the rest must get
 * EAGAIN, not wait in a read for a byte another thread took (#276). */
static int pd_sock;
static atomic_int pd_done, pd_taken;
enum { pd_n = 5000 };

static void *pd_thread(void *a) {
	(void)a;
	int d = fcntl(pd_sock, F_DUPFD_CLOEXEC, 3);
	char buf[128];
	while (!atomic_load(&pd_done)) {
		struct pollfd pf = {.fd = d, .events = POLLIN};
		poll(&pf, 1, 50);
		ssize_t r;
		while ((r = read(d, buf, sizeof buf)) > 0) atomic_fetch_add(&pd_taken, (int)r);
	}
	close(d);
	return 0;
}

static void pipe_drain(void) {
	int sv[2];
	CHECK("pipe_drain", socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, sv) == 0);
	pd_sock = sv[0];
	pthread_t t[4];
	for (int i = 0; i < 4; i++) CHECK("pipe_drain", pthread_create(&t[i], 0, pd_thread, 0) == 0);
	struct timespec t0;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	int i = 1;
	for (; i <= pd_n; i++) {
		if (write(sv[1], "x", 1) != 1) break;
		while (atomic_load(&pd_taken) < i && ms_since(&t0) < 20000) sched_yield();
		if (atomic_load(&pd_taken) < i) break;
	}
	atomic_store(&pd_done, 1);
	/* Bytes for any reader left waiting in a read, so the threads end. */
	write(sv[1], "xxxx", 4);
	for (int k = 0; k < 4; k++) pthread_join(t[k], 0);
	close(sv[0]);
	close(sv[1]);
	CHECK("pipe_drain", i > pd_n /* a reader waited in a read of an empty pipe */);
	printf("ok pipe_drain\n");
}

static int listener(int *port) {
	int l = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (l < 0) return -1;
	int one = 1;
	setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
	if (bind(l, (void *)&a, sizeof a) < 0 || listen(l, 64) < 0) return -1;
	socklen_t n = sizeof a;
	getsockname(l, (void *)&a, &n);
	*port = ntohs(a.sin_port);
	return l;
}

static int dial(int port, int flags) {
	int s = socket(AF_INET, SOCK_STREAM | flags, 0);
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
	int r = connect(s, (void *)&a, sizeof a);
	if (r < 0 && errno != EINPROGRESS) { close(s); return -1; }
	return s;
}

static void tcp_echo(void) {
	int port;
	int l = listener(&port);
	CHECK("tcp_echo", l >= 0 && port > 0);
	pid_t c = fork();
	if (c == 0) {
		int s = accept(l, 0, 0);
		char b[64];
		int n;
		while ((n = read(s, b, sizeof b)) > 0) write(s, b, n);
		_exit(0);
	}
	int s = dial(port, 0);
	CHECK("tcp_echo", s >= 0);
	int one = 1;
	CHECK("tcp_echo", setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one) == 0);
	CHECK("tcp_echo", send(s, "hello", 5, 0) == 5);
	char b[16] = {0};
	CHECK("tcp_echo", recv(s, b, sizeof b, 0) == 5 && memcmp(b, "hello", 5) == 0);
	struct sockaddr_in peer;
	socklen_t pl = sizeof peer;
	CHECK("tcp_echo", getpeername(s, (void *)&peer, &pl) == 0 && ntohs(peer.sin_port) == port);
	close(s);
	waitpid(c, 0, 0);
	close(l);
	printf("ok tcp_echo\n");
}

/* Edge-triggered epoll on a connected TCP socket that can be written at
 * once: the wait that follows the first report still sees it become
 * readable (Go's netpoller waits so). */
static void tcp_et(void) {
	int port;
	int l = listener(&port);
	CHECK("tcp_et", l >= 0);
	pid_t c = fork();
	if (c == 0) {
		int s = accept(l, 0, 0);
		usleep(200000);
		write(s, "x", 1);
		usleep(200000);
		_exit(0);
	}
	int s = dial(port, 0);
	CHECK("tcp_et", s >= 0);
	fcntl(s, F_SETFL, O_NONBLOCK);
	int ep = epoll_create1(0);
	struct epoll_event ev = {.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET, .data.u64 = 7};
	CHECK("tcp_et", epoll_ctl(ep, EPOLL_CTL_ADD, s, &ev) == 0);
	struct epoll_event out[4];
	CHECK("tcp_et", epoll_wait(ep, out, 4, 1000) == 1 && (out[0].events & EPOLLOUT) && !(out[0].events & EPOLLIN));
	char b[4];
	CHECK("tcp_et", read(s, b, 1) < 0 && errno == EAGAIN);
	int n = epoll_wait(ep, out, 4, 3000);
	CHECK("tcp_et", n == 1 && (out[0].events & EPOLLIN));
	CHECK("tcp_et", read(s, b, 1) == 1 && b[0] == 'x');
	close(ep);
	close(s);
	waitpid(c, 0, 0);
	close(l);
	printf("ok tcp_et\n");
}

/* Edge-triggered epoll in its own thread, as .NET's socket engine waits:
 * a report of IN that the reader takes up only after the wait has begun
 * again, a drain to EAGAIN, and then the next data, which must be
 * reported too. The peer answers each byte after a pause: the one at
 * $ETD_PORT on the host if it's set, or else a child. */
static int etd_ep, etd_in;
static pthread_mutex_t etd_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t etd_cv = PTHREAD_COND_INITIALIZER;

static void *etd_loop(void *a) {
	struct epoll_event out[4];
	for (;;) {
		int n = epoll_wait(etd_ep, out, 4, -1);
		for (int i = 0; i < n; i++)
			if (out[i].events & EPOLLIN) {
				pthread_mutex_lock(&etd_mu);
				etd_in = 1;
				pthread_cond_broadcast(&etd_cv);
				pthread_mutex_unlock(&etd_mu);
			}
	}
	return a;
}

static void tcp_et_drain(void) {
	int port, l = -1;
	pid_t c = -1;
	if (getenv("ETD_PORT") != NULL)
		port = atoi(getenv("ETD_PORT"));
	else {
		l = listener(&port);
		CHECK("tcp_et_drain", l >= 0);
		c = fork();
		if (c == 0) {
			int s = accept(l, 0, 0);
			char b;
			while (read(s, &b, 1) == 1) {
				usleep(150000);
				write(s, &b, 1);
			}
			_exit(0);
		}
	}
	int s = dial(port, SOCK_NONBLOCK);
	CHECK("tcp_et_drain", s >= 0);
	etd_ep = epoll_create1(0);
	struct epoll_event ev = {.events = EPOLLIN | EPOLLOUT | EPOLLET, .data.u64 = 1};
	CHECK("tcp_et_drain", epoll_ctl(etd_ep, EPOLL_CTL_ADD, s, &ev) == 0);
	pthread_t t;
	CHECK("tcp_et_drain", pthread_create(&t, 0, etd_loop, 0) == 0);
	usleep(100000);
	for (int round = 0; round < 3; round++) {
		char b = 'a' + round, got;
		CHECK("tcp_et_drain", send(s, &b, 1, MSG_NOSIGNAL) == 1);
		int r;
		while ((r = recv(s, &got, 1, MSG_DONTWAIT)) < 0) {
			CHECK("tcp_et_drain", errno == EAGAIN);
			struct timespec dl;
			clock_gettime(CLOCK_REALTIME, &dl);
			/* Long enough for a loaded host to start the child and
			 * run its echo; a missed edge still fails. */
			dl.tv_sec += 15;
			pthread_mutex_lock(&etd_mu);
			int to = 0;
			while (!etd_in && !to) to = pthread_cond_timedwait(&etd_cv, &etd_mu, &dl);
			etd_in = 0;
			pthread_mutex_unlock(&etd_mu);
			CHECK("tcp_et_drain", !to);
			/* Read once the epoll thread is waiting again. */
			usleep(50000);
		}
		CHECK("tcp_et_drain", r == 1 && got == b);
	}
	close(s);
	if (c > 0) {
		waitpid(c, 0, 0);
		close(l);
	}
	printf("ok tcp_et_drain\n");
}

/* getsockname on an IPv4 TCP socket before bind, and between bind and
 * listen, as Kestrel reads it: an AF_INET address, the bound port. */
static void bound_name(void) {
	int port;
	int l = listener(&port);
	CHECK("bound_name", l >= 0);
	close(l);
	int s = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in a;
	socklen_t n = sizeof a;
	memset(&a, 0xee, sizeof a);
	CHECK("bound_name", getsockname(s, (void *)&a, &n) == 0);
	CHECK("bound_name", n == sizeof a && a.sin_family == AF_INET && a.sin_port == 0 && a.sin_addr.s_addr == 0);
	int one = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	struct sockaddr_in b = {.sin_family = AF_INET, .sin_port = htons(port)};
	CHECK("bound_name", bind(s, (void *)&b, sizeof b) == 0);
	n = sizeof a;
	memset(&a, 0xee, sizeof a);
	CHECK("bound_name", getsockname(s, (void *)&a, &n) == 0);
	CHECK("bound_name", n == sizeof a && a.sin_family == AF_INET && ntohs(a.sin_port) == port && a.sin_addr.s_addr == 0);
	CHECK("bound_name", listen(s, 8) == 0);
	n = sizeof a;
	CHECK("bound_name", getsockname(s, (void *)&a, &n) == 0 && a.sin_family == AF_INET && ntohs(a.sin_port) == port);
	close(s);
	printf("ok bound_name\n");
}

static void nb_connect(void) {
	int port;
	int l = listener(&port);
	CHECK("nb_connect", l >= 0);
	int s = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
	CHECK("nb_connect", connect(s, (void *)&a, sizeof a) < 0 && errno == EINPROGRESS);
	struct pollfd f = {s, POLLOUT, 0};
	CHECK("nb_connect", poll(&f, 1, 5000) == 1 && (f.revents & POLLOUT));
	int err = -1;
	socklen_t el = sizeof err;
	CHECK("nb_connect", getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &el) == 0 && err == 0);
	/*
	 * Non-blocking accept: one pending, then none. The connect finishing
	 * doesn't mean the listener has the call yet: through a mounted /net
	 * the server answers listen separately, so wait for it to be readable,
	 * as an event loop does before it accepts.
	 */
	fcntl(l, F_SETFL, O_NONBLOCK);
	f = (struct pollfd){l, POLLIN, 0};
	CHECK("nb_connect", poll(&f, 1, 5000) == 1 && (f.revents & POLLIN));
	int a1 = accept4(l, 0, 0, SOCK_NONBLOCK);
	CHECK("nb_connect", a1 >= 0);
	CHECK("nb_connect", accept(l, 0, 0) < 0 && errno == EAGAIN);
	char b[4];
	CHECK("nb_connect", recv(a1, b, 4, 0) < 0 && errno == EAGAIN);
	close(a1);
	close(s);
	close(l);
	printf("ok nb_connect\n");
}

static void half_close(void) {
	int port;
	int l = listener(&port);
	CHECK("half_close", l >= 0);
	int s = dial(port, 0);
	int a = accept(l, 0, 0);
	CHECK("half_close", s >= 0 && a >= 0);
	int ep = epoll_create1(0);
	struct epoll_event ev = {.events = EPOLLIN | EPOLLRDHUP | EPOLLET, .data.fd = a};
	epoll_ctl(ep, EPOLL_CTL_ADD, a, &ev);
	CHECK("half_close", shutdown(s, SHUT_WR) == 0);
	struct epoll_event out;
	CHECK("half_close", epoll_wait(ep, &out, 1, 5000) == 1 && (out.events & EPOLLRDHUP));
	char b[4];
	CHECK("half_close", read(a, b, 4) == 0);
	/* The other way still works. */
	CHECK("half_close", write(a, "x", 1) == 1 && read(s, b, 1) == 1 && b[0] == 'x');
	close(a);
	close(s);
	close(l);
	printf("ok half_close\n");
}

/* A process that exits holding a socket closes it, so its peer reads EOF.
 * The child is the first process to poll a host socket, which starts h9's
 * host poller; that poller held on to the child's fds, so the connection
 * outlived it. */
static void exit_eof(void) {
	int port;
	int l = listener(&port);
	CHECK("exit_eof", l >= 0);
	pid_t c = fork();
	if (c == 0) {
		int a = accept(l, 0, 0);
		struct pollfd f = {a, POLLIN, 0};
		poll(&f, 1, 50);
		_exit(a >= 0 ? 0 : 1);
	}
	int s = dial(port, 0);
	CHECK("exit_eof", s >= 0);
	int st;
	CHECK("exit_eof", waitpid(c, &st, 0) == c && WIFEXITED(st) && WEXITSTATUS(st) == 0);
	alarm(10);
	char b[4];
	CHECK("exit_eof", read(s, b, sizeof b) == 0);
	alarm(0);
	close(s);
	close(l);
	printf("ok exit_eof\n");
}

/* An IPv6 socket with IPV6_V6ONLY and an IPv4 one listen on one port,
 * as Redis's default "bind * -::*" does; without IPv6 on the host, the
 * IPv6 socket is EAFNOSUPPORT, so Redis skips it. */
static void dual_bind(void) {
	int l4 = socket(AF_INET, SOCK_STREAM, 0);
	int one = 1;
	setsockopt(l4, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	struct sockaddr_in any = {.sin_family = AF_INET};
	CHECK("dual_bind", bind(l4, (void *)&any, sizeof any) == 0 && listen(l4, 8) == 0);
	/* An IPv4 wildcard socket is IPv4. */
	struct sockaddr_in got;
	socklen_t n = sizeof got;
	CHECK("dual_bind", getsockname(l4, (void *)&got, &n) == 0 && got.sin_family == AF_INET && got.sin_port != 0);
	int l6 = socket(AF_INET6, SOCK_STREAM, 0);
	if (l6 < 0) {
		CHECK("dual_bind", errno == EAFNOSUPPORT);
	} else {
		setsockopt(l6, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
		CHECK("dual_bind", setsockopt(l6, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one) == 0);
		struct sockaddr_in6 a = {.sin6_family = AF_INET6, .sin6_port = got.sin_port, .sin6_addr = IN6ADDR_ANY_INIT};
		CHECK("dual_bind", bind(l6, (void *)&a, sizeof a) == 0 && listen(l6, 8) == 0);
		close(l6);
	}
	close(l4);
	printf("ok dual_bind\n");
}

static void udp(void) {
	int r = socket(AF_INET, SOCK_DGRAM, 0);
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
	CHECK("udp", r >= 0 && bind(r, (void *)&a, sizeof a) == 0);
	socklen_t n = sizeof a;
	CHECK("udp", getsockname(r, (void *)&a, &n) == 0 && a.sin_port != 0);
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	CHECK("udp", sendto(s, "ping", 4, 0, (void *)&a, sizeof a) == 4);
	char b[16];
	struct sockaddr_in from;
	socklen_t fl = sizeof from;
	CHECK("udp", recvfrom(r, b, sizeof b, 0, (void *)&from, &fl) == 4 && memcmp(b, "ping", 4) == 0);
	CHECK("udp", from.sin_family == AF_INET && from.sin_addr.s_addr == htonl(INADDR_LOOPBACK) && from.sin_port != 0);
	/* And a reply to the sender's address. */
	CHECK("udp", sendto(r, "pong", 4, 0, (void *)&from, fl) == 4);
	CHECK("udp", recv(s, b, sizeof b, 0) == 4 && memcmp(b, "pong", 4) == 0);
	printf("ok udp\n");
}

/* Erlang's resolver: a fresh UDP socket, before it sends, has nothing to
 * read. poll says it's writable only, a nonblocking recv is EAGAIN (not
 * ENOTCONN), and a recv blocked on it wakes for the reply to its first
 * sendto, which another thread makes. */
static int uf_sock;
static char uf_buf[16];
static void *uf_waiter(void *arg) {
	(void)arg;
	return (void *)(long)recv(uf_sock, uf_buf, sizeof uf_buf, 0);
}
static void udp_fresh(void) {
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	struct pollfd pf = {s, POLLIN | POLLOUT, 0};
	CHECK("udp_fresh", s >= 0 && poll(&pf, 1, 0) == 1 && pf.revents == POLLOUT);
	char b[16];
	errno = 0;
	CHECK("udp_fresh", recv(s, b, sizeof b, MSG_DONTWAIT) < 0 && errno == EAGAIN);
	int r = socket(AF_INET, SOCK_DGRAM, 0);
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
	socklen_t n = sizeof a;
	CHECK("udp_fresh", r >= 0 && bind(r, (void *)&a, sizeof a) == 0 && getsockname(r, (void *)&a, &n) == 0);
	uf_sock = s;
	pthread_t t;
	CHECK("udp_fresh", pthread_create(&t, 0, uf_waiter, 0) == 0);
	usleep(100000);
	CHECK("udp_fresh", sendto(s, "ping", 4, 0, (void *)&a, sizeof a) == 4);
	struct sockaddr_in from;
	socklen_t fl = sizeof from;
	CHECK("udp_fresh", recvfrom(r, b, sizeof b, 0, (void *)&from, &fl) == 4);
	CHECK("udp_fresh", sendto(r, "pong", 4, 0, (void *)&from, fl) == 4);
	alarm(10);
	void *got;
	CHECK("udp_fresh", pthread_join(t, &got) == 0 && (long)got == 4 && memcmp(uf_buf, "pong", 4) == 0);
	alarm(0);
	close(s);
	close(r);
	printf("ok udp_fresh\n");
}

/* QUIC stacks (quinn, quic-go): probe UDP_SEGMENT and UDP_GRO, which h9
 * refuses so they send a datagram per call, then batch with sendmmsg and
 * recvmmsg. recvmmsg returns what's queued without waiting for the rest. */
static void udp_mmsg(void) {
	int r = socket(AF_INET, SOCK_DGRAM, 0);
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
	CHECK("udp_mmsg", r >= 0 && bind(r, (void *)&a, sizeof a) == 0);
	socklen_t n = sizeof a;
	CHECK("udp_mmsg", getsockname(r, (void *)&a, &n) == 0);
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	int one = 1, v = 0;
	socklen_t vl = sizeof v;
	CHECK("udp_mmsg", setsockopt(s, IPPROTO_UDP, 103 /* UDP_SEGMENT */, &one, sizeof one) < 0 && errno == ENOPROTOOPT);
	CHECK("udp_mmsg", getsockopt(s, IPPROTO_UDP, 103, &v, &vl) < 0 && errno == ENOPROTOOPT);
	CHECK("udp_mmsg", setsockopt(r, IPPROTO_UDP, 104 /* UDP_GRO */, &one, sizeof one) < 0 && errno == ENOPROTOOPT);
	char out[3][8] = {"one", "two", "three"};
	struct iovec oiov[3];
	struct mmsghdr om[3];
	memset(om, 0, sizeof om);
	for (int i = 0; i < 3; i++) {
		oiov[i] = (struct iovec){out[i], strlen(out[i])};
		om[i].msg_hdr = (struct msghdr){.msg_name = &a, .msg_namelen = sizeof a, .msg_iov = &oiov[i], .msg_iovlen = 1};
	}
	CHECK("udp_mmsg", sendmmsg(s, om, 3, 0) == 3);
	CHECK("udp_mmsg", om[0].msg_len == 3 && om[1].msg_len == 3 && om[2].msg_len == 5);
	char in[4][16];
	struct iovec iiov[4];
	struct sockaddr_in from[4];
	struct mmsghdr im[4];
	memset(im, 0, sizeof im);
	for (int i = 0; i < 4; i++) {
		iiov[i] = (struct iovec){in[i], sizeof in[i]};
		im[i].msg_hdr = (struct msghdr){.msg_name = &from[i], .msg_namelen = sizeof from[i], .msg_iov = &iiov[i], .msg_iovlen = 1};
	}
	/* Wait for all three to arrive, then take them in one call; the
	 * fourth slot finds the queue empty and ends the batch. */
	struct pollfd pf = {r, POLLIN, 0};
	CHECK("udp_mmsg", poll(&pf, 1, 2000) == 1);
	usleep(100000);
	int got = 0;
	while (got < 3) {
		int k = recvmmsg(r, im + got, 4 - got, MSG_DONTWAIT, NULL);
		CHECK("udp_mmsg", k > 0 || (k < 0 && errno == EAGAIN && poll(&pf, 1, 2000) == 1));
		if (k > 0) got += k;
	}
	CHECK("udp_mmsg", im[0].msg_len == 3 && memcmp(in[0], "one", 3) == 0);
	CHECK("udp_mmsg", im[1].msg_len == 3 && memcmp(in[1], "two", 3) == 0);
	CHECK("udp_mmsg", im[2].msg_len == 5 && memcmp(in[2], "three", 5) == 0);
	CHECK("udp_mmsg", from[2].sin_family == AF_INET && from[2].sin_port != 0);
	errno = 0;
	CHECK("udp_mmsg", recvmmsg(r, im, 4, MSG_DONTWAIT, NULL) < 0 && errno == EAGAIN);
	printf("ok udp_mmsg\n");
}

/* glibc's resolver: a connected, non-blocking socket sends the A and
 * AAAA queries in one sendmmsg, and sizes the buffer for each answer
 * with FIONREAD, which is the next datagram's length. Told 0, it
 * receives the second into no buffer and fails the lookup. */
static void udp_fionread(void) {
	int r = socket(AF_INET, SOCK_DGRAM, 0);
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
	CHECK("udp_fionread", r >= 0 && bind(r, (void *)&a, sizeof a) == 0);
	socklen_t n = sizeof a;
	CHECK("udp_fionread", getsockname(r, (void *)&a, &n) == 0);
	int s = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	CHECK("udp_fionread", s >= 0 && connect(s, (void *)&a, sizeof a) == 0);
	int q = -1;
	CHECK("udp_fionread", ioctl(s, FIONREAD, &q) == 0 && q == 0);
	char q1[] = "query A", q2[] = "query AAAA";
	struct iovec iov[2] = {{q1, strlen(q1)}, {q2, strlen(q2)}};
	struct mmsghdr m[2];
	memset(m, 0, sizeof m);
	for (int i = 0; i < 2; i++)
		m[i].msg_hdr = (struct msghdr){.msg_iov = &iov[i], .msg_iovlen = 1};
	CHECK("udp_fionread", sendmmsg(s, m, 2, MSG_NOSIGNAL) == 2);
	char b[64];
	struct sockaddr_in from;
	for (int i = 0; i < 2; i++) {
		socklen_t fl = sizeof from;
		CHECK("udp_fionread", recvfrom(r, b, sizeof b, 0, (void *)&from, &fl) == (ssize_t)iov[i].iov_len);
	}
	/* Answers of three sizes, the last for a zero-length recv. */
	CHECK("udp_fionread", sendto(r, "answer one", 10, 0, (void *)&from, sizeof from) == 10);
	CHECK("udp_fionread", sendto(r, "answer number two", 17, 0, (void *)&from, sizeof from) == 17);
	CHECK("udp_fionread", sendto(r, "three", 5, 0, (void *)&from, sizeof from) == 5);
	struct pollfd pf = {s, POLLIN, 0};
	CHECK("udp_fionread", poll(&pf, 1, 2000) == 1 && (pf.revents & POLLIN));
	usleep(100000);
	CHECK("udp_fionread", ioctl(s, FIONREAD, &q) == 0 && q == 10);
	CHECK("udp_fionread", recv(s, b, sizeof b, 0) == 10 && memcmp(b, "answer one", 10) == 0);
	CHECK("udp_fionread", ioctl(s, FIONREAD, &q) == 0 && q == 17);
	CHECK("udp_fionread", recv(s, b, sizeof b, 0) == 17 && memcmp(b, "answer number two", 17) == 0);
	/* A zero-length recv takes the datagram and returns 0, as Linux's. */
	CHECK("udp_fionread", ioctl(s, FIONREAD, &q) == 0 && q == 5);
	CHECK("udp_fionread", recvfrom(s, NULL, 0, 0, NULL, NULL) == 0);
	CHECK("udp_fionread", ioctl(s, FIONREAD, &q) == 0 && q == 0);
	errno = 0;
	CHECK("udp_fionread", recv(s, b, sizeof b, 0) < 0 && errno == EAGAIN);
	close(s);
	close(r);
	printf("ok udp_fionread\n");
}

/* musl's resolver: bind to any address and port 0, then two sendtos to
 * the same server (the A and AAAA queries). Under --net outbound the
 * bind can't announce, so the first sendto connects the socket and the
 * second, to the same address, must still send. */
static void udp_twice(int port) {
	int s = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	struct sockaddr_in any = {.sin_family = AF_INET};
	CHECK("udp_twice", s >= 0 && bind(s, (void *)&any, sizeof any) == 0);
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
	CHECK("udp_twice", sendto(s, "A", 1, MSG_NOSIGNAL, (void *)&a, sizeof a) == 1);
	CHECK("udp_twice", sendto(s, "B", 1, MSG_NOSIGNAL, (void *)&a, sizeof a) == 1);
	close(s);
	printf("ok udp_twice\n");
}

/* getaddrinfo's route probes under a name pattern (design/linux-dns.md):
 * NAME has an A record for 127.0.0.1 and an AAAA record with no route.
 * musl ranks the answers by connecting a UDP socket to each, so the IPv4
 * address must come first. A UDP socket connected to it, to PORT, which
 * no pattern allows for UDP, is a probe: the connect and getsockname
 * work, and send, write, and sendto fail with EACCES. */
static void udp_probe(const char *name, const char *port) {
	struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM}, *ai;
	CHECK("udp_probe", getaddrinfo(name, port, &hints, &ai) == 0);
	CHECK("udp_probe", ai->ai_family == AF_INET && ai->ai_next != NULL);
	struct sockaddr_in a = *(struct sockaddr_in *)ai->ai_addr, l;
	freeaddrinfo(ai);
	int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	socklen_t n = sizeof l;
	CHECK("udp_probe", s >= 0 && connect(s, (void *)&a, sizeof a) == 0);
	CHECK("udp_probe", getsockname(s, (void *)&l, &n) == 0 && l.sin_addr.s_addr == htonl(INADDR_LOOPBACK));
	errno = 0;
	CHECK("udp_probe", send(s, "probe", 5, MSG_NOSIGNAL) == -1 && errno == EACCES);
	errno = 0;
	CHECK("udp_probe", write(s, "probe", 5) == -1 && errno == EACCES);
	errno = 0;
	CHECK("udp_probe", sendto(s, "probe", 5, MSG_NOSIGNAL, (void *)&a, sizeof a) == -1 && errno == EACCES);
	close(s);
	/* A sendto on a socket that isn't connected tries the same. */
	s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	errno = 0;
	CHECK("udp_probe", sendto(s, "probe", 5, MSG_NOSIGNAL, (void *)&a, sizeof a) == -1 && errno == EACCES);
	close(s);
	printf("ok udp_probe\n");
}

/* A UDP connect to ADDR!PORT, an address no lookup recorded, is refused. */
static void udp_refused(const char *addr, int port) {
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
	CHECK("udp_refused", inet_pton(AF_INET, addr, &a.sin_addr) == 1);
	int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	errno = 0;
	CHECK("udp_refused", s >= 0 && connect(s, (void *)&a, sizeof a) == -1 && errno == EACCES);
	close(s);
	printf("ok udp_refused\n");
}

static void many(void) {
	int port;
	int l = listener(&port);
	CHECK("many", l >= 0);
	enum { N = 40 };
	int c[N], a[N];
	for (int i = 0; i < N; i++) {
		c[i] = dial(port, 0);
		CHECK("many", c[i] >= 0);
		a[i] = accept(l, 0, 0);
		CHECK("many", a[i] >= 0);
	}
	for (int i = 0; i < N; i++) {
		char b = 'a' + i % 26, r;
		CHECK("many", write(c[i], &b, 1) == 1 && read(a[i], &r, 1) == 1 && r == b);
	}
	for (int i = 0; i < N; i++) { close(c[i]); close(a[i]); }
	close(l);
	printf("ok many\n");
}

static void disabled(void) {
	int s = socket(AF_INET, SOCK_STREAM, 0);
	CHECK("disabled", s < 0 && errno == EACCES);
	printf("ok disabled\n");
}

/* A server and client over a named and an abstract Unix socket, as
 * PostgreSQL's local connections are; no network needed. */
static void unix_one(const char *name, struct sockaddr_un *a, socklen_t alen) {
	int l = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	CHECK(name, l >= 0);
	CHECK(name, connect(l, (struct sockaddr *)a, alen) < 0);
	close(l);
	l = socket(AF_UNIX, SOCK_STREAM, 0);
	CHECK(name, bind(l, (struct sockaddr *)a, alen) == 0 && listen(l, 8) == 0);
	int again = socket(AF_UNIX, SOCK_STREAM, 0);
	CHECK(name, bind(again, (struct sockaddr *)a, alen) < 0 && errno == EADDRINUSE);
	/* A listening socket's file is a socket, as Wine's client checks. */
	struct stat st;
	if (a->sun_path[0] != 0) CHECK(name, stat(a->sun_path, &st) == 0 && S_ISSOCK(st.st_mode));
	close(again);
	struct sockaddr_un got;
	socklen_t gl = sizeof got;
	CHECK(name, getsockname(l, (struct sockaddr *)&got, &gl) == 0 && gl == alen && memcmp(&got, a, alen) == 0);
	pid_t c = fork();
	if (c == 0) {
		for (int i = 0; i < 2; i++) {
			int s = socket(AF_UNIX, SOCK_STREAM, 0);
			if (connect(s, (struct sockaddr *)a, alen) != 0) _exit(1);
			char b[16] = {0};
			if (send(s, "ping", 4, 0) != 4 || recv(s, b, sizeof b, 0) != 4 || strcmp(b, "pong") != 0) _exit(2);
			close(s);
		}
		_exit(0);
	}
	/* The listener wakes epoll, as PostgreSQL's postmaster waits. */
	int ep = epoll_create1(0);
	struct epoll_event ev = {.events = EPOLLIN, .data.fd = l}, out;
	CHECK(name, epoll_ctl(ep, EPOLL_CTL_ADD, l, &ev) == 0);
	for (int i = 0; i < 2; i++) {
		CHECK(name, epoll_wait(ep, &out, 1, 5000) == 1 && out.data.fd == l);
		struct sockaddr_un peer;
		socklen_t pl = sizeof peer;
		int s = accept4(l, (struct sockaddr *)&peer, &pl, SOCK_CLOEXEC);
		CHECK(name, s >= 0 && pl == sizeof(sa_family_t));
		int type = 0;
		socklen_t tl = sizeof type;
		CHECK(name, getsockopt(s, SOL_SOCKET, SO_TYPE, &type, &tl) == 0 && type == SOCK_STREAM);
		char b[16] = {0};
		CHECK(name, recv(s, b, sizeof b, 0) == 4 && strcmp(b, "ping") == 0 && send(s, "pong", 4, 0) == 4);
		close(s);
	}
	CHECK(name, waitpid(c, 0, 0) == c);
	close(ep);
	close(l);
	/* With the listener gone, a connect is refused. */
	int s = socket(AF_UNIX, SOCK_STREAM, 0);
	CHECK(name, connect(s, (struct sockaddr *)a, alen) < 0 && errno == ECONNREFUSED);
	close(s);
	printf("ok %s\n", name);
}

static void unix_sock(void) {
	struct sockaddr_un a = {.sun_family = AF_UNIX};
	const char *d = getenv("DIR");
	snprintf(a.sun_path, sizeof a.sun_path, "%s/.s.test", d ? d : "/tmp");
	unlink(a.sun_path);
	unix_one("unix_sock", &a, offsetof(struct sockaddr_un, sun_path) + strlen(a.sun_path) + 1);
	unlink(a.sun_path);
	struct sockaddr_un b = {.sun_family = AF_UNIX};
	memcpy(b.sun_path, "\0h9-abstract", 12);
	unix_one("unix_abstract", &b, offsetof(struct sockaddr_un, sun_path) + 12);
}

/* Sends one byte of `data` with fd attached (fd < 0: none). */
static int send_fd(int s, char data, int fd) {
	char cbuf[CMSG_SPACE(sizeof(int))] = {0};
	struct iovec iov = {.iov_base = &data, .iov_len = 1};
	struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1};
	if (fd >= 0) {
		m.msg_control = cbuf;
		m.msg_controllen = sizeof cbuf;
		struct cmsghdr *c = CMSG_FIRSTHDR(&m);
		c->cmsg_level = SOL_SOCKET;
		c->cmsg_type = SCM_RIGHTS;
		c->cmsg_len = CMSG_LEN(sizeof(int));
		memcpy(CMSG_DATA(c), &fd, sizeof fd);
	}
	return sendmsg(s, &m, 0);
}

/* recvmsg into buf; *fd gets a passed fd, or -1. */
static int recv_fd(int s, char *buf, int n, int *fd) {
	char cbuf[CMSG_SPACE(sizeof(int) * 4)];
	struct iovec iov = {.iov_base = buf, .iov_len = n};
	struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = cbuf, .msg_controllen = sizeof cbuf};
	int r = recvmsg(s, &m, MSG_CMSG_CLOEXEC);
	*fd = -1;
	if (r < 0) return r;
	struct cmsghdr *c = CMSG_FIRSTHDR(&m);
	if (c && c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS && c->cmsg_len == CMSG_LEN(sizeof(int)))
		memcpy(fd, CMSG_DATA(c), sizeof(int));
	return r;
}

/* SCM_RIGHTS over a socket pair and across fork, as Wine's wineserver
 * passes fds: a read stops before a message with fds and takes only
 * that message, and fds a plain read skips over are closed. */
static void scm_rights(void) {
	int sv[2], p[2], fd;
	char b[16];
	CHECK("scm_rights", socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0 && pipe(p) == 0);
	CHECK("scm_rights", write(sv[0], "a", 1) == 1 && send_fd(sv[0], 'b', p[1]) == 1 && write(sv[0], "c", 1) == 1);
	close(p[1]);
	CHECK("scm_rights", recv_fd(sv[1], b, sizeof b, &fd) == 1 && b[0] == 'a' && fd == -1);
	CHECK("scm_rights", recv_fd(sv[1], b, sizeof b, &fd) == 1 && b[0] == 'b' && fd >= 0);
	int fd2 = fd;
	CHECK("scm_rights", (fcntl(fd2, F_GETFD) & FD_CLOEXEC) != 0);
	CHECK("scm_rights", recv_fd(sv[1], b, sizeof b, &fd) == 1 && b[0] == 'c' && fd == -1);
	/* The passed write end works, and is the pipe's last writer once closed. */
	CHECK("scm_rights", write(fd2, "x", 1) == 1 && close(fd2) == 0);
	CHECK("scm_rights", read(p[0], b, sizeof b) == 1 && b[0] == 'x' && read(p[0], b, sizeof b) == 0);
	int w = -1;
	/* A child passes an fd back to its parent. */
	int q[2];
	CHECK("scm_rights", pipe(q) == 0);
	pid_t c = fork();
	if (c == 0) {
		if (send_fd(sv[1], 'e', q[1]) != 1) _exit(1);
		_exit(0);
	}
	CHECK("scm_rights", waitpid(c, 0, 0) == c);
	close(q[1]);
	CHECK("scm_rights", recv_fd(sv[0], b, sizeof b, &w) == 1 && b[0] == 'e' && w >= 0);
	CHECK("scm_rights", write(w, "x", 1) == 1 && close(w) == 0 && read(q[0], b, sizeof b) == 1 && b[0] == 'x');
	CHECK("scm_rights", read(q[0], b, sizeof b) == 0);
	/* An fd that a plain read skips is closed: the pipe sees its writer go. */
	int r2[2];
	CHECK("scm_rights", pipe(r2) == 0 && send_fd(sv[0], 'f', r2[1]) == 1);
	close(r2[1]);
	CHECK("scm_rights", read(sv[1], b, sizeof b) == 1 && b[0] == 'f');
	CHECK("scm_rights", read(r2[0], b, sizeof b) == 0);
	printf("ok scm_rights\n");
}

/* WebKit's IPC: a SOCK_SEQPACKET socket pair sends each message as a
 * gathered iovec and reads it back whole, one message per read; the
 * ends are sockets (fstat, SO_TYPE); SO_PASSCRED on the reader gets
 * SCM_CREDENTIALS naming the sender; and an end passed with
 * SCM_RIGHTS is still a socket in the receiver. */
static void seqpacket(void) {
	int sv[2], sv2[2], fd, on = 1, t;
	socklen_t tl = sizeof t;
	struct stat st;
	char h[4] = "head", body[6] = "body!", b[64];
	CHECK("seqpacket", socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv) == 0);
	CHECK("seqpacket", fstat(sv[0], &st) == 0 && S_ISSOCK(st.st_mode));
	CHECK("seqpacket", getsockopt(sv[0], SOL_SOCKET, SO_TYPE, &t, &tl) == 0 && t == SOCK_SEQPACKET);
	struct iovec out[2] = {{h, 4}, {body, 5}};
	CHECK("seqpacket", writev(sv[0], out, 2) == 9 && write(sv[0], "x", 1) == 1);
	struct iovec in[2] = {{b, 2}, {b + 2, 30}};
	CHECK("seqpacket", readv(sv[1], in, 2) == 9 && !memcmp(b, "headbody!", 9));
	CHECK("seqpacket", read(sv[1], b, sizeof b) == 1 && b[0] == 'x');

	CHECK("seqpacket", setsockopt(sv[1], SOL_SOCKET, SO_PASSCRED, &on, sizeof on) == 0);
	on = 0;
	CHECK("seqpacket", getsockopt(sv[1], SOL_SOCKET, SO_PASSCRED, &on, &tl) == 0 && on == 1);
	CHECK("seqpacket", write(sv[0], "c", 1) == 1);
	char cbuf[CMSG_SPACE(sizeof(struct ucred))];
	struct iovec iov = {b, sizeof b};
	struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = cbuf, .msg_controllen = sizeof cbuf};
	CHECK("seqpacket", recvmsg(sv[1], &m, 0) == 1 && b[0] == 'c');
	struct cmsghdr *c = CMSG_FIRSTHDR(&m);
	CHECK("seqpacket", c && c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_CREDENTIALS);
	struct ucred u;
	memcpy(&u, CMSG_DATA(c), sizeof u);
	CHECK("seqpacket", u.pid == getpid() && u.uid == getuid());

	CHECK("seqpacket", socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv2) == 0);
	CHECK("seqpacket", send_fd(sv[0], 'r', sv2[1]) == 1 && close(sv2[1]) == 0);
	m.msg_controllen = sizeof cbuf;
	char rb[CMSG_SPACE(sizeof(struct ucred)) + CMSG_SPACE(sizeof(int))];
	m.msg_control = rb;
	m.msg_controllen = sizeof rb;
	CHECK("seqpacket", recvmsg(sv[1], &m, 0) == 1 && b[0] == 'r');
	fd = -1;
	for (c = CMSG_FIRSTHDR(&m); c; c = CMSG_NXTHDR(&m, c))
		if (c->cmsg_type == SCM_RIGHTS) memcpy(&fd, CMSG_DATA(c), sizeof fd);
	CHECK("seqpacket", fd >= 0 && fstat(fd, &st) == 0 && S_ISSOCK(st.st_mode));
	CHECK("seqpacket", setsockopt(fd, SOL_SOCKET, SO_PASSCRED, &on, sizeof on) == 0);
	CHECK("seqpacket", write(sv2[0], "p", 1) == 1 && read(fd, b, sizeof b) == 1 && b[0] == 'p');
	close(fd), close(sv2[0]), close(sv[0]), close(sv[1]);
	printf("ok seqpacket\n");
}

/* getifaddrs (netlink's link and address dumps) lists loopback, up,
 * with 127.0.0.1; a listener bound to 127.0.0.1 reports that address,
 * not the wildcard. */
static void ifaddrs(void) {
	struct ifaddrs *ifs, *i;
	int lo = 0;
	CHECK("ifaddrs", getifaddrs(&ifs) == 0);
	for (i = ifs; i; i = i->ifa_next)
		if (i->ifa_addr && i->ifa_addr->sa_family == AF_INET &&
		    ((struct sockaddr_in *)i->ifa_addr)->sin_addr.s_addr == htonl(INADDR_LOOPBACK))
			lo = !strcmp(i->ifa_name, "lo") && (i->ifa_flags & 1);
	freeifaddrs(ifs);
	CHECK("ifaddrs", lo);
	int l = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in a = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
	socklen_t n = sizeof a;
	CHECK("ifaddrs", bind(l, (void *)&a, sizeof a) == 0 && listen(l, 1) == 0);
	CHECK("ifaddrs", getsockname(l, (void *)&a, &n) == 0 && a.sin_addr.s_addr == htonl(INADDR_LOOPBACK));
	close(l);
	printf("ok ifaddrs\n");
}

/* GLib sizes a netlink read with MSG_PEEK|MSG_TRUNC first: the peek
 * returns the full length and leaves the message for the real read. */
static void netlink_peek(void) {
	int s = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
	CHECK("netlink_peek", s >= 0);
	struct { struct nlmsghdr h; struct rtgenmsg g; } req = {
		.h = {.nlmsg_len = sizeof req, .nlmsg_type = RTM_GETLINK, .nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP, .nlmsg_seq = 1},
		.g = {.rtgen_family = AF_UNSPEC}};
	CHECK("netlink_peek", send(s, &req, sizeof req, 0) == sizeof req);
	char one[1], buf[65536];
	int n = recv(s, one, 1, MSG_PEEK | MSG_TRUNC);
	CHECK("netlink_peek", n > (int)sizeof(struct nlmsghdr));
	CHECK("netlink_peek", recv(s, buf, sizeof buf, 0) == n);
	close(s);
	printf("ok netlink_peek\n");
}

int main(int argc, char **argv) {
	signal(SIGPIPE, SIG_IGN);
	setvbuf(stdout, 0, _IONBF, 0);
	for (int i = 1; i < argc; i++) {
		const char *n = argv[i];
		int all = strcmp(n, "all") == 0;
		if (all || !strcmp(n, "poll_pipe")) poll_pipe();
		if (all || !strcmp(n, "nonblock_pipe")) nonblock_pipe();
		if (all || !strcmp(n, "readv_pipe")) readv_pipe();
		if (all || !strcmp(n, "pipe_full")) pipe_full();
		if (all || !strcmp(n, "splice_pipe")) splice_pipe();
		if (!strcmp(n, "poll_ready")) poll_ready();
		if (all || !strcmp(n, "epoll_et")) epoll_et();
		if (all || !strcmp(n, "eventfd")) eventfd_epoll();
		if (all || !strcmp(n, "dupfd_threads")) dupfd_threads();
		if (all || !strcmp(n, "pipe_drain")) pipe_drain();
		if (all || !strcmp(n, "eventfd_waker")) eventfd_waker();
		if (all || !strcmp(n, "unix_sock")) unix_sock();
		if (all || !strcmp(n, "scm_rights")) scm_rights();
		if (all || !strcmp(n, "seqpacket")) seqpacket();
		if (!strcmp(n, "tcp_echo") || !strcmp(n, "net")) tcp_echo();
		if (!strcmp(n, "nb_connect") || !strcmp(n, "net")) nb_connect();
		if (!strcmp(n, "tcp_et") || !strcmp(n, "net")) tcp_et();
		if (!strcmp(n, "bound_name") || !strcmp(n, "net")) bound_name();
		if (!strcmp(n, "tcp_et_drain") || !strcmp(n, "net")) tcp_et_drain();
		if (!strcmp(n, "half_close") || !strcmp(n, "net")) half_close();
		if (!strcmp(n, "exit_eof") || !strcmp(n, "net")) exit_eof();
		if (!strcmp(n, "dual_bind") || !strcmp(n, "net")) dual_bind();
		if (!strcmp(n, "udp") || !strcmp(n, "net")) udp();
		if (!strcmp(n, "udp_fresh") || !strcmp(n, "net")) udp_fresh();
		if (!strcmp(n, "udp_mmsg") || !strcmp(n, "net")) udp_mmsg();
		if (!strcmp(n, "udp_fionread") || !strcmp(n, "net")) udp_fionread();
		if (!strcmp(n, "many") || !strcmp(n, "net")) many();
		if (!strcmp(n, "disabled")) disabled();
		if (!strcmp(n, "ifaddrs")) ifaddrs();
		if (!strcmp(n, "netlink_peek")) netlink_peek();
		if (!strcmp(n, "udp_twice") && i + 1 < argc) udp_twice(atoi(argv[++i]));
		if (!strcmp(n, "udp_probe") && i + 2 < argc) { udp_probe(argv[i + 1], argv[i + 2]); i += 2; }
		if (!strcmp(n, "udp_refused") && i + 2 < argc) { udp_refused(argv[i + 1], atoi(argv[i + 2])); i += 2; }
	}
	return failed;
}
