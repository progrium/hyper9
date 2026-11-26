//! Test and fuzzing support: compiles IR regions with this host's emitter
//! (x64.zig or arm64.zig) into code memory, for check.zig's `.entry` tier.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../ir.zig");
const ctx = @import("../ctx.zig");
const alloc_mod = @import("../alloc.zig");
const codemem = @import("../codemem.zig");
const emitter = @import("../emitter.zig");

const host = switch (builtin.cpu.arch) {
    .x86_64 => @import("x64.zig"),
    .aarch64 => @import("arm64.zig"),
    else => null,
};

/// Prints the `fp.*` and `v.*` ops most often compiled to ir_eval's
/// fallback (x64 only), with their lane sizes.
pub fn printFallbacks() void {
    if (@TypeOf(host) == @TypeOf(null) or !@hasDecl(host, "ext_fallbacks")) return;
    const t = &host.ext_fallbacks;
    var shown: usize = 0;
    var done: [t.len]bool = @splat(false);
    while (shown < 12) : (shown += 1) {
        var best: ?usize = null;
        for (t, 0..) |n, k| if (n != 0 and !done[k] and (best == null or n > t[best.?])) {
            best = k;
        };
        const k = best orelse break;
        done[k] = true;
        const op: ir.Op = std.enums.fromInt(ir.Op, k / 4) orelse continue;
        std.debug.print("    {d:>7} {s} esize {d}\n", .{ t[k], @tagName(op), k % 4 });
    }
}

/// Whether this host has an emitter and code memory works.
pub fn available() bool {
    return @TypeOf(host) != @TypeOf(null) and codemem.available();
}

pub const name = if (@TypeOf(host) != @TypeOf(null)) @tagName(builtin.cpu.arch) else "none";

/// The host's emitter lowers lazy eflags records (`Emitter.lazy_eflags`);
/// ir_eval does too, so with no host emitter it's true.
pub const lazy_eflags = if (@TypeOf(host) != @TypeOf(null)) host.emitter_def.lazy_eflags else true;

/// A code region that `compile` fills, resetting it when full (which
/// invalidates every entry it returned before).
pub const Native = struct {
    code: codemem.Region,
    /// Regions compiled, and those the emitter declined.
    compiled: u64 = 0,
    unsupported: u64 = 0,

    pub fn init() !Native {
        if (!available()) return error.JitUnavailable;
        var code: codemem.Region = try .init(8 << 20);
        if (builtin.cpu.arch == .x86_64) code.addUnwind(@import("x64.zig").win64_unwind);
        return .{ .code = code };
    }

    pub fn deinit(n: *Native) void {
        n.code.deinit();
    }

    /// The region's entry, or null if the emitter doesn't support it.
    pub fn compile(n: *Native, gpa: std.mem.Allocator, reg: *const ir.Region) !?ctx.EntryFn {
        if (@TypeOf(host) == @TypeOf(null)) return null;
        var a = try alloc_mod.spillAll(gpa, reg);
        defer a.deinit(gpa);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const out = host.emit(gpa, reg, &a, &buf) catch |e| switch (e) {
            error.Unsupported => {
                n.unsupported += 1;
                return null;
            },
            else => |x| return x,
        };
        const off = n.code.alloc(buf.items.len, 16) orelse blk: {
            n.code.reset();
            break :blk n.code.alloc(buf.items.len, 16) orelse return error.TooLarge;
        };
        n.code.write(off, buf.items);
        n.compiled += 1;
        return n.code.entry(off + out.entry);
    }
};
