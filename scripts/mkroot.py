#!/usr/bin/env python3
"""Builds the 9front arm64 root tree from the pinned QEMU image.

Boots the image headless in QEMU (no network), tars the file system out onto
a second raw disk, and unpacks it into .local/9front/root-<release>, with
.local/9front/root pointing at it. The image itself is left untouched.

The tree leaves out what running programs doesn't need: boot kernels,
/sys/doc and, unless --src is given, /sys/src (needed for self-hosting,
design/self-host.md).
That's about 250 MB instead of 420 MB.

Usage: scripts/mkroot.py [--force] [--src]
Needs qemu-system-aarch64, qemu-img and bsdtar (or a tar that reads ustar).
"""

import atexit
import os
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
LOCAL = os.path.join(REPO, ".local")

# Top-level directories the 9front kernel supplies through #/ rather than the
# disk. h9 binds devices onto them, so they must exist in the host tree.
MOUNT_POINTS = [
    "bin", "boot", "dev", "env", "fd", "mnt", "mnt/term", "mnt/term/cwd", "mnt/wsys", "n",
    "net", "net.alt", "proc", "root", "shr", "srv", "tmp",
]
# On-disk directories left out of the export: dist holds installer payloads.
EXCLUDE = ["dist"]
# Left out when unpacking: kernels and boot files for real hardware, and
# documentation. bsdtar patterns, matched against the whole path.
SKIP = [
    "arm64/9*", "arm64/s9*", "386/9boot*", "386/*.efi", "386/efiboot.fat",
    "386/mbr", "386/pbs", "sys/doc",
]
SKIP_SRC = ["sys/src"]

PROMPT = b"H9> "


def die(msg):
    sys.exit("mkroot: " + msg)


def log(msg):
    print("mkroot: " + msg, file=sys.stderr, flush=True)


def pin(name):
    with open(os.path.join(HERE, "pins.sh")) as f:
        m = re.search(r"^%s=(\S+)" % name, f.read(), re.M)
    if not m:
        die("%s not set in scripts/pins.sh" % name)
    return m.group(1)


def run(*args):
    subprocess.run(args, check=True)


def mbr_partition(path, ptype):
    with open(path, "rb") as f:
        mbr = f.read(512)
    for i in range(4):
        e = mbr[446 + 16 * i : 446 + 16 * (i + 1)]
        if e[4] == ptype:
            return struct.unpack_from("<II", e, 8)
    die("no partition of type 0x%x in the image" % ptype)


def fat16_read(img, want):
    """Returns the bytes of a file in the root directory of a FAT16 volume."""
    bps, spc, rsv, nfats, nroot = struct.unpack_from("<HBHBH", img, 11)
    spf = struct.unpack_from("<H", img, 22)[0]
    if spf == 0:
        die("boot partition is not FAT16")
    fat = rsv * bps
    root = fat + nfats * spf * bps
    data = root + nroot * 32
    csize = bps * spc
    for off in range(root, data, 32):
        e = img[off : off + 32]
        if e[0] == 0:
            break
        if e[0] == 0xE5 or e[11] & 0x18:
            continue
        name = e[0:8].decode().strip()
        ext = e[8:11].decode().strip()
        if (name + ("." + ext if ext else "")).lower() != want:
            continue
        cl = struct.unpack_from("<H", e, 26)[0]
        size = struct.unpack_from("<I", e, 28)[0]
        out = bytearray()
        while 2 <= cl < 0xFFF8:
            out += img[data + (cl - 2) * csize : data + (cl - 1) * csize]
            cl = struct.unpack_from("<H", img, fat + 2 * cl)[0]
        return bytes(out[:size])
    die("no %s on the boot partition" % want)


class Console:
    def __init__(self, argv):
        self.p = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        atexit.register(self.close)
        self.buf = b""
        self.transcript = bytearray()

    def close(self):
        if self.p.poll() is None:
            self.p.kill()
            self.p.wait()

    def until(self, pat, timeout):
        end = time.time() + timeout
        while time.time() < end:
            m = re.search(pat, self.buf)
            if m:
                out, self.buf = self.buf[: m.start()], self.buf[m.end() :]
                return out
            if self.p.poll() is not None:
                break
            r, _, _ = select.select([self.p.stdout], [], [], 0.5)
            if r:
                d = os.read(self.p.stdout.fileno(), 65536)
                self.buf += d
                self.transcript += d
        sys.stderr.write(self.transcript[-2000:].decode("latin1"))
        die("timed out waiting for %r from the guest" % pat)

    def send(self, line):
        # The emulated UART drops input that arrives faster than rc reads it.
        for ch in (line + "\n").encode():
            self.p.stdin.write(bytes([ch]))
            self.p.stdin.flush()
            time.sleep(0.005)

    def cmd(self, line, timeout=60):
        self.send(line)
        out = self.until(PROMPT, timeout)
        return out.replace(b"\r", b"").split(b"\n", 1)[-1].decode("latin1")


def main():
    args = sys.argv[1:]
    for a in args:
        if a not in ("--force", "--src"):
            die("usage: scripts/mkroot.py [--force] [--src]")
    force = "--force" in args
    skip = SKIP + ([] if "--src" in args else SKIP_SRC)
    release = pin("NINEFRONT_RELEASE")
    image = os.path.join(LOCAL, "9front", "9front-%s.arm64.qcow2" % release)
    dest = os.path.join(LOCAL, "9front", "root-%s" % release)
    link = os.path.join(LOCAL, "9front", "root")
    if not os.path.exists(image):
        die("no %s (run scripts/fetch.sh)" % os.path.relpath(image, REPO))
    for tool in ("qemu-system-aarch64", "qemu-img", "bsdtar"):
        if not shutil.which(tool):
            die("%s not found" % tool)
    if os.path.exists(dest) and not force:
        log("%s exists (--force to rebuild)" % os.path.relpath(dest, REPO))
        return

    os.makedirs(os.path.join(LOCAL, "cache"), exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.path.join(LOCAL, "cache"), prefix="mkroot.") as tmp:
        overlay = os.path.join(tmp, "overlay.qcow2")
        run("qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", image, overlay)

        # The kernel and plan9.ini live on the image's FAT partition, which
        # U-Boot normally loads; QEMU loads them directly instead.
        fat_img = os.path.join(tmp, "fat.raw")
        start, count = mbr_partition_qcow2(image, tmp)
        run("qemu-img", "dd", "-f", "qcow2", "-O", "raw", "bs=512",
            "count=%d" % (start + count), "if=" + image, "of=" + fat_img)
        with open(fat_img, "rb") as f:
            f.seek(start * 512)
            fat = f.read()
        kernel = os.path.join(tmp, "9qemu.u")
        with open(kernel, "wb") as f:
            f.write(fat16_read(fat, "9qemu.u"))
        ini = os.path.join(tmp, "plan9.ini")
        with open(ini, "w") as f:
            f.write("console=0\nnobootprompt=local!/dev/sdF0/fs\nuser=glenda\n")

        out = os.path.join(tmp, "out.tar")
        with open(out, "wb") as f:
            f.truncate(2 << 30)

        log("booting 9front %s in QEMU" % release)
        con = Console([
            "qemu-system-aarch64", "-M", "virt-2.12,gic-version=3", "-cpu", "cortex-a72",
            "-m", "2G", "-smp", "2", "-nographic", "-nic", "none",
            "-kernel", kernel,
            "-device", "loader,file=%s,addr=0x40010000,force-raw=on" % ini,
            "-drive", "file=%s,format=qcow2,if=none,id=disk" % overlay,
            "-device", "virtio-blk-pci-non-transitional,drive=disk",
            "-drive", "file=%s,format=raw,if=none,id=out" % out,
            "-device", "virtio-blk-pci-non-transitional,drive=out",
        ])
        con.until(rb"\n% ", 300)
        con.send("prompt=('HP'^'9> ' '\t')")
        con.until(PROMPT, 30)
        cputype = con.cmd("cat /env/cputype").strip("\0 \n")
        if cputype != "arm64":
            die("guest cputype is %r, not arm64" % cputype)
        disk = con.cmd("ls /dev/sd*/data").split()
        if "/dev/sdG0/data" not in disk:
            die("output disk not found in the guest: %s" % disk)

        log("exporting the file system")
        excl = "|".join(EXCLUDE)
        res = con.cmd(
            "cd /root && tar cf /dev/sdG0/data `{ls | grep -v '^(%s)$'} && echo TAR-OK" % excl,
            1800,
        )
        if "TAR-OK" not in res:
            die("tar failed in the guest:\n" + res)
        con.cmd("fshalt", 60)
        con.close()

        log("unpacking into %s" % os.path.relpath(dest, REPO))
        staging = dest + ".tmp"
        shutil.rmtree(staging, ignore_errors=True)
        os.makedirs(staging)
        excl = [a for pat in skip for a in ("--exclude", "^" + pat)]
        run("bsdtar", "-xpf", out, "-C", staging, *excl)
        for d in MOUNT_POINTS:
            os.makedirs(os.path.join(staging, d), exist_ok=True)
        shutil.rmtree(dest, ignore_errors=True)
        os.rename(staging, dest)

    if os.path.islink(link) or os.path.exists(link):
        os.remove(link)
    os.symlink(os.path.basename(dest), link)
    for f in ("lib/namespace", "arm64/bin/cat", "arm64/bin/rc"):
        if not os.path.isfile(os.path.join(dest, f)):
            die("tree is missing %s" % f)
    log("done: .local/9front/root -> %s" % os.path.basename(dest))


def mbr_partition_qcow2(image, tmp):
    mbr = os.path.join(tmp, "mbr.raw")
    run("qemu-img", "dd", "-f", "qcow2", "-O", "raw", "bs=512", "count=1",
        "if=" + image, "of=" + mbr)
    # Partition type 0x0B is FAT32 in the table, but 9front formats it FAT16.
    return mbr_partition(mbr, 0x0B)


if __name__ == "__main__":
    main()
