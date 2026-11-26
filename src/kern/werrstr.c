/*
 * drawterm's werrstr (sysfile.c), which stays C since it's variadic; the
 * rest of sysfile.c is src/kern/sysfile.zig (design/kernel-port.md).
 */
#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

void
werrstr(char *f, ...)
{
	char buf[ERRMAX];
	va_list arg;

	va_start(arg, f);
	vsnprint(buf, sizeof buf, f, arg);
	va_end(arg);

	if(up->nerrlab)
		strecpy(up->errstr, up->errstr+ERRMAX, buf);
	else
		strecpy(up->syserrstr, up->syserrstr+ERRMAX, buf);
}
