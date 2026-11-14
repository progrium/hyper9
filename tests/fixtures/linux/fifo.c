/* Named pipes (design/linux-fifo.md): each case named on the command line
 * prints "ok NAME" or "FAIL NAME: why". The FIFOs are made in $DIR, or
 * /tmp. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

static int failed;

#define CHECK(name, cond) do { if (!(cond)) { printf("FAIL %s: %s (errno %d %s)\n", name, #cond, errno, strerror(errno)); failed = 1; return; } } while (0)

static char path[256];

static const char *fresh(const char *name) {
	const char *d = getenv("DIR");
	snprintf(path, sizeof path, "%s/%s", d ? d : "/tmp", name);
	unlink(path);
	return path;
}

static int child_status(pid_t c) {
	int st;
	if (waitpid(c, &st, 0) != c || !WIFEXITED(st))
		return -1;
	return WEXITSTATUS(st);
}

/* mkfifo makes a FIFO that stat, lstat, fstat, and getdents report, and
 * that unlink removes. */
static void make(void) {
	const char *p = fresh("f.make");
	struct stat st;
	CHECK("make", mkfifo(p, 0640) == 0);
	CHECK("make", mkfifo(p, 0640) < 0 && errno == EEXIST);
	CHECK("make", stat(p, &st) == 0 && S_ISFIFO(st.st_mode) && st.st_size == 0);
	CHECK("make", lstat(p, &st) == 0 && S_ISFIFO(st.st_mode));
	char dir[256];
	snprintf(dir, sizeof dir, "%s", p);
	*strrchr(dir, '/') = 0;
	DIR *d = opendir(dir);
	CHECK("make", d != NULL);
	struct dirent *e;
	int seen = 0;
	while ((e = readdir(d)) != NULL)
		if (strcmp(e->d_name, "f.make") == 0)
			seen = e->d_type == DT_FIFO;
	closedir(d);
	CHECK("make", seen);
	int fd = open(p, O_RDWR);
	CHECK("make", fd >= 0 && fstat(fd, &st) == 0 && S_ISFIFO(st.st_mode));
	close(fd);
	CHECK("make", mknod(p, S_IFCHR | 0600, 0) < 0 && errno == EEXIST);
	CHECK("make", unlink(p) == 0 && stat(p, &st) < 0 && errno == ENOENT);
	CHECK("make", mknod(p, S_IFIFO | 0600, 0) == 0 && stat(p, &st) == 0 && S_ISFIFO(st.st_mode));
	CHECK("make", unlink(p) == 0);
	printf("ok make\n");
}

/* A reader and a writer meet, in either order, and the reader sees EOF
 * once the writer closes. */
static void meet(void) {
	const char *p = fresh("f.meet");
	CHECK("meet", mkfifo(p, 0600) == 0);
	for (int round = 0; round < 2; round++) {
		pid_t c = fork();
		if (c == 0) {
			if (round == 1)
				usleep(100000);
			int fd = open(p, O_WRONLY);
			_exit(fd < 0 || write(fd, "hello", 5) != 5);
		}
		if (round == 0)
			usleep(100000);
		int fd = open(p, O_RDONLY);
		CHECK("meet", fd >= 0);
		char b[16];
		int n = 0, r;
		while ((r = read(fd, b + n, sizeof b - n)) > 0)
			n += r;
		CHECK("meet", r == 0 && n == 5 && memcmp(b, "hello", 5) == 0);
		CHECK("meet", read(fd, b, sizeof b) == 0 && read(fd, b, sizeof b) == 0 && read(fd, b, sizeof b) == 0 && read(fd, b, sizeof b) == 0);
		close(fd);
		CHECK("meet", child_status(c) == 0);
	}
	unlink(p);
	printf("ok meet\n");
}

/* O_NONBLOCK: a write open with no reader is ENXIO, a read open returns
 * at once and reads EOF with no writer, and then a write open finds it. */
static void nonblock(void) {
	const char *p = fresh("f.nonblock");
	CHECK("nonblock", mkfifo(p, 0600) == 0);
	CHECK("nonblock", open(p, O_WRONLY | O_NONBLOCK) < 0 && errno == ENXIO);
	int r = open(p, O_RDONLY | O_NONBLOCK);
	CHECK("nonblock", r >= 0);
	char b[8];
	CHECK("nonblock", read(r, b, sizeof b) == 0);
	int w = open(p, O_WRONLY | O_NONBLOCK);
	CHECK("nonblock", w >= 0);
	CHECK("nonblock", read(r, b, sizeof b) < 0 && errno == EAGAIN);
	CHECK("nonblock", write(w, "x", 1) == 1);
	struct pollfd pf = {.fd = r, .events = POLLIN};
	CHECK("nonblock", poll(&pf, 1, 1000) == 1 && (pf.revents & POLLIN));
	CHECK("nonblock", read(r, b, sizeof b) == 1 && b[0] == 'x');
	close(w);
	CHECK("nonblock", read(r, b, sizeof b) == 0);
	close(r);
	unlink(p);
	printf("ok nonblock\n");
}

/* O_RDWR returns at once and is both ends, so what it writes it reads,
 * and other openers find it. */
static void rdwr(void) {
	const char *p = fresh("f.rdwr");
	CHECK("rdwr", mkfifo(p, 0600) == 0);
	int fd = open(p, O_RDWR);
	CHECK("rdwr", fd >= 0);
	char b[8];
	CHECK("rdwr", write(fd, "ab", 2) == 2 && read(fd, b, sizeof b) == 2 && memcmp(b, "ab", 2) == 0);
	int w = open(p, O_WRONLY);
	CHECK("rdwr", w >= 0 && write(w, "c", 1) == 1);
	close(w);
	int r = open(p, O_RDONLY);
	CHECK("rdwr", r >= 0 && read(r, b, sizeof b) == 1 && b[0] == 'c');
	close(r);
	close(fd);
	unlink(p);
	printf("ok rdwr\n");
}

static void onalarm(int s) { (void)s; }

/* A signal interrupts an open waiting for the other end with EINTR. */
static void intr(void) {
	const char *p = fresh("f.intr");
	CHECK("intr", mkfifo(p, 0600) == 0);
	struct sigaction sa = {.sa_handler = onalarm};
	sigaction(SIGALRM, &sa, NULL);
	struct itimerval it = {.it_value = {.tv_usec = 200000}};
	setitimer(ITIMER_REAL, &it, NULL);
	int fd = open(p, O_RDONLY);
	CHECK("intr", fd < 0 && errno == EINTR);
	setitimer(ITIMER_REAL, &it, NULL);
	fd = open(p, O_WRONLY);
	CHECK("intr", fd < 0 && errno == EINTR);
	/* The interrupted opens are gone: a nonblocking write open finds no reader. */
	CHECK("intr", open(p, O_WRONLY | O_NONBLOCK) < 0 && errno == ENXIO);
	unlink(p);
	printf("ok intr\n");
}

/* Writing once every reader has closed is EPIPE, with SIGPIPE ignored. */
static void epipe(void) {
	const char *p = fresh("f.epipe");
	CHECK("epipe", mkfifo(p, 0600) == 0);
	signal(SIGPIPE, SIG_IGN);
	int r = open(p, O_RDONLY | O_NONBLOCK);
	int w = open(p, O_WRONLY | O_NONBLOCK);
	CHECK("epipe", r >= 0 && w >= 0);
	close(r);
	CHECK("epipe", write(w, "x", 1) < 0 && errno == EPIPE);
	close(w);
	signal(SIGPIPE, SIG_DFL);
	unlink(p);
	printf("ok epipe\n");
}

/* The job token pool stdenv and GNU make keep in a FIFO: one O_RDWR holder
 * fills it, and workers that open it by path take and return tokens. */
static void tokens(void) {
	const char *p = fresh("f.tokens");
	CHECK("tokens", mkfifo(p, 0600) == 0);
	int fd = open(p, O_RDWR);
	CHECK("tokens", fd >= 0 && write(fd, "++++", 4) == 4);
	pid_t kids[8];
	for (int i = 0; i < 8; i++) {
		kids[i] = fork();
		if (kids[i] == 0) {
			int r = open(p, O_RDONLY);
			int w = open(p, O_WRONLY);
			char t;
			if (r < 0 || w < 0 || read(r, &t, 1) != 1)
				_exit(1);
			usleep(10000);
			_exit(write(w, &t, 1) != 1);
		}
	}
	for (int i = 0; i < 8; i++)
		CHECK("tokens", child_status(kids[i]) == 0);
	char b[8];
	CHECK("tokens", read(fd, b, sizeof b) == 4);
	close(fd);
	unlink(p);
	printf("ok tokens\n");
}

int main(int argc, char **argv) {
	setvbuf(stdout, 0, _IONBF, 0);
	for (int i = 1; i < argc; i++) {
		const char *n = argv[i];
		int all = strcmp(n, "all") == 0;
		if (all || !strcmp(n, "make")) make();
		if (all || !strcmp(n, "meet")) meet();
		if (all || !strcmp(n, "nonblock")) nonblock();
		if (all || !strcmp(n, "rdwr")) rdwr();
		if (all || !strcmp(n, "intr")) intr();
		if (all || !strcmp(n, "epipe")) epipe();
		if (all || !strcmp(n, "tokens")) tokens();
	}
	return failed;
}
