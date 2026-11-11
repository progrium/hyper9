# Embedding h9 in a Zig program

The `h9` command is a thin layer over a Zig library. The library runs 9front
programs in **machines**: one VM, one private namespace, one console, and one
process tree each. This guide shows how to build a program on that library,
configure a machine, run programs in it, run several at once, and connect it
to your own files and 9P servers.

It assumes you've read the [manual](../MANUAL.md) up to chapter 3 and know
what a root tree is. Everything here is checked against the source as of
this writing: [src/root.zig](../src/root.zig) is the public surface, and
[src/machine.zig](../src/machine.zig) has the `Machine` API with its doc
comments. A complete program, [embedding/embed.zig](embedding/embed.zig),
builds with `zig build embed` and runs in `zig build test`.

## Contents

1. [A first program](#a-first-program)
2. [Depending on h9 from your project](#depending-on-h9-from-your-project)
3. [Machine.Options](#machineoptions)
4. [Running programs](#running-programs)
5. [Standard I/O, traces, and signals](#standard-io-traces-and-signals)
6. [The sandbox policy](#the-sandbox-policy)
7. [Backends](#backends)
8. [Several machines in one process](#several-machines-in-one-process)
9. [Connecting files, devices, and 9P servers](#connecting-files-devices-and-9p-servers)
10. [Rules for embedders](#rules-for-embedders)

## A first program

This runs `rc -c 'echo hello from $sysname'` from a root tree and captures
its output in memory:

```zig
const std = @import("std");
const h9 = @import("h9");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var m = try h9.Machine.init(gpa, io, .{
        // Host paths must be absolute with symlinks resolved.
        .root = .{ .dir = "/Users/me/9front/root" },
        .stdio = .{ .out = &out.writer, .err = &out.writer },
    });
    defer m.deinit();

    const status = try m.run(.{ .guest = "rc" }, &.{ "rc", "-c", "echo hello from $sysname" });
    switch (status) {
        .exited => |msg| std.debug.print("exited \"{s}\": {s}", .{ msg, out.written() }),
        .killed => |msg| std.debug.print("killed: {s}\n", .{msg}),
    }
}
```

It prints `exited "": hello from h9`. The empty string is success, as in
9front.

The steps are always the same: `Machine.init` compiles the options into a
namespace plan and creates the backend's VM, `Machine.run` runs one program
until its first process exits, and `Machine.deinit` frees the VM. One
machine can run any number of programs, one after another; each run gets a
fresh namespace and process tree, so nothing carries over between runs
except what was written to the host.

## Depending on h9 from your project

The repository's `build.zig` exports a module named `h9`. It links
drawterm's kernel (`kern`) into anything that imports it, so a consumer only
adds the backend's own libraries.

**In this repository.** The example is wired up this way in `build.zig`
(`embed_example`): a `b.addExecutable` whose root module imports `mod`,
then the same three things the `h9` executable does:

- on macOS, `linkFramework("Hypervisor")` and the SDK paths (`addSdkPaths`);
- `linkUnicorn(exe)`, which links Unicorn when built with `-Demu=unicorn`;
- on macOS, an ad-hoc `codesign` with [h9.entitlements](../h9.entitlements)
  before the program runs, because HVF refuses to create a VM without the
  hypervisor entitlement.

**From another project.** A path dependency on a checkout works:

```zig
// build.zig.zon
.dependencies = .{ .h9 = .{ .path = "../hyper9" } },
```

```zig
// build.zig
const h9 = b.dependency("h9", .{ .target = target, .optimize = optimize, .emu = .unicorn });
const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "h9", .module = h9.module("h9") }},
}) });
if (target.result.os.tag == .macos) exe.root_module.linkFramework("Hypervisor", .{});
```

Drop `.emu = .unicorn` for the MIT build, which has HVF only. With it, the
checkout needs Unicorn's prebuilt library in `.local/unicorn`
(`scripts/fetch.sh`) and, as in this repository, Linux needs a musl target
(`-Dtarget=x86_64-linux-musl`). On a Mac your build also has to sign the
binary with the entitlement, as above, and set `SDKROOT` if Zig can't find
the SDK (`scripts/env.sh` does). Unicorn is GPLv2, so a program that links
it is a GPLv2 program; see SPEC.md, "Emulator".

A fetched (URL or hash) dependency doesn't work yet: `build.zig.zon`'s
`paths` leave out `third_party/` and `scripts/`, so drawterm's sources and
the version pins aren't in the package.

## Machine.Options

Every field but `stdio` has a default:

| Field | Type | Default | What it does |
| --- | --- | --- | --- |
| `backend` | `vmm.BackendKind` | `.auto` | `.auto`, `.hvf`, `.kvm`, `.whp`, `.native`, `.emu`, `.v86` (an alias of `.emu`); one not built for this host fails with `BackendNotBuilt`. See [Backends](#backends). |
| `arch` | `?vmm.Arch` | host's | `.arm64`, `.amd64`, or `.i386`. Read it from an a.out with `h9.aout.parse(bytes).arch`. |
| `root` | `?Root` | none | `.{ .dir = path }`, `.{ .tcp = "tcp!host!564" }`, `.{ .unix = path }`, or `.{ .ws = "wss://host/9p" }`. Without one, only `.bytes` programs run. |
| `root_spec` | `[]const u8` | `""` | The attach name for a 9P root. |
| `root_user` | `?[]const u8` | machine's user | The uname h9 attaches to a 9P root with. |
| `root_headers` | `[]const []const u8` | `&.{}` | Extra handshake headers for a `.ws` root, as `"Name: value"`. |
| `root_ca` | `?[]const u8` | host's bundle | A PEM file a `wss://` root must chain to: a host path. |
| `proxy` | `?Machine.Proxy` | direct | Proxies for connections h9 makes itself (a `.ws` root, WebSocket mounts in `ns`): `.{ .http = ..., .https = ..., .no_proxy = ... }`. The CLI fills it from `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY`; the library never reads the environment. Guest connections always go direct. |
| `cwd` | `?[]const u8` | none | A host directory bound at `/mnt/term/cwd` and made the guest's cwd. |
| `env` | `[]const EnvVar` | `&.{}` | Guest environment variables, beyond the defaults (`user`, `sysname`, `path`, and so on). |
| `policy` | `Policy` | `.{}` | The sandbox: binds, write mode, network, limits. See [The sandbox policy](#the-sandbox-policy). |
| `guest_tools` | `bool` | `true` | Binds h9's own commands (`#H/bin`, such as `wsmount`) after `/bin`. `false` leaves them out and masks `#H`, as `--no-guest-tools` does. |
| `trace` | `?*std.Io.Writer` | none | Receives a ratrace-style line per syscall. |
| `dump_on_fault` | `bool` | `false` | On a fault, prints the registers and a symbolized PC to `stdio.err`. |
| `ns` | `?[]const u8` | none | A namespace file (newns syntax) to replay after the policy's namespace is built. It's a *guest* path, so a relative one is in the guest's cwd. |
| `owned_vcpus` | `?u32` | backend's | For tests of the vCPU pool; leave it alone. |
| `gfx` | `?Machine.Gfx` | none | A host window for this machine, as `--gfx` gives: `.{}`, or `.{ .clipboard = false }` for `--gfx=noclip` and `.scale` for `--gfx-scale`. Only one machine in the process can have it. See [Graphics](#graphics). |
| `signals` | `?*Machine.Signals` | none | Lets you deliver Ctrl-C and hangup to a running machine. |
| `stdio` | `Machine.Stdio` | required | The console's host side: `in`, `out`, `err`, and callbacks. |

The machine keeps the `Options` value as you passed it, so every slice in
it (paths, `env`, policy lists) must outlive the machine, not just `init`.

`Machine.init` fails with `vmm.CreateError` (the backend couldn't make a VM:
`HypervisorUnavailable`, `BackendNotBuilt`, `WrongArch`, `OutOfGuestMemory`,
and so on), `PolicyConflict`, or one of `h9.gfx.Error` for `gfx` (`GfxNotBuilt`, `GfxInUse`, `GfxUnavailable`). For the reason behind a conflict, call
`Machine.initExplained(gpa, io, opts, &msg)` instead.

To see what a set of options will build without making a VM, which is what
`h9 --print` does, compile the plan yourself and print it:

```zig
var why: []const u8 = "";
const plan = try h9.Machine.compilePlan(arena, opts, &why);
try plan.print(writer);
```

## Running programs

```zig
pub fn run(m: *Machine, prog: Program, argv: []const []const u8) RunError!Status
```

`prog` is either:

- `.{ .bytes = data }`: an a.out you've read on the host (or built in
  memory). This is what the CLI does for `./prog`. Set `Options.arch` to
  match it, since there's no header sniffing in `run`.
- `.{ .guest = name }`: a path or name looked up in the machine's
  namespace. Names without a leading `/`, `./`, or `../` are searched along
  `$path`, as rc does.

`argv[0]` is the name the program sees for itself.

The result is a `Status`:

- `.exited`: the `exits` string, unchanged. Empty means success. The CLI
  turns it into an exit code (SPEC.md, "Exit codes"); the library leaves
  that to you.
- `.killed`: the process died, with the reason in note form
  (`sys: trap: fault read addr=0x0`, `h9: timeout`).

`run` fails with a `RunError`. The ones you'll handle:

| Error | Meaning |
| --- | --- |
| `NotFound` | The guest program wasn't found. `m.err_msg` has the details. |
| `NotExecutable` | Not a runnable a.out for this machine. `m.err_msg` says why. |
| `NamespaceFailed` | The root or cwd couldn't be bound. `m.err_msg` names the bind that failed. |
| `Stuck` | An earlier run timed out and left a process in a host call; this machine can't run again. |
| `TooManyMachines` | 64 machines are already running in this process. |

The status's message and `err_msg` point into a buffer inside the machine.
They're valid until the next `run` or `deinit`, so copy them first if you
need them later. [embedding/embed.zig](embedding/embed.zig) does this.

### Timeouts and stuck machines

With `policy.timeout_ns` set, `run` stops the machine at the deadline: it
posts `hangup`, gives processes two seconds, then kicks every vCPU,
interrupts blocking kernel calls, and returns `.killed = "h9: timeout"`.

A process can be in a host call that can't be interrupted, such as a read of
`stdio.in` with no `in_cancel`. Then `run` returns anyway after a short
grace period and sets `m.stuck`. The backend, the plan, and the run's state
are leaked rather than freed under the process, and that process may still
touch `argv`, the program bytes, the `Stdio` streams, and the trace writer
when its call returns. Keep those alive, or exit the host process, which is
what the CLI does. `deinit` on a stuck machine is safe and frees nothing.

## Standard I/O, traces, and signals

```zig
pub const Stdio = struct {
    in: ?*std.Io.Reader = null,
    in_cancel: ?consin.Cancel = null,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    raw: ?Raw = null,
};
```

**Output.** Writes to fd 1 go to `out` and fd 2 to `err`. The console takes
a lock around each write and flushes after it, so `out` and `err` can be the
same writer, and output from several guest processes never interleaves
within a write. Use `std.Io.Writer.Allocating` to capture, a
`std.Io.Writer.Discarding` to drop it, or a file writer to stream.

**Input.** With `in` null the guest reads end of file. Otherwise a reader
thread reads `in` on the guest's behalf, one read per guest request, so
input no guest asked for stays in your stream. If `in` can block (a pipe, a
terminal, a socket), give `in_cancel` too: its `func` must make a blocked
read on that thread return, and `reset` clears a cancel left from an
earlier run. Without it a run that ends during a console read ends `stuck`.
The CLI's [src/stdin.zig](../src/stdin.zig) is a worked example: a poll on
stdin and a wake pipe on POSIX, `CancelSynchronousIo` on Windows. A
`std.Io.Reader.fixed(bytes)` never blocks and needs no cancel.

**Raw mode.** `raw.set(ctx, on)` is called when the guest writes `rawon` or
`rawoff` to `/dev/consctl`. The library never touches a terminal; the CLI
puts the host's in raw mode there. The machine turns raw mode off when a run
ends.

**Traces.** `trace` gets one line per syscall, as `h9 --trace` prints. The
machine serializes writes to it.

**Signals.** To interrupt a running machine from another thread, create a
`Machine.Signals`, point `Options.signals` at it, and call:

```zig
var sig: h9.Machine.Signals = .{};
opts.signals = &sig;
// later, from any thread, even a signal handler's watcher:
sig.interrupt(io); // `interrupt` note to the foreground note group (Ctrl-C)
sig.hangup(io);    // `hangup` to every process, teardown after 2 s
sig.stop(io);      // tear the machine down now
```

Each call only sets a flag and wakes `run`'s thread, which posts the notes.
Calls while nothing is running are dropped.
[src/hostsig.zig](../src/hostsig.zig) shows how the CLI wires SIGINT,
SIGTERM, SIGHUP, and the Windows console handler to these.

## The sandbox policy

`Options.policy` is an `h9.Policy`, the same struct the CLI fills from its
flags (manual chapter 23):

| Field | Flag | Default |
| --- | --- | --- |
| `profile` | `--profile` | `.default`; `.tight` has no network, a read-only cwd, and a 10 minute timeout. |
| `readable` | `--readable` | Host paths bound read-only. |
| `writable` | `--writable` | Host paths bound read-write. |
| `read_deny` | `--read-deny` | Host paths hidden even inside a bound tree. |
| `write` | `--write` | `.none`, `.scope`, or `.ephemeral` (copy-on-write in memory). Null: the profile's. |
| `net` | `--net` | `.disable`, `.outbound`, or `.enable`. Null: outbound, or disable for tight. |
| `net_allow` | `--net-allow` | Dial-string patterns every connect must match. |
| `memory` | `--memory` | Bytes of guest memory, page tables, and ephemeral files included. |
| `timeout_ns` | `--timeout` | The machine's deadline. |
| `pids` | `--pids` | Cap on live processes. |
| `cpus` | `--cpus` | Cap on vCPUs running guest code at once. |
| `cwd_writable` | `--sandbox` | Whether the cwd is writable. Null: the profile's. |
| `host_fs` | `--host-fs` | Bind the whole host filesystem at `/mnt/term`. |

Paths in it follow the same rule as `root` and `cwd`: absolute, symlinks
resolved. Use `std.Io.Dir.cwd().realPathFileAlloc` on them, as the CLI does
(`resolveAll` in [src/main.zig](../src/main.zig)). Contradictory settings,
such as `write = .none` with `writable` paths or `net = .disable` with
`net_allow` patterns, fail `init` with `PolicyConflict`.

A policy the build can't enforce isn't an error. Check
`m.plan.unenforced` (or the plan from `compilePlan`) and refuse to run if
it's not empty, which is what `h9 --strict` does.

## Backends

| `BackendKind` | Host | Runs | Built |
| --- | --- | --- | --- |
| `.hvf` | macOS on Apple Silicon | arm64 | always, on that host |
| `.kvm` | Linux on arm64 or x86\_64, with access to `/dev/kvm` | the host's: arm64 or amd64 | always, on those hosts ([kvm](../design/kvm.md)) |
| `.native` | Linux x86\_64, 5.11 or later | amd64 | always, on that host ([native-backend](../design/native-backend.md)) |
| `.emu` | any | arm64, amd64, 386 | with `-Demu=unicorn` (GPLv2) |
| `.whp` | Windows x86\_64, with the Windows Hypervisor Platform feature | amd64 | on Windows x86\_64; incomplete ([whp](../design/whp.md)) |

On KVM, h9 blocks `SIGRTMIN + 1` in the threads that run vCPUs and sends it
to kick them out of the guest. Leave that signal to h9: don't unblock it or
install a handler for it in threads that call into a machine.

`.auto` uses the host's hypervisor if it's built in and can run `arch`. When
the hypervisor is unavailable or can't run `arch`, it falls back to the
native backend on Linux x86\_64, then to the emulator if that's built in,
and otherwise returns the error. It doesn't fall back on any other failure.
Check `m.backend.kind()` after `init` to see which one you got; the CLI
warns when `.auto` lands on `.native` or `.emu`.

`h9.vmm.Kind.built(.hvf)`, `.built(.kvm)`, and `.built(.emu)` tell you at run time what's
compiled in, and `h9.vmm.host_arch` is the architecture that runs natively.

### Graphics

`Options.gfx` gives the machine the process's one window, drawn by the GUI
backend built in with `-Dgfx` (`h9.gfx.backend`; Cocoa on macOS and Win32 on
Windows by default). Closing the window calls `signals.hangup`, so pass
`signals` if you want to handle it; without them the machine gets its own.
On macOS AppKit needs the main thread, so call `h9.gfx.main(work, ctx)` from
`main` and create machines in `work`, which runs on another thread; the
process exits with `work`'s return value. Elsewhere `h9.gfx.main` just calls
`work`. `h9.gfx.unavailable()` says why there's no display, if there isn't
one.

## Several machines in one process

Machines are independent values. Each one's first process starts with a
fresh namespace, environment, file descriptor table, and console, so one
machine never sees another's `/tmp`, `/srv`, binds, or environment
variables. They share drawterm's kernel, which boots once per host process
on first use.

To run machines at the same time, give each its own thread and its own
`Machine`, and call `run` on that thread:

```zig
const Job = struct {
    opts: h9.Machine.Options,
    out: std.Io.Writer.Allocating,
    status: []const u8 = "",

    fn run(j: *Job, gpa: std.mem.Allocator, io: std.Io) void {
        j.opts.stdio = .{ .out = &j.out.writer, .err = &j.out.writer };
        var m = h9.Machine.init(gpa, io, j.opts) catch return;
        defer m.deinit();
        const st = m.run(.{ .guest = "rc" }, &.{ "rc", "-c", "echo $machine" }) catch return;
        j.status = gpa.dupe(u8, switch (st) {
            inline else => |s| s,
        }) catch "";
    }
};
```

[embedding/embed.zig](embedding/embed.zig) is the full version, with
`$machine` set per job and results printed in order:

```
$ zig build embed -Demu=unicorn
$ zig-out/bin/embed -j 3 --root .local/9front/root rc -c 'echo $machine'
machine 0 (hvf): exited ""
  0
machine 1 (emu): exited ""
  1
machine 2 (emu): exited ""
  2
```

The limits:

- **One HVF machine per host process.** Hypervisor.framework allows one VM
  per process, so on a Mac only one machine can exist on `.hvf` at a time;
  `init` for a second fails. Use `.emu` for the others, as the example and
  the backend tests do, or run machines one after another, or run one
  process per machine.
- **64 running machines.** Each run takes a console slot, and there are 64
  (`max_consoles` in [src/kern.zig](../src/kern.zig)). The 65th concurrent
  `run` fails with `TooManyMachines`.
- **One run at a time per machine.** `run` copies the machine's state into
  the run, but don't call it twice at once on the same `Machine`.
- **Memory.** Each machine has a guest memory region of 1 GiB unless
  `policy.memory` says otherwise. The host backs pages as the guest uses
  them, but set `memory` when you run many, so one runaway guest can't take
  them all.

## Connecting files, devices, and 9P servers

There's no API for adding a kernel device in Zig yet: the device table is
drawterm's, compiled in ([src/kern/devtab.c](../src/kern/devtab.c)). What a
machine can see comes from these places, all set in `Options`:

**Host directories.** `root = .{ .dir = ... }`, `cwd`, and the policy's
`readable` and `writable` paths are served by drawterm's devfs (`#U`). The
write mode decides whether writes reach the host, stay in memory, or fail.

**A 9P server as the root.** Point `root` at any 9P2000 server and the
machine mounts it at `/` ([9p-roots](../design/9p-roots.md)):

```zig
.root = .{ .unix = "/tmp/myfs.sock" }, // or .{ .tcp = "tcp!127.0.0.1!5640" }
.root_spec = "main",                   // the attach name, if your server uses one
.root_user = "glenda",                 // the attach uname
```

or, for a server behind a WebSocket
([websocket-9p](../design/websocket-9p.md)):

```zig
.root = .{ .ws = "wss://fs.example/9p" },
.root_headers = &.{"Authorization: Bearer ..."},
.root_ca = "/etc/myca.pem", // only if it isn't signed by a CA the host trusts
```

The machine connects to the server once per run, posts the connection as
`/srv/root`, and mounts it at `/`. This is the way to give a machine files
that come from your program rather than from disk: serve them with any 9P
library, in-process on a thread or in another process, and the guest sees
them as ordinary files. `.unix` isn't supported on Windows; use `.tcp`.

**More 9P servers, mounted before the program starts.** Set `ns` to a
namespace file (manual chapter 25). Its `mount` lines can name a
WebSocket URL, which h9 connects on the host, as it does a root, using
`proxy`:

```
mount -c wss://fs.example/9p /n/fs
```

A WebSocket mount that fails stops the run with `NamespaceFailed`, unlike
other namespace-file lines. It's refused under `write = .none`, which h9
can't enforce on a server it doesn't control. The file's `bind`,
`unmount`, and `cd` lines rearrange the rest of the namespace.

**More 9P servers, mounted by the guest.** When the policy lets it connect
(`net = .outbound`, the default profile's, ideally with a `net_allow`
pattern for just that server), a guest can dial a server itself: over TCP
with `srv tcp!127.0.0.1!5640 myfs; mount /srv/myfs /n/myfs`, or over a
WebSocket with `wsmount ws://127.0.0.1:8080/9p /n/myfs`, which is one of
h9's guest tools and needs `guest_tools`. Guest connections don't use
`proxy`.

**The console.** `stdio` is the machine's `/dev/cons`, so a pair of
`std.Io` streams of your own is a device of sorts: whatever you implement
behind a `Reader` and `Writer` is what the guest's console reads and
writes.

## Rules for embedders

- Pass host paths absolute and resolved, on Windows in `#U` form
  (`/C:/Users/me`; `kernPath` in [src/main.zig](../src/main.zig)).
- Keep everything `Options` points at alive for the machine's life, and
  for the life of the process if a run can end stuck.
- Copy a `Status` message or `err_msg` before the next `run` or `deinit`.
- Don't share a `Machine` between threads while it runs.
- Run at most one HVF machine per host process.
- Exit codes are yours to decide; the library returns `exits` strings.
- The library never reads the process's stdin, environment, or terminal,
  and never writes to stdout itself. Everything goes through `Options`.
