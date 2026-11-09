//! A machine run's console input: a host thread that reads `Stdio.in` on
//! behalf of guest console reads, so a guest process waits in drawterm's
//! sleep (src/kern/devhcons.c), where a note or a teardown interrupts it,
//! and never in a host read. See SPEC.md, "Filesystem, boot, and I/O".
//!
//! The thread does one host read per guest request, as a terminal returns
//! one line, and nothing reads ahead: input no guest asked for stays in the
//! host stream. Bytes read for an interrupted request are kept for the
//! next read, and dropped when the run ends.

const std = @import("std");
const web = @import("web.zig");

/// Makes a read blocked in a `Stdio.in` on `thread` return, with any
/// result, so a run can end while a console read is pending. Called
/// repeatedly until the reader thread exits, so it needn't handle a read
/// that hasn't started yet.
pub const Cancel = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, thread: web.Thread) void,
    /// Clears a cancel left over from an earlier run on the same stream;
    /// called on the reader thread before its first read.
    reset: *const fn (ctx: *anyopaque) void,
};

pub const ConsoleInput = struct {
    io: std.Io,
    src: *std.Io.Reader,
    cancel: ?Cancel,
    /// The console's id, for `wake`.
    id: u32,
    /// Wakes a guest read sleeping on console `id`.
    wake: *const fn (id: u32) void,

    mutex: std.atomic.Mutex = .unlocked,
    /// Guarded by `mutex`, but read without it by `ready`.
    state: std.atomic.Value(State) = .init(.idle),
    buf: [4096]u8 = undefined,
    off: usize = 0,
    len: usize = 0,
    /// Bumped to wake the thread.
    seq: std.atomic.Value(u32) = .init(0),
    thread: ?web.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    pub const State = enum(u8) {
        /// No request and nothing buffered.
        idle,
        /// A guest asked for input; the thread is reading.
        want,
        /// `buf[off..len]` holds input.
        data,
        eof,
        failed,
    };

    /// What `read` returns when the guest has to wait for `ready`.
    pub const would_block = -2;

    /// Copies buffered input into `dest` and returns its length, 0 at end
    /// of input or -1 on a read error. With nothing buffered it asks the
    /// thread for a read and returns `would_block`. Never blocks.
    pub fn read(c: *ConsoleInput, dest: []u8) isize {
        if (dest.len == 0) return 0;
        c.lock();
        defer c.mutex.unlock();
        switch (c.state.raw) {
            .data => {
                const n = @min(dest.len, c.len - c.off);
                @memcpy(dest[0..n], c.buf[c.off..][0..n]);
                c.off += n;
                if (c.off == c.len) c.state.store(.idle, .release);
                return @intCast(n);
            },
            // A terminal can give more input after an EOF, so each one is
            // reported once.
            .eof => {
                c.state.store(.idle, .release);
                return 0;
            },
            .failed => {
                c.state.store(.idle, .release);
                return -1;
            },
            .want => return would_block,
            .idle => {
                if (c.thread == null) {
                    c.thread = web.Thread.spawn(.{}, run, .{c}) catch return -1;
                }
                c.state.store(.want, .release);
                _ = c.seq.fetchAdd(1, .release);
                c.io.futexWake(u32, &c.seq.raw, 1);
                return would_block;
            },
        }
    }

    /// Asks the thread for a read if there's no request and nothing
    /// buffered, as `read` does, for a guest that polls before it reads
    /// (busybox `read`). Returns whether input is there now.
    pub fn request(c: *ConsoleInput) bool {
        c.lock();
        defer c.mutex.unlock();
        if (c.state.raw != .idle) return c.state.raw != .want;
        if (c.thread == null) {
            c.thread = web.Thread.spawn(.{}, run, .{c}) catch return true;
        }
        c.state.store(.want, .release);
        _ = c.seq.fetchAdd(1, .release);
        c.io.futexWake(u32, &c.seq.raw, 1);
        return false;
    }

    /// Whether a guest read waiting for input can go on.
    pub fn ready(c: *const ConsoleInput) bool {
        return switch (c.state.load(.acquire)) {
            .idle, .want => false,
            .data, .eof, .failed => true,
        };
    }

    /// Stops the thread, cancelling a pending host read for up to
    /// `grace_ms`. Returns false if the thread is still in a host read it
    /// couldn't cancel: it's detached then, and `c` must be leaked, since
    /// the thread still uses it. Once stopping, the thread never touches
    /// the console again.
    pub fn stop(c: *ConsoleInput, grace_ms: u32) bool {
        c.stopping.store(true, .release);
        _ = c.seq.fetchAdd(1, .release);
        c.io.futexWake(u32, &c.seq.raw, 1);
        const t = c.thread orelse return true;
        var waited: u32 = 0;
        while (!c.done.load(.acquire)) : (waited += 10) {
            if (waited >= grace_ms) {
                t.detach();
                return false;
            }
            if (c.cancel) |k| k.func(k.ctx, t);
            c.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        t.join();
        return true;
    }

    fn lock(c: *ConsoleInput) void {
        while (!c.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn run(c: *ConsoleInput) void {
        defer c.done.store(true, .release);
        if (c.cancel) |k| k.reset(k.ctx);
        while (true) {
            const seq = c.seq.load(.acquire);
            if (c.stopping.load(.acquire)) return;
            if (c.state.load(.acquire) != .want) {
                c.io.futexWaitUncancelable(u32, &c.seq.raw, seq);
                continue;
            }
            var data = [1][]u8{&c.buf};
            var failed = false;
            const got: ?usize = c.src.readVec(&data) catch |err| switch (err) {
                error.EndOfStream => null,
                error.ReadFailed => blk: {
                    failed = true;
                    break :blk 0;
                },
            };
            if (c.stopping.load(.acquire)) return;
            // A reader may fill its own buffer and return 0; read again.
            if (!failed and got != null and got.? == 0) continue;
            const next: State = if (failed) .failed else if (got == null) .eof else .data;
            c.lock();
            c.off = 0;
            c.len = got orelse 0;
            c.state.store(next, .release);
            c.mutex.unlock();
            c.wake(c.id);
        }
    }
};

const testing = std.testing;

const Woken = struct {
    var n: std.atomic.Value(u32) = .init(0);
    fn wake(_: u32) void {
        _ = n.fetchAdd(1, .release);
    }
};

fn waitReady(c: *ConsoleInput) !void {
    var i: u32 = 0;
    while (!c.ready()) : (i += 1) {
        if (i > 2000) return error.Timeout;
        try c.io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "reads on request, keeps the rest for the next read, and reports EOF once" {
    var src: std.Io.Reader = .fixed("hello");
    var c: ConsoleInput = .{ .io = testing.io, .src = &src, .cancel = null, .id = 0, .wake = Woken.wake };
    var buf: [3]u8 = undefined;
    try testing.expectEqual(ConsoleInput.would_block, c.read(&buf));
    try testing.expectEqual(ConsoleInput.would_block, c.read(&buf));
    try waitReady(&c);
    try testing.expectEqual(3, c.read(&buf));
    try testing.expectEqualStrings("hel", &buf);
    try testing.expectEqual(2, c.read(&buf));
    try testing.expectEqualStrings("lo", buf[0..2]);
    try testing.expectEqual(ConsoleInput.would_block, c.read(&buf));
    try waitReady(&c);
    try testing.expectEqual(0, c.read(&buf));
    try testing.expect(c.stop(1000));
    try testing.expect(Woken.n.load(.acquire) >= 2);
}

test "stop without a read never starts the thread" {
    var src: std.Io.Reader = .fixed("x");
    var c: ConsoleInput = .{ .io = testing.io, .src = &src, .cancel = null, .id = 0, .wake = Woken.wake };
    try testing.expect(c.stop(0));
    try testing.expect(c.thread == null);
}
