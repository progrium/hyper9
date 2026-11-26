/*
 * The host's half of the policy's file checks (src/host/fscheck.c), which
 * the host tree device calls (src/host/devfs_posix.zig and
 * devfs_win32.zig, which declare them in Zig). None of them raises. The
 * operation numbers match policy.Op in src/policy.zig.
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
 * Contained trees (design/epoch-0/symlinks-in-root.md): h9_fs_resolvein's
 * results, and the most links one walk follows.
 */
enum {
	H9_RESNONEXIST = -1,	/* an element, or a link's target, is missing */
	H9_RESNOTDIR = -2,
	H9_RESLOOP = -3,	/* more than H9_MAXLINKS links */
	H9_RESTOOLONG = -4,
	H9_MAXLINKS = 40,
};

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
/*
 * The policy decision for an already-open fd, by the file the fd actually
 * opened rather than by resolving a path string again: devfs opens, then
 * checks the fd, so a swapped symlink can't steer the open past the check
 * (the check-then-open race). Returns 0, -1, or -2, as h9_fs_check.
 */
int	h9_fs_checkfd(int fd, int op);
/*
 * WASI has no way to ask an fd for its path (no /proc, no F_GETPATH), so on
 * the web host devfs notes the path it opened each fd by, and
 * h9_fs_checkfd and h9_fs_checkat read it back.
 */
#ifdef __wasi__
void	h9_fs_notefd(int fd, char *path);
void	h9_fs_notefdat(int fd, int dfd, char *name);
#endif
/*
 * The same for the entry `name` within the directory `dfd` already refers to,
 * judged by that directory's canonical path joined to `name`, without
 * following `name`. For an unlinkat or renameat done relative to a parent
 * directory fd the devfs code opened and checked once.
 */
int	h9_fs_checkat(int dfd, char *name, int op);
#else
/* The same, for devfs-win32's paths, "C:\a\b". */
int	h9_fs_resolveinw(wchar_t *top, wchar_t *dir, char *rel, wchar_t *buf, int nbuf);
/* The target of the symlink or junction at path, as it was written. */
int	h9_fs_readlinkw(wchar_t *path, char *buf, int nbuf);
int	h9_fs_checkw(wchar_t *path, int op);
int	h9_fs_checknamew(wchar_t *path, int op);
/*
 * The same for an already-open handle, by the file the handle actually
 * opened (GetFinalPathNameByHandle) rather than by resolving a path again:
 * devfs opens, then checks the handle, so a swapped component can't steer
 * the open past the check. The handle is a void*, as HANDLE is.
 */
int	h9_fs_checkhandlew(void *handle, int op);

/*
 * devfs's paths spelled for the Win32 file calls. A drive path,
 * "C:\a\b", goes as "\\?\C:\a\b", so a name Windows reserves for a device
 * (aux, con, nul, prn, com1 and the rest, with or without an extension)
 * is a file like any other, as are trailing dots and spaces, and paths
 * can be longer than MAX_PATH. "\\?\" turns off Win32's own handling of
 * "." and "..", so h9_fs_longw resolves them, lexically as Win32 does.
 * It returns the path in memory the caller frees, or nil (with
 * ERROR_FILENAME_EXCED_RANGE) if it's too long. Other paths, "" and
 * "C:", are copied as they are. The calls open beneath the machine's
 * directory handles (src/host/dirs.c).
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
#endif
#endif
