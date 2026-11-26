/*
 * The device table's optional operations (design/file-interface.md,
 * Part 2): what a device can do beyond 9P2000's nine. A device that has
 * some lists them in a Devx, named in devxtab (src/kern/devtab.c, or
 * nstab.c in the namespace kernel), by its device character; a device
 * in Zig has them in its dev.Native ops. The device switch
 * (src/kern/dev.zig) calls them through src/kern/devshim.c, so each may
 * raise, and any a device leaves nil gets the switch's default, which
 * is what h9 did before: links are "permission denied" and read as no
 * link, a link is a copy, attributes are built from stat and set by
 * wstat, and a rename is a wstat within a directory and "cross-device
 * link" across one.
 *
 * Every operation is checked by the device where its open and wstat
 * are: a new name is checked as a create, and an old one as a rename.
 * The switch calls link and rename only on two chans of one device
 * instance, so a link can't name a file from another tree.
 */

typedef struct Attr Attr;
typedef struct Devx Devx;

/*
 * A file's attributes, as Linux has them. valid says which are set, by
 * the A bits below, which are 9P2000.L's getattr mask; a getattr asks
 * for some, and a setattr names the ones it sets (for setattr, Aatime
 * and Amtime with the time Anow means now).
 */
struct Attr
{
	uvlong	valid;
	Qid	qid;
	ulong	mode;	/* Plan 9 mode bits: DMDIR, H9_DMSYMLINK, H9_DMFIFO, and the permissions */
	ulong	uid;
	ulong	gid;
	uvlong	nlink;
	uvlong	rdev;
	uvlong	size;
	uvlong	blocks;
	vlong	atime;
	vlong	atimens;
	vlong	mtime;
	vlong	mtimens;
	vlong	ctime;
	vlong	ctimens;
};

enum
{
	Amode	= 0x1,
	Anlink	= 0x2,
	Auid	= 0x4,
	Agid	= 0x8,
	Ardev	= 0x10,
	Aatime	= 0x20,
	Amtime	= 0x40,
	Actime	= 0x80,
	Aino	= 0x100,
	Asize	= 0x200,
	Ablocks	= 0x400,
	Abasic	= 0x7ff,

	Anow	= (1<<30)-1,	/* a setattr's atimens or mtimens: the time now */
};

struct Devx
{
	int	dc;	/* the device's character, as in its Dev */

	/*
	 * The target of the link c is, as written, into buf (nul-terminated,
	 * cut to nbuf-1): its length, or -1 if c isn't a link.
	 */
	int	(*readlink)(Chan *c, char *buf, int nbuf);
	/* Makes name in the directory c a symbolic link to target. */
	void	(*symlink)(Chan *c, char *name, char *target);
	/*
	 * Makes name in the directory dir another name for c's file: 0, or
	 * 1 if it can't, for the default (a copy).
	 */
	int	(*link)(Chan *c, Chan *dir, char *name);
	/* Fills a with what mask asks for, and sets a->valid to what it has. */
	void	(*getattr)(Chan *c, uvlong mask, Attr *a);
	/* Sets what mask names from a. */
	void	(*setattr)(Chan *c, uvlong mask, Attr *a);
	/*
	 * Moves c to name in the directory dir, replacing a file there, at
	 * once where it can: 0, or 1 if it can't, for the default to try.
	 */
	int	(*rename)(Chan *c, Chan *dir, char *name);
};

extern Devx *devxtab[];
