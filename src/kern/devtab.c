/*
 * h9's device table: drawterm's kern/devtab.c plus our devices. The
 * build compiles this instead of drawterm's copy.
 */
#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#include "devx.h"

extern Dev consdevtab;
extern Dev rootdevtab;
extern Dev pipedevtab;
extern Dev ssldevtab;
extern Dev tlsdevtab;
extern Dev mousedevtab;
#ifdef H9_GFX_NONE
extern Dev drawdevtab;
#define h9drawdevtab drawdevtab
#define h9consdevtab consdevtab
#define h9kbddevtab kbddevtab
#define h9mousedevtab mousedevtab
#else
/* devdraw opening the screen lazily, and devcons's snarf limited to the machine with it (src/kern/dev/gfx.zig) */
extern Dev h9drawdevtab;
extern Dev h9consdevtab;
extern Dev h9kbddevtab;	/* devkbd, serving kbdfs's format, and kbdin */
extern Dev h9mousedevtab;	/* devmouse, and mousein */
#endif
extern Dev ipdevtab;	/* src/host/devip.zig */
extern Dev fsdevtab;	/* src/host/devfs.zig */
extern Dev mntdevtab;
extern Dev lfddevtab;
extern Dev audiodevtab;
extern Dev kbddevtab;
extern Dev envdevtab;
extern Dev hconsdevtab;
extern Dev dupdevtab;
extern Dev procdevtab;
extern Dev overlaydevtab;
extern Dev srvdevtab;
extern Dev htoolsdevtab;
extern Dev hstreamdevtab;
extern Dev dotldevtab;
extern Dev hidxdevtab;
extern Dev linuxdevtab;
extern Dev evdevtab;
extern Dev ptydevtab;
extern Dev machinedevtab;	/* #μ, child machines (src/kern/dev/machine.zig) */


Dev *devtab[] = {
	&rootdevtab,
	&h9consdevtab,
	&pipedevtab,
	&ssldevtab,
	&tlsdevtab,
	&h9mousedevtab,
	&h9drawdevtab,
	&ipdevtab,
	&fsdevtab,
	&mntdevtab,
	&lfddevtab,
	&audiodevtab,
	&h9kbddevtab,
	&envdevtab,
	&hconsdevtab,
	&dupdevtab,
	&procdevtab,
	&overlaydevtab,
	&srvdevtab,
	&htoolsdevtab,
	&hstreamdevtab,
	&dotldevtab,
	&hidxdevtab,
	&linuxdevtab,
	&evdevtab,
	&ptydevtab,
	&machinedevtab,
	0
};

/*
 * The optional operations of the C devices that have them
 * (design/file-interface.md, src/kern/devx.h): none. devfs's and devip's
 * are their own (src/host/devfs.zig and devip.zig).
 */
Devx *devxtab[] = {
	0
};
