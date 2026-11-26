//! The cases for park and resume (design/scheduler.md), with no engine
//! and no kernel: continuations driven by a test scheduler.

const std = @import("std");
const builtin = @import("builtin");
const stack = @import("stack.zig");
const cont = @import("cont.zig");
const Cont = cont.Cont;
const Executor = cont.Executor;
const Pool = stack.Pool;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const is_wasm = builtin.cpu.arch.isWasm();

/// A run queue: `ready` appends.
fn Queue(comptime T: type) type {
    return struct {
        items: [max]*T = undefined,
        head: usize = 0,
        tail: usize = 0,

        const max = 1024;

        fn push(q: *@This(), p: *T) void {
            q.items[q.tail % max] = p;
            q.tail += 1;
        }

        fn pop(q: *@This()) ?*T {
            if (q.head == q.tail) return null;
            defer q.head += 1;
            return q.items[q.head % max];
        }
    };
}

/// A process, as far as these cases need one.
const Proc = struct {
    k: Cont = .{ .ready = ready },
    id: u32,
    rounds: u32,
    /// The world it parks in, and checks against.
    w: *World,
    /// Where its kernel call's frame was, at its first park.
    frame: usize = 0,
    parks: u32 = 0,
    failed: bool = false,
    done: bool = false,

    fn ready(k: *Cont) void {
        const p: *Proc = @fieldParentPtr("k", k);
        p.w.q.push(p);
    }
};

const World = struct {
    q: Queue(Proc) = .{},
    /// Processes parked and not yet unparked, in park order.
    parked: std.ArrayList(*Proc) = .empty,
    rng: std.Random.DefaultPrng = .init(9),
};

/// Recurses to a depth of its own, so each process's stack has a shape of
/// its own, and parks at the bottom, `rounds` times. Every frame checks
/// its own locals after each park.
fn descend(p: *Proc, depth: u32) void {
    var local: [24]u32 = undefined;
    for (&local, 0..) |*v, i| v.* = p.id *% 2654435761 +% depth *% 97 +% @as(u32, @intCast(i));
    const here = @intFromPtr(&local);
    if (depth > 0) {
        descend(p, depth - 1);
    } else {
        while (p.parks < p.rounds) {
            if (p.frame == 0) p.frame = here;
            if (p.frame != here) p.failed = true;
            // Every third park, an unpark comes first: kept, the park
            // returns at once.
            if (p.parks % 3 == 2) {
                cont.unpark(&p.k);
            } else {
                p.w.parked.append(std.testing.allocator, p) catch @panic("oom");
            }
            cont.park();
            p.parks += 1;
            if (cont.self() != &p.k) p.failed = true;
            const sp = @intFromPtr(&local);
            if (!p.k.stack.?.holds(sp)) p.failed = true;
        }
    }
    if (@intFromPtr(&local) != here) p.failed = true;
    for (local, 0..) |v, i| if (v != p.id *% 2654435761 +% depth *% 97 +% @as(u32, @intCast(i))) {
        p.failed = true;
    };
}

fn body(arg: ?*anyopaque) void {
    const p: *Proc = @ptrCast(@alignCast(arg.?));
    descend(p, 3 + p.id % 13);
    p.done = true;
}

test "continuations on one thread keep their own stacks and state across park and resume [scheduler]" {
    const n = 200;
    var pool: Pool = .{ .size = 64 * 1024 };
    defer pool.deinit();
    var ex: Executor = .init(&pool);
    defer ex.deinit();
    var w: World = .{};
    defer w.parked.deinit(std.testing.allocator);

    const procs = try std.testing.allocator.alloc(Proc, n);
    defer std.testing.allocator.free(procs);
    for (procs, 0..) |*p, i| p.* = .{ .id = @intCast(i), .rounds = 1 + @as(u32, @intCast(i % 7)), .w = &w };

    for (procs) |*p| {
        const out = try ex.call(&p.k, body, p);
        try expectEqual(cont.Outcome.parked, out);
        try expect(p.k.isParked());
    }
    // Each parked process holds one stack, and the executor none.
    try expectEqual(@as(usize, n), pool.mapped);
    try expectEqual(@as(?stack.Stack, null), ex.spare);

    // Unpark in a shuffled order, and run what's runnable, until none is
    // left parked.
    var resumed: usize = 0;
    while (w.parked.items.len > 0 or w.q.head != w.q.tail) {
        if (w.parked.items.len > 0) {
            const i = w.rng.random().uintLessThan(usize, w.parked.items.len);
            const p = w.parked.swapRemove(i);
            cont.unpark(&p.k);
        }
        while (w.q.pop()) |p| {
            try expect(!p.k.isParked());
            _ = ex.@"resume"(&p.k);
            resumed += 1;
        }
    }
    for (procs) |*p| {
        try expect(!p.failed);
        try expect(p.done);
        try expectEqual(p.rounds, p.parks);
        try expect(p.k.stack == null);
    }
    try expect(resumed > 0);
    // Every stack is back: one with the executor, the rest in the pool.
    try expectEqual(pool.mapped - 1, pool.nfree);
}

fn noop(arg: ?*anyopaque) void {
    const n: *u32 = @ptrCast(@alignCast(arg.?));
    n.* += 1;
}

fn parkOnce(arg: ?*anyopaque) void {
    cont.park();
    noop(arg);
}

fn readyNone(_: *Cont) void {}

test "a stack returned to the pool is reused [scheduler]" {
    var pool: Pool = .{ .size = 32 * 1024 };
    defer pool.deinit();
    var ex: Executor = .init(&pool);
    defer ex.deinit();
    var count: u32 = 0;

    // A call that doesn't park leaves its stack with the executor, for
    // the next call.
    var a: Cont = .{ .ready = readyNone };
    try expectEqual(cont.Outcome.returned, try ex.call(&a, noop, &count));
    const first = ex.spare.?.mem.ptr;
    try expectEqual(cont.Outcome.returned, try ex.call(&a, noop, &count));
    try expectEqual(first, ex.spare.?.mem.ptr);
    try expectEqual(@as(usize, 1), pool.mapped);

    // One that parks takes the stack with it; the executor gets another.
    // When it returns, its stack goes back to the pool and is handed out
    // again.
    var b: Cont = .{ .ready = readyNone };
    try expectEqual(cont.Outcome.parked, try ex.call(&b, parkOnce, &count));
    try expectEqual(first, b.stack.?.mem.ptr);
    try expectEqual(@as(?stack.Stack, null), ex.spare);
    try expectEqual(cont.Outcome.returned, try ex.call(&a, noop, &count));
    try expectEqual(@as(usize, 2), pool.mapped);
    cont.unpark(&b);
    try expectEqual(cont.Outcome.returned, ex.@"resume"(&b));
    try expectEqual(@as(usize, 1), pool.nfree);
    const again = try pool.get();
    try expectEqual(first, again.mem.ptr);
    pool.put(again);
    try expectEqual(@as(u32, 4), count);

    // Over many park and resume cycles, no more stacks are mapped.
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try expectEqual(cont.Outcome.parked, try ex.call(&b, parkOnce, &count));
        try expectEqual(cont.Outcome.returned, try ex.call(&a, noop, &count));
        cont.unpark(&b);
        try expectEqual(cont.Outcome.returned, ex.@"resume"(&b));
    }
    try expectEqual(@as(usize, 2), pool.mapped);
}

fn unparkSelf(arg: ?*anyopaque) void {
    // An unpark before the park: the park returns at once, on the same
    // stack, without switching out.
    cont.unpark(cont.self().?);
    cont.park();
    noop(arg);
}

test "an unpark before a park is kept [scheduler]" {
    var pool: Pool = .{ .size = 32 * 1024 };
    defer pool.deinit();
    var ex: Executor = .init(&pool);
    defer ex.deinit();
    var count: u32 = 0;
    var k: Cont = .{ .ready = readyNone };
    cont.unpark(&k);
    try expectEqual(cont.Outcome.returned, try ex.call(&k, parkOnce, &count));
    try expectEqual(cont.Outcome.returned, try ex.call(&k, unparkSelf, &count));
    try expectEqual(@as(u32, 2), count);
}

// A guard page hit is a fault. The overflow runs in a child process, so
// the fault ends it and not the test runner.
const posix_host = !is_wasm and builtin.os.tag != .windows;
extern "c" fn fork() c_int;
extern "c" fn signal(sig: c_int, handler: usize) usize;

fn overflow(arg: ?*anyopaque) void {
    var buf: [1024]u8 = undefined;
    const p: *volatile [1024]u8 = &buf;
    p[0] = 1;
    const depth: *usize = @ptrCast(@alignCast(arg.?));
    depth.* += 1;
    if (depth.* < 1 << 20) overflow(arg);
    p[1] = p[0];
}

test "running off a kernel stack faults at its guard page [scheduler]" {
    if (!posix_host) return error.SkipZigTest;
    var pool: Pool = .{ .size = 32 * 1024 };
    defer pool.deinit();
    const sigbus: c_int = if (builtin.os.tag.isDarwin()) 10 else 7;
    const pid = fork();
    try expect(pid >= 0);
    if (pid == 0) {
        // Zig's own segfault handler would print and abort; the default
        // action is what an overflowing process gets.
        _ = signal(11, 0);
        _ = signal(sigbus, 0);
        var ex: Executor = .init(&pool);
        var depth: usize = 0;
        var k: Cont = .{ .ready = readyNone };
        _ = ex.call(&k, overflow, &depth) catch {};
        std.c._exit(0);
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const st: u32 = @bitCast(status);
    try expect(std.c.W.IFSIGNALED(st));
    const sig: c_int = @intCast(@backingInt(std.c.W.TERMSIG(st)));
    try expect(sig == 11 or sig == sigbus);
}

// Many executors on host threads, sharing one run queue, with unparks
// from another thread: a continuation resumes wherever it's taken.
const Shared = struct {
    lock: std.atomic.Mutex = .unlocked,
    q: Queue(MProc) = .{},
    parked: std.ArrayList(*MProc) = .empty,
    left: std.atomic.Value(usize),
    bad: std.atomic.Value(usize) = .init(0),
    migrated: std.atomic.Value(usize) = .init(0),

    fn acquire(s: *Shared) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }
};

const MProc = struct {
    k: Cont = .{ .ready = ready },
    s: *Shared,
    id: u32,

    fn ready(k: *Cont) void {
        const p: *MProc = @fieldParentPtr("k", k);
        p.s.acquire();
        p.s.q.push(p);
        p.s.lock.unlock();
    }

    fn run(arg: ?*anyopaque) void {
        const p: *MProc = @ptrCast(@alignCast(arg.?));
        var mine: [16]u64 = undefined;
        for (&mine, 0..) |*v, i| v.* = @as(u64, p.id) << 32 | i;
        var last = cont.current().?;
        var round: usize = 0;
        while (round < 20) : (round += 1) {
            p.s.acquire();
            p.s.parked.append(std.heap.page_allocator, p) catch @panic("oom");
            p.s.lock.unlock();
            cont.park();
            const now = cont.current().?;
            if (now != last) _ = p.s.migrated.fetchAdd(1, .monotonic);
            last = now;
            if (cont.self() != &p.k) _ = p.s.bad.fetchAdd(1, .monotonic);
            for (mine, 0..) |v, i| if (v != @as(u64, p.id) << 32 | i) {
                _ = p.s.bad.fetchAdd(1, .monotonic);
            };
        }
        _ = p.s.left.fetchSub(1, .acq_rel);
    }
};

fn executorThread(s: *Shared, pool: *Pool, procs: []MProc) void {
    var ex: Executor = .init(pool);
    defer ex.deinit();
    for (procs) |*p| _ = ex.call(&p.k, MProc.run, p) catch @panic("oom");
    while (s.left.load(.acquire) > 0) {
        s.acquire();
        const next = s.q.pop();
        s.lock.unlock();
        if (next) |p| _ = ex.@"resume"(&p.k) else std.atomic.spinLoopHint();
    }
}

fn unparker(s: *Shared) void {
    var rng: std.Random.DefaultPrng = .init(1);
    while (s.left.load(.acquire) > 0) {
        s.acquire();
        const p: ?*MProc = if (s.parked.items.len > 0)
            s.parked.swapRemove(rng.random().uintLessThan(usize, s.parked.items.len))
        else
            null;
        s.lock.unlock();
        // Possibly before the park has switched out: the executor then
        // takes the unpark and goes straight on.
        if (p) |pp| cont.unpark(&pp.k) else std.atomic.spinLoopHint();
    }
}

test "continuations move between executors on host threads [scheduler]" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const per = 50;
    const nex = 3;
    var pool: Pool = .{ .size = 32 * 1024 };
    defer pool.deinit();
    var s: Shared = .{ .left = .init(per * nex) };
    defer s.parked.deinit(std.heap.page_allocator);
    var procs: [per * nex]MProc = undefined;
    for (&procs, 0..) |*p, i| p.* = .{ .s = &s, .id = @intCast(i) };

    var threads: [nex]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, executorThread, .{ &s, &pool, procs[i * per ..][0..per] });
    const u = try std.Thread.spawn(.{}, unparker, .{&s});
    for (threads) |t| t.join();
    u.join();
    try expectEqual(@as(usize, 0), s.bad.load(.acquire));
    try expect(s.migrated.load(.acquire) > 0);
    try expectEqual(pool.mapped, pool.nfree);
}

const Yielder = struct {
    k: Cont = .{ .ready = noready },
    steps: u32 = 0,

    fn noready(_: *Cont) void {}

    fn run(arg: ?*anyopaque) void {
        const y: *Yielder = @ptrCast(@alignCast(arg.?));
        var mark: u32 = 77;
        while (y.steps < 3) {
            y.steps += 1;
            cont.yield();
        }
        if (mark != 77) y.steps = 1000;
        mark += 1;
        cont.exit();
    }
};

test "a yield leaves a continuation runnable, and exit ends its call [scheduler]" {
    if (is_wasm) return error.SkipZigTest;
    var pool: Pool = .{ .size = 32 * 1024 };
    defer pool.deinit();
    var ex: Executor = .init(&pool);
    defer ex.deinit();
    var y: Yielder = .{};
    try expectEqual(cont.Outcome.yielded, try ex.call(&y.k, Yielder.run, &y));
    try expect(!y.k.isParked());
    try expectEqual(cont.Outcome.yielded, ex.@"resume"(&y.k));
    try expectEqual(cont.Outcome.yielded, ex.@"resume"(&y.k));
    try expectEqual(cont.Outcome.returned, ex.@"resume"(&y.k));
    try expectEqual(@as(u32, 3), y.steps);
    try expect(y.k.stack == null);
    try expect(ex.spare != null);
}
