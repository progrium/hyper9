#!/usr/bin/env python3
"""Remakes a Linux root's absolute symbolic links on Windows.

    python scripts/winlinks.py ARCHIVE DEST [DEPTH]

ARCHIVE is a tar (plain or gzipped) that was unpacked into DEST. Git
Bash's tar, under MSYS=winsymlinks:native, makes each link a native one,
but it turns an absolute target into a Windows path through MSYS's mount
table: Alpine's /bin/sh -> /bin/busybox becomes a link to
C:\\Program Files\\Git\\usr\\bin\\busybox, which no Linux walk can follow,
so every busybox applet is missing. This remakes each link whose target in
the archive is absolute as a native link to the same target with
backslashes, \\bin\\busybox, which h9 reads back as /bin/busybox and
resolves from the Linux root (src/kern/fscheck.c, h9_fs_readlinkw).
Relative links are left as tar made them.

DEPTH is how many leading names of a member's path are the Linux root
that holds it: 0 when the archive is one root (an Alpine layer), 2 for
the CI's roots.tar, whose roots are linux/alpine-<arch>. It's only used
to tell a link to a directory from one to a file, which Windows records.
"""

import os
import posixpath
import sys
import tarfile


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__.strip().splitlines()[2].strip())
    archive, dest = sys.argv[1], sys.argv[2]
    depth = int(sys.argv[3]) if len(sys.argv) == 4 else 0

    members = {}
    with tarfile.open(archive) as tf:
        for m in tf:
            members[posixpath.normpath(m.name).lstrip("/")] = m

    def key(root, names):
        return "/".join([root] + names if root else names)

    def isdir(root, target):
        """Whether target, absolute in the root at root, is a directory,
        following links in the archive as Linux would."""
        pend, cur, links = [p for p in target.split("/") if p], [], 0
        while pend:
            name = pend.pop(0)
            if name == ".":
                continue
            if name == "..":
                if cur:
                    cur.pop()
                continue
            m = members.get(key(root, cur + [name]))
            if m is None:
                return False
            if m.issym():
                links += 1
                if links > 40:
                    return False
                if m.linkname.startswith("/"):
                    cur = []
                pend = [p for p in m.linkname.split("/") if p] + pend
                continue
            cur.append(name)
        return not cur or members[key(root, cur)].isdir()

    n = 0
    for name, m in members.items():
        if not m.issym() or not m.linkname.startswith("/"):
            continue
        parts = name.split("/")
        if len(parts) <= depth:
            continue
        root = "/".join(parts[:depth])
        path = os.path.join(dest, *parts)
        if os.path.lexists(path):
            try:
                os.unlink(path)
            except (IsADirectoryError, PermissionError):
                os.rmdir(path)
        target = m.linkname.replace("/", "\\")
        os.symlink(target, path, target_is_directory=isdir(root, m.linkname))
        n += 1
    print(f"winlinks: {n} absolute links remade in {dest}")


if __name__ == "__main__":
    main()
