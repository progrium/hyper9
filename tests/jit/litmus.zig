//! zig build litmus [-- options]: the litmus tests (src/jit/check/
//! litmus.zig) on every tier, with each test's tally of outcomes. Exits 1
//! if any run saw an outcome its test forbids.
//!
//!   --iters N    runs of each test on each tier (default 10000)
//!   --tier T     only this tier: t0, ir_eval, or native
//!   --only NAME  only tests whose names contain NAME
//!   --seed S     the skew's seed

const std = @import("std");
const vcpu = @import("vcpu");
const litmus = vcpu.check.litmus;

const Suite = struct { arch: *const litmus.Arch, tests: []const *const litmus.Test };
const suites = [_]Suite{
    .{ .arch = &vcpu.check.litmus_a64.arch, .tests = &vcpu.check.litmus_a64.all },
    .{ .arch = &vcpu.check.litmus_x86.arch, .tests = &vcpu.check.litmus_x86.all },
    .{ .arch = &vcpu.check.litmus_x86.arch64, .tests = &vcpu.check.litmus_x86.all64 },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var opts: litmus.Options = .{ .iterations = 10000 };
    var tier: ?litmus.Tier = null;
    var only: ?[]const u8 = null;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var args = Args{ .v = argv[1..] };
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--iters")) {
            opts.iterations = try std.fmt.parseInt(u32, args.next() orelse return usage(), 10);
        } else if (std.mem.eql(u8, a, "--tier")) {
            tier = std.meta.stringToEnum(litmus.Tier, args.next() orelse return usage()) orelse return usage();
        } else if (std.mem.eql(u8, a, "--only")) {
            only = args.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "--seed")) {
            opts.seed = try std.fmt.parseInt(u64, args.next() orelse return usage(), 10);
        } else return usage();
    }
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const w = &fw.interface;
    var bad = false;
    for (suites) |s| for (s.tests) |t| {
        if (only) |o| if (std.mem.indexOf(u8, t.name, o) == null) continue;
        for ([_]litmus.Tier{ .t0, .ir_eval, .native }) |tr| {
            if (tier) |want| if (tr != want) continue;
            if (tr == .native and !vcpu.emit.native.available()) continue;
            var o = opts;
            o.tier = tr;
            var tally = litmus.run(gpa, s.arch, t, o) catch |e| {
                try w.print("{s} ({t}): {t}\n", .{ t.name, tr, e });
                try w.flush();
                continue;
            };
            defer tally.deinit(gpa);
            try tally.print(t, tr, w);
            try w.flush();
            if (tally.forbidden != 0) bad = true;
        }
    };
    if (bad) std.process.exit(1);
}

fn usage() error{Usage} {
    std.debug.print("usage: zig build litmus -- [--iters N] [--tier t0|ir_eval|native] [--only NAME] [--seed S]\n", .{});
    return error.Usage;
}

const Args = struct {
    v: []const [:0]const u8,
    i: usize = 0,
    fn next(a: *Args) ?[]const u8 {
        if (a.i == a.v.len) return null;
        a.i += 1;
        return a.v[a.i - 1];
    }
};
