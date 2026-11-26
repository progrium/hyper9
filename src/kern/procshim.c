/*
 * The C that src/kern/proc.zig calls and that can raise, caught as
 * src/kern/devshim.c catches a C device's error(): each returns -1 with
 * the error string on the process as error() left it, or 0 with the
 * result in *r. devenv.c's environment groups go once devenv is Zig,
 * and the call of h9_kern_isolated's function once gfx.c's screen setup
 * is (design/kernel-port.md).
 */
#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"

int
h9_shim_egrpnew(void **r)
{
	if(waserror())
		return -1;
	*r = h9_egrpnew();
	poperror();
	return 0;
}

int
h9_shim_egrpcopy(void *from, void **r)
{
	if(waserror())
		return -1;
	*r = h9_egrpcopy(from);
	poperror();
	return 0;
}

int
h9_shim_call(void (*fn)(void*), void *arg)
{
	if(waserror())
		return -1;
	fn(arg);
	poperror();
	return 0;
}
