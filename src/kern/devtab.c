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
extern Dev drawdevtab;
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

Dev *devtab[] = {
	&rootdevtab,
	&consdevtab,
	&pipedevtab,
	&ssldevtab,
	&tlsdevtab,
	&mousedevtab,
	&drawdevtab,
	&ipdevtab,
	&fsdevtab,
	&mntdevtab,
	&lfddevtab,
	&audiodevtab,
	&kbddevtab,
	&cmddevtab,
	&envdevtab,
	&hconsdevtab,
	&dupdevtab,
	&procdevtab,
	&overlaydevtab,
	&srvdevtab,
	0
};

