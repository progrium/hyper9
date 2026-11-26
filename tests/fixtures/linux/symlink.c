/* Linux symlinks (design/epoch-0/linux-symlinks.md), and hard links and
 * renames (design/file-interface.md): each case named on the command
 * line prints "ok NAME" or "FAIL NAME: why". The links are made in $DIR,
 * or /tmp. "all" runs the symlink cases. */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failed;

#define CHECK(name, cond) do { if (!(cond)) { printf("FAIL %s: %s (errno %d %s)\n", name, #cond, errno, strerror(errno)); failed = 1; return; } } while (0)

static char path[4][256];

/* A fresh name in $DIR, in slot i. */
static const char *fresh(int i, const char *name) {
	const char *d = getenv("DIR");
	snprintf(path[i], sizeof path[i], "%s/%s", d ? d : "/tmp", name);
	unlink(path[i]);
	return path[i];
}

static const char *dir(void) {
	const char *d = getenv("DIR");
	return d ? d : "/tmp";
}

/* d_type of name in $DIR, or -1. */
static int dtype(const char *name) {
	DIR *dp = opendir(dir());
	struct dirent *de;
	int t = -1;
	if (dp == NULL)
		return -1;
	while ((de = readdir(dp)) != NULL)
		if (strcmp(de->d_name, name) == 0)
			t = de->d_type;
	closedir(dp);
	return t;
}

/* lstat, fstatat with AT_SYMLINK_NOFOLLOW, readlink, getdents, and
 * O_NOFOLLOW act on a link, a dangling one too; stat and open follow it. */
static void nofollow(void) {
	const char *f = fresh(0, "sl.f"), *l = fresh(1, "sl.l"), *d = fresh(2, "sl.d");
	struct stat st;
	char buf[64];
	int fd;
	ssize_t n;

	fd = open(f, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	CHECK("nofollow", fd >= 0);
	CHECK("nofollow", write(fd, "hello", 5) == 5);
	close(fd);
	CHECK("nofollow", symlink("sl.f", l) == 0);
	CHECK("nofollow", symlink("sl.nowhere", d) == 0);
	CHECK("nofollow", lstat(l, &st) == 0 && S_ISLNK(st.st_mode) && st.st_size == 4);
	CHECK("nofollow", fstatat(AT_FDCWD, l, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(st.st_mode));
	CHECK("nofollow", stat(l, &st) == 0 && S_ISREG(st.st_mode) && st.st_size == 5);
	n = readlink(l, buf, sizeof buf);
	CHECK("nofollow", n == 4 && memcmp(buf, "sl.f", 4) == 0);
	CHECK("nofollow", lstat(d, &st) == 0 && S_ISLNK(st.st_mode));
	errno = 0;
	CHECK("nofollow", stat(d, &st) < 0 && errno == ENOENT);
	CHECK("nofollow", dtype("sl.l") == DT_LNK && dtype("sl.d") == DT_LNK && dtype("sl.f") == DT_REG);
	errno = 0;
	CHECK("nofollow", open(l, O_RDONLY | O_NOFOLLOW) < 0 && errno == ELOOP);
	fd = open(l, O_RDONLY);
	CHECK("nofollow", fd >= 0);
	n = read(fd, buf, sizeof buf);
	close(fd);
	CHECK("nofollow", n == 5 && memcmp(buf, "hello", 5) == 0);
	/* rename and unlink act on the link, not its target. */
	CHECK("nofollow", rename(d, fresh(3, "sl.d2")) == 0);
	CHECK("nofollow", lstat(path[3], &st) == 0 && S_ISLNK(st.st_mode));
	CHECK("nofollow", unlink(l) == 0 && unlink(path[3]) == 0);
	CHECK("nofollow", stat(f, &st) == 0 && st.st_size == 5);
	unlink(f);
	printf("ok nofollow\n");
}

/* A loop of links is ELOOP. */
static void loop(void) {
	const char *a = fresh(0, "sl.a"), *b = fresh(1, "sl.b");
	struct stat st;

	CHECK("loop", symlink("sl.b", a) == 0 && symlink("sl.a", b) == 0);
	errno = 0;
	CHECK("loop", open(a, O_RDONLY) < 0 && errno == ELOOP);
	errno = 0;
	CHECK("loop", stat(a, &st) < 0 && errno == ELOOP);
	CHECK("loop", lstat(a, &st) == 0 && S_ISLNK(st.st_mode));
	unlink(a);
	unlink(b);
	printf("ok loop\n");
}

/* /proc/self/fd/N of a file removed since it was opened still opens. */
static void deleted(void) {
	const char *f = fresh(0, "sl.gone");
	char p[64], buf[16];
	int fd, fd2;
	ssize_t n;

	fd = open(f, O_RDWR | O_CREAT | O_TRUNC, 0644);
	CHECK("deleted", fd >= 0);
	CHECK("deleted", write(fd, "still", 5) == 5);
	CHECK("deleted", unlink(f) == 0);
	snprintf(p, sizeof p, "/proc/self/fd/%d", fd);
	fd2 = open(p, O_RDONLY);
	CHECK("deleted", fd2 >= 0);
	n = pread(fd2, buf, sizeof buf, 0);
	CHECK("deleted", n == 5 && memcmp(buf, "still", 5) == 0);
	close(fd2);
	close(fd);
	printf("ok deleted\n");
}

/* Writes s to p, replacing it. */
static int put(const char *p, const char *s) {
	int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	int ok;
	if (fd < 0)
		return -1;
	ok = write(fd, s, strlen(s)) == (ssize_t)strlen(s);
	close(fd);
	return ok ? 0 : -1;
}

/* Whether p holds exactly s. */
static int holds(const char *p, const char *s) {
	char buf[64];
	int fd = open(p, O_RDONLY);
	ssize_t n;
	if (fd < 0)
		return 0;
	n = read(fd, buf, sizeof buf);
	close(fd);
	return n == (ssize_t)strlen(s) && memcmp(buf, s, n) == 0;
}

/* link makes a second name for the file, not a copy: one inode with a
 * link count of two, and a write through either name shows through the
 * other (design/file-interface.md). */
static void hardlink(void) {
	const char *a = fresh(0, "hl.a"), *b = fresh(1, "hl.b");
	struct stat sa, sb;
	int fd;

	CHECK("hardlink", put(a, "one") == 0);
	CHECK("hardlink", link(a, b) == 0);
	CHECK("hardlink", stat(a, &sa) == 0 && stat(b, &sb) == 0);
	CHECK("hardlink", sa.st_ino == sb.st_ino && sa.st_nlink == 2 && sb.st_nlink == 2);
	fd = open(b, O_WRONLY | O_APPEND);
	CHECK("hardlink", fd >= 0 && write(fd, "two", 3) == 3);
	close(fd);
	CHECK("hardlink", holds(a, "onetwo"));
	errno = 0;
	CHECK("hardlink", link(a, b) < 0 && errno == EEXIST);
	CHECK("hardlink", unlink(a) == 0);
	CHECK("hardlink", stat(b, &sb) == 0 && sb.st_nlink == 1 && holds(b, "onetwo"));
	unlink(b);
	printf("ok hardlink\n");
}

/* rename across directories moves the file itself and replaces what the
 * new name was in one step: the same inode at the new name, and an fd
 * open on the replaced file still reads it. A directory moves whole
 * (design/file-interface.md). */
static void renamedir(void) {
	char da[256], db[256], a[300], b[300], y[300], d[300], dy[320];
	struct stat sa, st;
	char buf[8];
	int fd;

	snprintf(da, sizeof da, "%s/rn.a", dir());
	snprintf(db, sizeof db, "%s/rn.b", dir());
	snprintf(a, sizeof a, "%s/x", da);
	snprintf(b, sizeof b, "%s/x", db);
	snprintf(y, sizeof y, "%s/y", da);
	snprintf(d, sizeof d, "%s/d", db);
	snprintf(dy, sizeof dy, "%s/y", d);
	unlink(a);
	unlink(b);
	unlink(y);
	unlink(dy);
	rmdir(d);
	rmdir(da);
	rmdir(db);
	CHECK("renamedir", mkdir(da, 0755) == 0 && mkdir(db, 0755) == 0);
	CHECK("renamedir", put(a, "new") == 0 && put(b, "old") == 0 && put(y, "y") == 0);
	CHECK("renamedir", stat(a, &sa) == 0);
	fd = open(b, O_RDONLY);
	CHECK("renamedir", fd >= 0);
	CHECK("renamedir", rename(a, b) == 0);
	errno = 0;
	CHECK("renamedir", stat(a, &st) < 0 && errno == ENOENT);
	CHECK("renamedir", stat(b, &st) == 0 && st.st_ino == sa.st_ino && holds(b, "new"));
	CHECK("renamedir", pread(fd, buf, sizeof buf, 0) == 3 && memcmp(buf, "old", 3) == 0);
	close(fd);
	CHECK("renamedir", rename(da, d) == 0 && holds(dy, "y"));
	errno = 0;
	CHECK("renamedir", stat(da, &st) < 0 && errno == ENOENT);
	unlink(dy);
	unlink(b);
	rmdir(d);
	rmdir(db);
	printf("ok renamedir\n");
}

int main(int argc, char **argv) {
	setvbuf(stdout, 0, _IONBF, 0);
	for (int i = 1; i < argc; i++) {
		const char *n = argv[i];
		int all = strcmp(n, "all") == 0;
		if (all || !strcmp(n, "nofollow")) nofollow();
		if (all || !strcmp(n, "loop")) loop();
		if (all || !strcmp(n, "deleted")) deleted();
		if (!strcmp(n, "hardlink")) hardlink();
		if (!strcmp(n, "renamedir")) renamedir();
	}
	return failed;
}
