---
slug: host-handles
title: Host access through handles
status: draft
created: 2026-11-21
authors: [progrium]
depends: [kernel-port]
areas: [kern, sandbox, web, tests]
branch: []
---

# Proposal: Host access through handles

## Abstract

h9's kernel calls the host OS directly, by path and by address, and the sandbox policy is checks hooked into those calls. This proposal turns that around. The kernel never calls the host. It's given a table of handles when it's made: directory handles, a dialer, a listener, a clock, a console, an entropy source, and a window. A device that reaches outside does it through a handle, and the policy is which handles exist and what each allows. Native hosts open files beneath a directory handle, which the OS confines. The web host already works this way, through WASI preopens and JavaScript imports, so the two become one design. The policy, its flags, and `--print` don't change.

## Background

- **Checks are hooks in vendored code.** `third_party/drawterm/kern/devfs-posix.c` has 57 references to h9's policy functions, and `devfs-win32.c` has 29. devip has its own for dials and listens. Each is a place where a path or an address is checked just before a host call, and a call added without its check is a hole.
- **Path checks need care to be sound.** [spec/sandbox.md](../spec/sandbox.md) has sections on path resolution, symbolic links, and contained trees, because checking a path and then opening it by name races with whoever can rename it.
- **Two designs.** On the web host there's no ambient file system: WASI gives h9 preopened directories, and everything else is a JavaScript import. The native hosts have ambient everything and subtract.
- **[host-sandbox](host-sandbox.md)** would confine the h9 process from outside with Seatbelt, Landlock and seccomp, or an AppContainer. It has to be derived from the same policy, and it's simplest to derive when the set of things h9 opens is known up front.

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

**Why an embedder interface.** Tests want a kernel with no host at all, and [namespace-kernel](namespace-kernel.md) is already a kernel whose whole outside is handed to it.

## Compatibility

- **CLI, the policy flags, profiles, `--print`, and exit codes.** Unchanged.
- **Timing of errors.** A readable or writable path that doesn't exist fails when the machine starts, not when the guest first reaches it. Paths the policy marks optional are skipped, as now.
- **`Machine.Options`.** `host` is new and optional.
- **Paths that change under a running machine.** A handle follows its directory through a rename on the host. Today's path checks would follow the name instead.
- **`third_party/`.** The policy hooks in `devfs-posix.c`, `devfs-win32.c`, and devip go, since those files are no longer compiled.

## Security

This is a security change. The guest can reach nothing new. What changes is how "nothing else" is enforced: by the OS, per open, with no window between a check and a use. Each host's beneath-a-handle open has its own edge cases (macOS has no `RESOLVE_BENEATH`, and Windows has reparse points), so each has a test that tries to escape through a symbolic link swapped in during the walk. The policy cases that exist today must pass unchanged.

## Done criteria

- [ ] Every sandbox case in `tests/` passes unchanged on macOS, Linux, Windows, and the web host.
- [ ] `test "a symlink swapped in mid-walk can't escape a handle [host-handles]"` passes on macOS, Linux, and Windows.
- [ ] `test "a kernel with an empty Host can reach nothing outside [host-handles]"` passes.
- [ ] `test "an embedder's in-memory dirs handle serves a root [host-handles]"` passes.
- [ ] `git grep -lE '#include <(unistd|fcntl|sys/|windows)' src/kern/` finds nothing.
- [ ] `h9 --print` output is the same as before for the policy cases.
- [ ] [spec/sandbox.md](../spec/sandbox.md) describes handles, and its path resolution section describes what each host does beneath one.

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
- Whether [host-sandbox](host-sandbox.md) should depend on this. It would be simpler after, but it doesn't need it.
