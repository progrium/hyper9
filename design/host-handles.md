---
slug: host-handles
title: Host access through handles
status: draft
created: 2026-11-21
authors: [progrium]
depends: [kernel-port]
areas: [kern, sandbox, web, tests]
branch: [dev, host-handles, host-handles-2]
---

# Proposal: Host access through handles

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

h9's kernel calls the host OS directly, by path and by address, and the sandbox policy is checks hooked into those calls. This proposal turns that around. The kernel never calls the host. It's given a table of handles when it's made: directory handles, a dialer, a listener, a clock, a console, an entropy source, and a window. A device that reaches outside does it through a handle, and the policy is which handles exist and what each allows. Native hosts open files beneath a directory handle, which the OS confines. The web host already works this way, through WASI preopens and JavaScript imports, so the two become one design. The policy, its flags, and `--print` don't change.

## Background

- **Checks are hooks in vendored code.** `third_party/drawterm/kern/devfs-posix.c` has 57 references to h9's policy functions, and `devfs-win32.c` has 29. devip has its own for dials and listens. Each is a place where a path or an address is checked just before a host call, and a call added without its check is a hole.
- **Path checks need care to be sound.** [spec/sandbox.md](../spec/sandbox.md) has sections on path resolution, symbolic links, and contained trees, because checking a path and then opening it by name races with whoever can rename it.
- **Two designs.** On the web host there's no ambient file system: WASI gives h9 preopened directories, and everything else is a JavaScript import. The native hosts have ambient everything and subtract.
- **[host-sandbox](host-sandbox.md)** confines the h9 process from outside: Seatbelt on macOS, Landlock and seccomp on Linux, and process mitigation policies on Windows. It's derived from the same policy, and it depends on this proposal, since it's simplest to derive when the set of things h9 opens is known up front.

[kernel-port](kernel-port.md) comes first because a kernel that's a value takes its host as an argument, and because the devices that touch the host have to be h9's own code to change.

## Proposal

### The host table

`Kernel.init(gpa, host)` takes a `Host`:

| Handle | Gives | Native | Web |
| --- | --- | --- | --- |
| `dirs` | Named directory handles, each read-only or read-write, with deny patterns | A directory fd or `HANDLE` opened before the program starts | A WASI preopen, or a JavaScript tree |
| `dial` | Outbound connections, filtered by the plan's network rules | Sockets | WebSocket and fetch imports |
| `listen` | Listening addresses the plan names | Sockets | None |
| `clock` | Wall and monotonic time, and timers | The OS | JavaScript |
| `console` | The terminal | The TTY or pipes | The page's terminal |
| `random` | Entropy | The OS | `crypto.getRandomValues` |
| `window` | The `--gfx` window | drawterm's GUI backend | A canvas |
| `spawn` | Host commands, where the plan allows them ([host-cmd](host-cmd.md)) | Processes | None |

A handle that's absent is a capability the machine doesn't have. `--net disable` is no `dial` and no `listen`.

### Files beneath a handle

The host tree device opens every file relative to one of `dirs`, never by absolute path. On Linux that's `openat2` with `RESOLVE_BENEATH`, or `RESOLVE_IN_ROOT` for a contained tree. On macOS and the BSDs it's a walk of one component at a time with `O_NOFOLLOW`. On Windows it's `NtCreateFile` relative to a directory handle. The OS enforces that the result is inside the directory, so there's no check to race.

Read-deny patterns, which carve a hole in an allowed tree, stay as a check on the path relative to its handle. They're the one rule a handle can't express alone.

### Handle names in the namespace

Each of `dirs` has a short name the plan gives it: `cwd` for the host cwd, `root` for a `--dir` root, and `d1`, `d2`, and so on for the rest, in the plan's order. The host tree device is attached by that name, `#Ucwd`, and a path under it is relative to the handle, so a binding reads `bind -c '#Ucwd' /mnt/term/cwd`. `/proc/n/ns` prints that, and no host path, under every profile. The guest learns the host's layout only from what the plan chooses to show it, such as the `/mnt/term/<host path>` a `--readable` path is bound at.

`--print` still shows each handle's host path, since the plan is read on the host and has to say what it opens. It names the handle beside it, so the two can be matched. `--ns` replays `/proc/n/ns`'s output in any machine whose plan has handles of the same names, which the same flags give. A namespace file that names `#U` by a host path, as one written by hand can, keeps working: the path is resolved to the handle that holds it, and the binding is shown by that handle's name. A host path under no handle fails as it does now.

### The policy compiles to handles

The plan is compiled as now. Its last step opens the handles: one per readable or writable tree, the dialer with the plan's `--net` and `--net-allow` rules, and so on. `--print` shows the same plan. A path that can't be opened is the same exit 125, earlier.

### Devices

devfs, devip, the console, the clock, and the GUI glue are rewritten to take their handle from the kernel's `Host`. Nothing under `src/kern/` includes a host OS header: those are in `src/host/posix`, `src/host/win32`, and `src/host/web`, which implement `Host`.

### Embedders

`Machine.Options` gains `host: ?Host`, for an embedder that wants to supply handles of its own: an in-memory tree for tests, a dialer that goes through its own proxy, or a clock it controls. Left null, h9 builds one from the policy, as the CLI does.

## Rationale

**Why handles and not better checks.** A check says no to what's listed. A handle makes everything unlisted unreachable, including what nobody thought of. The web host shows the kernel doesn't need more.

**Why keep read-deny as a check.** Opening a directory with a subtree removed isn't something any host offers. The alternative, splitting an allowed tree into handles around each denied path, changes what a directory listing shows.

**Why not rely on [host-sandbox](host-sandbox.md) alone.** It's coarser (Landlock has no deny within an allow, and Seatbelt is deprecated API), it isn't available on every host or inside every container, and it does nothing for the web. The two fit together: with handles opened up front, the host sandbox can deny every open by path afterwards.

**Names, not host paths, in `/proc/n/ns`.** A guest reading its own namespace learned the host's layout, the open question [hide-host-paths](epoch-0/hide-host-paths.md) was written for. Its options were to hide host binds, which breaks `--ns` replay and `ns` output a person reads to debug, or to show a placeholder, which `--ns` can't replay. Once devices reach the host only through named handles, the name is what the kernel holds, so showing it costs nothing and still replays. Hiding it only under `--profile=tight`, as hide-host-paths asked, would leave two formats for no benefit.

**Why an embedder interface.** Tests want a kernel with no host at all, and [namespace-kernel](epoch-0/namespace-kernel.md) is already a kernel whose whole outside is handed to it.

## Compatibility

- **CLI, the policy flags, profiles, `--print`, and exit codes.** Unchanged.
- **Timing of errors.** A readable or writable path that doesn't exist fails when the machine starts, not when the guest first reaches it. Paths the policy marks optional are skipped, as now.
- **`Machine.Options`.** `host` is new and optional.
- **`/proc/n/ns`.** `#U` binds show a handle name, `#Ucwd`, where they showed a host path. A guest script that read host paths from it gets names. `--ns` files written from it replay where the same handles exist. `--print`'s caveat that `/proc/n/ns` shows host paths goes.
- **Paths that change under a running machine.** A handle follows its directory through a rename on the host. Today's path checks would follow the name instead.
- **`third_party/`.** The policy hooks in `devfs-posix.c`, `devfs-win32.c`, and devip go, since those files are no longer compiled.

## Security

This is a security change. The guest can reach nothing new. What changes is how "nothing else" is enforced: by the OS, per open, with no window between a check and a use. Each host's beneath-a-handle open has its own edge cases (macOS has no `RESOLVE_BENEATH`, and Windows has reparse points), so each has a test that tries to escape through a symbolic link swapped in during the walk. The policy cases that exist today must pass unchanged.

## Done criteria

- [ ] Every sandbox case in `tests/` passes unchanged on macOS, Linux, Windows, and the web host.
- [ ] `test "a symlink swapped in mid-walk can't escape a handle [host-handles]"` passes on macOS, Linux, and Windows.
- [x] `test "a kernel with an empty Host can reach nothing outside [host-handles]"` passes.
- [ ] `test "an embedder's in-memory dirs handle serves a root [host-handles]"` passes.
- [x] `git grep -lE '#include <(unistd|fcntl|sys/|windows)' src/kern/` finds nothing.
- [ ] `h9 --print` output is the same as before for the policy cases, apart from handle names and the caveat that goes.
- [ ] `test "/proc/n/ns shows handle names and no host path, in every profile [host-handles]"` passes.
- [ ] `test "--ns replays /proc/n/ns output in a machine with the same handles [host-handles]"` passes.
- [x] [spec/sandbox.md](../spec/sandbox.md) describes handles, and its path resolution section describes what each host does beneath one.

## Implementation

1. The `Host` type, and a host built from the policy that wraps today's calls, so nothing changes yet.
2. Files: the host tree device on directory handles, a host at a time, with the escape tests.
3. Network: the dialer and the listener.
4. The clock, the console, entropy, and the window.
5. Move host code out of `src/kern/` into `src/host/`.
6. `Machine.Options.host`, and the web host on the same `Host`.
7. The spec.

## Open issues

- Whether `spawn` belongs here or stays with [host-cmd](host-cmd.md), which is still being built.
- `--host-fs`, which binds the whole host tree. As written it's one read-write handle on `/`, which is what it means.

## Updates

**2026-11-26, the `Host` type.** `src/host/host.zig` defines `Host`, each handle an interface of a context and a function table, as `std.mem.Allocator` is, and `src/host/planned.zig` builds one from a compiled plan whose handles ask the plan, as devfs's and devip's hooks do now. `Machine` builds it at init, and no device uses it yet. Some things building it settled:

- **Names come from the plan.** `root` is the first host directory on the root stack, `cwd` the host cwd, and `d1` on each other path an allow rule names, in rule order, once. A path that's both the root and the cwd has both names. `--host-fs`'s rule on `/` is one of the `d` handles. A handle is writable when the plan's verdict at its top is, so a tree under an overlay is read-only to it.
- **Under `--net=outbound` there is a listener, and it refuses every guest address.** h9's own loopback listeners, such as [linux-dns](linux-dns.md)'s resolver, which takes the queries devip redirects to it, open through `listen` too, so only `--net=disable` leaves it out.
- **The handles hold a pointer to the plan**, so `Machine` keeps a copy in its arena, which doesn't move when a `Machine` is returned by value. A `Kernel` that's a value will hold its `Host` the same way.
- **`Machine.Stdio` is the host's `Console`**, which has the same fields.

**2026-11-26, files, the network, and the rest.** Steps 2 to 4 are built. Some things they settled:

- **devfs keeps its paths, and opens beneath the handle that holds each.** Each tree a plan allows is opened when the machine is made (`src/host/dirs.zig`): a directory fd (`O_PATH` on Linux), a `HANDLE`, or for a one-file tree its directory's and its name. devfs still names files by resolved host path, and `src/host/dirs.c` opens each beneath the deepest handle whose path holds it: `openat2` with `RESOLVE_BENEATH` on Linux, a walk of one name at a time with `O_NOFOLLOW` elsewhere, and `NtCreateFile` a name at a time with `FILE_OPEN_REPARSE_POINT` on Windows. devfs-posix's opens, `stat`s, `lstat`s, and `readlink`s go through it (`src/kern/fscheck.h`), and devfs-win32's `CreateFile` and `CreateDirectory`; its deletes, renames, attributes, and `FindFirstFile` are still by path. The `#U` attach specs, and so `/proc/n/ns`, still name host paths: handle names in the namespace are later work.
- **A 9front program's links still reach other trees.** Its walks follow links anywhere, and the policy decides by the resolved path, so an open whose links leave its handle is made again by the path it resolves to, beneath the handle holding that, with no link followed; with no such handle it's a hidden file. A link swapped in meanwhile fails rather than being followed.
- **Ancestors are looked at by path.** A path no handle holds is an ancestor that `/mnt/term` lists, or hidden; only directories are opened there, read-only, and devfs's checks decide.
- **The policy checks stay**, as the second line: read-deny, and the verdict on what was opened. Removing them waits on handle names in the namespace and on devfs leaving `third_party/`.
- **The resolver's sockets are the host's.** `Dial.connect` and `Listen.bind` make h9's own connections (`src/host/net.zig`, which was the resolver's `HostNet`), without asking `allows`; the resolver gets the machine's dialer and listener. Under `--net=outbound` the listener refuses every guest address and still binds the resolver's loopback sockets, as the open question above has it. devip's checks ask the dialer and listener (`allows`, `probe`, `lookup`, `resolved`), and a missing one refuses. `#ℏ`'s checks still ask the plan.
- **The clock, entropy, the console, and the window.** `kern.wallNs` and `kern.monoNs` read the calling thread's host clock, which in a planned host is the OS's; `getrandom`, `AT_RANDOM`, and `/proc`'s uuids read its `random`; a run's console is its `console`, refreshed from `Options.stdio` at each run since an embedder may change it; and `--gfx` takes the screen through its `window`. devcons's `#c/random` is still drawterm's.

**2026-11-26, the host's code in `src/host/`, `Options.host`, and the spec.** Steps 5 to 7 are built. Some things they settled:

- **The host's devices are h9's own Zig.** devfs-posix and devfs-win32 are `src/host/devfs_posix.zig` and `devfs_win32.zig` behind `devfs.zig`, devip is `devip.zig`, and devlfd is `devlfd.zig`, native devices whose optional operations replace their `Devx`. They're close ports, function by function, so behaviour is unchanged. drawterm's files are back to upstream and out of the build, and so is `win32.c`: the host's C reads Windows errors through `src/host/win32.zig`'s `oserr`. devip's socket calls (`ipsock-*.c`) and h9's (`hostsock-*.c`) stay C, called through `raising`.
- **`src/host` is a module of its own** (`host_dev`), which the kernel's Zig imports for its devices and which imports the kernel's in turn, with the host's C headers translated apart from the kernel's (`src/host/libc.h`).
- **Two of drawterm's patches remain**: devcons's hooks (`pid`, `ppid`, the clock, and `sysstat`), and `dat.h`'s include of h9's `Proc` and `Chan.srvname`. Neither is host code; they end with devcons and `dat.h` ported, which is the kernel's, not this proposal's.
- **An embedder's host is used as given.** The policy is still compiled beside it, and devfs still checks the plan's verdicts, so for files its handles can narrow what the plan allows but not widen it; devip's checks ask its dialer and listener, which decide. Its directory handles stay the embedder's to close, and its console, when it has one, replaces `Options.stdio`'s.
- **The web host's table is the planned one**, with its trees as WASI preopens, described and not opened, and no listener. devfs opens by path there, which wasi-libc resolves beneath a preopen.
