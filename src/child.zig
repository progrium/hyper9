//! Child machines (design/child-machines.md): the host side of the
//! machine device, `#μ` (src/kern/dev/machine.zig). A guest process
//! opens `/dev/machine/clone`, writes a child's options to its `ctl` as
//! plan lines (design/plan-format.md), and `exec` starts the child on
//! the parent's engine, on a host thread of its own, with its console
//! here: `data` is its input and output, `stderr` its standard error
//! when asked for apart, and `wait` its exit status.
//!
//! The device calls the `h9_child_*` functions below on the calling
//! process's thread, so `Machine.Caller.current` is the machine whose
//! child it is. They never fail with kernel errors: they return -1 with
//! the error in an ERRMAX buffer. A read that has to wait returns
//! `would_block`, and the device sleeps until `kern.childWake`.
//!
//! The child's plan narrows its parent's (`policy.narrow`): its limits
//! come out of what the parent has left, its network is no broader, and
//! its devices are masked as the parent's are. Its namespace is built
//! from the caller's channels (`Machine.compileChild`), so it reaches
//! only what the caller can.

const std = @import("std");
const kern = @import("kern.zig");
const policy = @import("policy.zig");
const engine = @import("engine.zig");
const web = @import("web.zig");
const Machine = @import("machine.zig").Machine;
const newns = @import("newns.zig");

/// The conversations in the host process, every machine's.
pub const max_convs = 64;
const would_block = -2;

// The device's kinds (src/kern/dev/machine.zig).
const Kctl = 0;
const Kdata = 1;
const Kstderr = 2;
const Kwait = 3;
const Kplan = 4;
const Knote = 5;
const Kdatawrite = 6;

/// How much of a child's output is kept for a reader before the child
/// waits for it.
const out_max = 1 << 20;

/// Bytes between a child and its conversation.
const Pipe = struct {
    buf: std.ArrayList(u8) = .empty,
    /// No more bytes will come.
    closed: bool = false,

    fn deinit(p: *Pipe, gpa: std.mem.Allocator) void {
        p.buf.deinit(gpa);
        p.* = .{};
    }
};

const State = enum { free, config, running, done };

const Conv = struct {
    state: State = .free,
    /// The machine whose child it is (`Machine.Caller.key`).
    owner: usize = 0,
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    /// Open channels, and the child's thread while it runs.
    refs: u32 = 0,
    /// Opens of `data` for writing; the child's input ends with the last.
    writers: u32 = 0,
    had_writer: bool = false,
    /// The `ctl` lines so far, as plan lines.
    lines: std.ArrayList(u8) = .empty,
    /// A `stderr` line: standard error goes to `stderr`, not `data`.
    stderr_apart: bool = false,
    out: Pipe = .{},
    err: Pipe = .{},
    in: Pipe = .{},
    in_cancel: bool = false,
    /// Bumped when the pipes change, for the child's threads.
    seq: std.atomic.Value(u32) = .init(0),
    status_buf: [64]u8 = undefined,
    status: []const u8 = "",
    plan_text: []u8 = &.{},
    /// What `exec` compiled, until the device starts it.
    arena: std.heap.ArenaAllocator = undefined,
    pending: ?Pending = null,
    m: ?*Machine = null,
    signals: Machine.Signals = .{},
    thread: ?web.Thread = null,
    out_w: std.Io.Writer = undefined,
    err_w: std.Io.Writer = undefined,
    in_r: std.Io.Reader = undefined,

    fn id(cv: *const Conv) usize {
        return (@intFromPtr(cv) - @intFromPtr(&convs)) / @sizeOf(Conv);
    }
};

const Pending = struct {
    opts: Machine.Options,
    argv: []const []const u8,
    cwd: ?[]const u8,
};

var lock_: std.atomic.Mutex = .unlocked;
var convs: [max_convs]Conv = @splat(.{});

fn lock() void {
    while (!lock_.tryLock()) std.atomic.spinLoopHint();
}

fn unlock() void {
    lock_.unlock();
}

/// Wakes the device's readers and the child's threads.
fn wake(cv: *Conv) void {
    _ = cv.seq.fetchAdd(1, .release);
    if (cv.state != .free) cv.io.futexWake(u32, &cv.seq.raw, std.math.maxInt(u32));
    kern.childWake(@intCast(cv.id()));
}

fn setErr(err: [*]u8, msg: []const u8) c_int {
    const n = @min(msg.len, kern.ERRMAX - 1);
    @memcpy(err[0..n], msg[0..n]);
    err[n] = 0;
    return -1;
}

/// Conversation `n` if it's the calling machine's.
fn mine(n: usize) ?*Conv {
    const caller = Machine.Caller.current() orelse return null;
    if (n >= max_convs) return null;
    const cv = &convs[n];
    if (cv.state == .free or cv.owner != caller.key()) return null;
    return cv;
}

fn freeLocked(cv: *Conv) void {
    const gpa = cv.gpa;
    cv.lines.deinit(gpa);
    cv.out.deinit(gpa);
    cv.err.deinit(gpa);
    cv.in.deinit(gpa);
    gpa.free(cv.plan_text);
    cv.arena.deinit();
    cv.* = .{};
}

/// Drops a reference: the last one frees the conversation, and the last
/// fd kills the child.
fn putLocked(cv: *Conv) void {
    cv.refs -= 1;
    if (cv.refs == 0) {
        freeLocked(cv);
        return;
    }
    // Only the child's thread is left.
    if (cv.refs == 1 and cv.state == .running) cv.signals.stop(cv.io);
}

/// Stops every child of machine `owner`, for the end of its run.
pub fn stopAll(owner: usize) void {
    lock();
    defer unlock();
    for (&convs) |*cv| if (cv.state == .running and cv.owner == owner) cv.signals.stop(cv.io);
}

// The child's console.

const out_vtable: std.Io.Writer.VTable = .{ .drain = drainOut };
const err_vtable: std.Io.Writer.VTable = .{ .drain = drainErr };
const in_vtable: std.Io.Reader.VTable = .{ .stream = streamIn };

fn drainOut(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const cv: *Conv = @alignCast(@fieldParentPtr("out_w", w));
    return drain(cv, &cv.out, w, data, splat);
}

fn drainErr(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const cv: *Conv = @alignCast(@fieldParentPtr("err_w", w));
    return drain(cv, if (cv.stderr_apart) &cv.err else &cv.out, w, data, splat);
}

/// Queues the child's output for the conversation's readers, waiting
/// while a reader is behind. With no fd open, it's dropped.
fn drain(cv: *Conv, p: *Pipe, w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    var n: usize = 0;
    try put(cv, p, w.buffered());
    w.end = 0;
    for (data[0 .. data.len - 1]) |d| {
        try put(cv, p, d);
        n += d.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| try put(cv, p, last);
    return n + last.len * splat;
}

fn put(cv: *Conv, p: *Pipe, b: []const u8) std.Io.Writer.Error!void {
    if (b.len == 0) return;
    while (true) {
        lock();
        if (cv.refs <= 1 or p.closed) {
            unlock();
            return;
        }
        if (p.buf.items.len < out_max) {
            p.buf.appendSlice(cv.gpa, b) catch {
                unlock();
                return error.WriteFailed;
            };
            unlock();
            wake(cv);
            return;
        }
        const seq = cv.seq.load(.acquire);
        unlock();
        cv.io.futexWaitTimeout(u32, &cv.seq.raw, seq, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch {};
    }
}

fn streamIn(r: *std.Io.Reader, wr: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const cv: *Conv = @alignCast(@fieldParentPtr("in_r", r));
    const dest = limit.slice(try wr.writableSliceGreedy(1));
    while (true) {
        lock();
        if (cv.in_cancel) {
            cv.in_cancel = false;
            unlock();
            return error.ReadFailed;
        }
        if (cv.in.buf.items.len > 0) {
            const n = @min(dest.len, cv.in.buf.items.len);
            @memcpy(dest[0..n], cv.in.buf.items[0..n]);
            cv.in.buf.replaceRangeAssumeCapacity(0, n, &.{});
            unlock();
            wr.advance(n);
            return n;
        }
        if (cv.in.closed) {
            unlock();
            return error.EndOfStream;
        }
        const seq = cv.seq.load(.acquire);
        unlock();
        cv.io.futexWaitTimeout(u32, &cv.seq.raw, seq, .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }) catch {};
    }
}

fn cancelIn(ctx: *anyopaque, _: web.Thread) void {
    const cv: *Conv = @ptrCast(@alignCast(ctx));
    lock();
    cv.in_cancel = true;
    unlock();
    wake(cv);
}

fn resetIn(ctx: *anyopaque) void {
    const cv: *Conv = @ptrCast(@alignCast(ctx));
    lock();
    cv.in_cancel = false;
    unlock();
}

// The plan.

/// A `ctl` line as a plan line: the host flags' names that differ are
/// kept as aliases (design/plan-format.md, "Child machines").
fn planLine(a: std.mem.Allocator, words: []const []const u8) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    const aliases = [_][2][]const u8{ .{ "readable", "allow read" }, .{ "writable", "allow write" }, .{ "readdeny", "deny read" } };
    var first = words[0];
    for (aliases) |al| if (std.mem.eql(u8, first, al[0])) {
        first = al[1];
    };
    w.writeAll(first) catch return error.OutOfMemory;
    for (words[1..]) |word| {
        w.writeAll(" ") catch return error.OutOfMemory;
        policy.writeWord(w, word) catch return error.OutOfMemory;
    }
    w.writeAll("\n") catch return error.OutOfMemory;
    return out.written();
}

const PrepareError = error{ OutOfMemory, Refused };

/// The child's options from conversation `cv`'s lines, narrowed by the
/// caller's machine, in `a`; `why` says what's refused. `spec_out` gets
/// the plan as `--print` writes it.
fn prepare(a: std.mem.Allocator, cv: *Conv, caller: Machine.Caller, lines: []const u8, why: *[]const u8, spec_out: ?*policy.Spec) PrepareError!Pending {
    const pm = caller.machine();
    var perr: policy.PlanError = .{};
    const spec = policy.parsePlan(a, lines, &perr) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            why.* = try std.fmt.allocPrint(a, "{s}", .{perr.msg});
            return error.Refused;
        },
    };
    for (spec.mounts) |mt| switch (mt.kind) {
        .dir, .tmp, .builtin => {},
        else => {
            why.* = try std.fmt.allocPrint(a, "{t}: a child's mounts are dir, tmp, builtin, and bind", .{mt.kind});
            return error.Refused;
        },
    };
    if (spec.gfx != null or spec.serve.len > 0) {
        why.* = if (spec.gfx != null) "gfx: a child has no window" else "serve: a child can't serve";
        return error.Refused;
    }
    if (spec.policy.host_fs) {
        why.* = "devices host-fs: a child reaches only the caller's files";
        return error.Refused;
    }
    const kind = pm.engine.kind();
    if (spec.engine) |e| if (e != .auto and !std.mem.eql(u8, @tagName(e), @tagName(kind))) {
        why.* = try std.fmt.allocPrint(a, "engine {t}: a child runs on its parent's engine, {t}", .{ e, kind });
        return error.Refused;
    };
    if (spec.arch) |x| if (x != pm.arch) {
        why.* = try std.fmt.allocPrint(a, "arch {s}: a child runs its parent's architecture, {s}", .{ x.name(), pm.arch.name() });
        return error.Refused;
    };

    // What narrows: the parent's limits as it has them left, its network,
    // and its devices. Paths are the caller's, so they need no rule: the
    // child reaches no more than the caller's channels do.
    var base = try caller.spec(a);
    base.mounts = &.{};
    base.binds = &.{};
    base.ns = &.{};
    base.policy.readable = &.{};
    base.policy.writable = &.{};
    base.policy.read_deny = &.{};
    base.policy.write = null;
    base.policy.cwd_writable = null;
    base.cwd = null;
    base.env = &.{};
    base.run = null;
    base.gfx = null;
    base.serve = &.{};
    base.serve_root = null;
    base.serve_token = null;
    base.serve_origins = &.{};
    base.serve_net = false;
    base.engine = null;
    base.arch = null;
    base.lines = .{};
    const left = caller.memoryLeft();
    base.policy.memory = left;
    base.policy.pids = caller.pidsLeft();
    base.policy.timeout_ns = caller.timeLeft();
    base.policy.cpus = pm.plan.cpus;
    var by = spec;
    by.mounts = &.{};
    by.binds = &.{};
    by.ns = &.{};
    by.policy.readable = &.{};
    by.policy.writable = &.{};
    by.policy.read_deny = &.{};
    by.policy.write = null;
    by.policy.cwd_writable = null;
    by.cwd = null;
    by.env = &.{};
    by.engine = null;
    by.arch = null;
    var w: []const u8 = "";
    var r = policy.narrow(a, base, by, &w) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Widens => {
            why.* = w;
            return error.Refused;
        },
    };
    // Without a memory line, half of what's left.
    if (spec.policy.memory == null) r.policy.memory = std.mem.alignBackward(u64, left / 2, engine.page_size);
    const min_memory = 16 * engine.page_size;
    if (r.policy.memory.? < min_memory) {
        why.* = "memory: the parent has too little left";
        return error.Refused;
    }

    var pol = r.policy;
    pol.readable = spec.policy.readable;
    pol.writable = spec.policy.writable;
    pol.read_deny = spec.policy.read_deny;
    pol.write = spec.policy.write;
    pol.cwd_writable = null;
    // Without a mount on /, the root is the caller's.
    var mounts: std.ArrayList(Machine.Mount) = .empty;
    const has_root = for (spec.mounts) |mt| {
        if (mt.stack()) |st| if (st[0] == .root) break true;
    } else false;
    if (!has_root) try mounts.append(a, .{ .kind = .dir, .src = "/", .dst = "/" });
    try mounts.appendSlice(a, spec.mounts);
    const env = try a.alloc(@import("machine.zig").EnvVar, spec.env.len);
    for (spec.env, env) |e, *o| {
        const eq = std.mem.indexOfScalar(u8, e, '=').?;
        o.* = .{ .name = e[0..eq], .value = e[eq + 1 ..] };
    }
    cv.out_w = .{ .buffer = &.{}, .vtable = &out_vtable };
    cv.err_w = .{ .buffer = &.{}, .vtable = &err_vtable };
    cv.in_r = .{ .vtable = &in_vtable, .buffer = &.{}, .seek = 0, .end = 0 };
    // Without a cwd line, the child starts where the caller is, which is
    // writable as a host machine's cwd is.
    const cwd = spec.cwd orelse try callerCwd(a);
    const opts: Machine.Options = .{
        .cwd = cwd,
        .engine = std.meta.stringToEnum(engine.Choice, @tagName(kind)).?,
        .arch = pm.arch,
        .mounts = mounts.items,
        .binds = spec.binds,
        .ns = spec.ns,
        .policy = pol,
        .guest_tools = r.guest_tools,
        .env = env,
        .nameservers = pm.opts.nameservers,
        .tmp_dir = pm.opts.tmp_dir,
        .index = .none,
        .console_tty = false,
        .signals = &cv.signals,
        .stdio = .{ .in = &cv.in_r, .in_cancel = .{ .ctx = cv, .func = cancelIn, .reset = resetIn }, .out = &cv.out_w, .err = &cv.err_w },
    };
    if (spec_out) |so| {
        var ps = r;
        ps.mounts = mounts.items;
        ps.binds = spec.binds;
        ps.ns = spec.ns;
        ps.policy = pol;
        ps.engine = std.meta.stringToEnum(policy.EngineChoice, @tagName(kind)).?;
        ps.arch = pm.arch;
        ps.env = spec.env;
        ps.cwd = null;
        so.* = ps;
    }
    return .{ .opts = opts, .argv = spec.run orelse &.{}, .cwd = cwd };
}

/// The calling process's cwd, as a path in its namespace, or "/".
fn callerCwd(a: std.mem.Allocator) std.mem.Allocator.Error!?[]const u8 {
    const fd = kern.open(".", kern.OREAD) catch return "/";
    defer kern.close(fd) catch {};
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    @memset(&buf, 0);
    kern.fd2path(fd, &buf) catch return "/";
    return try a.dupe(u8, std.mem.sliceTo(&buf, 0));
}

/// The child's plan as `--print` writes it, in `gpa`.
fn planText(gpa: std.mem.Allocator, cv: *Conv, caller: Machine.Caller, lines: []const u8, why: *[]const u8, scratch: std.mem.Allocator) PrepareError![]u8 {
    var spec: policy.Spec = .{};
    const p = try prepare(scratch, cv, caller, lines, why, &spec);
    var paths: std.ArrayList([]const u8) = .empty;
    var msg: []const u8 = "";
    const plan = Machine.compileChild(scratch, caller, p.opts, &paths, &msg) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Conflict => {
            why.* = msg;
            return error.Refused;
        },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    policy.printPlan(&out.writer, spec, &plan) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

// The child's run.

fn runChild(cv: *Conv, m: *Machine, argv: []const []const u8) void {
    var sb: [64]u8 = undefined;
    const st: []const u8 = if (m.run(.{ .guest = argv[0] }, argv)) |s| switch (s) {
        .exited => |msg| if (msg.len == 0) "0" else msg,
        .killed => |msg| killedCode(&sb, msg),
    } else |e| blk: {
        var eb: [256]u8 = undefined;
        const why = if (m.err_msg.len > 0) m.err_msg else @errorName(e);
        const line = std.fmt.bufPrint(&eb, "h9: {s}: {s}\n", .{ argv[0], why }) catch "h9: the child failed\n";
        lock();
        if (cv.refs > 1) (if (cv.stderr_apart) &cv.err else &cv.out).buf.appendSlice(cv.gpa, line) catch {};
        unlock();
        break :blk switch (e) {
            error.NotFound => "127",
            error.NotExecutable => "126",
            else => "125",
        };
    };
    // The status may be the machine's own words: kept before it goes.
    var keep: [64]u8 = undefined;
    const n = @min(st.len, keep.len);
    @memcpy(keep[0..n], st[0..n]);
    const id: u32 = @intCast(cv.id());
    const stuck = m.stuck;
    const pj = m.parentJob();
    const io = cv.io;
    if (!stuck) {
        m.deinit();
        cv.gpa.destroy(m);
    }
    lock();
    @memcpy(cv.status_buf[0..n], keep[0..n]);
    cv.status = cv.status_buf[0..n];
    cv.state = .done;
    cv.out.closed = true;
    cv.err.closed = true;
    cv.m = null;
    unlock();
    wake(cv);
    lock();
    // A stuck child may still use the conversation's console.
    if (stuck) cv.refs += 1;
    putLocked(cv);
    unlock();
    // Last: the parent's run may end, and its allocator with it. A stuck
    // child never ends, and its parent is stuck too.
    if (stuck) return;
    // The servers of the caller's paths end as the child's mounts of
    // them go, the last with the child's machine; their fids hold the
    // caller's channels, so the parent waits for them too.
    // A channel the child's kernel state still holds would keep one
    // open, so after a moment they're hung up.
    var waited: u32 = 0;
    while (kern.childServed(id) > 0 and waited < 5000) : (waited += 5) {
        if (waited == 100) kern.childUnserve(id);
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    if (pj) |j| Machine.childGone(j, io);
}

/// A killed child's exit status, as the CLI's for the common notes
/// (design/epoch-0/exit-status.md): 124 for the timeout, 128 and the
/// signal for the notes that are one, and 125 for h9's own.
fn killedCode(buf: []u8, note: []const u8) []const u8 {
    const code: u8 = if (std.mem.eql(u8, note, "h9: timeout")) 124 else if (std.mem.startsWith(u8, note, "h9: ")) 125 else if (std.mem.eql(u8, note, "hangup")) 129 else if (std.mem.eql(u8, note, "interrupt")) 130 else if (std.mem.eql(u8, note, "alarm")) 142 else if (std.mem.eql(u8, note, "kill") or std.mem.startsWith(u8, note, "Killed")) 137 else if (std.mem.startsWith(u8, note, "sys: trap: ") or std.mem.startsWith(u8, note, "sys: bad address")) 139 else 1;
    return std.fmt.bufPrint(buf, "{d}", .{code}) catch "1";
}

// The device's calls (src/kern/dev/machine.zig).

fn h9_child_clone(err: [*]u8) callconv(.c) c_long {
    const caller = Machine.Caller.current() orelse return setErr(err, "not an h9 process");
    const pm = caller.machine();
    lock();
    defer unlock();
    for (&convs) |*cv| if (cv.state == .free) {
        cv.* = .{ .state = .config, .owner = caller.key(), .gpa = pm.gpa, .io = pm.io, .refs = 1, .arena = .init(pm.gpa) };
        return @intCast(cv.id());
    };
    return setErr(err, "too many child machines");
}

fn h9_child_convs(out: [*]c_int, max: c_int) callconv(.c) c_int {
    const caller = Machine.Caller.current() orelse return 0;
    lock();
    defer unlock();
    var n: c_int = 0;
    for (&convs) |*cv| if (cv.state != .free and cv.owner == caller.key() and n < max) {
        out[@intCast(n)] = @intCast(cv.id());
        n += 1;
    };
    return n;
}

fn h9_child_mine(n: c_int) callconv(.c) c_int {
    lock();
    defer unlock();
    return @intFromBool(n >= 0 and mine(@intCast(n)) != null);
}

fn h9_child_open(id: c_ulong, kind: c_int, err: [*]u8) callconv(.c) c_int {
    const caller = Machine.Caller.current() orelse return setErr(err, "not an h9 process");
    lock();
    const cv = mine(id) orelse {
        unlock();
        return setErr(err, "no such child");
    };
    cv.refs += 1;
    if (kind == Kdatawrite) {
        cv.writers += 1;
        cv.had_writer = true;
    }
    if (kind != Kplan) {
        unlock();
        return 0;
    }
    // The plan as the lines so far make it, compiled now.
    const lines = cv.gpa.dupe(u8, cv.lines.items) catch {
        putLocked(cv);
        unlock();
        return setErr(err, "no memory");
    };
    const gpa = cv.gpa;
    unlock();
    defer gpa.free(lines);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var why: []const u8 = "";
    const text = planText(gpa, cv, caller, lines, &why, scratch.allocator()) catch |e| {
        lock();
        putLocked(cv);
        unlock();
        return setErr(err, if (e == error.OutOfMemory) "no memory" else why);
    };
    lock();
    gpa.free(cv.plan_text);
    cv.plan_text = text;
    unlock();
    return 0;
}

fn h9_child_close(id: c_ulong, kind: c_int) callconv(.c) void {
    lock();
    defer unlock();
    if (id >= max_convs) return;
    const cv = &convs[id];
    if (cv.state == .free) return;
    if (kind == Kdatawrite) {
        cv.writers -= 1;
        if (cv.writers == 0) {
            cv.in.closed = true;
            wake(cv);
        }
    }
    putLocked(cv);
}

fn h9_child_ctl(id: c_ulong, buf: [*]const u8, n: c_long, err: [*]u8) callconv(.c) c_long {
    lock();
    const cv = mine(id) orelse {
        unlock();
        return setErr(err, "no such child");
    };
    const gpa = cv.gpa;
    unlock();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const text = std.mem.trimEnd(u8, buf[0..@intCast(@max(n, 0))], "\n");
    // An exec is the whole write, so an argument may hold a newline in
    // its quotes.
    const whole = std.mem.startsWith(u8, std.mem.trimStart(u8, text, " \t"), "exec");
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (if (whole) @as(?[]const u8, text) else lines.next()) |raw| {
        var rest = raw;
        while (rest.len > 0) {
            var words: std.ArrayList([]const u8) = .empty;
            rest = newns.split(sa, rest, &words) catch |e| return setErr(err, if (e == error.OutOfMemory) "no memory" else "a quote isn't closed");
            if (words.items.len == 0) continue;
            const r = ctlLine(cv, sa, words.items, err);
            if (r != 0) return r;
        }
        if (whole) break;
    }
    return 0;
}

/// One `ctl` line: 0, -1 for a mistake, or 1 for an exec the device is
/// to start.
fn ctlLine(cv: *Conv, sa: std.mem.Allocator, words: []const []const u8, err: [*]u8) c_long {
    const cmd = words[0];
    lock();
    const state = cv.state;
    unlock();
    if (state != .config) {
        if (std.mem.eql(u8, cmd, "kill")) {
            cv.signals.stop(cv.io);
            return 0;
        }
        return setErr(err, "the child has started: ctl takes only kill");
    }
    if (std.mem.eql(u8, cmd, "kill")) return setErr(err, "the child hasn't started");
    if (std.mem.eql(u8, cmd, "stderr")) {
        if (words.len != 1) return setErr(err, "stderr takes no value");
        lock();
        cv.stderr_apart = true;
        unlock();
        return 0;
    }
    if (std.mem.eql(u8, cmd, "exec")) {
        if (words.len < 2) return setErr(err, "exec needs a program");
        return exec(cv, words[1..], err);
    }
    if (std.mem.eql(u8, cmd, "run")) return setErr(err, "run: a child's program is its exec line");
    const line = planLine(sa, words) catch return setErr(err, "no memory");
    // Each line is checked as it's written, so the write that has a
    // mistake fails.
    var perr: policy.PlanError = .{};
    _ = policy.parsePlan(sa, line, &perr) catch |e| return setErr(err, if (e == error.OutOfMemory) "no memory" else std.fmt.allocPrint(sa, "{s}: {s}", .{ cmd, perr.msg }) catch "a bad line");
    lock();
    defer unlock();
    cv.lines.appendSlice(cv.gpa, line) catch return setErr(err, "no memory");
    return 0;
}

/// `exec`: compiles the child's plan, for the device to walk its paths
/// and start it (h9_child_start). Returns 1, or -1 if it's refused.
fn exec(cv: *Conv, argv: []const []const u8, err: [*]u8) c_long {
    const caller = Machine.Caller.current() orelse return setErr(err, "not an h9 process");
    lock();
    if (cv.state != .config or cv.pending != null) {
        unlock();
        return setErr(err, "the child has started");
    }
    const a = cv.arena.allocator();
    const lines = a.dupe(u8, cv.lines.items) catch {
        unlock();
        return setErr(err, "no memory");
    };
    unlock();
    var why: []const u8 = "";
    var p = prepare(a, cv, caller, lines, &why, null) catch |e| return setErr(err, if (e == error.OutOfMemory) "no memory" else why);
    p.argv = a.alloc([]const u8, argv.len) catch return setErr(err, "no memory");
    for (@constCast(p.argv), argv) |*d, w| d.* = a.dupe(u8, w) catch return setErr(err, "no memory");
    // The paths the device walks: the plan's sources.
    var paths: std.ArrayList([]const u8) = .empty;
    var msg: []const u8 = "";
    _ = Machine.compileChild(a, caller, p.opts, &paths, &msg) catch |e| return setErr(err, if (e == error.OutOfMemory) "no memory" else msg);
    lock();
    cv.pending = p;
    paths_of[cv.id()] = paths.items;
    unlock();
    return 1;
}

/// Each pending child's paths, for the device.
var paths_of: [max_convs][]const []const u8 = @splat(&.{});

fn h9_child_npaths(id: c_ulong) callconv(.c) c_int {
    lock();
    defer unlock();
    if (mine(id) == null) return -1;
    return @intCast(paths_of[id].len);
}

fn h9_child_path(id: c_ulong, i: c_int, buf: [*]u8, n: c_int) callconv(.c) c_int {
    lock();
    defer unlock();
    if (mine(id) == null) return -1;
    const ps = paths_of[id];
    if (i < 0 or i >= ps.len) return -1;
    const p = ps[@intCast(i)];
    if (p.len + 1 > n) return -1;
    @memcpy(buf[0..p.len], p);
    return @intCast(p.len);
}

fn h9_child_start(id: c_ulong, srcs: [*]?*anyopaque, n: c_int, cwd: [*:0]const u8, err: [*]u8) callconv(.c) c_int {
    const caller = Machine.Caller.current() orelse return setErr(err, "not an h9 process");
    lock();
    const cv = mine(id) orelse {
        unlock();
        return setErr(err, "no such child");
    };
    var p = cv.pending orelse {
        unlock();
        return setErr(err, "nothing to start");
    };
    cv.pending = null;
    paths_of[id] = &.{};
    const a = cv.arena.allocator();
    unlock();
    // Without a cwd line, where the caller is.
    const at = p.cwd orelse (a.dupe(u8, std.mem.span(cwd)) catch return setErr(err, "no memory"));
    var why: []const u8 = "";
    const m = Machine.initChild(cv.gpa, cv.io, caller, p.opts, srcs[0..@intCast(n)], at, &why) catch |e| return setErr(err, switch (e) {
        error.PolicyConflict => why,
        error.OutOfMemory => "no memory",
        else => @errorName(e),
    });
    p.opts = m.opts;
    lock();
    cv.m = m;
    cv.state = .running;
    cv.refs += 1;
    unlock();
    cv.thread = web.Thread.spawn(.{}, runChild, .{ cv, m, p.argv }) catch {
        lock();
        cv.state = .config;
        cv.m = null;
        cv.refs -= 1;
        unlock();
        // The sources are the machine's now; it never ran.
        const pj = m.parentJob();
        m.deinit();
        cv.gpa.destroy(m);
        if (pj) |j| Machine.childGone(j, cv.io);
        return setErr(err, "can't start a thread for the child");
    };
    cv.thread.?.detach();
    return 0;
}

fn h9_child_ready(id: c_ulong, kind: c_int) callconv(.c) c_int {
    lock();
    defer unlock();
    if (id >= max_convs) return 1;
    const cv = &convs[id];
    if (cv.state == .free) return 1;
    return @intFromBool(switch (kind) {
        Kdata => cv.out.buf.items.len > 0 or cv.out.closed or cv.state == .config,
        Kstderr => cv.err.buf.items.len > 0 or cv.err.closed or cv.state == .config,
        Kwait => cv.state == .done,
        else => true,
    });
}

fn h9_child_read(id: c_ulong, kind: c_int, buf: [*]u8, n: c_long, off: i64, err: [*]u8) callconv(.c) c_long {
    lock();
    defer unlock();
    const cv = mine(id) orelse return setErr(err, "no such child");
    const len: usize = @intCast(@max(n, 0));
    switch (kind) {
        Kdata, Kstderr => {
            const p = if (kind == Kdata) &cv.out else &cv.err;
            if (cv.state == .config) return setErr(err, "the child hasn't started");
            if (p.buf.items.len == 0) return if (p.closed) 0 else would_block;
            const k = @min(len, p.buf.items.len);
            @memcpy(buf[0..k], p.buf.items[0..k]);
            p.buf.replaceRangeAssumeCapacity(0, k, &.{});
            wake(cv);
            return @intCast(k);
        },
        Kwait => {
            if (cv.state == .config) return setErr(err, "the child hasn't started");
            if (cv.state != .done) return would_block;
            return readAt(cv.status, buf, len, off);
        },
        Kplan => return readAt(cv.plan_text, buf, len, off),
        else => return setErr(err, "not readable"),
    }
}

fn readAt(s: []const u8, buf: [*]u8, len: usize, off: i64) c_long {
    if (off < 0 or off >= s.len) return 0;
    const o: usize = @intCast(off);
    const k = @min(len, s.len - o);
    @memcpy(buf[0..k], s[o..][0..k]);
    return @intCast(k);
}

fn h9_child_write(id: c_ulong, kind: c_int, buf: [*]const u8, n: c_long, err: [*]u8) callconv(.c) c_long {
    lock();
    defer unlock();
    const cv = mine(id) orelse return setErr(err, "no such child");
    const b = buf[0..@intCast(@max(n, 0))];
    switch (kind) {
        Kdata => {
            if (cv.state == .config) return setErr(err, "the child hasn't started");
            if (cv.state == .done or cv.in.closed) return setErr(err, "the child's input is closed");
            // A write of nothing ends the child's input, as on a pipe.
            if (b.len == 0) cv.in.closed = true else cv.in.buf.appendSlice(cv.gpa, b) catch return setErr(err, "no memory");
            wake(cv);
            return n;
        },
        Knote => {
            if (cv.state != .running) return setErr(err, "the child isn't running");
            const msg = std.mem.trimEnd(u8, b, "\n");
            if (std.mem.eql(u8, msg, "interrupt")) cv.signals.interrupt(cv.io) else if (std.mem.eql(u8, msg, "hangup")) cv.signals.hangup(cv.io) else if (std.mem.eql(u8, msg, "kill")) cv.signals.stop(cv.io) else cv.signals.note(cv.io, msg);
            return n;
        },
        else => return setErr(err, "not writable"),
    }
}

/// The calling child machine's `#μsN`, while its namespace is built.
fn h9_child_source(n: c_int) callconv(.c) ?*anyopaque {
    const caller = Machine.Caller.current() orelse return null;
    if (n < 0) return null;
    return caller.source(@intCast(n));
}

comptime {
    if (kern.available) {
        @export(&h9_child_clone, .{ .name = "h9_child_clone" });
        @export(&h9_child_convs, .{ .name = "h9_child_convs" });
        @export(&h9_child_mine, .{ .name = "h9_child_mine" });
        @export(&h9_child_open, .{ .name = "h9_child_open" });
        @export(&h9_child_close, .{ .name = "h9_child_close" });
        @export(&h9_child_ctl, .{ .name = "h9_child_ctl" });
        @export(&h9_child_npaths, .{ .name = "h9_child_npaths" });
        @export(&h9_child_path, .{ .name = "h9_child_path" });
        @export(&h9_child_start, .{ .name = "h9_child_start" });
        @export(&h9_child_read, .{ .name = "h9_child_read" });
        @export(&h9_child_ready, .{ .name = "h9_child_ready" });
        @export(&h9_child_write, .{ .name = "h9_child_write" });
        @export(&h9_child_source, .{ .name = "h9_child_source" });
    }
}
