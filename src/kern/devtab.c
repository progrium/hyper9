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
extern Dev linuxdevtab;
extern Dev evdevtab;

#ifdef H9_WEB
/*
 * devfs on the web host (design/0012-browser-host.md). WASI has no
 * permission bits, so devfs gives every file mode 0, which devoverlay
 * takes as unwritable and ls shows as ----------. The policy, not the
 * mode, decides what the guest may do, so this device is devfs with
 * files and directories reading as rwxrwxr-x.
 */
enum { Modeoff = BIT16SZ+BIT16SZ+BIT32SZ+QIDSZ };	/* size type dev qid mode */

static void
webfsmodes(uchar *p, long n)
{
	long m;
	ulong mode;

	while(n >= Modeoff+BIT32SZ){
		m = BIT16SZ + GBIT16(p);
		if(m > n)
			break;
		mode = GBIT32(p+Modeoff);
		if((mode & 0777) == 0)
			PBIT32(p+Modeoff, mode|0775);
		p += m;
		n -= m;
	}
}

static void webfsreset(void) { fsdevtab.reset(); }
static void webfsinit(void) { fsdevtab.init(); }
static void webfsshutdown(void) { fsdevtab.shutdown(); }
static Chan* webfsattach(char *spec) { return fsdevtab.attach(spec); }
static Walkqid* webfswalk(Chan *c, Chan *nc, char **name, int nname) { return fsdevtab.walk(c, nc, name, nname); }
static Chan* webfsopen(Chan *c, int omode) { return fsdevtab.open(c, omode); }
static Chan* webfscreate(Chan *c, char *name, int omode, ulong perm) { return fsdevtab.create(c, name, omode, perm); }
static void webfsclose(Chan *c) { fsdevtab.close(c); }
static Block* webfsbread(Chan *c, long n, ulong off) { return fsdevtab.bread(c, n, off); }
static long webfswrite(Chan *c, void *a, long n, vlong off) { return fsdevtab.write(c, a, n, off); }
static long webfsbwrite(Chan *c, Block *b, ulong off) { return fsdevtab.bwrite(c, b, off); }
static void webfsremove(Chan *c) { fsdevtab.remove(c); }
static int webfswstat(Chan *c, uchar *dp, int n) { return fsdevtab.wstat(c, dp, n); }

static int
webfsstat(Chan *c, uchar *dp, int n)
{
	n = fsdevtab.stat(c, dp, n);
	webfsmodes(dp, n);
	return n;
}

static long
webfsread(Chan *c, void *a, long n, vlong off)
{
	n = fsdevtab.read(c, a, n, off);
	if(c->qid.type & QTDIR)
		webfsmodes(a, n);
	return n;
}

Dev webfsdevtab = {
	'U',
	"fs",

	webfsreset,
	webfsinit,
	webfsshutdown,
	webfsattach,
	webfswalk,
	webfsstat,
	webfsopen,
	webfscreate,
	webfsclose,
	webfsread,
	webfsbread,
	webfswrite,
	webfsbwrite,
	webfsremove,
	webfswstat,
};
#define fsdevtab webfsdevtab
#endif

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
	&linuxdevtab,
	&evdevtab,
	0
};

