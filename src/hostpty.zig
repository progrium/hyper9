//! Pseudoterminals whose master the host holds (design/epoch-0/linux-pty.md,
//! "Host masters"): an embedder that draws a terminal, such as uitree's
//! terminal node, opens a pair inside a running machine and reads and
//! writes its master from host threads, while a program in the machine
//! runs on the slave, `/dev/pts/N` in the Linux view (`#τ/N`).
//!
//! The pair is the machine's like any other (src/kern/devpty.c): it's
//! opened by a kernel process of the machine, so its number is the
//! machine's, and the line discipline, `SIGWINCH`, `SIGHUP` and
//! controlling terminals work as they do for a guest's own pty. No host
//! pty is made.
//!
//! Threads. The machine serves the host's pairs with kernel processes
//! (src/machine.zig, `ptyServerMain`): a pty server that `run` starts
//! when `Options.ptys` is set, and per pair a control process, which
//! opens `#τ/ptmx` and writes the master, and a reader, which reads it
//! and hands the bytes to `Output.data`. Host calls only queue work and
//! wake them, so none blocks on the guest, except `Ptys.open`, which
//! waits for the pair to be made.

const std = @import("std");

pub const Error = error{
    /// No run is in progress, or it ended.
    NotRunning,
    /// The machine couldn't open a pair (no free ptys, `#τ` masked).
    OpenFailed,
    /// The pair is closed, or its machine ended.
    Gone,
    /// More than `in_cap` bytes are waiting for the program to read.
    Full,
    OutOfMemory,
};

/// The most a pair holds for the master that the program hasn't taken
/// yet, past the kernel's own 64 KiB queue.
pub const in_cap: usize = 1 << 20;

pub const Winsize = struct {
    rows: u16,
    cols: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

/// Where a pair's output goes. Both are called on the pair's reader, a
/// kernel process's thread, never on a host caller's.
pub const Output = struct {
    ctx: *anyopaque,
    /// What the program wrote to the slave. It may block: the master
    /// isn't read while it does, so the program's writes wait once the
    /// kernel's queue fills (backpressure).
    data: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    /// The slave's last open closed, and the master read to its end.
    /// Called each time that happens: reading starts again when a program
    /// opens the slave.
    hangup: *const fn (ctx: *anyopaque) void,
    /// The pair is freed: neither is called again. On whichever thread
    /// drops the last reference, which may be a host caller's.
    release: ?*const fn (ctx: *anyopaque) void = null,
};

/// A machine's host-held pairs. The embedder makes one, points
/// `Options.ptys` at it, and calls `open` from any thread while `run` is
/// running. It outlives the machine.
pub const Ptys = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mu: std.atomic.Mutex = .unlocked,
    /// Bumped when `pending` gains a pair or the run ends, for the pty
    /// server to wait on.
    seq: std.atomic.Value(u32) = .init(0),
    state: State = .idle,
    /// Pairs asked for that the pty server hasn't started on.
    pending: std.ArrayList(*Pty) = .empty,

    pub const State = enum { idle, running, done };

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Ptys {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(ps: *Ptys) void {
        ps.pending.deinit(ps.gpa);
    }

    fn lock(ps: *Ptys) void {
        while (!ps.mu.tryLock()) std.atomic.spinLoopHint();
    }

    fn wake(ps: *Ptys) void {
        _ = ps.seq.fetchAdd(1, .release);
        ps.io.futexWake(u32, &ps.seq.raw, std.math.maxInt(u32));
    }

    /// Makes a pair in the running machine with window size `size`, and
    /// returns it once it's open: its slave is unlocked, so a program can
    /// open `/dev/pts/{pty.n}` at once. `out` gets what the program writes.
    /// Release it with `close`.
    pub fn open(ps: *Ptys, out: Output, size: Winsize) Error!*Pty {
        const pty = try ps.gpa.create(Pty);
        pty.* = .{ .ps = ps, .out = out, .size = size };
        ps.lock();
        if (ps.state != .running) {
            ps.mu.unlock();
            ps.gpa.destroy(pty);
            return error.NotRunning;
        }
        ps.pending.append(ps.gpa, pty) catch {
            ps.mu.unlock();
            ps.gpa.destroy(pty);
            return error.OutOfMemory;
        };
        // The host's reference, and the one the pty server takes.
        pty.rc.store(2, .release);
        ps.mu.unlock();
        ps.wake();
        // Wait for the control process to open it, or fail to.
        while (true) {
            const seq = pty.seq.load(.acquire);
            pty.lock();
            const st = pty.state;
            pty.mu.unlock();
            switch (st) {
                .opening => {},
                .open => return pty,
                .failed, .gone => {
                    pty.unref();
                    return if (st == .failed) error.OpenFailed else error.NotRunning;
                },
            }
            ps.io.futexWaitTimeout(u32, &pty.seq.raw, seq, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
        }
    }

    // ---- the machine's side (src/machine.zig)

    /// `run` is starting: `open` works from now on.
    pub fn begin(ps: *Ptys) void {
        ps.lock();
        defer ps.mu.unlock();
        ps.state = .running;
    }

    /// `run` ended: no new pairs, and the ones not started fail.
    pub fn end(ps: *Ptys) void {
        ps.lock();
        ps.state = .done;
        const left = ps.pending.toOwnedSlice(ps.gpa) catch &.{};
        ps.mu.unlock();
        for (left) |pty| {
            pty.finish(.gone);
            pty.unref();
        }
        ps.gpa.free(left);
        ps.wake();
    }

    /// The pty server: the next pair to start, or null once the run is
    /// ending (`stopping` says so) or has ended.
    pub fn next(ps: *Ptys, stopping: *const std.atomic.Value(bool)) ?*Pty {
        while (true) {
            const seq = ps.seq.load(.acquire);
            ps.lock();
            const pty: ?*Pty = if (ps.pending.items.len > 0) ps.pending.orderedRemove(0) else null;
            const done = ps.state != .running;
            ps.mu.unlock();
            if (pty) |p| return p;
            if (done or stopping.load(.acquire)) return null;
            ps.io.futexWaitTimeout(u32, &ps.seq.raw, seq, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
        }
    }
};

/// One host-held pair.
pub const Pty = struct {
    ps: *Ptys,
    out: Output,
    /// The pair's number: the slave is `/dev/pts/{n}`, or `#τ/{n}`. Set
    /// once `open` returns.
    n: u32 = 0,
    /// The host's reference and the machine's processes'.
    rc: std.atomic.Value(u32) = .init(1),
    mu: std.atomic.Mutex = .unlocked,
    /// Bumped by every request and state change.
    seq: std.atomic.Value(u32) = .init(0),
    state: State = .opening,
    /// Bytes for the master, not written yet.
    in: std.ArrayList(u8) = .empty,
    /// The window size; `size_set` when the control process hasn't
    /// applied it yet.
    size: Winsize,
    size_set: bool = true,
    closing: bool = false,
    /// The control and reader processes, for `close` to interrupt
    /// (kern.Proc), while they're running.
    ctl: ?*anyopaque = null,
    reader: ?*anyopaque = null,
    /// Set by the machine: interrupts a kernel process (kern.interrupt).
    interrupt: ?*const fn (*anyopaque) void = null,

    pub const State = enum { opening, open, failed, gone };

    fn lock(pty: *Pty) void {
        while (!pty.mu.tryLock()) std.atomic.spinLoopHint();
    }

    fn wake(pty: *Pty) void {
        _ = pty.seq.fetchAdd(1, .release);
        pty.ps.io.futexWake(u32, &pty.seq.raw, std.math.maxInt(u32));
    }

    /// Any thread: queues `bytes` for the master, as if typed. Never
    /// blocks; fails with `Full` past `in_cap` unread.
    pub fn write(pty: *Pty, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        pty.lock();
        if (pty.state != .open or pty.closing) {
            pty.mu.unlock();
            return error.Gone;
        }
        if (pty.in.items.len + bytes.len > in_cap) {
            pty.mu.unlock();
            return error.Full;
        }
        pty.in.appendSlice(pty.ps.gpa, bytes) catch {
            pty.mu.unlock();
            return error.OutOfMemory;
        };
        pty.mu.unlock();
        pty.wake();
    }

    /// Any thread: a new window size, which the pair takes as TIOCSWINSZ
    /// does: a change sends SIGWINCH to its foreground group.
    pub fn resize(pty: *Pty, size: Winsize) void {
        pty.lock();
        pty.size = size;
        pty.size_set = true;
        pty.mu.unlock();
        pty.wake();
    }

    /// Any thread: closes the master, which hangs the slave up (its
    /// foreground group gets SIGHUP), and releases the host's reference.
    /// It doesn't wait for the reader: one already inside `Output.data`
    /// finishes that call, so `data` must return; `release` says when
    /// nothing will call `out` again.
    pub fn close(pty: *Pty) void {
        pty.lock();
        pty.closing = true;
        if (pty.interrupt) |f| {
            if (pty.ctl) |k| f(k);
            if (pty.reader) |k| f(k);
        }
        pty.mu.unlock();
        pty.wake();
        pty.unref();
    }

    pub fn ref(pty: *Pty) *Pty {
        _ = pty.rc.fetchAdd(1, .monotonic);
        return pty;
    }

    pub fn unref(pty: *Pty) void {
        if (pty.rc.fetchSub(1, .acq_rel) != 1) return;
        if (pty.out.release) |f| f(pty.out.ctx);
        pty.in.deinit(pty.ps.gpa);
        pty.ps.gpa.destroy(pty);
    }

    // ---- the machine's side (src/machine.zig)

    /// The control process: the pair opened (or not).
    pub fn finish(pty: *Pty, st: State) void {
        pty.lock();
        // `gone` ends an open pair; a pair that failed stays failed.
        if (pty.state == .opening or (st == .gone and pty.state == .open)) pty.state = st;
        pty.mu.unlock();
        pty.wake();
    }

    /// The control process's next work: bytes to write (into `buf`,
    /// cleared first) and a size to apply. Waits up to 100 ms for some;
    /// `closing` true means close the master and exit.
    pub fn take(pty: *Pty, buf: *std.ArrayList(u8)) error{OutOfMemory}!Work {
        const seq = pty.seq.load(.acquire);
        pty.lock();
        buf.clearRetainingCapacity();
        std.mem.swap(std.ArrayList(u8), buf, &pty.in);
        const w: Work = .{
            .size = if (pty.size_set) pty.size else null,
            .closing = pty.closing,
            .bytes = buf.items,
        };
        pty.size_set = false;
        pty.mu.unlock();
        if (w.size == null and w.bytes.len == 0 and !w.closing)
            pty.ps.io.futexWaitTimeout(u32, &pty.seq.raw, seq, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
        return w;
    }

    pub const Work = struct {
        size: ?Winsize,
        closing: bool,
        bytes: []const u8,
    };

    /// Whether `close` was called.
    pub fn isClosing(pty: *Pty) bool {
        pty.lock();
        defer pty.mu.unlock();
        return pty.closing;
    }

    /// Records (or, with null, forgets) the control or reader process,
    /// for `close` to interrupt. Returns false, recording nothing, if the
    /// pair is already closing.
    pub fn setProc(pty: *Pty, which: enum { ctl, reader }, k: ?*anyopaque, interrupt: *const fn (*anyopaque) void) bool {
        pty.lock();
        defer pty.mu.unlock();
        pty.interrupt = interrupt;
        const slot = switch (which) {
            .ctl => &pty.ctl,
            .reader => &pty.reader,
        };
        slot.* = k;
        return k == null or !pty.closing;
    }
};

test "a pair queued before the run ends fails" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{});
    defer threaded.deinit();
    var ps: Ptys = .init(t.allocator, threaded.io());
    defer ps.deinit();
    const Sink = struct {
        fn data(_: *anyopaque, _: []const u8) void {}
        fn hangup(_: *anyopaque) void {}
    };
    var ctx: u8 = 0;
    const out: Output = .{ .ctx = &ctx, .data = Sink.data, .hangup = Sink.hangup };
    try t.expectError(error.NotRunning, ps.open(out, .{ .rows = 24, .cols = 80 }));
    ps.begin();
    const Ender = struct {
        fn run(p: *Ptys) void {
            // Take nothing: end the run while the pair waits.
            while (true) {
                p.lock();
                const n = p.pending.items.len;
                p.mu.unlock();
                if (n > 0) break;
                std.Thread.yield() catch {};
            }
            p.end();
        }
    };
    const th = try std.Thread.spawn(.{}, Ender.run, .{&ps});
    try t.expectError(error.NotRunning, ps.open(out, .{ .rows = 24, .cols = 80 }));
    th.join();
}
