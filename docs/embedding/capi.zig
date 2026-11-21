//! Proof of concept: a C ABI over h9.Machine, built as a shared library by
//! `zig build capi`, for hosts that load it with dlopen (such as Go with
//! purego). Not a stable API.

const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");

const gpa = std.heap.c_allocator;

var threaded: std.Io.Threaded = undefined;
var io_state: std.atomic.Value(u8) = .init(0); // 0 none, 1 initing, 2 ready

fn io() std.Io {
    while (true) switch (io_state.load(.acquire)) {
        2 => return threaded.io(),
        1 => std.atomic.spinLoopHint(),
        else => if (io_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            threaded = .init(gpa, .{});
            onStack();
            io_state.store(2, .release);
        },
    };
}

/// Io.Threaded installs SIGIO and SIGPIPE handlers without SA_ONSTACK. A
/// Go host requires it on every handler, since a signal can land on a
/// goroutine's small stack, so the handlers are put back with it.
fn onStack() void {
    if (builtin.os.tag == .windows) return;
    const posix = std.posix;
    for ([_]posix.SIG{ .IO, .PIPE }) |sig| {
        var act: posix.Sigaction = undefined;
        posix.sigaction(sig, null, &act);
        act.flags |= posix.SA.ONSTACK;
        posix.sigaction(sig, &act, null);
    }
}

/// Runs the a.out in `prog[0..len]` in a fresh machine on the default
/// backend, with the console's output written to `out`: a file
/// descriptor, or a HANDLE on Windows. The exits
/// string, or the kill note prefixed with "killed: ", goes to `status` as
/// a NUL-terminated string. Returns 0 if it ran, -1 if it couldn't (the
/// reason in `status`).
export fn h9_run_aout(prog: [*]const u8, len: usize, out: isize, status: [*]u8, status_cap: usize) c_int {
    const st = status[0..status_cap];
    const bytes = prog[0..len];
    const arch = (h9.aout.parse(bytes) catch return fail(st, "not an a.out")).arch;

    var buf: [4096]u8 = undefined;
    const file: std.Io.File = .{ .handle = if (builtin.os.tag == .windows) @ptrFromInt(@as(usize, @bitCast(out))) else @intCast(out), .flags = .{ .nonblocking = false } };
    var w = file.writerStreaming(io(), &buf);

    var m = h9.Machine.init(gpa, io(), .{
        .arch = arch,
        .policy = .{ .net = .disable, .memory = 256 << 20, .timeout_ns = 30 * std.time.ns_per_s },
        .stdio = .{ .out = &w.interface, .err = &w.interface },
    }) catch |e| return fail(st, @errorName(e));
    defer m.deinit();

    const s = m.run(.{ .bytes = bytes }, &.{"hello"}) catch |e|
        return fail(st, if (m.err_msg.len > 0) m.err_msg else @errorName(e));
    w.interface.flush() catch {};
    const text = switch (s) {
        .exited => |x| std.fmt.bufPrintZ(st, "{s}", .{x}),
        .killed => |x| std.fmt.bufPrintZ(st, "killed: {s}", .{x}),
    } catch "";
    _ = text;
    return 0;
}

/// The backend `.auto` picks on this host, for the caller's logs.
export fn h9_backend(status: [*]u8, status_cap: usize) c_int {
    var m = h9.Machine.init(gpa, io(), .{ .stdio = .{ .out = undefined, .err = undefined } }) catch |e|
        return fail(status[0..status_cap], @errorName(e));
    defer m.deinit();
    _ = std.fmt.bufPrintZ(status[0..status_cap], "{t}", .{m.backend.kind()}) catch {};
    return 0;
}

fn fail(st: []u8, msg: []const u8) c_int {
    _ = std.fmt.bufPrintZ(st, "{s}", .{msg}) catch {};
    return -1;
}
