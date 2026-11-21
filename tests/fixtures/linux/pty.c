/* Pseudoterminals (design/linux-pty.md): each case named on the command
 * line prints "ok NAME" or "FAIL NAME: why". */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#ifndef TIOCGPTPEER
#define TIOCGPTPEER _IO('T', 0x41)
#endif

static int failed;

#define CHECK(name, cond) do { if (!(cond)) { printf("FAIL %s: %s (errno %d %s)\n", name, #cond, errno, strerror(errno)); failed = 1; return; } } while (0)

/* A new pair with its default termios: the master in *m, the slave opened by its name in *s. */
static int cooked(int *m, int *s, char *name, size_t n) {
	*m = posix_openpt(O_RDWR | O_NOCTTY);
	if (*m < 0 || grantpt(*m) != 0 || unlockpt(*m) != 0)
		return -1;
	if (ptsname_r(*m, name, n) != 0)
		return -1;
	*s = open(name, O_RDWR | O_NOCTTY);
	return *s < 0 ? -1 : 0;
}

/* The same, in raw mode (cfmakeraw), so bytes pass unchanged. */
static int pair(int *m, int *s, char *name, size_t n) {
	struct termios t;
	if (cooked(m, s, name, n) != 0 || tcgetattr(*s, &t) != 0)
		return -1;
	cfmakeraw(&t);
	return tcsetattr(*s, TCSANOW, &t);
}

/* Reads exactly n bytes, or fails. */
static int readn(int fd, char *buf, int n) {
	int got = 0;
	while (got < n) {
		int r = read(fd, buf + got, n - got);
		if (r <= 0)
			return -1;
		got += r;
	}
	return got;
}

static void openpt(void) {
	int m, s;
	char name[64], buf[64];
	CHECK("openpt", pair(&m, &s, name, sizeof name) == 0);
	CHECK("openpt", strncmp(name, "/dev/pts/", 9) == 0);
	CHECK("openpt", isatty(m) && isatty(s));
	struct stat st;
	CHECK("openpt", fstat(s, &st) == 0 && S_ISCHR(st.st_mode) && major(st.st_rdev) == 136 && minor(st.st_rdev) == (unsigned)atoi(name + 9));
	CHECK("openpt", stat("/dev/ptmx", &st) == 0 && S_ISCHR(st.st_mode) && major(st.st_rdev) == 5 && minor(st.st_rdev) == 2);
	CHECK("openpt", stat(name, &st) == 0 && S_ISCHR(st.st_mode));
	CHECK("openpt", ttyname_r(s, buf, sizeof buf) == 0 && strcmp(buf, name) == 0);
	CHECK("openpt", write(m, "to slave", 8) == 8);
	CHECK("openpt", readn(s, buf, 8) == 8 && memcmp(buf, "to slave", 8) == 0);
	CHECK("openpt", write(s, "to master", 9) == 9);
	CHECK("openpt", readn(m, buf, 9) == 9 && memcmp(buf, "to master", 9) == 0);
	/* Both numbers are in /dev/pts while the pair is open. */
	CHECK("openpt", access(name, F_OK) == 0);
	close(s);
	close(m);
	CHECK("openpt", access(name, F_OK) != 0);
	printf("ok openpt\n");
}

static void eof(void) {
	int m, s;
	char name[64], buf[16];
	CHECK("eof", pair(&m, &s, name, sizeof name) == 0);
	CHECK("eof", write(s, "last", 4) == 4);
	close(s);
	/* What the slave wrote is still read, and then EIO. */
	CHECK("eof", readn(m, buf, 4) == 4 && memcmp(buf, "last", 4) == 0);
	errno = 0;
	CHECK("eof", read(m, buf, sizeof buf) < 0 && errno == EIO);
	struct pollfd pf = {.fd = m, .events = POLLIN};
	CHECK("eof", poll(&pf, 1, 1000) == 1 && (pf.revents & POLLHUP));
	/* The slave opens again, and the master reads it. */
	s = open(name, O_RDWR | O_NOCTTY);
	CHECK("eof", s >= 0 && write(s, "again", 5) == 5 && readn(m, buf, 5) == 5);
	close(s);
	close(m);
	printf("ok eof\n");
}

static void raw(void) {
	int m, s;
	char name[64];
	unsigned char out[256], in[256];
	struct termios t;
	CHECK("raw", cooked(&m, &s, name, sizeof name) == 0);
	CHECK("raw", tcgetattr(s, &t) == 0 && (t.c_lflag & ICANON) && (t.c_lflag & ECHO));
	cfmakeraw(&t);
	CHECK("raw", tcsetattr(s, TCSANOW, &t) == 0);
	struct termios back;
	CHECK("raw", tcgetattr(m, &back) == 0 && !(back.c_lflag & (ICANON | ECHO)) && !(back.c_oflag & OPOST));
	for (int i = 0; i < 256; i++)
		out[i] = i;
	CHECK("raw", write(m, out, 256) == 256 && readn(s, (char *)in, 256) == 256 && memcmp(in, out, 256) == 0);
	CHECK("raw", write(s, out, 256) == 256 && readn(m, (char *)in, 256) == 256 && memcmp(in, out, 256) == 0);
	/* Nothing was echoed back to the master. */
	int q = -1;
	CHECK("raw", ioctl(m, FIONREAD, &q) == 0 && q == 0);
	CHECK("raw", write(m, "abc", 3) == 3 && ioctl(s, FIONREAD, &q) == 0 && q == 3);
	CHECK("raw", tcflush(s, TCIFLUSH) == 0 && ioctl(s, FIONREAD, &q) == 0 && q == 0);
	close(s);
	close(m);
	printf("ok raw\n");
}

static void locked(void) {
	int m = posix_openpt(O_RDWR | O_NOCTTY);
	char name[64];
	CHECK("locked", m >= 0 && ptsname_r(m, name, sizeof name) == 0);
	errno = 0;
	CHECK("locked", open(name, O_RDWR | O_NOCTTY) < 0 && errno == EIO);
	CHECK("locked", unlockpt(m) == 0);
	int s = open(name, O_RDWR | O_NOCTTY);
	CHECK("locked", s >= 0);
	/* TIOCGPTPEER opens the slave without its name. */
	int p = ioctl(m, TIOCGPTPEER, O_RDWR | O_NOCTTY);
	char buf[64];
	CHECK("locked", p >= 0 && write(m, "pe\n", 3) == 3 && readn(p, buf, 3) == 3);
	CHECK("locked", ttyname_r(p, buf, sizeof buf) == 0 && strcmp(buf, name) == 0);
	close(p);
	close(s);
	close(m);
	printf("ok locked\n");
}

static void nonblock(void) {
	int m, s;
	char name[64], buf[8];
	CHECK("nonblock", pair(&m, &s, name, sizeof name) == 0);
	CHECK("nonblock", fcntl(m, F_SETFL, O_NONBLOCK) == 0);
	errno = 0;
	CHECK("nonblock", read(m, buf, sizeof buf) < 0 && errno == EAGAIN);
	struct pollfd pf = {.fd = m, .events = POLLIN | POLLOUT};
	CHECK("nonblock", poll(&pf, 1, 0) == 1 && pf.revents == POLLOUT);
	if (fork() == 0) {
		usleep(100000);
		write(s, "x", 1);
		_exit(0);
	}
	pf.events = POLLIN;
	CHECK("nonblock", poll(&pf, 1, 5000) == 1 && (pf.revents & POLLIN));
	CHECK("nonblock", read(m, buf, sizeof buf) == 1);
	wait(NULL);
	close(s);
	close(m);
	printf("ok nonblock\n");
}

static volatile sig_atomic_t got;
static void onsig(int n) { got = n; }

/*
 * A child that closes the master m, makes a session with the slave as its terminal, says
 * so on `ready`, then waits up to two seconds for signal `want`. Its
 * exit status: 0 if it came, 1 if not, 2 if setting up failed.
 */
static pid_t terminal_child(int m, const char *name, int ready, int want) {
	pid_t c = fork();
	if (c != 0)
		return c;
	close(m);	/* the master's last close is the parent's */
	signal(want, onsig);
	if (setsid() < 0)
		_exit(2);
	int s = open(name, O_RDWR);	/* without O_NOCTTY: the session's terminal now */
	if (s < 0)
		_exit(2);
	if (tcgetpgrp(s) != getpid() || tcgetsid(s) != getpid())
		_exit(2);
	/* /dev/tty is the slave. */
	int t = open("/dev/tty", O_RDWR);
	char tn[64];
	if (t < 0 || ttyname_r(t, tn, sizeof tn) != 0 || strcmp(tn, name) != 0)
		_exit(2);
	write(ready, "r", 1);
	for (int i = 0; i < 200 && got != want; i++)
		usleep(10000);
	_exit(got == want ? 0 : 1);
}

static int status(pid_t c) {
	int st;
	if (waitpid(c, &st, 0) != c || !WIFEXITED(st))
		return -1;
	return WEXITSTATUS(st);
}

static void winch(void) {
	int m, s, pp[2];
	char name[64], b;
	CHECK("winch", pair(&m, &s, name, sizeof name) == 0 && pipe(pp) == 0);
	pid_t c = terminal_child(m, name, pp[1], SIGWINCH);
	CHECK("winch", read(pp[0], &b, 1) == 1);
	struct winsize ws = {.ws_row = 40, .ws_col = 132};
	CHECK("winch", ioctl(m, TIOCSWINSZ, &ws) == 0);
	struct winsize back;
	CHECK("winch", ioctl(s, TIOCGWINSZ, &back) == 0 && back.ws_row == 40 && back.ws_col == 132);
	int r = status(c);
	CHECK("winch", r == 0);
	close(s);
	close(m);
	printf("ok winch\n");
}

/* Reads what's there within 200 ms, up to n bytes. */
static int drain(int fd, char *buf, int n) {
	int got = 0;
	struct pollfd pf = {.fd = fd, .events = POLLIN};
	while (got < n && poll(&pf, 1, 200) == 1 && (pf.revents & POLLIN)) {
		int r = read(fd, buf + got, n - got);
		if (r <= 0)
			break;
		got += r;
	}
	return got;
}

static void canon(void) {
	int m, s;
	char name[64], buf[64];
	CHECK("canon", cooked(&m, &s, name, sizeof name) == 0);
	/* DEL erases the b; the slave reads the line at the newline, ICRNL makes CR one. */
	CHECK("canon", write(m, "ab\x7f" "c\r", 5) == 5);
	int n = read(s, buf, sizeof buf);
	CHECK("canon", n == 3 && memcmp(buf, "ac\n", 3) == 0);
	/* Echo, with ECHOE's erase and ONLCR's CR LF. */
	n = drain(m, buf, sizeof buf);
	CHECK("canon", n == 8 && memcmp(buf, "ab\b \bc\r\n", 8) == 0);
	/* A read returns one line, and the next one is still there. */
	CHECK("canon", write(m, "one\ntwo\n", 8) == 8);
	CHECK("canon", read(s, buf, sizeof buf) == 4 && read(s, buf, sizeof buf) == 4 && memcmp(buf, "two\n", 4) == 0);
	drain(m, buf, sizeof buf);
	/* Ctrl-U kills the line; Ctrl-W erases a word. */
	CHECK("canon", write(m, "junk\x15keep this\x17that\n", 20) == 20);
	n = read(s, buf, sizeof buf);
	CHECK("canon", n == 10 && memcmp(buf, "keep that\n", 10) == 0);
	drain(m, buf, sizeof buf);
	/* VEOF ends a line without a newline, and on an empty line it's an end of file. */
	CHECK("canon", write(m, "x\x04", 2) == 2 && read(s, buf, sizeof buf) == 1 && buf[0] == 'x');
	CHECK("canon", write(m, "\x04", 1) == 1 && read(s, buf, sizeof buf) == 0);
	drain(m, buf, sizeof buf);
	/* The slave's newlines reach the master as CR LF. */
	CHECK("canon", write(s, "hi\n", 3) == 3 && drain(m, buf, sizeof buf) == 4 && memcmp(buf, "hi\r\n", 4) == 0);
	/* Without ECHO nothing comes back; without ICANON a byte is readable at once. */
	struct termios t;
	CHECK("canon", tcgetattr(s, &t) == 0);
	t.c_lflag &= ~(ECHO | ICANON);
	t.c_cc[VMIN] = 1;
	CHECK("canon", tcsetattr(s, TCSANOW, &t) == 0);
	CHECK("canon", write(m, "q", 1) == 1 && read(s, buf, sizeof buf) == 1 && buf[0] == 'q');
	CHECK("canon", drain(m, buf, sizeof buf) == 0);
	/* VMIN 0 and VTIME 0: a read with nothing there returns 0 at once. */
	t.c_cc[VMIN] = 0;
	t.c_cc[VTIME] = 0;
	CHECK("canon", tcsetattr(s, TCSANOW, &t) == 0 && read(s, buf, sizeof buf) == 0);
	close(s);
	close(m);
	printf("ok canon\n");
}

static void intr(void) {
	int m, s, pp[2];
	char name[64], b, buf[16];
	CHECK("intr", cooked(&m, &s, name, sizeof name) == 0 && pipe(pp) == 0);
	pid_t c = terminal_child(m, name, pp[1], SIGINT);
	CHECK("intr", read(pp[0], &b, 1) == 1);
	/* A line being typed goes with the interrupt. */
	CHECK("intr", write(m, "half", 4) == 4 && write(m, "\x03", 1) == 1);
	int r = status(c);
	CHECK("intr", r == 0);
	/* Echoed as ^C. */
	int n = drain(m, buf, sizeof buf);
	CHECK("intr", n == 6 && memcmp(buf, "half^C", 6) == 0);
	int q = -1;
	CHECK("intr", ioctl(s, FIONREAD, &q) == 0 && q == 0);
	close(s);
	close(m);
	printf("ok intr\n");
}

static void hangup(void) {
	int m, s, pp[2];
	char name[64], b;
	CHECK("hangup", pair(&m, &s, name, sizeof name) == 0 && pipe(pp) == 0);
	pid_t c = terminal_child(m, name, pp[1], SIGHUP);
	CHECK("hangup", read(pp[0], &b, 1) == 1);
	close(m);
	int r = status(c);
	CHECK("hangup", r == 0);
	/* The slave reads an end of file, and its writes fail. */
	char buf[4];
	CHECK("hangup", read(s, buf, sizeof buf) == 0);
	errno = 0;
	CHECK("hangup", write(s, "x", 1) < 0 && errno == EIO);
	close(s);
	printf("ok hangup\n");
}

int main(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "openpt") == 0) openpt();
		else if (strcmp(argv[i], "eof") == 0) eof();
		else if (strcmp(argv[i], "raw") == 0) raw();
		else if (strcmp(argv[i], "locked") == 0) locked();
		else if (strcmp(argv[i], "nonblock") == 0) nonblock();
		else if (strcmp(argv[i], "winch") == 0) winch();
		else if (strcmp(argv[i], "hangup") == 0) hangup();
		else if (strcmp(argv[i], "canon") == 0) canon();
		else if (strcmp(argv[i], "intr") == 0) intr();
		else { printf("FAIL %s: no such case\n", argv[i]); failed = 1; }
	}
	return failed;
}
