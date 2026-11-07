//! One machine: a VM running 9front processes whose syscalls are served by
//! drawterm's kern. See DESIGN.md, "Process model" and "Filesystem, boot
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
const hstream = @import("hstream.zig");
const ws = @import("ws.zig");

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
} || kern.Error || vmm.CreateError || loader.Error;

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
        /// Proxies for host-made connections; null goes direct. The CLI
        /// fills it from HTTPS_PROXY, HTTP_PROXY and NO_PROXY.
        proxy: ?Proxy = null,
        /// Host directory bound at /mnt/term/cwd and made the guest's cwd.
        cwd: ?[]const u8 = null,
        /// Guest environment variables, beyond the defaults.
        env: []const EnvVar = &.{},
        /// The sandbox policy (DESIGN.md, "Sandbox policy"). Host paths in
        /// it, like `root` and `cwd`, must be absolute and resolved.
        policy: policy.Policy = .{},
        /// Bind h9's own commands, `#H/bin`, after /bin; false leaves the
        /// bind out and masks `#H` (design/0032-guest-tools.md).
        guest_tools: bool = true,
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
        stdio: Stdio,
    };

    /// Host events an embedder delivers to a running machine, from any
    /// thread, including a signal handler's watcher (DESIGN.md, "Signals
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

    pub const InitError = vmm.CreateError || error{PolicyConflict};

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
        /// or `rawoff` to /dev/consctl, or closing its last consctl). The
        /// CLI puts the host terminal in raw mode. The machine turns raw
        /// mode off when a run ends.
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

    /// Compiles a policy for a machine with these options, as `init` does,
    /// without creating one (for `--print`).
    pub fn compilePlan(arena: std.mem.Allocator, opts: Options, err_msg: *[]const u8) policy.CompileError!policy.Plan {
        const arch = opts.arch orelse vmm.host_arch orelse .arm64;
        var in: policy.Inputs = .{ .root = null, .cwd = opts.cwd, .arch = arch, .guest_tools = opts.guest_tools };
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
        const backend = try vmm.create(gpa, io, opts.backend, .{ .arch = arch, .memory = plan.memory });
        return .{ .gpa = gpa, .io = io, .opts = opts, .arch = arch, .backend = backend, .plan = plan, .arena = arena };
    }

    pub fn deinit(m: *Machine) void {
        // A stuck process still uses the backend and the plan, so they're
        // leaked rather than freed under it.
        if (m.stuck) return;
        m.backend.destroy();
        m.arena.deinit();
        m.gpa.destroy(m.arena);
    }

    /// The CPUs the machine may use, as /dev/sysstat lists them: `--cpus`
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
        // Heap-allocated, with its own copy of the machine, so a stuck
        // process never refers to the caller's Machine.
        const job = try m.gpa.create(Job);
        const pool = cpupool.Pool.init(m.gpa, m.io, m.backend, m.plan.cpus, m.opts.owned_vcpus) catch |e| {
            m.gpa.destroy(job);
            return e;
        };
        job.* = .{ .m = undefined, .mc = m.*, .prog = prog, .argv = argv, .con = .{ .in = null, .out = m.opts.stdio.out, .err = m.opts.stdio.err, .raw = m.opts.stdio.raw }, .pool = pool };
        job.pool.gpa = m.gpa;
        job.ncpu = m.cpuCount();
        kern.setNoteKick(Proc.noteKick);
        kern.setProcStatus(Proc.status);
        kern.setProcSegment(Proc.segments);
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
        const first = job.newProc() catch |e| {
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
            job.con.setRaw(false);
            return .{ .killed = if (timed_out) timeout_note else stopped_note };
        }
        kern.removeConsole(job.con_id);
        job.con.setRaw(false);
        m.root_changes = job.rootChanges();
        if (job.mach.load(.acquire)) |mc| mc.put();
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
        trace_lock: std.atomic.Mutex = .unlocked,
        /// vCPUs for the processes.
        pool: cpupool.Pool,
        /// The CPUs /dev/sysstat lists (design/0007-go-compat.md).
        ncpu: u32 = 1,
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

        /// Allocates and registers a process with the next pid. Fails with
        /// TooManyProcs at the policy's `--pids` cap.
        fn newProc(j: *Job) error{ OutOfMemory, TooManyProcs }!*Proc {
            const gpa = j.m.gpa;
            const p = try gpa.create(Proc);
            errdefer gpa.destroy(p);
            j.lockSpin();
            defer j.lock.unlock();
            if (j.m.plan.pids) |cap| if (j.procs.items.len >= cap) return error.TooManyProcs;
            try j.procs.append(gpa, p);
            p.* = .{ .job = j, .pid = j.next_pid };
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
            j.lock.unlock();
            j.m.gpa.destroy(p);
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
            return j.all_done.isSet();
        }
    };

    /// One guest process: a kernel process with its own host thread, an
    /// address space and segments, and a vCPU while it runs.
    const Proc = struct {
        job: *Job,
        /// Machine-local pid.
        pid: u32,
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
        in_sys: std.atomic.Value(u64) = .init(0),
        mem_kb: std.atomic.Value(u64) = .init(0),

        fn noteMem(p: *Proc) void {
            p.mem_kb.store(p.segs.mapped() / 1024, .release);
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
        fn status(aux: ?*anyopaque, buf: [*]u8, n: c_int, mem: *c_ulong) callconv(.c) void {
            const p: *Proc = @ptrCast(@alignCast(aux orelse return));
            mem.* = @intCast(p.mem_kb.load(.acquire));
            const out = buf[0..@intCast(n)];
            const nr = p.in_sys.load(.acquire);
            var name: []const u8 = "Running";
            if (nr != 0) name = std.enums.tagName(syscall.Nr, @enumFromInt(nr - 1)) orelse "Syscall";
            const len = @min(name.len, out.len - 1);
            @memcpy(out[0..len], name[0..len]);
            if (nr != 0 and len > 0) out[0] = std.ascii.toUpper(out[0]);
            out[len] = 0;
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
            // The namespace and fds can hold overlays, whose pages are the
            // machine's: they go now, not after the machine stops waiting.
            kern.release();
            // No kick hook may run on the Proc once it's freed.
            kern.setAux(null);
            if (p.lease) |l| {
                p.setLease(null);
                l.release();
            }
            if (p.as) |as| {
                p.segs.release(as);
                as.destroy();
            }
            if (p.image) |b| gpa.free(b);
            j.lockSpin();
            for (j.procs.items, 0..) |q, i| if (q == p) {
                _ = j.procs.swapRemove(i);
                break;
            };
            const empty = j.procs.items.len == 0;
            j.lock.unlock();
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
        j.mach.store(kern.mach(), .release);
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

        var arena: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena.deinit();
        // A guest program goes through #! as exec does, so `h9 man` runs
        // the rc script /rc/bin/man (bound on /bin) like a binary.
        var argv = j.argv;
        const bytes = switch (j.prog) {
            .bytes => |b| b,
            .guest => |name| blk: {
                const g = try m.readGuest(arena.allocator(), name);
                const img = interpret(arena.allocator(), g.path, g.bytes, argv) catch |err| {
                    m.err_msg = switch (err) {
                        error.NotFound => kern.errstr(),
                        error.OutOfMemory => "no memory",
                        else => ebadexec,
                    };
                    return if (err == error.NotFound) error.NotFound else error.NotExecutable;
                };
                argv = img.argv;
                break :blk img.bytes;
            },
        };
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
        return m.loop(p);
    }

    /// A forked process's thread.
    fn childMain(p: *Proc) void {
        const m = p.job.m;
        kern.setPlan(&m.plan);
        kern.setPages(&p.job.pages);
        kern.setCpus(p.job.ncpu);
        p.setKproc();
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
        const j = p.job;
        try j.pool.acquire(&p.lease_store);
        p.setLease(&p.lease_store);
        const vcpu = &p.lease_store;
        try vcpu.setAddressSpace(p.as.?);
        vcpu.setExtra(&p.extra);
        var u = p.ureg;
        vcpu.setUreg(&u);
        while (true) {
            if (j.stopping.load(.acquire)) return .{ .killed = if (j.timed_out.load(.acquire)) timeout_note else stopped_note };
            if (p.note_flag.swap(false, .acq_rel)) {
                if (try deliver(p, vcpu, &u)) |msg| return .{ .killed = msg };
            }
            const exit = try vcpu.run();
            vcpu.getUreg(&u);
            switch (exit) {
                .syscall => switch (blk: {
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
                .interrupted => {},
                .halted => return .{ .killed = "halted" },
                .other => |code| return .{ .killed = try std.fmt.bufPrint(&p.msg_buf, "sys: trap: unexpected exit 0x{x} pc=0x{x}", .{ code, u.pc() }) },
            }
        }
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
        const w = u.wordSize();
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
                gm.write(as, sp, words[0 .. 2 * w]) catch return suicide;
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
        const c = j.newProc() catch return failWith("no procs");
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
        const old = p.as.?;
        p.segs.replace(old, img.segs);
        old.destroy();
        p.as = nas;
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
    }

    const Image = struct { bytes: []const u8, argv: []const []const u8 };

    /// Follows up to 8 levels of #! interpreters from the file at `path`,
    /// whose contents are `bytes`, and returns the binary to load and its
    /// argv. Shared by exec and the first process. A failed stat or open
    /// sets the error string and gives NotFound or NotExecutable; a bad
    /// #! line gives BadExec.
    fn interpret(arena: std.mem.Allocator, path: []const u8, bytes: []const u8, argv: []const []const u8) RunError!Image {
        var pre: std.ArrayList([]const u8) = .empty;
        var cur = bytes;
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
        }
        if (indir == 0) return .{ .bytes = cur, .argv = argv };

        // As 9front builds it: the interpreters' arguments (the outermost's
        // first) and the script's full name, with the first interpreter's
        // name swapped for the script's last path element, then the
        // caller's arguments after argv[0]. So `#!/bin/rc` running /bin/x
        // with argv `x a` gets `x /bin/x a`.
        var out: std.ArrayList([]const u8) = .empty;
        try out.append(arena, basename(path));
        try out.appendSlice(arena, pre.items[1..]);
        if (argv.len > 1) try out.appendSlice(arena, argv[1..]);
        return .{ .bytes = cur, .argv = out.items };
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

    /// Builds the first Proc's namespace from the plan (DESIGN.md, "Boot
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
                try std.fmt.bufPrintZ(&buf, "{s}{d}", .{ b.from, con_id })
            else
                try std.fmt.bufPrintZ(&buf, "{s}", .{b.from});
            var flag: c_int = switch (b.flag) {
                .repl => kern.MREPL,
                .before => kern.MBEFORE,
                .after => kern.MAFTER,
            };
            if (b.create) flag |= kern.MCREATE;
            const to = try std.fmt.bufPrintZ(&buf2, "{s}", .{b.to});
            if (bindOrOverlay(from, b.lower, to, flag, &buf)) |id| {
                if (std.mem.eql(u8, b.to, "/mnt/term/cwd")) cwd_at = "/mnt/term/cwd";
                if (std.mem.eql(u8, b.to, "/") and id != null) root_ov = id;
                continue;
            } else |_| {}
            if (b.fallback) |fb| {
                if (bindOrOverlay(from, b.lower, try std.fmt.bufPrintZ(&buf2, "{s}", .{fb}), flag, &buf)) |_| {
                    if (std.mem.eql(u8, b.to, "/mnt/term/cwd")) cwd_at = "/mnt/term";
                    continue;
                } else |_| {}
            }
            if (!b.optional) return m.fail("bind {s} {s}: {s}", .{ b.from, b.to, kern.errstr() });
        }
        if (cwd_at) |at| kern.chdir(at) catch return m.fail("cwd: {s}", .{kern.errstr()});
        if (m.plan.root_overlay) makeHome();

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
            .ws => |u| return m.postStream(try m.connectStream(u, .{
                .headers = m.opts.root_headers,
                .ca_file = m.opts.root_ca,
                .proxy = m.opts.proxy orelse .{},
            }, "root")),
            .tcp => |a| dialTcp(a),
            .unix => |path| kern.unixDial(std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return m.fail("root {s}: name too long", .{addr})),
        } catch return m.fail("root {s}: {s}", .{ addr, kern.errstr() });
        defer kern.close(fd) catch {};
        const srv = kern.create(policy.root_srv, kern.OWRITE, 0o666) catch return m.fail("root {s}: post {s}: {s}", .{ addr, policy.root_srv, kern.errstr() });
        defer kern.close(srv) catch {};
        var num: [16]u8 = undefined;
        _ = kern.pwrite(srv, std.fmt.bufPrint(&num, "{d}", .{fd}) catch unreachable, 0) catch return m.fail("root {s}: post {s}: {s}", .{ addr, policy.root_srv, kern.errstr() });
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

    /// Posts a WebSocket root's channel as `#s/root`, as `connectRoot`
    /// posts a dialed one.
    fn postStream(m: *Machine, fd: u31) RunError!void {
        const addr = m.plan.root_9p.?.addr;
        defer kern.close(fd) catch {};
        const srv = kern.create(policy.root_srv, kern.OWRITE, 0o666) catch return m.fail("root {f}: post {s}: {s}", .{ ws.Url.elide(addr), policy.root_srv, kern.errstr() });
        defer kern.close(srv) catch {};
        var num: [16]u8 = undefined;
        _ = kern.pwrite(srv, std.fmt.bufPrint(&num, "{d}", .{fd}) catch unreachable, 0) catch return m.fail("root {f}: post {s}: {s}", .{ ws.Url.elide(addr), policy.root_srv, kern.errstr() });
    }

    /// Dials `tcp!host!port` through `#I`, as 9front's dial does through
    /// /net: cs translates the address, and each translation is tried in
    /// turn. Returns an fd on the connection's data file.
    fn dialTcp(addr: []const u8) kern.Error!u31 {
        var buf: [512]u8 = undefined;
        const cs = try kern.open("#I/cs", kern.ORDWR);
        defer kern.close(cs) catch {};
        _ = try kern.pwrite(cs, addr, 0);
        // cs returns one "/net/tcp/clone ip!port" line per read, so a name
        // with several addresses (::1 and 127.0.0.1 for localhost) takes
        // several reads.
        var off: i64 = 0;
        var last: kern.Error = error.Kern;
        while (true) {
            const n = try kern.pread(cs, &buf, off);
            if (n == 0) return last;
            off += @intCast(n);
            const line = std.mem.trimEnd(u8, buf[0..n], "\n");
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            if (dialOne(line[sp + 1 ..])) |fd| return fd else |e| last = e;
        }
    }

    fn dialOne(ipport: []const u8) kern.Error!u31 {
        var buf: [128]u8 = undefined;
        const ctl = try kern.open("#I/tcp/clone", kern.ORDWR);
        defer kern.close(ctl) catch {};
        const n = try kern.pread(ctl, &buf, 0);
        const conv = std.mem.trim(u8, buf[0..n], " \n");
        var cmd: [160]u8 = undefined;
        _ = try kern.pwrite(ctl, std.fmt.bufPrint(&cmd, "connect {s}", .{ipport}) catch return error.Kern, 0);
        return kern.open(std.fmt.bufPrintZ(&cmd, "#I/tcp/{s}/data", .{conv}) catch return error.Kern, kern.ORDWR);
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
    /// overlay over `#U<lower>`. A bare `#O` with no `lower` is a fresh
    /// overlay over what `to` is now, as in a namespace file. `buf` is
    /// scratch, and may hold `from`.
    /// Returns the overlay's instance, or null for a plain bind.
    fn bindOrOverlay(from: [:0]const u8, lower: ?[]const u8, to: [:0]const u8, flag: c_int, buf: []u8) kern.Error!?u32 {
        const l = lower orelse {
            if (std.mem.eql(u8, from, "#O")) return try overlay(to, to, flag);
            try kern.bind(from, to, flag);
            return null;
        };
        return try overlay(std.fmt.bufPrintZ(buf, "#U{s}", .{l}) catch return error.Kern, to, flag);
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
        const bytes = try gpa.alloc(u8, len);
        var off: usize = 0;
        while (off < len) {
            const got = kern.pread(fd, bytes[off..], @intCast(off)) catch return error.NotExecutable;
            if (got == 0) break;
            off += got;
        }
        return bytes[0..off];
    }
};

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
