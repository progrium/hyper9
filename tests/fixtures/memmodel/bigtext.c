/*
 * For "a.out text is filled on touch" in tests/integration.zig
 * (design/memory-model.md). The test puts the includes and a few
 * thousand functions f0, f1, ... ahead of this, so the text is most of a
 * megabyte, and main runs none of them. It compares this process's resident
 * bytes, from the 10th field of /proc/n/status, with the text from f0 to
 * etext, and prints "less" when they're fewer, or both numbers when not.
 * The numbers can differ between engines; the word doesn't.
 */
extern char etext[];

void
main(void)
{
	char path[64], buf[512], *f[12];
	int fd, n;
	vlong resident, text;

	snprint(path, sizeof path, "/proc/%d/status", getpid());
	fd = open(path, OREAD);
	if(fd < 0)
		sysfatal("open: %r");
	n = read(fd, buf, sizeof buf - 1);
	close(fd);
	if(n < 0)
		sysfatal("read: %r");
	buf[n] = 0;
	if(tokenize(buf, f, nelem(f)) < 10)
		sysfatal("short status: %s", buf);
	resident = strtoll(f[9], nil, 10)*1024;
	text = (uintptr)etext - (uintptr)f0;
	if(text < 512*1024)
		sysfatal("only %lld bytes of text", text);
	if(resident <= 0 || resident >= text){
		print("resident %lld, text %lld\n", resident, text);
		exits("more");
	}
	print("less\n");
	exits(nil);
}
