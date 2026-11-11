/*
 * h9's sandbox hooks for devfs (src/kern/fscheck.c). The operation
 * numbers match policy.Op in src/policy.zig.
 */
enum {
	H9_FSWALK = 0,
	H9_FSREAD = 1,
	H9_FSWRITE = 2,
	H9_FSCREATE = 3,
	H9_FSREMOVE = 4,
	H9_FSRENAME = 5,	/* the source of a rename */
};

/*
 * Contained trees (design/symlinks-in-root.md): h9_fs_resolvein's
 * results, and the most links one walk follows.
 */
enum {
	H9_RESNONEXIST = -1,	/* an element, or a link's target, is missing */
	H9_RESNOTDIR = -2,
	H9_RESLOOP = -3,	/* more than H9_MAXLINKS links */
	H9_RESTOOLONG = -4,
	H9_MAXLINKS = 40,
};

/* The error for H9_RESLOOP. */
#define H9_ELOOP "too many symbolic links"

#ifndef WINDOWS
/*
 * Resolves rel, '/'-separated, from dir inside the tree top: an absolute
 * link target starts again at top, and ".." stops there. top is canonical,
 * and dir is top or a path this returned. Puts the host path in buf and
 * returns 0, or an H9_RES error. Doesn't check the policy.
 */
int	h9_fs_resolvein(char *top, char *dir, char *rel, char *buf, int nbuf);
/* Returns 0 if op on the host path is allowed, -1 if hidden, -2 if read-only. */
int	h9_fs_check(char *path, int op);
/* Like h9_fs_check, without following a link that's the last element. */
int	h9_fs_checkname(char *path, int op);
/* Like h9_fs_check, but raises "file does not exist" or "permission denied". */
void	h9_fs_allow(char *path, int op);
/*
 * The policy decision for an already-open fd, by the file the fd actually
 * opened rather than by resolving a path string again: devfs opens, then
 * checks the fd, so a swapped symlink can't steer the open past the check
 * (the check-then-open race). h9_fs_checkfd returns 0/-1/-2 as h9_fs_check;
 * h9_fs_allowfd raises the matching error.
 */
int	h9_fs_checkfd(int fd, int op);
void	h9_fs_allowfd(int fd, int op);
/*
 * WASI has no way to ask an fd for its path (no /proc, no F_GETPATH), so on
 * the web host devfs notes the path it opened each fd by, and
 * h9_fs_checkfd and h9_fs_checkat read it back. Elsewhere these do nothing.
 */
#ifdef __wasi__
void	h9_fs_notefd(int fd, char *path);
void	h9_fs_notefdat(int fd, int dfd, char *name);
#else
#define	h9_fs_notefd(fd, path)	do{}while(0)
#define	h9_fs_notefdat(fd, dfd, name)	do{}while(0)
#endif
/*
 * The same for the entry `name` within the directory `dfd` already refers to,
 * judged by that directory's canonical path joined to `name`, without
 * following `name`. For an unlinkat or renameat done relative to a parent
 * directory fd the devfs code opened and checked once.
 */
int	h9_fs_checkat(int dfd, char *name, int op);
void	h9_fs_allowat(int dfd, char *name, int op);
#else
/* The same, for devfs-win32's paths, "C:\a\b". */
int	h9_fs_resolveinw(wchar_t *top, wchar_t *dir, char *rel, wchar_t *buf, int nbuf);
/* The target of the symlink or junction at path, as it was written. */
int	h9_fs_readlinkw(wchar_t *path, char *buf, int nbuf);
int	h9_fs_checkw(wchar_t *path, int op);
int	h9_fs_checknamew(wchar_t *path, int op);
void	h9_fs_allow(wchar_t *path, int op);
/*
 * The same for an already-open handle, by the file the handle actually
 * opened (GetFinalPathNameByHandle) rather than by resolving a path again:
 * devfs-win32 opens, then checks the handle, so a swapped component can't
 * steer the open past the check. The handle is a void* so this header needn't
 * include windows.h; HANDLE is a void* on Windows.
 */
int	h9_fs_checkhandlew(void *handle, int op);
void	h9_fs_allowhandlew(void *handle, int op);

/*
 * devfs-win32's paths spelled for the Win32 file calls. A drive path,
 * "C:\a\b", goes as "\\?\C:\a\b", so a name Windows reserves for a device
 * (aux, con, nul, prn, com1 and the rest, with or without an extension)
 * is a file like any other, as are trailing dots and spaces, and paths
 * can be longer than MAX_PATH. "\\?\" turns off Win32's own handling of
 * "." and "..", so h9_fs_longw resolves them, lexically as Win32 does.
 * It returns the path in memory the caller frees, or nil (with
 * ERROR_FILENAME_EXCED_RANGE) if it's too long. Other paths, "" and
 * "C:", are copied as they are. These need windows.h, which linux.c
 * doesn't include.
 */
#ifdef WINAPI
wchar_t*	h9_fs_longw(wchar_t *path);
HANDLE	h9_fs_findfirst(wchar_t *path, WIN32_FIND_DATAW *wfd);
HANDLE	h9_fs_createfile(wchar_t *path, DWORD access, DWORD share, SECURITY_ATTRIBUTES *sa, DWORD disp, DWORD flags, HANDLE tmpl);
BOOL	h9_fs_createdir(wchar_t *path, SECURITY_ATTRIBUTES *sa);
BOOL	h9_fs_removedir(wchar_t *path);
BOOL	h9_fs_deletefile(wchar_t *path);
BOOL	h9_fs_movefile(wchar_t *old, wchar_t *new);
DWORD	h9_fs_getattr(wchar_t *path);

#ifndef H9_FSCHECK_IMPL
/* devfs-win32 makes these calls through the functions above. */
#undef FindFirstFile
#undef CreateFile
#undef CreateFileW
#undef CreateDirectory
#undef RemoveDirectory
#undef DeleteFile
#undef MoveFile
#undef GetFileAttributesW
#define FindFirstFile	h9_fs_findfirst
#define CreateFile	h9_fs_createfile
#define CreateFileW	h9_fs_createfile
#define CreateDirectory	h9_fs_createdir
#define RemoveDirectory	h9_fs_removedir
#define DeleteFile	h9_fs_deletefile
#define MoveFile	h9_fs_movefile
#define GetFileAttributesW	h9_fs_getattr
#endif
#endif
#endif

/*
 * devfs's side (third_party/drawterm/kern/devfs-*.c). h9_fs_anchor makes
 * a contained attach's tree the place its namec walk ended; chan.c calls
 * it. h9_fs_readlink puts the target of the link a devfs chan was walked
 * through as its last name in buf, NUL-terminated, and returns its
 * length, or -1 if that name isn't a link.
 */
void	h9_fs_anchor(Chan *c);
int	h9_fs_readlink(Chan *c, char *buf, int nbuf);
/* The same by a path in the caller's namespace, through an overlay (fscheck.c). */
int	h9_fs_readlinkpath(char *path, char *buf, int nbuf);
/*
 * h9_fs_symlink makes name in the devfs directory c a link to target.
 * h9_fs_symlinkpath does it by a path in the caller's namespace, in an
 * overlay or a devfs tree (fscheck.c); 0, or -1 with the error in errstr.
 */
void	h9_fs_symlink(Chan *c, char *name, char *target);
int	h9_fs_symlinkpath(char *path, char *target);
/*
 * h9_fs_rename moves the devfs file c to name in the devfs directory dir
 * with the host's rename, checked as a rename of c and a create of name;
 * 1 if the host can't (Windows, for now). h9_fs_renamepath does it by
 * paths in the caller's namespace, for renameat across directories,
 * also moving within one overlay (h9_overlay_move): 0, 1 if it can't
 * (the caller's EXDEV), or -1 with the error in errstr.
 */
int	h9_fs_rename(Chan *c, Chan *dir, char *name);
/*
 * h9_fs_syncfs syncs the host file system behind the open devfs chan c,
 * for syncfs(2); h9_fs_sync syncs every host file system, for sync(2).
 * Each raises the host's error.
 */
void	h9_fs_syncfs(Chan *c);
void	h9_fs_sync(void);
int	h9_fs_renamepath(char *old, char *new);
