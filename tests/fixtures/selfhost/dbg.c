/*
 * A small debugger for the self-host cases (tests/integration.zig,
 * design/0010-self-host.md), built in the guest. Addresses are hex.
 *
 *	dbg peek pid addr		print the long at addr
 *	dbg copy pid from to n		copy n bytes of pid's memory from to to
 *	dbg brk pid addr		write a breakpoint instruction at addr
 *	dbg regs pid			check regs and fpregs: whether regs is a
 *					Ureg with the PC in the text segment, and
 *					fpregs's size
 */
#include <u.h>
#include <libc.h>
#include <ureg.h>

int
procfd(int pid, char *file, int mode)
{
	char buf[64];
	int fd;

	snprint(buf, sizeof buf, "/proc/%d/%s", pid, file);
	fd = open(buf, mode);
	if(fd < 0)
		sysfatal("open %s: %r", buf);
	return fd;
}

uvlong
hex(char *s)
{
	return strtoull(s, nil, 16);
}

/* The text segment's [base, top) from /proc/n/segment. */
void
textseg(int pid, uvlong *base, uvlong *top)
{
	char buf[1024], *lines[16], *f[8];
	int fd, n, i;

	fd = procfd(pid, "segment", OREAD);
	n = read(fd, buf, sizeof buf - 1);
	close(fd);
	if(n <= 0)
		sysfatal("read segment: %r");
	buf[n] = 0;
	n = getfields(buf, lines, nelem(lines), 1, "\n");
	for(i = 0; i < n; i++)
		if(tokenize(lines[i], f, nelem(f)) >= 4 && strcmp(f[0], "Text") == 0){
			/* "Text R base top refs" */
			*base = hex(f[2]);
			*top = hex(f[3]);
			return;
		}
	sysfatal("no Text segment");
}

void
main(int argc, char **argv)
{
	char buf[8192];
	uchar brk[4];
	uvlong base, top;
	struct Ureg u;	/* 386's ureg.h has no typedef */
	ulong l;
	int fd, pid, n, nbrk;

	if(argc < 3)
		sysfatal("usage");
	pid = atoi(argv[2]);
	if(strcmp(argv[1], "peek") == 0 && argc == 4){
		fd = procfd(pid, "mem", OREAD);
		if(pread(fd, &l, sizeof l, hex(argv[3])) != sizeof l)
			sysfatal("peek: %r");
		print("%#lux\n", l);
	}else if(strcmp(argv[1], "copy") == 0 && argc == 6){
		n = atoi(argv[5]);
		if(n > sizeof buf)
			sysfatal("copy: too big");
		fd = procfd(pid, "mem", ORDWR);
		if(pread(fd, buf, n, hex(argv[3])) != n)
			sysfatal("copy: read: %r");
		if(pwrite(fd, buf, n, hex(argv[4])) != n)
			sysfatal("copy: write: %r");
	}else if(strcmp(argv[1], "brk") == 0 && argc == 4){
		/* libmach's breakpoints: BRK #0 on arm64, INT3 on x86. */
		if(strcmp(getenv("objtype"), "arm64") == 0){
			brk[0] = 0x00; brk[1] = 0x00; brk[2] = 0x20; brk[3] = 0xd4;
			nbrk = 4;
		}else{
			brk[0] = 0xcc;
			nbrk = 1;
		}
		fd = procfd(pid, "mem", ORDWR);
		if(pwrite(fd, brk, nbrk, hex(argv[3])) != nbrk)
			sysfatal("brk: %r");
	}else if(strcmp(argv[1], "regs") == 0 && argc == 3){
		fd = procfd(pid, "regs", OREAD);
		n = read(fd, buf, sizeof buf);
		close(fd);
		if(n < 0)
			sysfatal("regs: %r");
		if(n == sizeof u)
			print("regs: a Ureg\n");
		else
			print("regs: %d bytes, not %d\n", n, sizeof u);
		memmove(&u, buf, sizeof u);
		textseg(pid, &base, &top);
		print("pc in text %d\n", u.pc >= base && u.pc < top);
		fd = procfd(pid, "fpregs", OREAD);
		n = read(fd, buf, sizeof buf);
		close(fd);
		if(n < 0)
			sysfatal("fpregs: %r");
		print("fpregs %d\n", n);
	}else
		sysfatal("usage");
	exits(nil);
}
