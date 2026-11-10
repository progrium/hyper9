//! zig build fuzz-long: fuzz-a64, fuzz-x86, and fuzz-x64 with the region check,
//! --native, and lockstep where Unicorn is built in, --jobs processes of
//! each at once for --minutes, seeds 2^40 apart from --seed. (A Run step
//! per job would run them one after another: zig build gives each one the
//! terminal in turn.) Each fuzzer prints its own totals and tally; this
//! exits 1 if any of them failed or diverged.
//!
//!   fuzz-long --minutes M --jobs J --seed S FUZZER...

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    var minutes: []const u8 = "60";
    var jobs: u32 = 2;
    var seed: u64 = 0;
    var fuzzers: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--minutes") and i + 1 < argv.len) {
            i += 1;
            minutes = argv[i];
        } else if (std.mem.eql(u8, a, "--jobs") and i + 1 < argv.len) {
            i += 1;
            jobs = try std.fmt.parseInt(u32, argv[i], 0);
        } else if (std.mem.eql(u8, a, "--seed") and i + 1 < argv.len) {
            i += 1;
            seed = try std.fmt.parseInt(u64, argv[i], 0);
        } else try fuzzers.append(arena, a);
    }
    var children: std.ArrayList(std.process.Child) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    for (fuzzers.items) |f| for (0..jobs) |j| {
        const s = try std.fmt.allocPrint(arena, "{d}", .{seed +% (@as(u64, j) << 40)});
        const child = try std.process.spawn(io, .{
            .argv = &.{ f, "--native", "--keep-going", "--len", "64", "--minutes", minutes, "--seed", s },
            .stdin = .ignore,
        });
        try children.append(arena, child);
        try names.append(arena, try std.fmt.allocPrint(arena, "{s} --seed {s}", .{ std.fs.path.basename(f), s }));
    };
    var bad = false;
    for (children.items, names.items) |*c, n| {
        const term = try c.wait(io);
        const ok = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) {
            std.debug.print("fuzz-long: {s}: {any}\n", .{ n, term });
            bad = true;
        }
    }
    if (bad) std.process.exit(1);
    std.debug.print("fuzz-long: {d} fuzzer runs, none diverged\n", .{children.items.len});
}
