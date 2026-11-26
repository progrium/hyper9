/*
 * The edge of drawterm's C (design/kernel-port.md). h9's kernel is Zig,
 * with error unions, but the drawterm code it still builds (devcons,
 * devdraw, devfs, devip, devssl, devtls, and the rest) raises with
 * error(), which is setjmp and longjmp, and only C can set the label
 * that jumps to. So the Zig calls that code through this one function:
 * fn(arg) under a label, returning 0, or -1 with the error string on
 * the process as error() left it. src/kern/dev.zig's `raising` packs a
 * call into fn and arg; fn is a Zig function with nothing to undo.
 *
 * It's h9's, not drawterm's, and lives beside the vendored tree rather
 * than in it, so h9 patches nothing there to have it.
 */
#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"

int
h9_catch(void (*fn)(void*), void *arg)
{
	if(waserror())
		return -1;
	fn(arg);
	poperror();
	return 0;
}
