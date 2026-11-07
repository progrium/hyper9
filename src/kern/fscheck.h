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
 * Contained trees (design/0034-symlinks-in-root.md): h9_fs_resolvein's
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
#else
/* The same, for devfs-win32's paths, "C:\a\b". */
int	h9_fs_resolveinw(wchar_t *top, wchar_t *dir, char *rel, wchar_t *buf, int nbuf);
/* The target of the symlink or junction at path, as it was written. */
int	h9_fs_readlinkw(wchar_t *path, char *buf, int nbuf);
int	h9_fs_checkw(wchar_t *path, int op);
int	h9_fs_checknamew(wchar_t *path, int op);
void	h9_fs_allow(wchar_t *path, int op);
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
