/* chroot (design/linux-chroot.md): each case named on the command line
 * prints "ok NAME" or "FAIL NAME: why". Each case runs in a child, which
 * chroots, so the next one starts from the Linux view's top. The trees
 * are made in $DIR, or /tmp. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#define CHECK(name, cond) do { if (!(cond)) { printf("FAIL %s: %s (errno %d %s)\n", name, #cond, errno, strerror(errno)); fflush(stdout); _exit(1); } } while (0)

static char top[256];	/* the case's tree, by its name from the Linux view's top */
static char root[256];	/* top/r, the directory the case chroots to */

static void put(const char *path, const char *data) {
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
	if (fd >= 0) {
		if (write(fd, data, strlen(data)) < 0) {}
		close(fd);
	}
}

/* Whether path reads as want. */
static int reads(const char *path, const char *want) {
	char buf[64];
	int fd = open(path, O_RDONLY);
	ssize_t n;
	if (fd < 0)
		return 0;
	n = read(fd, buf, sizeof buf - 1);
	close(fd);
	if (n < 0)
		return 0;
	buf[n] = 0;
	return strcmp(buf, want) == 0;
}

static int cwdis(const char *want) {
	char buf[256];
	return getcwd(buf, sizeof buf) != NULL && strcmp(buf, want) == 0;
}

/* $DIR/cr.NAME with r/f ("in"), r/sub, r/l -> /f, and f ("out") beside r. */
static void tree(const char *name) {
	const char *d = getenv("DIR");
	char p[300];
	snprintf(top, sizeof top, "%s/cr.%s", d ? d : "/tmp", name);
	snprintf(root, sizeof root, "%s/r", top);
	mkdir(top, 0755);
	mkdir(root, 0755);
	snprintf(p, sizeof p, "%s/sub", root);
	mkdir(p, 0755);
	snprintf(p, sizeof p, "%s/f", root);
	put(p, "in");
	snprintf(p, sizeof p, "%s/f", top);
	put(p, "out");
	snprintf(p, sizeof p, "%s/l", root);
	unlink(p);
	symlink("/f", p);
}

/* Absolute paths start at the new root; what's outside it isn't there. */
static void narrow(void) {
	char out[300];
	snprintf(out, sizeof out, "%s/f", top);
	CHECK("narrow", reads(out, "out"));
	CHECK("narrow", chroot(root) == 0);
	CHECK("narrow", reads("/f", "in"));
	CHECK("narrow", access("/sub", F_OK) == 0);
	CHECK("narrow", access(out, F_OK) < 0 && errno == ENOENT);
	CHECK("narrow", access("/etc/os-release", F_OK) < 0 && errno == ENOENT);
}

/* .. at the new root is the root, in a path, a chdir, and getcwd. */
static void dotdot(void) {
	CHECK("dotdot", chroot(root) == 0);
	CHECK("dotdot", chdir("/") == 0);
	CHECK("dotdot", reads("/../../f", "in"));
	CHECK("dotdot", reads("/sub/../../f", "in"));
	CHECK("dotdot", chdir("..") == 0 && chdir("../..") == 0);
	CHECK("dotdot", cwdis("/"));
	CHECK("dotdot", reads("f", "in"));
	CHECK("dotdot", chdir("sub/../../sub") == 0 && cwdis("/sub"));
}

/* An absolute link's target is walked from the new root. */
static void link_(void) {
	char buf[16];
	CHECK("link", chroot(root) == 0);
	CHECK("link", readlink("/l", buf, sizeof buf) == 2 && memcmp(buf, "/f", 2) == 0);
	CHECK("link", reads("/l", "in"));
}

/* The working directory stays; under the new root, it's named from there. */
static void cwd(void) {
	char p[300];
	snprintf(p, sizeof p, "%s/sub", root);
	CHECK("cwd", chdir(p) == 0);
	CHECK("cwd", chroot(root) == 0);
	CHECK("cwd", cwdis("/sub"));
	CHECK("cwd", reads("../f", "in"));
	CHECK("cwd", chdir("..") == 0 && cwdis("/"));
	/* chroot(".") from inside it, as apk does after fchdir. */
	CHECK("cwd", chdir("/sub") == 0 && chroot(".") == 0);
	CHECK("cwd", cwdis("/"));
	CHECK("cwd", access("/f", F_OK) < 0 && errno == ENOENT);
}

/* A working directory left outside the new root still works by relative paths. */
static void outside(void) {
	CHECK("outside", chdir(top) == 0);
	CHECK("outside", chroot(root) == 0);
	CHECK("outside", reads("f", "out"));
	CHECK("outside", reads("r/f", "in"));
	CHECK("outside", reads("/f", "in"));
}

/* Forked children keep the chroot. */
static void fork_(void) {
	pid_t pid;
	int st;
	CHECK("fork", chroot(root) == 0);
	pid = fork();
	CHECK("fork", pid >= 0);
	if (pid == 0)
		_exit(reads("/f", "in") && access("/etc/os-release", F_OK) < 0 ? 0 : 1);
	CHECK("fork", waitpid(pid, &st, 0) == pid);
	CHECK("fork", WIFEXITED(st) && WEXITSTATUS(st) == 0);
}

/* exec keeps the chroot, and runs a program found in it. */
static void exec_(const char *self) {
	char p[300], buf[4096];
	int in, out;
	ssize_t n;
	snprintf(p, sizeof p, "%s/me", root);
	in = open(self, O_RDONLY);
	CHECK("exec", in >= 0);
	out = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0755);
	CHECK("exec", out >= 0);
	while ((n = read(in, buf, sizeof buf)) > 0)
		CHECK("exec", write(out, buf, n) == n);
	close(in);
	close(out);
	CHECK("exec", chroot(root) == 0);
	CHECK("exec", chdir("/") == 0);
	execl("/me", "me", "inside", (char *)NULL);
	CHECK("exec", 0);
}

static void inside(void) {
	CHECK("exec", reads("/f", "in"));
	CHECK("exec", access("/etc/os-release", F_OK) < 0 && errno == ENOENT);
	CHECK("exec", cwdis("/"));
}

/* An fd opened before a chroot leads back out of it, as Linux's does:
 * the way out ends at the Linux view's top, the guest's own root. */
static void escape(void) {
	char out[300];
	int fd = open("/", O_RDONLY | O_DIRECTORY);
	CHECK("escape", fd >= 0);
	snprintf(out, sizeof out, "%s/f", top);
	CHECK("escape", chroot(root) == 0 && chdir("/") == 0);
	CHECK("escape", access(out, F_OK) < 0);
	CHECK("escape", fchdir(fd) == 0);
	CHECK("escape", chroot(".") == 0);
	CHECK("escape", reads(out, "out"));
	CHECK("escape", access("/etc/os-release", F_OK) == 0);
	CHECK("escape", access("/../../etc/os-release", F_OK) == 0);
}

/* chroot to the Linux view's top changes nothing. */
static void top_(void) {
	char out[300];
	snprintf(out, sizeof out, "%s/f", top);
	CHECK("top", chroot("/") == 0);
	CHECK("top", reads(out, "out"));
	CHECK("top", chdir("/") == 0 && chroot(".") == 0);
	CHECK("top", reads(out, "out"));
	CHECK("top", access("/proc/self/stat", F_OK) == 0);
}

/* What isn't a directory is refused as Linux refuses it. */
static void errors(void) {
	char p[300];
	snprintf(p, sizeof p, "%s/f", root);
	CHECK("errors", chroot(p) < 0 && errno == ENOTDIR);
	snprintf(p, sizeof p, "%s/none", root);
	CHECK("errors", chroot(p) < 0 && errno == ENOENT);
	CHECK("errors", chroot("") < 0 && errno == ENOENT);
}

/* mount, umount2, pivot_root and new namespaces stay refused. */
static void refused(void) {
	CHECK("refused", mount("none", root, "tmpfs", 0, NULL) < 0 && errno == EPERM);
	CHECK("refused", umount2(root, 0) < 0 && errno == EPERM);
	CHECK("refused", syscall(SYS_pivot_root, root, root) < 0 && errno == EPERM);
	CHECK("refused", unshare(CLONE_NEWNS) < 0 && errno == EPERM);
}

/* A socket, which h9 opens from the 9front view, leaves the chroot as it was. */
static void socket_(void) {
	int s;
	CHECK("socket", chroot(root) == 0);
	s = socket(AF_INET, SOCK_STREAM, 0);
	if (s >= 0)
		close(s);
	CHECK("socket", reads("/f", "in"));
	CHECK("socket", access("/etc/os-release", F_OK) < 0 && errno == ENOENT);
}

static void run(const char *name, const char *self) {
	tree(name);
	if (strcmp(name, "narrow") == 0) narrow();
	else if (strcmp(name, "dotdot") == 0) dotdot();
	else if (strcmp(name, "link") == 0) link_();
	else if (strcmp(name, "cwd") == 0) cwd();
	else if (strcmp(name, "outside") == 0) outside();
	else if (strcmp(name, "fork") == 0) fork_();
	else if (strcmp(name, "exec") == 0) exec_(self);
	else if (strcmp(name, "escape") == 0) escape();
	else if (strcmp(name, "top") == 0) top_();
	else if (strcmp(name, "errors") == 0) errors();
	else if (strcmp(name, "refused") == 0) refused();
	else if (strcmp(name, "socket") == 0) socket_();
	else {
		printf("FAIL %s: no such case\n", name);
		fflush(stdout);
		_exit(1);
	}
}

int main(int argc, char **argv) {
	char self[256];
	int i, st, failed = 0;
	ssize_t n;
	pid_t pid;

	if (argc == 2 && strcmp(argv[1], "inside") == 0) {
		inside();
		printf("ok exec\n");
		return 0;
	}
	n = readlink("/proc/self/exe", self, sizeof self - 1);
	self[n > 0 ? n : 0] = 0;
	for (i = 1; i < argc; i++) {
		fflush(stdout);
		pid = fork();
		if (pid < 0) {
			printf("FAIL %s: fork (errno %d)\n", argv[i], errno);
			return 1;
		}
		if (pid == 0) {
			run(argv[i], self);
			printf("ok %s\n", argv[i]);
			fflush(stdout);
			_exit(0);
		}
		if (waitpid(pid, &st, 0) != pid || !WIFEXITED(st) || WEXITSTATUS(st) != 0)
			failed = 1;
	}
	return failed;
}
