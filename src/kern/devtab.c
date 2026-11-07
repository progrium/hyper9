/*
 * h9's device table: drawterm's kern/devtab.c plus our devices. The
 * build compiles this instead of drawterm's copy.
 */
#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

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
#else
/* devdraw opening the screen lazily, and devcons's snarf limited to the machine with it (gfx.c) */
extern Dev h9drawdevtab;
extern Dev h9consdevtab;
extern Dev h9kbddevtab;	/* devkbd, serving kbdfs's format */
#endif
extern Dev ipdevtab;
extern Dev fsdevtab;
extern Dev mntdevtab;
extern Dev lfddevtab;
extern Dev audiodevtab;
extern Dev kbddevtab;
extern Dev cmddevtab;
extern Dev envdevtab;
extern Dev hconsdevtab;
extern Dev dupdevtab;
extern Dev procdevtab;
extern Dev overlaydevtab;
extern Dev srvdevtab;
extern Dev htoolsdevtab;
extern Dev hstreamdevtab;

Dev *devtab[] = {
	&rootdevtab,
	&h9consdevtab,
	&pipedevtab,
	&ssldevtab,
	&tlsdevtab,
	&mousedevtab,
	&h9drawdevtab,
	&ipdevtab,
	&fsdevtab,
	&mntdevtab,
	&lfddevtab,
	&audiodevtab,
	&h9kbddevtab,
#ifdef H9_HOSTCMD
	&cmddevtab,	/* -Dhost-cmd only */
#endif
	&envdevtab,
	&hconsdevtab,
	&dupdevtab,
	&procdevtab,
	&overlaydevtab,
	&srvdevtab,
	&htoolsdevtab,
	&hstreamdevtab,
	0
};

