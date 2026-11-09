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
	d.mode = (c->qid.type<<24)|(stbuf.st_mode&0777);
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
	int omode;

	omode = openmode(mode);

	uif = c->aux;
	/* h9: a link walked to as itself has no target to open (danglingwalk). */
	if(S_ISLNK(uif->mode))
		error(Enonexist);
	h9_fs_allow(uif->path, omode == OREAD && !(mode&OTRUNC) ? H9_FSREAD : H9_FSWRITE);
	if(mode & ORCLOSE)
		h9_fs_allow(uif->path, H9_FSREMOVE);
	if(c->qid.type & QTDIR) {
		if(omode != OREAD)
			error(Eperm);
		if((uif->dir = opendir(uif->path)) == NULL)
			error(strerror(errno));
	}	
	else {
		int m = fsomode(omode & 3);
		if(mode & OTRUNC)
			m |= O_TRUNC;
		if((uif->fd = open(uif->path, m, 0666)) < 0)
			error(strerror(errno));
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
	int fd, omode;

	omode = openmode(mode & ~OEXCL);

	uif = c->aux;
	path = catpath(uif->path, name);
	if(waserror()){
		free(path);
		nexterror();
	}
	fd = -1;
	dir = NULL;
	h9_fs_allow(path, H9_FSCREATE);
	if(perm & DMDIR) {
		if(omode != OREAD)
			error(Eperm);
		if(mkdir(path, uif->mode & perm & 0777) < 0){
			if(errno != EEXIST || mode & OEXCL)
				error(strerror(errno));
		}
		if((dir = opendir(path)) == NULL)
			error(strerror(errno));
		if(waserror()){
			closedir(dir);
			nexterror();
		}
	}
	else {
		int m = omode & 3;
		/*
		 * POSIX specifies that O_TRUNC with O_RDONLY is undefined.
		 * OpenBSD chooses to return an error.
		 */
		m = fsomode(m == OREAD ? ORDWR : m) | O_CREAT | O_TRUNC;
		if(mode & OEXCL)
			m |= O_EXCL;
		if((fd = open(path, m, uif->mode & perm & 0777)) < 0)
			error(strerror(errno));
		if(waserror()){
			close(fd);
			nexterror();
		}
	}
	if(stat(path, &stbuf) < 0)
		error(strerror(errno));
	c->qid = fsqid(&stbuf);
	uif->fd = fd;
	uif->dir = dir;
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
	/* h9: a link is removed, not its target. */
	h9_fs_allow(ownpath(uif), H9_FSREMOVE);
	if(uif->lpath != nil)
		n = unlink(uif->lpath);
	else if(c->qid.type & QTDIR)
		n = rmdir(uif->path);
	else
		n = remove(uif->path);
	if(n < 0)
		error(strerror(errno));
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
	int byfd, fl;

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
	/*
	 * h9: an open file may have been renamed since (Zig renames its
	 * cache entries into place, then truncates the output it still has
	 * open), so its path is stale: one open for writing is changed
	 * through its fd, as Linux's ftruncate and fchmod change the file.
	 */
	byfd = 0;
	if(openfile(c) && fstat(uif->fd, &fdst) == 0
	&& (stat(uif->path, &stbuf) < 0 || stbuf.st_dev != fdst.st_dev || stbuf.st_ino != fdst.st_ino)){
		fl = fcntl(uif->fd, F_GETFL);
		if(fl < 0 || (fl & O_ACCMODE) == O_RDONLY || d.name[0] != 0)
			error(strerror(ENOENT));
		byfd = 1;
		stbuf = fdst;
	}else if(stat(uif->path, &stbuf) < 0){
		/* h9: a dangling link (danglingwalk) is checked and renamed as itself */
		if(lstat(ownpath(uif), &stbuf) < 0 || !S_ISLNK(stbuf.st_mode))
			error(strerror(errno));
		if(h9_fs_checkname(ownpath(uif), H9_FSWRITE) < 0)
			error(Eperm);
	}else
		h9_fs_allow(uif->path, H9_FSWRITE);

	/*
	 * try things in increasing order of harm to the file.
	 * mtime should come after truncate so that if you
	 * do both the mtime actually takes effect, but i'd rather
	 * leave truncate until last.
	 * (see above comment about atomicity).
	 */
	if(~d.mode != 0 && (int)(d.mode&0777) != (int)(stbuf.st_mode&0777)) {
		if((byfd ? fchmod(uif->fd, d.mode&0777) : chmod(uif->path, d.mode&0777)) < 0)
			error(strerror(errno));
		uif->mode &= ~0777;
		uif->mode |= d.mode&0777;
	}
	if(~d.atime != 0 || ~d.mtime != 0){
		struct timeval t[2];
		t[0].tv_sec = ~d.atime != 0 ? d.atime : stbuf.st_atime;
		t[0].tv_usec = 0;
		t[1].tv_sec = ~d.mtime != 0 ? d.mtime : stbuf.st_mtime;
		t[1].tv_usec = 0;
		if(byfd){
			/* h9: futimens, which every libc h9 builds with has. */
			struct timespec ts[2];
			ts[0].tv_sec = t[0].tv_sec;
			ts[0].tv_nsec = 0;
			ts[1].tv_sec = t[1].tv_sec;
			ts[1].tv_nsec = 0;
			futimens(uif->fd, ts);
		}else
			utimes(uif->path, t);
	}
	if(d.name[0] && strcmp(d.name, lastelem(ownpath(uif))) != 0) {
		char *base, *newpath;

		/* h9: a link is renamed, not its target. */
		base = strdup(ownpath(uif));
		*lastelem(base) = 0;
		newpath = catpath(base, d.name);
		free(base);
		if(waserror()){
			free(newpath);
			nexterror();
		}
		h9_fs_allow(newpath, H9_FSCREATE);
		h9_fs_allow(ownpath(uif), H9_FSRENAME);
		if(lstat(newpath, &stbuf) >= 0)
			error(Eexist);
		if(rename(ownpath(uif), newpath) < 0)
			error(strerror(errno));
		if(uif->lpath != nil){
			free(uif->lpath);
			uif->lpath = newpath;
		}else{
			free(uif->path);
			uif->path = newpath;
		}
		poperror();
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

	if((uvlong)d.length != (uvlong)~0 && (byfd ? ftruncate(uif->fd, d.length) : truncate(uif->path, d.length)) < 0)
		error(strerror(errno));

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
		d.mode = (d.qid.type<<24)|(stbuf.st_mode&0777);
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
	char *path;

	if(devtab[c->type]->dc != 'U')
		error(Eperm);
	uif = c->aux;
	path = catpath(uif->path, name);
	if(waserror()){
		free(path);
		nexterror();
	}
	h9_fs_allow(path, H9_FSCREATE);
	if(symlink(target, path) < 0)
		error(strerror(errno));
	poperror();
	free(path);
}

/* h9: c moved to name in directory dir, for renameat across directories */
int
h9_fs_rename(Chan *c, Chan *dir, char *name)
{
	Ufsinfo *uif, *duif;
	char *newpath;

	if(devtab[c->type]->dc != 'U' || devtab[dir->type]->dc != 'U')
		error(Eperm);
	uif = c->aux;
	duif = dir->aux;
	newpath = catpath(duif->path, name);
	if(waserror()){
		free(newpath);
		nexterror();
	}
	h9_fs_allow(newpath, H9_FSCREATE);
	h9_fs_allow(ownpath(uif), H9_FSRENAME);
	if(rename(ownpath(uif), newpath) < 0)
		error(strerror(errno));
	poperror();
	free(newpath);
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
