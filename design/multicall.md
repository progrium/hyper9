---
issue: 64
slug: multicall
title: A multi-call 9front userland binary
status: implemented
created: 2026-11-06
authors: [progrium]
depends: []
areas: [build, tests, docs]
branch: [main]
---

# Proposal: A multi-call 9front userland binary

Nov 8, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

h9 gains a build of 9front's own commands as one statically linked multi-call binary, `9box`, in the spirit of busybox. The commands are 9front's sources, unmodified, compiled inside h9 by 9front's compilers; generated `-D` flags per command rename its global symbols so they can share one link. `9box` picks the command from the name it runs as, through hard links in a host tree or two-line `#!` stubs anywhere else. A new build step assembles a slim root around it: the 42 commands needed for basic operation, one set and no menu. Each tree is `9box`, its links or stubs, `rcmain`, the mount points h9 binds onto, and nothing else. Nothing changes in h9 itself: no flags, no `Machine.Options`, no devices.

## Background

- **Slim roots are a recipe today.** [The userland guide](../docs/userland.md) section 4 builds a slim 9front by copying about 20 binaries and `/rc/lib/rcmain` out of the stock tree, which is about 250 MB. That works, but every binary is a separate static link, so each carries its own copy of libc and libbio, and the tree is as many files as commands.
- **9front builds itself in h9.** [self-host](self-host.md) measured `mk` in `/sys/src/cmd` rebuilding the shipped binaries byte for byte, and `cd /sys/src && mk install` in about a minute. So h9 can build a 9front program without a 9front machine, and this proposal relies on that.
- **Commands collide when linked together.** A scan of 9front's `sys/src/cmd/*.c` at HEAD (a regular-expression pass, so approximate) finds 1233 non-static top-level functions across the single-file commands, of which 114 names are defined in more than one file: `main` in 136, `usage` in 75, `error` in 15, `emalloc` in 14, `erealloc` in 9. 9front's linkers reject a second definition of a function (`redefinition:` in `7l/obj.c`), merge uninitialised globals of the same name, and have no relocatable output (no `ld -r`), so renaming has to happen in the source, before compiling.
- **`#!` keeps the script's name.** 9front's `sysexec` (`port/sysproc.c`) follows up to 8 levels of interpreters and builds argv as the interpreters' arguments, outermost first, then the script's full path, with `argv[0]` replaced by the script's last path element, then the caller's arguments. h9's `interpret` in `src/machine.zig` builds the same argv. So a two-line stub can turn any file into a command of a multi-call binary, on h9 and on 9front alike.
- **A prototype.** On 2026-11-07 a prototype built both sets from the pinned 11952 source inside h9, with `-D` flags passed to `7c`, and to `mk` as `CC` for directory commands. Measured on an x86_64 Linux host on the Unicorn emulator, as it has no hypervisor:

  | | `min`, 42 binaries | `min` `9box` | `slim`, 106 binaries | `slim` `9box` |
  | --- | --- | --- | --- | --- |
  | Size as shipped (with symbols) | 3.55 MB | 768 KB | 12.99 MB | 2.50 MB |
  | Size stripped | 2.28 MB | 535 KB | 8.89 MB | 1.91 MB |
  | Stripped, gzipped | 1.09 MB (tar) | 247 KB | 4.02 MB (tar) | 847 KB |
  | Data and BSS in every process | per command, 4 KB (`echo`) to 550 KB (`sed`) | 1.6 MB | per command | 4.4 MB |
  | `ps` size of a running `ps` | 348K | 2908K | 348K | 7764K |
  | 1600 execs in one rc loop (`echo`, `wc`, `ls`, `sed`), 2 runs | 13.8, 13.7 s | 15.0, 14.5 s (+7%) | 14.2, 14.3 s | 20.3, 20.5 s (+43%) |

  An earlier 31-command build measured single runs too: `h9 ls /` took 13 ms with separate binaries and 12 ms boxed, and `h9 rc -c 'ls /'` 58 ms and 51 ms. Hard links and `#!` stubs ran the same, a script starting `#!/bin/rc` ran right when `/bin/rc` was a stub, and a smoke script over the `slim` set (tar and gzip round trips, checksums, `ramfs`, `hoc`, `tcs`, `ed`, `file`, usage lines of `ssh`, and `tlsclient`) printed the same output from the box and from the separate binaries.

  The cost is BSS. Every command's static buffers land in one BSS, so every process gets all of them, led by `sed` (543 KB), `tr` (288 KB), `tcs` (377 KB, plus 489 KB of tables in data), `ftpfs` (174 KB) and `dossrv` (145 KB). `freq` alone has 8.9 MB, so it was left out of `slim`. h9 allocates and copies all of it on every `rfork` and exec, which is why the `slim` box runs the exec loop 43% slower. That makes BSS the main open issue (below).
- **What else the prototype found.**
  - A prefix has to make a valid identifier, and `9660srv_` doesn't, so it's `bx_9660srv_`.
  - A command that initialises a global a library also defines leaks the value into every other command: rc's `char *argv0 = "rc"` merged with libc's `argv0`, and since `ARGBEGIN` only sets `argv0` when it's nil, `ssh` printed `usage: rc ...`. The dispatcher now sets `argv0` to nil before running a command, and the build should report any other such symbol.
  - Programs with `threadmain` work through a private copy of libthread compiled with `-Dmain=_threadlibmain`. The dispatcher defines `threadmain` to call the chosen command's, and copies the command's `mainstacksize`, which is renamed like any other global, into libthread's before starting it. `ramfs`, `webfs`, `sshfs`, `mntgen`, `plumber`, and the rest of the thread programs in `slim` linked this way.
  - A directory command's objects come from its own mkfile: the prototype runs `mk`, reads the link line from `mk -n -a`, and rebuilds those objects with the flags. A local library named by `#pragma lib`, like `auth`'s `lib.7.a`, is linked once, unrenamed, since only the commands' own objects are renamed.
  - `sam` failed: a `-D` flag for its global `left` collided with a macro of the same name in another of its headers. `join`, `bzip2`, and `compress` are APE programs, linked against a different libc, and `bc`, `pc`, and `units` are single-file yacc programs the prototype didn't handle, so all of these are out of both sets for now.
- **h9 reads the whole binary on each exec.** `readFile` in `src/machine.zig` stats the program and reads all of it; there's no text cache. A bigger binary costs more per exec, which matters most on [9P](ninep-roots.md) and [WebSocket](websocket-9p.md) roots.

## Proposal

### The binary

`src/9box/` holds an h9-owned mkfile and generator, and no copy of 9front source:

```text
src/9box/
  9box.c      # the dispatcher
  slim        # the set: name and source directory per line
  mkfile      # builds 9box for $objtype against /sys/src
  mkcmd       # rc: builds one command with its globals renamed
```

The set file, `slim`, lists one command per line: its name, and the directory under `/sys/src/cmd` its mkfile is in, or `.` for a single-file command.

```text
ls       .
grep     grep
gunzip   gzip
telnet   ip
ftpfs    ip/ftpfs
```

For each command, `mkcmd` does three things:

1. Builds it as 9front does: `7c` for a single file, or `mk` on its target in a copy of its directory, and reads the objects off the link line from `mk -n -a`.
2. Runs `nm` over those objects for the globals they define (`T`, `D`, and `B`), and makes a `-D` flag for each that libc and libbio don't also define, with a `bx_CMD_` prefix: `-Dmain=bx_ls_main`, `-Dusage=bx_ls_usage`, `-Derrs=bx_ls_errs`.
3. Compiles the objects again with those flags: `7c` for single files, and `mk 'CC=7c FLAGS' OBJECTS` for directory commands, so their yacc steps and `CFLAGS` still apply. Helper programs a mkfile builds for itself, like awk's `maketab`, aren't on the link line and stay out.

A command that defines a symbol libc or libbio also defines (an override of a libc function, or an initialised `argv0`) is reported, since one link can hold only one; the set is checked for that at build time. A `-D` flag that collides with a macro, as in `sam`, fails the command's compile and is reported the same way.

Thread programs, whose `main` is libthread's, are refused: the set has none, and boxing one needs a private libthread with its `main` renamed (Open issues).

`9box.c` is a table generated from the set, `{name, main}`, and a `main` that chooses the command:

- **By name.** The command is the last path element of `argv[0]`, and argv is passed on as it is. This is how hard links work.
- **By stub.** When `argv[1]` is `-!`, the command is the last path element of `argv[2]`, and `argv[1]` and `argv[2]` are removed. This is how stubs work (below).
- **By interpreter.** When the name isn't a command, and an argument is a file whose `#!` line names a command as its interpreter, with the line's other fields in the arguments before it, that command runs with argv as it is. exec of a `#!/bin/rc` script, when `/bin/rc` is a hard link to `9box`, starts `9box` with the script's name in `argv[0]` and its path after the line's arguments, as 9front's kernel does for any interpreter.
- **As `9box CMD ARGS`.** When the name is `9box`, the first argument names the command.
- **Bare.** `9box` with no arguments lists its commands.

An unknown command prints `9box: no command NAME` and exits with that status. Before running the command, `9box` sets `argv0` to nil, so the command's own `ARGBEGIN` sets it. The command's `main` then runs as the program, and ends with `exits` as it would on its own.

### Links and stubs

A command gets its name in one of two ways, chosen when the tree is assembled:

- **Hard links**, for host trees: `/$cputype/bin/ls` is a hard link to `/$cputype/bin/9box`. h9 serves a host tree as it is, and the guide's Go box already works this way.
- **Stubs**, for anything that has no hard links: 9P servers, disk images (with [image-roots](image-roots.md)), a copy onto cwfs or hjfs. `/$cputype/bin/ls` is the file:

  ```text
  #!/bin/9box -!
  ```

  Running `/bin/ls -l` execs `9box` with argv `ls -! /bin/ls -l`, and `9box` runs `ls` with `ls -l`. The command is taken from the stub's path rather than `argv[0]` because `argv[0]` is the outermost script's name: a script `/bin/x` starting `#!/bin/rc`, where `/bin/rc` is itself a stub, gives `9box` the argv `x -! /bin/rc /bin/x ARGS`, and `9box` runs `rc` with `x /bin/x ARGS`, just as the real `rc` would get. That costs one level of the 8 that h9 and 9front allow.

A served root doesn't need either: a 9P server like the guide's `rootfs` can serve `9box`'s bytes under every name.

### The trees

`zig build slim -Darch=arm64` (or `amd64`, `386`) builds `9box` by running the built h9 against the stock root, with `/sys/src` from a root made with `scripts/mkroot.py --src` or from the fetched checkout at `NINEFRONT_REV`, bound in with `--readable`. The output is written to a directory shared with `--writable`; the root stays read-only. It then assembles `.local/9front/slim-<release>-<arch>/`:

```text
<arch>/bin/9box
<arch>/bin/<cmd>          # hard links, or stubs with -Dslim-links=stub
rc/lib/rcmain
adm/timezone/local
dev env fd mnt/term/cwd net proc srv tmp
```

That's the tree the guide's section 4 describes, built rather than copied. The rc scripts in `/rc/bin` are left out.

### The set

**`slim`**, the commands basic operation needs: a shell, the file and text commands scripts lean on, the common archive formats, and the namespace, process, and file-serving commands that make it 9front. That's what h9's own scripts in `#H` use, too. 43 commands:

- Shell and files: `rc`, `echo`, `cat`, `ls`, `cp`, `mv`, `rm`, `mkdir`, `pwd`, `test`, `date`, `sleep`, `touch`, `chmod`, `du`, `basename`, `read`.
- Text: `wc`, `sort`, `uniq`, `tr`, `sed`, `awk`, `grep`, `cmp`, `diff`, `tail`, `tee`, `xargs`, `mc`.
- Archives: `tar`, `gzip`, `gunzip`, `unzip`.
- Namespace, processes, and serving: `bind`, `mount`, `unmount`, `ns`, `ps`, `srv`, `srvfs`, `exportfs`, `ramfs`.

Anything else stays a separate binary, copied from the stock root as the guide's section 4 does.

## Rationale

**9front's source, not a rewrite.** The point of a 9front userland is that it is 9front: flags, output, and quirks match the stock tree and the manual. A Go userland like u-root, or a fresh one in Zig, would be a different userland, and Go has no `plan9/arm64` port. The guide already shows how to write your own; this proposal is for when you want 9front's, smaller.

**Rename in the preprocessor, not the linker.** 9front's linkers can't rename symbols or make relocatable objects, and changing them would mean a patched toolchain. A `-D` flag per symbol, generated from `nm`, needs neither, and leaves 9front's sources untouched so the set follows upstream when the pin moves. Renaming every defined global, not only the ones that collide today, means adding a command never breaks another.

**Not merging uninitialised globals.** The linkers would merge, say, every command's `Biobuf bout` into one, and since only one command runs per process, that would even work. But initialised data and functions still collide, and relying on the merge makes the result depend on which commands are in the set. Renaming everything is one rule.

**Stubs, not binds.** A namespace file could bind `9box` over each name, but a bind's target has to exist first, so the tree would need a placeholder per command anyway, and every machine would replay one bind per command at start. A stub is a file of 15 bytes that works on h9 and on 9front, needs no namespace file, and costs one interpreter level.

**`-!`, not `argv[0]`.** `argv[0]` is the outermost script's name when stubs nest, as with `rc`, so dispatching on it would run the script's name as a command. The stub's path is always `argv[2]`. `-!` is the marker because no command in the set takes it as a first argument, which the build checks.

**Not built into h9.** [guest-tools](guest-tools.md) kept binaries out of `#H` so h9 wouldn't become a distributor of 9front programs built per architecture. The same holds here: `9box` is a build product in `.local/`, like the root tree, made by the user's own h9 from the pinned source. Shipping prebuilt slim roots is an open issue, not part of this proposal.

**Keep copying as the simple path.** The guide's section 4 stays: copying a handful of binaries needs no build at all. `9box` earns its place only if it's clearly smaller without being slower, and Done when measures both.

**One set, not several or a menu.** The basic set is what most uses of a slim root need, and is the size of the guide's copied list. A larger set ran the exec loop 43% slower (Background), and more sets or a menu of per-command options would make every tree different, and harder to test. A command the set lacks can be copied in beside the box.

## Compatibility

- **CLI, exit codes, `Machine.Options`, sandbox defaults:** unchanged.
- **The root tree:** the stock root is unchanged. The slim tree is a new, separate directory under `.local/9front/`.
- **`third_party/`:** unchanged. 9front's source is used from the fetched checkout, not vendored.
- **Build:** new `zig build slim`, with `-Darch` and `-Dslim-links`. It needs a root and 9front source, as `zig build integration` needs a root.
- **Docs:** the guide's section 4 gains the built tree as an alternative to copying.

## Security

None. `9box` is ordinary 9front code running in the guest under the same policy as the binaries it's built from. The build runs inside h9 with the root read-only and only its output directory writable.

## Done criteria

- [x] `zig build slim` builds the tree from a clean checkout and root, and the PR reports its size against the same commands copied.
- [x] The prototype's exec loop runs within 10% of the separate binaries' time, on a hypervisor host.
- [x] `h9 --root .local/9front/slim-11952-arm64 --check` passes, and `h9 --root ... --rc 'ls /bin | wc -l'` runs.

Integration cases tagged `[multicall]`, run against the slim tree:

- [x] `test "9box runs a command through a hard link [multicall]"`
- [x] `test "9box runs a command through a #! stub [multicall]"`
- [x] `test "an rc script runs when /bin/rc is a stub [multicall]"`
- [x] `test "9box CMD ARGS and an unknown command [multicall]"`
- [x] `test "ramfs runs from the box [multicall]"`
- [x] `test "argv0 is the command's own name [multicall]"`
- [x] `test "each boxed command matches its stock binary on the corpus [multicall]"`: every command in the set run over a small fixed corpus of inputs and flags, in the slim tree and the stock tree, with output and exit status compared.
- [x] `test "a 9P root serving 9box under every name [multicall]"`

## Implementation

1. `src/9box/`: `9box.c`, `mkcmd`, and the mkfile, with a set of a few single-file commands, to prove the renaming.
2. The set, including the directory commands `rc`, `grep`, `awk`, `diff`, `gzip`, and `exportfs`, and the build-time checks: library overrides, initialised library globals, thread programs, and `-!` as a first argument.
3. `zig build slim`, with hard links and stubs.
4. The integration cases and the differential corpus.
5. docs/userland.md section 4 and the README's build commands. SPEC.md: the slim tree under "Filesystem, boot, and I/O". Set `status: implemented`.

## Open issues

- **Exec cost.** Every boxed process carries the whole box: 1.6 MB of data and BSS for the set (Background), and its text. h9 allocates and copies it on every exec and `rfork`, and rc forks for each command it runs, so the box ran the exec loop 7% slower in the prototype (Updates has where the cost really is). Growing the set makes it worse, which is why there's one small set.
- **Is it worth it?** By size, clearly: under a quarter of the bytes. By speed, close to the 10% line on the emulator; a hypervisor host and a 9P root are still unmeasured.
- **Larger sets.** A set with archives, file servers, and network clients (106 commands in the prototype) ran the exec loop 43% slower, and would need thread programs (a private libthread with its `main` renamed `_threadlibmain`, and the command's `mainstacksize` copied in), `sam`'s macro clash, and APE programs (`join`, `bzip2`, `compress`) solved. That waits on the exec cost.
- **Exec cost on remote roots.** h9 reads the whole program on every exec, so a script that runs `sed` in a loop reads all of `9box` each time. On a host tree that's a page-cache read, but over 9P or WebSocket it's a full transfer per exec. A text cache keyed by qid and version would make one binary cheaper than many instead of dearer; that's a proposal of its own, and this one should measure an exec-heavy loop on both kinds of root first. The browser host, which fetches binaries over the network, has the same trade-off.
- **Graphical commands.** `rio`, `acme`, and anything using libdraw are out of scope until [gfx](gfx.md), and are large enough that they may be better as their own binaries.
- **Shipping prebuilt slim roots.** A release tarball per architecture would save users the build, at the cost of h9 distributing 9front binaries. 9front's MIT licence allows it; whether the project wants to is a separate decision.
- **amd64 and 386.** The pinned arm64 root has no `/amd64/lib`, so a cross build starts with `objtype=amd64 mk libs` on a writable copy of the root, as self-host describes.

## Updates

- 2026-11-07: Filed as #64 and marked implemented. The Done-when checks that need a hypervisor host (the exec loop within 10% of separate binaries, and `--check` on the arm64 tree) are still to be run on one. The dependency on [self-host](self-host.md), still `accepted`, is dropped: what this needs from it, `mk` building 9front's commands inside h9, works today, and the build here does it.
- 2026-11-07: One set. The proposal had `min`, `slim`, and `dev`; `slim` ran the exec loop 44% slower than separate binaries, so there's only the basic set, now named `slim`, and no `-Dslim-set`. The private libthread went with it, since the set has no thread program, and `mkcmd` refuses one. The notes below about `plumber`, `ed`, `dossrv`, `passwd`, `bc`, and the larger set's numbers are from building the larger set before it was dropped.
- 2026-11-07: Implemented as proposed (`src/9box/`, `tools/slim.zig`, `zig build slim`), except the `dev` set, with these refinements:
  - **Stubs are checked.** `9box` takes `-!` as a stub's marker only when `argv[2]` is a file whose first line is `#!…/9box -!`, so a command run by name with a first argument of `-!` (`echo -! x`) gets it as its own. The build still refuses a command whose `ARGBEGIN` takes `-!`.
  - **Layers, not copies.** `mkcmd` builds each command in place under `/sys/src/cmd`, behind a `bind -bc` of a fresh directory over the command's directory and each one under it, so `../` paths and a mkfile's `cd lib; mk` work and `/sys/src` is never written. The layers are siblings, since one holding another hides the source directory of the same name. Single-file commands build through `/sys/src/cmd/mkfile` too, which runs yacc, so `bc` and `pc` built in the larger set (108 commands); `units` builds but reads `/lib/units`, which the tree doesn't have.
  - **Library overrides.** `ed` defines libc's `mktemp` and `dossrv` its `cistrcmp`. In a separate binary the command's own wins; linked together, it would have replaced libc's for every command (`diff` calls `mktemp`). Such an override is renamed with the rest, so the command calls its own and the others libc's, which is what each binary does on its own as long as the library's own code doesn't call it. The build fails a command whose override libc or libbio calls, or that initialises a library global other than `argv0`.
  - **ramfs isn't a thread program** at 11952, so the basic set has none; `plumber` and `sshfs` in the larger set ran through the private libthread.
  - **Hard links share a qid.** A bind over one command in a hard-link tree covers every command, `9box` included, as the mount table matches by qid. The stub case binds a `/bin` of its own, and the guide says to build with `-Dslim-links=stub` to bind over single commands.
  - **One recipe at a time.** The tool runs `mk` without `NPROC`: on the emulator, which runs one process's guest code at a time, four compilers taking turns built about five times slower than one after another.
  - **The corpus runs in a ramfs**, since 9front's `diff` takes only files from a mount (`Dir.type == 'M'`) as regular and copies the rest to `/tmp`, and fails on h9's `#U` and `#O` files. That's an h9 compatibility bug of its own.
  - **`fcp` has no corpus entry**: its eight `RFMEM` workers hang h9 now and then, the stock binary too (2 runs in 10 copying `/lib/namespace` on the emulator). Another h9 bug of its own.
  - **`dev` is left out.** The compilers link `../cc/cc.a$O`, whose code calls back into each compiler's own functions, so a command's local libraries would have to be renamed with it (a compiler wrapper bound over `$CC` while they're rebuilt, say) rather than linked once as they are. That's follow-up work.
  - **Measured on the emulator** (x86\_64 Linux, Unicorn, release build of h9), the prototype's exec loop takes 18.4 and 18.1 s with separate binaries against 20.3 and 19.8 s from the basic box (+9.5%), and 18.4 and 17.7 s against 26.2 and 25.7 s for the larger set (+44%). BSS isn't what costs: a program with 4 MB of BSS runs 800 times in 4.42 s against 4.17 s for an empty one, while one with 4 MB of initialised data takes 8.32 s. `/bin/echo` from the larger box runs 800 times 5.6 s slower than the stock `echo`, and stripping the box's symbols (2.5 to 1.9 MB) saves only 0.4 s of that; a bare fork is 1.2 ms slower in a boxed rc. So the cost is allocating and copying 1.9 MB of text and data on every exec (on the emulator, mapping it in Unicorn too), and copying the data and BSS on every fork, not the zero pages themselves. The fix that helps every program is an exec image cache, the text shared between processes and the file read once (Open issues: exec cost on remote roots); whether the basic set needs it waits on the hypervisor measurement.
- 2026-11-13: `lc` works in the slim tree and the built-in root. Any `#!/bin/rc` script failed with `9box: no command NAME` over a hard-link tree, h9's own `#H` scripts included, since exec puts the script's name in `argv[0]`; `9box` now falls back to the interpreter the script's `#!` line names. The set gains `mc`, and the tree `/rc/bin/lc` (`ls -pF $* | mc`) from the stock root. `mc` links the parts of libdraw it uses to find a window's width (it falls back to 80 columns with no `/dev/window` or `$font`), which adds 53 KB to the amd64 box (736 to 789 KB).
