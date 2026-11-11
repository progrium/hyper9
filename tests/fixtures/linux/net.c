/* Readiness and sockets (design/linux-net.md): each case named on
 * the command line prints "ok NAME" or "FAIL NAME: why". "all" runs the
 * ones that need no network; the socket cases need --net=enable. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
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
	/* Non-blocking accept: one pending, then none. */
	fcntl(l, F_SETFL, O_NONBLOCK);
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
		if (all || !strcmp(n, "epoll_et")) epoll_et();
		if (all || !strcmp(n, "eventfd")) eventfd_epoll();
		if (all || !strcmp(n, "unix_sock")) unix_sock();
		if (all || !strcmp(n, "scm_rights")) scm_rights();
		if (all || !strcmp(n, "seqpacket")) seqpacket();
		if (!strcmp(n, "tcp_echo") || !strcmp(n, "net")) tcp_echo();
		if (!strcmp(n, "nb_connect") || !strcmp(n, "net")) nb_connect();
		if (!strcmp(n, "tcp_et") || !strcmp(n, "net")) tcp_et();
		if (!strcmp(n, "half_close") || !strcmp(n, "net")) half_close();
		if (!strcmp(n, "exit_eof") || !strcmp(n, "net")) exit_eof();
		if (!strcmp(n, "dual_bind") || !strcmp(n, "net")) dual_bind();
		if (!strcmp(n, "udp") || !strcmp(n, "net")) udp();
		if (!strcmp(n, "udp_mmsg") || !strcmp(n, "net")) udp_mmsg();
		if (!strcmp(n, "many") || !strcmp(n, "net")) many();
		if (!strcmp(n, "disabled")) disabled();
		if (!strcmp(n, "ifaddrs")) ifaddrs();
		if (!strcmp(n, "netlink_peek")) netlink_peek();
		if (!strcmp(n, "udp_twice") && i + 1 < argc) udp_twice(atoi(argv[++i]));
	}
	return failed;
}
