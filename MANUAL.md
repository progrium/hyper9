# h9 Manual

> This manual is for people *using* h9, the command-line program from the
> Hyper9 project, including people who have never used Plan 9.
> [DEVELOPING.md](DEVELOPING.md) is the place for build and test instructions, and
> [SPEC.md](SPEC.md) for internals. It describes h9 as built on `main`;
> features that aren't built yet are marked with the proposal that adds them
> (see Conventions).

## Conventions used in this manual

- `host$` is a prompt on the host shell (bash, zsh, PowerShell); `%` is rc
  inside h9.
- Every Plan 9 concept chapter has the same three parts: **In Plan 9** (how the
  real system works), **In h9** (what h9 does the same, differently, or not
  yet), and **Try it** (commands to paste).
- Badges: *Not yet available ([gfx](design/0015-gfx.md))* marks something
  that isn't built yet, linked to the [proposal](design/README.md) that adds
  it. A badge comes off when its proposal is marked implemented. A feature
  whose proposal was declined is said to be declined, with a link to why.
- Man page references use Plan 9's form, `bind(1)`, `intro(5)`. Read them
  inside h9 with `h9 man 1 bind`, or online at
  [man.9front.org](https://man.9front.org/).
- Output shown for host paths uses a Mac with the user `me`, h9 checked out
  at `~/src/hyper9`, and the default root tree in
  `~/src/hyper9/.local/9front/root`. Your paths, pids, and counts will differ.

---

## Part I: Getting started

### 1. What h9 is

h9 runs 9front programs on macOS, Linux, and Windows as if they were host
programs. There's no virtual machine image to download, nothing boots, and no
Plan 9 kernel runs inside a guest. You type `h9 ls`, and 9front's own `ls`
binary runs and prints your directory, in a few milliseconds.

9front is the actively maintained fork of Plan 9 from Bell Labs, the operating
system the Unix team built next. Its programs are small, its shell is rc, and
its central idea is that everything, from devices to the network to other
machines, is a file tree that each process can rearrange for itself. Part II
explains all of that; this chapter explains what h9 does with it.

#### One invocation is one machine

The one idea to carry through this manual:

> **Each time you run h9, you start a small, complete Plan 9 machine.** It
> has its own namespace (its view of the file tree), its own environment, its
> own console, its own processes, and its own `/srv`. It exists only as long
> as the program you started, and when that program exits, the machine and
> everything in it disappear.

So `h9 rc` gives you a shell in a fresh machine, and every command you run
in that shell runs in the same machine. Two `h9` commands in a row, on the
other hand, are two separate machines that share nothing but the files on your
disk. Changes you make to the namespace, the environment, `/tmp`, or the set
of running programs never outlive the h9 invocation.

#### How it works, briefly

```text
 ┌─────────────────────── h9 (one host process) ───────────────────────┐
 │                                                                     │
 │   9front programs (rc, ls, mk, ...)       each on its own virtual   │
 │   running native machine code            CPU, isolated by the host  │
 │            │                              hypervisor                │
 │            │ system calls                                           │
 │            ▼                                                        │
 │   Plan 9 kernel (from drawterm)  ── namespaces, devices, 9P, pipes  │
 │            │                                                        │
 │            │ only what the sandbox policy allows                    │
 └────────────┼────────────────────────────────────────────────────────┘
              ▼
   host files, terminal, network
```

Each Plan 9 program runs as real machine code on a virtual CPU from your
host's hypervisor (Hypervisor.framework on macOS, KVM on Linux, and the
Windows Hypervisor Platform on Windows x86\_64).
When a program makes a system call, it
doesn't reach your host's kernel. It's answered by a Plan 9 kernel that runs
inside the h9 process: the kernel from drawterm, Plan 9's remote terminal
program. That kernel decides which of your host's files, and how much of the
network, the program can see. Chapter 23 covers that sandbox.

On Linux x86\_64 hosts without KVM, such as containers and many cloud VMs,
h9 can run amd64 programs directly on the CPU, in a small helper process
whose system calls it traps (the native backend) — but that backend shares
h9's own process and isn't a sandbox, so you choose it explicitly, with
`--backend native`, for a program you trust (chapter 23). On other hosts
without a usable hypervisor, such as most Windows machines and CI runners,
`h9-emu` runs the same programs in a CPU emulator: slower for heavy
computation, but otherwise identical (chapter 27).

h9 runs Linux programs too. A Linux binary's system calls are answered by
the same Plan 9 kernel, so it gets the same sandbox, and Linux and 9front
programs can share one machine (chapter 20).

#### How h9 differs from other ways to run Plan 9

| If you know... | h9 is different because... |
| --- | --- |
| 9front in QEMU or on hardware | Nothing boots and there's no disk image or drivers. h9 starts in milliseconds and runs one program, not a whole system. |
| drawterm | drawterm connects your computer to a remote Plan 9 cpu server, where the programs run. h9 uses drawterm's kernel but runs the programs on your computer. |
| plan9port | plan9port is Plan 9's tools rewritten to run on Unix. h9 runs the actual, unmodified 9front binaries. |
| 9vx | 9vx is h9's closest ancestor: 9front binaries on a host, in a software sandbox. h9 uses the hardware hypervisor instead, and runs on current hosts. |

[How h9 compares](docs/comparison.md) goes wider, to containers, sandboxes
and compatibility layers.

#### What h9 doesn't do

- It doesn't run the 9front kernel, so there are no hardware drivers and no
  9front boot process. Kernel features come from drawterm's kernel and h9
  itself, so a few are missing or still being built (badges in this manual
  mark them).
- It runs your host's architecture on the hypervisor: arm64 9front programs
  on arm64 hosts, and amd64 programs on x86\_64 hosts. The emulator can also
  run amd64 programs on arm64 hosts and 386 programs anywhere, but that's
  for testing (and for Go programs, chapter 19).
- It runs 9front programs and Linux ELF programs, not those of the original
  Plan 9 or other forks, whose system calls differ, nor macOS or Windows
  programs.
- It isn't a long-running service. Every invocation is its own machine.

### 2. Installing

h9 needs two things: the `h9` program, and a **root tree**, a 9front file
system that h9 serves to programs as `/`. The root tree holds every 9front
program and library file, so it's where `ls` and `rc` come from. Usually it's
a directory extracted from the 9front release image; it can also be a 9P file
server on the network (chapter 16).

> **Note:** h9 hasn't had a release yet, so for now both come from building
> from source, as below. When releases exist, the binaries will come from the
> project's [GitHub releases page](https://github.com/progrium/hyper9/releases).

#### Which binary

| Binary | License | Runs programs with |
| --- | --- | --- |
| `h9` | MIT | Your host's hypervisor; on Linux x86\_64 without KVM, the native backend only when you ask for it (`--backend native`, for a trusted guest) |
| `h9-emu` | GPLv2 | The same, or the Unicorn CPU emulator when neither is usable |

The two take the same flags and behave the same way; `h9-emu` is a separate
program because Unicorn is GPL-licensed. Use `h9` where it works, and
`h9-emu` on Windows on ARM, on Windows x86\_64 without the Windows
Hypervisor Platform, on Macs for amd64 programs, and on arm64 Linux VMs
without nested virtualization. This manual says `h9` throughout; everything applies
to `h9-emu` too. (When you build `h9-emu` from source it's still called
`zig-out/bin/h9`; the release scripts rename it.)

| Host | `h9` | `h9-emu` |
| --- | --- | --- |
| macOS on Apple Silicon | ✓ (Hypervisor.framework) | ✓ |
| Linux arm64 | ✓ (KVM; built, but not yet run on an arm64 KVM host, [#92](https://github.com/progrium/hyper9/issues/92)) | ✓ |
| Linux x86\_64 | ✓ (KVM; without it, `h9-emu`, or `--backend native` for a trusted guest), with an amd64 root tree (`zig build mkroot` on x86\_64) | ✓, with an amd64 root tree |
| Windows on ARM | *Not yet available ([whp](design/0017-whp.md))* | ✓ |
| Windows x86\_64 | ✓ (WHP, with the Windows Hypervisor Platform feature), with an amd64 root tree | ✓, with an amd64 root tree |

**Host requirements.** On macOS, h9 must be signed with the hypervisor
entitlement in `h9.entitlements`; `zig build` does that, and release binaries
will come signed. `h9-emu` needs nothing special. On Linux, KVM needs read
and write access to `/dev/kvm` (usually by being in the `kvm` group), and in
a VM, nested virtualization. Without them, `auto` won't run on Linux x86\_64:
use `h9-emu`, or `--backend native` for a program you trust (the native
backend shares h9's process and isn't a sandbox; it needs Linux 5.11 or
later, for Syscall User Dispatch, and seccomp). `h9 --check` tells you which
backends work and why the others don't. On Windows x86\_64, the WHP backend needs the optional Windows
Hypervisor Platform feature; without it, `h9-emu` falls back to the
emulator.

#### Building from source

On a Mac with Zig 0.16 and Xcode installed:

```sh
host$ git clone https://github.com/progrium/hyper9 && cd hyper9
host$ . scripts/env.sh       # Zig's cache and tools under .local/; puts zig-out/bin on PATH
host$ ./scripts/fetch.sh     # downloads the pinned 9front release and other sources
host$ zig build              # builds and signs zig-out/bin/h9
host$ zig build -Demu=unicorn   # or: h9 with the emulator built in (h9-emu)
```

[DEVELOPING.md](DEVELOPING.md) has the details, including cross-building for Linux
and Windows.

#### Getting a root tree

```sh
host$ brew install qemu
host$ zig build mkroot      # about a minute; ~250 MB in .local/9front/root
```

`zig build mkroot` boots the pinned 9front release image in QEMU, without a
window, copies its file system out, and unpacks it into `.local/9front/root`.
It leaves out the hardware kernels, `/sys/doc`, and the source code; pass
`--src` (`zig build mkroot -- --src`) to keep `/sys/src`, which you need to
build 9front programs inside h9 (chapter 18). The tree has binaries for
your machine's architecture unless `--arch` names others (`--arch arm64`,
`--arch 386,amd64`). The image's binaries are arm64; `/386` and `/amd64` are
built by compiling `/sys/src` inside h9, which takes a built
`zig-out/bin/h9`. Each architecture takes a few minutes on an arm64
hypervisor, but about an hour on the emulator, which x86\_64 hosts need
because the compilers are arm64. On an existing tree it
only adds what's missing. Appendix C describes what's in the tree.

h9 looks for its root in this order:

1. `--root` on the command line.
2. The `H9ROOT` environment variable.
3. `.local/9front/root` in the source tree, when you run the `h9` that
   `zig build` put in `zig-out/bin`.
4. The built-in root, a small read-only tree inside the h9 binary.

`--root` and `H9ROOT` take a directory, or a 9P server: a dial string such
as `tcp!fs.example.com!564`, `unix!/path/to/socket`, the path of a unix
socket, or a WebSocket URL (chapter 16). A `--root` directory can also be a
Linux root, such as Alpine's, which comes on top of the 9front root rather
than replacing it (chapter 20).

So the development build finds its tree on its own. If you copy `h9`
somewhere else, such as onto your `PATH`, set `H9ROOT` in your shell profile:

```sh
host$ export H9ROOT=~/src/hyper9/.local/9front/root
```

The built-in root is what lets a fresh install work with nothing but the
h9 binary. It holds 42 of 9front's commands, built from the pinned
release's own source into one program, `9box`: rc, the file and text tools
(`ls`, `cat`, `sed`, `awk`, `grep`, `diff`, and so on), `tar` and `gzip`, and
the namespace tools (`bind`, `mount`, `ns`, `ps`, `srv`, `exportfs`,
`ramfs`). Everything else in the namespace, your cwd, `/tmp`, and the
sandbox, is the same as over a full tree:

```sh
host$ h9 --rc 'echo hi | sed s/hi/ho/; pwd'
ho
/mnt/term/cwd
```

Compilers, `mk`, `rio`, fonts, the manual, and sources are only in the full
tree. A command that isn't in the built-in root says so:

```sh
host$ h9 mk
h9: mk: not found (not in the built-in root; pass --root or set H9ROOT for the full 9front tree)
```

`--builtin` changes how the built-in root is used. `--builtin=only` uses it
even when `H9ROOT` or the development tree would give a root. With a root,
`--builtin=before` puts its commands in `/bin` ahead of the root's, which
saves reading them from a slow 9P or WebSocket root, and `--builtin=after`
puts them behind, to fill in commands a slim root lacks. `--builtin=off`
turns it off: then, without a root, h9 can still run a program from a host
path (`h9 ./prog`), but the program sees only the kernel's devices, and
anything else is an error (exit 125).

A development build embeds the commands only if `zig build slim` has made
them for the architecture (chapter 18); otherwise `zig build` warns, and the
built-in root has its directories but no commands.

#### Checking the install

`h9 --check` tries each backend built into h9 and the root, one line each,
and exits 0 if h9 can run programs from the root (125 if not):

```sh
host$ h9 --check
h9 v0.1.0-123-gfe6c65f on macos aarch64
backend hvf: ok, 64 vCPUs, hello in 2.8 ms
backend auto: ok (uses hvf), 64 vCPUs, hello in 1.1 ms
gfx cocoa: built in
root /Users/me/src/hyper9/.local/9front/root-11952: ok, /bin/echo runs (arm64)
```

Each backend line runs a tiny test program in a new machine, so a failure
there names the problem (see the table below). `h9-emu` adds a `backend emu`
line. `auto` is the backend h9 uses unless you pass `--backend`; with
`--backend`, only that one is checked. The vCPU count is the hypervisor's
limit (see chapter 8). The `gfx` line says whether `--gfx` can open a window
(chapter 17). The version is `git describe` for a development build
and the release's version for a release. The root line shows the root with
symlinks resolved, so `root` appears as `root-11952`, the release it came
from.

On a Linux x86\_64 VM without KVM and with no root tree, it looks like
this:

```sh
host$ h9 --check
h9 fe6c65f on linux x86_64
backend kvm: no /dev/kvm (no KVM in this kernel, or a VM without nested virtualization)
backend native: ok, hello in 2.8 ms
backend auto: ok (uses native), hello in 1.9 ms
gfx: not built in
root: built-in (9front 11952 slim, amd64; no tree found): ok, /bin/echo runs (amd64)
```

`h9 --version` prints the h9 version, the 9front release, and drawterm
revision it was built against, the backends built in, the window code
(`gfx:`), and what the built-in root holds:

```sh
host$ h9 --version
h9 fe6c65f
9front 11952 (602faae9a52f)
drawterm be39bbaa88fd
backends: kvm native
gfx: none
built-in root: 9front 11952 slim, amd64 (42 commands)
```

`h9 --help` (or `h9 -h` alone) prints the usage. Then run something:

```sh
host$ h9 echo hello
hello
host$ h9 --rc 'cat /dev/sysname; echo; echo $cputype'
h9
arm64
```

If this fails, the message says why:

| Message | Exit | Fix |
| --- | --- | --- |
| `h9: root DIR: not found` | 125 | Check `--root` or `H9ROOT`, or run `zig build mkroot` |
| `h9: root DIR: not a directory or socket` | 125 | `--root` names a plain file |
| `h9: no root tree found; pass --root or set H9ROOT` | 125 | Only with `--builtin=off`; see the lookup order above |
| `h9: mk: not found (not in the built-in root; ...)` | 127 | The command is only in the full tree: pass `--root` or set `H9ROOT` |
| `h9: cannot create auto machine for arm64: no usable hypervisor (is h9 signed with h9.entitlements?)` | 125 | Build with `zig build`, which signs it, or use `h9-emu` |
| `h9: cannot create emu machine for arm64: the emulator isn't built into this h9 (use h9-emu from the releases, or build with -Demu=unicorn)` | 125 | Use `h9-emu` |
| `h9: warning: no usable hypervisor; using the emulator` | | Not an error: `h9-emu` fell back to the emulator |
| `h9: cannot create kvm machine for amd64: no access to /dev/kvm (is your user in the kvm group?)` | 125 | Only with `--backend kvm`: add yourself to the `kvm` group, or leave `--backend` off |
| `h9: warning: the native backend runs guest code in h9's own process and is not a security boundary` | | Not an error: `--backend native` was chosen; use a hypervisor or `h9-emu` to contain an untrusted guest |
| `h9: cannot create native machine for amd64: the kernel has no Syscall User Dispatch (Linux 5.11 or later)` | 125 | Upgrade the kernel, or use `h9-emu` |

### 3. First run

#### Running a program

Give h9 a program name and its arguments, as you would at your host's shell:

```sh
host$ cd ~/notes
host$ h9 ls
notes.txt
todo.txt
host$ h9 wc -l todo.txt
     12 todo.txt
host$ h9 cat /lib/namespace
# kernel devices
bind #c /dev
...
```

`ls` listed your host directory because h9 shares the directory you run it
from with the machine: it appears inside as `/mnt/term/cwd`, and it's the
program's working directory. The rest of your host's files aren't visible.
`/lib/namespace`, on the other hand, is a file from the root tree. Chapter 6
explains how these two worlds are joined into one file tree, and chapter 22
how to share more host directories.

Everything after the program name goes to the program, so `h9 ls -l` passes
`-l` to `ls`. h9's own options are long flags (`--root`, `--rc`, and so on)
and must come *before* the program name:

```sh
host$ h9 --profile=tight ls -l     # --profile is h9's; -l is ls's
```

Plan 9 programs use single-letter flags and few of them; their `ls` has no
`--color` and no `-h`. Chapter 14 and Appendix B help with the differences.

#### An interactive shell

`h9 rc` starts rc, Plan 9's shell, with a `%` prompt:

```text
host$ h9 rc
% pwd
/mnt/term/cwd
% echo $user $cputype
me arm64
% exit
host$
```

Type `exit` or Ctrl-D to leave; the machine ends with the shell. Ctrl-C
interrupts the command you're running and rc prompts again; a second Ctrl-C
within a second ends the whole machine.

Line editing at the prompt is your host terminal's: Backspace works, but
there's no history, arrow keys, or tab completion. In Plan 9 those belong to
the window system, not the shell. Chapter 10 is an rc primer for bash and zsh
users, and chapter 13 explains the console.

#### Running a shell command line

`--rc` runs one rc command line in the machine, so pipes, redirections, and
`;` happen inside Plan 9:

```sh
host$ h9 --rc 'ls /bin | wc -l'
    453
host$ h9 --rc 'echo $1 and $2' first second
first and second
```

Use single quotes on the host so your host shell leaves `$`, `|`, and `;`
alone. Arguments after the command line become rc's `$*`.

Compare these two:

```sh
host$ h9 --rc 'ls | wc -l'    # one machine: Plan 9's ls piped to Plan 9's wc
host$ h9 ls | wc -l           # Plan 9's ls piped to your host's wc
```

Both work. h9 reads from standard input and writes to standard output and
standard error like any host program, so it fits into host pipelines and
scripts.

**Scripts.** rc scripts (files starting with `#!/bin/rc`) in the machine,
including many 9front commands such as `man`, `lc`, `kill`, and `hget`,
run directly: `h9 man 1 bind`. A script named by a host path
(`./script.rc`) can't be run directly yet: h9 reports `not a 9front
executable` (*Not yet available ([host-scripts](design/host-scripts.md))*).
Run it through rc instead, as `h9 rc script.rc`, or by its guest path,
`h9 /mnt/term/cwd/script.rc`.

#### How h9 finds the program

| You write | h9 runs |
| --- | --- |
| `h9 ./hello`, `h9 ../bin/hello` | A file on the **host**, relative to your current directory. It doesn't need to be anywhere the machine can see. It must be a 9front a.out or a Linux ELF binary (chapter 20), not a script. |
| `h9 ls`, `h9 aux/vga` | A program found through the machine's `$path`, which is `(. /bin)`: the current directory, then `/bin`. With a Linux root, the Linux `PATH` instead (chapter 20). |
| `h9 /bin/ls` | A path **inside the machine**. `/Users/me/prog` isn't a host path here; inside, your cwd is `/mnt/term/cwd`. |
| `h9 --rc 'cmd'` | `/bin/rc -c 'cmd'` |
| `h9 --rc` | A login rc, which runs the root's default command from `/rc/lib/rcmain.local` |

On Windows, `.\hello` is a host path too. Chapter 21 has the complete rules.

#### Exit status

A Plan 9 program exits with a string, not a number: an empty string means
success, and anything else says what went wrong. h9 turns that string into a
host exit status. A string that's a plain number from 1 to 255 becomes that
number, silently, so rc's `exit 3` exits 3. Any other string becomes 1, and
h9 prints it to standard error:

```sh
host$ h9 --rc 'exit oops'; echo $?
oops
1
host$ h9 --rc 'exit 3'; echo $?
3
```

| Status | Meaning |
| --- | --- |
| 0 | The program succeeded |
| 1–255 | The program exited with that number as its string (`exit 3` in rc, `os.Exit(3)` in Go); nothing is printed |
| 1 | The program failed with any other string, which is printed on standard error |
| 2 | h9's command line was wrong; h9 prints its usage or the conflict |
| 125 | h9 itself failed: no root tree, no hypervisor, not enough memory, a 9P root that can't be reached, a `--serve` address in use |
| 126 | The program isn't a 9front executable for this machine (chapter 29) |
| 127 | The program wasn't found |

When h9 itself fails (2, 125–127), it always prints a message starting with
`h9:`, and a numeric exit string never prints anything, so a host script can
tell "the Plan 9 program failed" from "h9 couldn't run it" even if a program
exits with 125 on purpose:

```sh
if h9 grep -s TODO main.c; then echo "has TODOs"; fi
```

### 4. A ten-minute tour

This tour runs one interactive session and visits each idea Part II explains,
with a link to the chapter that does. Make a scratch directory with a small
rc script in it, then start a shell:

```sh
host$ mkdir tour && cd tour
host$ printf '#!/bin/rc\necho hello, $1\n' > greet && chmod +x greet
host$ h9 rc
%
```

**1. Where am I?** ([Namespaces](#6-namespaces))

```text
% pwd
/mnt/term/cwd
% ls
greet
% ls /
/386
/acme
/adm
...
```

`/` is the 9front root tree, under a copy-on-write overlay: you can change
it, but the changes live in memory and are gone when h9 exits, and the tree on
your host is never written. Your host directory is mounted inside
it at `/mnt/term/cwd`, read-write; `/mnt/term` is where Plan 9 traditionally
puts the files of the terminal you're sitting at. Nothing else on your host is
visible.

**2. Devices are files.** ([Everything is a file server](#5-everything-is-a-file-server), [Kernel devices](#7-kernel-devices-and--names))

```text
% ls /dev | sed 4q
/dev/bintime
/dev/cons
/dev/cons
/dev/consctl
% cat /dev/sysname; echo
h9
% cat /dev/time
 1793983803   1793983803567348707   1793983803567349142            1000000000
% echo hello > /dev/cons
hello
```

There are no device nodes or ioctls in Plan 9. `/dev/cons` is the console,
here your host terminal, and the clock, the machine's name, and the random
number generator are files you read. (`/dev/cons` is listed twice because
`/dev` is a union of two devices that both have one; the first wins.)

**3. Union directories.** ([Namespaces](#6-namespaces))

```text
% greet world
hello, world
% cd /
% greet world
greet: file does not exist: '/bin/greet'
% bind -a /mnt/term/cwd /bin
% greet again
hello, again
% ls /bin/greet
/bin/greet
% cd /mnt/term/cwd
```

`greet` ran at first because `$path` includes `.`. After `cd /` it didn't, so
`bind -a` added your directory to the *end* of `/bin`. `/bin` is now a union
of three directories: 9front's programs, its rc scripts, and yours. Plan 9 has
no long `$PATH`; it has one `/bin` that each process can assemble as it likes,
and the change affects only this machine, and only this shell and the
programs it starts.

**4. A private namespace.** ([Namespaces](#6-namespaces), [Processes](#8-processes))

```text
% @{ rfork n; bind /mnt/term/cwd /lib; ls /lib }
/lib/greet
% ls /lib | sed 1q
/lib/1oct1993
```

`@{ }` runs commands in a child shell, and `rfork n` gives it its own copy of
the namespace. Its `bind` replaced `/lib` with your directory, for that child
alone; the shell outside still sees 9front's `/lib`. No privileges are needed:
rearranging the file tree is an ordinary thing for any process to do.

**5. The environment is files.** ([The environment](#11-the-environment), [The rc shell](#10-the-rc-shell))

```text
% name=(one two three)
% echo $#name $name(2)
3 two
% cat /env/cputype; echo
arm64
% xd -c /env/name
0000000   o  n  e 00  t  w  o 00  t  h  r  e  e 00
000000e
% echo $home
/usr/me
```

rc variables are lists, and every variable is a file in `/env`, its elements
separated by NUL bytes. h9 doesn't pass your host's environment in: the
machine starts with a few standard variables such as `user`, `home`,
`cputype`, and `path`, plus any you give with `--env`.

**6. Exit strings.** ([Processes](#8-processes))

```text
% ls /nonexistent
ls: /nonexistent: file does not exist: '/nonexistent'
% echo $status
ls 12: errors
```

`$status` is the failed program's exit string, prefixed with its name and
process ID. Programs report errors in words; there are no errno numbers.

**7. The network is files.** ([Networking](#15-networking))

```text
% ls /net
/net/cs
/net/tcp
/net/udp
% cat /net/tcp/clone; echo
0
```

Opening `/net/tcp/clone` reserved TCP connection 0, at `/net/tcp/0`; writing
`connect 9front.org!80` to its `ctl` file would dial it. Programs normally use
the `dial` library or `hget` instead. By default h9 lets programs connect
out but not listen.

**8. Processes and notes.** ([Processes](#8-processes), [Notes](#9-notes-plan-9s-signals))

```text
% sleep 1000 &
% ps | grep sleep
me             14    0:00   0:00       64K Sleep    sleep
% kill sleep
@{echo kill>/proc/14/note} # sleep
% kill sleep | rc
```

`kill` doesn't kill anything: it prints the rc commands that would, writing
`kill` to the process's `note` file in `/proc`. Piping its output to rc runs
them. Plan 9's signals are text messages called notes.

**9. File servers.** ([File servers](#16-file-servers-srv-and-9p-mounts))

```text
% ramfs -S scratch
% mkdir /tmp/scratch
% mount -c /srv/scratch /tmp/scratch
% echo hi > /tmp/scratch/f
% ls /tmp/scratch
/tmp/scratch/f
```

`ramfs` is an ordinary program that serves an in-memory file tree over 9P. It
posts its connection in `/srv`, and `mount` attaches it to the namespace. Every
service in Plan 9, from the window system to FTP sites to mail, is a program
like this. (On 9front `mntgen` makes `/n/scratch` for you; h9 has no
`mntgen`, so the tour uses the machine's private `/tmp`.)

**10. The view from outside.** ([Namespaces](#6-namespaces), [Sandboxing](#23-sandboxing))

Leave the shell, and ask h9 to describe the machine it would build, without
running anything:

```text
% exit
host$ h9 --print rc
profile:  default
enforces: env.scrub fs.read.scope fs.write.overlay fs.write.scope ipc.restrict kernel.isolation net.outbound
limits:   write=overlay net=outbound
devmask:  #C #U #b #i #m
namespace:
  bind '#U/Users/me/src/hyper9/.local/9front/root-11952' / ro
  bind -c '#O' /                                         eph  # /Users/me/src/hyper9/.local/9front/root-11952
  bind '#c' /dev
  bind -b '#y<id>' /dev
  bind -c '#e' /env
  bind '#d' /fd
  bind '#p' /proc
  bind -c '#s' /srv
  bind '#I' /net
  bind -a '#ℏ' /net  # WebSockets, under --net
  bind '/arm64/bin' /bin
  bind -a '/rc/bin' /bin
  bind -a '#H/bin' /bin  # h9's commands
  bind -c '#O' /tmp                                      eph  # /Users/me/src/hyper9/.local/9front/root-11952/tmp
  bind -c '#U/Users/me/tour' /mnt/term/cwd               rw
access:
  eph  /Users/me/src/hyper9/.local/9front/root-11952
  rw   /Users/me/tour
caveats:
  ...
```

The namespace section is the list of `bind` commands that built the file
tree you just explored. `#U` is the host's file system, `#c` the console, `#e`
the environment, `#p` the processes, `#s` the service registry, `#I` the
network, `#ℏ` WebSockets, `#H` h9's own commands, and `#O` an overlay in
memory, over the root and over `/tmp`, that keeps your changes off the host. Each `#`
name is a kernel device, and the `devmask` line says which ones a program
can't attach again, so it can't reach more of your host than this list
allows. That's how h9's sandbox works, and chapter 23 explains the rest.

---

## Part II: Plan 9 for h9 users

### 5. Everything is a file server

**In Plan 9**

Plan 9 has one way to reach a resource: a file tree served over one protocol,
9P. Devices, the network, windows, the environment, process control, and
remote machines are all files you open, read, and write. To control something
you write a text command to its `ctl` file; to ask about it you read a text
file. There's no `ioctl`, no socket API, and no binary `/proc`.

| Unix mechanism | Plan 9 equivalent |
| --- | --- |
| `ioctl(fd, ...)` | `echo command > .../ctl` |
| Sockets, `connect`, `bind`, `listen` | `/net/tcp/clone`, `ctl`, and `data` files (chapter 15) |
| Signals | Notes, written to `/proc/n/note` (chapter 9) |
| `/proc` (binary, OS-specific) | `/proc/n/status`, `ctl`, `note`, `ns`, `fd`: plain text |
| `getenv`, `setenv` | Files in `/env` (chapter 11) |
| `mount -t nfs`, FUSE | Any program that speaks 9P, mounted with `mount` (chapter 16) |
| `/dev/tty`, termios | `/dev/cons` and `/dev/consctl` (chapter 13) |

9P has a dozen or so messages, and they map onto what a program does with a
file: **attach** to a server's root, **walk** to a name, **open** it,
**read** and **write** it, **stat** and **wstat** its metadata, and
**clunk** it (close). Anything that answers those messages is a file server,
and any file server can be attached anywhere in any process's namespace. A
kernel device is a file server built into the kernel; `ramfs`, `exportfs`, and
the window system are file servers that are ordinary programs. The protocol
is described in `intro(5)`.

**In h9**

The same. The kernel inside h9 is drawterm's, and its devices are compiled
in: the console, environment, processes, pipes, the network, the host file
system, and a few of h9's own (chapter 7). User-level file servers such as
`ramfs`, `srvfs`, `exportfs`, `factotum`, and `plumber` run as guest
processes, post themselves in the machine's `/srv`, and are mounted with
`mount`, as on 9front (chapter 16).

**Try it**

```text
host$ h9 rc
% cat /dev/sysname; echo
h9
% cat /dev/hostowner; echo
me
% cat /dev/time
 1793983803   1793983803567348707   1793983803567349142            1000000000
% xd /dev/bintime
...
% cat /dev/drivers
#/ root
#c cons
...
```

`/dev/time` is seconds, nanoseconds, clock ticks, and ticks per second, as
text; `/dev/bintime` is the same clock as binary words, for programs.
`/dev/drivers` lists the kernel's devices. 9front's `/dev/user` isn't served
in h9; `$user` and `/dev/hostowner` give the same name.

### 6. Namespaces

This is the most important chapter; everything else in h9 builds on it.

**In Plan 9**

Every process has its own **namespace**: the mapping from names such as
`/bin/ls` to files on file servers. A child inherits its parent's namespace,
shared by default, and a process can make a private copy with `rfork n` (or
an empty one with `rfork N`) and change it without affecting anyone else. No
privileges are needed: rearranging names is an ordinary thing to do, like
changing directory.

Three commands change it:

- `bind new old`, `bind(1)`: make the name `old` refer to the file or
  directory `new`. It's like a symlink, but it lives in the process's
  namespace, not on disk.
- `mount srvfile old [spec]`, also `bind(1)`: attach a 9P server, reached
  through a file descriptor such as a `/srv` entry, at `old`.
- `unmount [new] old`: undo a bind or mount.

Both `bind` and `mount` can make a **union directory** instead of replacing:

| Flag | Meaning |
| --- | --- |
| (none) | Replace: `old` now shows `new` only |
| `-b` | Before: `new` is searched before what was at `old` |
| `-a` | After: `new` is searched after it |
| `-c` | Allow creating files here; with `-a` or `-b`, as `-ac` or `-bc` |

A lookup in a union tries each member in order and takes the first that has
the name, and a listing shows every member's entries (so a name in two
members is listed twice). A new file is created in the first member bound
with `-c`. That's why Plan 9 has no `$PATH` sprawl: `/bin` is a union of
`/$cputype/bin`, the compiled programs, and `/rc/bin`, the scripts, and a
user adds `$home/bin/$cputype` to it with `bind -a` rather than adding a
directory to a search path.

Namespaces are built by scripts. `/lib/namespace` is the standard one that
9front runs for each login, in the syntax of `namespace(6)`, run by
`newns(2)`; `ns(1)` prints the current namespace in the same syntax. The
conventional places are described in `namespace(4)`: `/n` for mounted file
systems, `/mnt` for services such as `/mnt/factotum` and `/mnt/plumb`, and
`/mnt/term` for the files of the terminal you're sitting at when you run
commands on a cpu server.

**In h9**

h9 doesn't run `/lib/namespace`. It builds each machine's starting namespace
itself, from the sandbox policy, and `h9 --print` shows it. Here it is for a
plain `h9 rc` in `~/tour`, line by line:

```text
  bind '#U/Users/me/src/hyper9/.local/9front/root-11952' / ro
  bind '#c' /dev
  bind -b '#y<id>' /dev
  bind -c '#e' /env
  bind '#d' /fd
  bind '#p' /proc
  bind -c '#s' /srv
  bind '#I' /net
  bind -a '#ℏ' /net  # WebSockets, under --net
  bind '/arm64/bin' /bin
  bind -a '/rc/bin' /bin
  bind -a '#H/bin' /bin  # h9's commands
  bind -c '#O' /tmp                                      eph  # /Users/me/src/hyper9/.local/9front/root-11952/tmp
  bind -c '#U/Users/me/tour' /mnt/term/cwd               rw
```

| Line | What it does |
| --- | --- |
| `bind '#U/...' / ro` | The root tree, from the host file system device `#U`, is `/`, read-only. (A 9P root is a `mount` here instead; chapter 16.) |
| `bind -c '#O' /` | A copy-on-write overlay in memory over the root, before every other bind, so writes to `/` succeed and vanish when the machine ends. Not there under `--write=scope` or `--write=none`, or when the root is `--writable`. |
| `bind '#c' /dev` | The kernel's console device: `time`, `sysname`, `random`, `null`, and the rest |
| `bind -b '#y<id>' /dev` | h9's console for this machine, before `#c`, so `/dev/cons`, `/dev/consctl`, and `/dev/stderr` are your terminal |
| `bind -c '#e' /env` | The environment, writable |
| `bind '#d' /fd` | `/fd/0`, `/fd/1`, and so on: this process's open files |
| `bind '#p' /proc` | The machine's processes |
| `bind -c '#s' /srv` | The machine's own service registry |
| `bind '#I' /net` | The network; missing under `--net=disable` |
| `bind -a '#ℏ' /net` | WebSockets, as `/net/ws` (chapter 16); missing under `--net=disable` |
| `bind '/arm64/bin' /bin`, `bind -a '/rc/bin' /bin` | The `/bin` union |
| `bind -a '#H/bin' /bin` | h9's own commands, last in the union, so the root's win; left out under `--no-guest-tools` |
| `bind -c '#O' /tmp` | A private, writable `/tmp` in memory over the tree's empty `/tmp` |
| `bind -c '#U/...' /mnt/term/cwd rw` | Your host directory, read-write; it's also the program's working directory |

Host paths you share with `--readable` and `--writable` appear under
`/mnt/term` at their host path (`/mnt/term/Users/me/notes`), unless they're
inside the root or the cwd (chapter 22). That's the convention drawterm uses
for the terminal's files on a cpu server, and the host is h9's terminal.

You can change the namespace two ways:

- **Inside a session**, with `bind`, `mount`, and `unmount` in rc. The change
  affects that process and the processes it starts afterwards, and ends with
  the machine.
- **At startup**, with `--ns FILE`: h9 replays a namespace file after
  building its own namespace and before looking up the program (chapter 25).

Because `--print`'s namespace section is in namespace-file syntax, you can
save it, edit it, and replay it with `--ns`.

**Try it**

```text
host$ h9 rc
% ns | sed 5q
...
% mkdir /tmp/bin && cp /bin/date /tmp/bin/now
% bind -b /tmp/bin /bin
% now
Thu Nov  6 16:46:18 PST 2026
% @{ rfork n; bind /tmp/bin /bin; ls /bin }
/bin/now
% ls /bin | wc -l
    454
```

The private namespace from `rfork n` replaced `/bin` for the child only; the
shell's `/bin` is still the union with `now` in front. Compare `ns` before
and after a `bind` to see the new line at the end.

### 7. Kernel devices and `#` names

**In Plan 9**

A path that starts with `#` and a letter names a kernel device directly,
whatever the namespace says: `#c` is the console device, `#e` the
environment, `#p` the processes. A namespace is built by binding devices
into place (`bind '#c' /dev`), and `/dev/drivers` lists the devices this
kernel has. `intro(3)` introduces them, and each has its own page in section
3: `cons(3)`, `env(3)`, `proc(3)`, and so on. Quote `#` names in rc, since
`#` starts a comment.

**In h9**

| Name | Device | Bound at | In h9 |
| --- | --- | --- | --- |
| `#/` | root | | The kernel's skeleton of mount points, under the root tree |
| `#c` | cons | `/dev` | drawterm's console device: `time`, `bintime`, `sysname`, `hostowner`, `random`, `null`, `zero`, `pid`, `ppid`, `sysstat`, and more. No `user` file. |
| `#y` | hcons | `/dev`, before `#c` | h9's per-machine console: `cons`, `consctl`, and `stderr`. Each machine gets its own, as `#y<id>`. |
| `#e` | env | `/env` | 9front's environment device, one environment per group. No `#ec` (the config environment). |
| `#d` | dup | `/fd` | Open file descriptors |
| `#p` | proc | `/proc` | The machine's processes only, numbered from 1 within the machine, with 9front's debugging files `mem`, `regs`, `fpregs`, and `text` for acid ([self-host](design/0010-self-host.md)). |
| `#s` | srv | `/srv` | 9front's service registry, one per machine |
| `#\|` | pipe | | Pipes |
| `#I` | ip | `/net` | The network, through the host's own stack: `cs`, `tcp`, `udp`. Masked under `--net=disable`. |
| `#ℏ` | hstream | `/net`, after `#I` | WebSockets, as `/net/ws` (chapter 16), and the connection behind a WebSocket root. Masked under `--net=disable`. |
| `#M` | mnt | | The 9P client behind every `mount` |
| `#U` | fs | `/`, `/mnt/term/...` | The host's file system, through the sandbox's checks. Masked after startup. |
| `#O` | overlay | `/tmp`, ephemeral paths | h9's copy-on-write overlay in memory (chapter 22) |
| `#C` | cmd | | Runs host commands. Only in builds with `-Dhost-cmd`, and masked unless `--host-cmd`. |
| `#H` | htools | `/bin`, after the root's | h9's own commands: small rc scripts built into h9 that wrap its devices, read-only. Masked under `--no-guest-tools`. |
| `#L` | lfd | | Host file descriptors as channels; h9 uses it for unix-socket roots |
| `#a`, `#D` | tls, ssl | | TLS and SSL record layers, for `tlsclient` and friends |
| `#i`, `#m`, `#b` | draw, mouse, kbd | `/dev`, with `--gfx` | The window, its mouse and cursor, and its keyboard (chapter 17). Masked without `--gfx`. |
| `#A` | audio | | Present, but there's no sound to drive |
| `#λ` | linux | A Linux process's `/` | The Linux view: `/9`, `/tmp`, `/mnt/term`, `/dev`, `/proc`, and `/sys`, with the Linux root unioned after them (chapter 20) |
| `#ε` | eventfd | | Linux `eventfd`, `epoll`, and `signalfd` instances |

9front's hardware devices aren't there: no `#S` disks, `#l` Ethernet, `#t`
serial lines, `#v` VGA, or `#P` architecture, and no `#σ` shared-memory
directory or named `#g` segments.

**The device mask.** After building the namespace, h9 tells the kernel that
this machine may no longer attach some devices by name: `#U` and `#C`
always, `#I` and `#ℏ` when the network is off, `#i`, `#m`, and `#b` without
`--gfx`, and `#H` under `--no-guest-tools`. That's the `devmask:` line of
`--print`. Existing binds keep working, so `/mnt/term/cwd` still reaches
your host directory, but a program can't attach `#U` again to reach the rest
of your disk:

```text
% ls '#U/'
ls: #U/: mount/attach disallowed
% ls /mnt/term/cwd
...
```

This is the core of the sandbox (chapter 23): the namespace h9 built is the
whole of the host a program can reach. `--host-fs` leaves `#U` unmasked, and
`--host-cmd` leaves `#C` unmasked.

**Host commands.** *Only in an h9 built with `zig build -Dhost-cmd`; release
builds leave them out while [host-cmd](design/host-cmd.md) rethinks them. In
other builds `#C` and `hcmd` don't exist and `--host-cmd` exits 2.* Under
`--host-cmd`, `hcmd cmd args...` runs `cmd` on the
host, as you, with h9's host environment. Its standard input, output, and
error are the guest's, and `hcmd` exits with its status: empty on success,
the exit code (`3`), `killed`, or `signal: N`. It runs in the host directory
the guest's current directory comes from, so `cd sub; hcmd make` under
`/mnt/term/cwd` runs in `sub` of your host directory; where that isn't a
host directory (`/tmp`, the root, an overlay), it runs in h9's own. `-d dir`
names the host directory, and `-n` gives the command an empty standard
input. An interrupt or a hangup kills the host command.

Host commands die with the machine: when it ends, normally or at a timeout,
any still running are killed, with their process groups, however they were
started.

```text
$ h9 --host-cmd hcmd uname -s
Linux
$ echo hello | h9 --host-cmd --rc 'hcmd tr a-z A-Z'
HELLO
$ h9 hcmd true
hcmd: host commands are off; run h9 with --host-cmd
```

`hcmd` drives `#C` as a program can directly: open `#C/cmd/clone` and read
the connection number `n`, open `#C/cmd/n/wait` (the exit status is kept only
while it's open), write `dir /host/path` and `exec cmd args...` to the clone
file, which is the connection's `ctl`, then use `data` for standard input and
output and `stderr`. `wait` holds one message, `pid 0 0 0 'exit string'`,
with no newline. Writing `kill` to `ctl` stops the command. A process reading
`data` or `stderr` waits on a host pipe, and a note can't interrupt that,
which is why `hcmd` reads them in the background.

### 8. Processes

**In Plan 9**

New processes come from `rfork(2)`, whose flags choose what the child shares
with its parent and what it gets a copy of:

| rc's `rfork` letter | Call flag | Effect |
| --- | --- | --- |
| `n` / `N` | `RFNAMEG` / `RFCNAMEG` | Copy the namespace / start with a clean one |
| `e` / `E` | `RFENVG` / `RFCENVG` | Copy the environment / start with an empty one |
| `f` / `F` | `RFFDG` / `RFCFDG` | Copy the file descriptors / start with none |
| `s` | `RFNOTEG` | Start a new note group |

`fork()` is `rfork(RFFDG|RFREND|RFPROC)`, and threads are processes made with
`RFMEM`, sharing memory. A program is replaced with `exec`, a parent waits
for a child with `wait` (`await` underneath), and a process ends with
`exits(msg)`, a string: empty for success, otherwise the error. The parent
sees `name pid: msg`. Each process has a directory in `/proc`, named by its
pid, with text files describing and controlling it (`proc(3)`).

**In h9**

The same calls, with the same semantics. Underneath, each Plan 9 process is
a host thread running guest code on its own virtual CPU, and h9 serves its
system calls; there's no guest scheduler, so the host OS schedules
processes. Pids are per machine and start at 1 with the program you ran, so
`/proc` shows only the machine's own processes. The machine ends when its
first process exits; any others are sent `hangup`, then stopped. The first
process's exit string becomes h9's exit status (chapter 3).

`/proc/n` has `args`, `ctl`, `fd`, `fpregs`, `mem`, `note`, `noteid`,
`notepg`, `ns`, `ppid`, `regs`, `segment`, `status`, `text`, and `wait`, so
`ps`, `kill`, `slay`, `pstree`, and `acid` work. `ctl` takes `stop`, `start`,
`waitstop`, `startstop`, and `hang` as well as `kill`, and a stopped process
reads `Stopped` in `status`. The CPU times in `status` read 0 for now, and `ns` shows host
paths of bound host trees (a caveat `--print` lists).

Limits: `--pids N` caps how many processes can be alive at once (`rfork`
fails with `no procs` past it), and `--cpus N` caps how many run guest code
at the same moment (chapter 24). On macOS the hypervisor allows 64 vCPUs per
machine. A machine with more than 56 live processes still works: the extra
ones share a pool of 8 vCPUs, which costs a thread handoff on each of their
system calls. You'd notice only with very wide pipelines or `mk` with many
jobs, and only as some slowdown. The emulator has no such limit.

**Try it**

```text
% cat /proc/$pid/status | awk '{print $1, $3}'
rc Await
% sleep 10 & echo $apid
3
% wait $apid; echo waited
waited
% @{ rfork e; x=inner; echo $x }; echo x is $#x
inner
x is 0
% cat /no/such/file; echo $status
cat: can't open /no/such/file: file does not exist: '/no/such/file'
cat 5: can't open /no/such/file: file does not exist: '/no/such/file'
% ps
me              1    0:00   0:00      256K Await    rc
me              6    0:00   0:00       64K Pread    ps
```

`$apid` is the pid of the last background command, and `$status` the exit
string of the last command. `rfork e` gave the child its own environment, so
its `x` didn't leak out.

### 9. Notes: Plan 9's signals

**In Plan 9**

A **note** is a string posted to a process: `interrupt` when you press the
interrupt key, `hangup` when the terminal goes away, `alarm`, `kill`, and
`sys: ...` for traps the kernel raises, such as `sys: write on closed pipe`
or `sys: trap: fault read addr=0x0`. A program installs a handler with
`notify(2)` and finishes with `noted(NCONT)` or `noted(NDFLT)`; without a
handler, the note kills the process and becomes its exit string.

Processes belong to a **note group**, usually a shell and its foreground
job. Writing to `/proc/n/note` posts to one process, and `/proc/n/notepg` to
its whole group. `rfork s` starts a new group. `kill(1)` and `slay(1)` don't
kill anything themselves: they print rc commands that write `kill` to the
right `note` files, which you pipe to rc. Writing `kill` to `/proc/n/ctl`
kills a process whatever its handlers do. In rc, a function named after a
note (`fn sigint`, `fn sighup`) is its handler.

**In h9**

Notes are delivered as on 9front, with a saved register state for the
handler, and blocking calls are interrupted by them. h9 maps host events to
notes:

| Host event | Note |
| --- | --- |
| Ctrl-C at the terminal | `interrupt` to the foreground note group; rc abandons the command and prompts again |
| A second Ctrl-C within a second | The machine is stopped |
| SIGTERM, or closing the terminal (SIGHUP); on Windows, closing the console, logoff, or shutdown | `hangup` to every process, then the machine is stopped 2 s later if it hasn't exited |
| `--timeout` reached | `hangup` to every process, then the machine is stopped 2 s later, and h9 prints `h9: PROG: h9: timeout` and exits 124 |
| Ctrl-Break on Windows | `interrupt` |

If the first process dies of one of these notes, h9 exits as a shell would
for the matching signal: 130 for `interrupt`, 129 for `hangup`. A stopped
machine exits 130 after a second Ctrl-C, 129 after SIGHUP, and 143 after
SIGTERM (chapter 21 lists every exit code).

When a program has put the console in raw mode (chapter 13), Ctrl-C isn't
an interrupt: it reaches the program as a key, as Del does on 9front.

**Try it**

```text
% fn sigint { echo caught }
% sleep 100
^Ccaught
% fn sigint
% sleep 1000 &
% echo kill > /proc/$apid/ctl
% fn sighup { echo hung up }; echo hangup > /proc/$pid/note
hung up
% { rfork s; sleep 1; echo survived } & echo hangup > /proc/$pid/notepg
```

`fn sigint` with no body removes the handler. In the last line the block in
braces made its own note group, so the hangup posted to the shell's group
didn't reach it.

### 10. The rc shell

rc is Plan 9's shell. It's smaller and more regular than sh, and a few of its
rules trip up bash and zsh users. `rc(1)` is the reference, and Tom Duff's
paper "Rc — The Plan 9 Shell" the tutorial; Appendix B has a side-by-side
table.

**Quoting.** There's one kind of quote, the single quote, and nothing is
expanded inside it. To put a `'` in a quoted word, double it:

```text
% echo 'it''s $home'
it's $home
```

There are no double quotes, and none are needed: a variable's value is never
split again or globbed after substitution.

**Variables are lists.**

```text
% path=(. /bin)
% files=(a.c b.c 'with space.c')
% echo $#files                 # how many
3
% echo $files(3)               # one element, counting from 1
with space.c
% echo $"files                 # joined into one word with spaces
a.c b.c with space.c
% x=()                         # empty list; $#x is 0
```

**Concatenation** uses `^`: `$name^.c`. rc inserts a "free caret" between a
variable and the text next to it, so `$name.c` works too, and two lists of the
same length concatenate pairwise: `(a b)^(1 2)` is `a1 b2`.

**Status and conditions.** `$status` is a string, the exit string of the last
command, and a command is true if its status is empty. Control flow:

```rc
if(test -f mkfile) mk
if not echo no mkfile

if(~ $1 *.c) echo C source      # ~ is pattern matching; true if any pattern matches

switch($1){
case *.c
	echo C
case *.h
	echo header
case *
	echo other
}

for(f in *.c) echo $f
while(! test -e done) sleep 1
! grep -s TODO main.c && echo clean
```

**Substitution and redirection.**

| rc | Meaning |
| --- | --- |
| `` `{date} `` | Command substitution, split on spaces, tabs, and newlines |
| `<{cmd}` | `cmd`'s output as a file name (`/fd/N`), for programs that want a file |
| `>[2] file` | Redirect fd 2 |
| `>[2=1]` | Make fd 2 a copy of fd 1 |
| `>> file` | Append |
| `<<EOF` ... `EOF` | Here document (with `$` substitution unless the marker is quoted) |
| `<>[3] file` | Open fd 3 for reading and writing |

**Functions.** `fn name { body }` defines one; `$*` holds its arguments,
`$1`, `$2` the first ones, `$0` the function's name, and `shift` drops the
first. Functions are exported through `/env` like variables, so child shells
have them.

**What's missing compared to POSIX sh.** No `$(( ))` arithmetic (use
`hoc`, `awk`, or `seq`), no `[[ ]]` (use `test` and `~`), no `export` (every
variable is exported), no `local` (use `@{ }` or `rfork e`), no `set -e`
(test `$status`, or use `||`), no `trap` (use `fn sigint` and friends), no
job control beyond `&`, `wait`, and `$apid`, and no history or line editing.

**In h9**

- `h9 --rc 'cmd' a b c` runs `rc -c 'cmd'` with `$*` set to `a b c`.
- Host quoting and rc quoting nest. The host shell sees the outer single
  quotes; rc sees what's inside them. To give rc a quoted word inside a
  host single-quoted string, end the host quote, add an escaped quote, and
  reopen it, or put the command in a file:

  ```sh
  host$ h9 --rc 'echo '\''it'\'''\''s'\'''     # rc sees: echo 'it''s'
  it's
  host$ h9 --rc "echo 'it''s'"                    # or use host double quotes
  it's
  ```

  With host double quotes, remember the host shell expands `$` inside them;
  write `\$` for rc's variables.
- rc scripts in the machine run directly through `#!/bin/rc`, including
  ones in your host cwd by their guest path or through `$path`'s `.`, as in
  the tour. A host path such as `./script` doesn't work yet (chapter 3).

### 11. The environment

**In Plan 9**

Environment variables are files in `/env`, served by the kernel's `#e`
device, one environment per environment group. Reading `/env/x` is getenv;
writing it is putenv. rc stores a list with its elements separated by NUL
bytes, and functions as `fn#name`. A child shares its parent's environment
unless it's made with `rfork e` (a copy) or `rfork E` (an empty one), so a
shell's changes are seen by the programs it starts, and a subshell's changes
stay private only if it copies.

Conventional variables:

| Variable | Meaning |
| --- | --- |
| `user` | Your user name |
| `home` | Your home directory, `/usr/$user` |
| `cputype` | The architecture programs run on: `arm64`, `amd64`, `386` |
| `objtype` | The architecture the compilers build for, usually `$cputype` |
| `sysname` | The machine's name |
| `service` | `terminal` or `cpu`, as the machine was started |
| `path` | rc's search path |
| `prompt` | rc's prompt, a list of two strings (`('% ' '	')`) |
| `timezone` | The time zone, for `date` and `ls -l` |

**In h9**

h9 never imports the host's environment: your `HOME`, `PATH`, tokens, and
other secrets stay out of the guest (`env.scrub` in the sandbox's terms), and
their Plan 9 meanings differ anyway. Each machine starts with:

| Variable | Value |
| --- | --- |
| `user` | Your host user name |
| `home` | `/usr/$user`, which usually doesn't exist in the root tree (Appendix C) |
| `cputype`, `objtype` | The machine's architecture: `arm64` on Apple Silicon |
| `sysname` | `h9` |
| `service` | `terminal` |
| `path` | `(. /bin)` |
| `timezone` | Copied from the root tree's `/adm/timezone/local`, when it has one |
| `NPROC` | The vCPUs the machine can run at once: `--cpus`, else the host's CPU count. `mk` runs this many jobs. |

plus whatever you pass with `--env name=value`, which can repeat and
overrides the defaults. A value is passed as one word; it isn't split into a
list. Pass host values deliberately, letting the host shell expand them:

```sh
host$ h9 --env home=/mnt/term/cwd rc
host$ h9 --env "GITHUB_TOKEN=$GITHUB_TOKEN" ./client
host$ h9 --env "timezone=$(cat ~/.plan9-tz)" date
```

**Try it**

```text
host$ h9 --env greeting=hello rc
% ls /env
/env/cputype
/env/greeting
/env/home
...
% cat /env/path | xd -c
0000000   . 00  /  b  i  n 00
0000007
% @{ rfork e; greeting=bye; echo $greeting }; echo $greeting
bye
hello
% @{ greeting=bye }; echo $greeting
bye
```

The last line shows sharing: without `rfork e`, the child's assignment
changed the parent's `/env/greeting`.

### 12. Users, ownership, and permissions

**In Plan 9**

There's no root user and no uid 0. The **hostowner** owns the machine's
kernel and devices, which gives far fewer powers than root does. Files have
an owner, a group, and permissions for user, group, and other, as on Unix, but
there's no setuid, and users and groups are *names* that each file server
defines for itself. Proving who you are to a file server is the job of
`factotum`, an agent that holds your keys and runs the authentication
protocols, with `secstore` keeping them encrypted.

**In h9**

- The hostowner and `$user` are your host user name.
- The host's file system is served by drawterm's devfs, which shows each
  host file's owner and group as names, so `ls -l` in `/mnt/term/cwd` shows
  your files as yours. The root tree's files show whoever owns them on the
  host, usually you.
- The host's own permission checks still apply underneath: h9 runs as you,
  so it can't read anything you can't.
- `factotum` runs (`auth/factotum -n` starts it without secstore) and serves
  `/mnt/factotum`, and `mount` works without authentication against servers
  that don't ask for it. A 9P root that wants authentication isn't supported
  yet (*Not yet available ([root-auth](design/root-auth.md))*).

"Permission denied" in h9 can mean three things:

| Cause | Typical message | How to tell |
| --- | --- | --- |
| A read-only bind: the root under `--write=scope`, a `--readable` path, the cwd under `--profile=tight` | `mounted directory forbids creation` for a new file, `permission denied` for an existing one | `--print` shows `ro` on that bind |
| The sandbox's access rules: a path read-only by policy, a rename that would move a protected path | `permission denied` | `--print`'s `access:` section; `--trace` shows the failing call |
| The host's own permissions | `permission denied` | The same operation fails outside h9 |

A path hidden by `--read-deny`, or outside every bound tree, isn't denied: it
doesn't exist (`file does not exist`). Chapters 28 and 29 have more on
telling these apart.

### 13. The console and the terminal

**In Plan 9**

`/dev/cons` is the console, and it's line-oriented: a program reads whole
lines and writes plain text. Programs don't send terminal escape codes, and
there's no termcap, curses, or terminal size. Writing `rawon` to
`/dev/consctl` turns off line editing and echo, so a program reads each key
as it's typed, until it writes `rawoff` or closes `consctl`. The interrupt
key is Del. Line editing, scrollback, and cut and paste belong to the window
system, rio, not to the program or the shell.

**In h9**

- `/dev/cons` is your host terminal, or whatever h9's standard input and
  output are: a pipe or a file works too. A read returns after one host read,
  so a typed line arrives when you press Enter.
- Line editing is your host terminal's cooked mode: Backspace and Ctrl-U
  work, Ctrl-D is end of file, and there's no history.
- Writing `rawon` to `/dev/consctl` puts the host terminal in raw mode, until
  `rawoff`, the last close of `consctl`, or the end of the run (or a crash).
  In raw mode Ctrl-C reaches the program as a key, as Del does on 9front.
- Writing `echooff` to `/dev/consctl` (an h9 addition) turns the host
  terminal's echo off and keeps its line editing, for password prompts,
  until `echoon`, the last close of `consctl`, or the end of the run. A Linux
  program's `tcsetattr` sets both: `ICANON` off is raw mode, and `ECHO` off is
  `echooff`, so `stty -echo` and `read -s` work as on Linux.
- Standard error is separate. On 9front, fd 2 is the console like fd 1; in
  h9 it's `/dev/stderr`, which goes to the host's standard error, so `h9 prog
  2>err.log` works as you'd expect.
- On Windows, line endings typed at the console arrive as `\n`.

Because h9 is an ordinary host program, it fits in host pipelines:

```sh
host$ cat words.txt | h9 wc -l
host$ h9 ls /bin | sort | head
host$ h9 --rc 'grep -n TODO *.c' > todo.txt
```

### 14. Text tools and the 9front userland

9front's tools look like the Unix ones and mostly do the same jobs, but
they're older, smaller, and more consistent. The differences that catch people:

- **Fewer flags.** `ls` has no colours, no columns (`lc` lists in columns)
  and no `-h`; `ls -l` shows sizes in bytes. `du -a` walks a tree, since
  there's no `find` (`walk` lists names too). `tail +3` and `tail -3` work,
  `tail -n 3` doesn't. `date` takes no format string. `seq` exists; `tr` has
  no character classes.
- **One regular expression syntax**, described in `regexp(6)`, used by
  `grep`, `sed`, `awk`, `sam`, and the C library. It's what GNU calls
  extended: `+`, `?`, `|`, and `()` work unescaped, and there are no
  backreferences or `\d`, `\w`, or `{n,m}`. `grep -s` is silent, for tests,
  and `grep -n` numbers lines.
- **Structural regular expressions.** `sam`, Plan 9's editor, describes
  edits as nested `x/regexp/ command` loops that work on any text structure,
  not just lines. `ssam` runs a sam script over standard input like `sed`;
  `sam -d` is sam without graphics, for editing a file at a prompt.

  ```sh
  host$ h9 --rc 'echo foo bar foo | ssam ''x/foo/ c/baz/'''
  baz bar baz
  ```

- **No pager or full-screen programs.** There's no `less` or `vi`. `p` pages
  a screenful at a time (Enter for more, `q` to quit); `ed` and `sam -d` edit
  files. (9front's `vi` is a MIPS emulator, not an editor.)

**Reading manual pages.** The root tree has 9front's manual in `/sys/man`:

```sh
host$ h9 man rc                # by name
host$ h9 man 1 bind            # bind(1), not bind(2)
host$ h9 lookman namespace     # search the index for a word
host$ h9 sig open              # a C function's prototype
```

The papers in `/sys/doc` aren't in h9's root tree; Appendix D has links.
Appendix B has a Unix to 9front command table.

### 15. Networking

**In Plan 9**

The network is a file tree, usually at `/net`. Each protocol is a directory
(`/net/tcp`, `/net/udp`); opening its `clone` file reserves a new
connection, numbered `n`, and returns its `ctl` file, whose first read gives
`n`. Writing `connect 10.0.0.1!80` to `ctl` dials; then `/net/tcp/n/data`
is the byte stream, and `status`, `local`, and `remote` describe it. Servers
write `announce *!8080` and open `listen` to wait for calls.

Addresses are **dial strings**, `network!host!service`, such as
`tcp!9front.org!443` or `net!example.com!http`, where `net` means any
network. The **connection server**, `/net/cs`, turns a dial string into the
`clone` file and address to use, looking names up in `ndb(6)` and DNS. The C
library's `dial(2)` and `announce` do all of this for programs. Commands:
`hget` fetches URLs (it's a script over the `webfs` file server),
`aux/listen1` runs a command for each incoming call, `ssh` and `rcpu`
connect to other machines, and `9fs` mounts remote file servers.

**In h9**

- `#I` is drawterm's network device, which uses the host's network stack:
  connections come from your host's addresses, through its routing, VPN, and
  firewall. It has `tcp`, `udp`, and `cs` only; there's no `/net/ipifc`,
  `/net/ether`, or `/net/dns`, and nothing to configure.
- `/net/cs` is built into the device and resolves names with the host's
  resolver, so there's no `ndb/cs` or `ndb/dns` to start. `ndb/csquery`
  works against it.
- The `--net` flag decides what's allowed:

  | Mode | Clients (`connect`) | Servers (`announce`) |
  | --- | --- | --- |
  | `outbound` (the default) | Allowed, except to link-local addresses (169.254.0.0/16, fe80::/10) | Refused, "permission denied" |
  | `enable` | Allowed, except link-local | Allowed |
  | `disable` (`--profile=tight`'s default) | `#I` is masked and `/net` is empty | — |

- `--net-allow PATTERN` (repeatable) turns the network into an allowlist:
  every connect must match a pattern, and `cs` resolves only names a pattern
  covers. A pattern is `proto!host!port`: `tcp`, `udp`, or `net` or `*` for
  both; an address, a CIDR range, a host name, `*.example.com` (one or more
  labels in front), or `*`; and a port, a range `8000-8999`, or `*`. With any
  pattern, link-local addresses are reachable only if a pattern names them.
  A connect to an address that a name resolved to is allowed if the name's
  pattern allows it, so connect by name, through `cs`, rather than by
  address.

  ```sh
  host$ h9 --net-allow 'tcp!*.github.com!443' --net-allow 'udp!10.0.0.53!53' ./client
  host$ h9 --net-allow 'tcp!10.0.0.0/8!564' --rc 'srv tcp!fileserver!564 fs && mount /srv/fs /tmp/fs'
  ```

  `--net-allow` with `--net=disable`, or a malformed pattern, is a usage
  error (exit 2).
- Servers in the guest listen on the host's ports, reachable by anything
  that can reach your host. `--print` lists that as a caveat under
  `--net=enable`.

**Try it**

Dialing by hand, with a host listener (`nc -l 8000` in another host
terminal) to talk to:

```text
host$ h9 rc
% <>[3] /net/tcp/clone {
	n=`{read <[0=3]}
	echo 'connect 127.0.0.1!8000' >[1=3]
	echo hello from plan 9 > /net/tcp/$n/data
}
% ndb/csquery /net/cs tcp!localhost!http
/net/tcp/clone 127.0.0.1!80
```

Fetching a page with `hget` needs `webfs` running, mounted at `/mnt/web`.
The root tree's `/mnt` has no `web` directory, so make one in `/tmp` and
union it in first:

```text
% mkdir -p /tmp/m/web && bind -a /tmp/m /mnt
% webfs
% hget http://example.com/ | sed 3q
```

A server, which needs `--net=enable`:

```sh
host$ h9 --net=enable aux/listen1 -t 'tcp!*!8080' /bin/cat
```

### 16. File servers, `/srv`, and 9P mounts

**In Plan 9**

A user-level file server is a program that answers 9P on a file descriptor.
To share itself it **posts** that descriptor in `/srv` (`srv(3)`): writing a
file descriptor's number to a new file in `/srv` makes the file a handle on
the open channel, and anyone who opens it gets the same channel. `mount
/srv/name /n/name` then attaches it. That's how every service is built:

- `ramfs -S name` serves an in-memory tree and posts it as `/srv/name`.
- `srvfs name dir` re-exports a directory of your namespace as `/srv/name`.
- `exportfs` serves a namespace over a connection, for `cpu` and `import`.
- `srv tcp!host!564 name` dials a remote 9P server and posts the connection;
  `9fs host` does that and mounts it on `/n/host`.
- `u9fs` serves Unix file systems to Plan 9.

Writing your own with `lib9p` (`9p(2)`) is how you build services and
devices in Plan 9.

**In h9**

- `/srv` is the machine's own registry (9front's `#s`), so file servers post
  themselves and other processes mount them as on 9front. `ramfs`, `srvfs`,
  `exportfs`, `factotum`, and `plumber` run. Machines can't see each other's
  `/srv`, and everything posted is closed when the machine ends.
- `mount` works with or without authentication through `fauth`, for any
  server the guest has a descriptor for: a `/srv` entry, a pipe, or a
  network connection the network policy allowed.
- 9front fills `/n` and `/mnt` with directories on demand (`mntgen`); h9
  doesn't, so make the mount point first: `mkdir /n/x` works in the root's
  overlay, or make one in `/tmp` and union it onto `/mnt` with `bind -a` as
  in chapter 15.
- **9P roots.** `--root` can be a 9P server instead of a directory: a dial
  string `tcp!host!port` (`tcp!host` means port 564), `unix!/path`, or the
  path of a unix socket. h9 connects before the program runs, posts the
  connection as `/srv/root`, mounts it at `/`, and binds everything else over
  it as usual. `--root-spec NAME` sets the attach name and `--root-user NAME`
  the user name sent to the server (your user by default). The server must
  not ask for authentication: `u9fs -a none`, or `exportfs` behind
  `aux/listen1 -t`, such as another h9 serving its tree. By default writes
  stay in the root's overlay and never reach the server; under
  `--write=scope` they go to the server, which decides what's writable.
  `--write=none` with a 9P root is a usage error. A refused connection or attach is exit 125. The connection
  is plain, unencrypted 9P, so keep a TCP root on a trusted network. Unix
  socket roots need a macOS or Linux host.
- **9P over WebSocket** ([websocket-9p](design/0021-websocket-9p.md)).
  `--root ws://host/path` or `wss://host/path` uses a 9P server behind a
  WebSocket as the root. h9 makes the connection on the host, offering the
  `9p` subprotocol, and mounts it like any 9P root. `--root-header 'Name:
  value'` adds a handshake header, and `--root-header @FILE` reads them from
  a file, so a token stays out of `ps`. `wss` trusts the host's CA bundle,
  or a PEM file given with `--root-ca FILE`. `HTTPS_PROXY`, `HTTP_PROXY`, and
  `NO_PROXY` are honored. A namespace file can mount a URL too: `mount -c
  wss://fs.example/9p /n`. On the command line the scheme can be left off
  ([schemeless-roots](design/0076-schemeless-roots.md)): a `--root` or
  `$H9ROOT` that isn't an existing path and looks like
  `host[:port][/path]`, with a dotted host, a bracketed address, a port, or
  `localhost`, is read as `wss://` plus the value, or `ws://` for
  `localhost`, `127.x.x.x`, and `[::1]`. `--root fs.example.com/9p` is
  `wss://fs.example.com/9p`, and `--root fs.example.com` is
  `wss://fs.example.com/`. An existing path always wins, and `--print`
  shows the URL h9 chose.
- **WebSockets in the guest.** `/net/ws` is laid out like `/net/tcp` and
  follows `--net` and `--net-allow` as a TCP dial to the URL's host and port
  would. A conversation's `data` file carries binary messages as a byte
  stream, and its `text` file text messages, one per read and write.
  `wsmount [-h 'Name: value'] url mountpoint` dials a 9P server and mounts
  it. Guest connections don't use the host's proxies.
- **Serving the machine** ([serve](design/0035-serve.md)). `--serve ADDR`
  makes h9 a 9P server while the program runs: `unix!/path`,
  `tcp!host!port`, or `ws://host:port/path`, repeatable. Each connection
  gets its own `exportfs` of the machine's namespace as the plan built it,
  so a client sees what the guest sees, under the same rules, but not binds
  the program makes later, and not `/net` unless `--serve-net` is given.
  `--serve-root PATH` exports a subtree instead of `/`, and `--write=none`
  makes the export read-only (`exportfs -R`). With no program, h9 only
  serves, until Ctrl-C, SIGTERM, a hangup, or `--timeout`, and then exits
  0. Port 0 picks a free port, and h9 prints it (`serve:
  tcp!127.0.0.1!53122`) before the program starts; the program finds every
  bound address in `$serve`. A unix socket is created mode 0600 next to a
  `PATH.lock` file, a stale socket from a run that crashed is replaced, and
  both are removed at exit. A WebSocket listener accepts a request without
  an `Origin` header, or with one listed by `--serve-origin`, and with
  `--serve-token @FILE` it also needs the token, as `Authorization: Bearer
  TOKEN` or `?token=TOKEN` (a browser can only use the query). Unix and TCP
  listeners don't authenticate, so every client acts as your user: keep TCP
  on loopback or a trusted network. A machine serves up to 32 connections,
  each with up to 8 exportfs processes; serving's processes count against
  `--pids` separately from the program's. Every listener also speaks
  9P2000.L ([dotl](design/0022-dotl.md)), so Linux mounts it: `mount -t 9p
  -o trans=unix,version=9p2000.L /path/h9.sock /mnt`. A .L client sees
  regular files and directories only, with every file owned by your host
  uid. Renames work only within a directory, and symlinks, device nodes,
  and hard links can't be made. Byte-range locks are advisory, shared by
  the machine's connections.
- **9P2000.L servers** ([dotl](design/0022-dotl.md)). `dotlfs addr
  mountpoint [spec]` dials a server that speaks 9P2000.L, such as diod or
  ZeroFS, and mounts it. It also mounts a plain 9P2000 server, so it can be
  used without knowing which one is at the address. The dial goes through
  `/net`, under `--net` and `--net-allow`. The server's symlinks are
  followed, but none can leave the mount: an absolute target starts at the
  mount's root, and `..` stops there. Dangling links aren't listed, and
  devices and FIFOs can't be opened. A .L server knows users by number, so
  the guest's user goes out as your host uid, and any other number shows as
  itself, such as `1000`. Running as root sends 65534 (nobody), never 0.
  `--user-map FILE` gives a file in `/etc/passwd` format to map names to
  numbers both ways, and it's the only way to send 0. `/net/dotl/N/status`
  says which dialect the server chose. A 9P root's address can be a .L
  server too: `--root tcp!host!port` works with either. A file read from
  start to end is read a whole `msize` (up to 1 MiB) at a time, not
  devmnt's 32 KiB, and any write drops what was read ahead.
- **Reconnecting to ZeroFS** ([dotl](design/0022-dotl.md)). With a server
  that speaks ZeroFS's 9P2000.L.Z, a TCP mount or root survives the
  connection dropping: h9 dials again for up to 120 seconds, a second apart,
  reopens every open file without truncating it, and resends each request
  that wasn't answered, which the server applies once. Meanwhile the guest
  sees slow replies, not errors. .L.Z's compound requests also save round
  trips: a walk brings the file's attributes, so a stat after it is free,
  opening a file to read brings up to its first megabyte, and a directory
  listing comes with every entry's attributes. `dotlfs host1,host2
  mountpoint` gives addresses to try in turn, as for an HA server, and a
  server that answers that it's no longer the leader is dialed again the
  same way. `dotlfs -L` asks for plain .L. `/net/dotl/N/status` shows
  `9P2000.L.Z reconnects N` once a reconnect has happened. A unix socket
  root reconnects too, but a WebSocket root doesn't yet.
- Not yet available: roots that need authentication
  ([root-auth](design/root-auth.md)); serving a machine's namespace to the
  host or the network as a 9P server from h9 itself, rather than with
  `exportfs` inside the guest as below ([serve](design/0035-serve.md)).
- 9front disk images as roots were proposed and declined
  ([image-roots](design/0014-image-roots.md)), since host directories, 9P
  servers, and overlays have covered every root so far. To run from an
  image, boot it in a VM and serve its file system over 9P, or copy its files
  out, as `zig build mkroot` does.

**Try it**

Scratch space in memory:

```sh
host$ h9 --rc 'ramfs -S tmp && mkdir /tmp/n && mount -c /srv/tmp /tmp/n && touch /tmp/n/a && ls /tmp/n'
/tmp/n/a
```

A named pipe, from `srv(3)`'s example:

```sh
host$ h9 --rc 'echo hello | { echo 0 >/srv/namedpipe }; cat /srv/namedpipe'
hello
```

One h9 serving its namespace, read-only, and another mounting it:

```sh
host$ h9 --write=none --serve 'tcp!127.0.0.1!5640' &
host$ h9 --root 'tcp!127.0.0.1!5640' --rc 'mount /srv/root /mnt/temp && ls /mnt/temp/mnt/term/cwd'
```

The guest can do the same itself with `aux/listen1` under `--net=enable`,
since exportfs is in the root tree:

```sh
host$ h9 --net=enable aux/listen1 -t 'tcp!127.0.0.1!5640' /bin/exportfs -R -r / &
host$ h9 --root 'tcp!127.0.0.1!5640' ls /
```

A root over a WebSocket, with the relay from h9's tests in front of the
server above, and a guest mount over one:

```sh
host$ zig build wsrelay -- 8080 5640 &
host$ h9 --root ws://localhost:8080/9p ls /
host$ h9 --rc 'mkdir /tmp/fs && wsmount ws://localhost:8080/9p /tmp/fs && ls /tmp/fs'
```

Sharing the host's network with a machine that has none, such as one in a
browser tab. One h9 serves its `/net`, and the other mounts it before its
own `/net/ws`, so `dial(2)` and `/net/tcp` go through the host, under the
serving machine's `--net` and `--net-allow`. Here the second machine may
only reach the listener, and still fetches from the host's port 8000:

```sh
host$ h9 --serve ws://127.0.0.1:5640/ --serve-root /net --serve-net &
host$ h9 --net-allow 'tcp!127.0.0.1!5640' --rc 'wsmount -b ws://127.0.0.1:5640/ /net && cat /net/tcp/clone'
```

In the browser demo, add `--serve-origin` with the page's origin (and a
`--serve-token` beyond loopback), then type the same `wsmount -b` line.
Linux programs use the mount too, since their sockets open `/net`
through the namespace: from busybox, `/9/bin/wsmount -b
ws://127.0.0.1:5640/ /net` and then `wget` fetches through the host. Each
connection carries about 7 sockets waiting at once, since each holds one
of the server's 8 exportfs processes; mount `/net` over more connections
for more. A UDP socket on a mounted `/net` has one peer: `recvfrom`
reports it, so an unconnected server can't tell its clients apart.

Mounting a remote 9P server the network policy allows:

```sh
host$ h9 --rc 'srv tcp!fs.example.com!564 fs && mkdir /tmp/fs && mount /srv/fs /tmp/fs && ls /tmp/fs'
```

### 17. Graphics: rio, acme, and the plumber

**In Plan 9**

Graphics are files too: `/dev/draw` for drawing, `/dev/mouse`, `/dev/kbd`,
and `/dev/cursor` for input, and `/dev/snarf` for the clipboard. rio, the
window system, is a file server that gives each window its own `/dev/cons`,
`/dev/mouse`, and `/dev/draw`, so programs inside a window don't know they're
in one. Text is edited with three mouse buttons: button 1 selects, button 2
runs commands (cut, paste, snarf) and button 3 opens or plumbs; chords such
as 1-2 cut and 1-3 paste. acme is a programmer's environment built on that
idea, where any text is a command. The **plumber** routes messages between
programs, such as opening a file name you clicked in the right editor.

**In h9**

`--gfx` gives the machine one host window, drawn by drawterm's own window
code: Cocoa on macOS, Win32 on Windows, and X11 on Linux. Its namespace gets
`#i`, `#m`, and `#b` on `/dev`, so `/dev/draw`, `/dev/mouse`, `/dev/cursor`, and
`/dev/kbd` are the window's, and `/dev/snarf` is the host clipboard. Run rio
in it and the window is a 9front screen. The window opens when a program
first uses the screen, not before. Closing it posts `hangup` to the machine,
as closing the terminal does.

The console stays on the host terminal: `/dev/cons` is still the terminal you
ran h9 from, so messages and anything rio's own console prints appear there.
rio writes `rawon` to the console, so the terminal stays in raw mode until
the run ends.

- `--gfx=noclip` keeps `/dev/snarf` inside the h9 process, shared by the
  guest's programs only, so the guest can't read what you last copied on the
  host or put text on the clipboard.
- `--gfx-scale N` is drawterm's `-x`, on macOS only: 1 (the default) draws in
  points, 0 in the display's backing pixels, and N in backing pixels divided
  by N.
- Only one machine in an h9 process has a window. Without `--gfx`, `#i`, `#m`,
  and `#b` are masked, so a guest can't open one.
- Linux builds have no window code unless built with `-Dgfx=x11`; `h9
  --version` says which (`gfx:`), and `h9 --check` says whether `$DISPLAY`
  opens. Without it, or without a display, `--gfx` exits 125.
- rio needs `/mnt/temp` in the root tree; `zig build mkroot` makes it, and
  adds it to a tree it built before.
- `--print` shows a `gfx:` line, and lists the clipboard and the guest's
  freedom to draw anything in its window (including what looks like a host
  dialog) as caveats.

**In a browser.** On the browser host, a page's `<canvas>` is the window
([browser-gfx](design/0120-browser-gfx.md)). `h9-web.js`'s
`createMachine({ gfx: { canvas } })` moves the canvas into the machine's
Worker, and rio and acme draw on it. The demo page's **rio** button runs
`rio -i 'window acme'` that way.

- Click the canvas to type to it. Keys reach the guest only while the canvas
  has focus, and keys the browser keeps for itself, such as Ctrl-W and
  Ctrl-T, never reach it. Leaving the canvas releases every key still held.
- With a one-button mouse or a trackpad, Alt (Option) and click is button 2,
  and Cmd and click on macOS, or Ctrl and click elsewhere, is button 3. The
  wheel is buttons 4 and 5, as rio and acme expect.
- `/dev/snarf` is a buffer in the machine, not the page's clipboard. Ctrl-V
  (Cmd-V) in the canvas puts the clipboard's text in it, and then rio's or
  acme's own paste (button 2's menu, or a 1-3 chord) pastes it. A snarf in
  the guest copies to the page's clipboard; if the browser refuses, the
  machine fires a `snarf` event with the text, so the page can offer its own
  copy button. So the guest reads the clipboard only when you paste.
  `clipboard: "private"` keeps the buffer to the guest, as `--gfx=noclip`
  does.
- `scale` is `--gfx-scale`: 0 (the default) draws in device pixels, so text
  is small on a high-DPI display, 1 in CSS pixels, and N in device pixels
  divided by N. The screen follows the canvas's size.
- A page can't move the pointer, so rio's and acme's warps don't happen.
- `machine.hangup()` posts `hangup`, as closing a native window does.
- The root archive holds rio, acme, `window`, and the `vga` font they open
  by default; other fonts need a fuller root. `h9-node` has no canvas, so
  `--gfx` there exits 125 as a build without graphics does.

The plumber starts and serves `/mnt/plumb`, and `sam -d` and `ed` edit text
without graphics.

**Try it**

```
host$ h9 --gfx rio
host$ h9 --gfx rio -i 'window acme'
host$ h9 --gfx=noclip rio
```

In rio, hold button 3 on the grey background and choose New, then sweep out
a window with button 3; it runs rc. Type `echo hi > /dev/snarf` in it, then
paste in a host program.

### 18. Building software inside h9

**In Plan 9**

Each architecture has its own compiler, assembler, and linker, named by a
letter: `7c`, `7a`, and `7l` for arm64, `6c`, `6a`, and `6l` for amd64, `8c`,
`8a`, and `8l` for 386. Object files are named by the same letter (`ls.7`),
and `$objtype` picks the target. `pcc` is a cc-like driver for ANSI and POSIX
code (APE). Programs are built with `mk`, Plan 9's make, from a `mkfile`
that includes shared rules from `/sys/src/cmd/mkone` and friends. Sources
live in `/sys/src`, and `mk install` copies results into `/$objtype/bin`.

**In h9**

The compilers, linkers, and `mk` run, and rebuild 9front's userland from
`/sys/src` byte for byte; that's how `zig build mkroot -- --arch` adds `/386` and
`/amd64`. `acid` debugs a live process ([self-host](design/0010-self-host.md)).

- You need `/sys/src` in the root tree for the headers and libraries to
  rebuild 9front itself: build the tree with `zig build mkroot -- --src`.
  For your own programs, `/$objtype/lib` and `/sys/include`, which every
  tree has, are enough.
- The root is a copy-on-write overlay by default, so `mk install` works and
  the installed files are there for the rest of the run, then gone: try an
  install that way first. To keep it, install with `--writable "$H9ROOT"`.
  On a terminal, h9 tells you when a run's changes to the root were
  discarded: `h9: changes to the root under /arm64, /sys were discarded
  (rerun with --writable "$H9ROOT" to keep them)`.
- `$objtype` is the machine's architecture; set it to cross-compile, as in
  `objtype=386 mk`. The arm64 root has no `/amd64/lib`, so run
  `objtype=amd64 mk libs` in `/sys/src` once, on a writable root, first.
- `mk` runs `$NPROC` jobs at once, the machine's vCPU limit.

**Try it**

A program in your host cwd:

```sh
host$ cat hello.c
#include <u.h>
#include <libc.h>

void
main(void)
{
	print("hello from %s\n", getenv("cputype"));
	exits(nil);
}
host$ h9 --rc '7c hello.c && 7l -o hello hello.7'
host$ h9 ./hello
hello from arm64
```

With a mkfile:

```sh
host$ cat mkfile
</$objtype/mkfile

TARG=hello
OFILES=hello.$O
BIN=/mnt/term/cwd/bin

</sys/src/cmd/mkone
host$ mkdir bin && h9 mk install
host$ ls bin
hello
```

Rebuilding a 9front command from a tree made with `--src`, and installing it
into the root:

```sh
host$ h9 --writable "$H9ROOT" --rc 'cd /sys/src/cmd && mk ls.install'
```

### 19. Go programs

Go has a Plan 9 port, so Go programs built with `GOOS=plan9` run in h9
unchanged.

```sh
host$ GOOS=plan9 GOARCH=amd64 go build -o hello .
host$ h9 ./hello
h9: warning: no usable hypervisor; using the emulator
hello, world
```

- **Architecture.** Go supports `plan9/amd64` and `plan9/386`, but not
  `plan9/arm64`. So on an Apple Silicon Mac a Go program runs on the
  emulator, which needs `h9-emu`; `h9-emu` picks the emulator by itself,
  with the warning above, and `--backend emu` picks it silently. On an
  x86\_64 Linux host, h9 runs it on KVM, or on the native backend when you
  pass `--backend native` (Go's own test suite has been run on the emulator
  only), and on Windows `h9-emu` runs it on the emulator. Compute-heavy Go code runs several times slower
  on the emulator than natively (chapter 27).
- **Or build for Linux.** A `GOOS=linux` binary runs through the Linux
  personality (chapter 20), and Go has `linux/arm64`, so on an Apple Silicon
  Mac `GOOS=linux GOARCH=arm64 go build` gives a program that runs on the
  hypervisor at full speed: `h9 ./hello`. It sees Linux's system calls
  rather than Plan 9's, so it can't use Plan 9 features such as `bind` or
  notes directly, but it still runs in the machine's namespace and sandbox.
- **What works:** goroutines on several processes, timers and `time.Now`,
  files, `os/exec` and `os.Getpid`/`Getppid`, `os.Executable`, `net` and
  `net/http`, `os/signal` (Ctrl-C arrives as `os.Interrupt`), panics from
  faults such as a nil dereference, and `os.Exit(n)`, which becomes h9's exit
  status `n`. `runtime.NumCPU` follows `--cpus`.
- **Memory.** A Go program reserves several hundred MB at start. That's free
  until it's touched, but it counts against `--memory`, whose default is
  1 GB. A program that uses `os/exec` needs `--memory 4G`, because `rfork`
  copies the parent's memory eagerly.
- **Not yet:** running 9front commands from Go with `os/exec` unless your
  root tree has `/amd64/bin` (`zig build mkroot` on x86\_64, or
  `--arch amd64`).
- A Go program doesn't need a root tree to run. Without one it gets the
  built-in root (chapter 2), with `/tmp`, your cwd, and its 42 commands;
  give it `--root` for the full tree.

### 20. Linux programs

h9 runs Linux ELF programs as well as 9front ones
([linux-personality](design/0018-linux-personality.md)). There's no Linux
kernel: a Linux program's system calls are translated onto the same Plan 9
kernel that serves 9front programs, so it runs in the same machine, with
the same namespace, sandbox, network policy, and limits. Static and dynamic
programs for arm64 and amd64 run, built against musl or glibc; Alpine's
busybox, `apk`, Python, SQLite, PostgreSQL, Redis, Git, the Go and Zig
toolchains, fzf, htop, ripgrep, and Claude Code have all been run this way.

**A single binary.** A static Linux program on the host runs like a 9front
one, by its host path, with no Linux tree at all:

```sh
host$ zig cc -target x86_64-linux-musl -static -o hello hello.c
host$ h9 ./hello
hello from linux
```

Go programs built with `GOOS=linux` work the same way, which is the fast
way to run Go on an Apple Silicon Mac (chapter 19). A dynamic program needs
its loader and libraries, so it needs a Linux root.

**A Linux root.** `--root` takes a Linux file system as readily as a 9front
one. h9 tells them apart by looking: a tree with `/etc/os-release` or a
`/lib/ld-*` loader, and no `/rc/bin` or `/$cputype/bin`, is a Linux root.
Alpine's minirootfs, or any container image unpacked to a directory, works:

```sh
host$ mkdir alpine && curl -fsSL https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-minirootfs-3.22.2-aarch64.tar.gz | tar -xzf - -C alpine
host$ h9 --root ./alpine sh -c 'cat /etc/alpine-release; id -u'
3.22.2
0
host$ h9 --root ./alpine sh
/mnt/term/cwd #
```

[Recreating Docker](docs/containers.md) shows how to pull any image from
Docker Hub this way. `--root` can be given twice, once for a 9front tree and
once for a Linux one, in either order. With only a Linux root, the 9front
side comes from the usual lookup (`$H9ROOT`, the development tree, then the
built-in root), and `--builtin=off` leaves the machine with none. A Linux
root has to be a host directory: 9P and WebSocket roots are always 9front
trees.

**Which program runs.** With a Linux root, a bare name (`h9 --root ./alpine
ls`) is looked up on the Linux `PATH`, and an absolute path is a path in the
Linux view, so `h9 --root ./alpine /9/bin/ls` runs 9front's `ls`. `--rc`
always runs 9front's rc. Each program then runs as what it is: an ELF exec'd
from 9front runs as Linux, and an a.out exec'd from Linux runs as 9front, so
the two kinds pipe into each other freely. A script that starts `#!/bin/rc` runs with 9front's rc when the Linux root has no `/bin/rc`, so `/9/bin/wsmount` works from busybox, and its mount is the shell's. A 9front program reaches the
Linux tree as `'#λ'` (quoted in rc), so `'#λ'/bin/busybox ls` runs
busybox from rc.

**The Linux view.** A Linux process's `/` is the Linux root, with a few
directories h9 provides on top:

| Path | What it is |
| --- | --- |
| `/9` | The machine's 9front root: `/9/bin/ls` is 9front's `ls` |
| `/tmp` | The machine's private `/tmp`, the same files a 9front program sees there |
| `/mnt/term` | The shared host paths; your cwd is `/mnt/term/cwd`, and programs start in it |
| `/dev` | `null`, `zero`, `full`, `random`, `urandom`, `tty` (the console), `stdin`, `stdout`, `stderr`, `fd`, `shm`, a private in-memory directory as a tmpfs would be, and `9`, the machine's 9front `/dev` as it was at start, so with `--gfx` a Linux program can open `/dev/9/draw`, `mouse`, and `kbd` |
| `/proc`, `/sys` | What libc, busybox, Python, and htop read: `cpuinfo` (following `--cpus`), `meminfo`, `mounts`, and per-process `stat`, `status`, `maps`, `cmdline`, `exe`, `fd`, and `task` |
| `/etc/resolv.conf` | Your host's DNS servers, when the root has none |

The root's symlinks always resolve inside it, as `chroot` would, so
Alpine's `/bin/ls -> /bin/busybox` reads the root's busybox
(`--root-contained` is implied). Writes to the root go to a copy-on-write
overlay in memory and are thrown away at exit, as for a 9front root, so
`apk add` works for the run; pass `--writable ./alpine` to keep what it
installs. `h9 --print` shows the view as binds on `'#λ'`.

**Users and the environment.** A Linux program starts as uid 0, and `stat`
shows every file as owned by it. That grants nothing: access is still the
namespace's and the sandbox's, as in a rootless container. The `set*id`
calls work, so `su` and programs that won't run as root (such as
PostgreSQL's `initdb`) behave as on Linux, and `chown` succeeds without
changing anything. A Linux program's environment is the machine's `/env`,
as `NAME=value`, plus `USER`, `LOGNAME`, `HOME`, and a default `PATH`;
`--env` sets more, and the host's environment still isn't imported.

**Network.** A socket is a `/net` connection underneath, so `--net`,
`--net-allow`, and listening only under `--net=enable` apply to Linux
programs exactly as to 9front ones. DNS is the program's own, through the
`/etc/resolv.conf` above, so under `--net-allow` a pattern has to cover
those servers (`udp!8.8.8.8!53`). Unix-domain sockets, `socketpair`,
`epoll`, `eventfd`, passing file descriptors, and passing credentials
(`SO_PASSCRED`) work between the processes of one machine, and
`SOCK_SEQPACKET` keeps each message whole. `memfd_create`, and a file
unlinked while still open, work for shared memory.

**The terminal.** `isatty` is true only when h9's standard input and output
are both terminals, so `ls` doesn't colour a pipe. A program that turns off
canonical mode or echo with `tcsetattr` changes the host terminal, so `vi`,
`less`, `read -s`, `fzf`, and `htop` work, and `TIOCGWINSZ` gives the host
terminal's size.

**Signals and exit status.** Notes and signals map onto each other: Ctrl-C
is `SIGINT`, a hangup `SIGHUP`, a fault `SIGSEGV`, and a Linux `kill` posts
`linux: signal N`, which a 9front program sees as a note. A Linux program
killed by a signal exits as a host shell would report it, 128 plus the
host's number for the signal:

```sh
host$ h9 --root ./alpine sh -c 'kill -TERM $$'; echo $?
h9: sh: linux: signal 15
143
```

**Architectures and speed.** A program for the host's architecture runs on
the hypervisor (or, with `--backend native`, the native backend), at native
speed apart from system calls. One for another architecture, such as an amd64 image on an Apple
Silicon Mac, runs only on the emulator (`h9-emu`), and much more slowly.
32-bit x86 programs run with `--arch 386` on the emulator
([linux-i386](design/0105-linux-i386.md)).

**Not yet.**

- Job-control stops: `SIGSTOP` and `SIGTSTP` are ignored, and a terminal
  resize doesn't send `SIGWINCH`.
- Hard links: `link` copies the file, since 9P has none, so the two names
  don't share later writes. `git clone` of a local repository needs
  `--no-hardlinks`.
- Moving a directory across directories inside the root's overlay, or
  between two overlays, fails with `EXDEV`; `mv` falls back to copying.
- Memory: `exec` copies the whole program image into the new process, so a
  large program that starts others, such as `zig cc` or a compiler driver,
  can need `--memory 3g` to `8g`
  (*Not yet available ([cow-fork](design/0121-cow-fork.md))*).
- CPU times in `/proc/stat` and `/proc/n/stat` read 0, so `top` and `htop`
  show 0%.
- `symlink` works in overlays (the root and `/tmp`) and host trees on macOS
  and Linux, but not on Windows hosts.
- A call h9 doesn't know returns `ENOSYS`, and `--trace` shows it as
  `= -ENOSYS (absent)`; please report the ones a program needs.

---

## Part III: Using h9

### 21. Command-line reference

**Synopsis**

```text
h9 [flags] [--] program [args...]
h9 [flags] --rc 'command' [args...]
h9 [flags] --rc
h9 [--backend B] [--root DIR|DIAL|SOCKET|URL] [--memory SIZE] --check
h9 --version
h9 --help          (or -h alone)
```

**Parsing rules**

- There are no subcommands: `h9 ls` always runs 9front's `ls`. h9's own
  functions are flags (`--check`, `--version`, `--help`).
- h9's flags are long flags only, and parsing stops at the first argument that
  doesn't start with `--`; everything from there on is the program and its
  arguments, so `h9 ls -l --help` passes both flags to `ls`. `--` ends h9's
  flags explicitly, for a program whose name starts with `--`.
- A flag's value can be the next argument or follow `=`: `--root DIR` or
  `--root=DIR`. Flags marked *repeatable* can be given more than once.
- `-h` is `--help` only when it's the only argument.
- Running `h9` with no program (and no `--serve`), an unknown flag, or a bad value prints the
  usage to standard error and exits 2. A combination h9 refuses (such as
  `--write=none --writable DIR`) prints `h9: ...` and exits 2.

**Program resolution**

| Argument | Resolution |
| --- | --- |
| Starts with `./` or `../` (on Windows also `.\` or `..\`) | A host file, relative to the host's current directory, read before the machine starts. It must be a 9front a.out or a Linux ELF binary. Its header decides the architecture unless `--arch` says otherwise. |
| Starts with `/` | A path in the machine's namespace, or in the Linux view with a Linux root (`/9/bin/ls` is then 9front's `ls`). The host's `/Users/me/x` is `/mnt/term/Users/me/x` inside, and only if it's shared. |
| Anything else (`ls`, `aux/vga`) | Looked up through `$path`, `(. /bin)`, or with a Linux root through the Linux `PATH` |
| `--rc 'cmd'` | `/bin/rc -c 'cmd'`, with the remaining arguments as `$*` |

A program found in the namespace may be an rc script starting with `#!`; a
host file may not (*Not yet available ([host-scripts](design/host-scripts.md))*).
With `--ns FILE`, the file is replayed before the program is looked up, so
the program can come from something the file binds.

**Flags**

Machine:

| Flag | Meaning |
| --- | --- |
| `--backend auto\|hvf\|kvm\|whp\|native\|emu` | What runs guest code (chapter 27). `auto` (the default) uses the host's hypervisor when it can run the program's architecture, and otherwise the emulator, with a warning. It never selects `native`, which shares h9's process and isn't a security boundary (chapter 23); pass `--backend native` to choose it for a trusted guest. Naming one that isn't built in or can't run here is exit 125. `whp` is incomplete ([whp](design/0017-whp.md)). |
| `--arch arm64\|amd64\|386` | The architecture to run. It picks `/$cputype/bin` and sets `$cputype`. Default: a host program's own, and the host's for anything else. Only the emulator runs amd64 on arm64 hosts, and 386 anywhere. |
| `--root DIR\|DIAL\|SOCKET\|URL` | The root: a host directory, a 9P server's dial string (`tcp!host!port`, `tcp!host`, `unix!path`), a unix socket's path, or a `ws://` or `wss://` URL (chapter 16), whose scheme can be left off: `wss://` is assumed, or `ws://` for a loopback host. A host directory can be a 9front tree or a Linux one, and `--root` can be given twice, once for each (chapter 20). Default: `$H9ROOT`, then `.local/9front/root` for a development build, then the built-in root. |
| `--builtin auto\|only\|before\|after\|off` | The built-in root (chapter 2). `auto` (the default) uses it when no 9front root is found, so a Linux root alone gets it as `/9`. `only` uses it even when `$H9ROOT` would give a root, and can't be used with `--root`. `before` and `after` put its commands in `/bin` before or after a root's. `off` never uses it, and leaves a Linux root alone without `/9`. |
| `--root-spec NAME` | The attach name sent to a 9P root. Default: empty. |
| `--root-user NAME` | The user name sent to a 9P root. Default: your user name. |
| `--user-map FILE` | A file in `/etc/passwd` format that maps user names to the numbers a 9P2000.L server sees, both ways. Without it, your user is sent as your host uid (65534 when you're root, never 0). |
| `--root-header 'NAME: VALUE'\|@FILE` | A header for a WebSocket root's handshake, such as `Authorization: Bearer ...`; repeatable. `@FILE` reads one header per line from a file, so a token stays out of `ps`. |
| `--root-ca FILE` | Trust this PEM file for a `wss://` root instead of the host's CA bundle |
| `--root-contained` | Resolve the root tree's symlinks inside it: `/bin/ls -> /bin/busybox` reads the tree's `/bin/busybox`, not the host's, and `..` stops at the tree's top. For 9front trees with links; a Linux root is always contained. With a 9P root, exit 2. |
| `--cwd DIR` | The host directory to bind at `/mnt/term/cwd` and start in, instead of the current one |
| `--env name=value` | Set a guest environment variable; repeatable. The host environment is never imported. |
| `--rc 'command'` | Run an rc command line instead of a program. It's always 9front's rc, even with a Linux root. |
| `--rc` (last) | Run a login rc: the root's default command from `/rc/lib/rcmain.local`, then an interactive rc on a terminal, or commands from stdin otherwise |
| `--ns FILE` | Replay a namespace file before running the program (chapter 25). `FILE` is a guest path; a relative one is in `/mnt/term/cwd`. |

Files and sandbox (chapters 22 and 23):

| Flag | Meaning |
| --- | --- |
| `--profile default\|tight` | The sandbox defaults; other flags override them |
| `--sandbox DIR` | `--profile=tight` with only `DIR` bound, read-write, as the cwd. Can't be combined with `--cwd`, `--host-fs`, or `--host-cmd`. |
| `--readable PATH` | Share a host path read-only; repeatable |
| `--writable PATH` | Share a host path read-write; repeatable |
| `--read-deny PATH` | Hide a host path, even inside a shared tree; repeatable. The path needn't exist. |
| `--write none\|scope\|ephemeral\|overlay` | `none`: deny every write. `scope`: writes go to the writable paths on the host, and the root is read-only. `overlay` (the default, in both profiles): as `scope`, with a copy-on-write overlay over the root, thrown away at exit. `ephemeral`: the root and the writable paths are copy-on-write overlays in memory, thrown away at exit. |
| `--net disable\|outbound\|enable` | No network; clients only (the default); clients and servers |
| `--net-allow PATTERN` | Allow connections only to matching dial strings; repeatable (chapter 15) |
| `--serve ADDR` | Serve the namespace over 9P on `unix!PATH`, `tcp!HOST!PORT`, or `ws://HOST:PORT/PATH`; repeatable. With no program, only serve (chapter 16) |
| `--serve-root PATH` | The guest path `--serve` exports, `/` by default |
| `--serve-token @FILE` | The token WebSocket listeners require |
| `--serve-origin ORIGIN` | An `Origin` WebSocket listeners accept, or `*` with a token; repeatable |
| `--serve-net` | Export `/net` too |
| `--host-fs` | Show the whole host file system, read-only, at `/mnt/term` |
| `--host-cmd` | Leave `#C`, which runs host commands, unmasked. Only in builds with `-Dhost-cmd`; otherwise exit 2. |
| `--no-guest-tools` | Leave h9's own commands (`#H/bin`) off `/bin`, and mask `#H` |
| `--strict` | Refuse, with exit 2, anything this build can't enforce |
| `--print` | Print the compiled sandbox plan and exit without running |

Limits (chapter 24):

| Flag | Meaning |
| --- | --- |
| `--memory SIZE` | Cap guest memory: a byte count or `k`, `m`, `g`, `t` (`512m`, `4G`). Default 1 GB, at most 32 GB. |
| `--timeout DURATION` | Post `hangup` after `ms`, `s`, `m`, or `h` (`30s`, `500ms`; a plain number is seconds), and stop the machine 2 s later |
| `--pids N` | Cap live processes |
| `--cpus N` | Cap processes running guest code at the same moment |

Debugging (chapter 28):

| Flag | Meaning |
| --- | --- |
| `--trace[=FILE]` | Log every system call, to standard error or to `FILE` |
| `--dump-on-fault` | Print the registers and the symbolized PC when a program faults |
| `--gfx[=noclip]` | Give the machine a host window, with `/dev/snarf` as the host clipboard, or private with `=noclip` (chapter 17) |
| `--gfx-scale N` | The window's scale on macOS: 1 points, 0 backing pixels, N backing pixels divided by N |

Tools:

| Flag | Meaning |
| --- | --- |
| `--check` | Check each backend and the root, then exit 0 or 125 (chapter 2). Takes `--backend`, `--root`, `--root-spec`, `--root-user`, `--builtin`, and `--memory`. |
| `--version` | Print the version, the pinned 9front and drawterm revisions, the backends built in, and the window code (`gfx:`) |
| `--help`, `-h` | Print the usage to standard output |


**Exit codes**

| Code | Meaning | Printed on standard error |
| --- | --- | --- |
| 0 | The program's exit string was empty | Nothing |
| 1–255 | The exit string was that number in decimal (digits only: no sign, leading zero, or spaces) | Nothing |
| 1 | Any other exit string, including `0`; or the program was killed by a note that isn't a signal | The string, or `h9: PROG: NOTE` |
| 2 | Usage error or refused combination | The usage, or `h9: ...` |
| 124 | `--timeout` was reached | `h9: PROG: h9: timeout` |
| 125 | h9 failed: no root, no usable backend, too little memory, a 9P root that can't be reached, a `--serve` address that can't be listened on, or the machine failed mid-run | `h9: ...` |
| 126 | The program isn't a runnable a.out or ELF binary for this machine | `h9: PROG: not a 9front executable...` |
| 127 | The program wasn't found | `h9: PROG: ...` |
| 128+N | The program was killed by a note that's signal N, as a shell reports it: 130 for Ctrl-C (`interrupt`), 129 for `hangup`, 137 for `kill`, 141 for a closed pipe, 139 for a fault; a Linux program killed by signal N (`linux: signal N`); or a second Ctrl-C (130), SIGHUP (129), or SIGTERM (143) stopped the machine. N is the host's number for the signal, so `usr1` is 138 on Linux and 158 on macOS | Nothing for Ctrl-C and a closed pipe; otherwise `h9: PROG: NOTE` |

**Signals and the terminal**

| | macOS and Linux | Windows |
| --- | --- | --- |
| Ctrl-C | `interrupt` to the foreground note group; a second within a second stops the machine | The same, and Ctrl-Break posts `interrupt` too |
| Ctrl-C in raw mode | Reaches the program as a key | The same |
| Hangup | SIGHUP or SIGTERM: `hangup` to every process, stop 2 s later | Closing the console, logoff, or shutdown: the same, with a shorter grace period because Windows ends the process soon after |
| Raw mode | termios: no line editing, echo, or signals | Console mode: the same |

### 22. Sharing files with the host

**The current directory.** The host directory you run h9 from, or `--cwd
DIR`, is bound at `/mnt/term/cwd`, read-write, and is the program's working
directory, so relative paths mean what you expect: `h9 cat notes.txt` reads
your file. Under `--profile=tight` it's read-only.

**More directories.** `--readable PATH` shares a host path read-only, and
`--writable PATH` read-write. Where a path appears depends on where it is:

| The host path is... | It appears at | Example |
| --- | --- | --- |
| Inside the cwd | Its place under `/mnt/term/cwd` | `--writable ./out` is `/mnt/term/cwd/out` |
| Inside the root tree | Its place under `/` | `--writable "$H9ROOT"` makes `/` writable |
| Anywhere else | `/mnt/term/<host path>` | `--readable ~/notes` is `/mnt/term/Users/me/notes` |

For the last case h9 unions the host's `/` after the tree's `/mnt/term`, and
the sandbox shows only the shared paths and the directories leading to them,
so `ls /mnt/term/Users/me` lists `notes` and nothing else. A `--writable`
path inside a read-only one (`--profile=tight --writable ./out`) is writable
while the rest stays read-only.

```sh
host$ h9 --readable ~/src/proj --rc 'grep -n TODO /mnt/term'$HOME'/src/proj/*.c'
```

The host shell fills in `$HOME` there; inside, rc's `$home` is `/usr/me`,
not your host home.

**Hiding secrets.** `--read-deny PATH` hides a path inside a shared tree, so
it doesn't appear in listings and opening it fails with `file does not
exist`. It wins over every allow, and the path doesn't have to exist yet:

```sh
host$ h9 --read-deny .env --read-deny secrets ls
```

**The whole host.** `--host-fs` shows the entire host file system read-only
at `/mnt/term` (and unmasks `#U`). `--writable` paths are still writable.

**Ephemeral writes.** `--write=ephemeral` makes every path that would be
writable (the cwd, each `--writable` path) a copy-on-write overlay in memory
instead. The program can create, change, remove, and rename files there and
sees its changes, but they're thrown away when the machine ends, and the host
is never written. That's the way to let a program mess with a directory
safely:

```sh
host$ h9 --write=ephemeral --rc 'rm -f *.c && echo gone > x && ls'
mkfile
x
host$ ls
cat.c  ls.c  mkfile
```

The overlay copies a file into memory, whole, the first time it's opened for
writing, and it counts against `--memory`; when memory runs out, writes fail
with `file system full`. Renaming a host directory inside an overlay is
refused with `permission denied`.

**Exclusive-use files.** In an overlay (the root, `/tmp`, ephemeral paths),
a file with the `l` mode bit (`DMEXCL`, set by `create` or `chmod +l`) can
be open only once at a time in the machine, as on 9front's file servers: a
second open fails with `file is locked` until the first is closed. Host
directories have no such bit, so it isn't kept there: a file created with it
on a shared host path opens as often as any other.

**`/tmp`.** Every machine has its own `/tmp`, an overlay in memory over the
root tree's empty `/tmp`, in both profiles. It's not your host's temporary
directory and it disappears with the machine. Under `--write=none` it's
read-only.

**Host file system details.**

- **Windows paths.** Inside, a Windows path `C:\Users\me` is `/C:/Users/me`,
  so a shared directory appears at `/mnt/term/C:/Users/me/...`.
- **Case-insensitive file systems** (macOS and Windows defaults): names
  match as the host matches them, and h9 checks access by each file's real
  name, so `.ENV` can't be used to reach a denied `.env`.
- **Symlinks** are followed, and every path is checked *after* resolving
  them, so a link inside a shared tree that points outside it fails as if
  the target didn't exist. Creating, removing, or renaming acts on the link
  itself.
  With `--root-contained`, the root tree's links are read inside it
  instead: an absolute target starts at the tree's top, and `..` stops
  there, so a Linux root's `/bin/ls -> /bin/busybox` works as it does in
  that system. A loop of links is "too many symbolic links".
- **Hardlinks** can't be detected that way: a hardlink inside a writable
  path to a file outside it lets the guest change that file. `--print` lists
  this as a caveat.
- **Line endings** aren't translated. Plan 9 programs write `\n`.
- **Ownership.** `ls -l` shows the host's owner and group names, and the
  host's permission bits. Changing them with `chmod` works where the host
  lets you; there's no `chown` across users.

### 23. Sandboxing

> **Warning.** h9 is an in-development research prototype. Its sandbox
> hasn't been through a security audit. Don't rely on it to contain
> malicious code until it has.

**The threat model in plain words.** A program in h9 runs in a separate
address space on a virtual CPU, so it can't touch the h9 process's memory or
make host system calls: every system call is answered by the Plan 9 kernel
inside h9. A Linux program's
calls are answered the same way, by the same kernel. That kernel's namespace is the only route to your host, and h9
builds it from the policy: which host directories to bind, read-only or not,
whether `/net` exists, and which devices are masked so they can't be
attached again. What's *not* protected: the h9 process itself, which runs as
you with your full rights and isn't sandboxed by the host, so a bug in h9's
kernel or device code is a bug in the sandbox; and anything you share. The
native backend goes further: it runs guest code in h9's own process, so it
is not a boundary at all, and `auto` never chooses it — use it, with
`--backend native`, only for a program you already trust.

**Profiles**

| | `default` | `tight` | `--sandbox DIR` |
| --- | --- | --- | --- |
| Root tree | Read-only | Read-only | Read-only |
| Host cwd | Read-write | Read-only | Not bound; `DIR` is the cwd, read-write |
| Other host paths | Hidden | Hidden | Hidden |
| `/tmp` | Private, in memory | Private, in memory | Private, in memory |
| Network | Outbound only | Off | Off |
| Host commands (`#C`) | Masked | Masked | Masked |
| Environment | Defaults plus `--env` | The same | The same |
| Timeout | None | 10 minutes | 10 minutes |
| Memory, processes, CPUs | 1 GB, unlimited, unlimited | The same | The same |

Explicit flags override the profile: `--profile=tight --net=outbound` gives
tight with a network.

**Capabilities.** The plan names what's enforced as capabilities:

| Capability | Meaning | Controlled by |
| --- | --- | --- |
| `env.scrub` | The host environment isn't imported | Always |
| `kernel.isolation` | System calls are answered by h9's kernel, not the host's | Always |
| `ipc.restrict` | Host sockets and pipes are reachable only through devices the policy controls | Always |
| `fs.read.scope` | Only shared host paths can be read | Everything but `--host-fs` |
| `fs.write.scope` | Only writable paths can be written | Always |
| `fs.read.deny` | Denied paths are hidden even in shared trees | `--read-deny` |
| `fs.write.ephemeral` | Writable paths are overlays in memory | `--write=ephemeral` |
| `fs.write.overlay` | The root is an overlay in memory | `--write=overlay` (the default), `--write=ephemeral` |
| `net.disable` | No network device | `--net=disable`, `tight` |
| `net.outbound` | Connects allowed, listening refused | `--net=outbound`, `default` |
| `net.allow` | Connects only to allowed dial strings | `--net-allow` |
| `res.memory` | Guest memory capped | `--memory` |
| `res.pids` | Live processes capped | `--pids` |
| `res.cpu` | Running vCPUs capped | `--cpus` |
| `proc.timeout` | A deadline for the machine | `--timeout`, `tight` |

**Reading `--print`.** `--print` compiles the policy and prints it without
running anything:

```text
host$ cd ~/src/proj
host$ h9 --print --profile=tight --writable ./out --memory 512m --timeout 1m mk
profile:  tight
enforces: env.scrub fs.read.scope fs.write.overlay fs.write.scope ipc.restrict kernel.isolation net.disable proc.timeout res.memory
limits:   write=overlay net=disable memory=512M timeout=1m
devmask:  #C #I #ℏ #U #b #i #m
namespace:
  bind '#U/Users/me/src/hyper9/.local/9front/root-11952' / ro
  bind -c '#O' /                                         eph  # /Users/me/src/hyper9/.local/9front/root-11952
  bind '#c' /dev
  bind -b '#y<id>' /dev
  bind -c '#e' /env
  bind '#d' /fd
  bind '#p' /proc
  bind -c '#s' /srv
  bind '/arm64/bin' /bin
  bind -a '/rc/bin' /bin
  bind -a '#H/bin' /bin  # h9's commands
  bind -c '#O' /tmp                                      eph  # /Users/me/src/hyper9/.local/9front/root-11952/tmp
  bind '#U/Users/me/src/proj' /mnt/term/cwd              ro
  bind -c '#U/Users/me/src/proj/out' /mnt/term/cwd/out   rw
access:
  eph  /Users/me/src/hyper9/.local/9front/root-11952
  ro   /Users/me/src/proj
  rw   /Users/me/src/proj/out
caveats:
  - writes to the root are kept in memory, count against --memory, and are lost when the machine ends; when memory runs out they fail with "file system full"
  - a file opened for writing is copied into memory whole the first time
  - hardlinks under writable paths can modify host files outside them
  - writes to writable paths are not capped (no res.disk)
  - paths are checked after resolving symlinks, so a host process renaming paths concurrently can race the check
  - /proc/n/ns shows the host paths of bound host trees
  - the h9 process itself is not host-sandboxed
```

| Section | What it says |
| --- | --- |
| `profile:` | The profile the defaults came from |
| `enforces:` | The capabilities in force |
| `unenforced:` | Shown only when you asked for something this build can't enforce yet |
| `limits:` | The write and network modes, and any memory, timeout, process, and CPU caps |
| `devmask:` | Devices a program can't attach by name after startup |
| `net-allow:` | Shown only with `--net-allow`: the patterns |
| `namespace:` | The namespace, in namespace-file syntax, with each host tree's access (`ro`, `rw`, `eph`, `9p`) at the end of its line; `<id>` stands for the machine's console number |
| `access:` | The rules the host file system device checks: allowed read-only, read-write, ephemeral, or denied, by host path |
| `caveats:` | What the sandbox doesn't cover in this configuration |

**`--strict`.** When you ask for something this build can't enforce, h9 falls
back to the safer choice and lists it as `unenforced`, and `--strict` refuses
to run instead, with exit 2. This build enforces every capability it knows,
so today `--strict` always runs.

**Recipes**

```sh
# Run an untrusted script against your project, keeping every change in memory:
host$ h9 --write=ephemeral --net=disable --timeout 5m --rc 'mk test'

# Build, writing only to ./out:
host$ h9 --profile=tight --writable ./out mk

# Read a source tree with its secrets hidden:
host$ h9 --readable ~/src/proj --read-deny ~/src/proj/.env ls /mnt/term$HOME/src/proj

# Work in a scratch directory and nothing else:
host$ h9 --sandbox ./work --rc 'touch f && ls'

# No network, capped time and memory, for CI:
host$ h9 --net=disable --memory 512m --timeout 30s --pids 64 --rc 'mk test'

# Egress only to one API:
host$ h9 --net-allow 'tcp!api.example.com!443' ./client
```

### 24. Resource limits

| Flag | Units | Default | When a program hits it |
| --- | --- | --- | --- |
| `--memory SIZE` | Bytes, or `k`, `m`, `g`, `t` | 1 GB, at most 32 GB | Memory is allocated on demand from one region of this size. If the program doesn't fit at all, h9 exits 125 (`OutOfGuestMemory`). Later, growing memory fails (`malloc` returns nil) and creating `/tmp` or ephemeral files fails with `file system full`. |
| `--pids N` | A count | Unlimited | `rfork` fails with `no procs`, and the program that tried gets the error |
| `--cpus N` | A count | Unlimited (the host's CPUs, and 64 on macOS) | Nothing fails: past `N` running at once, processes wait their turn. `/dev/sysstat` and Go's `runtime.NumCPU` report `N`. |
| `--timeout DURATION` | `ms`, `s`, `m`, `h`; a plain number is seconds | None (`tight`: 10 minutes) | Every process gets a `hangup` note; 2 s later the machine is stopped, and h9 prints `h9: PROG: h9: timeout` and exits 124 |

Memory counts everything the machine uses for guests: each process's
memory, the stacks, shared segments, and the files in `/tmp` and ephemeral
overlays. `--memory 8m` is enough for `echo`; a Go program needs several
hundred MB, or about 4 GB if it starts other processes.

### 25. Namespace files with `--ns`

`--ns FILE` replays a namespace file after h9 has built the machine's
namespace and before it looks up the program, so the file can add, replace,
or remove anything h9 set up, and the program can come from a directory the
file binds.

**Syntax** (a subset of `namespace(6)`):

| Line | Meaning |
| --- | --- |
| `bind [-abcC] new old` | As `bind(1)` |
| `mount [-abcC] srvfile old [spec]` | As `mount(1)`; `srvfile` is usually a `/srv` entry |
| `unmount [new] old` | As `unmount(1)` |
| `cd dir` | Change the working directory |
| `clear` | Start from an empty namespace (the device mask stays) |
| `# ...` | A comment, also at the end of a line |

Quote with single quotes, doubling a quote inside one. `--print`'s extra
column (`ro`, `rw`, `eph`, `9p`) and its `<id>` placeholder are accepted, so
its output replays unchanged. A bind from a bare `#O` creates a fresh
copy-on-write overlay in memory over whatever its target is at that point.
`.` (include), `chdev`, and `$variable` expansion aren't supported.

**Errors.** As in 9front's `newns`, a line that fails (a missing directory,
a masked device) is skipped and the replay goes on; `--trace` shows which
call failed. A syntax error stops h9 with exit 125.

**Where the file is.** `FILE` is a guest path, read inside the machine: a
relative path is in `/mnt/term/cwd`, your host directory, and an absolute one
is in the root tree. A file elsewhere on the host has to be shared first.

**Workflow**

```sh
host$ h9 --print rc | sed -n '/^namespace:/,/^access:/p' | sed '1d;$d' > ns
host$ cat ns
  bind '#U/Users/me/src/hyper9/.local/9front/root-11952' / ro
  ...
  bind -c '#U/Users/me/src/proj' /mnt/term/cwd           rw
host$ echo "bind -b /mnt/term/cwd/bin /bin" >> ns
host$ h9 --ns ns rc
```

Replaying a namespace doesn't widen the sandbox: `#U` is already masked when
the file runs, so a line binding `'#U/...'` fails and is skipped, and the
bind h9 already made stays. That's why replaying `--print` output is
harmless: only the lines you add, or that differ, change anything. A
`bind -c '#O'` line, on the other hand, does take effect: it puts a fresh
overlay in memory over its target, so the target becomes writable for the
run, even under `--write=none`. An `#O` line whose target is a bind or
mount point, such as `/mnt/term/cwd`, overlays the tree bound there. One
over `/` keeps what was bound below it before: `/mnt/term/cwd` still shows
your directory, and the program starts in it.

Simpler files are fine too:

```sh
host$ echo 'bind /sys/lib /lib' > ns
host$ h9 --ns ns ls -d /lib/acid
/lib/acid
```

### 26. Using h9 from host scripts and tools

h9 behaves like a host program: standard input, output, and error are its
own, and its exit status follows the table in chapter 21.

```sh
# In a pipeline:
host$ git diff | h9 wc -l

# In a Makefile:
check:
	h9 --rc 'mk test'

# Testing the result:
if h9 grep -s TODO *.c; then echo "has TODOs"; fi
case $? in 125|126|127) echo "h9 itself failed";; esac
```

**Arguments through two shells.** With a program, arguments pass through
untouched: `h9 grep -n 'a b' file` gives grep exactly `a b`. With `--rc`,
rc parses the command line again, so put values in arguments rather than in
the command text, where they arrive safely as `$1`, `$2`, and `$*`:

```sh
host$ h9 --rc 'grep -n $1 $2 | sed 5q' "$pattern" "$file"
```

**Wrapping a 9front tool** as a host command:

```sh
# ~/.zshrc or ~/.bashrc
ssam() { h9 ssam "$@"; }
mk9() { h9 mk "$@"; }
```

```sh
#!/bin/sh
# ~/bin/9sed: 9front sed, reading stdin
exec h9 sed "$@"
```

**One machine or many.** Each `h9` invocation starts a new machine, which
costs a few milliseconds on a hypervisor (`--check` prints the time for a
tiny program). That's cheap enough to run per command. Use one `--rc`
command line, or an rc script, when the commands need to share state:
environment variables, binds, `/tmp` files, posted servers, or background
processes.

**Embedding h9 in a Zig program.** The CLI is a thin layer over a library.
`Machine.init` takes `Machine.Options` (the backend, architecture, root,
cwd, environment, sandbox `Policy`, standard I/O, and an optional trace
writer), and `Machine.run` runs a program and returns its exit string
unchanged; the mapping to exit codes is the CLI's. Several machines can run
in one host process. [Embedding h9 in a Zig program](docs/embedding.md)
walks through all of it with an example that builds.

### 27. Backends and performance

A **backend** is what runs guest code:

| Backend | Host | Runs |
| --- | --- | --- |
| `hvf` | macOS on Apple Silicon (Hypervisor.framework) | arm64 |
| `kvm` | Linux x86\_64 and arm64, with access to `/dev/kvm` | The host's architecture. The arm64 path is built but hasn't yet run on an arm64 KVM host ([#92](https://github.com/progrium/hyper9/issues/92)). |
| `whp` | Windows x86\_64, with the Windows Hypervisor Platform feature | amd64 |
| `native` | Linux x86\_64, 5.11 or later, without a hypervisor | amd64 |
| `emu` | Any, in `h9-emu` only (Unicorn) | arm64, amd64, and 386 |

`--backend auto`, the default, uses the host's hypervisor if it's built in,
usable, and can run the program's architecture, and otherwise the emulator,
printing `h9: warning: no usable hypervisor; using the emulator`. It never
chooses the native backend, which shares h9's process and isn't a security
boundary; where only native could run (Linux x86\_64 without KVM, in an
`h9` that has no emulator), `auto` fails and points you at `--backend
native` as an explicit choice for a trusted guest. Naming a backend uses
that one or fails with exit 125, and `--backend native` warns that it isn't
a security boundary. `h9 --check` lists each backend built in and whether it
works here.

**KVM** runs guest code on a virtual CPU, as Hypervisor.framework does on a
Mac. In a VM it needs nested virtualization, and each system call then goes
through both hypervisors, so it costs tens of microseconds rather than
about one.

**The native backend** runs amd64 guest code directly on the CPU, with no
hypervisor, so it works in containers without `/dev/kvm` and cloud VMs
without nested virtualization ([native-backend](design/0095-native-backend.md)).
Each address space is a tiny stub process that h9 starts; the kernel's
Syscall User Dispatch turns every system call the guest makes into a signal
h9 answers, and a seccomp filter kills the stub if guest code reaches the
host kernel any other way. It's much faster than the emulator (an awk loop
that takes 10.7 s on the emulator takes 0.24 s), and a Linux program's
threads run in parallel. Unlike under KVM, guests see the host CPU's
features, such as AVX-512, in `CPUID`. It runs amd64 only. Because the stub
shares h9's own address space, this backend is **not a security boundary**:
guest code that gets past the dispatch and seccomp gates reaches the h9
process. So `auto` never picks it, and you choose it with `--backend native`
only for a program you trust (chapter 23).

**The emulator.** Use it where there's no hypervisor (Windows on ARM,
Windows without the Windows Hypervisor Platform, and arm64 Linux VMs
without nested virtualization), where there's no KVM and you won't opt into
the native backend, for Go
programs on Apple Silicon, and for testing amd64 or 386 programs on any
host. Measured on an M3 Max: system calls cost about the same as on the
hypervisor (about 0.8 µs round trip, against 1.1 µs), so shell pipelines
and file-heavy work run at nearly the same speed, while arm64 computation
runs about 5 times slower and amd64 about 7 times slower. The emulator runs
guest code on one virtual CPU at a time, so CPU-bound programs don't get
faster with more processes; blocking in the kernel still overlaps.

**In a browser.** h9 also builds for WebAssembly, where the emulator runs
386 programs ([browser-host](design/0012-browser-host.md)). `--backend v86`,
the browser's backend before the emulator replaced it, is another name for
`emu`.

**vCPU limits.** Each process normally has its own vCPU. On macOS the
hypervisor allows 64; KVM usually allows 1024, fewer if h9 can open few
file descriptors, since each vCPU holds one; WHP is set to 64. Past the
limit less 8, the rest share a pool of 8, costing a thread handoff per
system call. `--cpus N` caps how many processes run guest code at the same
moment, on every backend. The emulator and the native backend have no vCPU
limit; `h9 --check` prints the limit for each hypervisor.

### 28. Debugging

**Tracing system calls.** `--trace` prints a line for each system call to
standard error, or `--trace=FILE` writes them to a file, much like 9front's
`ratrace`: the pid, the call and its arguments, and the result, with the
error string when it failed. Linux programs' calls are traced too, by their
Linux names, and a call h9 doesn't serve shows as `= -ENOSYS (absent)`:

```text
host$ h9 --trace cat /lib/nosuch
...
1 open "/lib/nosuch" 0 = -1 'file does not exist: '/lib/nosuch''
...
```

**Faults.** `--dump-on-fault` prints the registers, the faulting address, and
the program counter, named by the a.out's symbol table, when a program takes
a fault it doesn't handle.

**`/proc`.** `ps`, `pstree`, `/proc/n/status`, `/proc/n/fd` (open files),
`/proc/n/ns` (the namespace) and `/proc/n/segment` (memory) work, and so
does `acid`, Plan 9's debugger: `h9 --rc 'sleep 5 & sleep 1; acid $apid'`,
then `stk()` for a stack trace; `new()`, `bpset`, `cont`, `step`, and `next`
work too
([self-host](design/0010-self-host.md)).

**Whose error is it?**

| You see | It came from |
| --- | --- |
| A message starting `h9:` and exit 2 or 125–127 | h9 itself (chapter 29) |
| `h9: PROG: h9: timeout` | `--timeout` |
| A program's own message, such as `ls: x: file does not exist: 'x'`, and exit 1 | The program; the error string came from the Plan 9 kernel |
| `mount/attach disallowed` | The device mask (chapter 7) |
| `mounted directory forbids creation` | A read-only bind |
| `permission denied` on a host path | The sandbox's rules or the host; `--print` and chapter 12 tell which |
| `permission denied` on a network write | The network policy (chapter 15) |
| `sys: bad sys call` | A system call h9 doesn't implement |

### 29. Troubleshooting and FAQ

**Exit 125: h9 couldn't run anything.** The message says why: no root tree
(`h9: no root tree found; pass --root or set H9ROOT`, chapter 2), a root
that isn't there, no usable backend (`zig build` signs h9 on macOS; join the
`kvm` group on Linux; or use `h9-emu`; `h9 --check` says which backends
work), a 9P root that refused the connection or wants authentication, or
too little memory (`OutOfGuestMemory`: raise `--memory`).

**Exit 126: not a 9front executable.** The file isn't a Plan 9 a.out or a
Linux ELF binary (a script given by host path, a Mach-O or PE binary), or
it's for an architecture this backend can't run: an amd64 binary on an Apple
Silicon Mac needs `h9-emu`, and a 386 binary always does. A guest `#!`
script whose interpreter line is empty also gives 126.

**Exit 127: not found.** Bare names are looked up in `.` and `/bin` inside
the machine. To run a program from your host directory, write `./prog`; to
run one elsewhere on the host, share its directory and use the guest path,
or `cd` there first.

**"permission denied".** Run the same command with `--print` to see the
binds and access rules, and with `--trace` to see which call failed. If the
host denies the operation outside h9 too, it's the host's permissions.
Chapter 12 has the table.

**"sys: bad sys call".** The program used a system call h9 doesn't
implement. The old compatibility calls (`_READ`, `_STAT`, and so on) aren't
served, as they're not used by current 9front. Please report others.

**A Linux program fails with "Function not implemented".** It made a Linux
system call h9 doesn't serve (`ENOSYS`). `--trace` shows which, as
`= -ENOSYS (absent)`. Please report it, with the program. Chapter 20 lists
what's known to be missing.

**A large Linux program can't start others** (Zig reports
`SystemResources`). `exec` copies the whole program image, so raise
`--memory` (`3g` to `8g` for compilers such as `zig cc`).

**"no procs".** `--pids` is too low for what the program starts. A pipeline
of `n` commands under `rc` needs `n + 1`.

**A program hangs reading the console, or Ctrl-C does nothing.** The program
is waiting for input on `/dev/cons`: type a line, or end input with Ctrl-D.
In raw mode Ctrl-C is a key, not an interrupt; press it twice within a second
to stop the machine, or close the terminal. When h9 reads from a pipe, the
program gets end of file when the pipe closes.

**Why doesn't `$HOME` or `$PATH` from my host show up?** h9 never imports the
host environment (chapter 11). Use `--env` for what you want to pass.

**Why don't colours, `less`, or `vi` work?** Plan 9 programs don't use
terminal escape codes, and there's no full-screen terminal interface. Use
`p` to page, `sam -d` or `ed` to edit, and `lc` for columns. acme and rio
need a window: `h9 --gfx rio` (chapter 17).

**Why can't I mount on `/n/something`?** There's no `mntgen` filling `/n`
in. Make the mount point first, `mkdir /n/something`, which the root's
overlay allows (chapter 16).

**My changes to `/tmp` are gone.** Each machine's `/tmp` is private and in
memory. Write to the host cwd to keep files.

**`hget` fails.** It needs `webfs` running at `/mnt/web` (chapter 15).

---

## Going further

Guides that put many of the features above together to build something.
They change faster than this manual, as proposals land.

- [Recipes](docs/recipes.md): quick one-liners for everyday use,
  sandboxing, mounts, serving 9P, building, and Go.
- [Embedding h9 in a Zig program](docs/embedding.md): a Zig program that
  runs 9front programs in machines of its own, several at once, with
  captured I/O, a sandbox policy, and 9P roots.
- [Building your own userland](docs/userland.md): a root of your own, from
  one Go program to a slim 9front, a layer over the stock root, or a tree
  served over 9P or WebSocket.
- [How h9 compares](docs/comparison.md): h9 next to containers, gVisor,
  microVMs, WSL, Wine, WASI runtimes and other ways to run Plan 9.
- [Recreating Docker](docs/containers.md): Docker-style images, layers,
  volumes, ports, and limits, from slim root trees and Linux images pulled
  from Docker Hub to images served over 9P, ending in a docker-like CLI.
- [Running Windows programs](docs/windows.md): Wine in a Linux root, a
  prefix that lasts between runs, console programs, and programs with
  windows through the `winedraw` display driver.

## Appendices

### A. Glossary

- **9P**: The protocol Plan 9 uses for all file access, local or remote. A program
  that answers 9P messages (attach, walk, open, read, write, stat, clunk, and a
  few more) is a *file server*, and its tree can be mounted anywhere in a
  namespace. See `intro(5)`.

- **9P root**: A root served by a 9P server over TCP or a unix socket instead of a host
  directory, given with `--root tcp!host!port`. See chapter 16.

- **a.out**: Plan 9's executable format: a short header, then text, then data, then a
  symbol table. h9 loads a.outs itself, and Linux ELF binaries through the
  Linux personality (chapter 20); it doesn't run Mach-O or PE programs. A
  program for an architecture the backend can't run exits 126.

- **attach**: The first 9P message on a connection, which gives a client the root of a
  server's tree. Attaching a kernel device is what a `#` name does.

- **backend**: h9's name for what runs guest code: a hypervisor (`hvf` on macOS, `kvm`
  on Linux, and `whp` on Windows), the host CPU in a stub
  process (`native`, on Linux x86\_64), or the emulator (`emu`). Chosen with
  `--backend`; see chapter 27.

- **bind**: Make one name in the namespace refer to another file or directory, like a
  symlink that lives in the process's namespace rather than on disk. See
  `bind(1)` and `bind(2)`.

- **chan**: The kernel's handle on an open or walked file: a file server, a path in it,
  and an offset. File descriptors refer to chans.

- **cpu server**: A Plan 9 machine that runs other users' programs, reached with `rcpu` (or
  drawterm). The user's own files appear on it at `/mnt/term`, a convention
  h9 borrows for the host's files.

- **cputype, objtype**: Environment variables naming the architecture programs run on (`cputype`)
  and the one the compilers build for (`objtype`): `arm64`, `amd64`, or `386`.
  `/bin` is built from `/$cputype/bin`.

- **devmask**: The set of kernel devices a process may no longer attach with a `#` name.
  Existing binds keep working, so the mask fixes the namespace in place. h9
  masks `#U` and `#C`, `#I` and `#ℏ` without a network, and the window's
  devices without `--gfx`, after building the namespace.

- **device, kernel device**: A file server built into the kernel, named by `#` and a letter (`#c` for
  the console, `#e` for the environment). See chapter 7 for h9's list and
  `intro(3)`.

- **dial string**: A network address in Plan 9 form: `network!host!service`, such as
  `tcp!9front.org!443` or `net!example.com!http`. See `dial(2)`.

- **drawterm**: A program that connects a Unix, macOS, or Windows host to a Plan 9 cpu
  server, with a small Plan 9 kernel inside it. h9 runs that kernel locally
  to serve its guests' system calls.

- **Egrp, Fgrp, Pgrp**: The kernel's environment group, file descriptor group, and namespace (process
  group). `rfork` chooses whether a child shares or copies each one.

- **ephemeral**: h9's `--write=ephemeral` mode, where writable host paths become
  copy-on-write overlays in memory that are thrown away when the machine ends.

- **exits string**: Plan 9 programs end with a string, not a number: empty for success, and
  otherwise a message saying what went wrong. rc keeps it in `$status`. h9
  turns it into host exit code 0, the number itself if it's a number from 1
  to 255, or 1, printing it, otherwise.

- **factotum**: The agent that holds a user's keys and runs authentication protocols for
  programs, served as files at `/mnt/factotum`.

- **file server**: Any program, or kernel device, that serves a file tree over 9P.

- **guest**: A Plan 9 program running inside h9, as opposed to the *host*, the operating
  system h9 itself runs on.

- **hostowner**: The user that owns a Plan 9 machine's kernel and devices; the closest thing
  Plan 9 has to root, with far fewer powers. In h9 it's the host user's name.

- **Hyper9**: The project; `h9` is its command and library.

- **Linux personality, Linux view**: The part of h9 that runs Linux ELF programs by
  translating their system calls onto the Plan 9 kernel, and the file tree
  a Linux process sees as `/` (the device `#λ`): the Linux root with `/9`,
  `/tmp`, `/mnt/term`, `/dev`, and `/proc` added. See chapter 20.

- **machine**: One h9 invocation: one namespace, console, environment, `/srv`, and process
  tree, which disappears when its first process exits. A library user can run
  several machines in one host process.

- **mount**: Attach a 9P server's tree at a name in the namespace. See `bind(1)`.

- **namespace**: A process's view of the file tree: which names lead to which files and
  servers. Each process has one, inherited by its children and changeable
  without affecting anyone else. See chapter 6.

- **newns, namespace file**: A script of `bind`, `mount`, and similar commands that builds a namespace,
  such as `/lib/namespace`. h9 replays one with `--ns`. See `namespace(6)`.

- **note, note group**: Plan 9's signals: strings such as `interrupt`, `hangup`, or `sys: trap: ...`
  posted to a process. A note group is the set of processes an interrupt is
  posted to, usually a shell and its foreground job. See `notify(2)`.

- **overlay**: h9's `#O` device: a copy-on-write tree in memory over a directory, used for
  the private `/tmp` and for ephemeral writes.

- **Proc**: The kernel's record of a process. In h9 each Proc is a host thread running
  guest code on its own vCPU.

- **profile**: A named set of sandbox defaults in h9: `default` or `tight`.

- **proposal**: A design document in `design/` describing a change to h9. This manual's
  badges link to the proposals for features that aren't built yet.

- **rc**: Plan 9's shell. See chapter 10 and `rc(1)`.

- **rfork**: Plan 9's process creation call, with flags choosing what the child shares
  with its parent and what it gets a copy of. See `fork(2)`.

- **rio**: Plan 9's window system, which is also a file server for the programs in its
  windows. Run it with `h9 --gfx rio`; see chapter 17.

- **root tree**: The directory holding an extracted 9front file system, which h9 serves as
  the guest's `/`. Chosen with `--root` or `$H9ROOT`; see Appendix C.

- **srv, /srv**: A directory where file servers post connections for others to mount. In h9
  each machine has its own. See `srv(3)` and `srv(4)`.

- **Tos**: "Top of stack": a small structure at the top of a new process's stack giving
  its pid and clock counters.

- **union directory**: A directory that combines several directories, made with `bind -a` or
  `bind -b`. Lookups try each member in order, and creates go to the first
  member bound with `-c`. `/bin` is one.

- **Ureg**: The saved user registers of a process, as the kernel sees them at a system
  call, fault, or note.

- **vCPU**: A virtual CPU from the host hypervisor, or an engine in the emulator. Each
  guest process normally has its own.

### B. Unix → Plan 9 cheat sheet

Commands marked † aren't usable in h9 yet; the notes say why.

**Commands**

| Unix | Plan 9 / 9front | Notes |
| --- | --- | --- |
| `ls --color`, `ls -C` | `ls`, `lc` | `lc` lists in columns; there are no colours |
| `less`, `more` | `p` | Pages by screenfuls; type Enter for the next one, `q` to quit |
| `vi`, `nano` | `sam`, `ed`, `acme` | `sam -d` runs sam without graphics; acme needs a window, `h9 --gfx acme` or acme in rio (chapter 17). 9front's `vi` is a MIPS emulator. |
| `make` | `mk` | mkfiles; see `mk(1)` |
| `cc`, `gcc` | `7c`/`7l` (arm64), `6c`/`6l` (amd64), `8c`/`8l` (386), `pcc` | Compile and link are separate steps (chapter 18) |
| `ps`, `kill PID` | `ps`, `kill name \| rc`, `slay name \| rc` | `kill` prints commands that write to `/proc/n/note`; pipe them to rc |
| `pkill -9` | `echo kill > /proc/n/ctl` | Kills whatever handlers the process has |
| `env`, `export X=1` | `ls /env`, `cat /env/X`, `X=1` | Every rc variable is in `/env` |
| `mount`, `ln -s`, `chroot` | `bind`, `mount`, `rfork n` | Per process, no privileges needed |
| `sudo`, `su` | none | There's no superuser |
| `ifconfig`, `netstat` | `netstat`, `cat /net/tcp/*/status` | h9's network has no `/net/ipifc` to configure |
| `curl`, `wget` | `hget` | Needs `webfs` running (chapter 15) |
| `nc` | `aux/listen1`, `con`, or `/net/tcp/clone` by hand | Listening needs `--net=enable` |
| `nslookup`, `host` | `ndb/csquery /net/cs` | |
| `ssh` | `ssh`, `rcpu` | `rcpu` connects to Plan 9 cpu servers |
| `man`, `apropos` | `man`, `lookman` | `sig name` prints a C function's signature |
| `grep -E`, `sed -E` | `grep`, `sed` | Plan 9 regexps are always "extended"; see `regexp(6)` |
| `xxd`, `hexdump` | `xd` | |
| `find` | `walk`, `du -a` | |
| `tar`, `gzip`, `unzip` | `tar`, `gzip`, `unzip` | |
| `strace` | `ratrace`, or `h9 --trace` | |
| `gdb` | `acid`, `db` | |
| `tmpfs` | `ramfs` | Or just `/tmp`, private and in memory in h9 |
| `sshfs`, NFS | `9fs`, `srv`, and `mount`, `sshfs` | Mount points go in `/tmp` in h9 (chapter 16) |
| `git` | `git` | 9front has its own git client |

**Concepts**

| Unix | Plan 9 |
| --- | --- |
| Signals (`SIGINT`, `SIGTERM`) | Notes (`interrupt`, `hangup`), strings posted to a process or note group |
| Exit status 0–255 | An exits string: empty means success |
| `fork`, `clone`, `unshare` | `rfork` with flags |
| `ioctl` | Writing text commands to a `ctl` file |
| Sockets, `connect`, `listen` | Dial strings and files in `/net` (`dial(2)`, `announce`) |
| `/proc` (mostly binary or Linux-specific) | `/proc/n/` text files: `status`, `ctl`, `note`, `ns`, `fd` |
| `$PATH` with many directories | One `/bin`, a union bound per process |
| Mount table, global | Namespace, per process |
| uid, gid numbers | User and group *names*, chosen by each file server |
| setuid programs | None; services are file servers with their own permissions |
| Terminal escape codes, curses | None; `/dev/cons` is plain text, and graphics are `/dev/draw` |
| Shared libraries | None; every program is statically linked |

**Shell (bash → rc)**

| bash | rc |
| --- | --- |
| `"$var"`, `'literal'` | `$var` (never re-split), `'literal'`; `''` inside quotes for a `'` |
| `X=1 cmd` | `X=1 cmd` (the same) |
| `arr=(a b); ${arr[1]}; ${#arr[@]}` | `arr=(a b); $arr(2); $#arr` (rc counts from 1) |
| `"$*"` joined | `$"*` |
| `$(cmd)` | `` `{cmd} `` |
| `<(cmd)` | `<{cmd}` |
| `cmd 2>/dev/null` | `cmd >[2]/dev/null` |
| `cmd 2>&1` | `cmd >[2=1]` |
| `$?` | `$status`, a string |
| `if [ -f x ]; then a; else b; fi` | `if(test -f x) a; if not b` |
| `case $x in a*) ...;; esac` | `switch($x){ case a*; ... }` |
| `[[ $x == a* ]]` | `~ $x a*` |
| `for f in *.c; do ...; done` | `for(f in *.c){ ... }` |
| `while cmd; do ...; done` | `while(cmd){ ... }` |
| `f() { ...; }`, `$1` | `fn f { ... }`, `$1` (and `$*`) |
| `a && b \|\| c` | `a && b \|\| c` (the same) |
| `trap '...' INT` | `fn sigint { ... }` |
| `"$a$b"`, `"${a}x"` | `$a^$b`, `$a^x` |
| `cmd &` then `$!` | `cmd &` then `$apid` |
| `source file`, `.` | `. file` |
| `~/x` | `$home/x` |
| `local x=1` | `@{ x=1; ... }` or `rfork e` |
| `$((1+2))` | `` `{echo 1+2 \| hoc} `` |

### C. The root tree

The root tree is a 9front file system extracted from the pinned release image
(9front 11952) by `zig build mkroot`. h9 serves it read-only as `/`, under
a copy-on-write overlay in memory, so a guest's changes vanish with the
machine and the tree changes only if you pass `--writable "$H9ROOT"`. It's about
250 MB.

**Left out:** `/dist` (installer payloads), the kernels and boot files for
real hardware (`/arm64/9*`, `/386/9boot*`, and similar) and `/sys/doc`.
`/sys/src` is left out too unless `zig build mkroot -- --src` is used;
rebuilding 9front programs from source (chapter 18) needs it. The binaries in
the image are arm64; `/386` and `/amd64` are empty skeletons unless `zig build
mkroot` filled them by compiling `/sys/src` inside h9, which it does for your
machine's architecture or the ones `--arch` names.

**Where things are**

| Path | Contents |
| --- | --- |
| `/arm64/bin`, `/amd64/bin`, `/386/bin` | Compiled programs for each architecture; `/bin` is `/$cputype/bin` |
| `/rc/bin` | rc scripts, unioned after the binaries in `/bin` (`man`, `kill`, `slay`, `hget`, `lc`, `9fs`, ...) |
| `/arm64/lib`, `/arm64/include` | Architecture-specific libraries and headers for the compilers |
| `/sys/include` | Portable C headers (`u.h`, `libc.h`, ...) |
| `/sys/lib` | Support files for programs: `acid`, `plumb` rules, `kbmap`, `newuser`, `tls`, ... |
| `/sys/man` | Manual pages, sections 1–8; read with `man` |
| `/lib` | Data files: `namespace`, `ndb` (network database), `font`, `keyboard`, the dictionary, `rfc`, and more |
| `/lib/namespace` | 9front's standard namespace file. h9 doesn't run it; it builds its own (see `h9 --print`) |
| `/adm/timezone` | Time zone files; h9 copies `local` into `$timezone` |
| `/acme`, `/mail`, `/cfg` | acme's tools, upas mail, per-system configuration |
| `/usr/glenda` | The default user's home directory |
| `/dev`, `/env`, `/fd`, `/proc`, `/srv`, `/net`, `/n`, `/mnt`, `/mnt/term`, `/tmp` | Empty mount points for devices and binds. `/tmp` becomes the machine's private overlay; `/n` and `/mnt` stay empty, since nothing runs 9front's `mntgen` to fill them. |

**Home directories.** h9 sets `$home` to `/usr/$user`, using your host user
name. The tree only has `/usr/glenda`, so h9 makes `/usr/$user` in the root's
overlay: it exists and is writable, and is gone at exit. Under
`--write=scope` it doesn't exist; work in the host cwd or `/tmp` instead, or
pass `--env home=/mnt/term/cwd` to keep files in your host directory.

**Updating.** Each tree is unpacked to `.local/9front/root-<release>`, with
`.local/9front/root` linked to it, so a new release gets its own tree and the
old one stays until you delete it.

**Other roots.** Any 9front file tree works as `--root`, as long as it has
the mount points above and binaries for the architecture you run. A 9P
server works too (chapter 16), and so does a Linux root, such as Alpine's
(chapter 20).

### D. Further reading

**9front**

- [The 9front FQA](https://fqa.9front.org/): 9front's manual and FAQ. Start
  with [section 0](https://fqa.9front.org/fqa0.html) (introduction to Plan 9,
  including "Plan 9 is not UNIX") and
  [section 8](https://fqa.9front.org/fqa8.html) (using 9front: rc, rio, text
  editors, the internet).
- [9front man pages](https://man.9front.org/), the same pages as `/sys/man`.
- [9front source](http://git.9front.org/plan9front/9front/HEAD/info.html),
  and its [GitHub mirror](https://github.com/9front/9front).

**Papers.** These are in `/sys/doc` on a 9front system, which h9's root tree
leaves out; the [9p.io copies](https://9p.io/sys/doc/) are the Bell Labs
originals.

- "Plan 9 from Bell Labs", Pike et al.: the overview. Read this first.
- "The Use of Name Spaces in Plan 9", Pike et al.
- "Rc — The Plan 9 Shell", Tom Duff.
- "The Organization of Networks in Plan 9", Presotto and Winterbottom.
- "Plan 9 C Compilers", Ken Thompson, and "How to Use the Plan 9 C Compiler",
  Rob Pike.
- "Maintaining Files on Plan 9 with Mk", Andrew Hume and Bob Flandrena.
- "The Text Editor sam" and "Acme: A User Interface for Programmers", Rob
  Pike.
- "Plumbing and Other Utilities", Rob Pike.
- "Security in Plan 9", Cox et al. (factotum and secstore).

**Man pages to read first**

| Page | About |
| --- | --- |
| `intro(1)` | Commands, and the conventions they share |
| `rc(1)` | The shell |
| `bind(1)`, `bind(2)` | Binds, mounts, and unions |
| `namespace(4)`, `namespace(6)` | The conventional namespace, and namespace files |
| `intro(3)` | Kernel devices; each device has its own page in section 3 |
| `intro(5)` | 9P |
| `fork(2)` | `rfork` and its flags |
| `notify(2)`, `proc(3)` | Notes and `/proc` |
| `srv(3)`, `ramfs(4)`, `exportfs(4)` | Posting and serving file systems |
| `dial(2)`, `ip(3)`, `ndb(6)` | Networking |
| `regexp(6)` | Regular expression syntax |
| `cons(3)` | `/dev/cons`, `consctl`, and the other console files |

**h9 itself**

- [DEVELOPING.md](DEVELOPING.md): building, testing, and releases.
- [SPEC.md](SPEC.md): how h9 works inside.
- [design/](design/README.md): proposals, including the ones this manual's
  badges point to.

**Related projects**

- [drawterm](http://drawterm.9front.org/), whose kernel h9 runs.
- [9vx](https://swtch.com/9vx/), which ran Plan 9 binaries on Linux and OS X in
  a vx32 sandbox; h9's closest ancestor.
- [plan9port](https://9fans.github.io/plan9port/), Plan 9's tools ported to
  Unix, for when you want rc or acme without h9.
- [hyper-linux](https://github.com/zw3rk/hyper-linux), the same shape as h9
  for Linux programs on macOS.
