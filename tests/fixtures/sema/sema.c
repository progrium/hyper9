/*
 * Test programs for the semaphores cases in tests/integration.zig
 * (design/semaphores.md), one per argument. Built inside the guest
 * with 7c and 7l. Semaphores and counters are in the data segment, which
 * rfork(RFPROC|RFMEM) children share.
 */
#include <u.h>
#include <libc.h>

enum
{
	Nproc	= 4,
	Iter	= 500,
};

long	sem;
long	counter;
QLock	lk;
int	handled;
char	notes[256];
int	parent;		/* the pid poster posts to */

/* Milliseconds on the fast clock, from /dev/time's fastticks and fasthz. */
vlong
msec(void)
{
	char buf[128], *f[5];
	int fd, n;
	vlong ticks, hz;

	fd = open("/dev/time", OREAD);
	if(fd < 0)
		sysfatal("open /dev/time: %r");
	n = pread(fd, buf, sizeof buf - 1, 0);
	close(fd);
	if(n <= 0)
		sysfatal("read /dev/time: %r");
	buf[n] = 0;
	if(tokenize(buf, f, nelem(f)) < 4)
		sysfatal("bad /dev/time");
	ticks = strtoll(f[2], nil, 10);
	hz = strtoll(f[3], nil, 10);
	if(hz <= 0)
		sysfatal("bad fasthz");
	return ticks*1000/hz;
}

void
waitall(int n)
{
	while(n-- > 0)
		free(wait());
}

/* Runs f(i) in an rfork(RFPROC|RFMEM) child. */
void
spawn(void (*f)(int), int i)
{
	switch(rfork(RFPROC|RFMEM)){
	case -1:
		sysfatal("rfork: %r");
	case 0:
		f(i);
		exits(nil);
	}
}

void
swap(void)
{
	uintptr v;

	switch(rfork(RFPROC)){
	case -1:
		sysfatal("rfork: %r");
	case 0:
		v = (uintptr)rendezvous((void*)0x1234, (void*)22);
		print("child got %llud\n", (uvlong)v);
		exits(nil);
	}
	v = (uintptr)rendezvous((void*)0x1234, (void*)11);
	waitall(1);
	print("parent got %llud\n", (uvlong)v);
}

/* Yields while holding the lock now and then, so the others contend. */
void
qlocker(int)
{
	int i;
	long c;

	for(i = 0; i < Iter; i++){
		qlock(&lk);
		c = counter;
		if(i % 10 == 0)
			sleep(0);
		counter = c + 1;
		qunlock(&lk);
	}
}

void
qlocks(void)
{
	int i;

	for(i = 0; i < Nproc; i++)
		spawn(qlocker, i);
	waitall(Nproc);
	print("%ld\n", counter);
}

void
releaser(int ms)
{
	sleep(ms);
	semrelease(&sem, 1);
}

void
semwait(void)
{
	vlong t;
	int r;

	spawn(releaser, 100);
	t = msec();
	r = semacquire(&sem, 1);
	t = msec() - t;
	waitall(1);
	print("semacquire %d %s\n", r, t >= 50 ? "waited" : "didn't wait");
}

/* A semaphore as a lock. */
void
semlocker(int)
{
	int i;
	long c;

	for(i = 0; i < Iter; i++){
		if(semacquire(&sem, 1) != 1)
			sysfatal("semacquire: %r");
		c = counter;
		if(i % 10 == 0)
			sleep(0);
		counter = c + 1;
		semrelease(&sem, 1);
	}
}

void
semcount(void)
{
	int i;

	sem = 1;
	for(i = 0; i < Nproc; i++)
		spawn(semlocker, i);
	waitall(Nproc);
	print("%ld %ld\n", counter, sem);
}

void
nowait(void)
{
	vlong t;

	t = msec();
	print("%d", semacquire(&sem, 0));
	print(" %d", tsemacquire(&sem, 0));
	sem = 1;
	print(" %d", semacquire(&sem, 0));
	sem = 1;
	print(" %d", tsemacquire(&sem, 0));
	t = msec() - t;
	print(" %ld %s\n", sem, t < 50 ? "at once" : "waited");
}

void
timeout(void)
{
	vlong t;
	int r;

	t = msec();
	r = tsemacquire(&sem, 100);
	t = msec() - t;
	print("timeout %d %s\n", r, t >= 100 && t < 1000 ? "in time" : "out of time");
	spawn(releaser, 50);
	t = msec();
	r = tsemacquire(&sem, 1000);
	t = msec() - t;
	waitall(1);
	print("release %d %s\n", r, t < 1000 ? "early" : "late");
}

void
catch(void*, char *msg)
{
	char *p;

	handled++;
	/* "sys:" notes posted to the process carry a pc. */
	if((p = strstr(msg, " pc=")) != nil)
		*p = 0;
	if(strlen(notes) + strlen(msg) + 2 < sizeof notes){
		strcat(notes, msg);
		strcat(notes, ";");
	}
	noted(NCONT);
}

/* Posts a note to parent after ms. */
void
poster(int ms)
{
	sleep(ms);
	if(postnote(PNPROC, parent, "alarm") < 0)
		sysfatal("postnote: %r");
}

void
interrupt(void)
{
	uintptr v;
	int r;

	notify(catch);
	parent = getpid();
	switch(rfork(RFPROC|RFMEM)){
	case -1:
		sysfatal("rfork: %r");
	case 0:
		poster(100);
		exits(nil);
	}
	v = (uintptr)rendezvous((void*)0x5678, nil);
	waitall(1);
	print("rendezvous %s, handled %d\n", v == ~(uintptr)0 ? "~0" : "other", handled);
	switch(rfork(RFPROC|RFMEM)){
	case -1:
		sysfatal("rfork: %r");
	case 0:
		poster(100);
		exits(nil);
	}
	r = semacquire(&sem, 1);
	print("semacquire %d '%r', handled %d\n", r, handled);
	waitall(1);
}

void
badaddr(void)
{
	notify(catch);
	print("odd %d '%r'\n", semacquire((long*)((uchar*)&sem + 2), 0));
	print("text %d '%r'\n", semacquire((long*)msec, 0));
	sem = -1;
	print("negative %d '%r'\n", semacquire(&sem, 0));
	print("negative %d '%r'\n", tsemacquire(&sem, 0));
	print("negative %ld '%r'\n", semrelease(&sem, 1));
	sem = 0;
	print("count %ld '%r'\n", semrelease(&sem, -1));
	print("unmapped %d '%r'\n", semacquire((long*)8, 0));
	print("notes %s\n", notes);
}

/* Children blocked in rendezvous and semacquire, until killed. */
void
blocker(int i)
{
	if(i == 0)
		rendezvous((void*)0x9999, nil);
	else
		semacquire(&sem, 1);
}

void
block(void)
{
	spawn(blocker, 0);
	spawn(blocker, 1);
	waitall(2);
}

void
main(int argc, char **argv)
{
	if(argc != 2)
		sysfatal("usage: sema test");
	if(strcmp(argv[1], "swap") == 0)
		swap();
	else if(strcmp(argv[1], "qlock") == 0)
		qlocks();
	else if(strcmp(argv[1], "wait") == 0)
		semwait();
	else if(strcmp(argv[1], "count") == 0)
		semcount();
	else if(strcmp(argv[1], "nowait") == 0)
		nowait();
	else if(strcmp(argv[1], "timeout") == 0)
		timeout();
	else if(strcmp(argv[1], "interrupt") == 0)
		interrupt();
	else if(strcmp(argv[1], "badaddr") == 0)
		badaddr();
	else if(strcmp(argv[1], "block") == 0)
		block();
	else
		sysfatal("unknown test %s", argv[1]);
	exits(nil);
}
