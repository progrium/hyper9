/*
 * The device switch's shim (design/kernel-port.md): the Zig kernel calls
 * a C device's functions, and a C Devgen, through these, which catch the
 * device's error() and return -1, with the error string on the process
 * as error() left it, or 0 with the function's result in *r. They're
 * the only waserror the Zig kernel runs under: src/kern/dev.zig's switch
 * calls the first of them, and the Zig that calls other C that can raise
 * calls the rest.
 */
#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#include "devx.h"

int
h9_dev_reset(Dev *d)
{
	if(waserror())
		return -1;
	d->reset();
	poperror();
	return 0;
}

int
h9_dev_init(Dev *d)
{
	if(waserror())
		return -1;
	d->init();
	poperror();
	return 0;
}

int
h9_dev_shutdown(Dev *d)
{
	if(waserror())
		return -1;
	d->shutdown();
	poperror();
	return 0;
}

int
h9_dev_attach(Dev *d, char *spec, Chan **r)
{
	if(waserror())
		return -1;
	*r = d->attach(spec);
	poperror();
	return 0;
}

int
h9_dev_walk(Dev *d, Chan *c, Chan *nc, char **name, int nname, Walkqid **r)
{
	if(waserror())
		return -1;
	*r = d->walk(c, nc, name, nname);
	poperror();
	return 0;
}

int
h9_dev_stat(Dev *d, Chan *c, uchar *db, int n, int *r)
{
	if(waserror())
		return -1;
	*r = d->stat(c, db, n);
	poperror();
	return 0;
}

int
h9_dev_open(Dev *d, Chan *c, int omode, Chan **r)
{
	if(waserror())
		return -1;
	*r = d->open(c, omode);
	poperror();
	return 0;
}

int
h9_dev_create(Dev *d, Chan *c, char *name, int omode, ulong perm, Chan **r)
{
	if(waserror())
		return -1;
	*r = d->create(c, name, omode, perm);
	poperror();
	return 0;
}

int
h9_dev_close(Dev *d, Chan *c)
{
	if(waserror())
		return -1;
	d->close(c);
	poperror();
	return 0;
}

int
h9_dev_read(Dev *d, Chan *c, void *a, long n, vlong off, long *r)
{
	if(waserror())
		return -1;
	*r = d->read(c, a, n, off);
	poperror();
	return 0;
}

int
h9_dev_bread(Dev *d, Chan *c, long n, ulong off, Block **r)
{
	if(waserror())
		return -1;
	*r = d->bread(c, n, off);
	poperror();
	return 0;
}

int
h9_dev_write(Dev *d, Chan *c, void *a, long n, vlong off, long *r)
{
	if(waserror())
		return -1;
	*r = d->write(c, a, n, off);
	poperror();
	return 0;
}

int
h9_dev_bwrite(Dev *d, Chan *c, Block *b, ulong off, long *r)
{
	if(waserror())
		return -1;
	*r = d->bwrite(c, b, off);
	poperror();
	return 0;
}

int
h9_dev_remove(Dev *d, Chan *c)
{
	if(waserror())
		return -1;
	d->remove(c);
	poperror();
	return 0;
}

int
h9_dev_wstat(Dev *d, Chan *c, uchar *db, int n, int *r)
{
	if(waserror())
		return -1;
	*r = d->wstat(c, db, n);
	poperror();
	return 0;
}

int
h9_dev_gen(Devgen *gen, Chan *c, char *name, Dirtab *tab, int ntab, int i, Dir *dp, int *r)
{
	if(waserror())
		return -1;
	*r = gen(c, name, tab, ntab, i, dp);
	poperror();
	return 0;
}

/*
 * The optional operations (src/kern/devx.h), each of which may raise.
 */
int
h9_dev_readlink(Devx *x, Chan *c, char *buf, int nbuf, int *r)
{
	if(waserror())
		return -1;
	*r = x->readlink(c, buf, nbuf);
	poperror();
	return 0;
}

int
h9_dev_symlink(Devx *x, Chan *c, char *name, char *target)
{
	if(waserror())
		return -1;
	x->symlink(c, name, target);
	poperror();
	return 0;
}

int
h9_dev_link(Devx *x, Chan *c, Chan *dir, char *name, int *r)
{
	if(waserror())
		return -1;
	*r = x->link(c, dir, name);
	poperror();
	return 0;
}

int
h9_dev_getattr(Devx *x, Chan *c, uvlong mask, Attr *a)
{
	if(waserror())
		return -1;
	x->getattr(c, mask, a);
	poperror();
	return 0;
}

int
h9_dev_setattr(Devx *x, Chan *c, uvlong mask, Attr *a)
{
	if(waserror())
		return -1;
	x->setattr(c, mask, a);
	poperror();
	return 0;
}

int
h9_dev_rename(Devx *x, Chan *c, Chan *dir, char *name, int *r)
{
	if(waserror())
		return -1;
	*r = x->rename(c, dir, name);
	poperror();
	return 0;
}

/*
 * What else the Zig calls that can raise: h9's hook in chan.zig,
 * devfs's anchored attach (src/kern/fscheck.h).
 */
extern void h9_fs_anchor(Chan*);

int
h9_shim_fs_anchor(Chan *c)
{
	if(waserror())
		return -1;
	h9_fs_anchor(c);
	poperror();
	return 0;
}

/*
 * And src/kern/fifo.zig's: the overlay's lower chan for a FIFO's key,
 * and whether a chan is a FIFO's (src/kern/fscheck.h), which stats it.
 */
extern Chan *h9_overlay_lower(Chan*);
extern int h9_fs_chanisfifo(Chan*);

int
h9_shim_overlay_lower(Chan *c, Chan **r)
{
	if(waserror())
		return -1;
	*r = h9_overlay_lower(c);
	poperror();
	return 0;
}

int
h9_shim_fs_chanisfifo(Chan *c, int *r)
{
	if(waserror())
		return -1;
	*r = h9_fs_chanisfifo(c);
	poperror();
	return 0;
}

/* And src/kern/dev/env.zig's: the process's Egrp, which proc.c raises without. */
extern void *h9_upegrp(void);

int
h9_shim_upegrp(void **r)
{
	if(waserror())
		return -1;
	*r = h9_upegrp();
	poperror();
	return 0;
}
