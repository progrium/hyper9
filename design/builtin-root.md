---
issue: 87
slug: builtin-root
title: A built-in root
status: implemented
created: 2026-11-06
authors: [progrium]
depends: [multicall]
areas: [kern, cli, build, sandbox]
branch: [main]
---

# Proposal: A built-in root

Nov 8, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

h9 builds a small read-only root into its binary: [multicall](multicall.md)'s tree, which is one `9box` binary per architecture serving 42 of 9front's commands, plus `rcmain`, the timezone file, and the directories h9's namespace binds onto. `#H`, the device that serves [guest-tools](guest-tools.md)' commands, serves it under the attach spec `root`. When h9 finds no root tree, it uses this built-in root instead of exiting 125. With a root, `--builtin=before` puts the box's commands in `/bin` ahead of the root's, so a 9P root supplies everything else, and `--builtin=only` uses the built-in root alone. Everything else in the namespace (devices, the cwd, `/mnt/term`, the private `/tmp`, the policy) is built over it as over any other root. So `h9 --rc 'echo hi'` and `h9 ./prog` work on a fresh install with nothing but the h9 binary, which grows by about half a megabyte per architecture. A full 9front tree becomes what you add for compilers, sources, and graphics, not what you need to start.

## Background

- **h9 needs a tree to do almost anything.** Getting one means `scripts/fetch.sh` and `zig build mkroot`, which boots the release image in QEMU and unpacks about 250 MB into `.local/9front/root`. An installed `h9` then needs `H9ROOT` set. Without a root, `h9 ./prog` runs, but the program sees only the kernel's devices: no `/bin`, no cwd, no `/tmp` (MANUAL chapter 2). Anything else is exit 125, `no root tree found`.
- **The CLI enforces it up front.** `src/main.zig` refuses a guest program name or `--ns` without a root, since lookup would fail later as a misleading "not found". `src/policy.zig` skips the `/bin` binds, the cwd bind, and `/mnt/term` when there's no root, because their targets don't exist on bare devroot.
- **A root is only a file tree to h9.** Nothing boots. h9 builds the namespace itself and reads one file, `/adm/timezone/local`, if it's there. The [userland guide](../docs/userland.md) shows a working root made of nine empty directories and one Go binary.
- **multicall makes a small 9front tree.** [multicall](multicall.md) compiles 9front's own commands, unmodified, into one statically linked `9box` inside h9, and `zig build slim` assembles a tree around it: `9box`, a name per command, `rcmain`, `adm/timezone/local`, and the mount points. Its set is 42 commands (a shell, file and text tools, `tar` and `gzip`, and `bind`, `mount`, `ns`, `ps`, `srv`, `exportfs`, `ramfs`), and its prototype's arm64 `9box` was 535 KB stripped, against 2.28 MB for the same commands as separate binaries. multicall leaves shipping prebuilt trees open, as a separate decision about h9 distributing 9front binaries.
- **`#H` already serves an embedded tree.** [guest-tools](guest-tools.md) generates a table from `src/guest/` at configure time (`tools/guesttree.zig`) and serves it read-only from constant memory through `src/kern/devhtools.c`. It allows only rc scripts, so its commands run only when the root has `rc`. It declined binaries because they're per architecture and "would make h9 a distributor of 9front programs", and said a proposal that needs them can propose that. This is that proposal, and the decision multicall left open.
- **An overlay with no lower tree already exists.** [ephemeral-writes](ephemeral-writes.md) keeps a `#O` instance with no lower tree available "for runs without a root tree", and a 9P root's `/tmp` is a bare `#O` today.
- **Other work wants the 9front tree to be optional.** The linux-personality spike found nothing in the personality reads the 9front tree, and suggested `/9` exist only when one is found; mixed pipelines and execing `rc` are what need it. The browser host has no host file system to hold a tree at all.

## Proposal

### The built-in root

The built-in root is a second table in `#H`, attached as `#Hroot`. `#H` with no spec stays guest-tools' tree. Both tables are served by the same code with the same rules: read-only, owned by the machine's user, qids fixed at build time. Where guest-tools' table has files 0444 and executables and directories 0555, the built-in root has a 9front tree's 0664 and 0775: an overlay over it, the root's or `/tmp`'s, takes its permissions from the tree below, so with 0555 directories nothing could be made in them. The device refuses every write either way.

Its contents are multicall's tree for each architecture the build embeds, as `zig build slim` assembles it:

```text
/
  $arch/bin/9box                    # one per embedded architecture
  $arch/bin/rc, ls, cat, ...        # the 42 commands of multicall's set
  rc/lib/rcmain
  adm/timezone/local
  bin dev env fd mnt/term/cwd net proc srv tmp usr   # empty mount points
```

Each command name is its own table entry with its own qid, but the entries share `9box`'s bytes, so a name costs a few bytes of table rather than a copy. That's the table's equivalent of multicall's hard links: `9box` sees the name it was run as in `argv[0]` and needs neither links nor `#!` stubs. Where the tree's directory list and h9's skeleton differ, the build adds what h9 binds onto (`usr`, so `home` has a parent).

Compilers, `mk`, `rio`, fonts, `/sys/src`, `/sys/man`, and `/lib/ndb` stay in the full tree. Proposals still add h9's own commands as rc scripts in `src/guest/`, not as binaries here.

### Where the binaries come from

From multicall's build, run against the pinned 9front release: `zig build slim -Darch=A` for each architecture, which compiles the release's own source inside h9. h9 doesn't patch or rewrite any of it; this proposal only decides to ship the result.

The h9 build reads the trees with `-Dbuiltin-root=DIR`, which defaults to `.local/9front/` and picks up each `slim-<release>-<arch>` it finds there. A build embeds the architectures it can run: the target's own for `h9`, and also `amd64` and `386` for `h9-emu`, each when its tree exists. The release recorded in the tree must be the pinned `NINEFRONT_RELEASE`, or the build fails, so a stale tree is never embedded. An architecture whose tree is missing is left out, so a machine of that architecture gets the skeleton only, and `zig build` prints a warning naming it and the `zig build slim` command that makes it. A release build (`-Drelease`) fails instead, so a release never ships a root with no commands.

`tools/guesttree.zig` grows the second table, and shares contents between entries with the same bytes. Contents are embedded with `@embedFile` from the build directory, not as generated source.

### Choosing it

The root lookup gains a last step:

1. `--root`.
2. `H9ROOT`.
3. `.local/9front/root`, for a development build.
4. The built-in root.

With a root, the built-in tree can also be layered into it. One flag says how:

| `--builtin MODE` | Meaning |
| --- | --- |
| `auto` (default) | `only` when no 9front root is found, `off` otherwise |
| `only` | The built-in root is `/`, even if `H9ROOT` or the development tree would give one. With `--root`, exit 2 |
| `before` | The root is `/`. The built-in `/$cputype/bin` is bound before the root's `/bin`, so the box's 42 commands win and the root supplies the rest |
| `after` | The same, bound after the root's `/bin` and `/rc/bin`, so it only fills gaps, such as a slim root with no `ls` |
| `off` | Never: no root is still exit 125 for a guest program, as today |

`before` and `after` bind only `/bin`. The root keeps its own `/rc/lib/rcmain` and everything else, so the box's `rc` reads the root's `rcmain` as the root's `rc` would.

`Machine.Options` gains `builtin: Builtin = .off` with the same values, and `root` gains nothing. `.off` keeps today's bare namespace for embedders, so a program embedding h9 changes only if it asks.

### The namespace

Over the built-in root, the plan is the usual one with one change, the root bind:

```text
  bind '#Hroot' /                                         builtin  # h9 v0.2.0, 9front 11952 slim
  bind '#c' /dev
  ...
  bind /arm64/bin /bin
  bind -a /rc/bin /bin
  bind -a '#H/bin' /bin                                   # h9's commands
  bind -c '#O' /tmp                                       eph
  bind '#U/Users/me/work' /mnt/term/cwd                   rw
```

- **`builtin`** is a new access column value, like `9p`: the root has no host path, so it has no access rule, and it's read-only whatever the flags. `--writable` can't name it.
- **`/rc/bin`** doesn't exist in multicall's tree, so its bind is skipped as it already is when a root lacks it.
- **`/tmp`** is a bare `#O`, as over a 9P root, since the root's own `/tmp` is empty and read-only. `--write=none` leaves it read-only.
- **The cwd, `--readable`, `--writable`, and `/mnt/term`** are bound as over a host root. `has_root` in `src/policy.zig` becomes true for the built-in root, which is all the plan needs.
- **`--write=overlay`**, once [overlay](overlay.md) is built, covers the built-in root like any other, so `mkdir /usr/me` works for the run.
- **`--ns`** replays `#Hroot` as an ordinary bind, so a plan printed over the built-in root replays on any h9 of the same version. The same bind in a namespace file layers the box by hand without the flag: `bind -b '#Hroot/arm64/bin' /bin`.

Over a 9P root with `--builtin=before`, the root is unchanged and `/bin` gains one bind ahead of the root's:

```text
  mount '#s/root' / ''                                    9p  # tcp!fs.example.com!564
  ...
  bind '#Hroot/arm64/bin' /bin                            builtin
  bind -a /arm64/bin /bin
  bind -a /rc/bin /bin
  bind -a '#H/bin' /bin                                   # h9's commands
```

`ls`, `grep`, and `rc` then come from h9's memory, and `mk` or `acme` from the server.

### What h9 reports

- `h9 --check` prints `root: built-in (9front 11952 slim, arm64; no tree found)`, runs `/bin/echo` from it, and exits 0.
- `h9 --version` adds `built-in root: 9front 11952 slim, arm64 amd64 386 (42 commands)`, or `skeleton only` for a build without binaries.
- `h9 --print` shows the root bind as above.
- A command that isn't in the built-in root fails as any missing command does (exit 127). Its message adds `(not in the built-in root; pass --root or set H9ROOT for the full 9front tree)` when the built-in root is in use, so the fix is one line away.

### With other roots

- **A Linux root** under [linux-personality](linux-personality.md): when no 9front tree is found, `/9` is the built-in root, so a Linux process can exec `/9/bin/rc` and pipe through 9front's `grep` without the full tree. A Linux root doesn't count as a root for `auto`, and `--builtin=off` leaves `/9` out.
- **The browser host** has no host tree to find, so it uses the built-in root's `386` tree when no 9P or WebSocket root is given (see Open issues for size).
- **A 9P, WebSocket, or image root** is unchanged.

## Rationale

**Built into the binary, not a downloaded tree.** A tree beside the binary, or a cache h9 fills on first run, would have to be found, kept in step with the binary, and allowed through the sandbox, which guest-tools already weighed for its scripts. A download also needs the network on first run. Embedding keeps h9 one file and makes the first run work offline.

**multicall's box, not separate binaries.** The first draft of this proposal embedded about 30 separate binaries, estimated at 2 to 3 MB per architecture. The box is 42 commands in 535 KB stripped, measured, so the built-in root covers more (`tar`, `gzip`, `awk`, `diff`, `exportfs`, `ramfs`) for a quarter of the bytes. It's also exactly the tree multicall already tests, so the built-in root adds no second set to keep working. The cost is multicall's BSS: about 1.6 MB of static buffers in every process, and execs about 7% slower in its prototype (Open issues).

**42 commands, not the prototype's 106.** multicall's prototype also measured a 106-command set, whose box is 1.91 MB stripped and 4.4 MB of BSS per process, and runs execs 43% slower until h9 backs BSS on demand. The built-in root is for starting, and the 42 are multicall's own answer to "what's needed for basic operation", the one set it ships. A fuller tree is a `--root` away.

**Exec cost is lowest here.** h9 reads the whole program on each exec, which multicall flags as the cost of one big binary on 9P and WebSocket roots. `#H` serves constant memory in the h9 process, so that read is a copy with no I/O, cheaper than from a host tree.

**In `#H`, not a new device.** It's the same kind of thing: a constant read-only tree generated at build time. One device keeps one generator, one table format, and one C file. `--no-guest-tools` still masks `#H` after the namespace is built, which leaves the root bind working, as with every masked device.

**Shipping 9front's binaries after all.** guest-tools declined it, and multicall left it open, to keep h9 from becoming a distribution. Running without a tree isn't possible otherwise: an rc reimplementation would be a second shell to maintain, and an rc-less root runs nothing by name. What ships is built from the pinned release's source, unmodified apart from multicall's symbol renaming, under 9front's MIT licence, whose notice goes in each release archive beside h9's. The set is multicall's, fixed and tested, so h9 ships a starter kit, not a userland.

**Automatic, not only behind a flag.** The point is that a fresh install works. Exit 125 for a missing tree is a dead end the user has to read the manual to get past, and nothing depends on it: the integration suite checks for the tree itself and skips, rather than relying on h9's exit. `--builtin=only` covers the opposite case, testing the built-in root on a machine that has a tree, and `off` gets the old behaviour back.

**A layer, not only a replacement.** An earlier draft had `--rootless`, which chose the built-in root instead of any other. But the built-in commands are useful with a root too. Over a 9P or WebSocket root, every exec reads the whole binary over the connection (multicall's exec-cost issue), and `before` turns the common ones into reads from h9's memory while the server still supplies compilers, sources, and everything else. Over a slim or custom root, `after` fills the gaps. One flag with a mode covers both and the no-root case, where a separate `--rootless` would have been a third concept.

**`/bin` only, not a union at `/`.** Binding the whole built-in tree before or after the root at `/` would union every directory, and its empty mount points and `rcmain` would shadow or mix with the root's. The commands are the only part worth layering, and `/bin` is already a union.

**`before` isn't the default with a root.** The root's own commands are what the user chose, and a root built from another 9front release, or a custom userland, may depend on its own versions. Shadowing them silently would be a surprise.

**`--builtin`, not `--root builtin`.** `--root` takes paths, dial strings, and URLs, so any word could be a directory. A separate flag can't be confused with one.

**Embedders default to `.off`.** An embedder that passes no root today gets the bare namespace and may depend on it, such as a host a.out that wants no files at all.

## Compatibility

- **CLI:** new `--builtin`. With no root found, a guest program or `--ns` runs over the built-in root instead of exiting 125 with `no root tree found`, and `h9 ./prog` gets the full namespace instead of the bare one; `--builtin=off` restores both. `--check` exits 0 with only the built-in root. `--builtin=only` with `--root` is exit 2. With a root, nothing changes unless `before` or `after` is given.
- **`Machine.Options`:** new `builtin`, `.off` by default, so embedders see no change.
- **`--print` and `--ns`:** the `builtin` access value and the `#Hroot` bind.
- **The binary:** grows by about 0.6 MB for `h9` (one `9box`, `rcmain`, the timezone file, and the table) and three times that for `h9-emu`, before any compression.
- **Building h9:** a release build needs multicall's trees first. A development build without them still builds, with the skeleton only.
- **Release archives:** gain 9front's licence notice.
- **The root tree and `third_party/`:** unchanged.

## Security

The built-in root is constant, read-only data in the h9 binary, the same as `#H`'s scripts, so it gives the guest nothing on the host. The commands run under the same policy, device mask, and sandbox as the same commands from a tree.

One change is visible: `h9 ./prog` with no root used to see no host files, because there was nowhere to bind them, and now sees its cwd and the paths the policy allows, as it would with a root. That's the policy working as documented rather than a gap closing by accident, but a script that relied on rootless runs being blind should pass `--sandbox` or `--write=none`. Embedders see no change unless they set `builtin`. `before` lets the box's commands shadow a root's, but only commands the guest could run anyway, and `--print` shows the bind.

## Done criteria

`env -u H9ROOT h9 --builtin=only --rc 'ls /bin | wc -l; echo $cputype; pwd'` on a host with no tree prints the command count, the architecture, and `/mnt/term/cwd`.

Integration cases tagged `[builtin-root]`. Those that need commands skip in a skeleton-only build, as guest-tools' cases do with `H9_TEST_GUEST_TOOLS`:

- [x] `test "with no root found, --rc runs from the built-in root [builtin-root]"`
- [x] `test "--builtin=only ignores H9ROOT [builtin-root]"`
- [x] `test "--builtin=only with --root is a usage error [builtin-root]"`
- [x] `test "--builtin=off without a root is exit 125 as before [builtin-root]"`
- [x] `test "--builtin=before runs the box's ls and the root's other commands [builtin-root]"`
- [x] `test "--builtin=after leaves the root's ls and fills a missing command [builtin-root]"`
- [x] `test "--builtin=before over a 9P root execs boxed commands without reading the server [builtin-root]"`
- [x] `test "a host a.out without a root sees /dev, /env, /proc, /tmp and its cwd [builtin-root]"`
- [x] `test "the built-in root refuses writes and /tmp is writable in memory [builtin-root]"`
- [x] `test "--print shows the #Hroot bind as builtin [builtin-root]"`
- [x] `test "--ns replays a plan printed over the built-in root [builtin-root]"`
- [x] `test "--check passes with only the built-in root [builtin-root]"`
- [x] `test "a missing command names the built-in root in its error [builtin-root]"`
- [x] `test "guest-tools' wsmount runs over the built-in root [builtin-root]"`
- [x] `test "the built-in root's commands match the slim tree's [builtin-root, multicall]"`: multicall's differential corpus run over `#Hroot`, so the embedded box and the built tree can't drift.

The content sharing, the release check, and the build failure on a stale tree are `zig build test` cases in `tools/guesttree.zig`. A `tests/backends.zig` case attaches `#Hroot` on the emulator with a test table and runs a command from it.

## Implementation

1. The skeleton: the second table in `tools/guesttree.zig`, the `root` spec in `devhtools.c`, `builtin` in `Machine.Options`, the plan changes in `src/policy.zig` for all four modes, the lookup step, and `--builtin` in `src/main.zig` and `src/cli.zig`. On its own this gives `h9 ./prog` the full namespace without a tree, and needs nothing from multicall.
2. Embedding multicall's trees: `-Dbuiltin-root`, content sharing, the release and staleness checks, and the binary's measured growth recorded under Updates. This step waits for multicall.
3. Reporting: `--check`, `--version`, and the missing-command hint.
4. Release: run `zig build slim` for each architecture before building `h9` and `h9-emu`, and add 9front's notice to the archives.
5. Docs: MANUAL chapter 2 (getting started no longer needs a tree first), the userland guide's sections 1 and 4, README. SPEC.md: the root lookup, `#H`'s second table, the namespace listing, the flag, and `Machine.Options`. Set `status: implemented`.

## Open issues

- **BSS.** Every process from the built-in root carries the box's 1.6 MB of static buffers, which counts against `--memory` and is copied on each `rfork` and exec. multicall's own options apply, best first making h9 back BSS on demand. Until then, a machine with a small `--memory` runs fewer processes from the built-in root than from the full tree.
- **Compressing the table.** The box gzips from 535 KB to 247 KB. Decompressing into the machine's pages on first open would halve the binary's growth but give up `#H`'s constant-memory reads. At these sizes it's probably not worth it.
- **The browser host's download.** Only `386` applies there, but every byte is downloaded per page load. It may want the table fetched separately and cached.
- **Before multicall lands.** Step 1 is useful on its own. If multicall stalls, step 2 could embed the same 42 commands as separate binaries copied from the stock tree, at about four times the size, and switch to the box later without changing anything else here.

## Updates

**2026-11-08.** Implemented in #86. `zig build` reads multicall's `slim-<release>-<arch>` trees, the one 42-command set multicall ships. Steps 1 to 3 and 5 are built. Still to do: step 4, running `zig build slim` for each architecture in `scripts/release.sh` and adding 9front's licence notice to the archives; the binary's measured growth; and the Done when cases for `--builtin=before` over a 9P root, `wsmount` over the built-in root, and the differential corpus over `#Hroot`.
