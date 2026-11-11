/*
 * A process for the self-host debugging cases (tests/integration.zig,
 * design/self-host.md), built in the guest with the root's
 * compiler. A debugger (dbg.c, or rc writing /proc/n/ctl) changes what
 * it does: answer, two and three are laid out in that order and the same
 * size, so copying two's or three's code over answer's makes answer
 * return 2 or 3. It writes its pid to the file pid first, and in pair
 * mode the child's to child.
 *
 *	target thrice	print answer(), then stop itself, three times
 *	target pair	fork; parent and child each stop, then print answer()
 *	target spin	compute forever, with a syscall every few ms
 *	target hang	set ctl hang, then exec /bin/echo hang
 *	target wait	sleep for a minute
 */
#include <u.h>
#include <libc.h>

long magic = 0x5eedf00d;
long sink;

int
answer(void)
{
	return 1;
}

int
two(void)
{
	return 2;
}

int
three(void)
{
	return 3;
}

/* Writes the number n to a new file. */
void
putpid(char *file, int n)
{
	int fd;

	fd = create(file, OWRITE, 0666);
	if(fd < 0)
		sysfatal("create %s: %r", file);
	fprint(fd, "%d", n);
	close(fd);
}

/* Writes msg to the calling process's /proc/n/ctl. */
void
ctl(char *msg)
{
	char buf[64];
	int fd;

	snprint(buf, sizeof buf, "/proc/%d/ctl", getpid());
	fd = open(buf, OWRITE);
	if(fd < 0 || write(fd, msg, strlen(msg)) != strlen(msg))
		sysfatal("ctl %s: %r", msg);
	close(fd);
}

void
main(int argc, char **argv)
{
	int i, pid;

	if(argc < 2)
		sysfatal("usage");
	putpid("pid", getpid());
	if(strcmp(argv[1], "thrice") == 0){
		for(i = 0; i < 3; i++){
			print("%d\n", answer());
			/* Stops as the write returns. */
			ctl("stop");
		}
	}else if(strcmp(argv[1], "pair") == 0){
		pid = fork();
		if(pid < 0)
			sysfatal("fork: %r");
		if(pid == 0){
			ctl("stop");
			print("child %d\n", answer());
			exits(nil);
		}
		putpid("child", pid);
		ctl("stop");
		print("parent %d\n", answer());
		waitpid();
	}else if(strcmp(argv[1], "spin") == 0){
		for(;;){
			for(i = 0; i < 1000000; i++)
				sink += i;
			sleep(0);
		}
	}else if(strcmp(argv[1], "hang") == 0){
		ctl("hang");
		execl("/bin/echo", "echo", "hang", nil);
		sysfatal("exec: %r");
	}else if(strcmp(argv[1], "wait") == 0)
		sleep(60*1000);
	else
		sysfatal("usage");
	exits(nil);
}
