# Test VMs

Lima VMs for running h9 with the emu backend (`--backend emu`) on Linux,
macOS and Windows. None has a usable hypervisor (no `/dev/kvm`, no nested
Hypervisor.framework, no WHP), which is the case emu is for. Nothing is
installed for building: cross-compile h9 on the host and copy it in.

| OS | Build |
| --- | --- |
| `linux` | `zig build -Demu=unicorn -Dtarget=aarch64-linux-musl` |
| `linux-amd64` | `zig build -Demu=unicorn -Dtarget=x86_64-linux-musl` |
| `macos` | `zig build -Demu=unicorn` |
| `windows` | `zig build -Demu=unicorn -Dtarget=aarch64-windows` (Unicorn from source) |

Use `--prefix zig-out/<os>` to keep the builds apart.

| OS | Instance | Guest | VM type |
| --- | --- | --- | --- |
| `linux` | `linux` | Ubuntu 24.04 | vz |
| `linux-amd64` | `linux-amd64` | Ubuntu 24.04 x86\_64 | qemu (emulated, slow) |
| `macos` | `macos` | macOS 15.6.1 | vz |
| `windows` | `windows` | Windows 11 25H2 | qemu (hvf) |

Instances live in `.local/lima`, which `vm` uses as `LIMA_HOME`, so they don't
show up in the default `limactl list`. To use `limactl` directly:

```sh
export LIMA_HOME=$PWD/.local/lima
```

## Usage

```sh
zig build -Demu=unicorn -Dtarget=aarch64-linux-musl --prefix zig-out/linux
scripts/lima/vm up linux                    # create (first time), start, provision
scripts/lima/vm push linux zig-out/linux/bin/h9 zig-out/fixtures/hello  # into ~/h9
scripts/lima/vm shell linux ./h9/h9 --backend emu ./h9/hello
scripts/lima/vm push-root linux             # 9front root tree into ~/h9/root
scripts/lima/vm shell linux ./h9/h9 --root h9/root /bin/cat /lib/namespace
scripts/lima/vm shell windows 'cd h9 && h9.exe --root root /bin/cat /lib/namespace'
scripts/lima/vm down linux
```

`push-root` copies `.local/9front/root` (from `scripts/mkroot.py`, about
250 MB in 10k files) as one tar stream over ssh, which takes seconds where
`push` would take minutes. It writes `h9/root/.h9-root` with the tree's
name and build time, and skips the copy when that matches; `-f` forces it.
The copy is unpacked beside the old one and swapped in, so an interrupted
push leaves the old tree intact. It takes about a second on Linux and about
a minute on Windows, where NTFS and Defender are slower. On Windows, three
files are left out: rc's `"` and `""` scripts (NTFS doesn't allow `"` in
names) and troff's `charlib/☺` (Windows `tar` decodes names in the ANSI code
page, not UTF-8).

`vm status` lists the VMs, `vm shell <os>` with no command opens a shell
(`cmd.exe` on Windows), and `vm rm <os>` deletes one.

## Tests

`vm test <os>` runs the backend and integration tests in the guest on the
emulator. Build them first with the same target as the table above, adding
`install-tests`:

```sh
zig build install install-tests -Demu=unicorn -Dtarget=aarch64-linux-musl --prefix zig-out/linux
scripts/lima/vm test linux                  # both sets
scripts/lima/vm test windows integration    # just one
H9_TEST_PENDING=1 scripts/lima/vm test macos integration  # include cases of proposals that aren't implemented
```

It pushes `h9` and the test binaries from `zig-out/<os>/bin`, runs
`push-root`, then runs each set over ssh with `H9_TEST_BIN`,
`H9_TEST_ROOT` and `H9_TEST_BACKENDS=emu`. The root tree is arm64 only, so
`linux-amd64` runs just the backend tests. `H9_TEST_SLOW` multiplies the
interactive cases' timeouts; it defaults to 10 on `linux-amd64` and 3 on
`windows`, where each guest process takes about 0.4 s to start.

ssh gives the tests no terminal, so the interactive cases make their own
([tests/term.zig](../../tests/term.zig)): a pty on Linux and macOS, ConPTY
on Windows. On Windows that differs from a local console in two ways the
tests allow for: ConPTY redraws the screen rather than passing output
through, so trailing spaces can come out as cursor movements, and Windows
OpenSSH itself runs everything under ConPTY, so a manual `vm shell windows`
session behaves like the tests, not like a local console window.

Windows Defender blocks some command lines as malware: a host command line
with 79 `| cat` stages is flagged as `Trojan:Win32/Commando.A!ml`, and
CreateProcess fails with access denied. Tests that need long pipelines
build them inside rc instead.

## First boot

- **linux** boots in seconds from the Ubuntu cloud image.
- **linux-amd64** uses the same image for x86\_64, fully emulated by QEMU, so
  the first boot takes a few minutes and everything runs slowly. Use it for
  amd64 binaries, which arm64 hosts only run on the emulator.
- **macos** runs the macOS installer from Apple's restore image (about 16 GB
  download, then a few minutes). The GUI password is in `~/password` in the
  guest.
- **windows** needs the Windows 11 Arm64 installer ISO: the "English (United
  States)" Arm64 ISO from
  https://www.microsoft.com/en-us/software-download/windows11, saved as
  `~/Downloads/Win11_25H2_English_Arm64_v2.iso`, or set `WIN_ISO`. The install
  is unattended and takes about 15 minutes. At first logon, Lima's
  `first_logon.ps1` installs OpenSSH, adds Lima's ssh key and saves a random
  password in `C:\Users\<you>\password.txt`. `vm up` returns once ssh works and
  `provision.ps1` has run. Watch the VM display, but don't touch it unless the
  install gets stuck.

If the Windows install gets stuck:

1. **Setup shows no disk** at "Select location to install Windows 11": choose
   **Load driver** > Browse > the virtio-win CD > `viostor\w11\ARM64`, then
   select the disk.
2. **ssh never comes up** after the desktop appears: check
   `C:\Users\<you>\lima-setup.log`. If it doesn't end with
   `All works completed`, open right-click Start > **Terminal (Admin)** and
   run (drive letters may differ; `Get-Volume` shows them):

   ```powershell
   pnputil /add-driver E:\NetKVM\w11\ARM64\*.inf /install
   powershell -ExecutionPolicy Bypass -File F:\first_logon.ps1
   ```

   Then run `scripts/lima/vm up windows` again.

[provision.ps1](provision.ps1) is idempotent. It disables Windows Update,
sleep and hibernation, excludes `~\h9` from Defender scanning, and runs
`ngen` on the .NET Framework to speed up PowerShell startup (about 20s
before; on a fresh install it dropped to about 15s, because Windows is still
busy with first-boot work).

Windows guests run in plain mode with no shared folders, so use `vm push` to
copy files in.
