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
 * What src/kern/fscheck.zig calls that raises: devoverlay's FIFOs, and
 * devfs's (or nstab.c's stand-ins for them).
 */
extern void h9_overlay_mkfifo(Chan*, char*, ulong);
extern void h9_fs_mkfifo(Chan*, char*, ulong);

int
h9_shim_overlay_mkfifo(Chan *c, char *name, ulong perm)
{
	if(waserror())
		return -1;
	h9_overlay_mkfifo(c, name, perm);
	poperror();
	return 0;
}

int
h9_shim_fs_mkfifo(Chan *c, char *name, ulong perm)
{
	if(waserror())
		return -1;
	h9_fs_mkfifo(c, name, perm);
	poperror();
	return 0;
}

/*
 * ns.c's pgrpcpy and devsrv.c's h9_srvpost, which raise, for
 * src/kern/dev/ns.zig.
 */
extern void pgrpcpy(Pgrp*, Pgrp*, int);
extern void h9_srvpost(void*, char*, Chan*, ulong);

int
h9_shim_pgrpcpy(Pgrp *to, Pgrp *from, int flag)
{
	if(waserror())
		return -1;
	pgrpcpy(to, from, flag);
	poperror();
	return 0;
}

int
h9_shim_srvpost(void *board, char *name, Chan *c, ulong perm)
{
	if(waserror())
		return -1;
	h9_srvpost(board, name, c, perm);
	poperror();
	return 0;
}

#ifndef H9_NSKERNEL
/*
 * devip's host-socket calls, which raise, for src/kern/netcheck.zig
 * and linuxnet.zig:
 * 0, or -1 with the error string set.
 */
#include "devip.h"
#include "hostsock.h"

int
h9_shim_so_getsockname(int fd, uchar *laddr, ushort *lport)
{
	if(waserror())
		return -1;
	so_getsockname(fd, laddr, lport);
	poperror();
	return 0;
}

int
h9_shim_so_bind(int fd, int su, ushort port, uchar *addr)
{
	if(waserror())
		return -1;
	so_bind(fd, su, port, addr);
	poperror();
	return 0;
}

int
h9_shim_so_socket(int proto, uchar *addr, int *opts, int *r)
{
	if(waserror())
		return -1;
	*r = h9so_socket(proto, addr, opts);
	poperror();
	return 0;
}

/* devip's ctl for the Linux socket calls, for src/kern/linuxnet.zig. */
extern long	h9_ip_ctl(Chan*, char*);

int
h9_shim_ip_ctl(Chan *c, char *msg)
{
	if(waserror())
		return -1;
	h9_ip_ctl(c, msg);
	poperror();
	return 0;
}
#endif
