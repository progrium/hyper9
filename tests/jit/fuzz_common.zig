//! What fuzz-a64 and fuzz-x86 share: options, the class filter, and the
//! tally of divergences.

const std = @import("std");

pub const usage =
    \\  --seed N       first seed (default: from the clock); program i uses seed+i
    \\  --iters N      programs to run (default 1000)
    \\  --len N        instructions per program (default 32)
    \\  --no-check     skip the region check
    \\  --no-lockstep  skip lockstep
    \\  --native       also run each checked region as this host's generated code
    \\  --keep-going   tally divergences by what differs instead of stopping
    \\  --trace        print each seed and program before running it
    \\  --without C,.. leave out instruction classes
    \\
;

pub fn Args(comptime Class: type) type {
    return struct {
        seed: u64,
        iters: u64 = 1000,
        len: u32 = 32,
        check: bool = true,
        lockstep: bool = true,
        native: bool = false,
        keep_going: bool = false,
        trace: bool = false,
        without: std.EnumSet(Class) = .initEmpty(),
        classes_buf: [std.enums.values(Class).len]Class = undefined,
        nclasses: usize = 0,

        const Self = @This();

        pub fn parse(name: []const u8, init: std.process.Init) !Self {
            var args: Self = .{ .seed = @truncate(@as(u128, @bitCast(@as(i128, std.Io.Timestamp.now(init.io, .real).nanoseconds)))) };
            const argv = try init.minimal.args.toSlice(init.arena.allocator());
            var i: usize = 1;
            while (i < argv.len) : (i += 1) {
                const a = argv[i];
                const next = if (i + 1 < argv.len) argv[i + 1] else "";
                if (std.mem.eql(u8, a, "--seed")) {
                    args.seed = try std.fmt.parseInt(u64, next, 0);
                    i += 1;
                } else if (std.mem.eql(u8, a, "--iters")) {
                    args.iters = try std.fmt.parseInt(u64, next, 0);
                    i += 1;
                } else if (std.mem.eql(u8, a, "--len")) {
                    args.len = try std.fmt.parseInt(u32, next, 0);
                    i += 1;
                } else if (std.mem.eql(u8, a, "--no-check")) {
                    args.check = false;
                } else if (std.mem.eql(u8, a, "--native")) {
                    args.native = true;
                } else if (std.mem.eql(u8, a, "--no-lockstep")) {
                    args.lockstep = false;
                } else if (std.mem.eql(u8, a, "--keep-going")) {
                    args.keep_going = true;
                } else if (std.mem.eql(u8, a, "--trace")) {
                    args.trace = true;
                } else if (std.mem.eql(u8, a, "--without")) {
                    var it = std.mem.tokenizeScalar(u8, next, ',');
                    while (it.next()) |cn| {
                        const c = std.meta.stringToEnum(Class, cn) orelse {
                            std.debug.print("{s}: no class {s}; classes: {any}\n", .{ name, cn, std.enums.values(Class) });
                            return error.Usage;
                        };
                        args.without.insert(c);
                    }
                    i += 1;
                } else {
                    std.debug.print("{s}: unknown option {s}\n{s}", .{ name, a, usage });
                    return error.Usage;
                }
            }
            for (std.enums.values(Class)) |c| if (!args.without.contains(c)) {
                args.classes_buf[args.nclasses] = c;
                args.nclasses += 1;
            };
            if (args.nclasses == 0) return error.Usage;
            return args;
        }

        pub fn classes(a: *const Self) []const Class {
            return a.classes_buf[0..a.nclasses];
        }
    };
}

/// Divergences counted by what differs (each report line's text before
/// its colon), not by the values.
pub const Tally = struct {
    map: std.StringArrayHashMapUnmanaged(u64) = .empty,

    pub fn deinit(t: *Tally, gpa: std.mem.Allocator) void {
        for (t.map.keys()) |k| gpa.free(k);
        t.map.deinit(gpa);
    }

    pub fn add(t: *Tally, gpa: std.mem.Allocator, report: []const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var lines = std.mem.splitScalar(u8, report, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, " region at ") != null) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (n > 0) try out.append(gpa, ' ');
            try out.appendSlice(gpa, line[0..colon]);
            n += 1;
            if (n == 6) break;
        }
        const g = try t.map.getOrPut(gpa, out.items);
        if (g.found_existing) {
            g.value_ptr.* += 1;
        } else {
            g.key_ptr.* = try out.toOwnedSlice(gpa);
            g.value_ptr.* = 1;
        }
    }

    pub fn print(t: *const Tally) void {
        for (t.map.keys(), t.map.values()) |k, v| std.debug.print("  {d:>6}  {s}\n", .{ v, k });
    }
};
