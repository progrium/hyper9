#include	"u.h"
#include	<sys/types.h>
#include	<sys/time.h>
#include	<sys/stat.h>
#include	<dirent.h>
#include	<fcntl.h>
#include	<errno.h>
#include	<stdio.h> /* for remove, rename */
#include	<limits.h>

#ifndef NAME_MAX
#	define NAME_MAX 256
#endif
#include	"lib.h"
#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"fscheck.h"	/* h9: sandbox hooks */

typedef	struct Ufsinfo	Ufsinfo;
struct Ufsinfo
{
	int	mode;
	int	fd;
	int	uid;
	int	gid;
	DIR*	dir;
	vlong	offset;
	QLock	oq;
	char*	path;
	char nextname[NAME_MAX];
	/*
	 * h9: a contained attach (#U!c, design/0034-symlinks-in-root.md)
	 * resolves links inside top, its tree, once namec's walk has set it
	 * (h9_fs_anchor). path is then always resolved, and lpath, if set,
	 * is the link the last name was, in its resolved directory.
	 */
	int	contained;
	char*	top;
	char*	lpath;
};

/* h9: the chan's own name on the host: the link, not its target. */
static char*
ownpath(Ufsinfo *uif)
{
	return uif->lpath != nil ? uif->lpath : uif->path;
}


#if defined(__wasi__)
/*
 * h9: WASI has no permission bits: every file stats as 0775 and chmod
 * fails. Programs that check what they set (PostgreSQL wants its data
 * directory 0700 or 0750) need the mode back, so the web host remembers
 * the permission bits a create or wstat gave each file, by inode, for
 * the life of the machine.
 */
typedef struct Wmode Wmode;
struct Wmode {
	dev_t	dev;
	ino_t	ino;
	int	mode;
	Wmode	*next;
};
static Wmode *wmodes[256];

static Wmode**
wmodeslot(struct stat *st)
{
	return &wmodes[((unsigned long)st->st_ino ^ (unsigned long)st->st_dev) & 255];
}

static void
wmodeset(struct stat *st, int mode)
{
	Wmode *w;

	for(w = *wmodeslot(st); w != nil; w = w->next)
		if(w->ino == st->st_ino && w->dev == st->st_dev){
			w->mode = mode & 0777;
			return;
		}
	w = malloc(sizeof *w);
	if(w == nil)
		return;
	w->dev = st->st_dev;
	w->ino = st->st_ino;
	w->mode = mode & 0777;
	w->next = *wmodeslot(st);
	*wmodeslot(st) = w;
}

static int
wmodeof(struct stat *st)
{
	Wmode *w;

	for(w = *wmodeslot(st); w != nil; w = w->next)
		if(w->ino == st->st_ino && w->dev == st->st_dev)
			return w->mode;
	return st->st_mode & 0777;
}
#define	STMODE(st)	wmodeof(st)
#else
#define	STMODE(st)	((st)->st_mode&0777)
#endif

static	Qid	fsqid(struct stat *);
static	char*	catpath(char*, char*);
static	ulong	fsdirread(Chan*, uchar*, int, ulong);
static	int	fsomode(int);
static	void	fsflush(Chan*);	/* h9 */

static char*
lastelem(char *s)
{
	char *t;

	if((t = strrchr(s, '/')) == nil)
		return s;
	if(t[1] == 0)
		return t;
	return t+1;
}

/*
 * h9: opens the parent directory of path for an *at operation, and checks it
 * by the directory the fd actually is (h9_fs_allowfd), so an openat, mkdirat,
 * unlinkat or renameat relative to the fd can't be steered outside the policy
 * by a swapped parent component. Copies path's last element into base, which
 * must hold NAME_MAX+1 bytes. Returns the fd (the caller closes it) or raises
 * the policy or host error.
 */
static int
h9_parentfd(char *path, char *base)
{
	char dir[PATH_MAX];
	char *slash;
	int fd, n;

	slash = strrchr(path, '/');
	if(slash == nil){
		if(strlen(path) > NAME_MAX)
			error(strerror(ENAMETOOLONG));
		strcpy(base, path);
		fd = open(".", O_RDONLY|O_DIRECTORY);
	}else{
		if(strlen(slash+1) > NAME_MAX)
			error(strerror(ENAMETOOLONG));
		strcpy(base, slash+1);
		n = slash - path;
		if(n == 0){
			dir[0] = '/';
			dir[1] = 0;
		}else{
			if(n >= sizeof dir)
				error(strerror(ENAMETOOLONG));
			memmove(dir, path, n);
			dir[n] = 0;
		}
		fd = open(dir, O_RDONLY|O_DIRECTORY);
	}
	if(fd < 0)
		error(strerror(errno));
	if(waserror()){
		close(fd);
		nexterror();
	}
	h9_fs_notefd(fd, slash == nil ? "." : dir);
	h9_fs_allowfd(fd, H9_FSWALK);
	poperror();
	return fd;
}
	
static Chan*
fsattach(char *spec)
{
	Chan *c;
	struct stat stbuf;
	static int devno;
	Ufsinfo *uif;
	int contained;

	/* h9: the only spec is !c, a contained tree. */
	contained = 0;
	if(spec != nil && spec[0] != 0){
		if(strcmp(spec, "!c") != 0)
			error(Ebadspec);
		contained = 1;
	}
	if(stat("/", &stbuf) < 0)
		error(strerror(errno));

	c = devattach('U', spec);

	uif = mallocz(sizeof(Ufsinfo), 1);
	uif->mode = stbuf.st_mode;
	uif->uid = stbuf.st_uid;
	uif->gid = stbuf.st_gid;
	uif->path = strdup("/");
	uif->contained = contained;

	c->aux = uif;
	c->dev = devno++;
	c->qid.type = QTDIR;
/*print("fsattach %s\n", chanpath(c));*/

	return c;
}

static Chan*
fsclone(Chan *c, Chan *nc)
{
	Ufsinfo *uif;

	uif = mallocz(sizeof(Ufsinfo), 1);
	*uif = *(Ufsinfo*)c->aux;
	uif->path = strdup(uif->path);
	if(uif->top != nil)
		uif->top = strdup(uif->top);
	if(uif->lpath != nil)
		uif->lpath = strdup(uif->lpath);
	nc->aux = uif;

	return nc;
}

/*
 * h9: a final name that's a link to nothing is walked to as the link
 * itself, so it can be renamed, removed and lstat'd (an open of it still
 * fails, following it). Returns 1, or 0 if name isn't such a link.
 */
static int
danglingwalk(Chan *c, char *name)
{
	struct stat stbuf;
	Ufsinfo *uif;
	char *path;

	uif = c->aux;
	if(strcmp(name, "..") == 0 || strcmp(name, ".") == 0)
		return 0;
	path = catpath(uif->path, name);
	if(h9_fs_checkname(path, H9_FSWALK) < 0 || lstat(path, &stbuf) < 0 || !S_ISLNK(stbuf.st_mode)){
		free(path);
		return 0;
	}
	free(uif->path);
	uif->path = path;
	free(uif->lpath);
	uif->lpath = nil;
	uif->mode = stbuf.st_mode;
	uif->uid = stbuf.st_uid;
	uif->gid = stbuf.st_gid;
	c->qid = fsqid(&stbuf);
	return 1;
}

/*
 * h9: a walk in a contained tree, resolved by fscheck.c inside it.
 * Returns 1, 0 if name doesn't exist, or -1 for too many links.
 */
static int
fswalkin(Chan *c, char *name)
{
	char buf[PATH_MAX];
	struct stat stbuf;
	Ufsinfo *uif;
	char *lpath;
	int r;

	uif = c->aux;
	r = h9_fs_resolvein(uif->top, uif->path, name, buf, sizeof buf);
	if(r == H9_RESLOOP)
		return -1;
	if(r < 0 || h9_fs_check(buf, H9_FSWALK) < 0 || stat(buf, &stbuf) < 0)
		return danglingwalk(c, name);
	lpath = nil;
	if(strcmp(name, "..") != 0){
		lpath = catpath(uif->path, name);
		if(strcmp(lpath, buf) == 0){
			free(lpath);
			lpath = nil;
		}
	}
	free(uif->path);
	uif->path = strdup(buf);
	free(uif->lpath);
	uif->lpath = lpath;

	uif->mode = stbuf.st_mode;
	uif->uid = stbuf.st_uid;
	uif->gid = stbuf.st_gid;

	c->qid = fsqid(&stbuf);

	return 1;
}

static int
fswalk1(Chan *c, char *name)
{
	struct stat stbuf;
	Ufsinfo *uif;
	char *path;

	/*print("** fs walk '%s' -> %s\n", path, name);  */

	uif = c->aux;
	if(uif->top != nil)
		return fswalkin(c, name);
	path = catpath(uif->path, name);
	if(h9_fs_check(path, H9_FSWALK) < 0 || stat(path, &stbuf) < 0){
		free(path);
		return danglingwalk(c, name);
	}
	free(uif->path);
	uif->path = path;

	uif->mode = stbuf.st_mode;
	uif->uid = stbuf.st_uid;
	uif->gid = stbuf.st_gid;

	c->qid = fsqid(&stbuf);

	return 1;
}

static Walkqid*
fswalk(Chan *c, Chan *nc, char **name, int nname)
{
	int i, loop;
	Walkqid *wq;

	if(nc != nil)
		panic("fswalk: nc != nil");
	wq = smalloc(sizeof(Walkqid)+(nname-1)*sizeof(Qid));
	nc = devclone(c);
	fsclone(c, nc);
	wq->clone = nc;
	loop = 0;
	for(i=0; i<nname; i++){
		if((loop = fswalk1(nc, name[i])) <= 0)
			break;
		wq->qid[i] = nc->qid;
	}
	if(i != nname){
		cclose(nc);
		wq->clone = nil;
	}
	/* h9: a link loop in a contained tree is an error, not a missing name. */
	if(loop < 0){
		free(wq);
		error(H9_ELOOP);
	}
	wq->nqid = i;
	/* h9: as devwalk does, so namec tries the rest of a union. */
	if(i == 0 && nname > 0){
		free(wq);
		kstrcpy(up->errstr, Enonexist, ERRMAX);
		return nil;
	}
	return wq;
}
	
/* h9: c is an open file, with a host fd (uif->fd is 0, not -1, before open). */
static int
openfile(Chan *c)
{
	return (c->flag & COPEN) != 0 && (c->qid.type & QTDIR) == 0 && ((Ufsinfo*)c->aux)->fd >= 0;
}

static int
fsstat(Chan *c, uchar *buf, int n)
{
	Dir d;
	struct stat stbuf;
	Ufsinfo *uif;

	if(n < BIT16SZ)
		error(Eshortstat);

	uif = c->aux;
	/*
	 * h9: an open file is the one its fd has, which a rename since may
	 * have moved from its path (fswstat); a dangling link (danglingwalk)
	 * has only its own stat.
	 */
	if(openfile(c) && fstat(uif->fd, &stbuf) == 0)
		;
	else if(stat(uif->path, &stbuf) < 0 && lstat(ownpath(uif), &stbuf) < 0)
		error(strerror(errno));

	d.name = lastelem(ownpath(uif));
	d.uid = eve;
	d.gid = eve;
	d.muid = eve;
	d.qid = c->qid;
	d.mode = (c->qid.type<<24)|STMODE(&stbuf);
	if(S_ISFIFO(stbuf.st_mode))
		d.mode |= H9_DMFIFO;	/* h9 */
	d.atime = stbuf.st_atime;
	d.mtime = stbuf.st_mtime;
	d.length = stbuf.st_size;
	d.type = 'U';
	d.dev = c->dev;
	return convD2M(&d, buf, n);
}

static Chan*
fsopen(Chan *c, int mode)
{
	Ufsinfo *uif;
	int omode, op, fd, m;

	omode = openmode(mode);

	uif = c->aux;
	/* h9: a link walked to as itself has no target to open (danglingwalk). */
	if(S_ISLNK(uif->mode))
		error(Enonexist);
	op = omode == OREAD && !(mode&OTRUNC) ? H9_FSREAD : H9_FSWRITE;
	/*
	 * h9: open first, then check the file the fd actually refers to
	 * (h9_fs_allowfd), rather than checking uif->path and opening it as two
	 * separate resolutions. A guest thread that swaps a path component for a
	 * symlink between a check and the open can't redirect this open past the
	 * policy: the fd and the check see one inode. The open follows symlinks
	 * as before but reads nothing until it has passed the check, and a
	 * truncation waits until then so a denied file is left intact.
	 */
	if(c->qid.type & QTDIR) {
		if(omode != OREAD)
			error(Eperm);
		if((fd = open(uif->path, O_RDONLY|O_DIRECTORY)) < 0)
			error(strerror(errno));
		if(waserror()){
			close(fd);
			nexterror();
		}
		h9_fs_notefd(fd, uif->path);
		h9_fs_allowfd(fd, op);
		if(mode & ORCLOSE)
			h9_fs_allowfd(fd, H9_FSREMOVE);
		if((uif->dir = fdopendir(fd)) == NULL)
			error(strerror(errno));
		poperror();
	}
	else if(S_ISFIFO(uif->mode)) {
		/*
		 * h9: a host FIFO is opened only to check it, without waiting for
		 * the other end, and never read or written (fsread, fswrite): a
		 * Linux program's open joins h9's own pipe for it (src/kern/fifo.c),
		 * and a Plan 9 program sees an empty file.
		 */
		if((fd = open(uif->path, O_RDONLY|O_NONBLOCK)) < 0)
			error(strerror(errno));
		if(waserror()){
			close(fd);
			nexterror();
		}
		h9_fs_notefd(fd, uif->path);
		h9_fs_allowfd(fd, op);
		if(mode & ORCLOSE)
			h9_fs_allowfd(fd, H9_FSREMOVE);
		poperror();
		uif->fd = fd;
	}
	else {
		m = fsomode(omode & 3);
		/* A truncation needs write access and must wait for the check. */
		if((mode & OTRUNC) && (m & O_ACCMODE) == O_RDONLY)
			m = (m & ~O_ACCMODE) | O_RDWR;
		if((fd = open(uif->path, m, 0666)) < 0)
			error(strerror(errno));
		if(waserror()){
			close(fd);
			nexterror();
		}
		h9_fs_notefd(fd, uif->path);
		h9_fs_allowfd(fd, op);
		if(mode & ORCLOSE)
			h9_fs_allowfd(fd, H9_FSREMOVE);
		if((mode & OTRUNC) && ftruncate(fd, 0) < 0)
			error(strerror(errno));
		poperror();
		uif->fd = fd;
	}
	uif->offset = 0;

	c->offset = 0;
	c->mode = omode;
	c->flag |= COPEN;
	return c;
}

static Chan*
fscreate(Chan *c, char *name, int mode, ulong perm)
{
	struct stat stbuf;
	Ufsinfo *uif;
	char *path;
	DIR *dir;
	int fd, dfd, omode;

	omode = openmode(mode & ~OEXCL);

	uif = c->aux;
	path = catpath(uif->path, name);
	if(waserror()){
		free(path);
		nexterror();
	}
	fd = -1;
	dir = NULL;
	/*
	 * h9: create relative to an fd for the parent directory, checked by the
	 * directory the fd actually is (h9_fs_allowfd). Check the new name's own
	 * slot before creating (h9_fs_allowat) and the created file by the file
	 * it actually is (h9_fs_allowfd) after, so a swapped parent component
	 * can't steer the create outside the policy, and a symlink left in place
	 * of the name can't hand back a write to a file outside it. A truncation
	 * waits for that check.
	 */
	dfd = open(uif->path, O_RDONLY|O_DIRECTORY);
	if(dfd < 0)
		error(strerror(errno));
	if(waserror()){
		close(dfd);
		nexterror();
	}
	h9_fs_notefd(dfd, uif->path);
	h9_fs_allowfd(dfd, H9_FSWALK);
	h9_fs_allowat(dfd, name, H9_FSCREATE);
	if(perm & DMDIR) {
		if(omode != OREAD)
			error(Eperm);
		if(mkdirat(dfd, name, uif->mode & perm & 0777) < 0){
			if(errno != EEXIST || mode & OEXCL)
				error(strerror(errno));
		}
		if((fd = openat(dfd, name, O_RDONLY|O_DIRECTORY)) < 0)
			error(strerror(errno));
		if(waserror()){
			close(fd);
			nexterror();
		}
		h9_fs_notefdat(fd, dfd, name);
		h9_fs_allowfd(fd, H9_FSCREATE);
		if((dir = fdopendir(fd)) == NULL)
			error(strerror(errno));
		poperror();
		/* dir now owns the fd; this isn't a file fd. */
		fd = -1;
		if(waserror()){
			closedir(dir);
			nexterror();
		}
		if(fstatat(dfd, name, &stbuf, 0) < 0)
			error(strerror(errno));
	}
	else {
		int m = omode & 3;
		/*
		 * POSIX specifies that O_TRUNC with O_RDONLY is undefined.
		 * OpenBSD chooses to return an error.
		 */
		m = fsomode(m == OREAD ? ORDWR : m) | O_CREAT;
		if(mode & OEXCL)
			m |= O_EXCL;
		if((fd = openat(dfd, name, m, uif->mode & perm & 0777)) < 0)
			error(strerror(errno));
		if(waserror()){
			close(fd);
			nexterror();
		}
		h9_fs_notefdat(fd, dfd, name);
		h9_fs_allowfd(fd, H9_FSCREATE);
		if(ftruncate(fd, 0) < 0)
			error(strerror(errno));
		if(fstat(fd, &stbuf) < 0)
			error(strerror(errno));
	}
#if defined(__wasi__)
	/* The parent's mode has no permission bits to inherit here. */
	wmodeset(&stbuf, perm & 0777);
#endif
	c->qid = fsqid(&stbuf);
	uif->fd = fd;
	uif->dir = dir;
	poperror();
	close(dfd);
	poperror();

	free(uif->path);
	uif->path = path;
	free(uif->lpath);
	uif->lpath = nil;
	uif->offset = 0;
	poperror();

	c->offset = 0;
	c->mode = omode;
	c->flag |= COPEN;
	return c;
}

static void
fsclose(Chan *c)
{
	Ufsinfo *uif;

	uif = c->aux;
	if(c->flag & COPEN) {
		if(c->qid.type & QTDIR)
			closedir(uif->dir);
		else
			close(uif->fd);
		c->flag &= ~COPEN;
		if(c->flag & CRCLOSE) {
			devtab[c->type]->remove(c);
			return;
		}
	}
	free(uif->path);
	free(uif->top);
	free(uif->lpath);
	free(uif);
}

static long
fsread(Chan *c, void *va, long n, vlong offset)
{
	int fd;
	vlong r;
	Ufsinfo *uif;

/*print("fsread %s\n", chanpath(c));*/
	if(c->qid.type & QTDIR)
		return fsdirread(c, va, n, offset);

	uif = c->aux;
	if(S_ISFIFO(uif->mode))
		return 0;	/* h9: see fsopen */
	qlock(&uif->oq);
	if(waserror()) {
		qunlock(&uif->oq);
		nexterror();
	}
	fd = uif->fd;
	if(uif->offset != offset) {
		r = lseek(fd, offset, 0);
		if(r < 0)
			error(strerror(errno));
		uif->offset = offset;
	}

	n = read(fd, va, n);
	if(n < 0)
		error(strerror(errno));

	uif->offset += n;
	qunlock(&uif->oq);
	poperror();

	return n;
}

static long
fswrite(Chan *c, void *va, long n, vlong offset)
{
	int fd;
	vlong r;
	Ufsinfo *uif;

	uif = c->aux;
	if(S_ISFIFO(uif->mode))
		error(Eperm);	/* h9: see fsopen */
	qlock(&uif->oq);
	if(waserror()) {
		qunlock(&uif->oq);
		nexterror();
	}
	fd = uif->fd;
	if(uif->offset != offset) {
		r = lseek(fd, offset, 0);
		if(r < 0)
			error(strerror(errno));
		uif->offset = offset;
	}

	n = write(fd, va, n);
	if(n < 0)
		error(strerror(errno));

	uif->offset += n;
	qunlock(&uif->oq);
	poperror();

	return n;
}

static void
fsremove(Chan *c)
{
	int n;
	Ufsinfo *uif;

	if(waserror()){
		fsclose(c);
		nexterror();
	}
	uif = c->aux;
	/*
	 * h9: remove the entry relative to an fd for its parent directory,
	 * checked (h9_fs_allowat) by that directory's own canonical path joined
	 * to the name, so a swapped parent component can't steer the unlink
	 * outside the policy. A link is removed, not its target.
	 */
	{
		char base[NAME_MAX+1];
		int dfd;

		dfd = h9_parentfd(ownpath(uif), base);
		if(waserror()){
			close(dfd);
			nexterror();
		}
		h9_fs_allowat(dfd, base, H9_FSREMOVE);
		n = unlinkat(dfd, base, (c->qid.type & QTDIR) ? AT_REMOVEDIR : 0);
		if(n < 0)
			error(strerror(errno));
		poperror();
		close(dfd);
	}
	poperror();
	fsclose(c);
}

int
fswstat(Chan *c, uchar *buf, int n)
{
	Dir d;
	struct stat stbuf;
	char strs[NAME_MAX*3];
	Ufsinfo *uif;

	/*
	 * wstat is supposed to be atomic.
	 * we check all the things we can before trying anything.
	 * still, if we are told to truncate a file and rename it and only
	 * one works, we're screwed.  in such cases we leave things
	 * half broken and return an error.  it's hardly perfect.
	 */
	struct stat fdst;
	int byfd, fl, opfd, wfd, trunc;

	if(convM2D(buf, n, &d, strs) != n)
		error(Ebadstat);

	uif = c->aux;
	/*
	 * h9: a wstat that changes nothing syncs the open file or directory
	 * (fsync(2) for Linux programs; a directory's makes a rename or a
	 * create in it durable).
	 */
	if(~d.mode == 0 && ~d.atime == 0 && ~d.mtime == 0 && (uvlong)d.length == (uvlong)~0 && d.name[0] == 0){
		fsflush(c);
		return n;
	}
	trunc = (uvlong)d.length != (uvlong)~0;
	/*
	 * h9: find the file to change and bind the metadata operations to it
	 * through a file descriptor, never by re-resolving its path. An open
	 * file may have been renamed since (Zig renames its cache entries into
	 * place, then truncates the output it still has open), so its path is
	 * stale: it is changed through its own fd. Otherwise the file is opened
	 * once and checked by the file the fd actually refers to (h9_fs_allowfd),
	 * then changed through that fd (fchmod/futimens/ftruncate), so a symlink
	 * swapped after the check can't redirect the change to a file outside the
	 * policy (the check-then-act race). A dangling link (danglingwalk) is
	 * checked and renamed as itself, and has no fd.
	 */
	byfd = 0;
	opfd = -1;
	wfd = -1;
	if(openfile(c) && fstat(uif->fd, &fdst) == 0
	&& (stat(uif->path, &stbuf) < 0 || stbuf.st_dev != fdst.st_dev || stbuf.st_ino != fdst.st_ino)){
		fl = fcntl(uif->fd, F_GETFL);
		if(fl < 0 || (fl & O_ACCMODE) == O_RDONLY || d.name[0] != 0)
			error(strerror(ENOENT));
		byfd = 1;
		wfd = uif->fd;
		stbuf = fdst;
	}else if(stat(uif->path, &stbuf) < 0){
		if(lstat(ownpath(uif), &stbuf) < 0 || !S_ISLNK(stbuf.st_mode))
			error(strerror(errno));
		if(h9_fs_checkname(ownpath(uif), H9_FSWRITE) < 0)
			error(Eperm);
	}else{
		/* Truncation needs write access; it waits for the check below. */
		if((opfd = open(uif->path, trunc ? O_RDWR : O_RDONLY)) < 0)
			error(strerror(errno));
		wfd = opfd;
	}
	if(waserror()){
		if(opfd >= 0)
			close(opfd);
		nexterror();
	}
	if(opfd >= 0){
		h9_fs_notefd(opfd, uif->path);
		h9_fs_allowfd(opfd, H9_FSWRITE);
		if(fstat(opfd, &stbuf) < 0)
			error(strerror(errno));
	}

	/*
	 * try things in increasing order of harm to the file.
	 * mtime should come after truncate so that if you
	 * do both the mtime actually takes effect, but i'd rather
	 * leave truncate until last.
	 * (see above comment about atomicity).
	 */
	if(~d.mode != 0 && (int)(d.mode&0777) != STMODE(&stbuf)) {
		if(wfd < 0)
			error(strerror(ENOENT));
#if defined(__wasi__)
		wmodeset(&stbuf, d.mode);
#else
		if(fchmod(wfd, d.mode&0777) < 0)
			error(strerror(errno));
#endif
		uif->mode &= ~0777;
		uif->mode |= d.mode&0777;
	}
	if(~d.atime != 0 || ~d.mtime != 0){
		/* h9: futimens, which every libc h9 builds with has. */
		struct timespec ts[2];
		if(wfd < 0)
			error(strerror(ENOENT));
		ts[0].tv_sec = ~d.atime != 0 ? d.atime : stbuf.st_atime;
		ts[0].tv_nsec = 0;
		ts[1].tv_sec = ~d.mtime != 0 ? d.mtime : stbuf.st_mtime;
		ts[1].tv_nsec = 0;
		futimens(wfd, ts);
	}
	if(d.name[0] && strcmp(d.name, lastelem(ownpath(uif))) != 0) {
		char base[NAME_MAX+1];
		char *dirpath, *newpath;
		int dfd;

		/*
		 * h9: a link is renamed, not its target. Rename relative to an fd
		 * for the (shared) parent directory, checked by that directory's
		 * own canonical path (h9_fs_allowat), so a swapped parent component
		 * can't steer the rename outside the policy.
		 */
		dfd = h9_parentfd(ownpath(uif), base);
		if(waserror()){
			close(dfd);
			nexterror();
		}
		h9_fs_allowat(dfd, d.name, H9_FSCREATE);
		h9_fs_allowat(dfd, base, H9_FSRENAME);
		if(fstatat(dfd, d.name, &stbuf, AT_SYMLINK_NOFOLLOW) >= 0)
			error(Eexist);
		if(renameat(dfd, base, dfd, d.name) < 0)
			error(strerror(errno));
		poperror();
		close(dfd);

		dirpath = strdup(ownpath(uif));
		*lastelem(dirpath) = 0;
		newpath = catpath(dirpath, d.name);
		free(dirpath);
		if(uif->lpath != nil){
			free(uif->lpath);
			uif->lpath = newpath;
		}else{
			free(uif->path);
			uif->path = newpath;
		}
	}

/*
	p = name2pass(gid, d.gid);
	if(p == 0)
		error(Eunknown);

	if(p->id != stbuf.st_gid) {
		if(chown(old, stbuf.st_uid, p->id) < 0)
			error(strerror(errno));

		uif->gid = p->id;
	}
*/

	if(trunc){
		if(wfd < 0)
			error(strerror(ENOENT));
		if(ftruncate(wfd, d.length) < 0)
			error(strerror(errno));
	}

	poperror();
	if(opfd >= 0)
		close(opfd);
	return n;
}

static Qid
fsqid(struct stat *st)
{
	Qid q;

	q.type = 0;
	if((st->st_mode&S_IFMT) ==  S_IFDIR)
		q.type = QTDIR;

	q.path = (uvlong)st->st_dev<<32 | st->st_ino;
	q.vers = st->st_mtime;

	return q;
}

static char*
catpath(char *base, char *ext)
{
	char *path;
	int n, m;

	n = strlen(base);
	m = strlen(ext);
	path = malloc(n+m+2);
	memmove(path, base, n);
	if(n > 0 && path[n-1] != '/')
		path[n++] = '/';
	memmove(path+n, ext, m+1);
	return path;
}

static int
isdots(char *name)
{
	if(name[0] != '.')
		return 0;
	if(name[1] == '\0')
		return 1;
	if(name[1] != '.')
		return 0;
	if(name[2] == '\0')
		return 1;
	return 0;
}

static int
p9readdir(char *name, Ufsinfo *uif)
{
	struct dirent *de;
	
	if(uif->nextname[0]){
		strcpy(name, uif->nextname);
		uif->nextname[0] = 0;
		return 1;
	}

	de = readdir(uif->dir);
	if(de == NULL)
		return 0;
		
	strcpy(name, de->d_name);
	return 1;
}

static ulong
fsdirread(Chan *c, uchar *va, int count, ulong offset)
{
	int i;
	Dir d;
	long n;
	char de[NAME_MAX];
	struct stat stbuf;
	Ufsinfo *uif;

/*print("fsdirread %s\n", chanpath(c));*/
	i = 0;
	uif = c->aux;

	errno = 0;
	if(uif->offset != offset) {
		if(offset != 0)
			error("bad offset in fsdirread");
		uif->offset = offset;  /* sync offset */
		uif->nextname[0] = 0;
		rewinddir(uif->dir);
	}

	while(i+BIT16SZ < count) {
		char *p;

		if(!p9readdir(de, uif))
			break;

		if(de[0]==0 || isdots(de))
			continue;

		d.name = de;
		/*
		 * h9: in a contained tree, an entry is listed as its walk
		 * resolves it, and a link whose target is missing isn't.
		 */
		if(uif->top != nil){
			char buf[PATH_MAX];

			if(h9_fs_resolvein(uif->top, uif->path, de, buf, sizeof buf) < 0)
				continue;
			p = strdup(buf);
		}else
			p = catpath(uif->path, de);
		if(h9_fs_check(p, H9_FSWALK) < 0){
			free(p);
			continue;
		}
		if(stat(p, &stbuf) < 0) {
			if(uif->top != nil){
				free(p);
				continue;
			}
			/* fprint(2, "dir: bad path %s\n", path); */
			/* but continue... probably a bad symlink */
			memset(&stbuf, 0, sizeof stbuf);
		}
		free(p);

		d.uid = eve;
		d.gid = eve;
		d.muid = eve;
		d.qid = fsqid(&stbuf);
		d.mode = (d.qid.type<<24)|STMODE(&stbuf);
		if(S_ISFIFO(stbuf.st_mode))
			d.mode |= H9_DMFIFO;	/* h9 */
		d.atime = stbuf.st_atime;
		d.mtime = stbuf.st_mtime;
		d.length = stbuf.st_size;
		d.type = 'U';
		d.dev = c->dev;
		n = convD2M(&d, (uchar*)va+i, count-i);
		if(n == BIT16SZ){
			strcpy(uif->nextname, de);
			break;
		}
		i += n;
	}
/*print("got %d\n", i);*/
	uif->offset += i;
	return i;
}

/*
 * h9: called by namec once a walk from a #U attach is done. A contained
 * attach's tree is where the walk ended, canonical.
 */
void
h9_fs_anchor(Chan *c)
{
	char buf[PATH_MAX];
	Ufsinfo *uif;

	uif = c->aux;
	if(!uif->contained || uif->top != nil)
		return;
	if(realpath(uif->path, buf) == nil)
		error(strerror(errno));
	uif->top = strdup(buf);
	free(uif->path);
	uif->path = strdup(buf);
	free(uif->lpath);
	uif->lpath = nil;
}

/* h9: the target of the link c's last name was, as it's written. */
int
h9_fs_readlink(Chan *c, char *buf, int nbuf)
{
	struct stat st;
	Ufsinfo *uif;
	char *p;
	int n;

	if(devtab[c->type]->dc != 'U' || nbuf <= 0)
		return -1;
	uif = c->aux;
	p = ownpath(uif);
	if(h9_fs_checkname(p, H9_FSWALK) < 0 || lstat(p, &st) < 0 || !S_ISLNK(st.st_mode))
		return -1;
	n = readlink(p, buf, nbuf-1);
	if(n < 0)
		return -1;
	buf[n] = 0;
	return n;
}

/*
 * h9: makes name in the directory c a symbolic link to target, for the
 * Linux personality's symlinkat. The new name is checked like a create;
 * the target is checked whenever a walk follows the link.
 */
void
h9_fs_symlink(Chan *c, char *name, char *target)
{
	Ufsinfo *uif;
	int dfd;

	if(devtab[c->type]->dc != 'U')
		error(Eperm);
	uif = c->aux;
	/*
	 * h9: create the link relative to an fd for the directory, checked by
	 * the directory the fd actually refers to (h9_fs_allowfd) and the new
	 * name's own slot (h9_fs_allowat), so a swapped parent component can't
	 * steer the create outside the policy.
	 */
	dfd = open(uif->path, O_RDONLY|O_DIRECTORY);
	if(dfd < 0)
		error(strerror(errno));
	if(waserror()){
		close(dfd);
		nexterror();
	}
	h9_fs_notefd(dfd, uif->path);
	h9_fs_allowfd(dfd, H9_FSWALK);
	h9_fs_allowat(dfd, name, H9_FSCREATE);
	if(symlinkat(target, dfd, name) < 0)
		error(strerror(errno));
	poperror();
	close(dfd);
}

/*
 * h9: makes name in the directory c a FIFO, for the Linux personality's
 * mknodat (design/linux-fifo.md). The new name is checked like a create.
 */
void
h9_fs_mkfifo(Chan *c, char *name, ulong perm)
{
#ifdef __wasi__
	USED(c);
	USED(name);
	USED(perm);
	error(Eperm);
#else
	Ufsinfo *uif;
	int dfd;

	if(devtab[c->type]->dc != 'U')
		error(Eperm);
	uif = c->aux;
	dfd = open(uif->path, O_RDONLY|O_DIRECTORY);
	if(dfd < 0)
		error(strerror(errno));
	if(waserror()){
		close(dfd);
		nexterror();
	}
	h9_fs_notefd(dfd, uif->path);
	h9_fs_allowfd(dfd, H9_FSWALK);
	h9_fs_allowat(dfd, name, H9_FSCREATE);
	if(mkfifoat(dfd, name, perm & 0777) < 0)
		error(strerror(errno));
	poperror();
	close(dfd);
#endif
}

/* h9: whether the devfs chan c is a host FIFO's */
int
h9_fs_isfifo(Chan *c)
{
	if(devtab[c->type]->dc != 'U')
		return 0;
	return S_ISFIFO(((Ufsinfo*)c->aux)->mode);
}

/* h9: c moved to name in directory dir, for renameat across directories */
int
h9_fs_rename(Chan *c, Chan *dir, char *name)
{
	Ufsinfo *uif, *duif;
	char base[NAME_MAX+1];
	int sdfd, ddfd;

	if(devtab[c->type]->dc != 'U' || devtab[dir->type]->dc != 'U')
		error(Eperm);
	uif = c->aux;
	duif = dir->aux;
	if(strlen(name) > NAME_MAX)
		error(strerror(ENAMETOOLONG));
	/*
	 * h9: rename relative to fds for the source and destination parent
	 * directories, each checked by the directory the fd actually refers to
	 * (h9_fs_allowfd/allowat), so a swapped parent component can't steer the
	 * rename outside the policy. The source link is moved, not its target.
	 */
	sdfd = h9_parentfd(ownpath(uif), base);
	if(waserror()){
		close(sdfd);
		nexterror();
	}
	if((ddfd = open(duif->path, O_RDONLY|O_DIRECTORY)) < 0)
		error(strerror(errno));
	if(waserror()){
		close(ddfd);
		nexterror();
	}
	h9_fs_notefd(ddfd, duif->path);
	h9_fs_allowfd(ddfd, H9_FSWALK);
	h9_fs_allowat(ddfd, name, H9_FSCREATE);
	h9_fs_allowat(sdfd, base, H9_FSRENAME);
	if(renameat(sdfd, base, ddfd, name) < 0)
		error(strerror(errno));
	poperror();
	close(ddfd);
	poperror();
	close(sdfd);
	return 0;
}

/*
 * h9: the host fd of an open file or directory, or -1. uif->fd is 0
 * until a file is opened, and a directory's is never set: its DIR is.
 */
static int
fshostfd(Chan *c)
{
	Ufsinfo *uif;

	uif = c->aux;
	if((c->flag & COPEN) == 0)
		return -1;
	if(c->qid.type & QTDIR)
		return uif->dir != NULL ? dirfd(uif->dir) : -1;
	return uif->fd;
}

/*
 * h9: syncs an open file or directory to the host's disk. On macOS
 * fsync(2) leaves the data in the drive's cache; F_FULLFSYNC flushes
 * it, and fsync stands in where the file system can't. Hosts that can't
 * sync a directory say EINVAL (or EBADF for one opened read-only), as
 * PostgreSQL's fsync_fname allows for.
 */
static void
fsflush(Chan *c)
{
	int fd;

	if((fd = fshostfd(c)) < 0)
		return;
#ifdef F_FULLFSYNC
	if(fcntl(fd, F_FULLFSYNC) == 0)
		return;
#endif
	if(fsync(fd) < 0 && errno != EINVAL && !(errno == EBADF && (c->qid.type & QTDIR)))
		error(strerror(errno));
}

#if defined(__linux__)
extern int syncfs(int);
#endif

/*
 * h9: syncfs(2) on the open devfs chan c: Linux's syncfs on the host
 * file system it's on. Elsewhere, sync(2) and then the file's own sync,
 * which on macOS (F_FULLFSYNC) also flushes the drive's cache; the web
 * host has only the file's.
 */
void
h9_fs_syncfs(Chan *c)
{
	int fd;

	if(devtab[c->type]->dc != 'U' || (fd = fshostfd(c)) < 0)
		return;
#if defined(__linux__)
	if(syncfs(fd) < 0)
		error(strerror(errno));
#else
#if !defined(__wasi__)
	sync();
#endif
	fsflush(c);
#endif
}

/* h9: sync(2): every host file system (none on the web host). */
void
h9_fs_sync(void)
{
#if !defined(__wasi__)
	sync();
#endif
}

static int
fsomode(int m)
{
	switch(m) {
	case OREAD:
	case OEXEC:
		return O_RDONLY;
	case OWRITE:
		return O_WRONLY;
	case ORDWR:
		return O_RDWR;
	}
	error(Ebadarg);
	return 0;
}

Dev fsdevtab = {
	'U',
	"fs",

	devreset,
	devinit,
	devshutdown,
	fsattach,
	fswalk,
	fsstat,
	fsopen,
	fscreate,
	fsclose,
	fsread,
	devbread,
	fswrite,
	devbwrite,
	fsremove,
	fswstat,
};
