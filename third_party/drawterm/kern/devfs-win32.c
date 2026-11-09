#include	<windows.h>
#include	<sys/types.h>
#include	<sys/stat.h>
#include	<fcntl.h>

#include	"u.h"
#include	"lib.h"
#include	"dat.h"
#include	"fns.h"
#include	"error.h"

#include	<libsec.h>	/* for sha1 in pathhash() */
#include	"fscheck.h"	/* h9: sandbox hooks */

typedef struct DIR	DIR;
typedef	struct Ufsinfo	Ufsinfo;

enum
{
	TPATH_ROOT	= 0,	// ""
	TPATH_VOLUME	= 1,	// "C:"
	TPATH_FILE	= 2,	// "C:\bla"
};

struct DIR
{
	// for FindFileFirst()
	HANDLE		handle;
	WIN32_FIND_DATA	wfd;

	// for GetLogicalDriveStrings()
	wchar_t		*drivebuf;
	wchar_t		*drivep;

	// dont move to the next item
	int		keep;
};

struct Ufsinfo
{
	int	mode;
	HANDLE	fh;
	DIR*	dir;
	vlong	offset;
	QLock	oq;
	wchar_t	*path;
	/*
	 * h9: a contained attach (#U!c, design/0034-symlinks-in-root.md)
	 * resolves links inside top once namec's walk has set it
	 * (h9_fs_anchor). path is then always resolved, and lpath, if set,
	 * is the link the last name was, in its resolved directory.
	 */
	int	contained;
	wchar_t	*top;
	wchar_t	*lpath;
};

/* h9: the chan's own name on the host: the link, not its target. */
static wchar_t*
ownpath(Ufsinfo *uif)
{
	return uif->lpath != nil ? uif->lpath : uif->path;
}

static	wchar_t *catpath(wchar_t *, char *, wchar_t *);
static	ulong	fsdirread(Chan*, uchar*, int, vlong);
static	ulong	fsaccess(int);
static	ulong	pathtype(wchar_t *);
static	int	checkvolume(wchar_t *);

static ulong
unixtime(FILETIME *ft)
{
	vlong t;
	t = ((vlong)ft->dwHighDateTime << 32)|((vlong)ft->dwLowDateTime);
	t -= 116444736000000000LL;
	return ((t<0)?(-1 - (-t - 1)) : t)/10000000;
}

static FILETIME
filetime(ulong ut)
{
	FILETIME ft;
	vlong t = (vlong)ut * 10000000LL;
	t += 116444736000000000LL;
	ft.dwLowDateTime = t;
	ft.dwHighDateTime = t >> 32;
	return ft;
}

static uvlong
pathhash(wchar_t *p)
{
	uchar digest[SHA1dlen];
	sha1((uchar*)p, wcslen(p)*sizeof(wchar_t), digest, nil);
	return *(uvlong*)digest;
}

static ulong
wfdtodmode(WIN32_FIND_DATA *wfd)
{
	int m;
	m = DMREAD|DMWRITE|DMEXEC;
	if(wfd->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
		m |= DMDIR;
	if(wfd->dwFileAttributes & FILE_ATTRIBUTE_READONLY)
		m &= ~DMWRITE;
	/*
	 * h9: owner bits only (0700, 0600, 0500). Windows has no group or
	 * other bits, and Postgres refuses a data directory that reads as
	 * group- or world-writable.
	 */
	m = (m & 07)<<6 | (m & ~0777);
	return m;
}

static Qid
wfdtoqid(wchar_t *path, WIN32_FIND_DATA *wfd)
{
	ulong t;
	WIN32_FIND_DATA f;
	Qid q;

	t = pathtype(path);
	switch(t){
	case TPATH_VOLUME:
	case TPATH_ROOT:
		q.type = QTDIR;
		q.path = pathhash(path);
		q.vers = 0;
		break;

	case TPATH_FILE:
		if(!wfd){
			HANDLE h;
			if((h = FindFirstFile(path, &f))==INVALID_HANDLE_VALUE)
				oserror();
			FindClose(h);
			wfd = &f;
		}
		q.type = (wfd->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? QTDIR : QTFILE;
		q.path = pathhash(path);
		q.vers = unixtime(&wfd->ftLastWriteTime);
		break;
	}
	return q;
}

static void
wfdtodir(wchar_t *path, Dir *d, WIN32_FIND_DATA *wfd)
{
	extern ulong kerndate;
	WIN32_FIND_DATA f;

	switch(pathtype(path)){
	case TPATH_VOLUME:
	case TPATH_ROOT:
		wfd = nil;
		d->mode = 0777 | DMDIR;
		d->atime = seconds();
		d->mtime = kerndate;
		d->length = 0;
		break;

	case TPATH_FILE:
		if(wfd == nil){
			HANDLE h;
			WIN32_FILE_ATTRIBUTE_DATA fa;
			if((h = FindFirstFile(path, &f))==INVALID_HANDLE_VALUE)
				oserror();
			FindClose(h);
			/*
			 * h9: FindFirstFile reads the directory entry, whose size and
			 * times NTFS updates lazily while another handle writes, so a
			 * stat right after a write could see the old size.
			 * GetFileAttributesEx reads the file's own record.
			 */
			if(GetFileAttributesExW(path, GetFileExInfoStandard, &fa)){
				f.dwFileAttributes = fa.dwFileAttributes;
				f.ftLastAccessTime = fa.ftLastAccessTime;
				f.ftLastWriteTime = fa.ftLastWriteTime;
				f.nFileSizeHigh = fa.nFileSizeHigh;
				f.nFileSizeLow = fa.nFileSizeLow;
			}
			wfd = &f;
		}
		d->mode		= wfdtodmode(wfd);
		d->atime	= unixtime(&wfd->ftLastAccessTime);
		d->mtime	= unixtime(&wfd->ftLastWriteTime);
		d->length	= ((uvlong)wfd->nFileSizeHigh << 32)|((uvlong)wfd->nFileSizeLow);
		break;
	}
	d->qid = wfdtoqid(path, wfd);
	d->uid = eve;
	d->gid = eve;
	d->muid = eve;
}

static char*
lastelem(Chan *c)
{
	char *s, *t;

	s = chanpath(c);
	if((t = strrchr(s, '/')) == nil)
		return s;
	if(t[1] == 0)
		return t;
	return t+1;
}

static ulong
pathtype(wchar_t *path)
{
	if(path[0] == 0 || path[1] == 0)
		return TPATH_ROOT;
	if(path[1] == ':' && path[2] == 0)
		return TPATH_VOLUME;
	return TPATH_FILE;
}

static int
checkvolume(wchar_t *path)
{
	wchar_t vol[MAX_PATH];
	wchar_t volname[MAX_PATH];
	wchar_t fsysname[MAX_PATH];
	DWORD complen;
	DWORD flags;

	wcscpy(vol, path);
	wcscat(vol, L"\\");
	if(!GetVolumeInformation(
		vol,
		volname,
		MAX_PATH,
		NULL,
		&complen,
		&flags,
		fsysname,
		MAX_PATH))
		return 0;

	return 1;	
}

static wchar_t*
wstrdup(wchar_t *s)
{
	wchar_t *d;
	long n;

	n = (wcslen(s)+1)*sizeof(wchar_t);
	d = mallocz(n, 0);
	memmove(d, s, n);
	return d;
}
	
static Chan*
fsattach(char *spec)
{
	static int devno;
	Ufsinfo *uif;
	Chan *c;
	int contained;

	/* h9: the only spec is !c, a contained tree. */
	contained = 0;
	if(spec != nil && spec[0] != 0){
		if(strcmp(spec, "!c") != 0)
			error(Ebadspec);
		contained = 1;
	}
	uif = mallocz(sizeof(Ufsinfo), 1);
	uif->path = wstrdup(L"");
	uif->contained = contained;

	c = devattach('U', spec);
	c->aux = uif;
	c->dev = devno++;
	c->qid.type = QTDIR;

	return c;
}

static Chan*
fsclone(Chan *c, Chan *nc)
{
	Ufsinfo *uif;

	uif = mallocz(sizeof(Ufsinfo), 1);
	*uif = *(Ufsinfo*)c->aux;
	uif->path = wstrdup(uif->path);
	if(uif->top != nil)
		uif->top = wstrdup(uif->top);
	if(uif->lpath != nil)
		uif->lpath = wstrdup(uif->lpath);
	nc->aux = uif;

	return nc;
}

/*
 * h9: a walk in a contained tree, resolved by fscheck.c inside it.
 * Returns 1, 0 if name doesn't exist, or -1 for too many links.
 */
static int
fswalkin(Chan *c, char *name)
{
	wchar_t buf[MAX_PATH*4], *lpath;
	WIN32_FIND_DATA wfd;
	Ufsinfo *uif;
	HANDLE h;
	int r;

	uif = c->aux;
	r = h9_fs_resolveinw(uif->top, uif->path, name, buf, nelem(buf));
	if(r == H9_RESLOOP)
		return -1;
	if(r < 0 || h9_fs_checkw(buf, H9_FSWALK) < 0)
		return 0;
	if(pathtype(buf) == TPATH_FILE){
		if((h = FindFirstFile(buf, &wfd)) == INVALID_HANDLE_VALUE)
			return 0;
		FindClose(h);
		c->qid = wfdtoqid(buf, &wfd);
	}else
		c->qid = wfdtoqid(buf, nil);
	lpath = nil;
	if(strcmp(name, "..") != 0){
		lpath = catpath(uif->path, name, nil);
		if(wcscmp(lpath, buf) == 0){
			free(lpath);
			lpath = nil;
		}
	}
	free(uif->path);
	uif->path = wstrdup(buf);
	free(uif->lpath);
	uif->lpath = lpath;
	return 1;
}

static int
fswalk1(Chan *c, char *name)
{
	WIN32_FIND_DATA wfd;
	HANDLE h;
	wchar_t *p;
	Ufsinfo *uif;
	
	uif = c->aux;
	if(uif->top != nil)
		return fswalkin(c, name);
	p = catpath(uif->path, name, nil);
	if(h9_fs_checkw(p, H9_FSWALK) < 0){
		free(p);
		return 0;
	}
	switch(pathtype(p)){
	case TPATH_VOLUME:
		if(!checkvolume(p)){
			free(p);
			return 0;
		}
	case TPATH_ROOT:
		c->qid = wfdtoqid(p, nil);
		break;

	case TPATH_FILE:
		if((h = FindFirstFile(p, &wfd)) == INVALID_HANDLE_VALUE){
			free(p);
			return 0;
		}
		FindClose(h);
		c->qid = wfdtoqid(p, &wfd);
		break;
	}
	free(uif->path);
	uif->path = p;
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
	
static int
fsstat(Chan *c, uchar *buf, int n)
{
	Dir d;
	Ufsinfo *uif;

	if(n < BIT16SZ)
		error(Eshortstat);
	uif = c->aux;
	d.name = lastelem(c);
	wfdtodir(uif->path, &d, nil);
	d.type = 'U';
	d.dev = c->dev;
	return convD2M(&d, buf, n);
}

static Chan*
fsopen(Chan *c, int mode)
{
	wchar_t *p;
	Ufsinfo *uif;
	int omode, op;

	omode = openmode(mode);

	uif = c->aux;
	op = omode == OREAD && !(mode&OTRUNC) ? H9_FSREAD : H9_FSWRITE;
	if(c->qid.type & QTDIR){
		DIR *d;

		/* A directory is listed by search, not a handle, so check its path. */
		h9_fs_allow(uif->path, op);
		if(mode & ORCLOSE)
			h9_fs_allow(uif->path, H9_FSREMOVE);
		if(omode != OREAD)
			error(Eperm);
		d = malloc(sizeof(*d));
		if(waserror()){
			free(d);
			nexterror();
		}
		switch(pathtype(uif->path)){
		case TPATH_ROOT:
			d->drivebuf = malloc(sizeof(wchar_t)*MAX_PATH);
			if(GetLogicalDriveStrings(MAX_PATH-1, d->drivebuf) == 0){
				free(d->drivebuf);
				d->drivebuf = nil;
				oserror();
			}
			d->drivep = d->drivebuf;
			break;
		case TPATH_VOLUME:
		case TPATH_FILE:
			p = catpath(uif->path, "*.*", nil);
			if((d->handle = FindFirstFile(p, &d->wfd)) == INVALID_HANDLE_VALUE){
				free(p);
				oserror();
			}
			free(p);
			break;
		}
		d->keep = 1;
		uif->dir = d;
		poperror();
	} else {
		DWORD access;

		uif->dir = NULL;
		/* FILE_READ_ATTRIBUTES so GetFinalPathNameByHandle works on a
		 * write-only open (the handle check needs it). */
		access = fsaccess(omode & 3) | FILE_READ_ATTRIBUTES;
		/* A truncation needs write access and must wait for the check. */
		if(mode & OTRUNC)
			access |= GENERIC_WRITE;
		/*
		 * h9: open first, then check the file the handle actually refers to
		 * (h9_fs_allowhandlew, via GetFinalPathNameByHandle), rather than
		 * checking uif->path and opening it as two separate resolutions. The
		 * open follows links as before, but the truncation is withheld
		 * (OPEN_EXISTING, then SetEndOfFile) until the check passes, so a
		 * denied file keeps its contents.
		 */
		if((uif->fh = CreateFile(
			uif->path,
			access,
			FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,	/* h9: as POSIX, a file can be removed while open */
			NULL,
			OPEN_EXISTING,
			FILE_ATTRIBUTE_NORMAL,
			0)) == INVALID_HANDLE_VALUE)
			oserror();
		if(waserror()){
			CloseHandle(uif->fh);
			uif->fh = INVALID_HANDLE_VALUE;
			nexterror();
		}
		h9_fs_allowhandlew(uif->fh, op);
		if(mode & ORCLOSE)
			h9_fs_allowhandlew(uif->fh, H9_FSREMOVE);
		if(mode & OTRUNC){
			if(SetFilePointer(uif->fh, 0, NULL, FILE_BEGIN) == INVALID_SET_FILE_POINTER
			|| !SetEndOfFile(uif->fh))
				oserror();
		}
		poperror();
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
	wchar_t *newpath;
	Ufsinfo *uif;
	DIR *d;
	HANDLE h;
	int omode;

	omode = openmode(mode & ~OEXCL);

	uif = c->aux;
	newpath = catpath(uif->path, name, nil);
	if(waserror()){
		free(newpath);
		nexterror();
	}
	d = NULL;
	h = INVALID_HANDLE_VALUE;
	h9_fs_allow(newpath, H9_FSCREATE);
	if(perm & DMDIR) {
		wchar_t *p;

		if(omode != OREAD || pathtype(uif->path) == TPATH_ROOT)
			error(Eperm);
		if(!CreateDirectory(newpath, NULL)){
			if(GetLastError() != ERROR_ALREADY_EXISTS || mode & OEXCL)
				oserror();
		}
		d = malloc(sizeof(*d));
		p = catpath(newpath, "*.*", nil);
		if((d->handle = FindFirstFile(p, &d->wfd)) == INVALID_HANDLE_VALUE){
			free(p);
			free(d);
			oserror();
		}
		free(p);
		if(waserror()){
			FindClose(d->handle);
			free(d);
			nexterror();
		}
		d->keep = 1;
	} else {
		if((h = CreateFile(
			newpath,
			fsaccess(omode & 3),
			FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,	/* h9: as in fsopen */
			NULL,
			(mode & OEXCL) ? CREATE_NEW : CREATE_ALWAYS,
			FILE_ATTRIBUTE_NORMAL,
			0)) == INVALID_HANDLE_VALUE)
			oserror();
		if(waserror()){
			CloseHandle(h);
			nexterror();
		}
	}
	c->qid = wfdtoqid(newpath, nil);
	uif->dir = d;
	uif->fh = h;
	poperror();
	free(uif->path);
	uif->path = newpath;
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
		if(uif->dir != nil){
			if(uif->dir->drivebuf != nil){
				free(uif->dir->drivebuf);
				uif->dir->drivebuf = nil;
			} else {
				FindClose(uif->dir->handle);
				free(uif->dir);
			}
		} else {
			CloseHandle(uif->fh);
		}
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
	HANDLE fh;
	DWORD r;
	Ufsinfo *uif;

	if(c->qid.type & QTDIR)
		return fsdirread(c, va, n, offset);

	uif = c->aux;
	qlock(&uif->oq);
	if(waserror()) {
		qunlock(&uif->oq);
		nexterror();
	}
	fh = uif->fh;
	if(uif->offset != offset) {
		LONG high;
		high = offset>>32;
		offset = SetFilePointer(fh, (LONG)(offset & 0xFFFFFFFF), &high, FILE_BEGIN);
		offset |= (vlong)high<<32;
		uif->offset = offset;
	}
	r = 0;
	if(!ReadFile(fh, va, (DWORD)n, &r, NULL))
		oserror();
	n = r;
	uif->offset += n;
	qunlock(&uif->oq);
	poperror();
	return n;
}

static long
fswrite(Chan *c, void *va, long n, vlong offset)
{
	HANDLE fh;
	DWORD w;
	Ufsinfo *uif;

	if(c->qid.type & QTDIR)
		return fsdirread(c, va, n, offset);

	uif = c->aux;
	qlock(&uif->oq);
	if(waserror()) {
		qunlock(&uif->oq);
		nexterror();
	}
	fh = uif->fh;
	if(uif->offset != offset) {
		LONG high;
		high = offset>>32;
		offset = SetFilePointer(fh, (LONG)(offset & 0xFFFFFFFF), &high, FILE_BEGIN);
		offset |= (vlong)high<<32;
		uif->offset = offset;
	}
	w = 0;
	if(!WriteFile(fh, va, (DWORD)n, &w, NULL))
		oserror();
	n = w;
	uif->offset += n;
	qunlock(&uif->oq);
	poperror();
	return n;
}

/*
 * h9: delete with POSIX semantics, as unlink(2) does: the name goes at
 * once, even while the file is open, rather than when the last handle
 * closes, so a new file can take the name right away. Falls back to
 * DeleteFile where the file system doesn't support it.
 */
static int
posixdelete(wchar_t *path)
{
	/* FILE_DISPOSITION_INFO_EX: DELETE | POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE */
	struct { DWORD Flags; } fd = { 0x1 | 0x2 | 0x10 };
	HANDLE h;
	BOOL ok;

	h = CreateFileW(path, DELETE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
		NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, 0);
	if(h == INVALID_HANDLE_VALUE)
		return DeleteFile(path);
	ok = SetFileInformationByHandle(h, 21 /* FileDispositionInfoEx */, &fd, sizeof fd);
	CloseHandle(h);
	if(ok)
		return 1;
	return DeleteFile(path);
}

static void
fsremove(Chan *c)
{
	Ufsinfo *uif;

	if(waserror()){
		fsclose(c);
		nexterror();
	}
	uif = c->aux;
	/* h9: a link is removed, not its target. */
	h9_fs_allow(ownpath(uif), H9_FSREMOVE);
	if(uif->lpath != nil){
		DWORD attr;

		attr = GetFileAttributesW(uif->lpath);
		if(attr == INVALID_FILE_ATTRIBUTES)
			oserror();
		if(attr & FILE_ATTRIBUTE_DIRECTORY){
			if(!RemoveDirectory(uif->lpath))
				oserror();
		}else if(!posixdelete(uif->lpath))
			oserror();
	} else if(c->qid.type & QTDIR){
		if(!RemoveDirectory(uif->path))
			oserror();
	} else {
		if(!posixdelete(uif->path))
			oserror();
	}
	poperror();
	fsclose(c);
}

static int
fswstat(Chan *c, uchar *buf, int n)
{
	char strs[MAX_PATH*3];
	Ufsinfo *uif;
	Dir d;

	if (convM2D(buf, n, &d, strs) != n)
		error(Ebadstat);
	uif = c->aux;
	/*
	 * h9: a wstat that changes nothing syncs the file (fsync(2) for Linux
	 * programs). A directory isn't opened as a handle here (it's a
	 * FindFirstFile search), and NTFS logs a rename or create in it
	 * itself, so a directory has nothing to sync.
	 */
	if(~d.mode == 0 && ~d.atime == 0 && ~d.mtime == 0 && (uvlong)d.length == (uvlong)~0 && d.name[0] == 0){
		if(uif->fh != INVALID_HANDLE_VALUE && uif->fh != NULL)
			FlushFileBuffers(uif->fh);	/* fails on a read-only handle, which has nothing to sync */
		return n;
	}
	if(pathtype(uif->path) != TPATH_FILE)
		error(Ebadstat);
	h9_fs_allow(uif->path, H9_FSWRITE);
	/*
	 * h9: change the length: truncate, ftruncate, and fallocate, which
	 * grows a file this way. Upstream ignored it, so the call succeeded
	 * with the file unchanged.
	 */
	if((uvlong)d.length != (uvlong)~0){
		HANDLE h;
		LARGE_INTEGER len;
		int ok;

		if((h = CreateFile(uif->path, GENERIC_WRITE,
			FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
			NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0)) == INVALID_HANDLE_VALUE)
			oserror();
		if(waserror()){
			CloseHandle(h);
			nexterror();
		}
		h9_fs_allowhandlew(h, H9_FSWRITE);
		len.QuadPart = d.length;
		ok = SetFilePointerEx(h, len, NULL, FILE_BEGIN) && SetEndOfFile(h);
		if(!ok)
			oserror();
		poperror();
		CloseHandle(h);
	}
	if(~d.atime != 0 || ~d.mtime != 0){
		FILETIME ta, *pta = NULL;
		FILETIME tm, *ptm = NULL;
		HANDLE h;
		if(~d.atime != 0){
			ta = filetime(d.atime);
			pta = &ta;
		}
		if(~d.mtime != 0){
			tm = filetime(d.mtime);
			ptm = &tm;
		}
		if((h = CreateFile(uif->path,
			FILE_WRITE_ATTRIBUTES | FILE_READ_ATTRIBUTES,
			FILE_SHARE_READ | FILE_SHARE_WRITE,
			NULL,
			OPEN_EXISTING,
			FILE_ATTRIBUTE_NORMAL,
			0)) != INVALID_HANDLE_VALUE){
			/* h9: check the file the handle actually opened, not the path. */
			if(waserror()){
				CloseHandle(h);
				nexterror();
			}
			h9_fs_allowhandlew(h, H9_FSWRITE);
			SetFileTime(h, NULL, pta, ptm);
			poperror();
			CloseHandle(h);
		}
	}
	/* change name */
	if(d.name[0]){
		wchar_t *base, *newpath;
		int l;

		/* h9: a link is renamed, not its target. */
		base = wstrdup(ownpath(uif));
		if(waserror()){
			free(base);
			nexterror();
		}
		/* replace last path-element with d.name */
		l = wcslen(base)-1;
		if(l <= 0)
			error(Ebadstat);
		for(;l>0; l--){
			if(base[l-1]=='\\')
				break;
		}
		if(l <= 0)
			error(Ebadstat);
		base[l] = 0;
		newpath = catpath(base, d.name, nil);
		free(base);
		poperror();
		if(waserror()){
			free(newpath);
			nexterror();
		}
		if(wcscmp(ownpath(uif), newpath)!=0){
			h9_fs_allow(newpath, H9_FSCREATE);
			h9_fs_allow(ownpath(uif), H9_FSRENAME);
			if(!MoveFile(ownpath(uif), newpath))
				oserror();
		}
		if(uif->lpath != nil){
			free(uif->lpath);
			uif->lpath = newpath;
		}else{
			free(uif->path);
			uif->path = newpath;
		}
		poperror();
	}

	/* fixme: change attributes */
	c->qid = wfdtoqid(uif->path, nil);
	return n;	
}

static wchar_t*
catpath(wchar_t *base, char *cext, wchar_t *wext)
{
	wchar_t *path;
	long n, m;

	n = wcslen(base);
	m = wext!=nil ? wcslen(wext) : strlen(cext)*4;
	path = malloc((n+m+2)*sizeof(wchar_t));
	memmove(path, base, n*sizeof(wchar_t));
	if(n > 0 && path[n-1] != '\\') path[n++] = '\\';
	if(wext != nil)
		memmove(path+n, wext, m*sizeof(wchar_t));
	else
		m = MultiByteToWideChar(CP_UTF8,0,cext,-1,path+n,m);
	path[n+m] = 0;
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

static ulong
fsdirread(Chan *c, uchar *va, int count, vlong offset)
{
	int i;
	ulong t;
	Dir d;
	long n;
	Ufsinfo *uif;
	char de[MAX_PATH*3];
	wchar_t *p;

	i = 0;
	uif = c->aux;
	errno = 0;

	t = pathtype(uif->path);
	if(uif->offset != offset) {
		if(offset != 0)
			error("bad offset in fsdirread");
		uif->offset = offset;  /* sync offset */
		switch(t){
		case TPATH_ROOT:
			uif->dir->drivep = uif->dir->drivebuf;
			break;
		case TPATH_VOLUME:
		case TPATH_FILE:
			FindClose(uif->dir->handle);
			p = catpath(uif->path, "*.*", nil);
			uif->dir->handle = FindFirstFile(p, &uif->dir->wfd);
			free(p);
			if(uif->dir->handle == INVALID_HANDLE_VALUE)
				oserror();
			break;
		}
		uif->dir->keep = 1;
	}

	while(i+BIT16SZ < count) {
		if(!uif->dir->keep) {
			switch(t){
			case TPATH_ROOT:
				uif->dir->drivep += 4;
				if(*uif->dir->drivep == 0)
					goto out;
				break;
			case TPATH_VOLUME:
			case TPATH_FILE:
				if(!FindNextFile(uif->dir->handle, &uif->dir->wfd))
					goto out;
				break;
			}
		} else {
			uif->dir->keep = 0;
		}
		if(t == TPATH_ROOT){
			uif->dir->drivep[2] = 0;
			WideCharToMultiByte(CP_UTF8,0,uif->dir->drivep,-1,de,sizeof(de),0,0);
		} else {
			WideCharToMultiByte(CP_UTF8,0,uif->dir->wfd.cFileName,-1,de,sizeof(de),0,0);
		}
		if(de[0]==0 || isdots(de))
			continue;
		d.name = de;
		/*
		 * h9: in a contained tree, an entry is listed as its walk
		 * resolves it, and a link whose target is missing isn't.
		 */
		if(uif->top != nil && t != TPATH_ROOT){
			wchar_t buf[MAX_PATH*4];
			WIN32_FIND_DATA f;
			HANDLE h;

			if(h9_fs_resolveinw(uif->top, uif->path, de, buf, nelem(buf)) < 0)
				continue;
			if(h9_fs_checkw(buf, H9_FSWALK) < 0)
				continue;
			if(pathtype(buf) == TPATH_FILE){
				if((h = FindFirstFile(buf, &f)) == INVALID_HANDLE_VALUE)
					continue;
				FindClose(h);
				wfdtodir(buf, &d, &f);
			}else
				wfdtodir(buf, &d, nil);
			d.name = de;
			d.type = 'U';
			d.dev = c->dev;
			n = convD2M(&d, (uchar*)va+i, count-i);
			if(n == BIT16SZ){
				uif->dir->keep = 1;
				break;
			}
			i += n;
			continue;
		}
		if(t == TPATH_ROOT)
			p = catpath(uif->path, nil, uif->dir->drivep);
		else
			p = catpath(uif->path, nil, uif->dir->wfd.cFileName);
		if(h9_fs_checkw(p, H9_FSWALK) < 0){
			free(p);
			continue;
		}
		if(t == TPATH_ROOT)
			wfdtodir(p, &d, nil);
		else
			wfdtodir(p, &d, &uif->dir->wfd);
		free(p);
		d.type = 'U';
		d.dev = c->dev;
		n = convD2M(&d, (uchar*)va+i, count-i);
		if(n == BIT16SZ){
			uif->dir->keep = 1;
			break;
		}
		i += n;
	}
out:
	uif->offset += i;
	return i;
}

/*
 * h9: called by namec once a walk from a #U attach is done. A contained
 * attach's tree is where the walk ended, by its final path. The list of
 * drives can't be a tree, so a contained attach left there isn't one.
 */
void
h9_fs_anchor(Chan *c)
{
	wchar_t w[MAX_PATH*4], *p;
	Ufsinfo *uif;
	HANDLE h;
	DWORD n;

	uif = c->aux;
	if(!uif->contained || uif->top != nil)
		return;
	if(pathtype(uif->path) == TPATH_ROOT){
		uif->contained = 0;
		return;
	}
	p = uif->path;
	if(pathtype(p) == TPATH_VOLUME){
		uif->top = wstrdup(p);
		return;
	}
	h = CreateFileW(p, 0, FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
		nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nil);
	if(h == INVALID_HANDLE_VALUE)
		oserror();
	n = GetFinalPathNameByHandleW(h, w, nelem(w), FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
	CloseHandle(h);
	/* Only drive paths, \\?\C:\..., are allowed; not UNC or devices. */
	if(n == 0 || n >= nelem(w) || wcsncmp(w, L"\\\\?\\", 4) != 0 || w[5] != L':')
		error(Enonexist);
	p = w+4;
	n = wcslen(p);
	if(n > 2 && p[n-1] == L'\\')
		p[n-1] = 0;
	uif->top = wstrdup(p);
	free(uif->path);
	uif->path = wstrdup(p);
	free(uif->lpath);
	uif->lpath = nil;
}

/*
 * h9: symbolic links aren't made on Windows hosts.
 *
 * This is load-bearing for the sandbox. fscreate, fsremove, and the
 * wstat rename path still check a path string and then let the host
 * re-resolve it (CreateFile/DeleteFile/MoveFile), which is the same
 * check-then-act shape the POSIX backend had to close. It is safe here only
 * because the guest has no way to win that race: it can't plant a reparse
 * point (no symlink or junction creation anywhere in this driver) and can't
 * move a file across directories into an in-policy name (h9_fs_rename is
 * EXDEV), so it can never make the check and the operation resolve to
 * different files. fsopen and the wstat time-set don't rely on that: they
 * open first and check the handle (h9_fs_allowhandlew).
 *
 * If link or junction creation is ever added here, the create, remove, and
 * rename paths must move to handle-bound checks first (open-then-check, and
 * a handle-relative create via the NT RootDirectory, as devfs-posix.c does
 * with openat/unlinkat/renameat), or this race reopens.
 */
void
h9_fs_symlink(Chan *c, char *name, char *target)
{
	USED(c);
	USED(name);
	USED(target);
	error(Eperm);
}

/*
 * h9: syncfs(2) on c syncs its own file, as fsync does. Directories, and
 * sync(2)'s every volume, need a volume handle, which needs an
 * administrator, so they have nothing to sync here.
 */
void
h9_fs_syncfs(Chan *c)
{
	Ufsinfo *uif;

	if(devtab[c->type]->dc != 'U' || (c->flag & COPEN) == 0)
		return;
	uif = c->aux;
	if(uif->fh != INVALID_HANDLE_VALUE && uif->fh != NULL)
		FlushFileBuffers(uif->fh);
}

void
h9_fs_sync(void)
{
}

/* h9: renameat across directories stays EXDEV here for now. */
int
h9_fs_rename(Chan *c, Chan *dir, char *name)
{
	USED(c);
	USED(dir);
	USED(name);
	return 1;
}

/* h9: the target of the link c's last name was, as it's written. */
int
h9_fs_readlink(Chan *c, char *buf, int nbuf)
{
	Ufsinfo *uif;

	if(devtab[c->type]->dc != 'U' || nbuf <= 0)
		return -1;
	uif = c->aux;
	if(pathtype(ownpath(uif)) != TPATH_FILE || h9_fs_checknamew(ownpath(uif), H9_FSWALK) < 0)
		return -1;
	return h9_fs_readlinkw(ownpath(uif), buf, nbuf);
}

static ulong
fsaccess(int m)
{
	ulong a;
	a = 0;
	switch(m & 3){
	default:
		error(Eperm);
		break;
	case OREAD:
		a = GENERIC_READ;
		break;
	case OWRITE:
		a = GENERIC_WRITE;
		break;
	case ORDWR:
		a = GENERIC_READ | GENERIC_WRITE;
		break;
	}
	return a;
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
