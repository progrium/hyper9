/*
 * The C that src/kern/proc.zig calls and that can raise, caught as
 * src/kern/devshim.c catches a C device's error(): each returns -1 with
 * the error string on the process as error() left it. The call of
 * h9_kern_isolated's function goes once gfx.c's screen setup is Zig
 * (design/kernel-port.md).
 */
#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"

int
h9_shim_call(void (*fn)(void*), void *arg)
{
	if(waserror())
		return -1;
	fn(arg);
	poperror();
	return 0;
}
