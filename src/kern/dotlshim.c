/*
 * The C that #ℓ (src/kern/dev/dotl.zig) calls and that can raise, caught
 * as src/kern/devshim.c catches a C device: -1 with the error string on
 * the process as error() left it, or 0 with the result in *r. Each goes
 * when the file it calls is Zig (design/kernel-port.md).
 */
#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

/* rootdial.c */
extern Chan	*h9_unixchan(char *path);
/* devhstream.c */
extern Chan	*h9_hstream_dial(void *mach, char *url);

int
h9_shim_unixchan(char *path, Chan **r)
{
	if(waserror())
		return -1;
	*r = h9_unixchan(path);
	poperror();
	return 0;
}

int
h9_shim_hstream_dial(void *mach, char *url, Chan **r)
{
	if(waserror())
		return -1;
	*r = h9_hstream_dial(mach, url);
	poperror();
	return 0;
}
