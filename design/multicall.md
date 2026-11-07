---
slug: multicall
title: A multi-call 9front userland binary
status: draft
created: 2026-11-06
authors: [progrium]
depends: [10]
areas: [build, tests, docs]
---

# Proposal: A multi-call 9front userland binary

## Abstract

h9 gains a build of 9front's own commands as one statically linked multi-call binary, `9box`, in the spirit of busybox. The commands are 9front's sources, unmodified, compiled inside h9 by 9front's compilers; generated `-D` flags per command rename its global symbols so they can share one link. `9box` picks the command from the name it runs as, through hard links in a host tree or two-line `#!` stubs anywhere else. A new build step assembles a slim root around it: `9box`, its links or stubs, `rcmain`, the mount points h9 binds onto, and nothing else. Nothing changes in h9 itself: no flags, no `Machine.Options`, no devices.

## Background

- **Slim roots are a recipe today.** [The userland guide](../docs/userland.md) section 4 builds a slim 9front by copying about 20 binaries and `/rc/lib/rcmain` out of the stock tree, which is about 250 MB. That works, but every binary is a separate static link, so each carries its own copy of libc and libbio, and the tree is as many files as commands.
- **9front builds itself in h9.** [self-host](0010-self-host.md) measured `mk` in `/sys/src/cmd` rebuilding the shipped binaries byte for byte, and `cd /sys/src && mk install` in about a minute. So h9 can build a 9front program without a 9front machine, and this proposal relies on that.
- **Commands collide when linked together.** A scan of 9front's `sys/src/cmd/*.c` at HEAD (a regular-expression pass, so approximate) finds 1233 non-static top-level functions across the single-file commands, of which 114 names are defined in more than one file: `main` in 136, `usage` in 75, `error` in 15, `emalloc` in 14, `erealloc` in 9. 9front's linkers reject a second definition of a function (`redefinition:` in `7l/obj.c`), merge uninitialised globals of the same name, and have no relocatable output (no `ld -r`), so renaming has to happen in the source, before compiling.
- **`#!` keeps the script's name.** 9front's `sysexec` (`port/sysproc.c`) follows up to 8 levels of interpreters and builds argv as the interpreters' arguments, outermost first, then the script's full path, with `argv[0]` replaced by the script's last path element, then the caller's arguments. h9's `interpret` in `src/machine.zig` builds the same argv. So a two-line stub can turn any file into a command of a multi-call binary, on h9 and on 9front alike.
- **A prototype.** On 2026-11-07 a prototype built 31 commands (`rc echo cat ls grep sed awk wc sort uniq tr test mkdir rm cp mv touch tee date sleep basename cmp xd du bind mount unmount ns ps pwd chmod`) from the pinned 11952 source into one binary inside h9, with the `-D` renaming done by passing the flags to `7c` (and to `mk` as `CC`) rather than through wrapper files. Measured on an x86_64 Linux host on the Unicorn emulator, as it has no hypervisor:

  | | 31 separate binaries | `9box` |
  | --- | --- | --- |
  | Size, as shipped (with symbols) | 2,347,308 bytes | 570,630 bytes (24%) |
  | Size, stripped | 1,503,160 bytes | 400,384 bytes (27%) |
  | Stripped, gzipped | 716,373 bytes (tar) | 177,686 bytes |
  | `h9 ls /`, mean of 50 | 13 ms | 12 ms |
  | `h9 rc -c 'ls /'`, mean of 50 | 58 ms | 51 ms |
  | 1600 execs in one rc loop (`echo`, `wc`, `ls`, `sed`), 3 runs | 15.4 to 17.1 s | 16.3 to 16.7 s |
  | Data and BSS per process (`size`) | 4 KB (`echo`) to 550 KB (`sed`) | 1.33 MB for every command |

  Hard links and `#!` stubs ran the same. A script with `#!/bin/rc`, where `/bin/rc` is a stub, ran with the right argv. The cost the size doesn't show is BSS: the commands' static buffers all land in one BSS, so every process gets 1.28 MB of it, led by `sed` (543 KB), `tr` (288 KB) and `awk` (108 KB). `ps` shows 2468K for a boxed `ps` against 348K for the stock one.
- **h9 reads the whole binary on each exec.** `readFile` in `src/machine.zig` stats the program and reads all of it; there's no text cache. A bigger binary costs more per exec, which matters most on [9P](0013-9p-roots.md) and [WebSocket](0021-websocket-9p.md) roots.

## Proposal

### The binary

`src/9box/` holds an h9-owned mkfile and generator, and no copy of 9front source:

```text
src/9box/
  9box.c      # the dispatcher
  cmds        # the command set: name, sources, libraries
  mkfile      # builds 9box for $objtype against /sys/src
  mkcmd       # rc: builds one command with its globals renamed
```

`cmds` lists one command per line: its name, its sources relative to `/sys/src/cmd`, and any libraries beyond libc. Single-file commands give one source; directory commands such as `rc`, `grep`, `awk` and `mk` give the files from their own mkfile's `OFILES`.

```text
# name   sources                                             libs
ls       ls.c
sed      sed.c                                               bio
grep     grep/main.c grep/comp.c grep/dfa.c grep/sub.c       bio
rc       rc/code.c rc/exec.c rc/getflags.c ... rc/plan9.c
```

For each command, `mkcmd` does three things:

1. Compiles its sources as they are, and runs `nm` over the objects to list the global symbols they define (`T`, `D` and `B`).
2. Makes a `-D` flag per symbol that isn't also defined by a library in the link (libc and libbio, not every library: libthread defines `main`), giving each a `CMD_` prefix: `-Dmain=ls_main`, `-Dusage=ls_usage`, `-Derrs=ls_errs`.
3. Compiles the sources again with those flags: `7c` for single files, and `mk 'CC=7c FLAGS'` on the objects for directory commands, so their yacc steps and `CFLAGS` still apply. Helper programs a mkfile builds for itself, like awk's `maketab`, are left out of the link.

A command that defines a symbol a library also defines (an override of a libc function, say) is reported and left out, since one link can only hold one. The set is checked for that at build time.

`9box.c` is a table of `{name, CMD_main}` generated from `cmds`, and a `main` that chooses the command:

- **By name.** The command is the last path element of `argv[0]`, and argv is passed on as it is. This is how hard links work.
- **By stub.** When `argv[1]` is `-!`, the command is the last path element of `argv[2]`, and `argv[1]` and `argv[2]` are removed. This is how stubs work (below).
- **As `9box CMD ARGS`.** When the name is `9box`, the first argument names the command.
- **Bare.** `9box` with no arguments lists its commands.

An unknown command prints `9box: no command NAME` and exits with that status. The chosen `CMD_main` then runs as the program; it ends with `exits` as it would on its own, and `argv0` is set by its own `ARGBEGIN`.

### Links and stubs

A command gets its name in one of two ways, chosen when the tree is assembled:

- **Hard links**, for host trees: `/$cputype/bin/ls` is a hard link to `/$cputype/bin/9box`. h9 serves a host tree as it is, and the guide's Go box already works this way.
- **Stubs**, for anything that has no hard links: 9P servers, disk images (with [image-roots](0014-image-roots.md)), a copy onto cwfs or hjfs. `/$cputype/bin/ls` is the file:

  ```text
  #!/bin/9box -!
  ```

  Running `/bin/ls -l` execs `9box` with argv `ls -! /bin/ls -l`, and `9box` runs `ls` with `ls -l`. The command is taken from the stub's path rather than `argv[0]` because `argv[0]` is the outermost script's name: a script `/bin/x` starting `#!/bin/rc`, where `/bin/rc` is itself a stub, gives `9box` the argv `x -! /bin/rc /bin/x ARGS`, and `9box` runs `rc` with `x /bin/x ARGS`, just as the real `rc` would get. That costs one level of the 8 that h9 and 9front allow.

A served root doesn't need either: a 9P server like the guide's `rootfs` can serve `9box`'s bytes under every name.

### The slim root

`zig build slim -Darch=arm64` (or `amd64`, `386`) builds `9box` by running the built h9 against the stock root, with `/sys/src` from a root made with `scripts/mkroot.py --src` or from the fetched checkout at `NINEFRONT_REV`, bound in with `--readable`. The output is written to a directory shared with `--writable`; the root stays read-only. It then assembles `.local/9front/slim-<release>-<arch>/`:

```text
<arch>/bin/9box
<arch>/bin/<cmd>          # hard links, or stubs with -Dslim-links=stub
rc/lib/rcmain
adm/timezone/local
dev env fd mnt/term/cwd net proc srv tmp
```

That's the tree the guide's section 4 describes, built rather than copied. The rc scripts in `/rc/bin` are left out by default; `cmds` can name ones to copy, such as `kill` and `lc`, along with what they run.

The default set covers the guide's slim list and what h9's own scripts in `#H` use: `rc echo cat ls grep sed awk wc sort uniq tr test mkdir rm cp mv touch tee date sleep basename cmp xd du bind mount unmount ns ps`. `mk` and the compilers are a second, larger set (`-Dslim-set=dev`) for building inside a slim root.

## Rationale

**9front's source, not a rewrite.** The point of a 9front userland is that it is 9front: flags, output and quirks match the stock tree and the manual. A Go userland like u-root, or a fresh one in Zig, would be a different userland, and Go has no `plan9/arm64` port. The guide already shows how to write your own; this proposal is for when you want 9front's, smaller.

**Rename in the preprocessor, not the linker.** 9front's linkers can't rename symbols or make relocatable objects, and changing them would mean a patched toolchain. A `-D` flag per symbol, generated from `nm`, needs neither, and leaves 9front's sources untouched so the set follows upstream when the pin moves. Renaming every defined global, not only the ones that collide today, means adding a command never breaks another.

**Not merging uninitialised globals.** The linkers would merge, say, every command's `Biobuf bout` into one, and since only one command runs per process, that would even work. But initialised data and functions still collide, and relying on the merge makes the result depend on which commands are in the set. Renaming everything is one rule.

**Stubs, not binds.** A namespace file could bind `9box` over each name, but a bind's target has to exist first, so the tree would need a placeholder per command anyway, and every machine would replay one bind per command at start. A stub is a file of 15 bytes that works on h9 and on 9front, needs no namespace file, and costs one interpreter level.

**`-!`, not `argv[0]`.** `argv[0]` is the outermost script's name when stubs nest, as with `rc`, so dispatching on it would run the script's name as a command. The stub's path is always `argv[2]`. `-!` is the marker because no command in the set takes it as a first argument, which the build checks.

**Not built into h9.** [guest-tools](0032-guest-tools.md) kept binaries out of `#H` so h9 wouldn't become a distributor of 9front programs built per architecture. The same holds here: `9box` is a build product in `.local/`, like the root tree, made by the user's own h9 from the pinned source. Shipping prebuilt slim roots is an open issue, not part of this proposal.

**Keep copying as the simple path.** The guide's section 4 stays: copying a handful of binaries needs no build at all. `9box` earns its place only if it's clearly smaller, and Done when measures that.

## Compatibility

- **CLI, exit codes, `Machine.Options`, sandbox defaults:** unchanged.
- **The root tree:** the stock root is unchanged. The slim tree is a new, separate directory under `.local/9front/`.
- **`third_party/`:** unchanged. 9front's source is used from the fetched checkout, not vendored.
- **Build:** new `zig build slim`, with `-Darch`, `-Dslim-links` and `-Dslim-set`. It needs a root and 9front source, as `zig build integration` needs a root.
- **Docs:** the guide's section 4 gains the built tree as an alternative to copying.

## Security

None. `9box` is ordinary 9front code running in the guest under the same policy as the binaries it's built from. The build runs inside h9 with the root read-only and only its output directory writable.

## Done when

- `zig build slim -Darch=arm64` builds the tree from a clean checkout and root, and the PR reports the slim tree's size against the guide's copied tree with the same commands.
- `h9 --root .local/9front/slim-11952-arm64 --check` passes, and `h9 --root ... --rc 'ls /bin | wc -l'` runs.

Integration cases tagged `[multicall]`, run against the slim tree:

- `test "9box runs a command through a hard link [multicall]"`
- `test "9box runs a command through a #! stub [multicall]"`
- `test "an rc script runs when /bin/rc is a stub [multicall]"`
- `test "9box CMD ARGS and an unknown command [multicall]"`
- `test "each boxed command matches its stock binary on the corpus [multicall]"`: every command in the set run over a small fixed corpus of inputs and flags, in the slim tree and the stock tree, with output and exit status compared.
- `test "a 9P root serving 9box under every name [multicall]"`

## Implementation

1. `src/9box/`: `9box.c`, `mkcmd` and the mkfile, with `cmds` holding a few single-file commands, to prove the renaming.
2. The rest of the default set, including the directory commands `rc`, `grep` and `awk`, and the build-time checks: library overrides and `-!` as a first argument.
3. `zig build slim`, with hard links and stubs.
4. The integration cases and the differential corpus.
5. docs/userland.md section 4 and the README's build commands. DESIGN.md: the slim tree under "Filesystem, boot and I/O". Set `status: implemented`.

## Open issues

- **BSS.** Every boxed process carries every command's static buffers (Background). Since h9 copies memory eagerly on `rfork`, and rc forks for each command, that's 1.28 MB more to allocate and copy per command when rc is boxed. Options: leave out or patch the few commands with big static arrays (`sed`, `tr`), have the dispatcher run large commands as separate binaries, or make h9 back BSS with zero pages on demand, which would help every program. The prototype's exec loop didn't show it as a clear slowdown on the emulator, but a hypervisor run with larger sets should check.
- **Is it worth it?** On the prototype's 31 commands the binary is a quarter of the size, and execs cost about the same on the emulator. A hypervisor host and a 9P root are still unmeasured.
- **Exec cost on remote roots.** h9 reads the whole program on every exec, so a script that runs `sed` in a loop reads all of `9box` each time. On a host tree that's a page-cache read, but over 9P or WebSocket it's a full transfer per exec. A text cache keyed by qid and version would make one binary cheaper than many instead of dearer; that's a proposal of its own, and this one should measure an exec-heavy loop on both kinds of root first. The browser host, which fetches binaries over the network, has the same trade-off.
- **libthread commands.** Programs with `threadmain` get their `main` from libthread, which conflicts with `9box`'s. They're left out of the first set; one way in is a `9box` that calls libthread's start-up with the command's renamed `threadmain`.
- **Graphical commands.** `rio`, `acme` and anything using libdraw are out of scope until [gfx](0015-gfx.md), and are large enough that they may be better as their own binaries.
- **Shipping prebuilt slim roots.** A release tarball per architecture would save users the build, at the cost of h9 distributing 9front binaries. 9front's MIT licence allows it; whether the project wants to is a separate decision.
- **amd64 and 386.** The pinned arm64 root has no `/amd64/lib`, so a cross build starts with `objtype=amd64 mk libs` on a writable copy of the root, as self-host describes.
