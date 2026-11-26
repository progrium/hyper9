/*
 * Test programs for the memory-model cases in tests/integration.zig
 * (design/memory-model.md), one per argument. Built inside the guest with
 * the architecture's compiler and loader.
 *
 *	cow	a 48 MB heap, written, shared with three rfork children that
 *		each write their own page of it, run under a --memory that
 *		holds only two copies
 *	rfmem	an rfork(RFMEM) child's writes to data and bss reach the
 *		parent, and a plain rfork grandchild's don't
 *	seg	segattach, segbrk, segfree, and segdetach, printing
 *		/proc/n/segment after each
 */
#include <u.h>
#include <libc.h>

enum
{
	Heap	= 48*1024*1024,
	Nkid	= 3,
	Page	= 4096,
};

long	data = 1;	/* initialized: the data segment */
long	bss;		/* the bss */

void
cow(void)
{
	uchar *h;
	int i, k, p[Nkid][2], q[Nkid][2];
	char c;

	h = sbrk(Heap);
	if(h == (void*)-1)
		sysfatal("sbrk: %r");
	for(i = 0; i < Heap; i += Page)
		h[i] = 0xAA;
	for(k = 0; k < Nkid; k++){
		if(pipe(p[k]) < 0 || pipe(q[k]) < 0)
			sysfatal("pipe: %r");
		switch(rfork(RFPROC|RFFDG)){
		case -1:
			sysfatal("rfork: %r");
		case 0:
			/* Write my page, and say so. */
			h[(k+1)*Page] = k+1;
			write(p[k][1], "w", 1);
			/* Wait for the parent's write, then check. */
			if(read(q[k][0], &c, 1) != 1)
				sysfatal("read: %r");
			if(h[0] != 0xAA)
				sysfatal("child %d sees the parent's write", k);
			for(i = 0; i < Nkid; i++)
				if(h[(i+1)*Page] != (i == k ? k+1 : 0xAA))
					sysfatal("child %d sees page %d as %d", k, i+1, h[(i+1)*Page]);
			for(i = 0; i < Heap; i += 64*Page)
				if(i > Nkid*Page && h[i] != 0xAA)
					sysfatal("child %d: byte %d is %d", k, i, h[i]);
			exits(nil);
		}
	}
	for(k = 0; k < Nkid; k++)
		if(read(p[k][0], &c, 1) != 1)
			sysfatal("read: %r");
	h[0] = 0x55;
	for(k = 0; k < Nkid; k++)
		write(q[k][1], "p", 1);
	for(k = 0; k < Nkid; k++){
		Waitmsg *w = wait();
		if(w == nil)
			sysfatal("wait: %r");
		if(w->msg[0])
			sysfatal("%s", w->msg);
		free(w);
	}
	for(i = 0; i < Nkid; i++)
		if(h[(i+1)*Page] != 0xAA)
			sysfatal("the parent sees child %d's write", i);
	print("ok %d\n", h[0]);
}

void
rfmem(void)
{
	int p[2];
	char c;

	if(pipe(p) < 0)
		sysfatal("pipe: %r");
	switch(rfork(RFPROC|RFMEM)){
	case -1:
		sysfatal("rfork: %r");
	case 0:
		data = 2;
		bss = 3;
		/* A plain fork of the RFMEM child gets a copy of what it shares. */
		switch(rfork(RFPROC|RFFDG)){
		case -1:
			sysfatal("rfork: %r");
		case 0:
			if(read(p[0], &c, 1) != 1)
				sysfatal("read: %r");
			print("grandchild %ld %ld\n", data, bss);
			data = 4;
			bss = 5;
			exits(nil);
		}
		/* Writes after the fork don't reach the grandchild either. */
		data = 6;
		write(p[1], "x", 1);
		free(wait());
		exits(nil);
	}
	free(wait());
	print("parent %ld %ld\n", data, bss);
}

void
show(char *what)
{
	char path[64], buf[1024];
	int fd, n;

	snprint(path, sizeof path, "/proc/%d/segment", getpid());
	fd = open(path, OREAD);
	if(fd < 0)
		sysfatal("open: %r");
	n = read(fd, buf, sizeof buf - 1);
	close(fd);
	if(n < 0)
		sysfatal("read: %r");
	buf[n] = 0;
	print("%s:\n%s", what, buf);
}

void
segment(void)
{
	uchar *a, *b;

	a = segattach(0, "memory", (void*)0x10000000, 2*Page);
	if(a == (void*)-1)
		sysfatal("segattach memory: %r");
	b = segattach(0, "shared", nil, Page);
	if(b == (void*)-1)
		sysfatal("segattach shared: %r");
	a[0] = 1;
	b[0] = 2;
	show("attached");
	if(segbrk(a, a + 8*Page) == (void*)-1)
		sysfatal("segbrk: %r");
	a[7*Page] = 3;
	show("grown");
	if(segfree(a, 8*Page) < 0)
		sysfatal("segfree: %r");
	if(a[0] != 0 || a[7*Page] != 0)
		sysfatal("segfree left %d %d", a[0], a[7*Page]);
	show("freed");
	if(segdetach(b) < 0)
		sysfatal("segdetach: %r");
	show("detached");
}

void
main(int argc, char **argv)
{
	if(argc != 2)
		sysfatal("usage: mm cow|rfmem|seg");
	if(strcmp(argv[1], "cow") == 0)
		cow();
	else if(strcmp(argv[1], "rfmem") == 0)
		rfmem();
	else if(strcmp(argv[1], "seg") == 0)
		segment();
	else
		sysfatal("unknown test %s", argv[1]);
	exits(nil);
}
