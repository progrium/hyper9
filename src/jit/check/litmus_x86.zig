//! h86's litmus tests (litmus.zig): store buffering with and without a
//! locked instruction between the store and the load, message passing,
//! and a LOCK XADD counter, on T0 and T1. EBX holds the data page's
//! address; words are at [ebx], [ebx+8], and [ebx+16].
//!
//! x86 is TSO: plain SB may see both loads 0, but not with a locked
//! instruction (a full barrier) between, and MP's reader can't see the
//! flag without the data. On arm64 hosts, T1 keeps that with the region's
//! `tso` flag (LDAR and STLR).

const std = @import("std");
const litmus = @import("litmus.zig");
const x86 = @import("x86.zig");
const lift = @import("../x86/lift.zig");
const mem = @import("../../interp/mem.zig");
const ctx_mod = @import("../ctx.zig");
const cpu_mod = @import("../../interp/x86/cpu.zig");
const exec = @import("../../interp/x86/exec.zig");

const Cpu = cpu_mod.Cpu;
const ebx = 3;

pub const arch: litmus.Arch = .{
    .guest = &x86.guest,
    .init_cpu = initCpu,
    .reg = reg,
    .open = open,
    .close = close,
    .run_t0 = runT0,
};

fn initCpu(b: []u8, entry: u64, data: u64) void {
    const c: *Cpu = @ptrCast(@alignCast(b.ptr));
    c.* = .{};
    c.eip = @intCast(entry);
    c.r[ebx] = @intCast(data);
}

fn reg(b: []const u8, r: u8) u64 {
    const c: *const Cpu = @ptrCast(@alignCast(b.ptr));
    return c.r[r];
}

/// A thread's T0: the Map's memory, which `call.interp` reaches through
/// a lift.Mem in ctx.frontend too.
const Bound = struct {
    cpu: *Cpu,
    map: *const mem.Map,
    m: lift.Mem,
    icache: exec.ICache = .{},

    pub fn translate(b: *Bound, va: u32, access: cpu_mod.Access) ?[*]u8 {
        return mapTranslate(@constCast(b.map), va, access);
    }
};

fn mapTranslate(p: *anyopaque, va: u32, access: cpu_mod.Access) ?[*]u8 {
    const m: *const mem.Map = @ptrCast(@alignCast(p));
    for (m.regions) |r| if (va >= r.va and va - r.va < r.mem.len) {
        const ok = switch (access) {
            .read => r.read,
            .write => r.write,
            .exec => r.exec,
        };
        return if (ok) r.mem.ptr + (va - r.va) else null;
    };
    return null;
}

fn open(gpa: std.mem.Allocator, c: *ctx_mod.Ctx, map: *const mem.Map) anyerror!*anyopaque {
    const b = try gpa.create(Bound);
    b.* = .{ .cpu = c.cpuPtr(Cpu), .map = map, .m = .{ .ctx = @constCast(map), .translateFn = mapTranslate } };
    c.frontend = @intFromPtr(&b.m);
    return b;
}

fn close(gpa: std.mem.Allocator, p: *anyopaque) void {
    const b: *Bound = @ptrCast(@alignCast(p));
    gpa.destroy(b);
}

fn runT0(p: *anyopaque) anyerror!void {
    const b: *Bound = @ptrCast(@alignCast(p));
    b.cpu.icache = &b.icache;
    defer b.cpu.icache = null;
    while (true) switch (exec.run(b.cpu, b, .{})) {
        .syscall => return,
        .stopped => {},
        .exception => |v| return if (v == cpu_mod.vec_ud) error.Undefined else error.UnexpectedExit,
        .breakpoint, .fault => return error.UnexpectedExit,
    };
}

// ---------------------------------------------------------------- encodings

/// movl $imm, off(%ebx)
fn movStore(off: u8, imm: u8) [7]u8 {
    return .{ 0xc7, 0x43, off, imm, 0, 0, 0 };
}
/// movl off(%ebx), %r (eax 0, ecx 1, edx 2)
fn load(r: u8, off: u8) [3]u8 {
    return .{ 0x8b, 0x43 | r << 3, off };
}
/// movl $1, %ecx; xchgl %ecx, off(%ebx)
fn xchgStore(off: u8) [8]u8 {
    return .{ 0xb9, 1, 0, 0, 0, 0x87, 0x4b, off };
}
/// lock orl $0, 16(%ebx): a full barrier.
const lock_or = [_]u8{ 0xf0, 0x83, 0x4b, 16, 0 };
const int80 = [_]u8{ 0xcd, 0x80 };

const r0 = [_]litmus.Observe{ .{ .reg = .{ .thread = 0, .reg = 0 } }, .{ .reg = .{ .thread = 1, .reg = 0 } } };

// ---------------------------------------------------------------- tests

/// SB: each thread stores to one word and loads the other. Both 0 is
/// allowed under TSO, and an x86 host shows it.
pub const sb: litmus.Test = .{
    .name = "h86 SB",
    .threads = &.{
        &(movStore(0, 1) ++ load(0, 8) ++ int80),
        &(movStore(8, 1) ++ load(0, 0) ++ int80),
    },
    .observe = &r0,
};

/// SB with the stores as XCHG, which is locked: not both 0.
pub const sb_xchg: litmus.Test = .{
    .name = "h86 SB+xchg",
    .threads = &.{
        &(xchgStore(0) ++ load(0, 8) ++ int80),
        &(xchgStore(8) ++ load(0, 0) ++ int80),
    },
    .observe = &r0,
    .forbidden = &.{&.{ 0, 0 }},
};

/// SB with LOCK OR between store and load: not both 0.
pub const sb_lock: litmus.Test = .{
    .name = "h86 SB+lock-or",
    .threads = &.{
        &(movStore(0, 1) ++ lock_or ++ load(0, 8) ++ int80),
        &(movStore(8, 1) ++ lock_or ++ load(0, 0) ++ int80),
    },
    .observe = &r0,
    .forbidden = &.{&.{ 0, 0 }},
};

/// MP: data then flag; the reader loads flag then data. Flag without the
/// data is forbidden under TSO, with plain moves.
pub const mp: litmus.Test = .{
    .name = "h86 MP",
    .threads = &.{
        &(movStore(0, 1) ++ movStore(8, 1) ++ int80),
        &(load(0, 8) ++ load(1, 0) ++ int80),
    },
    .observe = &.{ .{ .reg = .{ .thread = 1, .reg = 0 } }, .{ .reg = .{ .thread = 1, .reg = 1 } } },
    .forbidden = &.{&.{ 1, 0 }},
};

const counter_n = 1000;
/// movl $N, %esi; loop: movl $1, %ecx; lock xaddl %ecx, (%ebx); decl
/// %esi; jnz loop; int $0x80
const counter_prog = [_]u8{ 0xbe, counter_n & 0xff, counter_n >> 8, 0, 0, 0xb9, 1, 0, 0, 0, 0xf0, 0x0f, 0xc1, 0x4b, 0, 0x4e, 0x75, 0xf3 } ++ int80;

/// Four threads add 1 a thousand times each with LOCK XADD: none lost.
pub const counter_xadd: litmus.Test = .{
    .name = "h86 LOCK XADD counter",
    .threads = &.{ &counter_prog, &counter_prog, &counter_prog, &counter_prog },
    .observe = &.{.{ .mem = 0 }},
    .only = &.{&.{4 * counter_n}},
};

pub const all = [_]*const litmus.Test{ &sb, &sb_xchg, &sb_lock, &mp, &counter_xadd };

test "litmus/x86: nothing forbidden on any tier" {
    const gpa = std.testing.allocator;
    for ([_]litmus.Tier{ .t0, .ir_eval, .native }) |tier| {
        if (tier == .native and !@import("../emit/native.zig").available()) continue;
        for (all) |t| {
            var tally = try litmus.run(gpa, &arch, t, .{ .iterations = 200, .tier = tier });
            defer tally.deinit(gpa);
            if (tally.forbidden != 0) {
                std.debug.print("{s} ({t}): forbidden outcomes\n", .{ t.name, tier });
                return error.Forbidden;
            }
        }
    }
}
