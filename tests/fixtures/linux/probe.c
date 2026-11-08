/* Files, directories, pipes, fork, vfork and exec, signals, mmap and the
 * clock, for the [linux-personality] integration cases. Prints "FAIL" for
 * anything that goes wrong. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <time.h>

static volatile int got;
static void h(int s) { got = s; }

#define CHECK(x) do { if (!(x)) { printf("FAIL %s:%d %s errno=%d %s\n", __FILE__, __LINE__, #x, errno, strerror(errno)); } else printf("ok %s\n", #x); } while (0)

int main(int argc, char **argv) {
	if (argc > 1 && strcmp(argv[1], "child") == 0) { printf("in exec child\n"); return 5; }
	char buf[256];
	CHECK(getcwd(buf, sizeof buf) != NULL); printf("cwd %s\n", buf);
	int fd = open("/tmp/lxprobe", O_CREAT|O_TRUNC|O_RDWR, 0644);
	CHECK(fd >= 0);
	CHECK(write(fd, "hello\n", 6) == 6);
	CHECK(lseek(fd, 0, SEEK_SET) == 0);
	CHECK(read(fd, buf, 6) == 6 && memcmp(buf, "hello\n", 6) == 0);
	struct stat st;
	CHECK(fstat(fd, &st) == 0 && st.st_size == 6 && S_ISREG(st.st_mode));
	close(fd);
	CHECK(stat("/tmp", &st) == 0 && S_ISDIR(st.st_mode));
	CHECK(open("/nonexistent", O_RDONLY) < 0 && errno == ENOENT);
	CHECK(mkdir("/tmp/lxdir", 0755) == 0 || errno == EEXIST);
	CHECK(rename("/tmp/lxprobe", "/tmp/lxprobe2") == 0);
	CHECK(unlink("/tmp/lxprobe2") == 0);
	DIR *d = opendir("/"); CHECK(d != NULL);
	int n = 0; struct dirent *e; while (d && (e = readdir(d))) n++;
	printf("root entries %d\n", n); if (d) closedir(d);
	CHECK(rmdir("/tmp/lxdir") == 0);
	CHECK(mkdir("/dev/shm/lxdir", 0700) == 0 && rmdir("/dev/shm/lxdir") == 0);
	/* pipes and fork */
	int p[2]; CHECK(pipe(p) == 0);
	pid_t c = fork();
	/* an empty write is no end of file to the reader */
	if (c == 0) { close(p[0]); write(p[1], "", 0); write(p[1], "child", 5); _exit(7); }
	close(p[1]);
	int k = read(p[0], buf, sizeof buf); buf[k > 0 ? k : 0] = 0;
	CHECK(strcmp(buf, "child") == 0);
	int status; CHECK(waitpid(c, &status, 0) == c && WIFEXITED(status) && WEXITSTATUS(status) == 7);
	/* vfork + exec */
	c = vfork();
	if (c == 0) { execl(argv[0], argv[0], "child", (char*)0); _exit(99); }
	CHECK(waitpid(c, &status, 0) == c); printf("exec child status %d\n", WEXITSTATUS(status));
	/* signals */
	signal(SIGUSR1, h);
	kill(getpid(), SIGUSR1);
	for (int i = 0; i < 100 && !got; i++) usleep(1000);
	CHECK(got == SIGUSR1);
	c = fork();
	if (c == 0) { pause(); _exit(0); }
	usleep(10000);
	kill(c, SIGTERM);
	CHECK(waitpid(c, &status, 0) == c && WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM);
	/* mmap */
	char *m = mmap(0, 1<<20, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	CHECK(m != MAP_FAILED); m[12345] = 1; CHECK(munmap(m, 1<<20) == 0);
	struct timespec ts; CHECK(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
	printf("pid %d ppid %d\n", getpid(), getppid());
	return 0;
}
