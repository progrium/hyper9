//! One machine: a VM running 9front processes whose syscalls are served by
//! drawterm's kern. See SPEC.md, "Process model" and "Filesystem, boot
//! and I/O".
//!
//! Each guest process runs on its own kernel thread with its own vCPU. The
//! first is made with kern.spawn: it builds the machine's namespace, loads
//! the program and runs the exit loop. rfork makes the others with
//! kern.fork, and they run the same loop. Machine.run waits for the first
//! to exit, then stops the rest.

const std = @import("std");
const vmm = @import("vmm.zig");
const loader = @import("loader.zig");
const aout = @import("aout.zig");
const kern = @import("kern.zig");
const syscall = @import("syscall.zig");
const policy = @import("policy.zig");
const segment = @import("segment.zig");
const newns = @import("newns.zig");
const cpupool = @import("cpupool.zig");
const gm = @import("guestmem.zig");
const consin = @import("consin.zig");
const web = @import("web.zig");
const hstream = @import("hstream.zig");
const dotl = @import("dotl/kern.zig");
const ws = @import("ws.zig");
const serve = @import("serve.zig");
const lsys = @import("linux/sys.zig");
const lsig = @import("linux/signal.zig");
const lexec = @import("linux/exec.zig");
const lmm = @import("linux/mm.zig");
const elf = @import("linux/elf.zig");
const kc = @import("linux/kc.zig");
const attr = @import("dotl/attr.zig");
const gfx = @import("gfx.zig");

pub const Status = union(enum) {
    /// The `exits` string; empty means success.
    exited: []const u8,
    /// The process died; the message is in Plan 9 note form.
    killed: []const u8,
};

/// What a run's guest changed in the root's overlay, which is discarded
/// when the machine ends (design/0011-overlay.md). Counting starts once
/// the namespace is built, so the `$home` the builder makes isn't a
/// change. A value type: it holds its names.
pub const RootChanges = struct {
    /// Whether the guest changed the root outside `$home`.
    changed: bool = false,
    /// Whether it changed `$home` (`/usr/$user`).
    home: bool = false,
    /// The top-level names it changed outside `$home`, in byte order:
    /// `lib` for `/lib/x`; empty for `/` itself.
    names: [max_names]Name = undefined,
    count: u8 = 0,
    /// More top-level names changed than `names` holds.
    more: bool = false,

    pub const max_names = 16;
    pub const Name = struct {
        buf: [64]u8 = undefined,
        len: u8 = 0,
        pub fn slice(n: *const Name) []const u8 {
            return n.buf[0..n.len];
        }
    };

    /// The changed top-level names (see `names`).
    pub fn dirs(r: *const RootChanges) []const Name {
        return r.names[0..r.count];
    }

    /// Records a change at `path`, relative to the root, with `home` the
    /// home directory's path relative to the root (`usr/glenda`).
    pub fn note(r: *RootChanges, path: []const u8, home: []const u8) void {
        if (home.len > 0 and std.mem.startsWith(u8, path, home) and (path.len == home.len or path[home.len] == '/')) {
            r.home = true;
            return;
        }
        r.changed = true;
        const top = path[0 .. std.mem.indexOfScalar(u8, path, '/') orelse path.len];
        for (r.dirs()) |*n| if (std.mem.eql(u8, n.slice(), top)) return;
        if (r.count == max_names or top.len > @as(Name, .{}).buf.len) {
            r.more = true;
            return;
        }
        var i: usize = r.count;
        while (i > 0 and std.mem.order(u8, r.names[i - 1].slice(), top) == .gt) : (i -= 1) r.names[i] = r.names[i - 1];
        const n = &r.names[i];
        n.* = .{};
        @memcpy(n.buf[0..top.len], top);
        n.len = @intCast(top.len);
        r.count += 1;
    }
};

/// What to run.
pub const Program = union(enum) {
    /// The bytes of an a.out read on the host (`./prog`).
    bytes: []const u8,
    /// A guest path or name, resolved in the machine's namespace: names
    /// without a leading `/`, `./` or `../` are searched along `$path`.
    guest: []const u8,
};

pub const EnvVar = struct { name: []const u8, value: []const u8 };

pub const RunError = error{
    /// The guest program wasn't found (exit code 127).
    NotFound,
    /// The program isn't a runnable a.out for this machine (exit code 126).
    NotExecutable,
    /// The namespace couldn't be built (bad root or cwd); see `err_msg`.
    NamespaceFailed,
    TooManyMachines,
    NoSpaceLeft,
    /// The machine's last run timed out and its process is still stuck in
    /// a host call, so the machine can't run another.
    Stuck,
    /// A `--serve` listener couldn't listen (exit code 125); see `err_msg`
    /// (design/0035-serve.md).
    ServeFailed,
} || kern.Error || vmm.CreateError || loader.Error;

/// The built-in root `#Hroot` serves (design/0087-builtin-root.md): what it
/// was built from, for the plan, `--version` and `--check`.
pub const builtin_root = struct {
    const t = kern.builtin_root;
    /// The 9front release multicall's trees were built from.
    pub const release: []const u8 = t.release;
    /// multicall's set (src/9box).
    pub const set: []const u8 = t.set;
    /// The architectures with commands, in 9front's names; empty for the
    /// skeleton only.
    pub const arches: []const []const u8 = &t.arches;
    /// Commands per architecture.
    pub const commands: usize = t.commands;

    /// Whether `arch` has commands in it.
    pub fn has(arch: vmm.Arch) bool {
        for (arches) |a| if (std.mem.eql(u8, a, arch.name())) return true;
        return false;
    }

    /// `h9 <version>, 9front <release> <set>`, or `skeleton only`.
    pub fn describe(arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        const v = @import("build_options").version;
        if (arches.len == 0) return std.fmt.allocPrint(arena, "h9 {s}, skeleton only", .{v});
        return std.fmt.allocPrint(arena, "h9 {s}, 9front {s} {s}", .{ v, release, set });
    }
};

pub const Machine = struct {
    /// The root tree (design/0013-9p-roots.md): a host directory, or a 9P
    /// server the machine connects to and mounts at /.
    pub const Root = union(enum) {
        /// A host directory, absolute and resolved, served through #U.
        dir: []const u8,
        /// A TCP 9P server: a dial string, `tcp!host!port`.
        tcp: []const u8,
        /// A unix-domain socket's host path. Not supported on Windows.
        unix: []const u8,
        /// A 9P server over a WebSocket: a ws:// or wss:// URL
        /// (design/0021-websocket-9p.md).
        ws: []const u8,
    };

    /// Proxies for the connections the machine makes itself: a WebSocket
    /// root and namespace-file mounts. Guest connections always go direct.
    pub const Proxy = ws.ProxyConfig;

    /// A `--serve` listener's address (design/0035-serve.md): a unix
    /// socket's host path, `host!port` for TCP, or `host:port/path` from
    /// a ws:// URL. Port 0 picks a free port.
    pub const Listen = serve.Listen;

    pub const Options = struct {
        backend: vmm.BackendKind = .auto,
        /// Architecture of the binaries this machine runs; null means the host's.
        arch: ?vmm.Arch = null,
        /// The guest's /: a host directory or a 9P server. Without one the
        /// machine has only devices, so only host-path programs can run.
        root: ?Root = null,
        /// The attach name for a 9P root.
        root_spec: []const u8 = "",
        /// The uname for h9's attaches to a 9P root; null means the
        /// machine's user.
        root_user: ?[]const u8 = null,
        /// Extra HTTP headers for a `ws` root's handshake, as `Name: value`.
        root_headers: []const []const u8 = &.{},
        /// PEM certificates a `wss` root must chain to, instead of the
        /// host's bundle: a host path.
        root_ca: ?[]const u8 = null,
        /// Resolve a host root tree's symlinks inside it: an absolute
        /// target starts at the tree's top, and `..` stops there
        /// (design/0034-symlinks-in-root.md).
        root_contained: bool = false,
        /// A Linux root tree, absolute and resolved: the Linux view's /
        /// (design/0018-linux-personality.md).
        linux_root: ?[]const u8 = null,
        /// The host's DNS servers, as addresses: a Linux root without an
        /// /etc/resolv.conf gets one naming them, and the network policy
        /// lets port 53 reach them even when they're link-local
        /// (design/0050-linux-net.md). The CLI reads the host's
        /// resolv.conf.
        nameservers: []const []const u8 = &.{},
        /// Resolve a guest program in the 9front view even with a Linux
        /// root: `--rc` always means 9front's rc.
        nine_prog: bool = false,
        /// Whether the console is a terminal, for a Linux program's
        /// isatty: the CLI sets it when its stdin and stdout both are.
        console_tty: bool = true,
        /// An `/etc/passwd`-format file's contents, mapping user names to
        /// the numbers a 9P2000.L server is sent (design/0022-dotl.md,
        /// "The user map"). Without it, the machine's user is the host's
        /// uid, never 0.
        user_map: ?[]const u8 = null,
        /// Proxies for host-made connections; null goes direct. The CLI
        /// fills it from HTTPS_PROXY, HTTP_PROXY and NO_PROXY.
        proxy: ?Proxy = null,
        /// Host directory bound at /mnt/term/cwd and made the guest's cwd.
        cwd: ?[]const u8 = null,
        /// Guest environment variables, beyond the defaults.
        env: []const EnvVar = &.{},
        /// The sandbox policy (SPEC.md, "Sandbox policy"). Host paths in
        /// it, like `root` and `cwd`, must be absolute and resolved.
        policy: policy.Policy = .{},
        /// Bind h9's own commands, `#H/bin`, after /bin; false leaves the
        /// bind out and masks `#H` (design/0032-guest-tools.md).
        guest_tools: bool = true,
        /// The built-in root, `#Hroot` (design/0087-builtin-root.md): `.only`
        /// makes it the root, and needs `root` null; `.before` and
        /// `.after` bind its commands before or after another root's
        /// /bin, and without one make it the root. `.off` leaves a machine
        /// without `root` with devices only.
        builtin: policy.Builtin = .off,
        /// Receives a ratrace-style line per syscall.
        trace: ?*std.Io.Writer = null,
        /// On a fault, print the Ureg and a symbolized PC to `stdio.err`.
        dump_on_fault: bool = false,
        /// A namespace file (newns syntax, src/newns.zig) to replay in the
        /// first process after the policy's namespace is built and before
        /// the program is looked up. It's a guest path, read as newns
        /// would, so a relative one is in the guest's cwd.
        ns: ?[]const u8 = null,
        /// How many processes may own a vCPU before the rest share the
        /// pool (src/cpupool.zig); null means the backend's limit less the
        /// pool. For tests of the pool.
        owned_vcpus: ?u32 = null,
        /// Host events to deliver while a run is in progress (Ctrl-C,
        /// hangup); see `Signals`.
        signals: ?*Signals = null,
        /// A host window (design/0015-gfx.md): `#i`, `#m` and `#b` on
        /// /dev, drawn by the GUI backend built in. One machine in the
        /// process can have it at a time; closing the window is a hangup.
        /// On macOS the program must run `h9.gfx.main` on its main thread.
        gfx: ?Gfx = null,
        /// Listeners that serve the machine's namespace over 9P while a run
        /// is in progress, each connection with its own exportfs
        /// (design/0035-serve.md). With an empty `argv`, `run` only serves,
        /// until a note ends it.
        serve: []const Listen = &.{},
        /// The guest path each connection exports.
        serve_root: []const u8 = "/",
        /// Required on WebSocket listeners when set.
        serve_token: ?[]const u8 = null,
        /// Origins WebSocket listeners accept; "*" for any.
        serve_origins: []const []const u8 = &.{},
        /// Export `/net` too; without it, clients don't see it.
        serve_net: bool = false,
        stdio: Stdio,
    };

    pub const Gfx = gfx.Options;

    /// Host events an embedder delivers to a running machine, from any
    /// thread, including a signal handler's watcher (SPEC.md, "Signals
    /// and TTY"). Each call only sets a flag and wakes `run`, which posts
    /// the notes. Calls while no run is in progress are dropped.
    pub const Signals = struct {
        /// Bumped by each call, for `run` to wait on.
        seq: std.atomic.Value(u32) = .init(0),
        pending: std.atomic.Value(u8) = .init(0),

        const interrupt_bit = 1;
        const hangup_bit = 2;
        const stop_bit = 4;

        /// Posts `interrupt` to the foreground note group (Ctrl-C).
        pub fn interrupt(s: *Signals, io: std.Io) void {
            s.raise(io, interrupt_bit);
        }

        /// Posts `hangup` to every process, then tears the machine down
        /// after the grace period (terminal closed, SIGTERM).
        pub fn hangup(s: *Signals, io: std.Io) void {
            s.raise(io, hangup_bit);
        }

        /// Tears the machine down at once (a second Ctrl-C).
        pub fn stop(s: *Signals, io: std.Io) void {
            s.raise(io, stop_bit);
        }

        fn raise(s: *Signals, io: std.Io, bit: u8) void {
            _ = s.pending.fetchOr(bit, .acq_rel);
            _ = s.seq.fetchAdd(1, .release);
            io.futexWake(u32, &s.seq.raw, 1);
        }
    };

    pub const InitError = vmm.CreateError || gfx.Error || error{PolicyConflict};

    /// Host streams behind the guest's console: reads from `in` (none means
    /// EOF), writes to fd 1 go to `out` and to fd 2 to `err`.
    pub const Stdio = struct {
        in: ?*std.Io.Reader = null,
        /// Makes a blocked read of `in` return, so a run can end while a
        /// console read is pending. Without it such a run ends `stuck`.
        in_cancel: ?consin.Cancel = null,
        out: *std.Io.Writer,
        err: *std.Io.Writer,
        /// Called when the guest turns raw mode on or off (writing `rawon`
        /// or `rawoff` to /dev/consctl, or closing its last consctl), and
        /// echo (`echooff`, `echoon`). The CLI puts the host terminal in
        /// raw mode or turns its echo off. The machine turns both back
        /// when a run ends.
        raw: ?Raw = null,
    };

    pub const Raw = kern.Console.Raw;

    gpa: std.mem.Allocator,
    io: std.Io,
    backend: vmm.Backend,
    arch: vmm.Arch,
    opts: Options,
    /// The compiled policy; allocated in `arena`.
    plan: policy.Plan,
    arena: *std.heap.ArenaAllocator,
    msg_buf: [256]u8 = undefined,
    err_buf: [256]u8 = undefined,
    /// Why the last run failed with NamespaceFailed, NotFound or NotExecutable,
    /// or why init failed with PolicyConflict.
    err_msg: []const u8 = "",
    /// Set when a timed-out process couldn't be torn down; see `run`.
    stuck: bool = false,
    /// Holds a returned status message or `err_msg`.
    out_buf: [256]u8 = undefined,
    /// What the last run's guest changed in the root's overlay, discarded
    /// with it (design/0011-overlay.md); empty without one.
    root_changes: RootChanges = .{},
    /// The machine's claim on the screen, with `Options.gfx`; in `arena`.
    gfx_claim: ?*gfx.Claim = null,
    /// The listeners' bound addresses, once a run has opened them; in
    /// `arena`.
    serve_addrs: []const []const u8 = &.{},

    /// Each `serve` listener's bound address, in the order given, with
    /// port 0 resolved, once a run has opened them; empty before.
    pub fn serving(m: *const Machine) []const []const u8 {
        return m.serve_addrs;
    }

    /// Compiles a policy for a machine with these options, as `init` does,
    /// without creating one (for `--print`).
    pub fn compilePlan(arena: std.mem.Allocator, opts: Options, err_msg: *[]const u8) policy.CompileError!policy.Plan {
        const arch = opts.arch orelse vmm.host_arch orelse .arm64;
        var in: policy.Inputs = .{ .root = null, .cwd = opts.cwd, .arch = arch, .guest_tools = opts.guest_tools, .root_contained = opts.root_contained, .linux_root = opts.linux_root, .nameservers = opts.nameservers, .builtin = opts.builtin };
        if (opts.serve.len > 0) {
            const ls = try arena.alloc(policy.Serve.Listener, opts.serve.len);
            for (ls, opts.serve) |*l, a| l.* = .{
                .addr = try std.fmt.allocPrint(arena, "{f}", .{a}),
                .kind = switch (a) {
                    .unix => .unix,
                    .tcp => .tcp,
                    .ws => .ws,
                },
            };
            in.serve = .{ .listeners = ls, .root = opts.serve_root, .token = opts.serve_token != null, .origins = opts.serve_origins, .net = opts.serve_net, .only = false };
        }
        if (opts.builtin != .off) in.builtin_note = try builtin_root.describe(arena);
        if (opts.gfx) |g| in.gfx = .{ .backend = @tagName(gfx.backend), .clipboard = g.clipboard, .scale = g.scale };
        if (opts.root) |r| switch (r) {
            .dir => |d| in.root = d,
            .tcp => |a| in.root_9p = .{ .kind = .tcp, .addr = a, .spec = opts.root_spec, .user = opts.root_user },
            .unix => |path| in.root_9p = .{
                .kind = .unix,
                .addr = try std.fmt.allocPrint(arena, "unix!{s}", .{path}),
                .spec = opts.root_spec,
                .user = opts.root_user,
            },
            .ws => |u| in.root_9p = .{
                .kind = .ws,
                .addr = u,
                .spec = opts.root_spec,
                .user = opts.root_user,
                .headers = opts.root_headers,
                .ca = opts.root_ca,
                .proxy = if (opts.proxy) |px| if (ws.Url.parse(u)) |url| px.pick(url) else |_| null else null,
            },
        };
        return policy.compile(arena, in, opts.policy, err_msg);
    }

    /// On PolicyConflict, `conflict` (if given) explains it.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) InitError!Machine {
        return initExplained(gpa, io, opts, null);
    }

    pub fn initExplained(gpa: std.mem.Allocator, io: std.Io, opts: Options, conflict: ?*[]const u8) InitError!Machine {
        const arch = opts.arch orelse vmm.host_arch orelse return error.WrongArch;
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }
        var msg: []const u8 = "";
        const plan = compilePlan(arena.allocator(), opts, &msg) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Conflict => {
                if (conflict) |c| c.* = msg;
                return error.PolicyConflict;
            },
        };
        var o = opts;
        var claim: ?*gfx.Claim = null;
        if (opts.gfx) |g| {
            // Closing the window is a hangup, so a machine without
            // Signals gets its own.
            const sig = o.signals orelse blk: {
                const s = try arena.allocator().create(Signals);
                s.* = .{};
                break :blk s;
            };
            o.signals = sig;
            const cl = try arena.allocator().create(GfxClose);
            cl.* = .{ .signals = sig, .io = io, .claim = .{ .ctx = cl, .close = GfxClose.close } };
            try gfx.acquire(io, &cl.claim, g);
            claim = &cl.claim;
        }
        errdefer if (claim) |cl| gfx.release(cl);
        const backend = try vmm.create(gpa, io, opts.backend, .{ .arch = arch, .memory = plan.memory });
        return .{ .gpa = gpa, .io = io, .opts = o, .arch = arch, .backend = backend, .plan = plan, .arena = arena, .gfx_claim = claim };
    }

    /// What closing the window does: a hangup, as for a closed terminal.
    const GfxClose = struct {
        signals: *Signals,
        io: std.Io,
        claim: gfx.Claim,

        fn close(ctx: *anyopaque) void {
            const g: *GfxClose = @ptrCast(@alignCast(ctx));
            g.signals.hangup(g.io);
        }
    };

    pub fn deinit(m: *Machine) void {
        // A stuck process still uses the backend and the plan, so they're
        // leaked rather than freed under it.
        if (m.stuck) return;
        if (m.gfx_claim) |cl| gfx.release(cl);
        m.backend.destroy();
        m.arena.deinit();
        m.gpa.destroy(m.arena);
    }

    /// The CPUs the machine may use, as /dev/sysstat lists them and
    /// `$NPROC` says: `--cpus`
    /// when given, else the host's CPU count, capped by the backend's vCPU
    /// limit.
    fn cpuCount(m: *const Machine) u32 {
        const host: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, std.math.maxInt(u32)));
        const want = m.plan.cpus orelse host;
        const max = m.backend.maxVcpus() catch want;
        return @max(1, @min(want, max));
    }

    /// Runs a program to completion. `argv[0]` is the program's name as it
    /// sees it.
    ///
    /// With a timeout in the policy, the process is stopped at the deadline:
    /// its vCPU is kicked and any blocking kernel call is interrupted, and
    /// it's killed with "h9: timeout". A console read waits in the kernel,
    /// so it's interrupted too, and the console's reader thread is stopped
    /// with `Stdio.in_cancel`. If a process is stuck in a host call that
    /// can't be interrupted, or `in` has no cancel and is blocked in a read,
    /// `run` returns after a short grace period anyway and the machine is
    /// left `stuck`: the
    /// backend, plan and run state are leaked rather than freed under the
    /// process, and the Machine itself may be dropped. The process can
    /// still touch `argv`, the program bytes, `Stdio` and the trace writer
    /// when its host call returns, so an embedder must keep those alive or
    /// exit, as the CLI does.
    pub fn run(m: *Machine, prog: Program, argv: []const []const u8) RunError!Status {
        if (m.stuck) return error.Stuck;
        m.root_changes = .{};
        // The listeners are bound before anything runs, so one that can't
        // listen ends the run here (design/0035-serve.md, "Flags").
        // The browser host can't listen, so its build leaves serving out.
        const srv: ?*serve.Server = if (comptime web.enabled) null else if (m.opts.serve.len > 0) blk: {
            var len: usize = 0;
            const s = serve.open(m.gpa, m.io, .{
                .listens = m.opts.serve,
                .token = m.opts.serve_token,
                .origins = m.opts.serve_origins,
                .trace = m.opts.trace,
            }, &m.msg_buf, &len) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ServeFailed => {
                    m.err_msg = m.msg_buf[0..len];
                    return error.ServeFailed;
                },
            };
            const a = m.arena.allocator();
            const addrs = a.alloc([]const u8, s.serving().len) catch {
                s.close();
                return error.OutOfMemory;
            };
            for (addrs, s.serving()) |*d, src| d.* = a.dupe(u8, src) catch {
                s.close();
                return error.OutOfMemory;
            };
            m.serve_addrs = addrs;
            // A port the host picked is printed, so a caller can find it.
            for (m.opts.serve, addrs) |l, b| if (l.port() == 0) {
                m.opts.stdio.err.print("serve: {s}\n", .{b}) catch {};
                m.opts.stdio.err.flush() catch {};
            };
            break :blk s;
        } else null;
        defer if (srv) |s| s.close();
        // Heap-allocated, with its own copy of the machine, so a stuck
        // process never refers to the caller's Machine.
        const job = try m.gpa.create(Job);
        const pool = cpupool.Pool.init(m.gpa, m.io, m.backend, m.plan.cpus, m.opts.owned_vcpus) catch |e| {
            m.gpa.destroy(job);
            return e;
        };
        job.* = .{ .m = undefined, .mc = m.*, .prog = prog, .argv = argv, .con = .{ .in = null, .out = m.opts.stdio.out, .err = m.opts.stdio.err, .raw = m.opts.stdio.raw }, .pool = pool, .srv = srv };
        if (srv) |s| s.cfg.trace_lock = &job.trace_lock;
        job.pool.gpa = m.gpa;
        job.ncpu = m.cpuCount();
        kern.setNoteKick(Proc.noteKick);
        kern.setProcStatus(Proc.status);
        kern.setProcThreads(Proc.threads);
        kern.setWantChld(Proc.wantChld);
        kern.setProcSegment(Proc.segments);
        kern.setStopKick(Proc.stopKick);
        kern.setProcDebug(Proc.debug);
        kc.setGen(linuxGen);
        job.start_ns = kern.monoNs();
        job.m = &job.mc;
        job.pages = .{ .ctx = job, .alloc = Job.allocPages, .free = Job.freePages };
        job.mc.err_msg = "";
        job.con_id = kern.addConsole(&job.con) catch |e| {
            m.gpa.destroy(job);
            return e;
        };
        if (m.opts.stdio.in) |src| {
            job.con_in = .{ .io = m.io, .src = src, .cancel = m.opts.stdio.in_cancel, .id = job.con_id, .wake = kern.wakeConsole };
            job.con.in = &job.con_in.?;
        }
        const first = job.newProc(.program) catch |e| {
            kern.removeConsole(job.con_id);
            job.pool.deinit();
            m.gpa.destroy(job);
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.TooManyProcs => unreachable, // the cap is at least 1
            };
        };
        kern.spawn("h9", Proc, firstMain, first) catch |e| {
            job.dropProc(first);
            kern.removeConsole(job.con_id);
            job.procs.deinit(m.gpa);
            job.pool.deinit();
            m.gpa.destroy(job);
            return e;
        };

        const timed_out = job.waitFirst();
        // The machine ends with its first process: any others are stopped,
        // as at a timeout.
        job.stopAll();
        if (!job.waitAll()) {
            m.stuck = true;
            m.root_changes = job.rootChanges();
            kern.removeConsole(job.con_id);
            job.con.reset();
            return .{ .killed = if (timed_out) timeout_note else stopped_note };
        }
        kern.removeConsole(job.con_id);
        job.con.reset();
        m.root_changes = job.rootChanges();
        if (job.mach.load(.acquire)) |mc| {
            dotl.unregister(@intFromPtr(mc));
            mc.put();
        }
        // No process reads the console now. A reader thread still in a
        // host read that can't be cancelled keeps the Job, leaked.
        const freed = if (job.con_in) |*in| in.stop(grace_ms) else true;
        if (!freed) m.stuck = true;
        defer if (freed) {
            job.procs.deinit(m.gpa);
            job.pool.deinit();
            m.gpa.destroy(job);
        };
        if (timed_out) return .{ .killed = timeout_note };
        m.err_msg = m.copyOut(job.mc.err_msg);
        const st = job.result catch |e| return e;
        return switch (st) {
            .exited => |t| .{ .exited = m.copyOut(t) },
            .killed => |t| .{ .killed = m.copyOut(t) },
        };
    }

    fn copyOut(m: *Machine, t: []const u8) []const u8 {
        const n = @min(t.len, m.out_buf.len);
        @memmove(m.out_buf[0..n], t[0..n]);
        return m.out_buf[0..n];
    }

    const timeout_note = "h9: timeout";
    const stopped_note = "h9: machine stopped";
    const grace_ms = 500;
    /// How long, past `grace_ms`, the machine waits for processes that
    /// are only tearing down.
    const teardown_ms = 30_000;
    /// How long processes have to handle `hangup` (at a timeout, a closed
    /// terminal or SIGTERM) before the machine is torn down. Shorter than
    /// the 5 s Windows gives a console process after CTRL_CLOSE_EVENT.
    const hangup_grace_ms = 2000;

    /// One run of the machine: its process tree and console.
    const Job = struct {
        /// Points at `mc`.
        m: *Machine,
        mc: Machine,
        /// The machine's pages for `#O` overlays: ephemeral files count
        /// against `--memory` (design/0006-ephemeral-writes.md).
        pages: kern.Pages = undefined,
        prog: Program,
        argv: []const []const u8,
        con: kern.Console,
        con_id: u32 = 0,
        /// The console's input, when Stdio has one.
        con_in: ?consin.ConsoleInput = null,
        /// The first process's outcome, set before `first_done`.
        result: RunError!Status = error.Kern,
        first_done: std.Io.Event = .unset,
        /// The kernel's machine, set by the first process once it's a
        /// kernel process, for posting host-side notes. `run` releases it.
        mach: std.atomic.Value(?*kern.Mach) = .init(null),
        /// Bumped when `first_done` is set, so `run` can wait on one
        /// futex for it and for `Signals`.
        wake: std.atomic.Value(u32) = .init(0),
        /// Set when the last process has exited.
        all_done: std.Io.Event = .unset,
        timed_out: std.atomic.Value(bool) = .init(false),
        /// Set to end every process; exit loops check it after every exit.
        stopping: std.atomic.Value(bool) = .init(false),
        /// Guards `procs`, `next_pid` and each Proc's `kproc` and `lease`.
        lock: std.atomic.Mutex = .unlocked,
        /// Live processes. A process is only made by a live one, so once
        /// this is empty it stays empty.
        procs: std.ArrayList(*Proc) = .empty,
        next_pid: u32 = 1,
        /// Of `procs`: the program's, and the server Proc and its
        /// descendants, each counted against `--pids` on its own
        /// (design/0035-serve.md, "Limits").
        n_program: u32 = 0,
        n_serving: u32 = 0,
        /// The listeners, with `--serve` (design/0035-serve.md).
        srv: ?*serve.Server = null,
        /// The exportfs the server Proc runs, as a guest path.
        exportfs_buf: [64]u8 = undefined,
        exportfs: []const u8 = "",
        trace_lock: std.atomic.Mutex = .unlocked,
        /// vCPUs for the processes.
        pool: cpupool.Pool,
        /// The CPUs /dev/sysstat lists (design/0007-go-compat.md).
        ncpu: u32 = 1,
        /// When the run started, for /proc/uptime.
        start_ns: i64 = 0,
        /// The guest's changes to the root's overlay, reported by #O once
        /// the namespace is built. Guarded by `changes_lock`.
        changes: RootChanges = .{},
        changes_lock: std.atomic.Mutex = .unlocked,
        /// `$home` relative to the root, `usr/<user>`, for `changes`.
        home_buf: [96]u8 = undefined,
        home: []const u8 = "",
        track: kern.OverlayTrack = undefined,

        fn rootChanged(ctx: *anyopaque, path: []const u8) void {
            const j: *Job = @ptrCast(@alignCast(ctx));
            while (!j.changes_lock.tryLock()) std.atomic.spinLoopHint();
            defer j.changes_lock.unlock();
            j.changes.note(path, j.home);
        }

        fn rootChanges(j: *Job) RootChanges {
            while (!j.changes_lock.tryLock()) std.atomic.spinLoopHint();
            defer j.changes_lock.unlock();
            return j.changes;
        }

        fn allocPages(ctx: *anyopaque, n: usize) ?[*]u8 {
            const j: *Job = @ptrCast(@alignCast(ctx));
            const mem = j.m.backend.allocPages(n / vmm.page_size) catch return null;
            return mem.ptr;
        }

        fn freePages(ctx: *anyopaque, p: [*]u8, n: usize) void {
            const j: *Job = @ptrCast(@alignCast(ctx));
            const a: [*]align(vmm.page_size) u8 = @alignCast(p);
            j.m.backend.freePages(a[0..n]);
        }

        fn lockSpin(j: *Job) void {
            while (!j.lock.tryLock()) std.atomic.spinLoopHint();
        }

        /// Wakes `run` to look at `first_done` again.
        fn wakeRun(j: *Job) void {
            _ = j.wake.fetchAdd(1, .release);
            j.m.io.futexWake(u32, &j.wake.raw, 1);
            if (j.m.opts.signals) |s| {
                _ = s.seq.fetchAdd(1, .release);
                j.m.io.futexWake(u32, &s.seq.raw, 1);
            }
        }

        /// Posts a host-side note, if the first process has started.
        fn post(j: *Job, to: kern.Mach.To, msg: [*:0]const u8) void {
            if (j.mach.load(.acquire)) |mc| _ = mc.post(to, msg);
        }

        /// Whose a new process is: the program's, or serving's, and then
        /// which connection's, if any (design/0035-serve.md).
        const Owner = union(enum) {
            program,
            serving: ?*Conn,
        };

        /// Allocates and registers a process with the next pid. Fails with
        /// TooManyProcs at the policy's `--pids` cap, which the program's
        /// processes and serving's are each counted against, or at a
        /// connection's cap.
        fn newProc(j: *Job, owner: Owner) error{ OutOfMemory, TooManyProcs }!*Proc {
            const gpa = j.m.gpa;
            const p = try gpa.create(Proc);
            errdefer gpa.destroy(p);
            j.lockSpin();
            defer j.lock.unlock();
            const n = switch (owner) {
                .program => &j.n_program,
                .serving => &j.n_serving,
            };
            if (j.m.plan.pids) |cap| if (n.* >= cap) return error.TooManyProcs;
            const conn: ?*Conn = switch (owner) {
                .program => null,
                .serving => |c| c,
            };
            if (conn) |c| if (c.live >= serve.conn_procs) return error.TooManyProcs;
            try j.procs.append(gpa, p);
            n.* += 1;
            if (conn) |c| c.live += 1;
            p.* = .{ .job = j, .pid = j.next_pid, .serving = owner == .serving, .conn = conn };
            j.next_pid += 1;
            return p;
        }

        /// Unregisters and frees a process that never ran.
        fn dropProc(j: *Job, p: *Proc) void {
            j.lockSpin();
            for (j.procs.items, 0..) |q, i| if (q == p) {
                _ = j.procs.swapRemove(i);
                break;
            };
            const ended = j.uncount(p);
            j.lock.unlock();
            if (ended) |c| j.connEnded(c);
            j.m.gpa.destroy(p);
        }

        /// Takes a leaving process out of the counts. Returns its
        /// connection if it was the connection's last. Called with `lock`
        /// held.
        fn uncount(j: *Job, p: *Proc) ?*Conn {
            if (!p.serving) {
                j.n_program -= 1;
                return null;
            }
            j.n_serving -= 1;
            const c = p.conn orelse return null;
            c.live -= 1;
            return if (c.live == 0) c else null;
        }

        /// A connection's last process is gone: it's no longer counted
        /// against the cap of 32.
        fn connEnded(j: *Job, c: *Conn) void {
            if (j.srv) |s| s.connEnded();
            j.m.gpa.destroy(c);
        }

        /// Waits for the first process to exit, delivering host signals
        /// meanwhile. At the timeout or a hangup, posts `hangup` to every
        /// process and gives them `hangup_grace_ms` to finish before the
        /// teardown. Returns whether the run reached its timeout.
        fn waitFirst(j: *Job) bool {
            const m = j.m;
            const io = m.io;
            const sig = m.opts.signals;
            const futex = if (sig) |s| &s.seq.raw else &j.wake.raw;
            var deadline: ?std.Io.Timestamp = if (m.plan.timeout_ns) |ns| std.Io.Timestamp.now(io, .awake).addDuration(.fromNanoseconds(ns)) else null;
            var hung_up = false;
            while (true) {
                const seq = @atomicLoad(u32, futex, .acquire);
                if (j.first_done.isSet()) break;
                if (sig) |s| {
                    const bits = s.pending.swap(0, .acq_rel);
                    if (bits & Signals.stop_bit != 0) break;
                    if (bits & Signals.interrupt_bit != 0) j.post(.foreground, "interrupt");
                    if (bits & Signals.hangup_bit != 0 and !hung_up) {
                        hung_up = true;
                        j.post(.all, "hangup");
                        deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(hangup_grace_ms));
                    }
                }
                const d = deadline orelse {
                    io.futexWaitUncancelable(u32, futex, seq);
                    continue;
                };
                const left = std.Io.Timestamp.now(io, .awake).durationTo(d);
                if (left.nanoseconds > 0) {
                    io.futexWaitTimeout(u32, futex, seq, .{ .duration = .{ .raw = left, .clock = .awake } }) catch {};
                    continue;
                }
                // The grace period after a hangup is over.
                if (hung_up) break;
                // The timeout: hangup first, then the grace period.
                hung_up = true;
                j.timed_out.store(true, .release);
                j.post(.all, "hangup");
                deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(hangup_grace_ms));
            }
            return j.timed_out.load(.acquire);
        }

        /// Stops every process: kicks vCPUs and interrupts blocking
        /// kernel calls. Safe from any thread.
        fn stopAll(j: *Job) void {
            j.stopping.store(true, .release);
            if (j.srv) |s| s.stop();
            // Host commands die with the machine. A process reading one's
            // output waits in a host read no interrupt reaches; this ends it.
            if (j.mach.load(.acquire)) |mc| mc.endHostCmds();
            j.lockSpin();
            defer j.lock.unlock();
            for (j.procs.items) |p| {
                if (p.lease) |l| l.kick();
                if (p.kproc) |k| kern.interrupt(k);
            }
        }

        /// Waits for every process to exit after `stopAll`, kicking again
        /// for a grace period. Returns false if some are stuck.
        fn waitAll(j: *Job) bool {
            var waited: u32 = 0;
            while (waited < grace_ms) : (waited += 10) {
                const tick: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(10), .clock = .awake };
                if (j.all_done.waitTimeout(j.m.io, .{ .duration = tick })) |_| return true else |_| j.stopAll();
            }
            // Processes already tearing down aren't stuck, only slow: an
            // emulator engine with thousands of regions takes seconds to
            // close. Wait for those, up to a bound.
            while (waited < teardown_ms and j.allExiting()) : (waited += 10) {
                const tick: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(10), .clock = .awake };
                if (j.all_done.waitTimeout(j.m.io, .{ .duration = tick })) |_| return true else |_| {}
            }
            return j.all_done.isSet();
        }

        fn allExiting(j: *Job) bool {
            j.lockSpin();
            defer j.lock.unlock();
            for (j.procs.items) |p| if (!p.exiting) return false;
            return true;
        }
    };

    /// One served connection (design/0035-serve.md): how many processes
    /// its exportfs and their children have, up to `serve.conn_procs`.
    /// Guarded by `Job.lock`; freed with its last process.
    const Conn = struct {
        live: u32 = 0,
    };

    /// One guest process: a kernel process with its own host thread, an
    /// address space and segments, and a vCPU while it runs.
    const Proc = struct {
        job: *Job,
        /// Machine-local pid.
        pid: u32,
        /// The server Proc or one of its descendants (design/0035-serve.md),
        /// counted apart from the program's processes.
        serving: bool = false,
        /// The connection a serving process belongs to, if any.
        conn: ?*Conn = null,
        /// For a connection's first process: its stream's fd, which
        /// becomes fds 0 and 1 before exportfs runs.
        serve_fd: ?u31 = null,
        /// Set on the process's own thread; guarded by `job.lock`.
        kproc: ?*kern.Proc = null,
        /// How it runs guest code, while it does.
        lease: ?*cpupool.Lease = null,
        lease_store: cpupool.Lease = undefined,
        as: ?vmm.AddressSpace = null,
        segs: segment.Segs = .{},
        sys: syscall.Process = undefined,
        /// Registers to start from.
        ureg: vmm.Ureg = undefined,
        extra: vmm.Extra = .{ .arm64 = .{} },
        /// The Tos address, for the pid at fork.
        tos: u64 = 0,
        /// The a.out, for symbolizing faults with dump_on_fault.
        image: ?[]u8 = null,
        msg_buf: [256]u8 = undefined,
        /// Set under `job.lock` once the process is tearing down
        /// (`Job.waitAll`).
        exiting: bool = false,
        /// Set when a note may be waiting: by the kernel's kick hook when a
        /// note is posted to the process, and after noted. The exit loop
        /// checks it before each run.
        note_flag: std.atomic.Value(bool) = .init(false),
        /// The guest address of the Ureg saved for the note handler, or 0
        /// (9front's noteureg); the word under each saved Ureg holds the
        /// one before it.
        noteureg: u64 = 0,
        /// The FP/SIMD state when the handler was entered, which noted
        /// restores (9front's fpunotify and fpunoted).
        note_extra: ?vmm.Extra = null,
        /// For /proc/n/status: the syscall being served plus 1, or 0 while
        /// running guest code, and the mapped memory in KiB.
        in_sys: web.Atomic(u64) = .init(0),
        mem_kb: web.Atomic(u64) = .init(0),
        /// The Linux personality's state, while the process runs a Linux
        /// binary (design/0018-linux-personality.md). Its Mm owns `as`.
        lx: ?*lsys.Process = null,
        /// Set in a vfork child: its parent waits on it until the child
        /// execs or exits.
        vfork_done: ?*std.Io.Event = null,
        /// Set by the stop kick hook when a debugger asks the process to
        /// stop, so the exit loop asks the kernel at its next stop point.
        stop_flag: std.atomic.Value(bool) = .init(false),
        /// Debugging state (design/0010-self-host.md), guarded by
        /// `dbg_lock`, which /proc/n/mem, regs and fpregs take on the
        /// reading thread. It also guards `as` against exec swapping it.
        dbg_lock: std.atomic.Mutex = .unlocked,
        /// The registers at the last syscall entry, or at the stop while
        /// `dbg_stopped`; /proc/n/regs serves them in a syscall
        /// (`in_sys`) or stopped, as 9front serves its dbgreg.
        dbg_ureg: vmm.Ureg = undefined,
        /// The FP registers while `dbg_stopped`.
        dbg_extra: vmm.Extra = undefined,
        dbg_stopped: bool = false,
        /// A debugger wrote `dbg_ureg` or `dbg_extra` while stopped.
        dbg_ureg_set: bool = false,
        dbg_extra_set: bool = false,

        fn dbgLock(p: *Proc) void {
            while (!p.dbg_lock.tryLock()) std.atomic.spinLoopHint();
        }

        fn noteMem(p: *Proc) void {
            const n = if (p.lx) |l| l.mm.bytes() else p.segs.mapped();
            p.mem_kb.store(n / 1024, .release);
        }

        /// Wakes a vfork parent.
        fn vforkRelease(p: *Proc) void {
            if (p.vfork_done) |ev| {
                p.vfork_done = null;
                ev.set(p.job.m.io);
            }
        }

        /// Drops the Linux state and its address space.
        fn dropLinux(p: *Proc) void {
            const l = p.lx orelse return;
            p.job.lockSpin();
            p.lx = null;
            p.job.lock.unlock();
            const m = l.mm;
            l.deinit();
            p.job.m.gpa.destroy(l);
            m.put();
            p.as = null;
        }

        /// The kernel's hook for /proc/n/segment. Runs on the reading
        /// thread.
        fn segments(aux: ?*anyopaque, buf: [*]u8, n: c_int) callconv(.c) c_int {
            const p: *Proc = @ptrCast(@alignCast(aux orelse return 0));
            return @intCast(p.segs.segmentText(buf[0..@intCast(n)]));
        }

        /// The kernel's hook for /proc/n/status: the state, as 9front's
        /// psstate (the syscall's name, capitalized, or Running), and the
        /// memory. Runs on the reading thread.
        fn status(aux: ?*anyopaque, buf: [*]u8, n: c_int, mem: *c_uint) callconv(.c) void {
            const p: *Proc = @ptrCast(@alignCast(aux orelse return));
            mem.* = @truncate(p.mem_kb.load(.acquire));
            const out = buf[0..@intCast(n)];
            const nr = p.in_sys.load(.acquire);
            var name: []const u8 = "Running";
            if (nr != 0) name = std.enums.tagName(syscall.Nr, @enumFromInt(nr - 1)) orelse "Syscall";
            const len = @min(name.len, out.len - 1);
            @memcpy(out[0..len], name[0..len]);
            if (nr != 0 and len > 0) out[0] = std.ascii.toUpper(out[0]);
            out[len] = 0;
        }

        /// The kernel's hook for Linux's /proc/n/status: the thread group
        /// and its size (design/0049-linux-threads.md).
        fn threads(aux: ?*anyopaque, tgid: *c_uint, n: *c_uint) callconv(.c) void {
            const p: *Proc = @ptrCast(@alignCast(aux orelse return));
            p.job.lockSpin();
            defer p.job.lock.unlock();
            const l = p.lx orelse return;
            tgid.* = @intCast(l.tgid());
            n.* = @intCast(l.g.count());
        }

        /// A Linux parent gets SIGCHLD when a child exits, unless it
        /// ignores it.
        fn wantChld(aux: ?*anyopaque) callconv(.c) c_int {
            const p: *Proc = @ptrCast(@alignCast(aux orelse return 0));
            const l = p.lx orelse return 0;
            return @intFromBool(lsys.load64(&l.sig.actions[lsig.SIGCHLD].handler) != lsig.SIG_IGN);
        }

        fn setKproc(p: *Proc) void {
            {
                p.job.lockSpin();
                defer p.job.lock.unlock();
                p.kproc = kern.self();
            }
            // From now on a note posted to the process kicks it; one posted
            // before (to a child just forked, say) is caught here.
            kern.setAux(p);
            if (kern.notePending()) p.note_flag.store(true, .release);
        }

        /// The kernel's hook for a note posted to process `aux`: flags it,
        /// and kicks its vCPU if it's running guest code, so the exit loop
        /// delivers the note. Runs on the posting thread.
        fn noteKick(aux: ?*anyopaque) callconv(.c) void {
            const p: *Proc = @ptrCast(@alignCast(aux orelse return));
            p.note_flag.store(true, .release);
            p.job.lockSpin();
            defer p.job.lock.unlock();
            if (p.lease) |l| l.kick();
        }

        /// The kernel's hook for ctl stop and startstop: flags process
        /// `aux` to check for a stop request, and kicks it out of guest
        /// code. Runs on the debugger's thread, as `noteKick` does.
        fn stopKick(aux: ?*anyopaque) callconv(.c) void {
            const p: *Proc = @ptrCast(@alignCast(aux orelse return));
            p.stop_flag.store(true, .release);
            p.job.lockSpin();
            defer p.job.lock.unlock();
            if (p.lease) |l| l.kick();
        }

        /// The kernel's hook for /proc/n/mem, regs and fpregs. Runs on the
        /// reading or writing thread with the target's note lock held,
        /// and only while it's set as `aux`, so the Proc is alive.
        fn debug(aux: ?*anyopaque, file: c_int, write: c_int, off: u64, buf: ?*anyopaque, n: c_long) callconv(.c) c_long {
            const p: *Proc = @ptrCast(@alignCast(aux orelse return 0));
            const b: [*]u8 = @ptrCast(buf orelse return 0);
            const data = b[0..@intCast(@max(n, 0))];
            p.dbgLock();
            defer p.dbg_lock.unlock();
            const r: kern.DebugError!usize = switch (@as(kern.DebugFile, @enumFromInt(file))) {
                .mem => p.memIo(off, data, write != 0),
                .regs => p.regsIo(off, data, write != 0),
                .fpregs => p.fpregsIo(off, data, write != 0),
            };
            return if (r) |got| @intCast(got) else |e| kern.debugCode(e);
        }

        /// /proc/n/mem: the process's memory at `addr`, as 9front's
        /// procctlmemio, through its address space, so only what's mapped
        /// there. A write into text first gives the process its own copy
        /// of the text (9front's txt2data), then makes its vCPU fetch the
        /// new code. Called with `dbg_lock` held.
        fn memIo(p: *Proc, addr: u64, data: []u8, write: bool) kern.DebugError!usize {
            const as = p.as orelse return error.BadAddress;
            const text = write and (p.segs.ownText(as, addr, data.len) catch return error.NoMemory);
            var done: usize = 0;
            while (done < data.len) {
                const va = addr +% done;
                if (va < addr) break;
                const chunk = @min(data.len - done, vmm.page_size - va % vmm.page_size);
                if (!as.copy(va, data[done..][0..chunk], if (write) .write else .read)) break;
                done += chunk;
            }
            if (done == 0 and data.len > 0) return error.BadAddress;
            if (text) as.codeChanged(addr, done);
            return done;
        }

        /// /proc/n/regs: the saved Ureg, in a syscall or stopped. A write
        /// (only while stopped) goes through the architecture's sanitize,
        /// as noted's does, so it can't set privileged state.
        fn regsIo(p: *Proc, off: u64, data: []u8, write: bool) kern.DebugError!usize {
            if (!p.dbg_stopped and p.in_sys.load(.acquire) == 0) return error.NoRegs;
            const cur = p.dbg_ureg.bytes();
            if (off >= cur.len) return 0;
            const o: usize = @intCast(off);
            const n = @min(data.len, cur.len - o);
            if (!write) {
                @memcpy(data[0..n], cur[o..][0..n]);
                return n;
            }
            var tmp: [@sizeOf(vmm.Ureg)]u8 = undefined;
            @memcpy(tmp[0..cur.len], cur);
            @memcpy(tmp[o..][0..n], data[0..n]);
            p.dbg_ureg = p.dbg_ureg.restored(tmp[0..cur.len]);
            p.dbg_ureg_set = true;
            return n;
        }

        /// /proc/n/fpregs: the FP registers in 9front's FPsave layout,
        /// while stopped.
        fn fpregsIo(p: *Proc, off: u64, data: []u8, write: bool) kern.DebugError!usize {
            if (!p.dbg_stopped) return error.NoRegs;
            var buf: [fpsave_max]u8 = undefined;
            const img = fpsave(&p.dbg_extra, &buf);
            if (off >= img.len) return 0;
            const o: usize = @intCast(off);
            const n = @min(data.len, img.len - o);
            if (!write) {
                @memcpy(data[0..n], img[o..][0..n]);
                return n;
            }
            @memcpy(img[o..][0..n], data[0..n]);
            setFpsave(&p.dbg_extra, img);
            p.dbg_extra_set = true;
            return n;
        }

        fn setLease(p: *Proc, l: ?*cpupool.Lease) void {
            p.job.lockSpin();
            defer p.job.lock.unlock();
            p.lease = l;
        }

        fn initSys(p: *Proc) void {
            const m = p.job.m;
            p.sys = .{
                .pid = p.pid,
                .gpa = m.gpa,
                .backend = m.backend,
                .as = p.as.?,
                .segs = &p.segs,
                .trace = m.opts.trace,
                .trace_lock = &p.job.trace_lock,
            };
        }

        /// Copies a note into the process's message buffer, for its status.
        fn keepNote(p: *Proc, msg: *const [kern.ERRMAX]u8) []const u8 {
            const t = std.mem.sliceTo(msg, 0);
            @memcpy(p.msg_buf[0..t.len], t);
            return p.msg_buf[0..t.len];
        }

        fn keepImage(p: *Proc, bytes: []const u8) void {
            if (p.image) |old| p.job.m.gpa.free(old);
            p.image = if (p.job.m.opts.dump_on_fault) p.job.m.gpa.dupe(u8, bytes) catch null else null;
        }

        /// Frees the process and unregisters it. Called last on its thread;
        /// the job may be gone once it returns.
        fn exit(p: *Proc) void {
            const j = p.job;
            const gpa = j.m.gpa;
            const io = j.m.io;
            j.lockSpin();
            p.exiting = true;
            j.lock.unlock();
            // No kick hook may run on the Proc once it's freed.
            kern.setAux(null);
            if (p.lease) |l| {
                p.setLease(null);
                l.release();
            }
            p.vforkRelease();
            if (p.lx != null) {
                p.dropLinux();
            } else if (p.as) |as| {
                p.segs.release(as);
                as.destroy();
            }
            // The namespace and fds can hold overlays, whose pages are the
            // machine's: they go now, not after the machine stops waiting.
            // After the memory, since the last unmap of a shared file
            // mapping writes it back by path, through the namespace.
            kern.release();
            if (p.image) |b| gpa.free(b);
            j.lockSpin();
            for (j.procs.items, 0..) |q, i| if (q == p) {
                _ = j.procs.swapRemove(i);
                break;
            };
            const empty = j.procs.items.len == 0;
            const ended = j.uncount(p);
            j.lock.unlock();
            if (ended) |c| j.connEnded(c);
            gpa.destroy(p);
            if (empty) j.all_done.set(io);
        }
    };

    /// The first process's thread: builds the namespace, loads the program
    /// and runs it.
    fn firstMain(p: *Proc) void {
        const j = p.job;
        const m = j.m;
        // devfs checks this thread's accesses against the plan.
        kern.setPlan(&m.plan);
        kern.setPages(&j.pages);
        kern.setCpus(j.ncpu);
        kern.setGuestPid(p.pid);
        p.setKproc();
        const mc = kern.mach();
        j.mach.store(mc, .release);
        // What #ℓ's translators send as the machine's user.
        if (mc) |x| dotl.register(@intFromPtr(x), .{ .user = kern.user(), .user_map = m.opts.user_map, .io = m.io });
        const r = m.startFirst(p);
        // The status and err_msg can point into the Proc or its errstr,
        // which go when it exits.
        j.result = if (r) |st| switch (st) {
            .exited => |t| .{ .exited = m.keep(t) },
            .killed => |t| .{ .killed = m.keep(t) },
        } else |e| e;
        const e = m.err_msg;
        if (e.len > 0 and !(@intFromPtr(e.ptr) >= @intFromPtr(&m.msg_buf) and @intFromPtr(e.ptr) < @intFromPtr(&m.msg_buf) + m.msg_buf.len)) {
            m.err_msg = m.keep2(e);
        }
        j.first_done.set(m.io);
        j.wakeRun();
        p.exit();
    }

    /// Reads the first process's 9front program, following #!, and
    /// returns its bytes, with argv updated.
    fn loadNine(m: *Machine, p: *Proc, arena: std.mem.Allocator, name: []const u8, argv: *[]const []const u8, text_path: *?[]const u8) RunError![]const u8 {
        _ = p;
        const g = try m.readGuest(arena, name);
        const img = interpret(arena, g.path, g.bytes, argv.*) catch |err| {
            m.err_msg = switch (err) {
                error.NotFound => kern.errstr(),
                error.OutOfMemory => "no memory",
                else => ebadexec,
            };
            return if (err == error.NotFound) error.NotFound else error.NotExecutable;
        };
        argv.* = img.argv;
        text_path.* = img.path;
        return img.bytes;
    }

    fn startFirst(m: *Machine, p: *Proc) RunError!Status {
        const j = p.job;
        if (j.stopping.load(.acquire)) return .{ .killed = timeout_note };
        const built = try m.buildNamespace(j.con_id);
        const root_ov = built.root_overlay;
        if (m.opts.ns) |path| {
            var buf: [1024]u8 = undefined;
            const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return m.fail("--ns: name too long", .{});
            const text = readFile(m.gpa, z) catch return m.fail("--ns {s}: {s}", .{ path, kern.errstr() });
            defer m.gpa.free(text);
            const cd = try m.replayNamespace(text, j.con_id);
            // The cwd is a chan from before the replay. Without a `cd` of
            // its own, the replay ends in the cwd as its binds left it: an
            // overlay over / (design/0011-overlay.md) puts the cwd's
            // mount point under the overlay, and the replay's binds onto
            // it are made there.
            if (!cd) if (built.cwd) |at| kern.chdir(at) catch {};
        }
        // The guest's changes to the root count from here
        // (design/0011-overlay.md).
        if (root_ov) |id| {
            j.home = std.fmt.bufPrint(&j.home_buf, "usr/{s}", .{kern.user()}) catch "";
            j.track = .{ .ctx = j, .changed = Job.rootChanged };
            kern.overlayTrack(id, &j.track);
        }
        // The server Proc gets a copy of the namespace as it is now, the
        // plan's, before the program can change it (design/0035-serve.md).
        if (!web.enabled and j.srv != null) {
            try m.startServer(p);
            if (j.argv.len == 0) return serveOnly(j);
        }

        var arena: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena.deinit();
        // A guest program goes through #! as exec does, so `h9 man` runs
        // the rc script /rc/bin/man (bound on /bin) like a binary.
        var argv = j.argv;
        // The guest path of the binary, for /proc/n/text.
        var text_path: ?[]const u8 = null;
        const bytes = switch (j.prog) {
            .bytes => |b| b,
            .guest => |name| blk: {
                if (m.opts.linux_root != null and !m.opts.nine_prog) {
                    // In the Linux view (design/0018, "CLI and API").
                    const a = arena.allocator();
                    const envp = linuxEnv(a) catch return error.OutOfMemory;
                    var path_var: []const u8 = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
                    for (envp) |e| if (std.mem.startsWith(u8, e, "PATH=")) {
                        path_var = e[5..];
                    };
                    const found = findLinux(a, name, path_var) orelse {
                        m.err_msg = "file does not exist";
                        return error.NotFound;
                    };
                    // A 9front program named by its Linux path (/9/bin/ls)
                    // runs as it would from the 9front view.
                    const head = readLinux(a, found) catch "";
                    const nine = head.len > 0 and !elf.isElf(head) and !std.mem.startsWith(u8, head, "#!");
                    if (nine and std.mem.startsWith(u8, found, "/9/")) break :blk try m.loadNine(p, a, found[2..], &argv, &text_path);
                    var name_buf: [kern.ERRMAX]u8 = undefined;
                    kern.setText(std.fmt.bufPrintZ(&name_buf, "{s}", .{basename(found)}) catch "a.out");
                    m.linuxExecPath(p, null, found, argv, envp) catch {
                        m.err_msg = kern.errstr();
                        return if (attr.errno(m.err_msg) == attr.E.NOENT) error.NotFound else error.NotExecutable;
                    };
                    return m.loop(p);
                }
                break :blk try m.loadNine(p, arena.allocator(), name, &argv, &text_path);
            },
        };
        if (elf.isElf(bytes)) {
            const path = switch (j.prog) {
                .guest => |n| n,
                .bytes => if (j.argv.len > 0) j.argv[0] else "a.out",
            };
            const envp = linuxEnv(arena.allocator()) catch return error.OutOfMemory;
            m.execLinux(p, null, arena.allocator(), path, bytes, argv, envp) catch {
                m.err_msg = kern.errstr();
                return error.NotExecutable;
            };
            return m.loop(p);
        }
        const hdr = aout.parse(bytes) catch {
            m.err_msg = "not a 9front executable";
            return error.NotExecutable;
        };
        if (hdr.arch != m.arch) {
            m.err_msg = "wrong architecture";
            return error.NotExecutable;
        }
        var name_buf: [kern.ERRMAX]u8 = undefined;
        const name = switch (j.prog) {
            .guest => |n| n,
            .bytes => if (j.argv.len > 0) j.argv[0] else "a.out",
        };
        kern.setText(std.fmt.bufPrintZ(&name_buf, "{s}", .{basename(name)}) catch "a.out");

        p.as = try m.backend.newAddressSpace();
        const img = try loader.load(m.gpa, m.backend, p.as.?, bytes, argv, p.pid);
        // Under the lock, since /proc/n/segment may be read already.
        p.segs.replace(p.as.?, img.segs);
        p.tos = img.tos;
        p.ureg = .initExec(img.arch, img.entry, img.sp, img.tos);
        p.extra = .initExec(img.arch);
        p.keepImage(bytes);
        p.initSys();
        p.noteMem();
        kern.setArgs(argv);
        if (text_path) |t| kern.setTextPath(arena.allocator().dupeZ(u8, t) catch null);
        return m.loop(p);
    }

    /// Forks the server Proc (design/0035-serve.md, "Each connection"):
    /// a copy of the first Proc's namespace, without `/net` unless
    /// `serve_net`, in a note group of its own, with no wait record for
    /// the program to see. It runs no guest code; it takes each ready
    /// stream and forks an exportfs for it.
    fn startServer(m: *Machine, first: *Proc) RunError!void {
        const j = first.job;
        const p = j.newProc(.{ .serving = null }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooManyProcs => unreachable, // the cap is at least 1
        };
        const flags = kern.RF.PROC | kern.RF.NAMEG | kern.RF.FDG | kern.RF.ENVG | kern.RF.NOTEG | kern.RF.NOWAIT;
        kern.fork(flags, p.pid, Proc, serverMain, p) catch {
            j.dropProc(p);
            return m.fail("serve: can't start the server process: {s}", .{kern.errstr()});
        };
    }

    /// The server Proc's thread.
    fn serverMain(p: *Proc) void {
        const j = p.job;
        const m = j.m;
        kern.setPlan(&m.plan);
        kern.setPages(&j.pages);
        kern.setCpus(j.ncpu);
        p.setKproc();
        kern.setText("serve");
        defer p.exit();
        const srv = j.srv.?;
        if (!m.opts.serve_net) kern.unmount(null, "/net") catch {};
        // A root without 9front's binaries has the built-in root's.
        var st: [512]u8 = undefined;
        j.exportfs = if (kern.stat("/bin/exportfs", &st)) |_|
            "/bin/exportfs"
        else |_|
            std.fmt.bufPrint(&j.exportfs_buf, "{s}/{s}/bin/exportfs", .{ policy.builtin_dev, m.arch.name() }) catch "/bin/exportfs";
        const mc = kern.mach() orelse return;
        const owner = @intFromPtr(mc);
        mc.put();
        srv.start(owner, kern.currentPages());
        while (srv.next()) |id| {
            m.serveConn(p, id);
            if (j.stopping.load(.acquire)) break;
        }
    }

    /// Forks an exportfs for a ready stream. Its fd is the child's until
    /// it execs, when it becomes fds 0 and 1.
    fn serveConn(m: *Machine, server: *Proc, id: u32) void {
        const j = server.job;
        const srv = j.srv.?;
        const fd = kern.hstreamFd(id) catch {
            hstream.release(id);
            srv.connEnded();
            return;
        };
        hstream.release(id);
        // Through a `#ℓ` conversation's server side (design/0022-dotl.md),
        // so a 9P2000.L client is translated and a 9P2000 one passes.
        const data = dotlConv("serve {d}", fd);
        kern.close(fd) catch {};
        const sfd = data catch {
            srv.connEnded();
            return;
        };
        defer kern.close(sfd) catch {};
        const conn = m.gpa.create(Conn) catch {
            srv.connEnded();
            return;
        };
        conn.* = .{};
        const c = j.newProc(.{ .serving = conn }) catch {
            m.gpa.destroy(conn);
            srv.connEnded();
            return;
        };
        c.serve_fd = sfd;
        const flags = kern.RF.PROC | kern.RF.NAMEG | kern.RF.FDG | kern.RF.NOWAIT;
        // On failure dropProc ends the connection, as its last process.
        kern.fork(flags, c.pid, Proc, exportfsMain, c) catch j.dropProc(c);
    }

    /// A connection's first process: puts the stream on fds 0 and 1 and
    /// runs `exportfs -r ROOT`, with `-R` under `--write=none`, as
    /// listen(8) does for a network service.
    fn exportfsMain(p: *Proc) void {
        const j = p.job;
        const m = j.m;
        kern.setPlan(&m.plan);
        kern.setPages(&j.pages);
        kern.setCpus(j.ncpu);
        p.setKproc();
        const st = m.startExportfs(p) catch |e| Status{ .killed = std.fmt.bufPrint(&p.msg_buf, "h9: exportfs: {t}", .{e}) catch "h9: error" };
        setExits(switch (st) {
            .exited => |t| t,
            .killed => |t| t,
        });
        p.exit();
    }

    fn startExportfs(m: *Machine, p: *Proc) RunError!Status {
        const j = p.job;
        const fd = p.serve_fd.?;
        _ = try kern.dup(fd, 0);
        _ = try kern.dup(fd, 1);
        try kern.close(fd);
        var arena: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, "exportfs");
        if (m.plan.write == .none) try argv.append(a, "-R");
        try argv.appendSlice(a, &.{ "-r", m.opts.serve_root });
        const path = try a.dupeZ(u8, j.exportfs);
        const bytes = readFile(a, path) catch |e| {
            return .{ .killed = std.fmt.bufPrint(&p.msg_buf, "h9: {s}: {t}", .{ j.exportfs, e }) catch "h9: no exportfs" };
        };
        if (elf.isElf(bytes)) return .{ .killed = "h9: exportfs isn't a 9front binary" };
        const hdr = aout.parse(bytes) catch return .{ .killed = "h9: exportfs: " ++ ebadexec };
        if (hdr.arch != m.arch) return .{ .killed = "h9: exportfs: wrong architecture" };
        kern.setText("exportfs");
        p.as = try m.backend.newAddressSpace();
        const img = try loader.load(m.gpa, m.backend, p.as.?, bytes, argv.items, p.pid);
        p.segs.replace(p.as.?, img.segs);
        p.tos = img.tos;
        p.ureg = .initExec(img.arch, img.entry, img.sp, img.tos);
        p.extra = .initExec(img.arch);
        p.keepImage(bytes);
        p.initSys();
        p.noteMem();
        kern.setArgs(argv.items);
        kern.setTextPath(path);
        return m.loop(p);
    }

    /// A run with `serve` and no program: the first Proc sleeps in the
    /// kernel until a note (an interrupt, a hangup, the timeout) ends it,
    /// and the run exits 0, as a server its operator stops does.
    fn serveOnly(j: *Job) RunError!Status {
        kern.setText("serve");
        while (!j.stopping.load(.acquire)) kern.sleep(60_000) catch break;
        return .{ .exited = "" };
    }

    /// A forked process's thread.
    fn childMain(p: *Proc) void {
        const m = p.job.m;
        kern.setPlan(&m.plan);
        kern.setPages(&p.job.pages);
        kern.setCpus(p.job.ncpu);
        p.setKproc();
        if (p.lx != null) kern.setNotify(true);
        const st = m.loop(p) catch |e| Status{ .killed = std.fmt.bufPrint(&p.msg_buf, "h9: {t}", .{e}) catch "h9: error" };
        setExits(switch (st) {
            .exited => |t| t,
            .killed => |t| t,
        });
        p.exit();
    }

    fn setExits(msg: []const u8) void {
        var buf: [kern.ERRMAX]u8 = undefined;
        const n = @min(msg.len, buf.len - 1);
        @memcpy(buf[0..n], msg[0..n]);
        buf[n] = 0;
        kern.setExits(buf[0..n :0]);
    }

    /// The exit loop: runs the process on its vCPU and serves its exits
    /// until it exits or dies. Notes are delivered before each run, so at
    /// the end of a syscall, after a kick or fault, and after noted, as
    /// 9front delivers them on the way back to user mode. Runs on the
    /// process's thread.
    fn loop(m: *Machine, p: *Proc) RunError!Status {
        const st = m.runLoop(p) catch |e| {
            if (p.lx) |l| _ = m.linuxEnd(p, l, .{ .killed = std.fmt.bufPrint(&p.msg_buf, "h9: {t}", .{e}) catch "h9: error" });
            return e;
        };
        const l = p.lx orelse return st;
        return m.linuxEnd(p, l, st);
    }

    /// How a Linux thread's end ends its group (design/0049-linux-
    /// threads.md). exit ends only the thread, but the leader waits for
    /// the others, since its wait record is the group's. exit_group and a
    /// fatal signal end the group: the first sets the status, the other
    /// threads are killed, and the leader exits with it once they're gone.
    fn linuxEnd(m: *Machine, p: *Proc, l: *lsys.Process, st: Status) Status {
        _ = m;
        lsys.threadExiting(l);
        lsys.threadCpuEnd(l);
        const g = l.g;
        const group_ends = switch (st) {
            .exited => |t| if (l.thread_exit) false else g.setEnd(t, false),
            .killed => |t| g.setEnd(t, true),
        };
        if (group_ends) {
            var buf: [256]u32 = undefined;
            for (g.others(l.pid, &buf)) |tid| _ = kern.postNote(tid, "kill", .user) catch {};
        }
        if (!l.isLeader()) return st;
        // The leader goes last. A kill while it waits (another thread's
        // exit_group) only ends the wait early.
        while (g.count() > 1 and !p.job.stopping.load(.acquire)) kern.sleep(5) catch {};
        lsys.reportCpu(l);
        lsys.releaseAllLocks(l);
        g.lockSpin();
        defer g.lock.unlock();
        const e = g.end orelse return st;
        const n = @min(e.msg.len, p.msg_buf.len);
        @memcpy(p.msg_buf[0..n], e.msg[0..n]);
        return if (e.killed) .{ .killed = p.msg_buf[0..n] } else .{ .exited = p.msg_buf[0..n] };
    }

    fn runLoop(m: *Machine, p: *Proc) RunError!Status {
        const j = p.job;
        try j.pool.acquire(&p.lease_store);
        p.setLease(&p.lease_store);
        const vcpu = &p.lease_store;
        try vcpu.setAddressSpace(p.as.?);
        vcpu.setExtra(&p.extra);
        var u = p.ureg;
        vcpu.setUreg(&u);
        // A clone or fork child's time starts here, on its own thread.
        if (p.lx) |l| l.cpu0 = lsys.cputime.thread();
        // A thread joins its group before its kernel process exists, so an
        // exit_group in between posts it a kill note that's lost. It looks
        // here, once it exists: a later exit_group's note reaches it.
        if (p.lx) |l| if (!l.isLeader() and l.g.ending()) return .{ .killed = "kill" };
        var last_fault: struct { addr: u64 = 0, access: @FieldType(vmm.Fault, "access") = .read, pc: u64 = 0, gen: u64 = 0 } = .{};
        while (true) {
            if (j.stopping.load(.acquire)) return .{ .killed = if (j.timed_out.load(.acquire)) timeout_note else stopped_note };
            if (p.lx) |l| {
                const flagged = p.note_flag.swap(false, .acq_rel);
                if (flagged or l.restart != null or l.sig.deliverable()) {
                    if (try m.deliverLinux(p, vcpu, &u, flagged)) |msg| return .{ .killed = msg };
                }
            } else if (try stopPoint(p, vcpu, &u)) |st| {
                // 9front stops a debugged process on its way back to user
                // mode, before delivering a note.
                return st;
            } else if (p.note_flag.swap(false, .acq_rel)) {
                if (try deliver(p, vcpu, &u)) |msg| return .{ .killed = msg };
            }
            const exit = try vcpu.run();
            vcpu.getUreg(&u);
            if (exit != .fault) last_fault = .{};
            if (p.lx) |l| switch (exit) {
                .syscall => {
                    if (try m.linuxSyscall(p, l, vcpu, &u)) |st| return st;
                    continue;
                },
                .fault => |f| {
                    // An EL0 read of an ID register, which Linux emulates
                    // (lexec.emulateIdRead): HVF reports it as a system
                    // register trap, the emulator as an invalid instruction.
                    if (m.arch == .arm64 and f.access == .exec and f.addr == u.pc()) {
                        var w: [4]u8 = undefined;
                        if (l.readMem(f.addr, &w)) |_| {
                            if (lexec.emulateIdRead(std.mem.readInt(u32, &w, .little))) |r| {
                                if (r.rt != 31) u.arm64.r[r.rt] = r.value;
                                u.arm64.pc += 4;
                                vcpu.setUreg(&u);
                                last_fault = .{};
                                continue;
                            }
                        } else |_| {}
                    }
                    // The same fault again at once, with no remap of the
                    // address space in between, means the retry didn't
                    // help: it's real. A remap between them (another
                    // thread's mmap or mprotect in the same chunk) may have
                    // caught the retry with the page briefly unmapped.
                    const same = f.addr == last_fault.addr and f.access == last_fault.access and u.pc() == last_fault.pc;
                    if (l.mm.fault(f.addr, switch (f.access) {
                        .read => .read,
                        .write => .write,
                        .exec => .exec,
                    }) catch null) |gen| if (!same or gen != last_fault.gen) {
                        last_fault = .{ .addr = f.addr, .access = f.access, .pc = u.pc(), .gen = gen };
                        p.noteMem();
                        continue;
                    };
                    if (m.opts.dump_on_fault) dumpFault(m.opts.stdio.err, &u, f, "");
                    // A fault while the signal is blocked or ignored kills,
                    // as Linux's force_sig does.
                    const a = l.sig.actions[lsig.SIGSEGV];
                    if (a.handler == lsig.SIG_DFL or a.handler == lsig.SIG_IGN or l.sig.mask & lsig.bit(lsig.SIGSEGV) != 0) {
                        return .{ .killed = lsig.deathNote(lsig.SIGSEGV, &p.msg_buf) };
                    }
                    _ = l.sig.post(lsig.SIGSEGV, .{ .code = if (!l.mm.mapped(f.addr)) lsig.SEGV_MAPERR else lsig.SEGV_ACCERR, .addr = f.addr });
                    continue;
                },
                else => {},
            };
            // On 386, int 0x80 (Linux's call) is a general protection
            // fault for a 9front process, as its IDT gate allows only
            // INT $64 from user mode (design/0105-linux-i386.md).
            if (exit == .syscall and u == .i386 and u.i386.trap != vmm.ia32.vector_syscall) {
                const note = "sys: trap: general protection violation";
                if (!(kern.postNote(p.pid, note, .debug) catch false)) {
                    return .{ .killed = try std.fmt.bufPrint(&p.msg_buf, "{s} pc=0x{x}", .{ note, u.pc() }) };
                }
                continue;
            }
            switch (exit) {
                .syscall => switch (blk: {
                    // /proc/n/regs serves these while the call runs.
                    p.dbgLock();
                    p.dbg_ureg = u;
                    p.dbg_lock.unlock();
                    if (try stopPoint(p, vcpu, &u)) |st| return st;
                    // A note posted during the last call had its interrupt
                    // cleared when that call returned (drawterm's wrappers
                    // clear it after every call). If the guest's next exit
                    // is this call, it must still be interrupted, as in
                    // 9front, where notepending holds until the note is
                    // delivered. `noteKick` sets the flag before the
                    // interrupt, so a note missed here interrupts the call.
                    if (p.note_flag.load(.acquire)) kern.interrupt(kern.self());
                    p.in_sys.store(u.syscallNumber() +% 1, .release);
                    defer p.in_sys.store(0, .release);
                    const out = syscall.dispatch(&p.sys, &u);
                    p.noteMem();
                    break :blk out;
                }) {
                    .ret => |r| {
                        u.setReturn(r);
                        vcpu.setUreg(&u);
                    },
                    .exits => |s| {
                        setExits(s);
                        return .{ .exited = s };
                    },
                    .rfork => |flags| {
                        try vcpu.getExtra(&p.extra);
                        const r: i64 = if (m.fork(p, flags, &u)) |pid| pid else |_| -1;
                        p.sys.traceRet("rfork", r);
                        u.setReturn(@bitCast(r));
                        vcpu.setUreg(&u);
                    },
                    .exec => |e| {
                        defer e.deinit(m.gpa);
                        if (m.exec(p, vcpu, e)) |_| {
                            p.sys.traceRet("exec", 0);
                            u = p.ureg;
                            vcpu.setExtra(&p.extra);
                        } else |_| {
                            p.sys.traceRet("exec", -1);
                            u.setReturn(@bitCast(@as(i64, -1)));
                        }
                        vcpu.setUreg(&u);
                    },
                    .noted => |arg| {
                        if (try noted(p, vcpu, &u, arg)) |msg| return .{ .killed = msg };
                    },
                },
                .fault => |f| {
                    // The stack grows down on demand, as 9front's does.
                    if (f.access != .exec and p.segs.growStack(f.addr)) {
                        p.noteMem();
                        continue;
                    }
                    if (m.opts.dump_on_fault) dumpFault(m.opts.stdio.err, &u, f, p.image orelse "");
                    // 9front's faultnote; popnote adds the pc. If the note
                    // can't be queued, the fault would only repeat.
                    var buf: [kern.ERRMAX]u8 = undefined;
                    const note = std.fmt.bufPrintZ(&buf, "sys: trap: fault {t} addr=0x{x}", .{ f.access, f.addr }) catch unreachable;
                    if (!(kern.postNote(p.pid, note, .debug) catch false)) {
                        return .{ .killed = try std.fmt.bufPrint(&p.msg_buf, "{s} pc=0x{x}", .{ note, u.pc() }) };
                    }
                },
                .breakpoint => {
                    // 9front's trap table posts this for BRK and INT3; a
                    // debugger stops the process at the next stop point
                    // before it's delivered.
                    const note = "sys: breakpoint";
                    if (!(kern.postNote(p.pid, note, .debug) catch false)) {
                        return .{ .killed = try std.fmt.bufPrint(&p.msg_buf, "{s} pc=0x{x}", .{ note, u.pc() }) };
                    }
                },
                .interrupted => {},
                .halted => return .{ .killed = "halted" },
                .other => |code| return .{ .killed = try std.fmt.bufPrint(&p.msg_buf, "sys: trap: unexpected exit 0x{x} pc=0x{x}", .{ code, u.pc() }) },
            }
        }
    }

    /// A stop point (design/0010-self-host.md): if a debugger asked the
    /// process to stop here, saves its registers for /proc/n/regs and
    /// fpregs, and parks on the process's own thread until ctl start,
    /// holding no vCPU. Registers the debugger wrote are loaded back
    /// before it runs on. Returns the status it ends with if the machine
    /// is torn down meanwhile. A note doesn't end the stop; ctl kill does,
    /// and the note delivery after it kills the process.
    fn stopPoint(p: *Proc, vcpu: *cpupool.Lease, u: *vmm.Ureg) RunError!?Status {
        // A stop request flags the process, and Ptraceme waits for a note,
        // which flags it too; the kernel decides.
        if (!p.stop_flag.swap(false, .acq_rel) and !p.note_flag.load(.acquire)) return null;
        if (!kern.wantStop()) return null;
        const j = p.job;
        var x: vmm.Extra = undefined;
        try vcpu.getExtra(&x);
        p.dbgLock();
        p.dbg_ureg = u.*;
        p.dbg_extra = x;
        p.dbg_ureg_set = false;
        p.dbg_extra_set = false;
        p.dbg_stopped = true;
        p.dbg_lock.unlock();
        defer {
            p.dbgLock();
            p.dbg_stopped = false;
            if (p.dbg_ureg_set) {
                u.* = p.dbg_ureg;
                vcpu.setUreg(u);
            }
            if (p.dbg_extra_set) vcpu.setExtra(&p.dbg_extra);
            p.dbg_lock.unlock();
        }
        while (!kern.stopWait()) {
            if (j.stopping.load(.acquire)) {
                kern.unstop();
                return .{ .killed = if (j.timed_out.load(.acquire)) timeout_note else stopped_note };
            }
            if (kern.killed()) {
                kern.unstop();
                p.note_flag.store(true, .release);
                break;
            }
        }
        return null;
    }

    /// Delivers the process's next note, as 9front's donotify does: with a
    /// handler, pushes the Ureg and the note on the user stack (growing it)
    /// and enters the handler; without one, or for a note that arrives in
    /// the handler, or if the frame doesn't fit, returns the note the
    /// process dies with. `u` holds the current registers.
    fn deliver(p: *Proc, vcpu: *cpupool.Lease, u: *vmm.Ureg) vmm.Error!?[]const u8 {
        var msg: [kern.ERRMAX]u8 = undefined;
        switch (kern.popNote(&msg, u.pc())) {
            .none => return null,
            .kill, .kill_debug => return p.keepNote(&msg),
            .handle => {},
        }
        const f = u.notifyFrame(p.sys.notify, kern.ERRMAX) orelse return p.keepNote(&msg);
        const end = f.nureg + u.size();
        _ = p.segs.growStack(f.sp);
        if (!p.segs.writable(f.sp, end -% f.sp)) return p.keepNote(&msg);
        const as = p.as.?;
        const w: usize = @intCast(u.wordSize());
        var words: [3 * 8]u8 = undefined;
        putWords(&words, w, &.{ 0, f.nureg, f.msg });
        var prev: [8]u8 = undefined;
        putWords(&prev, w, &.{p.noteureg});
        const zmsg = std.mem.sliceTo(&msg, 0);
        @memset(msg[zmsg.len..], 0);
        gm.write(as, f.nureg, u.bytes()) catch return p.keepNote(&msg);
        gm.write(as, f.msg, &msg) catch return p.keepNote(&msg);
        // The word under the Ureg is the previous saved Ureg.
        gm.write(as, f.nureg - w, prev[0..w]) catch return p.keepNote(&msg);
        gm.write(as, f.sp, words[0 .. 3 * w]) catch return p.keepNote(&msg);
        var x: vmm.Extra = undefined;
        try vcpu.getExtra(&x);
        p.note_extra = x;
        p.noteureg = f.nureg;
        u.* = f.regs;
        vcpu.setUreg(u);
        return null;
    }

    /// noted(arg), as 9front's sysnoted and noted: restores the registers
    /// the handler was entered with (keeping the privileged state), or
    /// for NSAVE re-enters the handler's frame, or kills the process with
    /// the note for NDFLT. Outside a handler, anything but NRSTR fails
    /// with "bad arg in system call". Returns the note the process dies
    /// with, if it does.
    fn noted(p: *Proc, vcpu: *cpupool.Lease, u: *vmm.Ureg, arg: i32) vmm.Error!?[]const u8 {
        var msg: [kern.ERRMAX]u8 = undefined;
        const how: kern.Noted = @enumFromInt(arg);
        switch (kern.noted(how, &msg) catch {
            p.sys.traceRet("noted", -1);
            u.setReturn(@bitCast(@as(i64, -1)));
            vcpu.setUreg(u);
            return null;
        }) {
            .kill, .kill_debug => return p.keepNote(&msg),
            .none, .handle => {},
        }
        if (p.note_extra) |x| {
            vcpu.setExtra(&x);
            p.note_extra = null;
        }
        const as = p.as.?;
        const nureg = p.noteureg;
        var saved: [@sizeOf(vmm.Ureg)]u8 = undefined;
        const w = u.wordSize();
        const n = u.size();
        if (nureg < w or nureg % w != 0) return suicide;
        const prev = gm.readWord(as, nureg - w, w) catch return suicide;
        gm.read(as, nureg, saved[0..n]) catch return suicide;
        var r = u.restored(saved[0..n]);
        switch (how) {
            .cont, .rstr => {
                p.noteureg = prev;
                if (!r.aligned() or as.translate(r.pc(), 1) == null or as.translate(r.stackPointer(), w) == null) return suicide;
            },
            .save => {
                const sp = nureg - 4 * w - kern.ERRMAX;
                var words: [2 * 8]u8 = undefined;
                putWords(&words, w, &.{ 0, nureg });
                if (as.translate(r.pc(), 1) == null or sp % w != 0 or !p.segs.writable(sp, 4 * w)) return suicide;
                gm.write(as, sp, words[0 .. 2 * @as(usize, @intCast(w))]) catch return suicide;
                r.setNoteSave(sp, nureg);
            },
            // kern.noted kills for every other argument.
            else => unreachable,
        }
        p.sys.traceRet("noted", 0);
        u.* = r;
        vcpu.setUreg(u);
        // A note held while in the handler is delivered now, not at some
        // later exit (9front would take it at the next clock tick).
        p.note_flag.store(true, .release);
        return null;
    }

    /// Little-endian words of `w` bytes (4 or 8) from `vals` into `out`.
    fn putWords(out: []u8, w: u64, vals: []const u64) void {
        for (vals, 0..) |v, i| {
            if (w == 4) std.mem.writeInt(u32, out[i * 4 ..][0..4], @truncate(v), .little) else std.mem.writeInt(u64, out[i * 8 ..][0..8], v, .little);
        }
    }

    /// 9front's exit status for a broken noted.
    const suicide = "Suicide";

    // The Linux personality (design/0018-linux-personality.md): exec of an
    // ELF binary, the exit loop's calls and signals, and clone.

    /// The environment a Linux program starts with, from /env: rc lists
    /// joined with spaces, `user` also as USER and LOGNAME, and rc's
    /// per-process variables left out. 9front's own (`path`, `home`) stay,
    /// so a 9front program the Linux one runs gets them back. PATH and
    /// HOME get Linux defaults when they aren't set.
    fn linuxEnv(arena: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var have_path = false;
        var have_home = false;
        const skip = [_][]const u8{ "prompt", "status", "pid", "apid", "timezone", "ifs", "rcname", "cflag", "0", "*" };
        const fd = kern.open("/env", kern.OREAD) catch return out.items;
        defer kern.close(fd) catch {};
        var buf: [8192]u8 = undefined;
        var off: i64 = 0;
        while (true) {
            const n = kern.pread(fd, &buf, off) catch break;
            if (n == 0) break;
            off += @intCast(n);
            var i: usize = 0;
            while (i + 2 <= n) {
                const size = @as(usize, std.mem.readInt(u16, buf[i..][0..2], .little)) + 2;
                if (i + size > n or size < 43) break;
                const nlen = std.mem.readInt(u16, buf[i + 41 ..][0..2], .little);
                const name = buf[i + 43 ..][0..nlen];
                i += size;
                if (std.mem.indexOfScalar(u8, name, '#') != null or std.mem.indexOfScalar(u8, name, '=') != null) continue;
                var skipped = false;
                for (skip) |sk| if (std.mem.eql(u8, sk, name)) {
                    skipped = true;
                };
                if (skipped) continue;
                var pbuf: [kern.ERRMAX + 8]u8 = undefined;
                const path = std.fmt.bufPrintZ(&pbuf, "/env/{s}", .{name}) catch continue;
                const vfd = kern.open(path, kern.OREAD) catch continue;
                defer kern.close(vfd) catch {};
                var vbuf: [16384]u8 = undefined;
                const vn = kern.pread(vfd, &vbuf, 0) catch continue;
                var v = vbuf[0..vn];
                if (v.len > 0 and v[v.len - 1] == 0) v = v[0 .. v.len - 1];
                for (v) |*ch| if (ch.* == 0) {
                    ch.* = ' ';
                };
                if (std.mem.eql(u8, name, "user")) {
                    try out.append(arena, try std.fmt.allocPrint(arena, "USER={s}", .{v}));
                    try out.append(arena, try std.fmt.allocPrint(arena, "LOGNAME={s}", .{v}));
                }
                if (std.mem.eql(u8, name, "PATH")) have_path = true;
                if (std.mem.eql(u8, name, "HOME")) have_home = true;
                try out.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ name, v }));
            }
        }
        if (!have_path) try out.append(arena, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
        if (!have_home) try out.append(arena, "HOME=/root");
        return out.items;
    }

    /// Loads Linux program `bytes`, found at `path`, into a new address
    /// space and makes it the process's, as exec does for an a.out: the
    /// process is unchanged until the image is built. With `vcpu` null
    /// (the first process) the exit loop sets the address space.
    fn execLinux(m: *Machine, p: *Proc, vcpu: ?*cpupool.Lease, arena: std.mem.Allocator, path: []const u8, bytes: []const u8, argv: []const []const u8, envp: []const []const u8) error{Failed}!void {
        const exe = elf.check(bytes, m.arch) catch return failWith(ebadexec);
        var interp: ?elf.Image = null;
        if (exe.interp) |ip| {
            // The loader's path is in the Linux view.
            const ib = readLinux(arena, ip) catch |err| return execError(err);
            interp = elf.check(ib, m.arch) catch return failWith(ebadexec);
        }
        var random: [16]u8 = undefined;
        m.io.random(&random);
        const prog = lexec.build(m.gpa, m.backend, .{
            .arch = m.arch,
            .exe = &exe,
            .interp = if (interp) |*ii| ii else null,
            .path = path,
            .argv = argv,
            .envp = envp,
            .random = random,
        }) catch |err| return failWith(switch (err) {
            error.BadElf, error.NotElf => ebadexec,
            else => "virtual memory allocation failed",
        });
        if (vcpu) |v| v.setAddressSpace(prog.mm.as) catch {
            prog.mm.put();
            return failWith("virtual memory allocation failed");
        };

        // Committed.
        const j = p.job;
        if (p.lx) |l| {
            const old = l.mm;
            l.mm = prog.mm;
            // /proc/n/mem may be reading through the old space.
            p.dbgLock();
            p.as = prog.mm.as;
            old.put();
            p.dbg_lock.unlock();
            l.sig.execReset();
            l.execFds();
            l.vdso = prog.vdso;
        } else {
            const l = m.gpa.create(lsys.Process) catch {
                prog.mm.put();
                return failWith("no memory");
            };
            l.* = .{
                .gpa = m.gpa,
                .io = m.io,
                .arch = m.arch,
                .pid = p.pid,
                .mm = prog.mm,
                .host = .{ .ctx = j, .kill = linuxKill, .pgidOf = linuxPgid },
                .pgid = p.pid,
                .sid = p.pid,
                .hwcap = lexec.hwcap(m.arch),
                .vdso = prog.vdso,
                .ncpu = j.ncpu,
                .mem_limit = m.plan.memory orelse vmm.default_memory,
                .console_tty = m.opts.console_tty,
                .trace = m.opts.trace,
                .trace_lock = &j.trace_lock,
            };
            l.newGroup() catch {
                m.gpa.destroy(l);
                prog.mm.put();
                return failWith("no memory");
            };
            p.dbgLock();
            if (p.as) |old| {
                p.segs.release(old);
                old.destroy();
            }
            l.cpu0 = lsys.cputime.thread();
            j.lockSpin();
            p.lx = l;
            p.as = prog.mm.as;
            j.lock.unlock();
            p.dbg_lock.unlock();
            p.noteureg = 0;
            p.note_extra = null;
        }
        const l = p.lx.?;
        l.setExe(realLinux(arena, path));
        if (!kc.inView()) kc.setSlash(true) catch {};
        kern.execNotes();
        kern.setNotify(true);
        p.ureg = lexec.initRegs(m.arch, prog.entry, prog.sp);
        p.extra = .initExec(m.arch);
        if (p.image) |b| m.gpa.free(b);
        p.image = null;
        p.noteMem();
        kern.setArgs(argv);
        kern.closeExec();
        var name_buf: [kern.ERRMAX]u8 = undefined;
        kern.setText(std.fmt.bufPrintZ(&name_buf, "{s}", .{basename(path)}) catch "a.out");
        p.vforkRelease();
    }

    /// Reads a file by its path in the Linux view, from either view. A
    /// `#λ` path doesn't cross the mounts on #λ, as no `#` path does, so
    /// from the 9front view the process's root is the Linux view's for
    /// the read.
    fn readLinux(arena: std.mem.Allocator, path: []const u8) RunError![]u8 {
        const swap = !kc.inView();
        if (swap) kc.setSlash(true) catch return error.NotFound;
        defer if (swap) kc.setSlash(false) catch {};
        return readFile(arena, try arena.dupeZ(u8, path));
    }

    /// `path` in the Linux view made absolute with its symbolic links
    /// followed, as Linux's /proc/self/exe names the file it runs:
    /// programs such as zig find their installation from it, and run
    /// through a link (/usr/bin/zig -> /opt/zig/zig) they'd look beside
    /// the link. `path` itself if it can't be resolved.
    fn realLinux(arena: std.mem.Allocator, path: []const u8) []const u8 {
        const swap = !kc.inView();
        if (swap) kc.setSlash(true) catch return path;
        defer if (swap) kc.setSlash(false) catch {};
        var cwd_buf: [4096]u8 = undefined;
        var todo: []const u8 = if (path.len > 0 and path[0] == '/') path else blk: {
            const cwd = kc.getcwd(&cwd_buf) catch return path;
            break :blk std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, path }) catch return path;
        };
        var out: std.ArrayList(u8) = .empty;
        var link_buf: [4096]u8 = undefined;
        var links: usize = 0;
        var i: usize = 0;
        while (i < todo.len) {
            while (i < todo.len and todo[i] == '/') i += 1;
            const j = std.mem.indexOfScalarPos(u8, todo, i, '/') orelse todo.len;
            const elem = todo[i..j];
            i = j;
            if (elem.len == 0 or std.mem.eql(u8, elem, ".")) continue;
            if (std.mem.eql(u8, elem, "..")) {
                out.shrinkRetainingCapacity(std.mem.lastIndexOfScalar(u8, out.items, '/') orelse 0);
                continue;
            }
            const save = out.items.len;
            out.append(arena, '/') catch return path;
            out.appendSlice(arena, elem) catch return path;
            const z = arena.dupeZ(u8, out.items) catch return path;
            const target = kern.readlink(z, &link_buf) catch continue;
            links += 1;
            if (links > 40 or target.len == 0) return path;
            out.shrinkRetainingCapacity(if (target[0] == '/') 0 else save);
            todo = std.fmt.allocPrint(arena, "{s}/{s}", .{ target, todo[i..] }) catch return path;
            i = 0;
        }
        return if (out.items.len == 0) "/" else out.items;
    }

    /// Finds a program in the Linux view as a Linux shell would: a name
    /// with a slash as it is, and a bare name along PATH.
    fn findLinux(arena: std.mem.Allocator, name: []const u8, path_var: []const u8) ?[]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
        const swap = !kc.inView();
        if (swap) kc.setSlash(true) catch return null;
        defer if (swap) kc.setSlash(false) catch {};
        var it = std.mem.tokenizeScalar(u8, path_var, ':');
        while (it.next()) |dir| {
            const full = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name }) catch return null;
            const z = arena.dupeZ(u8, full) catch return null;
            var st: [512]u8 = undefined;
            const n = kern.stat(z, &st) catch continue;
            if (n >= 25 and std.mem.readInt(u32, st[21..25], .little) & 0x80000000 == 0) return full;
        }
        return null;
    }

    /// execve from a Linux process: follows #! lines as Linux does (the
    /// interpreter, its one optional argument, the script's path, then
    /// the caller's arguments after argv[0]) and loads the ELF binary.
    fn linuxExec(m: *Machine, p: *Proc, vcpu: ?*cpupool.Lease, e: lsys.Exec) error{Failed}!void {
        return m.linuxExecPath(p, vcpu, e.path, @ptrCast(e.argv), @ptrCast(e.envp));
    }

    fn linuxExecPath(m: *Machine, p: *Proc, vcpu: ?*cpupool.Lease, path0: []const u8, argv0: []const []const u8, envp: []const []const u8) error{Failed}!void {
        var arena_state: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var path: []const u8 = path0;
        var bytes = readLinux(arena, path) catch |err| return execError(err);
        var argv: []const []const u8 = argv0;
        var depth: usize = 0;
        while (std.mem.startsWith(u8, bytes, "#!")) : (depth += 1) {
            if (depth >= 4) return failWith("too many levels of interpreters");
            const head = bytes[0..@min(bytes.len, 256)];
            const nl = std.mem.indexOfScalar(u8, head, '\n') orelse head.len;
            const line = std.mem.trim(u8, head[2..nl], " \t\r");
            if (line.len == 0) return failWith(ebadexec);
            const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
            const interp = line[0..sp];
            const arg = std.mem.trim(u8, line[sp..], " \t");
            var next: std.ArrayList([]const u8) = .empty;
            next.append(arena, interp) catch return failWith("no memory");
            if (arg.len > 0) next.append(arena, arg) catch return failWith("no memory");
            next.append(arena, path) catch return failWith("no memory");
            if (argv.len > 1) next.appendSlice(arena, argv[1..]) catch return failWith("no memory");
            argv = next.items;
            path = interp;
            bytes = readLinux(arena, path) catch |err| return execError(err);
        }
        if (!elf.isElf(bytes)) {
            // A 9front program: exec it as a 9front process does, back in
            // the 9front view, with the environment written to a new
            // Egrp (design/0018, "Environment").
            _ = aout.parse(bytes) catch return failWith(ebadexec);
            const v = vcpu orelse return failWith(ebadexec);
            const zargv = arena.alloc([:0]u8, argv0.len) catch return failWith("no memory");
            for (argv0, zargv) |a, *z| z.* = arena.dupeZ(u8, a) catch return failWith("no memory");
            try m.exec(p, v, .{ .path = arena.dupeZ(u8, path0) catch return failWith("no memory"), .argv = zargv });
            nineEnv(envp);
            return;
        }
        return m.execLinux(p, vcpu, arena, path, bytes, argv, envp);
    }

    /// Writes a Linux process's environment into a new, clean Egrp for
    /// the 9front program it execs. `path` is an rc list again.
    fn nineEnv(envp: []const []const u8) void {
        kern.rfork(kern.RF.CENVG) catch return;
        var have_path = false;
        for (envp) |e| {
            const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
            const name = e[0..eq];
            if (name.len == 0 or name.len > 64 or std.mem.indexOfScalar(u8, name, '/') != null) continue;
            if (std.mem.eql(u8, name, "path")) {
                have_path = true;
                var buf: [4096]u8 = undefined;
                var n: usize = 0;
                var it = std.mem.tokenizeScalar(u8, e[eq + 1 ..], ' ');
                while (it.next()) |el| {
                    if (n + el.len + 1 > buf.len) break;
                    @memcpy(buf[n..][0..el.len], el);
                    buf[n + el.len] = 0;
                    n += el.len + 1;
                }
                putEnv(name, buf[0..n]) catch {};
                continue;
            }
            putEnv(name, e[eq + 1 ..]) catch {};
        }
        if (!have_path) putEnv("path", ".\x00/bin\x00") catch {};
    }

    /// Serves a Linux process's syscall exit. Returns the status when the
    /// process exits.
    fn linuxSyscall(m: *Machine, p: *Proc, l: *lsys.Process, vcpu: *cpupool.Lease, u: *vmm.Ureg) RunError!?Status {
        // See the 9front branch of `loop`.
        if (p.note_flag.load(.acquire)) kern.interrupt(kern.self());
        if (u.* == .i386) {
            const r = &u.i386;
            // On 386 only int 0x80 is a Linux call: INT $64, 9front's, is
            // a general protection fault, SIGSEGV (design/0105-linux-i386.md).
            if (r.trap != vmm.ia32.vector_linux) {
                const a = l.sig.actions[lsig.SIGSEGV];
                if (a.handler == lsig.SIG_DFL or a.handler == lsig.SIG_IGN or l.sig.mask & lsig.bit(lsig.SIGSEGV) != 0) {
                    return .{ .killed = lsig.deathNote(lsig.SIGSEGV, &p.msg_buf) };
                }
                _ = l.sig.post(lsig.SIGSEGV, .{ .code = lsig.SI_KERNEL });
                return null;
            }
            // set_thread_area and get_thread_area: the TLS segment's base,
            // which is the vCPU's, as amd64's FS base is.
            if (r.ax == 243 or r.ax == 244) {
                try vcpu.getExtra(&p.extra);
                const v = threadArea(l, &p.extra.i386, r.ax == 243, r.bx);
                l.traceLine("{s}(0x{x}) = {d}", .{ if (r.ax == 243) "set_thread_area" else "get_thread_area", r.bx, v });
                if (r.ax == 243 and v == 0) vcpu.setExtra(&p.extra);
                r.ax = @truncate(@as(u64, @bitCast(v)));
                vcpu.setUreg(u);
                return null;
            }
        }
        // amd64's arch_prctl sets the FS and GS bases, which are the vCPU's.
        if (u.* == .amd64 and u.amd64.ax == 158) {
            const ARCH_SET_GS = 0x1001;
            const ARCH_SET_FS = 0x1002;
            const ARCH_GET_FS = 0x1003;
            const ARCH_GET_GS = 0x1004;
            const r = &u.amd64;
            try vcpu.getExtra(&p.extra);
            const v: i64 = switch (r.di) {
                ARCH_SET_FS => blk: {
                    if (r.si >= lmm.user_top) break :blk -attr.E.PERM;
                    p.extra.amd64.tls = r.si;
                    vcpu.setExtra(&p.extra);
                    break :blk 0;
                },
                ARCH_GET_FS => if (l.writeU64(r.si, p.extra.amd64.tls)) 0 else |_| -attr.E.FAULT,
                // GS base: 64-bit Wine keeps the Windows TEB there.
                ARCH_SET_GS => blk: {
                    if (r.si >= lmm.user_top) break :blk -attr.E.PERM;
                    p.extra.amd64.gs = r.si;
                    vcpu.setExtra(&p.extra);
                    break :blk 0;
                },
                ARCH_GET_GS => if (l.writeU64(r.si, p.extra.amd64.gs)) 0 else |_| -attr.E.FAULT,
                else => -attr.E.INVAL,
            };
            r.ax = @bitCast(v);
            vcpu.setUreg(u);
            return null;
        }
        const out = lsys.dispatch(l, u);
        p.noteMem();
        switch (out) {
            .ret => |r| {
                lsys.setReturn(u, r);
                vcpu.setUreg(u);
            },
            .exits => |s| {
                // linuxEnd releases the thread's futexes.
                setExits(s);
                return .{ .exited = s };
            },
            .clone => |cl| {
                try vcpu.getExtra(&p.extra);
                const r = m.linuxClone(p, l, u, cl);
                lsys.setReturn(u, @bitCast(r));
                vcpu.setUreg(u);
            },
            .exec => |e| {
                defer e.deinit(m.gpa);
                if (l.g.count() > 1) switch (m.groupExec(p, l, vcpu, e)) {
                    // The leader runs the new image; this thread is gone.
                    .handed_off => {
                        l.thread_exit = true;
                        return .{ .exited = "" };
                    },
                    .failed => {
                        const r = lsys.kerr();
                        l.traceLine("execve = {d} '{s}'", .{ r, kern.errstr() });
                        lsys.setReturn(u, @bitCast(r));
                        vcpu.setUreg(u);
                        return null;
                    },
                    .alone => {},
                };
                if (m.linuxExec(p, vcpu, e)) |_| {
                    // A 9front program has replaced the Linux state.
                    if (p.lx) |nl| nl.traceLine("execve = 0", .{}) else p.sys.traceRet("exec", 0);
                    u.* = p.ureg;
                    vcpu.setExtra(&p.extra);
                } else |_| {
                    const r = lsys.kerr();
                    l.traceLine("execve = {d} '{s}'", .{ r, kern.errstr() });
                    lsys.setReturn(u, @bitCast(r));
                }
                vcpu.setUreg(u);
            },
            .sigreturn => {
                var x: vmm.Extra = undefined;
                try vcpu.getExtra(&x);
                lsig.restore(l, &l.sig, u, &x) catch return .{ .killed = lsig.deathNote(lsig.SIGSEGV, &p.msg_buf) };
                vcpu.setExtra(&x);
                vcpu.setUreg(u);
                // A signal the handler held back can go now.
                if (l.sig.deliverable()) p.note_flag.store(true, .release);
            },
        }
        return null;
    }

    /// set_thread_area (`set`) or get_thread_area of a struct user_desc:
    /// i386 Linux's one TLS segment, GDT entry 6, whose base is the thread
    /// pointer that `Extra.tls` carries (design/0105-linux-i386.md, "TLS").
    /// Entry -1 asks for a free one, and gets 6; entries 7 and 8, which
    /// Linux also has, aren't there.
    fn threadArea(l: *lsys.Process, x: *vmm.X86Extra, set: bool, desc_va: u64) i64 {
        var d: [4]u32 = undefined;
        l.readMem(desc_va, std.mem.sliceAsBytes(&d)) catch return -attr.E.FAULT;
        const entry = d[0];
        if (set) {
            if (entry != lsig.i386_tls_entry and entry != 0xffff_ffff) return -attr.E.INVAL;
            if (entry == 0xffff_ffff) l.writeU32(desc_va, lsig.i386_tls_entry) catch return -attr.E.FAULT;
            x.tls = d[1];
            return 0;
        }
        if (entry != lsig.i386_tls_entry) return -attr.E.INVAL;
        // A flat, 32-bit, writable data segment in pages, as set.
        d = .{ entry, @truncate(x.tls), 0xfffff, 0x51 };
        l.writeMem(desc_va, std.mem.sliceAsBytes(&d)) catch return -attr.E.FAULT;
        return 0;
    }

    /// Sets the stack pointer of a Linux call's registers.
    fn setSp(u: *vmm.Ureg, sp: u64) void {
        switch (u.*) {
            inline else => |*r| r.sp = @truncate(sp),
        }
    }

    fn setTls(x: *vmm.Extra, v: u64) void {
        switch (x.*) {
            inline else => |*e| e.tls = v,
        }
    }

    /// An execve handed from a thread to its leader (design/0049-linux-
    /// threads.md): the new image runs with the leader's pid, as Linux
    /// gives it.
    const ExecReq = struct {
        e: lsys.Exec,
        done: std.Io.Event = .unset,
        ok: bool = false,
        err: [kern.ERRMAX]u8 = undefined,
    };

    const exec_note = "h9: execve";

    /// execve in a process with other threads: they're killed first. The
    /// leader execs itself once it's alone (`.alone`); another thread
    /// hands the exec to the leader and ends (`.handed_off`). A path that
    /// doesn't name a file fails before any thread is killed, so execvp's
    /// search along PATH leaves them be.
    fn groupExec(m: *Machine, p: *Proc, l: *lsys.Process, vcpu: *cpupool.Lease, e: lsys.Exec) enum { alone, handed_off, failed } {
        _ = vcpu;
        {
            const swap = !kc.inView();
            if (swap) kc.setSlash(true) catch {};
            defer if (swap) kc.setSlash(false) catch {};
            var st: [512]u8 = undefined;
            _ = kern.stat(e.path, &st) catch return .failed;
        }
        const g = l.g;
        if (!g.beginExec(l.pid)) return .failed;
        var buf: [256]u32 = undefined;
        for (g.others(l.pid, &buf)) |tid| {
            if (tid != g.tgid) _ = kern.postNote(tid, "kill", .user) catch {};
        }
        if (l.isLeader()) {
            m.waitAlone(p, g, 1);
            g.endExec();
            return .alone;
        }
        var req: ExecReq = .{ .e = e };
        g.exec_req = &req;
        _ = kern.postNote(g.tgid, exec_note, .user) catch {};
        req.done.waitUncancelable(m.io);
        if (req.ok) return .handed_off;
        kern.setErrstr(std.mem.sliceTo(&req.err, 0));
        return .failed;
    }

    /// Waits until the group has `n` members, or the job stops.
    fn waitAlone(m: *Machine, p: *Proc, g: *lsys.Group, n: usize) void {
        _ = m;
        while (g.count() > n and !p.job.stopping.load(.acquire)) kern.sleep(2) catch {};
    }

    /// The leader's side of a thread's execve: once only it and the
    /// thread are left, runs the exec, and tells the thread how it went.
    /// Returns whether there was one.
    fn leaderExec(m: *Machine, p: *Proc, vcpu: *cpupool.Lease, u: *vmm.Ureg) bool {
        const l = p.lx.?;
        const g = l.g;
        const req: *ExecReq = @ptrCast(@alignCast(g.exec_req orelse return false));
        g.exec_req = null;
        m.waitAlone(p, g, 2);
        if (m.linuxExec(p, vcpu, req.e)) |_| {
            req.ok = true;
            if (p.lx) |nl| {
                nl.restart = null;
                nl.traceLine("execve = 0 (from a thread)", .{});
            }
            u.* = p.ureg;
            vcpu.setExtra(&p.extra);
            vcpu.setUreg(u);
        } else |_| {
            const t = kern.errstr();
            const n = @min(t.len, req.err.len - 1);
            @memcpy(req.err[0..n], t[0..n]);
            req.err[n] = 0;
        }
        g.endExec();
        req.done.set(m.io);
        return true;
    }

    /// fork, vfork and clone: a child with a copy of the address space
    /// or, for vfork, the same one, while the parent waits for the child
    /// to exec or exit; or, with CLONE_THREAD, a thread: a process in the
    /// caller's thread group, sharing its memory (design/0049-linux-
    /// threads.md). Returns 0 in the child, and the child's pid (tid) or
    /// -errno in the caller.
    fn linuxClone(m: *Machine, p: *Proc, l: *lsys.Process, u: *const vmm.Ureg, cl: lsys.Clone) i64 {
        const vfork = cl.flags & lsys.CLONE_VFORK != 0;
        const thread = cl.flags & lsys.CLONE_THREAD != 0;
        const share = cl.flags & lsys.CLONE_VM != 0;
        const j = p.job;
        const c = j.newProc(if (p.serving) .{ .serving = p.conn } else .program) catch return -attr.E.AGAIN;
        const cx = m.gpa.create(lsys.Process) catch {
            j.dropProc(c);
            return -attr.E.NOMEM;
        };
        if (thread) {
            cx.* = l.threadChild(c.pid);
        } else {
            const cm = if (share) l.mm.get() else l.mm.fork() catch {
                m.gpa.destroy(cx);
                j.dropProc(c);
                return -attr.E.NOMEM;
            };
            cx.* = l.forkChild(c.pid, cm) catch {
                m.gpa.destroy(cx);
                cm.put();
                j.dropProc(c);
                return -attr.E.NOMEM;
            };
        }
        cx.joinGroup() catch {
            cx.mm.put();
            m.gpa.destroy(cx);
            j.dropProc(c);
            return -attr.E.NOMEM;
        };
        c.lx = cx;
        c.as = cx.mm.as;
        c.ureg = u.*;
        lsys.setReturn(&c.ureg, 0);
        if (cl.stack != 0) setSp(&c.ureg, cl.stack);
        c.extra = p.extra;
        if (cl.flags & lsys.CLONE_SETTLS != 0) setTls(&c.extra, cl.tls);
        if (cl.flags & lsys.CLONE_CHILD_CLEARTID != 0) cx.clear_tid = cl.ctid;
        if (cl.flags & lsys.CLONE_CHILD_SETTID != 0) cx.writeU32(cl.ctid, c.pid) catch {};
        if (cl.flags & lsys.CLONE_PARENT_SETTID != 0) l.writeU32(cl.ptid, c.pid) catch {};
        var done: std.Io.Event = .unset;
        if (vfork) c.vfork_done = &done;
        c.noteMem();
        var flag: c_int = kern.RF.PROC;
        if (cl.flags & lsys.CLONE_FILES == 0) flag |= kern.RF.FDG;
        // A thread's exit leaves no wait record: the group's is the leader's.
        // Its children are the leader's too, for any thread to wait for.
        if (thread) flag |= kern.RF.NOWAIT | kern.RF.LXTHREAD;
        const pid = c.pid;
        kern.fork(flag, pid, Proc, childMain, c) catch {
            c.dropLinux();
            j.dropProc(c);
            return -attr.E.AGAIN;
        };
        if (vfork) done.waitUncancelable(m.io);
        return pid;
    }

    /// Delivers a Linux process's signals (design/0018, "Signals"): turns
    /// its queued notes into pending signals, then runs the default action
    /// of the next deliverable one or enters its handler with a frame on
    /// the stack. A call that returned EINTR is restarted when no handler
    /// ran, or when the handler has SA_RESTART. Returns the note the
    /// process dies with, if it does.
    fn deliverLinux(m: *Machine, p: *Proc, vcpu: *cpupool.Lease, u: *vmm.Ureg, flagged: bool) vmm.Error!?[]const u8 {
        const l = p.lx.?;
        if (flagged) {
            var msg: [kern.ERRMAX]u8 = undefined;
            while (true) {
                switch (kern.popNote(&msg, u.pc())) {
                    .none => break,
                    .kill, .kill_debug => return lsig.deathNote(lsig.SIGKILL, &p.msg_buf),
                    .handle => {},
                }
                var tmp: [kern.ERRMAX]u8 = undefined;
                _ = kern.noted(.cont, &tmp) catch {};
                const text = std.mem.sliceTo(&msg, 0);
                if (std.mem.eql(u8, text, exec_note)) {
                    if (m.leaderExec(p, vcpu, u)) {
                        // A 9front program may have replaced the Linux state.
                        if (p.lx == null) return null;
                        l.sig.pending = 0;
                    }
                    continue;
                }
                // A note no signal stands for kills, as it does a 9front
                // process without a handler.
                const ns = lsig.noteSignal(text) orelse return p.keepNote(&msg);
                // A process's signal that this thread blocks goes to one
                // that doesn't, if there is one (design/0049-linux-threads.md).
                if (ns.signo != lsig.SIGKILL and l.sig.mask & lsig.bit(ns.signo) != 0 and !lsig.isThreadNote(text)) {
                    if (l.g.unblocked(l.pid, ns.signo)) |tid| {
                        var nb: [32]u8 = undefined;
                        if (kern.postNote(tid, lsig.threadNote(ns.signo, &nb), .user) catch false) continue;
                    }
                }
                _ = l.sig.post(ns.signo, ns.info);
            }
        }
        lsys.signalPosted(l);
        while (l.sig.next()) |signo| {
            const a = l.sig.actions[signo];
            if (a.handler == lsig.SIG_IGN) continue;
            if (a.handler == lsig.SIG_DFL) switch (lsig.defaultAction(signo)) {
                // Stops are job control's: until then they're ignored.
                .ignore, .cont, .stop => continue,
                .term, .core => return lsig.deathNote(signo, &p.msg_buf),
            };
            if (l.restart) |r| {
                l.restart = null;
                if (a.flags & lsig.SA_RESTART != 0 and !r.always_eintr) rewind(u, r);
            }
            const saved = l.sig.suspend_mask orelse l.sig.mask;
            l.sig.suspend_mask = null;
            var x: vmm.Extra = undefined;
            try vcpu.getExtra(&x);
            lsig.setup(l, &l.sig, u, &x, .{
                .signo = signo,
                .info = l.sig.info[signo],
                .act = a,
                .saved_mask = saved,
                .vdso = l.vdso,
                .vdso_sigreturn = elf.vdso_sigreturn_off,
            }) catch return lsig.deathNote(lsig.SIGSEGV, &p.msg_buf);
            l.sig.mask |= a.mask | (if (a.flags & lsig.SA_NODEFER != 0) 0 else lsig.bit(signo));
            l.sig.mask &= ~lsig.unblockable;
            if (a.flags & lsig.SA_RESETHAND != 0) l.sig.actions[signo] = .{};
            vcpu.setUreg(u);
            return null;
        }
        if (l.restart) |r| {
            l.restart = null;
            if (l.sig.suspend_mask) |sm| {
                l.sig.mask = sm;
                l.sig.suspend_mask = null;
            }
            rewind(u, r);
            vcpu.setUreg(u);
        }
        return null;
    }

    /// Backs the registers up to the syscall instruction, with its number
    /// and first argument as they were, so it runs again.
    fn rewind(u: *vmm.Ureg, r: lsys.Process.Restart) void {
        switch (u.*) {
            .arm64 => |*a| {
                a.pc = r.pc - 4;
                a.r[0] = r.arg0;
            },
            .amd64 => |*a| {
                a.pc = r.pc - 2;
                a.ax = r.nr;
            },
            // int 0x80, two bytes.
            .i386 => |*a| {
                a.pc = @truncate(r.pc - 2);
                a.ax = @truncate(r.nr);
            },
        }
    }

    /// devlinux's text files (src/kern/devlinux.c): /proc and /sys files
    /// made from the machine's state. `aux` is the process, for /proc/n
    /// files; the machine is the reader's. Runs on the reading thread,
    /// with the process's note lock held, so it doesn't block.
    fn linuxGen(aux: ?*anyopaque, name_z: [*:0]const u8, pid: c_ulong, buf: [*]u8, n: c_int) callconv(.c) c_int {
        _ = pid;
        var w: std.Io.Writer = .fixed(buf[0..@intCast(n)]);
        const name = std.mem.span(name_z);
        const eq = std.mem.eql;
        if (aux) |a| {
            const p: *Proc = @ptrCast(@alignCast(a));
            if (eq(u8, name, "maps")) {
                if (p.lx) |l| l.mm.mapsText(&w);
            } else if (eq(u8, name, "mounts")) {
                w.writeAll("rootfs / rootfs rw 0 0\n") catch {};
            } else return -1;
            return @intCast(w.end);
        }
        const reader: *Proc = @ptrCast(@alignCast(kern.aux() orelse return -1));
        const j = reader.job;
        const ncpu = j.ncpu;
        const arm = j.m.arch == .arm64;
        if (eq(u8, name, "cpuinfo")) {
            for (0..ncpu) |i| {
                if (arm) {
                    w.print("processor\t: {d}\nBogoMIPS\t: 48.00\nFeatures\t: fp asimd cpuid\nCPU implementer\t: 0x00\nCPU architecture: 8\nCPU variant\t: 0x0\nCPU part\t: 0x000\nCPU revision\t: 0\n\n", .{i}) catch {};
                } else {
                    w.print("processor\t: {d}\nvendor_id\t: h9\ncpu family\t: 6\nmodel\t\t: 0\nmodel name\t: h9 virtual CPU\ncpu cores\t: {d}\nflags\t\t: fpu tsc cx8 cmov mmx fxsr sse sse2\n\n", .{ i, ncpu }) catch {};
                }
            }
        } else if (eq(u8, name, "meminfo")) {
            const total_kb = (j.m.plan.memory orelse vmm.default_memory) / 1024;
            var used_kb: u64 = 0;
            {
                j.lockSpin();
                defer j.lock.unlock();
                for (j.procs.items) |q| used_kb += q.mem_kb.load(.acquire);
            }
            const free_kb = total_kb -| used_kb;
            w.print("MemTotal:       {d: >8} kB\nMemFree:        {d: >8} kB\nMemAvailable:   {d: >8} kB\nBuffers:               0 kB\nCached:                0 kB\nSwapTotal:             0 kB\nSwapFree:              0 kB\n", .{ total_kb, free_kb, free_kb }) catch {};
        } else if (eq(u8, name, "stat")) {
            w.writeAll("cpu  0 0 0 0 0 0 0 0 0 0\n") catch {};
            for (0..ncpu) |i| w.print("cpu{d} 0 0 0 0 0 0 0 0 0 0\n", .{i}) catch {};
            const boot = @divTrunc(kern.wallNs() - (kern.monoNs() - j.start_ns), std.time.ns_per_s);
            w.print("intr 0\nctxt 0\nbtime {d}\nprocesses {d}\nprocs_running 1\nprocs_blocked 0\n", .{ boot, j.next_pid -| 1 }) catch {};
        } else if (eq(u8, name, "uptime")) {
            const up_ns = kern.monoNs() - j.start_ns;
            const cs = @divTrunc(up_ns, 10 * std.time.ns_per_ms);
            const ucs: u64 = @intCast(@max(cs, 0));
            w.print("{d}.{d:0>2} 0.00\n", .{ ucs / 100, ucs % 100 }) catch {};
        } else if (eq(u8, name, "mounts")) {
            w.writeAll("rootfs / rootfs rw 0 0\n") catch {};
        } else if (eq(u8, name, "loadavg")) {
            w.print("0.00 0.00 0.00 1/{d} {d}\n", .{ j.procs.items.len, j.next_pid -| 1 }) catch {};
        } else if (eq(u8, name, "version")) {
            w.writeAll("Linux version 6.1.0-h9 (h9) #1 SMP h9\n") catch {};
        } else if (eq(u8, name, "filesystems")) {
            w.writeAll("nodev\tproc\nnodev\ttmpfs\n") catch {};
        } else if (eq(u8, name, "uuid") or eq(u8, name, "boot_id")) {
            var r: [16]u8 = undefined;
            j.m.io.random(&r);
            r[6] = (r[6] & 0x0f) | 0x40;
            r[8] = (r[8] & 0x3f) | 0x80;
            const x = std.fmt.bytesToHex(r, .lower);
            w.print("{s}-{s}-{s}-{s}-{s}\n", .{ x[0..8], x[8..12], x[12..16], x[16..20], x[20..32] }) catch {};
        } else if (eq(u8, name, "osrelease")) {
            w.writeAll("6.1.0-h9\n") catch {};
        } else if (eq(u8, name, "hostname")) {
            w.writeAll("h9\n") catch {};
        } else if (eq(u8, name, "resolv.conf")) {
            for (j.m.opts.nameservers) |ns| w.print("nameserver {s}\n", .{ns}) catch {};
        } else if (eq(u8, name, "online") or eq(u8, name, "possible")) {
            if (ncpu <= 1) w.writeAll("0\n") catch {} else w.print("0-{d}\n", .{ncpu - 1}) catch {};
        } else return -1;
        return @intCast(w.end);
    }

    /// Host.kill: posts signal `signo` as a note (design/0018, "Signals")
    /// to the processes `pid` names. Stops and continues aren't posted to
    /// 9front processes, which never stop. A process's signal goes to its
    /// thread group's leader, which passes it on to a thread that doesn't
    /// block it (`deliverLinux`); a thread's (tgkill) goes to that thread
    /// alone (design/0049-linux-threads.md).
    fn linuxKill(ctx: *anyopaque, from: *lsys.Process, pid: i64, signo: u8, thread: ?lsys.ThreadKill) i64 {
        const j: *Job = @ptrCast(@alignCast(ctx));
        const Target = struct { pid: u32, linux: bool };
        var targets: [256]Target = undefined;
        var n: usize = 0;
        {
            j.lockSpin();
            defer j.lock.unlock();
            for (j.procs.items) |q| {
                const ql = q.lx;
                const qg: ?u32 = if (ql) |x| x.pgid else null;
                // Only a group's leader stands for the process.
                const leader = if (ql) |x| x.isLeader() else true;
                const want = if (thread) |t|
                    q.pid == pid and (t.tgid == 0 or (ql != null and ql.?.tgid() == t.tgid))
                else if (pid > 0)
                    q.pid == pid
                else if (pid == -1)
                    leader and q.pid != from.tgid()
                else if (pid == 0)
                    leader and qg != null and qg.? == from.pgid
                else
                    leader and qg != null and qg.? == @as(u64, @intCast(-pid));
                if (!want or q.kproc == null) continue;
                if (n == targets.len) break;
                targets[n] = .{ .pid = q.pid, .linux = ql != null };
                n += 1;
            }
        }
        if (n == 0) return -attr.E.SRCH;
        if (signo == 0) return 0;
        var buf: [32]u8 = undefined;
        const note = if (signo == lsig.SIGKILL) "kill" else if (thread != null) lsig.threadNote(signo, &buf) else lsig.signalNote(signo, &buf);
        for (targets[0..n]) |t| {
            if (!t.linux) switch (lsig.defaultAction(signo)) {
                .stop, .cont => continue,
                else => {},
            };
            _ = kern.postNote(t.pid, note, .user) catch {};
        }
        return 0;
    }

    fn linuxPgid(ctx: *anyopaque, pid: u32) ?u32 {
        const j: *Job = @ptrCast(@alignCast(ctx));
        j.lockSpin();
        defer j.lock.unlock();
        for (j.procs.items) |q| if (q.pid == pid) return if (q.lx) |ql| ql.pgid else q.pid;
        return null;
    }

    /// rfork. With RF.PROC, starts a child that resumes from `u` with 0
    /// returned, and returns its pid; without, changes the caller's groups.
    /// On error the error string is set.
    fn fork(m: *Machine, p: *Proc, flags: u32, u: *const vmm.Ureg) error{Failed}!u32 {
        const flag: c_int = @bitCast(flags);
        if (flags & kern.RF.PROC == 0) {
            kern.rfork(flag) catch return error.Failed;
            return 0;
        }
        const j = p.job;
        // 9front's error when it runs out of procs.
        const c = j.newProc(if (p.serving) .{ .serving = p.conn } else .program) catch return failWith("no procs");
        const cas = m.backend.newAddressSpace() catch {
            j.dropProc(c);
            return failWith("no procs");
        };
        c.as = cas;
        c.segs = p.segs.fork(cas, flags & kern.RF.MEM != 0) catch {
            cas.destroy();
            j.dropProc(c);
            return failWith("virtual memory allocation failed");
        };
        loader.setTosPid(cas, m.arch, p.tos, c.pid);
        c.tos = p.tos;
        c.ureg = u.*;
        c.ureg.setReturn(0);
        c.extra = p.extra;
        if (p.image) |b| c.image = m.gpa.dupe(u8, b) catch null;
        c.initSys();
        c.noteMem();
        // The handler is inherited; queued notes and handler state aren't.
        c.sys.notify = p.sys.notify;
        // The child may run, exit and free itself before kern.fork returns.
        const pid = c.pid;
        kern.fork(flag, pid, Proc, childMain, c) catch {
            if (c.image) |b| m.gpa.free(b);
            c.segs.release(cas);
            cas.destroy();
            j.dropProc(c);
            return error.Failed;
        };
        return pid;
    }

    fn failWith(msg: []const u8) error{Failed} {
        kern.setErrstr(msg);
        return error.Failed;
    }

    const max_indir = 8;
    const ebadexec = "exec header invalid";

    /// exec, as 9front's sysexec: loads the program (following up to 8
    /// levels of #! interpreters) into a new address space, and only then
    /// replaces the process's memory, closes its close-on-exec fds and
    /// resets its registers. On error the process is unchanged and the
    /// error string is set.
    fn exec(m: *Machine, p: *Proc, vcpu: *cpupool.Lease, e: syscall.Exec) error{Failed}!void {
        var arena_state: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // The last path element names the process.
        const elem = basename(e.path);

        const first = readFile(arena, e.path) catch |err| return execError(err);
        const prog = interpret(arena, e.path, first, @ptrCast(e.argv)) catch |err| return execError(err);
        const bytes = prog.bytes;
        if (elf.isElf(bytes)) {
            const envp = linuxEnv(arena) catch return failWith("no memory");
            return m.execLinux(p, vcpu, arena, e.path, bytes, prog.argv, envp);
        }
        const hdr = aout.parse(bytes) catch return failWith(ebadexec);
        if (hdr.arch != m.arch) return failWith(ebadexec);

        const nas = m.backend.newAddressSpace() catch return failWith("virtual memory allocation failed");
        var img = loader.load(m.gpa, m.backend, nas, bytes, prog.argv, p.pid) catch |err| {
            nas.destroy();
            return failWith(switch (err) {
                error.BadExec, error.Truncated, error.BadMagic => ebadexec,
                else => "virtual memory allocation failed",
            });
        };
        // segattach's segments carry over, except SG_CEXEC ones.
        img.segs.inherit(&p.segs, nas) catch {
            img.segs.release(nas);
            nas.destroy();
            return failWith("virtual memory allocation failed");
        };
        vcpu.setAddressSpace(nas) catch {
            img.segs.release(nas);
            nas.destroy();
            return failWith("virtual memory allocation failed");
        };

        // Committed.
        const was_linux = p.lx != null;
        if (was_linux) {
            p.segs.replace(nas, img.segs);
            // /proc/n/mem may be reading through the old space.
            p.dbgLock();
            p.dropLinux();
        } else {
            const old = p.as.?;
            p.segs.replace(old, img.segs);
            p.dbgLock();
            old.destroy();
        }
        p.as = nas;
        p.dbg_lock.unlock();
        if (was_linux) {
            // From the Linux personality back to 9front's, whose state
            // was never made.
            kern.setNotify(false);
            if (kc.inView()) kc.setSlash(false) catch {};
            p.initSys();
        }
        p.tos = img.tos;
        p.sys.as = nas;
        p.sys.notify = 0;
        p.noteureg = 0;
        p.note_extra = null;
        kern.execNotes();
        p.ureg = .initExec(img.arch, img.entry, img.sp, img.tos);
        p.extra = .initExec(img.arch);
        p.keepImage(bytes);
        p.noteMem();
        kern.setArgs(prog.argv);
        kern.closeExec();
        var name_buf: [kern.ERRMAX]u8 = undefined;
        kern.setText(std.fmt.bufPrintZ(&name_buf, "{s}", .{elem}) catch "a.out");
        kern.setTextPath(arena.dupeZ(u8, prog.path) catch null);
        // With ctl hang, it stops before its first instruction.
        if (kern.execHang()) p.stop_flag.store(true, .release);
    }

    /// A loaded program: the binary's bytes, the path it was read from
    /// (the last interpreter's for a #! script), and its argv.
    const Image = struct { bytes: []const u8, path: []const u8, argv: []const []const u8 };

    /// Follows up to 8 levels of #! interpreters from the file at `path`,
    /// whose contents are `bytes`, and returns the binary to load and its
    /// argv. Shared by exec and the first process. A failed stat or open
    /// sets the error string and gives NotFound or NotExecutable; a bad
    /// #! line gives BadExec.
    fn interpret(arena: std.mem.Allocator, path: []const u8, bytes: []const u8, argv: []const []const u8) RunError!Image {
        var pre: std.ArrayList([]const u8) = .empty;
        var cur = bytes;
        var bin = path;
        var indir: usize = 0;
        while (std.mem.startsWith(u8, cur, "#!")) : (indir += 1) {
            if (indir >= max_indir) return error.BadExec;
            const head = cur[0..@min(cur.len, 256)];
            const nl = std.mem.indexOfScalar(u8, head, '\n') orelse return error.BadExec;
            var toks: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, head[2..nl], " \t\r");
            while (it.next()) |t| try toks.append(arena, t);
            if (toks.items.len < 1 or toks.items.len >= 32) return error.BadExec;
            if (indir == 0) try pre.append(arena, path);
            try pre.insertSlice(arena, 0, toks.items);
            const interp = try std.fmt.allocPrintSentinel(arena, "{s}", .{toks.items[0]}, 0);
            cur = try readFile(arena, interp);
            bin = interp;
        }
        if (indir == 0) return .{ .bytes = cur, .path = path, .argv = argv };

        // As 9front builds it: the interpreters' arguments (the outermost's
        // first) and the script's full name, with the first interpreter's
        // name swapped for the script's last path element, then the
        // caller's arguments after argv[0]. So `#!/bin/rc` running /bin/x
        // with argv `x a` gets `x /bin/x a`.
        var out: std.ArrayList([]const u8) = .empty;
        try out.append(arena, basename(path));
        try out.appendSlice(arena, pre.items[1..]);
        if (argv.len > 1) try out.appendSlice(arena, argv[1..]);
        return .{ .bytes = cur, .path = bin, .argv = out.items };
    }

    fn execError(err: RunError) error{Failed} {
        // A failed stat or open has set the error string already.
        return switch (err) {
            error.NotFound => error.Failed,
            error.OutOfMemory => failWith("no memory"),
            else => failWith(ebadexec),
        };
    }

    fn basename(path: []const u8) []const u8 {
        const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
        return path[i + 1 ..];
    }

    fn keep(m: *Machine, s: []const u8) []const u8 {
        const n = @min(s.len, m.msg_buf.len);
        @memmove(m.msg_buf[0..n], s[0..n]);
        return m.msg_buf[0..n];
    }

    /// Like `keep`, into a separate buffer, for `err_msg`.
    fn keep2(m: *Machine, s: []const u8) []const u8 {
        const n = @min(s.len, m.err_buf.len);
        @memmove(m.err_buf[0..n], s[0..n]);
        return m.err_buf[0..n];
    }

    fn fail(m: *Machine, comptime fmt: []const u8, args: anytype) error{NamespaceFailed} {
        m.err_msg = std.fmt.bufPrint(&m.msg_buf, fmt, args) catch fmt;
        return error.NamespaceFailed;
    }

    const Built = struct {
        /// The root overlay's instance, if the plan has one.
        root_overlay: ?u32 = null,
        /// Where the cwd was set, if anywhere.
        cwd: ?[:0]const u8 = null,
    };

    /// Builds the first Proc's namespace from the plan (SPEC.md, "Boot
    /// sequence"), then sets the device mask.
    fn buildNamespace(m: *Machine, con_id: u32) RunError!Built {
        var root_ov: ?u32 = null;
        var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
        var buf2: [std.fs.max_path_bytes + 8]u8 = undefined;
        var cwd_at: ?[:0]const u8 = null;
        if (m.opts.root) |r| if (r != .dir) try m.connectRoot(r);
        for (m.plan.binds) |b| {
            if (b.mount) {
                try m.mountRoot(b);
                continue;
            }
            const from = if (b.console)
                try std.fmt.bufPrintZ(&buf, "{s}{d}{s}", .{ b.from, con_id, if (b.cons_file) "/cons" else "" })
            else
                try std.fmt.bufPrintZ(&buf, "{s}", .{b.from});
            var flag: c_int = switch (b.flag) {
                .repl => kern.MREPL,
                .before => kern.MBEFORE,
                .after => kern.MAFTER,
            };
            if (b.create) flag |= kern.MCREATE;
            const to = try std.fmt.bufPrintZ(&buf2, "{s}", .{b.to});
            if (bindOrOverlay(from, b.lower, b.contained, to, flag, &buf)) |id| {
                if (std.mem.eql(u8, b.to, "/mnt/term/cwd")) cwd_at = "/mnt/term/cwd";
                if (std.mem.eql(u8, b.to, policy.linux_view ++ "/mnt/term/cwd")) cwd_at = policy.linux_view ++ "/mnt/term/cwd";
                if (std.mem.eql(u8, b.to, "/") and id != null) root_ov = id;
                continue;
            } else |_| {}
            if (b.fallback) |fb| {
                if (bindOrOverlay(from, b.lower, b.contained, try std.fmt.bufPrintZ(&buf2, "{s}", .{fb}), flag, &buf)) |_| {
                    if (std.mem.eql(u8, b.to, "/mnt/term/cwd")) cwd_at = "/mnt/term";
                    if (std.mem.eql(u8, b.to, policy.linux_view ++ "/mnt/term/cwd")) cwd_at = policy.linux_view ++ "/mnt/term";
                    continue;
                } else |_| {}
            }
            if (!b.optional) return m.fail("bind {s} {s}: {s}", .{ b.from, b.to, kern.errstr() });
        }
        if (cwd_at) |at| kern.chdir(at) catch return m.fail("cwd: {s}", .{kern.errstr()});
        if (m.plan.root_overlay) makeHome();
        if (m.opts.linux_root != null) linuxEtc();

        // fds 0-2 on the console.
        const in = kern.open("/dev/cons", kern.OREAD) catch return m.fail("open /dev/cons: {s}", .{kern.errstr()});
        const out = kern.open("/dev/cons", kern.OWRITE) catch return m.fail("open /dev/cons: {s}", .{kern.errstr()});
        const err = kern.open("/dev/stderr", kern.OWRITE) catch return m.fail("open /dev/stderr: {s}", .{kern.errstr()});
        if (in != 0 or out != 1 or err != 2) return m.fail("console fds are {d} {d} {d}", .{ in, out, err });

        try m.setEnv();

        // Existing binds keep working, but masked devices can't be attached
        // again to reach more of the host.
        if (m.plan.devmask.len > 0) kern.devmask(try std.fmt.bufPrintZ(&buf, "{s}", .{m.plan.devmask}));
        return .{ .root_overlay = root_ov, .cwd = cwd_at };
    }

    /// Makes `$home`, `/usr/$user`, in the root's overlay if the root
    /// doesn't have it (design/0011-overlay.md). Best effort: a run
    /// without it works as it did with a read-only root.
    fn makeHome() void {
        var buf: [128]u8 = undefined;
        var st: [512]u8 = undefined;
        const home = std.fmt.bufPrintZ(&buf, "/usr/{s}", .{kern.user()}) catch return;
        if (kern.stat(home, &st)) |_| return else |_| {}
        for ([_][:0]const u8{ "/usr", home }) |dir| {
            if (kern.stat(dir, &st)) |_| continue else |_| {}
            const fd = kern.create(dir, kern.OREAD, dmdir | 0o775) catch return;
            kern.close(fd) catch {};
        }
    }

    const dmdir: u32 = 0x80000000;

    /// Binds devlinux's /etc files after the Linux root's /etc when the
    /// root has no resolv.conf, as Alpine's minirootfs hasn't
    /// (design/0050-linux-net.md). Best effort: a root without /etc is
    /// left as it is.
    fn linuxEtc() void {
        var st: [512]u8 = undefined;
        const lv = policy.linux_view;
        if (kern.stat(lv ++ "/etc/resolv.conf", &st)) |_| return else |_| {}
        // /etc over itself first, creatable, so a file made in /etc (apk's
        // own, say) goes to the root's directory, not to #λetc.
        kern.bind(lv ++ "/etc", lv ++ "/etc", kern.MREPL | kern.MCREATE) catch return;
        kern.bind(lv ++ "etc", lv ++ "/etc", kern.MAFTER) catch {};
    }

    /// Connects to a 9P root and posts the connection as `#s/root`
    /// (design/0013-9p-roots.md), where the board holds it for the
    /// machine's life. h9 makes the connection, not the guest, so the
    /// network policy doesn't apply to it, and a TCP root is dialed through
    /// devip by device path whether or not `#I` is bound or masked later.
    fn connectRoot(m: *Machine, r: Root) RunError!void {
        const addr = m.plan.root_9p.?.addr;
        kern.setPlan(null);
        defer kern.setPlan(&m.plan);
        var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
        const fd = switch (r) {
            .dir => unreachable,
            .ws => |u| return m.postRoot(try m.connectStream(u, .{
                .headers = m.opts.root_headers,
                .ca_file = m.opts.root_ca,
                .proxy = m.opts.proxy orelse .{},
            }, "root")),
            // `#ℓ` dials a TCP or unix socket root itself, so it can
            // dial again if the server goes (9P2000.L.Z). A comma would
            // split the dial's list.
            .tcp => |a| return m.postDotl(dotlConv("dial {s}", a)),
            .unix => |path| if (std.mem.indexOfScalar(u8, path, ',') == null)
                return m.postDotl(dotlConv("dial unix!{s}", path))
            else
                kern.unixDial(std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return m.fail("root {s}: name too long", .{addr})),
        } catch return m.fail("root {s}: {s}", .{ addr, kern.errstr() });
        return m.postRoot(fd);
    }

    /// Posts a root's connection `fd` as `#s/root`, through a `#ℓ`
    /// conversation (design/0022-dotl.md), so a 9P2000.L server works as a
    /// root and a 9P2000 one passes through. Closes `fd`.
    fn postRoot(m: *Machine, conn: u31) RunError!void {
        defer kern.close(conn) catch {};
        return m.postDotl(dotlConv("fd {d}", conn));
    }

    /// Posts the data file of a `#ℓ` conversation, `data` from dotlConv,
    /// as `#s/root`.
    fn postDotl(m: *Machine, data: kern.Error!u31) RunError!void {
        const addr = m.plan.root_9p.?.addr;
        const fd = data catch return m.fail("root {f}: {s}", .{ ws.Url.elide(addr), kern.errstr() });
        defer kern.close(fd) catch {};
        const srv = kern.create(policy.root_srv, kern.OWRITE, 0o666) catch return m.fail("root {f}: post {s}: {s}", .{ ws.Url.elide(addr), policy.root_srv, kern.errstr() });
        defer kern.close(srv) catch {};
        var num: [16]u8 = undefined;
        _ = kern.pwrite(srv, std.fmt.bufPrint(&num, "{d}", .{fd}) catch unreachable, 0) catch return m.fail("root {f}: post {s}: {s}", .{ ws.Url.elide(addr), policy.root_srv, kern.errstr() });
    }

    /// Starts a `#ℓ` conversation with the ctl message `fmt` ("fd N" for
    /// a connection, which can be closed after, or "dial ADDR") and
    /// returns an fd on its data file, which devmnt mounts.
    fn dotlConv(comptime fmt: []const u8, arg: anytype) kern.Error!u31 {
        const dev = "#" ++ policy.dotl_dev ++ "/dotl/";
        const clone = try kern.open(dev ++ "clone", kern.ORDWR);
        defer kern.close(clone) catch {};
        var nbuf: [16]u8 = undefined;
        const n = std.mem.trim(u8, nbuf[0..try kern.pread(clone, &nbuf, 0)], " \n");
        var cmd: [std.fs.max_path_bytes + 16]u8 = undefined;
        _ = try kern.pwrite(clone, std.fmt.bufPrint(&cmd, fmt, .{arg}) catch return error.Kern, 0);
        var path: [64]u8 = undefined;
        return kern.open(std.fmt.bufPrintZ(&path, dev ++ "{s}/data", .{n}) catch unreachable, kern.ORDWR);
    }

    /// Connects a host-made WebSocket stream to `url` (`what` names it in
    /// errors: "root", or a namespace file's mount) and returns an fd on
    /// its channel. The connect waits in the kernel, so a note or the
    /// timeout interrupts it.
    fn connectStream(m: *Machine, url: []const u8, o: hstream.HostOptions, comptime what: []const u8) RunError!u31 {
        const shown = ws.Url.elide(url);
        hstream.setIo(m.io);
        const mc = kern.mach() orelse return m.fail(what ++ " {f}: not a machine process", .{shown});
        const owner = @intFromPtr(mc);
        mc.put();
        const id = hstream.openHost(owner, url, o) catch |e| return m.fail(what ++ " {f}: {s}", .{ shown, switch (e) {
            error.BadUrl => "bad URL",
            error.TooManyStreams => "too many streams",
            error.OutOfMemory => "out of memory",
            error.SystemResources => "can't start a thread",
        } });
        defer hstream.release(id);
        kern.hstreamWait(id) catch return m.fail(what ++ " {f}: {s}", .{ shown, kern.errstr() });
        return kern.hstreamFd(id) catch return m.fail(what ++ " {f}: {s}", .{ shown, kern.errstr() });
    }

    /// Mounts the 9P root's posted connection (`b.from`) at `b.to`. devmnt
    /// sends the calling process's user as the attach uname, so the first
    /// Proc takes on --root-user for the attach and gets its own back after.
    fn mountRoot(m: *Machine, b: policy.Bind) RunError!void {
        const r = m.plan.root_9p.?;
        var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
        var buf2: [std.fs.max_path_bytes + 8]u8 = undefined;
        const shown = ws.Url.elide(r.addr);
        const fd = kern.open(try std.fmt.bufPrintZ(&buf, "{s}", .{b.from}), kern.ORDWR) catch return m.fail("root {f}: {s}", .{ shown, kern.errstr() });
        defer kern.close(fd) catch {};
        var saved: [kern.ERRMAX]u8 = undefined;
        const own = kern.procUser();
        @memcpy(saved[0..own.len], own);
        saved[own.len] = 0;
        if (r.user) |u| kern.setProcUser(try std.fmt.bufPrintZ(&buf2, "{s}", .{u}));
        defer if (r.user != null) kern.setProcUser(saved[0..own.len :0]);
        const spec = try std.fmt.bufPrintZ(&buf2, "{s}", .{b.spec});
        _ = kern.mount(fd, -1, try std.fmt.bufPrintZ(&buf, "{s}", .{b.to}), kern.MREPL, spec) catch return m.fail("root {f}: {s}", .{ shown, kern.errstr() });
    }

    /// Binds `from` over `to`, or with `lower` (a host path), a fresh `#O`
    /// overlay over `#U<lower>` (`#U!c<lower>` when `contained`). A bare
    /// `#O` with no `lower` is a fresh overlay over what `to` is now, as in
    /// a namespace file. `buf` is scratch, and may hold `from`.
    /// Returns the overlay's instance, or null for a plain bind.
    fn bindOrOverlay(from: [:0]const u8, lower: ?[]const u8, contained: bool, to: [:0]const u8, flag: c_int, buf: []u8) kern.Error!?u32 {
        const l = lower orelse {
            if (std.mem.eql(u8, from, "#O")) return try overlay(to, to, flag);
            try kern.bind(from, to, flag);
            return null;
        };
        return try overlay(std.fmt.bufPrintZ(buf, "#U{s}{s}", .{ if (contained) "!c" else "", l }) catch return error.Kern, to, flag);
    }

    /// Binds a fresh `#O` overlay over the directory `lower` at `to`, and
    /// returns its instance.
    fn overlay(lower: [:0]const u8, to: [:0]const u8, flag: c_int) kern.Error!u32 {
        const id = try kern.overlayNew(lower);
        var spec: [16]u8 = undefined;
        kern.bind(std.fmt.bufPrintZ(&spec, "#O{d}", .{id}) catch unreachable, to, flag) catch |e| {
            kern.overlayDrop(id);
            return e;
        };
        return id;
    }

    /// Runs a namespace file's operations, as newns does: a failed bind or
    /// mount is skipped, and only a syntax error fails the run. The device
    /// mask is already set, so it can't reach masked devices. Returns
    /// whether the file has a `cd`.
    fn replayNamespace(m: *Machine, text: []const u8, con_id: u32) RunError!bool {
        var cd = false;
        var arena_state: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var line: usize = 0;
        const ops = newns.parse(arena, text, &line) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => return m.fail("--ns: line {d}: syntax error", .{line}),
        };
        for (ops) |op| switch (op) {
            // A bare #O is a fresh overlay over what the target is now.
            .bind => |b| if (std.mem.eql(u8, b.from, "#O")) {
                const to = try m.nsPath(arena, b.to, con_id);
                _ = overlay(to, to, mountFlag(b.flag)) catch {};
            } else kern.bind(try m.nsPath(arena, b.from, con_id), try m.nsPath(arena, b.to, con_id), mountFlag(b.flag)) catch {},
            // A WebSocket URL is connected by h9, as a root is; unlike
            // other failures, one that fails stops the run.
            .mount => |mt| if (ws.Url.is(mt.file)) {
                if (m.plan.write == .none) return m.fail("mount {f}: --write=none can't be enforced on a WebSocket mount", .{ws.Url.elide(mt.file)});
                const fd = try m.connectStream(mt.file, .{ .proxy = m.opts.proxy orelse .{} }, "mount");
                defer kern.close(fd) catch {};
                _ = kern.mount(fd, -1, try m.nsPath(arena, mt.to, con_id), mountFlag(mt.flag), try arena.dupeZ(u8, mt.spec)) catch
                    return m.fail("mount {f}: {s}", .{ ws.Url.elide(mt.file), kern.errstr() });
            } else {
                const fd = kern.open(try m.nsPath(arena, mt.file, con_id), kern.ORDWR) catch continue;
                defer kern.close(fd) catch {};
                _ = kern.mount(fd, -1, try m.nsPath(arena, mt.to, con_id), mountFlag(mt.flag), try arena.dupeZ(u8, mt.spec)) catch {};
            },
            .unmount => |u| kern.unmount(if (u.from) |f| try m.nsPath(arena, f, con_id) else null, try m.nsPath(arena, u.to, con_id)) catch {},
            .cd => |d| {
                cd = true;
                kern.chdir(try m.nsPath(arena, d, con_id)) catch {};
            },
            // newns's rfork(RFCNAMEG): an empty namespace, keeping the mask.
            .clear => kern.rfork(kern.RF.CNAMEG) catch {},
        };
        return cd;
    }

    /// A namespace-file path, with --print's `<id>` console placeholder
    /// filled in.
    fn nsPath(_: *Machine, arena: std.mem.Allocator, p: []const u8, con_id: u32) RunError![:0]const u8 {
        if (std.mem.indexOf(u8, p, "<id>")) |i| return std.fmt.allocPrintSentinel(arena, "{s}{d}{s}", .{ p[0..i], con_id, p[i + 4 ..] }, 0);
        return arena.dupeZ(u8, p);
    }

    fn mountFlag(f: newns.Flag) c_int {
        var flag: c_int = switch (f.order) {
            .repl => kern.MREPL,
            .before => kern.MBEFORE,
            .after => kern.MAFTER,
        };
        if (f.create) flag |= kern.MCREATE;
        if (f.cache) flag |= kern.MCACHE;
        return flag;
    }

    fn setEnv(m: *Machine) RunError!void {
        const user = kern.user();
        var home_buf: [96]u8 = undefined;
        const defaults = [_]EnvVar{
            .{ .name = "user", .value = user },
            .{ .name = "home", .value = std.fmt.bufPrint(&home_buf, "/usr/{s}", .{user}) catch "/" },
            .{ .name = "cputype", .value = m.arch.name() },
            .{ .name = "objtype", .value = m.arch.name() },
            .{ .name = "sysname", .value = "h9" },
            .{ .name = "service", .value = "terminal" },
        };
        for (defaults) |e| try putEnv(e.name, e.value);
        // As 9front's boot does: the local timezone, for date and ls -l.
        copyFile("/adm/timezone/local", "/env/timezone");
        // rc lists end each element with a NUL: path=(. /bin).
        try putEnv("path", ".\x00/bin\x00");
        // mk's job count, as 9front's termrc sets it from /dev/sysstat:
        // the CPUs the machine may use (design/0010-self-host.md).
        var nproc_buf: [16]u8 = undefined;
        try putEnv("NPROC", std.fmt.bufPrint(&nproc_buf, "{d}", .{m.cpuCount()}) catch unreachable);
        // The listeners' bound addresses, an rc list (design/0035-serve.md).
        if (m.serve_addrs.len > 0) {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(m.gpa);
            for (m.serve_addrs) |a| {
                try list.appendSlice(m.gpa, a);
                try list.append(m.gpa, 0);
            }
            try putEnv("serve", list.items);
        }
        for (m.opts.env) |e| try putEnv(e.name, e.value);
    }

    fn putEnv(name: []const u8, value: []const u8) RunError!void {
        var buf: [kern.ERRMAX + 8]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "/env/{s}", .{name}) catch return error.NamespaceFailed;
        const fd = kern.create(path, kern.OWRITE, 0o664) catch return;
        defer kern.close(fd) catch {};
        _ = kern.pwrite(fd, value, 0) catch {};
    }

    fn copyFile(from: [:0]const u8, to: [:0]const u8) void {
        const in = kern.open(from, kern.OREAD) catch return;
        defer kern.close(in) catch {};
        var buf: [4096]u8 = undefined;
        const n = kern.pread(in, &buf, 0) catch return;
        const out = kern.create(to, kern.OWRITE, 0o664) catch return;
        defer kern.close(out) catch {};
        _ = kern.pwrite(out, buf[0..n], 0) catch {};
    }

    /// Reads a guest program, searching $path for bare names, and returns
    /// the path it was found at with its contents.
    fn readGuest(m: *Machine, arena: std.mem.Allocator, name: []const u8) RunError!struct { path: []const u8, bytes: []u8 } {
        const direct = name.len > 0 and (name[0] == '/' or std.mem.startsWith(u8, name, "./") or std.mem.startsWith(u8, name, "../"));
        if (direct) {
            const path = try std.fmt.allocPrintSentinel(arena, "{s}", .{name}, 0);
            const b = readFile(arena, path) catch |e| {
                m.err_msg = kern.errstr();
                return e;
            };
            return .{ .path = path, .bytes = b };
        }
        var last: RunError = error.NotFound;
        for ([_][]const u8{ ".", "/bin" }) |dir| {
            const path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, name }, 0);
            if (readFile(arena, path)) |b| return .{ .path = path, .bytes = b } else |e| last = e;
        }
        m.err_msg = "file does not exist";
        return last;
    }

    fn readFile(gpa: std.mem.Allocator, path: [:0]const u8) RunError![]u8 {
        var dbuf: [512]u8 = undefined;
        const n = kern.stat(path, &dbuf) catch return error.NotFound;
        // Dir: size[2] type[2] dev[4] qid[13] mode[4] ... length[8] at 2+2+4+13+4+4+4 = 33.
        if (n < 41) return error.NotExecutable;
        const mode = std.mem.readInt(u32, dbuf[21..25], .little);
        if (mode & 0x80000000 != 0) return error.NotExecutable;
        const len = std.mem.readInt(u64, dbuf[33..41], .little);
        if (len > 1 << 30) return error.NotExecutable;
        const fd = kern.open(path, kern.OREAD) catch return error.NotExecutable;
        defer kern.close(fd) catch {};
        const bytes = try gpa.alloc(u8, @intCast(len));
        var off: usize = 0;
        while (off < len) {
            const got = kern.pread(fd, bytes[off..], @intCast(off)) catch return error.NotExecutable;
            if (got == 0) break;
            off += got;
        }
        return bytes[0..off];
    }
};

/// The largest FPsave: arm64's, 32 128-bit registers then FPCR and FPSR
/// as 32-bit words (libmach's FPREGSIZE, 520 bytes).
const fpsave_max = 32 * 16 + 8;

/// The FP registers in 9front's FPsave layout, as /proc/n/fpregs serves
/// them: on arm64 `regs[32][2]`, `control`, `status`; on amd64 and 386
/// the FXSAVE area.
fn fpsave(x: *const vmm.Extra, buf: *[fpsave_max]u8) []u8 {
    switch (x.*) {
        .arm64 => |a| {
            for (a.v, 0..) |q, i| std.mem.writeInt(u128, buf[i * 16 ..][0..16], q, .little);
            std.mem.writeInt(u32, buf[512..516], @truncate(a.fpcr), .little);
            std.mem.writeInt(u32, buf[516..520], @truncate(a.fpsr), .little);
            return buf[0..fpsave_max];
        },
        .amd64, .i386 => |t| {
            @memcpy(buf[0..@sizeOf(vmm.Fxsave)], std.mem.asBytes(&t.fx));
            return buf[0..@sizeOf(vmm.Fxsave)];
        },
    }
}

/// Takes back an FPsave image from `fpsave`, keeping the thread pointer.
fn setFpsave(x: *vmm.Extra, img: []const u8) void {
    switch (x.*) {
        .arm64 => |*a| {
            for (&a.v, 0..) |*q, i| q.* = std.mem.readInt(u128, img[i * 16 ..][0..16], .little);
            a.fpcr = std.mem.readInt(u32, img[512..516], .little);
            a.fpsr = std.mem.readInt(u32, img[516..520], .little);
        },
        .amd64, .i386 => |*t| {
            @memcpy(std.mem.asBytes(&t.fx), img[0..@sizeOf(vmm.Fxsave)]);
            // MXCSR's reserved bits would make FXRSTOR fault.
            t.fx.mxcsr &= 0xffff;
        },
    }
}

/// Prints a fault for `--dump-on-fault`: the Ureg, the faulting address and
/// the PC symbolized from the a.out symbol table.
fn dumpFault(w: *std.Io.Writer, u: *const vmm.Ureg, f: vmm.Fault, bytes: []const u8) void {
    dumpFaultTo(w, u, f, bytes) catch {};
    w.flush() catch {};
}

fn dumpFaultTo(w: *std.Io.Writer, u: *const vmm.Ureg, f: vmm.Fault, bytes: []const u8) std.Io.Writer.Error!void {
    try w.print("h9: fault: {t} addr=0x{x} syndrome=0x{x}\n", .{ f.access, f.addr, f.syndrome });
    try w.writeAll("h9: pc ");
    try writeSym(w, bytes, u.pc());
    try w.writeAll("\n");
    switch (u.*) {
        .arm64 => |r| {
            for (r.r, 0..) |v, i| {
                try w.print("R{d}\t0x{x:0>16}", .{ i, v });
                try w.writeAll(if (i % 4 == 3) "\n" else "  ");
            }
            try w.print("\nSP\t0x{x:0>16}  PC\t0x{x:0>16}  PSR\t0x{x:0>16}  TYPE\t0x{x:0>16}\n", .{ r.sp, r.pc, r.psr, r.type });
            try w.writeAll("h9: lr ");
            try writeSym(w, bytes, r.r[30]);
            try w.writeAll("\n");
        },
        .amd64 => |r| {
            inline for (.{ "ax", "bx", "cx", "dx", "si", "di", "bp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "pc", "sp", "flags" }, 0..) |name, i| {
                try w.print("{s}\t0x{x:0>16}", .{ name, @field(r, name) });
                try w.writeAll(if (i % 4 == 3) "\n" else "  ");
            }
            try w.writeAll("\n");
        },
        .i386 => |r| {
            inline for (.{ "ax", "bx", "cx", "dx", "si", "di", "bp", "sp", "pc", "flags", "trap", "ecode" }, 0..) |name, i| {
                try w.print("{s}\t0x{x:0>8}", .{ name, @field(r, name) });
                try w.writeAll(if (i % 4 == 3) "\n" else "  ");
            }
        },
    }
}

fn writeSym(w: *std.Io.Writer, bytes: []const u8, addr: u64) std.Io.Writer.Error!void {
    if (aout.symbolize(bytes, addr)) |s| {
        try w.print("0x{x} {s}+0x{x}", .{ addr, s.name, addr - s.value });
    } else try w.print("0x{x}", .{addr});
}
