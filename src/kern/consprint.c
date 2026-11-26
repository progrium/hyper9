/*
 * drawterm's devcons.c printers, which are variadic and so stay C:
 * print, iprint, pprint, and panic, over src/kern/dev/cons.zig's putstrn.
 * The rest of devcons is that Zig (design/kernel-port.md). The namespace
 * kernel has its own, in src/kern/nstab.c.
 */
#include	"u.h"
#include	"lib.h"
#include	"dat.h"
#include	"fns.h"
#include	"error.h"

#undef write

int	panicking;

int
print(char *fmt, ...)
{
	int n;
	va_list arg;
	char buf[PRINTSIZE];

	va_start(arg, fmt);
	n = vseprint(buf, buf+sizeof(buf), fmt, arg) - buf;
	va_end(arg);
	putstrn(buf, n);

	return n;
}

static void
hang(void)
{
	Rendez z = {0};
	while(up == nil) osyield();
	for(;;) sleep(&z, return0, 0);
}

void
panic(char *fmt, ...)
{
	int n;
	va_list arg;
	char buf[PRINTSIZE];

	kprintoq = nil;	/* don't try to write to /dev/kprint */

	if(panicking++) hang();
	splhi();
	strcpy(buf, "panic: ");
	va_start(arg, fmt);
	n = vseprint(buf+strlen(buf), buf+sizeof(buf), fmt, arg) - buf;
	va_end(arg);
	buf[n] = '\n';
	spllo();
	putstrn(buf, n+1);
	if(screenputs) hang();
	setterm(0);
	exit(1);
}

int
pprint(char *fmt, ...)
{
	int n;
	Chan *c;
	va_list arg;
	char buf[2*PRINTSIZE];

	if(up == nil || up->fgrp == nil)
		return 0;

	c = up->fgrp->fd[2];
	if(c==0 || (c->mode!=OWRITE && c->mode!=ORDWR))
		return 0;
	n = sprint(buf, "%s %lud: ", up->text, up->pid);
	va_start(arg, fmt);
	n = vseprint(buf+n, buf+sizeof(buf), fmt, arg) - buf;
	va_end(arg);

	if(waserror())
		return 0;
	devtab[c->type]->write(c, buf, n, c->offset);
	poperror();

	lock(&c->ref.lk);
	c->offset += n;
	unlock(&c->ref.lk);

	return n;
}

int
iprint(char *fmt, ...)
{
	int n, s;
	va_list arg;
	char buf[PRINTSIZE];

	s = splhi();
	va_start(arg, fmt);
	n = vseprint(buf, buf+sizeof(buf), fmt, arg) - buf;
	va_end(arg);
	write(2, buf, n);
	if(screenputs != 0)
		screenputs(buf, n);
	splx(s);

	return n;
}
