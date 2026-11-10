/*
 * The devfs side of the sandbox policy (SPEC.md, "Vendor hooks" and
 * "Path resolution"). devfs-posix calls these before touching a host path.
 * Each host path is resolved (symlinks followed, as devfs's own stat and
 * open do) and the resolved path is checked against the calling machine's
 * policy through a Zig leaf, h9_policy_check, which never raises errors.
 * Checking the resolved path keeps a symlink inside a bound tree from
 * reaching anything the policy doesn't allow.
 */

#ifdef WINDOWS
#include <windows.h>
#endif
#include "u.h"
#ifndef WINDOWS
#include <sys/stat.h>
#include <stdlib.h>
#include <limits.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#endif
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#define H9_FSCHECK_IMPL	/* the Win32 calls themselves, not fscheck.h's wrappers */
#include "fscheck.h"

/* Implemented in Zig (src/kern.zig): 0 allows, -1 hides, -2 is read-only. */
extern int h9_policy_check(char *path, long len, int op);
extern int h9_policy_active(void);

enum {
	Hidden = -1,
	Readonly = -2,
};

#ifndef WINDOWS

/*
 * The canonical path of an existing entry without following it if it's a
 * symlink, so a differently cased name on a case-insensitive file system
 * can't dodge a rule. Returns 0, or -1 if it doesn't exist.
 */
static int
canonical(char *path, char *buf)
{
	struct stat st;

	if(lstat(path, &st) < 0)
		return -1;
#ifdef __APPLE__
	{
		int fd;

		fd = open(path, O_EVTONLY|O_SYMLINK|O_CLOEXEC);
		if(fd < 0)
			return -1;
		if(fcntl(fd, F_GETPATH, buf) < 0){
			close(fd);
			return -1;
		}
		close(fd);
		return 0;
	}
#else
	/* Other hosts' file systems are case-sensitive, so the name stands. */
	if(!S_ISLNK(st.st_mode))
		return realpath(path, buf) == nil ? -1 : 0;
	return -1;
#endif
}

/*
 * Resolves path into buf. With nofollow, the last element itself isn't
 * followed (create, remove and rename act on a link, not its target): an
 * existing entry is canonicalised, and a new name is appended to its
 * resolved parent. Returns 0, or -1 if the path can't be resolved.
 */
static int
resolve(char *path, char *buf, int nofollow)
{
	char parent[PATH_MAX], *slash, *name;
	int n;

	if(!nofollow || strcmp(path, "/") == 0)
		return realpath(path, buf) == nil ? -1 : 0;
	if(canonical(path, buf) == 0)
		return 0;
	slash = strrchr(path, '/');
	if(slash == nil)
		return -1;
	name = slash+1;
	if(slash == path)
		strcpy(parent, "/");
	else{
		n = slash - path;
		if(n >= sizeof parent)
			return -1;
		memmove(parent, path, n);
		parent[n] = 0;
	}
	if(realpath(parent, buf) == nil)
		return -1;
	n = strlen(buf);
	if(n + 1 + strlen(name) + 1 > PATH_MAX)
		return -1;
	if(n > 0 && buf[n-1] != '/')
		buf[n++] = '/';
	strcpy(buf+n, name);
	return 0;
}

static int
check(char *path, int op, int nofollow)
{
	char buf[PATH_MAX];
	struct stat st;

	if(!h9_policy_active())
		return 0;
	if(resolve(path, buf, nofollow) < 0)
		return Hidden;
	/*
	 * Creating over an existing symlink writes its target, and over a
	 * dangling one creates a file wherever it points.
	 */
	if(op == H9_FSCREATE && lstat(buf, &st) == 0 && S_ISLNK(st.st_mode)){
		char target[PATH_MAX];

		if(realpath(buf, target) == nil)
			return Hidden;
		if(h9_policy_check(target, strlen(target), H9_FSWRITE) < 0)
			return Hidden;
	}
	return h9_policy_check(buf, strlen(buf), op);
}

int
h9_fs_check(char *path, int op)
{
	return check(path, op, op == H9_FSCREATE || op == H9_FSREMOVE || op == H9_FSRENAME);
}

int
h9_fs_checkname(char *path, int op)
{
	return check(path, op, 1);
}

/*
 * Contained trees (design/0034-symlinks-in-root.md). The walk is done here
 * one element at a time with lstat, instead of by the host's stat, so a
 * link is read relative to the tree as openat2's RESOLVE_IN_ROOT reads it:
 * an absolute target starts again at top, and ".." stops there. top is
 * canonical; dir is top or a path the resolver made beneath it, so it
 * holds no links, and neither does the result.
 */

static int
isdotdot(char *s, int n)
{
	return n == 2 && s[0] == '.' && s[1] == '.';
}

int
h9_fs_resolvein(char *top, char *dir, char *rel, char *buf, int nbuf)
{
	char cur[PATH_MAX], pend[2*PATH_MAX], rest[2*PATH_MAX], next[PATH_MAX], target[PATH_MAX];
	char *p, *e, *slash;
	int toplen, links, n, len, last;
	struct stat st;

	toplen = strlen(top);
	if(toplen > 1 && top[toplen-1] == '/')
		toplen--;
	n = strlen(dir);
	if(n >= sizeof cur || strlen(rel) >= sizeof pend)
		return H9_RESTOOLONG;
	memmove(cur, dir, n+1);
	strcpy(pend, rel);
	links = 0;
	p = pend;
	for(;;){
		while(*p == '/')
			p++;
		if(*p == 0)
			break;
		e = strchr(p, '/');
		len = e != nil ? e - p : strlen(p);
		/* The last element is the one with nothing but slashes after it. */
		last = 1;
		if(e != nil)
			for(slash = e; *slash; slash++)
				if(*slash != '/'){
					last = 0;
					break;
				}
		if(len == 1 && p[0] == '.'){
			p += len;
			continue;
		}
		if(isdotdot(p, len)){
			/* At the top, ".." is the top. */
			n = strlen(cur);
			if(n > toplen){
				slash = strrchr(cur, '/');
				if(slash == cur)
					cur[1] = 0;
				else
					*slash = 0;
			}
			p += len;
			continue;
		}
		n = strlen(cur);
		if(n + 1 + len + 1 > sizeof next)
			return H9_RESTOOLONG;
		memmove(next, cur, n);
		if(n == 0 || next[n-1] != '/')
			next[n++] = '/';
		memmove(next+n, p, len);
		next[n+len] = 0;
		if(lstat(next, &st) < 0)
			return errno == ENOTDIR ? H9_RESNOTDIR : errno == ENAMETOOLONG ? H9_RESTOOLONG : H9_RESNONEXIST;
		if(S_ISLNK(st.st_mode)){
			if(++links > H9_MAXLINKS)
				return H9_RESLOOP;
			n = readlink(next, target, sizeof target - 1);
			if(n <= 0)
				return H9_RESNONEXIST;
			target[n] = 0;
			/* The rest of the walk goes on from the link's target. */
			p += len;
			if(n + 1 + strlen(p) + 1 > sizeof pend)
				return H9_RESTOOLONG;
			strcpy(rest, p);
			snprint(pend, sizeof pend, "%s/%s", target, rest);
			p = pend;
			if(target[0] == '/'){
				memmove(cur, top, toplen);
				cur[toplen] = 0;
			}
			continue;
		}
		if(!last && !S_ISDIR(st.st_mode))
			return H9_RESNOTDIR;
		strcpy(cur, next);
		p += len;
	}
	n = strlen(cur);
	if(n >= nbuf)
		return H9_RESTOOLONG;
	memmove(buf, cur, n+1);
	return 0;
}

/*
 * The canonical path of an already-open fd: the file it actually refers to,
 * however its name resolved. /proc/self/fd on Linux, F_GETPATH on macOS.
 * Returns 0 with the path in buf (at most PATH_MAX), or -1.
 */
#ifdef __wasi__
/*
 * The web host's fd paths, as devfs noted them at the open. Every open that
 * devfs checks by its fd is noted, so a reused fd number gets its new path
 * before it's checked again. The web host runs one coroutine at a time and
 * no host call parks between an open and its check, so the path can't
 * change under it either.
 */
enum { Nwasifd = 4096 };
static char *wasifds[Nwasifd];

void
h9_fs_notefd(int fd, char *path)
{
	char cwd[PATH_MAX], *p;

	if(fd < 0 || fd >= Nwasifd)
		return;
	if(path[0] != '/'){
		if(getcwd(cwd, sizeof cwd) == nil)
			return;
		p = smprint("%s/%s", cwd, path);
	}else
		p = strdup(path);
	free(wasifds[fd]);
	wasifds[fd] = p;
}

void
h9_fs_notefdat(int fd, int dfd, char *name)
{
	char *p;

	if(fd < 0 || fd >= Nwasifd || dfd < 0 || dfd >= Nwasifd || wasifds[dfd] == nil)
		return;
	p = smprint("%s/%s", wasifds[dfd], name);
	if(p == nil)
		return;
	h9_fs_notefd(fd, p);
	free(p);
}
#endif

static int
fdpath(int fd, char *buf)
{
#ifdef __wasi__
	if(fd < 0 || fd >= Nwasifd || wasifds[fd] == nil || strlen(wasifds[fd]) >= PATH_MAX)
		return -1;
	strcpy(buf, wasifds[fd]);
	return 0;
#elif defined(__APPLE__)
	return fcntl(fd, F_GETPATH, buf) < 0 ? -1 : 0;
#else
	char link[64];
	int n;

	snprint(link, sizeof link, "/proc/self/fd/%d", fd);
	n = readlink(link, buf, PATH_MAX-1);
	if(n < 0)
		return -1;
	buf[n] = 0;
	return 0;
#endif
}

/*
 * The policy decision for an already-open fd, judged by the file the fd
 * actually opened rather than by resolving a path string a second time.
 * devfs opens a file and then checks its fd, so a guest that swaps a
 * directory for a symlink between a path check and the open (the devfs
 * check-then-open race, design/0034) can't steer the open to a file outside
 * the policy: the fd and the check see one inode. Returns 0 if op is allowed,
 * Hidden or Readonly as h9_fs_check does.
 */
int
h9_fs_checkfd(int fd, int op)
{
	char buf[PATH_MAX];

	if(!h9_policy_active())
		return 0;
	if(fdpath(fd, buf) < 0)
		return Hidden;
	return h9_policy_check(buf, strlen(buf), op);
}

void
h9_fs_allowfd(int fd, int op)
{
	switch(h9_fs_checkfd(fd, op)){
	case 0:
		return;
	case Readonly:
		error(Eperm);
	default:
		error(Enonexist);
	}
}

/*
 * The policy decision for the entry `name` within the directory `dfd` already
 * refers to, judged by that directory's own canonical path joined to `name`,
 * without following `name` itself. devfs opens the parent directory once and
 * then does the operation relative to that fd (unlinkat, renameat), so a
 * swapped parent component can't steer it outside the policy: the check and
 * the operation share one directory inode. `name` must be a single element.
 * Returns 0/-1/-2 as h9_fs_check does.
 */
int
h9_fs_checkat(int dfd, char *name, int op)
{
	char buf[PATH_MAX];
	int n;

	if(!h9_policy_active())
		return 0;
	if(fdpath(dfd, buf) < 0)
		return Hidden;
	n = strlen(buf);
	if(n + 1 + strlen(name) + 1 > PATH_MAX)
		return Hidden;
	if(n > 0 && buf[n-1] != '/')
		buf[n++] = '/';
	strcpy(buf+n, name);
	return h9_policy_check(buf, strlen(buf), op);
}

void
h9_fs_allowat(int dfd, char *name, int op)
{
	switch(h9_fs_checkat(dfd, name, op)){
	case 0:
		return;
	case Readonly:
		error(Eperm);
	default:
		error(Enonexist);
	}
}

#else

/*
 * devfs-win32's paths are "", "C:" or "C:\a\b". Policy paths use the
 * guest's spelling of #U paths, "/C:/a/b". Resolution opens the path and
 * asks for its final name, which follows symlinks and junctions and
 * canonicalises case and short names.
 */

enum {
	Longmax = 32767,	/* the longest \\?\ path, in characters */
	Longroot = 7,	/* \\?\C:\ */
};

wchar_t*
h9_fs_longw(wchar_t *path)
{
	wchar_t *l, *p, *e;
	int n, k, len;

	n = wcslen(path);
	if(path[0] == 0 || path[1] != L':' || (path[2] != L'\\' && path[2] != L'/')){
		if((l = malloc((n+1)*sizeof(wchar_t))) == nil){
			SetLastError(ERROR_NOT_ENOUGH_MEMORY);
			return nil;
		}
		memmove(l, path, (n+1)*sizeof(wchar_t));
		return l;
	}
	/* At most the prefix, the rest of path and a separator, then NUL. */
	if(n + 5 > Longmax){
		SetLastError(ERROR_FILENAME_EXCED_RANGE);
		return nil;
	}
	if((l = malloc((n+6)*sizeof(wchar_t))) == nil){
		SetLastError(ERROR_NOT_ENOUGH_MEMORY);
		return nil;
	}
	memmove(l, L"\\\\?\\", 4*sizeof(wchar_t));
	l[4] = path[0];
	l[5] = L':';
	l[6] = L'\\';
	k = Longroot;
	/* Each name is followed by a separator; ".." goes back one, never above the drive. */
	for(p = path+3; *p != 0; p = e){
		while(*p == L'\\' || *p == L'/')
			p++;
		for(e = p; *e != 0 && *e != L'\\' && *e != L'/'; e++)
			;
		len = e - p;
		if(len == 0 || (len == 1 && p[0] == L'.'))
			continue;
		if(len == 2 && p[0] == L'.' && p[1] == L'.'){
			if(k > Longroot)
				for(k--; k > Longroot && l[k-1] != L'\\'; k--)
					;
			continue;
		}
		memmove(l+k, p, len*sizeof(wchar_t));
		k += len;
		l[k++] = L'\\';
	}
	if(k > Longroot)
		k--;
	l[k] = 0;
	return l;
}

/* Frees l without losing the error of the call that used it. */
static void
longfree(wchar_t *l)
{
	DWORD err;

	err = GetLastError();
	free(l);
	SetLastError(err);
}

HANDLE
h9_fs_findfirst(wchar_t *path, WIN32_FIND_DATAW *wfd)
{
	wchar_t *l;
	HANDLE h;

	if((l = h9_fs_longw(path)) == nil)
		return INVALID_HANDLE_VALUE;
	h = FindFirstFileW(l, wfd);
	longfree(l);
	return h;
}

HANDLE
h9_fs_createfile(wchar_t *path, DWORD access, DWORD share, SECURITY_ATTRIBUTES *sa, DWORD disp, DWORD flags, HANDLE tmpl)
{
	wchar_t *l;
	HANDLE h;

	if((l = h9_fs_longw(path)) == nil)
		return INVALID_HANDLE_VALUE;
	h = CreateFileW(l, access, share, sa, disp, flags, tmpl);
	longfree(l);
	return h;
}

BOOL
h9_fs_createdir(wchar_t *path, SECURITY_ATTRIBUTES *sa)
{
	wchar_t *l;
	BOOL r;

	if((l = h9_fs_longw(path)) == nil)
		return FALSE;
	r = CreateDirectoryW(l, sa);
	longfree(l);
	return r;
}

BOOL
h9_fs_removedir(wchar_t *path)
{
	wchar_t *l;
	BOOL r;

	if((l = h9_fs_longw(path)) == nil)
		return FALSE;
	r = RemoveDirectoryW(l);
	longfree(l);
	return r;
}

BOOL
h9_fs_deletefile(wchar_t *path)
{
	wchar_t *l;
	BOOL r;

	if((l = h9_fs_longw(path)) == nil)
		return FALSE;
	r = DeleteFileW(l);
	longfree(l);
	return r;
}

BOOL
h9_fs_movefile(wchar_t *old, wchar_t *new)
{
	wchar_t *lo, *ln;
	BOOL r;

	if((lo = h9_fs_longw(old)) == nil)
		return FALSE;
	if((ln = h9_fs_longw(new)) == nil){
		longfree(lo);
		return FALSE;
	}
	r = MoveFileW(lo, ln);
	longfree(ln);
	longfree(lo);
	return r;
}

DWORD
h9_fs_getattr(wchar_t *path)
{
	wchar_t *l;
	DWORD r;

	if((l = h9_fs_longw(path)) == nil)
		return INVALID_FILE_ATTRIBUTES;
	r = GetFileAttributesW(l);
	longfree(l);
	return r;
}

/*
 * The guest's spelling, "/C:/a/b", of the file an open handle refers to,
 * from its final path name (symlinks and junctions followed, case and short
 * names canonicalised). Returns 0, or -1 if it isn't a drive path.
 */
static int
handlefinal(HANDLE h, char *buf, int nbuf)
{
	wchar_t w[MAX_PATH*4];
	DWORD n;
	char *p;
	int i;

	n = GetFinalPathNameByHandleW(h, w, nelem(w), FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
	if(n == 0 || n >= nelem(w))
		return -1;
	/* Only drive paths, \\?\C:\..., are allowed; not UNC or devices. */
	if(wcsncmp(w, L"\\\\?\\", 4) != 0 || w[5] != L':')
		return -1;
	buf[0] = '/';
	if(WideCharToMultiByte(CP_UTF8, 0, w+4, -1, buf+1, nbuf-1, nil, nil) == 0)
		return -1;
	for(p = buf; *p; p++)
		if(*p == '\\')
			*p = '/';
	i = strlen(buf);
	if(i > 1 && buf[i-1] == '/')
		buf[i-1] = 0;
	return 0;
}

static int
finalflags(wchar_t *path, char *buf, int nbuf, DWORD flags)
{
	HANDLE h;
	int r;

	h = h9_fs_createfile(path, 0, FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
		nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS|flags, nil);
	if(h == INVALID_HANDLE_VALUE)
		return -1;
	r = handlefinal(h, buf, nbuf);
	CloseHandle(h);
	return r;
}

static int
final(wchar_t *path, char *buf, int nbuf)
{
	return finalflags(path, buf, nbuf, 0);
}

static int
checkw(wchar_t *path, int op, int nofollow)
{
	char buf[MAX_PATH*4*UTFmax], *name;
	wchar_t parent[MAX_PATH*4], *slash;
	int n, len;

	if(!h9_policy_active())
		return 0;
	/* The list of drives, and the drives themselves, can be walked. */
	if(path[0] == 0 || (path[1] == L':' && path[2] == 0)){
		if(path[0] == 0)
			strcpy(buf, "/");
		else{
			buf[0] = '/';
			buf[1] = toupper(path[0]);
			buf[2] = ':';
			buf[3] = 0;
		}
		return h9_policy_check(buf, strlen(buf), op);
	}
	if(!nofollow){
		if(final(path, buf, sizeof buf) < 0)
			return Hidden;
		return h9_policy_check(buf, strlen(buf), op);
	}
	/*
	 * An existing entry is checked by its own canonical name (case, short
	 * names and trailing dots folded); creating over a link also writes
	 * its target.
	 */
	if(finalflags(path, buf, sizeof buf, FILE_FLAG_OPEN_REPARSE_POINT) == 0){
		char target[MAX_PATH*4*UTFmax];

		if(op == H9_FSCREATE && final(path, target, sizeof target) == 0
		&& strcmp(target, buf) != 0 && h9_policy_check(target, strlen(target), H9_FSWRITE) < 0)
			return Hidden;
		return h9_policy_check(buf, strlen(buf), op);
	}
	slash = wcsrchr(path, L'\\');
	if(slash == nil || slash-path >= nelem(parent))
		return Hidden;
	n = slash - path;
	memmove(parent, path, n*sizeof(wchar_t));
	parent[n] = 0;
	if(n == 2)
		wcscat(parent, L"\\");
	if(final(parent, buf, sizeof buf) < 0)
		return Hidden;
	len = strlen(buf);
	name = buf+len+1;
	if(WideCharToMultiByte(CP_UTF8, 0, slash+1, -1, name, sizeof buf - len - 1, nil, nil) == 0)
		return Hidden;
	buf[len] = '/';
	return h9_policy_check(buf, strlen(buf), op);
}

int
h9_fs_checkw(wchar_t *path, int op)
{
	return checkw(path, op, op == H9_FSCREATE || op == H9_FSREMOVE || op == H9_FSRENAME);
}

/*
 * Contained trees on Windows (design/0034-symlinks-in-root.md): as on
 * POSIX, with a reparse point's target in place of readlink. Symlinks and
 * junctions are followed; other reparse points are refused. An absolute
 * target, "C:\x", "\x" or a junction's "\??\C:\x", starts again at top:
 * its drive is dropped. A UNC or device target is refused.
 */

/* A reparse point's data, as FSCTL_GET_REPARSE_POINT returns it. */
typedef struct {
	ULONG	tag;
	USHORT	len;
	USHORT	reserved;
	USHORT	subst_off;
	USHORT	subst_len;
	USHORT	print_off;
	USHORT	print_len;
	/* then, for a symlink, ULONG flags; then the names */
} Reparse;

enum {
	Reparsebuf = 16*1024,	/* MAXIMUM_REPARSE_DATA_BUFFER_SIZE */
	Symrelative = 1,	/* SYMLINK_FLAG_RELATIVE */
};

/*
 * The target of the reparse point at path, in target (nul-terminated),
 * and whether it's relative. Returns 0, or -1 if it isn't a symlink or a
 * junction, or can't be read. print picks the name as it was written
 * rather than the substitute name.
 */
static int
reparsetarget(wchar_t *path, wchar_t *target, int ntarget, int *relative, int print)
{
	uchar buf[Reparsebuf];
	Reparse *r;
	wchar_t *names;
	HANDLE h;
	DWORD n;
	USHORT off, len;

	h = h9_fs_createfile(path, 0, FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
		nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT, nil);
	if(h == INVALID_HANDLE_VALUE)
		return -1;
	if(!DeviceIoControl(h, FSCTL_GET_REPARSE_POINT, nil, 0, buf, sizeof buf, &n, nil)){
		CloseHandle(h);
		return -1;
	}
	CloseHandle(h);
	r = (Reparse*)buf;
	if(r->tag == IO_REPARSE_TAG_SYMLINK){
		*relative = (*(ULONG*)(r+1) & Symrelative) != 0;
		names = (wchar_t*)((uchar*)(r+1) + sizeof(ULONG));
	}else if(r->tag == IO_REPARSE_TAG_MOUNT_POINT){
		*relative = 0;
		names = (wchar_t*)(r+1);
	}else
		return -1;
	off = print ? r->print_off : r->subst_off;
	len = print ? r->print_len : r->subst_len;
	if(print && len == 0){
		off = r->subst_off;
		len = r->subst_len;
	}
	if((uchar*)names + off + len > buf + n || len/sizeof(wchar_t) >= ntarget)
		return -1;
	memmove(target, (uchar*)names + off, len);
	target[len/sizeof(wchar_t)] = 0;
	return 0;
}

int
h9_fs_readlinkw(wchar_t *path, char *buf, int nbuf)
{
	wchar_t target[MAX_PATH*4];
	int relative;

	if(reparsetarget(path, target, nelem(target), &relative, 1) < 0)
		return -1;
	if(WideCharToMultiByte(CP_UTF8, 0, target, -1, buf, nbuf, nil, nil) == 0)
		return -1;
	return strlen(buf);
}

int
h9_fs_resolveinw(wchar_t *top, wchar_t *dir, char *rel, wchar_t *buf, int nbuf)
{
	wchar_t cur[MAX_PATH*4], pend[MAX_PATH*8], rest[MAX_PATH*8], next[MAX_PATH*4], target[MAX_PATH*4];
	wchar_t *p, *e, *slash, *t;
	int toplen, links, n, len, last, relative;
	DWORD attr;

	toplen = wcslen(top);
	n = wcslen(dir);
	if(n >= nelem(cur))
		return H9_RESTOOLONG;
	memmove(cur, dir, (n+1)*sizeof(wchar_t));
	if(MultiByteToWideChar(CP_UTF8, 0, rel, -1, pend, nelem(pend)) == 0)
		return H9_RESTOOLONG;
	links = 0;
	p = pend;
	for(;;){
		while(*p == L'/' || *p == L'\\')
			p++;
		if(*p == 0)
			break;
		for(e = p; *e && *e != L'/' && *e != L'\\'; e++)
			;
		len = e - p;
		last = 1;
		for(slash = e; *slash; slash++)
			if(*slash != L'/' && *slash != L'\\'){
				last = 0;
				break;
			}
		if(len == 1 && p[0] == L'.'){
			p = e;
			continue;
		}
		if(len == 2 && p[0] == L'.' && p[1] == L'.'){
			n = wcslen(cur);
			if(n > toplen){
				slash = wcsrchr(cur, L'\\');
				if(slash == nil || slash - cur < toplen)
					cur[toplen] = 0;
				else
					*slash = 0;
			}
			p = e;
			continue;
		}
		n = wcslen(cur);
		if(n + 1 + len + 1 > nelem(next))
			return H9_RESTOOLONG;
		memmove(next, cur, n*sizeof(wchar_t));
		if(n == 0 || next[n-1] != L'\\')
			next[n++] = L'\\';
		memmove(next+n, p, len*sizeof(wchar_t));
		next[n+len] = 0;
		attr = h9_fs_getattr(next);
		if(attr == INVALID_FILE_ATTRIBUTES)
			return H9_RESNONEXIST;
		if(attr & FILE_ATTRIBUTE_REPARSE_POINT){
			if(++links > H9_MAXLINKS)
				return H9_RESLOOP;
			if(reparsetarget(next, target, nelem(target), &relative, 0) < 0)
				return H9_RESNONEXIST;
			t = target;
			if(!relative){
				/* \??\C:\x, C:\x or \x: from top. */
				if(wcsncmp(t, L"\\??\\", 4) == 0 || wcsncmp(t, L"\\\\?\\", 4) == 0)
					t += 4;
				if(wcsncmp(t, L"UNC\\", 4) == 0 || wcsncmp(t, L"\\\\", 2) == 0)
					return H9_RESNONEXIST;
				if(t[0] != 0 && t[1] == L':')
					t += 2;
			}
			p = e;
			if(wcslen(t) + 1 + wcslen(p) + 1 > nelem(pend))
				return H9_RESTOOLONG;
			wcscpy(rest, p);
			wcscpy(pend, t);
			wcscat(pend, L"\\");
			wcscat(pend, rest);
			p = pend;
			if(!relative){
				memmove(cur, top, toplen*sizeof(wchar_t));
				cur[toplen] = 0;
			}
			continue;
		}
		if(!last && !(attr & FILE_ATTRIBUTE_DIRECTORY))
			return H9_RESNOTDIR;
		wcscpy(cur, next);
		p = e;
	}
	n = wcslen(cur);
	if(n >= nbuf)
		return H9_RESTOOLONG;
	memmove(buf, cur, (n+1)*sizeof(wchar_t));
	return 0;
}

int
h9_fs_checknamew(wchar_t *path, int op)
{
	return checkw(path, op, 1);
}

void
h9_fs_allow(wchar_t *path, int op)
{
	switch(h9_fs_checkw(path, op)){
	case 0:
		return;
	case Readonly:
		error(Eperm);
	default:
		error(Enonexist);
	}
}

/*
 * The policy decision for an already-open handle, judged by the file the
 * handle actually opened (its final path name) rather than by resolving a
 * path string again: devfs-win32 opens, then checks the handle, so a swapped
 * component can't steer the open past the check (the check-then-open race).
 * h9_fs_checkhandlew returns 0/-1/-2 as h9_fs_checkw; h9_fs_allowhandlew
 * raises the matching error. The handle is passed as void* so the header
 * needn't include windows.h; HANDLE is a void* on Windows.
 */
int
h9_fs_checkhandlew(void *handle, int op)
{
	char buf[MAX_PATH*4*UTFmax];

	if(!h9_policy_active())
		return 0;
	if(handlefinal((HANDLE)handle, buf, sizeof buf) < 0)
		return Hidden;
	return h9_policy_check(buf, strlen(buf), op);
}

void
h9_fs_allowhandlew(void *handle, int op)
{
	switch(h9_fs_checkhandlew(handle, op)){
	case 0:
		return;
	case Readonly:
		error(Eperm);
	default:
		error(Enonexist);
	}
}

#endif

#ifndef WINDOWS
void
h9_fs_allow(char *path, int op)
{
	switch(h9_fs_check(path, op)){
	case 0:
		return;
	case Readonly:
		error(Eperm);
	default:
		error(Enonexist);
	}
}
#endif

/* src/kern/devoverlay.c */
extern Chan *h9_overlay_lower(Chan*);
extern int h9_overlay_readlink(Chan*, char*, int);
extern void h9_overlay_symlink(Chan*, char*, char*);
extern int h9_overlay_move(Chan*, Chan*, char*);

/*
 * The target of the link that path's last name is, through #U and an
 * overlay over it, for the Linux personality's readlinkat and lstat
 * (design/0034-symlinks-in-root.md). Plan 9 programs never see links,
 * so it's a leaf, not a 9P message. Returns the target's length, with
 * it in buf, or -1 with the error in errstr, as the sys* wrappers do.
 */
int
h9_fs_readlinkpath(char *path, char *buf, int nbuf)
{
	Chan *c, *l;
	char *p;
	int n;

	c = nil;
	if(waserror()){
		if(c != nil)
			cclose(c);
		p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	c = namec(path, Aaccess, 0, 0);
	if((n = h9_overlay_readlink(c, buf, nbuf)) >= 0){
		cclose(c);
		poperror();
		return n;
	}
	if((l = h9_overlay_lower(c)) != nil){
		cclose(c);
		c = l;
	}
	n = h9_fs_readlink(c, buf, nbuf);
	if(n < 0)
		error("not a symbolic link");
	cclose(c);
	poperror();
	return n;
}

/*
 * Moves old to new in another directory, for the Linux personality's
 * renameat: a host rename when both are in devfs trees (fscheck.h), and
 * a move in memory when both are in one overlay (devoverlay.c).
 */
int
h9_fs_renamepath(char *old, char *new)
{
	Chan *volatile oc, *volatile nc;
	char *volatile dir;
	char *name, *p;
	int r;

	oc = nil;
	nc = nil;
	dir = nil;
	if(waserror()){
		if(oc != nil)
			cclose(oc);
		if(nc != nil)
			cclose(nc);
		free(dir);
		p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	oc = namec(old, Aaccess, 0, 0);
	dir = strdup(new);
	if(dir == nil)
		error(Enomem);
	name = strrchr(dir, '/');
	if(name == nil){
		name = dir;
		nc = namec(".", Aaccess, 0, 0);
	}else{
		*name++ = '\0';
		nc = namec(dir[0] != '\0' ? dir : "/", Aaccess, 0, 0);
	}
	if(name[0] == '\0' || strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
		error(Eexist);
	if((nc->qid.type & QTDIR) == 0)
		error(Enotdir);
	r = 1;
	if(devtab[oc->type]->dc == 'U' && devtab[nc->type]->dc == 'U')
		r = h9_fs_rename(oc, nc, name);
	else if(devtab[oc->type]->dc == 'O' && devtab[nc->type]->dc == 'O')
		r = h9_overlay_move(oc, nc, name);
	cclose(oc);
	cclose(nc);
	free(dir);
	poperror();
	return r;
}

/*
 * Makes path a symbolic link to target, for the Linux personality's
 * symlinkat: in memory in an overlay, or on the host in a devfs tree,
 * where the new name is checked like a create. Anywhere else it's
 * "permission denied". Returns 0, or -1 with the error in errstr.
 */
int
h9_fs_symlinkpath(char *path, char *target)
{
	Chan *volatile c;
	char *dir, *name, *p;

	c = nil;
	dir = nil;
	if(waserror()){
		if(c != nil)
			cclose(c);
		free(dir);
		p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	dir = strdup(path);
	if(dir == nil)
		error(Enomem);
	name = strrchr(dir, '/');
	if(name == nil){
		name = dir;
		c = namec(".", Aaccess, 0, 0);
	}else{
		*name++ = '\0';
		c = namec(dir[0] != '\0' ? dir : "/", Aaccess, 0, 0);
	}
	if(name[0] == '\0' || strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
		error(Eexist);
	if((c->qid.type & QTDIR) == 0)
		error(Enotdir);
	switch(devtab[c->type]->dc){
	case 'O':
		p = (char*)c;
		c = nil;
		h9_overlay_symlink((Chan*)p, name, target);
		break;
	case 'U':
		h9_fs_symlink(c, name, target);
		break;
	default:
		error(Eperm);
	}
	if(c != nil)
		cclose(c);
	free(dir);
	poperror();
	return 0;
}
