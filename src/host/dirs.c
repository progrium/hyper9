/*
 * Files beneath a directory handle (design/host-handles.md, "Files
 * beneath a handle"): the host side of devfs's opens. devfs names a host
 * file by its resolved host path, as before; here the path is matched to
 * the machine's directory handle that holds it (h9_host_dir, in Zig), and
 * the file is opened relative to that handle, so the host OS, not a check
 * on a path string, keeps the result inside the tree.
 *
 * On Linux that's one openat2 with RESOLVE_BENEATH (RESOLVE_IN_ROOT for a
 * contained tree). Elsewhere, and on Linux kernels without openat2, it's a
 * walk of one name at a time from the handle with O_NOFOLLOW, which reads
 * each link itself: a relative target is walked in place, and an absolute
 * one, or a ".." above the top, is an escape (EXDEV), or for a contained
 * tree starts again at the top. On Windows it's NtCreateFile relative to
 * the handle, a name at a time with FILE_OPEN_REPARSE_POINT, so no
 * symbolic link or junction is followed by the host.
 *
 * A 9front program's walks follow links anywhere, and the policy decides
 * by the resolved path (spec/sandbox.md, "Path resolution"). An open
 * whose links leave its handle is therefore opened again by the link
 * free path it resolves to, beneath the handle that holds that, if one
 * does; otherwise it fails as a hidden file does. A link swapped in
 * meanwhile fails that open rather than being followed.
 *
 * A path that no handle holds is an ancestor of one (/mnt/term/<path>),
 * or hidden: only directories are opened there, read-only, by path, and
 * devfs's checks of what was opened still apply. With no host (a kernel
 * thread, or a machine without a policy) everything is by path, as
 * before.
 */

#if defined(_WIN32)
#include <windows.h>
#include <winternl.h>
#include <wchar.h>
#include <stdlib.h>
#include <string.h>
#elif !defined(__wasi__)
#ifndef _GNU_SOURCE
#define _GNU_SOURCE	/* O_PATH */
#endif
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif
#endif

#if !defined(__wasi__)

/*
 * src/kern.zig: the handle of the calling machine's host that holds host
 * path (in the policy's spelling, "/C:/a/b" on Windows), and in rel the
 * path relative to it, '/'-separated, "." for the handle's own top. Its
 * flags: 1 if the tree is contained. Returns the handle (an fd, or on
 * Windows a HANDLE as an intptr), or one of the H9_HOST values.
 */
enum {
	H9HostNone = -2,	/* no host: by path, as before */
	H9HostOutside = -3,	/* the host has no handle that holds it */
	H9HostToolong = -4,
};
enum { H9HostContained = 1 };
extern long long h9_host_dir(const char *path, char *rel, int nrel, int *flags);

#endif

#if !defined(_WIN32) && !defined(__wasi__)

#ifndef O_PATH
#define O_PATH	0
#endif
#ifndef SYS_openat2
#ifdef __linux__
#define SYS_openat2	437
#endif
#endif

enum {
	Maxlinks = 40,	/* as fscheck.h's H9_MAXLINKS */
	Maxdepth = 256,
};

enum {
	Wnolinks = 1,	/* every link is ELOOP (a Linux process's walk) */
	Wcontained = 2,	/* links resolve inside the tree */
	Wfollow = 4,	/* follow a link that's the last name */
};

static void
closekeep(int fd)
{
	int e;

	e = errno;
	close(fd);
	errno = e;
}

/*
 * Resolves rel beneath the directory top, a name at a time, never letting
 * the host follow a link. Returns an fd of the directory that holds the
 * last name, which the caller closes, with the name in name ("." for the
 * directory itself); the name may not exist. -1 with errno set: EXDEV
 * for an escape, ELOOP for a link where none may be or too many.
 */
static int
walk(int top, const char *rel, int how, char *name)
{
	char buf[2][PATH_MAX+1], *rest, *p, *e;
	int stk[Maxdepth], depth, links, cur, n, fd, last, w, i;
	struct stat st;

	if(strlen(rel) > PATH_MAX){
		errno = ENAMETOOLONG;
		return -1;
	}
	strcpy(buf[0], rel);
	rest = buf[0];
	w = 0;
	depth = 0;
	links = 0;
	for(;;){
		cur = depth == 0 ? top : stk[depth-1];
		while(*rest == '/')
			rest++;
		if(*rest == 0){
			strcpy(name, ".");
			break;
		}
		p = rest;
		for(e = p; *e != 0 && *e != '/'; e++)
			;
		n = e - p;
		rest = e;
		while(*rest == '/')
			rest++;
		last = *rest == 0;
		if(n == 1 && p[0] == '.'){
			if(last){
				strcpy(name, ".");
				break;
			}
			continue;
		}
		if(n == 2 && p[0] == '.' && p[1] == '.'){
			if(depth == 0){
				if(how & Wcontained)
					continue;
				errno = EXDEV;
				goto err;
			}
			close(stk[--depth]);
			if(last){
				strcpy(name, ".");
				break;
			}
			continue;
		}
		if(n > NAME_MAX){
			errno = ENAMETOOLONG;
			goto err;
		}
		memmove(name, p, n);
		name[n] = 0;
		if(last && (how & Wfollow) == 0)
			break;
		if(fstatat(cur, name, &st, AT_SYMLINK_NOFOLLOW) < 0){
			if(last && errno == ENOENT)
				break;	/* a name to create */
			goto err;
		}
		if(S_ISLNK(st.st_mode)){
			char target[PATH_MAX+1];
			ssize_t tn;

			if((how & Wnolinks) || ++links > Maxlinks){
				errno = ELOOP;
				goto err;
			}
			if((tn = readlinkat(cur, name, target, PATH_MAX)) < 0)
				goto err;
			target[tn] = 0;
			if(target[0] == '/'){
				if((how & Wcontained) == 0){
					errno = EXDEV;
					goto err;
				}
				while(depth > 0)
					close(stk[--depth]);
			}
			if(tn + 1 + strlen(rest) > PATH_MAX){
				errno = ENAMETOOLONG;
				goto err;
			}
			w ^= 1;
			strcpy(buf[w], target);
			strcat(buf[w], "/");
			strcat(buf[w], rest);
			rest = buf[w];
			continue;
		}
		if(last)
			break;
		if(!S_ISDIR(st.st_mode)){
			errno = ENOTDIR;
			goto err;
		}
		if(depth == Maxdepth){
			errno = ENAMETOOLONG;
			goto err;
		}
		/* O_NOFOLLOW: a link swapped in since the fstatat fails here. */
		fd = openat(cur, name, (O_PATH ? O_PATH : O_RDONLY)|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
		if(fd < 0)
			goto err;
		stk[depth++] = fd;
	}
	if(depth > 0){
		fd = stk[--depth];
		for(i = 0; i < depth; i++)
			close(stk[i]);
		return fd;
	}
	return fcntl(top, F_DUPFD_CLOEXEC, 0);
err:
	for(i = 0; i < depth; i++)
		closekeep(stk[i]);
	return -1;
}

/* walk, then the last name opened without following it. */
static int
walkopen(int top, const char *rel, int how, int flags, int mode)
{
	char name[NAME_MAX+1];
	int dfd, fd, try;

	for(try = 0; try < 2; try++){
		if((dfd = walk(top, rel, how, name)) < 0)
			return -1;
		fd = openat(dfd, name, flags|O_NOFOLLOW|O_CLOEXEC, mode);
		closekeep(dfd);
		/* ELOOP: the last name became a link since walk read it. */
		if(fd >= 0 || errno != ELOOP || (how & (Wfollow|Wnolinks)) != Wfollow)
			return fd;
	}
	return -1;
}

#ifdef __linux__
struct openhow {
	unsigned long long	flags;
	unsigned long long	mode;
	unsigned long long	resolve;
};
enum {
	ResolveNoMagiclinks = 0x02,
	ResolveNoSymlinks = 0x04,
	ResolveBeneath = 0x08,
	ResolveInRoot = 0x10,
};
static int noopenat2;
#endif

/* For src/host/dirs.zig's cases: the walk alone, as hosts without openat2 have it. */
void
h9_host_test_noopenat2(int on)
{
#ifdef __linux__
	noopenat2 = on;
#else
	(void)on;
#endif
}

/* The file rel names beneath the handle top, opened with flags. */
static int
beneath(int top, const char *rel, int how, int flags, int mode)
{
#ifdef __linux__
	struct openhow oh;
	int fd, try;

	if(!noopenat2){
		memset(&oh, 0, sizeof oh);
		oh.flags = flags|O_CLOEXEC;
		if(how & (Wnolinks))
			oh.flags |= O_NOFOLLOW;
		oh.mode = (flags & O_CREAT) ? mode : 0;
		oh.resolve = ResolveNoMagiclinks|((how & Wcontained) ? ResolveInRoot : ResolveBeneath);
		if(how & Wnolinks)
			oh.resolve |= ResolveNoSymlinks;
		/* EAGAIN: a rename on the host raced the lookup. */
		for(try = 0; try < 8; try++){
			fd = syscall(SYS_openat2, top, rel, &oh, sizeof oh);
			if(fd >= 0 || errno != EAGAIN)
				break;
		}
		if(fd >= 0 || (errno != ENOSYS && errno != EPERM))
			return fd;
		noopenat2 = 1;
	}
#endif
	if(how & Wnolinks)
		flags |= O_NOFOLLOW;
	return walkopen(top, rel, how, flags, mode);
}

/*
 * The canonical name of the file path names, by opening it (following
 * links, or not with nofollow) and asking the fd. For a name that doesn't
 * exist, its directory's canonical name and the name. 0, or -1.
 */
static int
fdname(int fd, char *buf)
{
#ifdef __linux__
	char proc[64];
	ssize_t n;

	snprintf(proc, sizeof proc, "/proc/self/fd/%d", fd);
	if((n = readlink(proc, buf, PATH_MAX-1)) <= 0 || buf[0] != '/')
		return -1;
	buf[n] = 0;
	/* A file removed under us. */
	if(n > 10 && strcmp(buf+n-10, " (deleted)") == 0)
		return -1;
	return 0;
#elif defined(F_GETPATH)
	return fcntl(fd, F_GETPATH, buf) < 0 ? -1 : 0;
#else
	(void)fd;
	(void)buf;
	return -1;
#endif
}

static int
canonical(const char *path, int nofollow, char *buf)
{
	char parent[PATH_MAX+1];
	const char *slash;
	int fd, n;

#ifdef __linux__
	fd = open(path, O_PATH|O_CLOEXEC|(nofollow ? O_NOFOLLOW : 0));
#elif defined(O_EVTONLY) && defined(O_SYMLINK)
	fd = open(path, O_EVTONLY|O_NONBLOCK|O_CLOEXEC|(nofollow ? O_SYMLINK : 0));
#else
	fd = -1;
	errno = ENOSYS;
#endif
	if(fd >= 0){
		n = fdname(fd, buf);
		closekeep(fd);
		if(n == 0)
			return 0;
	}else if(errno != ENOENT && errno != ENOSYS)
		return -1;
	if(fd < 0 && errno == ENOSYS && !nofollow && realpath(path, buf) != NULL)
		return 0;
	/* A new name: its parent's canonical name, and the name. */
	slash = strrchr(path, '/');
	if(slash == NULL || slash == path || slash[1] == 0 || slash-path > PATH_MAX)
		return -1;
	n = slash - path;
	memmove(parent, path, n);
	parent[n] = 0;
	if(realpath(parent, buf) == NULL)
		return -1;
	n = strlen(buf);
	if(n + 1 + strlen(slash+1) > PATH_MAX - 1){
		errno = ENAMETOOLONG;
		return -1;
	}
	if(n > 1)
		buf[n++] = '/';
	strcpy(buf+n, slash+1);
	return 0;
}

/* Whether flags open a directory, or nothing, for reading only. */
static int
lookonly(int flags)
{
	if((flags & O_ACCMODE) != O_RDONLY || (flags & (O_CREAT|O_TRUNC)) != 0)
		return 0;
	return (flags & O_DIRECTORY) != 0 || (O_PATH != 0 && (flags & O_PATH) != 0);
}

/* By path, as before handles: a Linux process's walk follows no link. */
static int
bypath(const char *path, int flags, int mode, int nolinks)
{
	int top, fd;

	if(!nolinks)
		return open(path, flags|O_CLOEXEC, mode);
	if(path[0] != '/'){
		errno = EINVAL;
		return -1;
	}
	if((top = open("/", O_RDONLY|O_DIRECTORY|O_CLOEXEC)) < 0)
		return -1;
	fd = beneath(top, path+1, Wnolinks, flags, mode);
	closekeep(top);
	return fd;
}

/*
 * devfs's open(2): host path opened with flags beneath the handle that
 * holds it. With nolinks, no link is followed anywhere in it (a Linux
 * process's walk, design/epoch-0/linux-symlinks.md). Returns an fd, or -1
 * with errno set.
 */
int
h9_host_open(const char *path, int flags, int mode, int nolinks)
{
	char rel[PATH_MAX+1], canon[PATH_MAX+1];
	int how, hflags, fd;
	long long h;

	how = nolinks ? Wnolinks : (flags & O_NOFOLLOW) ? 0 : Wfollow;
	h = h9_host_dir(path, rel, sizeof rel, &hflags);
	if(h == H9HostNone)
		return bypath(path, flags, mode, nolinks);
	if(h == H9HostToolong){
		errno = ENAMETOOLONG;
		return -1;
	}
	if(h >= 0){
		fd = beneath((int)h, rel, how|((hflags & H9HostContained) ? Wcontained : 0), flags, mode);
		if(fd >= 0 || errno != EXDEV)
			return fd;
	}else if(lookonly(flags))
		return bypath(path, flags, mode, nolinks);	/* an ancestor */
	/* Its links left the handle, or no handle holds its name. */
	if(nolinks || canonical(path, (flags & O_NOFOLLOW) != 0, canon) < 0){
		errno = ENOENT;
		return -1;
	}
	h = h9_host_dir(canon, rel, sizeof rel, &hflags);
	if(h < 0){
		errno = ENOENT;
		return -1;
	}
	/* The canonical name holds no link but, perhaps, the last. */
	return beneath((int)h, rel, how|((hflags & H9HostContained) ? Wcontained : 0), flags, mode);
}

/*
 * fstatat's and readlinkat's place for path: a directory fd and the name
 * in it, found beneath the handle that holds path, the last name followed
 * if follow. -1 with errno set; -2 if path is to be used as it is (no
 * host, or an ancestor's metadata).
 */
static int
at(const char *path, int follow, char *name)
{
	char rel[PATH_MAX+1], canon[PATH_MAX+1];
	int hflags, how, dfd;
	long long h;

	h = h9_host_dir(path, rel, sizeof rel, &hflags);
	if(h == H9HostNone)
		return -2;
	if(h == H9HostToolong){
		errno = ENAMETOOLONG;
		return -1;
	}
	if(h == H9HostOutside)
		return -2;
	how = (follow ? Wfollow : 0)|((hflags & H9HostContained) ? Wcontained : 0);
	dfd = walk((int)h, rel, how, name);
	if(dfd >= 0 || errno != EXDEV)
		return dfd;
	if(canonical(path, !follow, canon) < 0 || (h = h9_host_dir(canon, rel, sizeof rel, &hflags)) < 0){
		errno = ENOENT;
		return -1;
	}
	return walk((int)h, rel, how, name);
}

static int
hoststat(const char *path, struct stat *st, int follow)
{
	char name[NAME_MAX+1];
	int dfd, r;

#ifdef __linux__
	if(!noopenat2){
		int fd;

		fd = h9_host_open(path, O_PATH|(follow ? 0 : O_NOFOLLOW), 0, 0);
		if(fd < 0)
			return -1;
		r = fstat(fd, st);
		closekeep(fd);
		return r;
	}
#endif
	if((dfd = at(path, follow, name)) == -2)
		return follow ? stat(path, st) : lstat(path, st);
	if(dfd < 0)
		return -1;
	r = fstatat(dfd, name, st, AT_SYMLINK_NOFOLLOW);
	closekeep(dfd);
	return r;
}

int
h9_host_stat(const char *path, struct stat *st)
{
	return hoststat(path, st, 1);
}

int
h9_host_lstat(const char *path, struct stat *st)
{
	return hoststat(path, st, 0);
}

ssize_t
h9_host_readlink(const char *path, char *buf, size_t n)
{
	char name[NAME_MAX+1];
	ssize_t r;
	int dfd;

	if((dfd = at(path, 0, name)) == -2)
		return readlink(path, buf, n);
	if(dfd < 0)
		return -1;
	r = readlinkat(dfd, name, buf, n);
	closekeep(dfd);
	return r;
}

#endif

#if defined(_WIN32)

/*
 * Windows: devfs-win32's paths are "C:\a\b" (src/kern/fscheck.c spells
 * them "\\?\C:\a\b" for the Win32 calls). A file beneath a handle is
 * opened with NtCreateFile relative to its directory, a name at a time,
 * each with FILE_OPEN_REPARSE_POINT, so the host follows no symbolic link
 * or junction: one met on the way is resolved, as on POSIX, by the
 * file's final path and the handle that holds that.
 */

enum {
	Longmax = 32767,
	Relmax = Longmax*3+1,	/* UTF-8 */
};

#ifndef FILE_OPEN_REPARSE_POINT
#define FILE_OPEN_REPARSE_POINT	0x00200000
#endif
#ifndef FILE_OPEN_FOR_BACKUP_INTENT
#define FILE_OPEN_FOR_BACKUP_INTENT	0x00004000
#endif
#ifndef FILE_DIRECTORY_FILE
#define FILE_DIRECTORY_FILE	0x00000001
#endif
#ifndef FILE_NON_DIRECTORY_FILE
#define FILE_NON_DIRECTORY_FILE	0x00000040
#endif
#ifndef FILE_SYNCHRONOUS_IO_NONALERT
#define FILE_SYNCHRONOUS_IO_NONALERT	0x00000020
#endif
#ifndef FILE_WRITE_THROUGH
#define FILE_WRITE_THROUGH	0x00000002
#endif
#ifndef FILE_SEQUENTIAL_ONLY
#define FILE_SEQUENTIAL_ONLY	0x00000004
#endif
#ifndef FILE_RANDOM_ACCESS
#define FILE_RANDOM_ACCESS	0x00000800
#endif
#ifndef FILE_NO_INTERMEDIATE_BUFFERING
#define FILE_NO_INTERMEDIATE_BUFFERING	0x00000008
#endif
#ifndef FILE_DELETE_ON_CLOSE
#define FILE_DELETE_ON_CLOSE	0x00001000
#endif
#ifndef FILE_OPEN
#define FILE_SUPERSEDE	0
#define FILE_OPEN	1
#define FILE_CREATE	2
#define FILE_OPEN_IF	3
#define FILE_OVERWRITE	4
#define FILE_OVERWRITE_IF	5
#endif
#ifndef OBJ_CASE_INSENSITIVE
#define OBJ_CASE_INSENSITIVE	0x40
#endif
#ifndef OBJ_INHERIT
#define OBJ_INHERIT	0x02
#endif

/* What a walk met: a link (a name surrogate reparse point), or an error. */
enum {
	Wok = 0,
	Wlink = 1,
	Werr = -1,
};

/* "C:\a\b" as the policy spells it, "/C:/a/b", in UTF-8; 0, or -1. */
static int
policyname(const wchar_t *path, char *buf, int nbuf)
{
	char *p;
	int n;

	if(wcsncmp(path, L"\\\\?\\", 4) == 0)
		path += 4;
	if(path[0] == 0 || path[1] != L':' || (path[2] != 0 && path[2] != L'\\' && path[2] != L'/'))
		return -1;
	buf[0] = '/';
	n = WideCharToMultiByte(CP_UTF8, 0, path, -1, buf+1, nbuf-1, NULL, NULL);
	if(n == 0)
		return -1;
	if(buf[1] >= 'a' && buf[1] <= 'z')
		buf[1] -= 'a' - 'A';
	for(p = buf; *p; p++)
		if(*p == '\\')
			*p = '/';
	/* "/C:/" is the drive itself, "/C:". */
	n = strlen(buf);
	while(n > 3 && buf[n-1] == '/')
		buf[--n] = 0;
	return 0;
}

static HANDLE
ntopen(HANDLE dir, const wchar_t *name, int len, ACCESS_MASK access, ULONG share, ULONG disp, ULONG opts, ULONG attrs, SECURITY_ATTRIBUTES *sa)
{
	UNICODE_STRING us;
	OBJECT_ATTRIBUTES oa;
	IO_STATUS_BLOCK io;
	NTSTATUS st;
	HANDLE h;

	us.Buffer = (PWSTR)name;
	us.Length = us.MaximumLength = len*sizeof(wchar_t);
	InitializeObjectAttributes(&oa, &us, OBJ_CASE_INSENSITIVE|(sa != NULL && sa->bInheritHandle ? OBJ_INHERIT : 0), dir, sa != NULL ? sa->lpSecurityDescriptor : NULL);
	st = NtCreateFile(&h, access, &oa, &io, NULL, attrs, share, disp, opts, NULL, 0);
	if(!NT_SUCCESS(st)){
		SetLastError(RtlNtStatusToDosError(st));
		return INVALID_HANDLE_VALUE;
	}
	return h;
}

/* Whether h is a symbolic link or junction, rather than what it names. */
static int
islink(HANDLE h)
{
	FILE_ATTRIBUTE_TAG_INFO ti;

	if(!GetFileInformationByHandleEx(h, FileAttributeTagInfo, &ti, sizeof ti))
		return 0;
	return (ti.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 && IsReparseTagNameSurrogate(ti.ReparseTag);
}

/*
 * Opens rel, '/'-separated UTF-8, beneath the directory top: every name
 * but the last as a directory, and the last with the caller's NtCreateFile
 * arguments. Puts the handle in *out and returns Wok; Wlink if a name was
 * a link (and *out is nothing); Werr with the error set.
 */
static int
ntwalk(HANDLE top, const char *rel, ACCESS_MASK access, ULONG share, ULONG disp, ULONG opts, ULONG attrs, SECURITY_ATTRIBUTES *sa, int wantlink, HANDLE *out)
{
	wchar_t *w, *p, *e;
	HANDLE cur, h;
	int n, last;

	*out = INVALID_HANDLE_VALUE;
	if((w = malloc((Longmax+1)*sizeof(wchar_t))) == NULL){
		SetLastError(ERROR_NOT_ENOUGH_MEMORY);
		return Werr;
	}
	if(MultiByteToWideChar(CP_UTF8, 0, rel, -1, w, Longmax+1) == 0){
		free(w);
		SetLastError(ERROR_FILENAME_EXCED_RANGE);
		return Werr;
	}
	cur = top;
	for(p = w;;){
		while(*p == L'/')
			p++;
		for(e = p; *e != 0 && *e != L'/'; e++)
			;
		n = e - p;
		last = 1;
		{
			wchar_t *q;

			for(q = e; *q != 0; q++)
				if(*q != L'/'){
					last = 0;
					break;
				}
		}
		if(n == 2 && p[0] == L'.' && p[1] == L'.'){
			/* devfs's paths are clean: this would climb out. */
			SetLastError(ERROR_ACCESS_DENIED);
			goto err;
		}
		if(n == 1 && p[0] == L'.')
			n = 0;	/* the directory itself: an empty name relative to it */
		if(!last){
			if(n == 0){
				p = e;
				continue;
			}
			h = ntopen(cur, p, n, FILE_TRAVERSE|FILE_READ_ATTRIBUTES|SYNCHRONIZE, FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE, FILE_OPEN,
				FILE_DIRECTORY_FILE|FILE_SYNCHRONOUS_IO_NONALERT|FILE_OPEN_REPARSE_POINT|FILE_OPEN_FOR_BACKUP_INTENT, 0, NULL);
			if(h == INVALID_HANDLE_VALUE)
				goto err;
			if(islink(h)){
				CloseHandle(h);
				goto link;
			}
			if(cur != top)
				CloseHandle(cur);
			cur = h;
			p = e;
			continue;
		}
		h = ntopen(cur, p, n, access, share, disp, opts|FILE_OPEN_REPARSE_POINT, attrs, sa);
		if(h == INVALID_HANDLE_VALUE)
			goto err;
		if(!wantlink && islink(h)){
			CloseHandle(h);
			goto link;
		}
		if(cur != top)
			CloseHandle(cur);
		free(w);
		*out = h;
		return Wok;
	}
link:
	if(cur != top)
		CloseHandle(cur);
	free(w);
	return Wlink;
err:
	{
		DWORD err;

		err = GetLastError();
		if(cur != top)
			CloseHandle(cur);
		free(w);
		SetLastError(err);
	}
	return Werr;
}

/* path's final name, through its links, in the policy's spelling; 0, or -1. */
static int
finalname(const wchar_t *path, char *buf, int nbuf)
{
	wchar_t *l, *f;
	HANDLE h;
	DWORD n;
	int r;

	if((l = malloc((Longmax+1)*sizeof(wchar_t))) == NULL)
		return -1;
	if(wcslen(path) + 4 > Longmax){
		free(l);
		return -1;
	}
	if(wcsncmp(path, L"\\\\?\\", 4) == 0)
		wcscpy(l, path);
	else{
		wcscpy(l, L"\\\\?\\");
		wcscat(l, path);
	}
	h = CreateFileW(l, FILE_READ_ATTRIBUTES, FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
	free(l);
	if(h == INVALID_HANDLE_VALUE)
		return -1;
	if((f = malloc((Longmax+1)*sizeof(wchar_t))) == NULL){
		CloseHandle(h);
		return -1;
	}
	n = GetFinalPathNameByHandleW(h, f, Longmax+1, FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
	CloseHandle(h);
	r = n == 0 || n > Longmax ? -1 : policyname(f, buf, nbuf);
	free(f);
	return r;
}

/* CreateFileW's arguments as NtCreateFile's. */
static ULONG
ntdisp(DWORD disp)
{
	switch(disp){
	case CREATE_NEW:	return FILE_CREATE;
	case CREATE_ALWAYS:	return FILE_OVERWRITE_IF;
	case OPEN_ALWAYS:	return FILE_OPEN_IF;
	case TRUNCATE_EXISTING:	return FILE_OVERWRITE;
	default:	return FILE_OPEN;
	}
}

static ULONG
ntopts(DWORD flags)
{
	ULONG o;

	o = 0;
	if((flags & FILE_FLAG_OVERLAPPED) == 0)
		o |= FILE_SYNCHRONOUS_IO_NONALERT;
	if(flags & FILE_FLAG_BACKUP_SEMANTICS)
		o |= FILE_OPEN_FOR_BACKUP_INTENT;
	else
		o |= FILE_NON_DIRECTORY_FILE;
	if(flags & FILE_FLAG_WRITE_THROUGH)
		o |= FILE_WRITE_THROUGH;
	if(flags & FILE_FLAG_NO_BUFFERING)
		o |= FILE_NO_INTERMEDIATE_BUFFERING;
	if(flags & FILE_FLAG_RANDOM_ACCESS)
		o |= FILE_RANDOM_ACCESS;
	if(flags & FILE_FLAG_SEQUENTIAL_SCAN)
		o |= FILE_SEQUENTIAL_ONLY;
	if(flags & FILE_FLAG_DELETE_ON_CLOSE)
		o |= FILE_DELETE_ON_CLOSE;
	return o;
}

/* Whether access changes anything. */
static int
writesw(ACCESS_MASK access)
{
	return (access & (FILE_WRITE_DATA|FILE_APPEND_DATA|FILE_WRITE_EA|FILE_WRITE_ATTRIBUTES|DELETE|WRITE_DAC|WRITE_OWNER|GENERIC_WRITE|GENERIC_ALL|MAXIMUM_ALLOWED)) != 0;
}

/* Whether h is a directory. */
static int
isdirw(HANDLE h)
{
	BY_HANDLE_FILE_INFORMATION fi;

	return GetFileInformationByHandle(h, &fi) && (fi.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

/*
 * An ancestor of a handle, or a drive, which no handle holds: opened by
 * path to be looked at, and kept only if it's a directory or the open
 * reads nothing.
 */
static void
ancestor(const wchar_t *path, ACCESS_MASK access, ULONG share, ULONG disp, ULONG opts, HANDLE *out)
{
	wchar_t *l;
	HANDLE h;

	*out = INVALID_HANDLE_VALUE;
	if(writesw(access) || disp != FILE_OPEN){
		SetLastError(ERROR_FILE_NOT_FOUND);
		return;
	}
	if((l = malloc((Longmax+1)*sizeof(wchar_t))) == NULL || wcslen(path) + 5 > Longmax){
		free(l);
		SetLastError(ERROR_FILENAME_EXCED_RANGE);
		return;
	}
	if(wcsncmp(path, L"\\\\?\\", 4) == 0 || path[0] == 0 || path[1] != L':')
		wcscpy(l, path);
	else{
		wcscpy(l, L"\\\\?\\");
		wcscat(l, path);
		if(l[6] == 0)
			wcscat(l, L"\\");	/* "C:" is the drive's root */
	}
	h = CreateFileW(l, access, share, NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS|((opts & FILE_OPEN_REPARSE_POINT) ? FILE_FLAG_OPEN_REPARSE_POINT : 0), NULL);
	free(l);
	if(h == INVALID_HANDLE_VALUE)
		return;
	if((access & (FILE_READ_DATA|GENERIC_READ|GENERIC_EXECUTE|FILE_EXECUTE)) != 0 && !isdirw(h)){
		CloseHandle(h);
		SetLastError(ERROR_FILE_NOT_FOUND);
		return;
	}
	*out = h;
}

/*
 * The NtCreateFile beneath the handle that holds path, or through its
 * links beneath the one that holds their target. Returns 1 with *out set
 * (INVALID_HANDLE_VALUE with the error set on failure), or 0 for the
 * caller to open path as it is: no host, or an ancestor to look at.
 */
static int
openbeneath(const wchar_t *path, ACCESS_MASK access, ULONG share, ULONG disp, ULONG opts, ULONG attrs, SECURITY_ATTRIBUTES *sa, int nolinks, int wantlink, HANDLE *out)
{
	char *name, *rel;
	int hflags, r;
	long long h;

	*out = INVALID_HANDLE_VALUE;
	if((name = malloc(Relmax)) == NULL || (rel = malloc(Relmax)) == NULL){
		free(name);
		SetLastError(ERROR_NOT_ENOUGH_MEMORY);
		return 1;
	}
	r = 1;
	if(policyname(path, name, Relmax) < 0)
		h = h9_host_dir("/", rel, Relmax, &hflags) == H9HostNone ? H9HostNone : H9HostOutside;
	else
		h = h9_host_dir(name, rel, Relmax, &hflags);
	switch(h){
	case H9HostNone:
		r = 0;
		goto out;
	case H9HostToolong:
		SetLastError(ERROR_FILENAME_EXCED_RANGE);
		goto out;
	case H9HostOutside:
		ancestor(path, access, share, disp, opts|(wantlink ? FILE_OPEN_REPARSE_POINT : 0), out);
		goto out;
	}
	switch(ntwalk((HANDLE)(intptr_t)h, rel, access, share, disp, opts, attrs, sa, wantlink, out)){
	case Wok:
	case Werr:
		goto out;
	}
	/* A link: the file it leads to, beneath the handle holding that, with no link on the way. */
	if(nolinks){
		SetLastError(ERROR_CANT_RESOLVE_FILENAME);
		goto out;
	}
	if(finalname(path, name, Relmax) < 0 || (h = h9_host_dir(name, rel, Relmax, &hflags)) < 0){
		SetLastError(ERROR_FILE_NOT_FOUND);
		goto out;
	}
	if(ntwalk((HANDLE)(intptr_t)h, rel, access, share, disp, opts, attrs, sa, 0, out) == Wlink)
		SetLastError(ERROR_CANT_RESOLVE_FILENAME);
out:
	free(name);
	free(rel);
	return r;
}

/*
 * devfs-win32's CreateFileW (through src/kern/fscheck.c's
 * h9_fs_createfile): 1 with *out set, or 0 for the caller to call
 * CreateFileW itself.
 */
int
h9_host_createfilew(const wchar_t *path, DWORD access, DWORD share, SECURITY_ATTRIBUTES *sa, DWORD disp, DWORD flags, HANDLE *out)
{
	int wantlink, r;
	HANDLE h;

	/* Only a Linux process's open asks for the reparse point (devfs-win32's fsopen). */
	wantlink = (flags & FILE_FLAG_OPEN_REPARSE_POINT) != 0;
	r = openbeneath(path, access|SYNCHRONIZE|FILE_READ_ATTRIBUTES, share, ntdisp(disp), ntopts(flags), (flags & 0xffff) == 0 ? FILE_ATTRIBUTE_NORMAL : (flags & 0xffff), sa, wantlink, wantlink, &h);
	if(r == 0)
		return 0;
	*out = h;
	return 1;
}

/* CreateDirectoryW's: 1 with *ok set, or 0 for the caller to call it. */
int
h9_host_createdirw(const wchar_t *path, SECURITY_ATTRIBUTES *sa, BOOL *ok)
{
	HANDLE h;

	if(openbeneath(path, FILE_LIST_DIRECTORY|SYNCHRONIZE, FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE, FILE_CREATE,
		FILE_DIRECTORY_FILE|FILE_SYNCHRONOUS_IO_NONALERT|FILE_OPEN_FOR_BACKUP_INTENT, FILE_ATTRIBUTE_NORMAL, sa, 0, 0, &h) == 0)
		return 0;
	*ok = h != INVALID_HANDLE_VALUE;
	if(*ok)
		CloseHandle(h);
	return 1;
}

#endif
