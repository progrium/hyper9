//! The test runner for tests/integration.zig, in place of Zig's default
//! one (lib/compiler/test_runner.zig, whose protocol with the build runner
//! this follows). It does two things the default can't:
//!
//! - Sharding. H9_TEST_SHARD is `I/N`, from zig build integration's
//!   -Dshards: the build runs the binary N times at once, and run I takes
//!   the cases whose names hash to I. The other cases aren't listed to the
//!   build runner at all, so a run's "pass, skip (total)" counts only its
//!   own cases, and a skip is a case that skipped, not one in another
//!   shard. Unset, or N below 2, every case runs.
//! - Skip reasons. A case that skips through tests/integration.zig's
//!   `skip` names why (`noteSkip`). With H9_TEST_SKIPS set (zig build
//!   integration -Dskips), each run prints its skipped cases at the end,
//!   grouped by reason; without it, it prints nothing for them.
//!
//! It has no fuzzing, which the integration cases don't use.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;
var stdin_reader: Io.File.Reader = undefined;
var stdout_writer: Io.File.Writer = undefined;
const runner_io: Io = Io.Threaded.global_single_threaded.io();
const pa = std.heap.page_allocator;

/// Why the running case skipped, if it said (noteSkip).
var reason_buf: [512]u8 = undefined;
var reason_len: ?usize = null;

/// Records why the running case is skipping; tests/integration.zig's
/// `skip` calls it before returning error.SkipZigTest. A later call in
/// the same case replaces an earlier one.
pub fn noteSkip(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&reason_buf, fmt, args) catch reason_buf[0..];
    reason_len = s.len;
}

const Skipped = struct { name: []const u8, reason: []const u8 };
var skipped: std.ArrayList(Skipped) = .empty;

/// The cases this run takes: indexes into builtin.test_functions.
fn shardCases(environ: std.process.Environ) []const u32 {
    const fns = builtin.test_functions;
    const out = pa.alloc(u32, fns.len) catch @panic("OOM");
    var i_n: ?[2]u64 = null;
    if (environ.getAlloc(pa, "H9_TEST_SHARD")) |v| {
        if (std.mem.indexOfScalar(u8, v, '/')) |slash| {
            const i = std.fmt.parseInt(u64, v[0..slash], 10) catch 0;
            const n = std.fmt.parseInt(u64, v[slash + 1 ..], 10) catch 1;
            if (n >= 2) i_n = .{ i, n };
        }
    } else |_| {}
    var len: usize = 0;
    for (fns, 0..) |f, idx| {
        if (i_n) |s| if (std.hash.Wyhash.hash(0, f.name) % s[1] != s[0]) continue;
        out[len] = @intCast(idx);
        len += 1;
    }
    return out[0..len];
}

const Status = enum { pass, skip, fail };

/// Runs builtin.test_functions[index] with a fresh testing allocator and
/// Io, as the default runner does, and returns its status and leaks.
fn runCase(init: std.process.Init.Minimal, index: u32) struct { Status, usize } {
    testing.environ = init.environ;
    testing.allocator_instance = .init(std.heap.page_allocator, .{
        .canary = 0xc3a701ba,
        .check_write_after_free = true,
    });
    testing.io_instance = .init(testing.allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    testing.log_level = .warn;
    log_err_count = 0;
    reason_len = null;
    const f = builtin.test_functions[index];
    const status: Status = if (f.func()) |_| .pass else |err| switch (err) {
        error.SkipZigTest => .skip,
        else => s: {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            break :s .fail;
        },
    };
    testing.io_instance.deinit();
    const leaks = testing.allocator_instance.deinit();
    if (status == .skip) {
        const why = if (reason_len) |n| reason_buf[0..n] else "no reason given";
        skipped.append(pa, .{ .name = f.name, .reason = pa.dupe(u8, why) catch "?" }) catch {};
    }
    return .{ status, leaks };
}

/// Prints the skipped cases by reason, most common first, if H9_TEST_SKIPS
/// is set.
fn reportSkips(environ: std.process.Environ) void {
    const want = environ.containsUnempty(pa, "H9_TEST_SKIPS") catch false;
    if (!want or skipped.items.len == 0) return;
    const items = skipped.items;
    std.mem.sort(Skipped, items, {}, struct {
        fn lt(_: void, a: Skipped, b: Skipped) bool {
            return switch (std.mem.order(u8, a.reason, b.reason)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, a.name, b.name) == .lt,
            };
        }
    }.lt);
    // Groups of one reason, as [start, end) into items.
    var groups: std.ArrayList([2]usize) = .empty;
    var i: usize = 0;
    while (i < items.len) {
        var j = i + 1;
        while (j < items.len and std.mem.eql(u8, items[j].reason, items[i].reason)) j += 1;
        groups.append(pa, .{ i, j }) catch return;
        i = j;
    }
    std.mem.sort([2]usize, groups.items, {}, struct {
        fn lt(_: void, a: [2]usize, b: [2]usize) bool {
            return a[1] - a[0] > b[1] - b[0];
        }
    }.lt);
    std.debug.print("{d} skipped:\n", .{items.len});
    for (groups.items) |g| {
        std.debug.print("  {d} {s}\n", .{ g[1] - g[0], items[g[0]].reason });
        for (items[g[0]..g[1]]) |s| std.debug.print("      {s}\n", .{s.name});
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.toSlice(pa) catch @panic("OOM");
    var listen = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, "--cache-dir")) {
            // For fuzzing, which this runner hasn't.
        } else {
            std.debug.panic("unrecognized command line argument: {s}", .{arg});
        }
    }
    const cases = shardCases(init.environ);
    if (listen) {
        mainServer(init, cases) catch |err| std.debug.panic("internal test runner failure: {t}", .{err});
    } else mainTerminal(init, cases);
}

fn mainServer(init: std.process.Init.Minimal, cases: []const u32) !void {
    stdin_reader = .initStreaming(.stdin(), runner_io, &stdin_buffer);
    stdout_writer = .initStreaming(.stdout(), runner_io, &stdout_buffer);
    var server: std.zig.Server = .{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
    };
    try server.serveStringMessage(.zig_version, builtin.zig_version_string);
    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => {
                reportSkips(init.environ);
                return std.process.exit(0);
            },
            .query_test_metadata => {
                var string_bytes: std.ArrayList(u8) = .empty;
                try string_bytes.append(pa, 0); // 0 is null
                const names = try pa.alloc(u32, cases.len);
                const expected_panic_msgs = try pa.alloc(u32, cases.len);
                for (cases, names, expected_panic_msgs) |idx, *name, *msg| {
                    name.* = @intCast(string_bytes.items.len);
                    try string_bytes.appendSlice(pa, builtin.test_functions[idx].name);
                    try string_bytes.append(pa, 0);
                    msg.* = 0;
                }
                try server.serveTestMetadata(.{
                    .names = names,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = string_bytes.items,
                });
            },
            .run_test => {
                const i = try server.receiveBody_u32();
                try server.serveStringMessage(.test_started, &.{});
                const status, const leaks = runCase(init, cases[i]);
                const TestResults = std.zig.Server.Message.TestResults;
                try server.serveTestResults(.{
                    .index = i,
                    .flags = .{
                        .status = switch (status) {
                            .pass => TestResults.Status.pass,
                            .skip => .skip,
                            .fail => .fail,
                        },
                        .fuzz = false,
                        .log_err_count = std.math.lossyCast(@FieldType(TestResults.Flags, "log_err_count"), log_err_count),
                        .leak_count = std.math.lossyCast(@FieldType(TestResults.Flags, "leak_count"), leaks),
                    },
                });
            },
            else => {
                std.debug.print("unsupported message: {x}\n", .{@backingInt(hdr.tag)});
                std.process.exit(1);
            },
        }
    }
}

fn mainTerminal(init: std.process.Init.Minimal, cases: []const u32) void {
    var ok: usize = 0;
    var skips: usize = 0;
    var fails: usize = 0;
    var leaked: usize = 0;
    var logged: usize = 0;
    for (cases, 0..) |idx, n| {
        std.debug.print("{d}/{d} {s}...", .{ n + 1, cases.len, builtin.test_functions[idx].name });
        const status, const leaks = runCase(init, idx);
        if (leaks != 0) leaked += 1;
        logged += log_err_count;
        switch (status) {
            .pass => ok += 1,
            .skip => skips += 1,
            .fail => fails += 1,
        }
        std.debug.print("{s}\n", .{switch (status) {
            .pass => "OK",
            .skip => "SKIP",
            .fail => "FAIL",
        }});
    }
    std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok, skips, fails });
    if (leaked != 0) std.debug.print("{d} tests leaked memory.\n", .{leaked});
    if (logged != 0) std.debug.print("{d} errors were logged.\n", .{logged});
    reportSkips(init.environ);
    if (fails != 0 or leaked != 0 or logged != 0) std.process.exit(1);
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(level) <= @backingInt(std.log.Level.err)) log_err_count +|= 1;
    if (@backingInt(level) <= @backingInt(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(level) ++ "): " ++ format ++ "\n", args);
    }
}
