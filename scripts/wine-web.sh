#!/usr/bin/env bash
# Makes the web demo's Wine root at .local/linux/wine-web, which
# `zig build web` packs into zig-out/web/wine.h9a with src/web/wine.list
# for the demo page's ?wine mode (site/wine.html):
#
#   scripts/wine-root.sh 386            # Alpine's 32-bit Wine, .local/linux/wine-386
#   scripts/fetch.sh wine && zig build wine
#   zig build -Demu=zig -Dgfx=headless -Doptimize=ReleaseSafe
#   scripts/wine-web.sh
#
# It's the 386 Wine root with winedraw installed and a prefix made ahead
# of time at /root/.wine: wineboot is two minutes on h86, too long for a
# page. The prefix draws through winedraw on a 1024x768 Wine desktop with
# a taskbar, and has shortcuts to Wine's own classic programs on the
# desktop and in the Start menu. The prefix is made by h9 itself, on the
# emulator, as the browser would run it: H9 names the h9 to use (default
# zig-out/bin/h9, which must have the emu backend and graphics: Wine's
# shell needs its display driver to make the shortcuts).
set -euo pipefail
. "$(dirname "$0")/env.sh"

src="$H9_LOCAL/linux/wine-386"
dir="$H9_LOCAL/linux/wine-web"
out="$H9_ROOT/zig-out/wine"
h9=${H9:-$H9_ROOT/zig-out/bin/h9}
[ -x "$src/usr/bin/wine" ] || { echo "wine-web: no $src; run scripts/wine-root.sh 386" >&2; exit 1; }
[ -f "$out/i386-unix/winedraw.so" ] || { echo "wine-web: no $out/i386-unix; run zig build wine" >&2; exit 1; }

rm -rf "$dir" "$dir.tmp"
cp -a "$src" "$dir.tmp"
cp "$out"/i386-unix/{winedraw.so,roundf386.so} "$dir.tmp/usr/lib/wine/i386-unix/"
cp "$out/i386-windows/winedraw.drv" "$dir.tmp/usr/lib/wine/i386-windows/"
mkdir -p "$dir.tmp/root"
zig cc -target x86-windows-gnu -municode -O2 -o "$dir.tmp/root/mklnk.exe" \
	"$H9_ROOT/src/wine/mklnk.c" -lole32 -luuid -lshell32

# The prefix is made in /mnt/term/cwd, the root's own /root, so that it
# lands in the tree rather than in the run's overlay.
cat >"$dir.tmp/root/setup.sh" <<'EOF'
set -e
# Wine names the prefix's profile, C:\users\$USER, from USER, which h9
# sets from the host's user. The page runs Wine as root (src/web/index.html).
export USER=root LOGNAME=root
export WINEPREFIX=/mnt/term/cwd/.wine
wineboot -i
reg() { wine reg add "$@" /f >/dev/null; }
reg 'HKCU\Software\Wine\Drivers' /v Graphics /d draw
# No menu entries for a host desktop, and Windows' classic look rather
# than Wine's theme, which the archive leaves out.
reg 'HKCU\Software\Wine\DllOverrides' /v winemenubuilder.exe /d ''
reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ThemeManager' /v ThemeActive /d 0
reg 'HKCU\Software\Wine\Explorer' /v Desktop /d shell
reg 'HKCU\Software\Wine\Explorer\Desktops' /v shell /d 1024x768
# Where the programs open, below the desktop's icons.
reg 'HKCU\Software\Microsoft\WinMine' /v Xpos /t REG_DWORD /d 600
reg 'HKCU\Software\Microsoft\WinMine' /v Ypos /t REG_DWORD /d 130
for v in X:150 Y:160 DX:520 DY:380; do
	reg 'HKCU\Software\Microsoft\Notepad' /v "iWindowPos${v%%:*}" /t REG_DWORD /d "${v#*:}"
done
for v in startX:90 startY:110 width:640 height:440; do
	reg 'HKCU\Software\Wine\WineFile' /v "${v%%:*}" /t REG_DWORD /d "${v#*:}"
done
desk='C:\users\Public\Desktop'
menu='C:\ProgramData\Microsoft\Windows\Start Menu\Programs'
# Run by its Windows path: a Unix path to the .exe would need a D: drive
# (docs/windows.md, section 3).
cp /mnt/term/cwd/mklnk.exe "$WINEPREFIX/drive_c/"
# Each line: program, name, Start menu folder, and an icon for a program
# without one of its own (Clock's is shell32's resource 21, a clock;
# Wine's desktop leaves out a shortcut it has no icon for).
while IFS='|' read -r exe name folder icon; do
	set -- "$exe" "$name"
	[ -z "$icon" ] || set -- "$@" "${icon%,*}" "${icon##*,}"
	wine 'C:\mklnk.exe' "$desk\\$name.lnk" "$@"
	wine 'C:\mklnk.exe' "$menu\\$folder\\$name.lnk" "$@"
done <<'LIST'
C:\windows\system32\winemine.exe|Minesweeper|Games|
C:\windows\system32\notepad.exe|Notepad|Accessories|
C:\windows\system32\clock.exe|Clock|Accessories|C:\windows\system32\shell32.dll,-21
C:\windows\system32\winefile.exe|File Manager|Accessories|
C:\Program Files\Windows NT\Accessories\wordpad.exe|WordPad|Accessories|
C:\windows\system32\cmd.exe|Command Prompt|Accessories|
C:\windows\regedit.exe|Registry Editor|System Tools|
C:\windows\system32\taskmgr.exe|Task Manager|System Tools|
LIST
rm "$WINEPREFIX/drive_c/mklnk.exe"
wineserver -w
EOF

"$h9" --backend emu --arch 386 --gfx --root "$dir.tmp" --cwd "$dir.tmp/root" \
	--env HOME=/root --env WINEDEBUG=-all \
	--env LD_PRELOAD=/usr/lib/wine/i386-unix/roundf386.so \
	sh /mnt/term/cwd/setup.sh
rm "$dir.tmp/root/setup.sh" "$dir.tmp/root/mklnk.exe"
# The prefix's C: and Z: are links, which the web archive doesn't keep;
# the page makes them (src/web/index.html, ?wine).
rm -f "$dir.tmp/root/.wine/dosdevices/"*
# Wine updates a prefix older than its wine.inf, by mtime, which the
# archive doesn't keep either: that's wineboot's two minutes again, at
# every start. "disable" tells it not to.
echo disable >"$dir.tmp/root/.wine/.update-timestamp"
mv "$dir.tmp" "$dir"
echo "linux/wine-web: $(du -sh "$dir/root/.wine" | cut -f1) prefix"
