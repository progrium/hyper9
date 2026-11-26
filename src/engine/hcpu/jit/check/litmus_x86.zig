//! h86's litmus tests (litmus.zig): store buffering with and without a
//! locked instruction between the store and the load, message passing,
//! and a LOCK XADD counter, on T0 and T1. EBX holds the data page's
//! address; words are at [ebx], [ebx+8], and [ebx+16]. hx64's are the
//! same in long mode, with 64-bit words, and a CMPXCHG16B counter
//! (`arch64` and `all64`, below).
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
    c.helpers = @import("../x86/helpers.zig").tableAddr();
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

// ---------------------------------------------------------------- long mode

const Cpu64 = cpu_mod.Cpu64;
const check = @import("../check.zig");
const lift_has_mem64 = @hasDecl(lift, "Mem64");

pub const arch64: litmus.Arch = .{
    .guest = &x86.guest64,
    .init_cpu = initCpu64,
    .reg = reg64,
    .open = open64,
    .close = close64,
    .run_t0 = runT064,
};

fn initCpu64(b: []u8, entry: u64, data: u64) void {
    const c: *Cpu64 = @ptrCast(@alignCast(b.ptr));
    c.* = .{};
    c.rip = entry;
    c.r[ebx] = data;
}

fn reg64(b: []const u8, r: u8) u64 {
    const c: *const Cpu64 = @ptrCast(@alignCast(b.ptr));
    return c.r[r];
}

/// A long-mode thread's T0 over the Map, and `call.interp`'s memory when
/// the lifter has a long-mode one (lift.Mem64).
const Bound64 = struct {
    cpu: *Cpu64,
    map: *const mem.Map,
    m: if (lift_has_mem64) lift.Mem64 else void,

    pub fn translate(b: *Bound64, va: u64, access: cpu_mod.Access) ?[*]u8 {
        return mapTranslate64(@constCast(b.map), va, access);
    }
};

fn mapTranslate64(p: *anyopaque, va: u64, access: cpu_mod.Access) ?[*]u8 {
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

fn open64(gpa: std.mem.Allocator, c: *ctx_mod.Ctx, map: *const mem.Map) anyerror!*anyopaque {
    const b = try gpa.create(Bound64);
    b.* = .{ .cpu = c.cpuPtr(Cpu64), .map = map, .m = if (lift_has_mem64) .{ .ctx = @constCast(map), .translateFn = mapTranslate64 } else {} };
    if (lift_has_mem64) c.frontend = @intFromPtr(&b.m);
    c.helpers = @import("../x86/helpers.zig").tableAddr();
    return b;
}

fn close64(gpa: std.mem.Allocator, p: *anyopaque) void {
    const b: *Bound64 = @ptrCast(@alignCast(p));
    gpa.destroy(b);
}

fn runT064(p: *anyopaque) anyerror!void {
    const b: *Bound64 = @ptrCast(@alignCast(p));
    while (true) switch (exec.runIn(.long, b.cpu, b, .{})) {
        .syscall => return,
        .stopped => {},
        .exception => |v| return if (v == cpu_mod.vec_ud) error.Undefined else error.UnexpectedExit,
        .breakpoint, .fault => return error.UnexpectedExit,
    };
}

/// movq $imm, off(%rbx)
fn movStore64(off: u8, imm: u8) [8]u8 {
    return .{ 0x48, 0xc7, 0x43, off, imm, 0, 0, 0 };
}
/// movq off(%rbx), %r (rax 0, rcx 1, rdx 2)
fn load64(r: u8, off: u8) [4]u8 {
    return .{ 0x48, 0x8b, 0x43 | r << 3, off };
}
/// movl $1, %ecx; xchgq %rcx, off(%rbx)
fn xchgStore64(off: u8) [9]u8 {
    return .{ 0xb9, 1, 0, 0, 0, 0x48, 0x87, 0x4b, off };
}
/// lock orq $0, 16(%rbx)
const lock_or64 = [_]u8{ 0xf0, 0x48, 0x83, 0x4b, 16, 0 };
const syscall = [_]u8{ 0x0f, 0x05 };

pub const sb64: litmus.Test = .{
    .name = "hx64 SB",
    .threads = &.{
        &(movStore64(0, 1) ++ load64(0, 8) ++ syscall),
        &(movStore64(8, 1) ++ load64(0, 0) ++ syscall),
    },
    .observe = &r0,
};

pub const sb_xchg64: litmus.Test = .{
    .name = "hx64 SB+xchg",
    .threads = &.{
        &(xchgStore64(0) ++ load64(0, 8) ++ syscall),
        &(xchgStore64(8) ++ load64(0, 0) ++ syscall),
    },
    .observe = &r0,
    .forbidden = &.{&.{ 0, 0 }},
};

pub const sb_lock64: litmus.Test = .{
    .name = "hx64 SB+lock-or",
    .threads = &.{
        &(movStore64(0, 1) ++ lock_or64 ++ load64(0, 8) ++ syscall),
        &(movStore64(8, 1) ++ lock_or64 ++ load64(0, 0) ++ syscall),
    },
    .observe = &r0,
    .forbidden = &.{&.{ 0, 0 }},
};

pub const mp64: litmus.Test = .{
    .name = "hx64 MP",
    .threads = &.{
        &(movStore64(0, 1) ++ movStore64(8, 1) ++ syscall),
        &(load64(0, 8) ++ load64(1, 0) ++ syscall),
    },
    .observe = &.{ .{ .reg = .{ .thread = 1, .reg = 0 } }, .{ .reg = .{ .thread = 1, .reg = 1 } } },
    .forbidden = &.{&.{ 1, 0 }},
};

/// movl $N, %esi; loop: movl $1, %ecx; lock xaddq %rcx, (%rbx); decl
/// %esi; jnz loop; syscall
const counter_prog64 = [_]u8{ 0xbe, counter_n & 0xff, counter_n >> 8, 0, 0, 0xb9, 1, 0, 0, 0, 0xf0, 0x48, 0x0f, 0xc1, 0x0b, 0xff, 0xce, 0x75, 0xf2 } ++ syscall;

pub const counter_xadd64: litmus.Test = .{
    .name = "hx64 LOCK XADD counter",
    .threads = &.{ &counter_prog64, &counter_prog64, &counter_prog64, &counter_prog64 },
    .observe = &.{.{ .mem = 0 }},
    .only = &.{&.{4 * counter_n}},
};

/// Adds 1 to the u64 at (%rbx) a thousand times with LOCK CMPXCHG16B.
pub const counter16b_prog = [_]u8{
    0x48, 0x89, 0xdf, // movq %rbx, %rdi
    0xbe, counter_n & 0xff, counter_n >> 8, 0, 0, // movl $N, %esi
    0x48, 0x8b, 0x07, // loop: movq (%rdi), %rax
    0x48, 0x8b, 0x57, 0x08, // movq 8(%rdi), %rdx
    0x48, 0x8d, 0x58, 0x01, // retry: leaq 1(%rax), %rbx
    0x48, 0x89, 0xd1, // movq %rdx, %rcx
    0xf0, 0x48, 0x0f, 0xc7, 0x0f, // lock cmpxchg16b (%rdi)
    0x75, 0xf2, // jnz retry
    0xff, 0xce, // decl %esi
    0x75, 0xe7, // jnz loop
} ++ syscall;

/// Four threads add 1 a thousand times each with LOCK CMPXCHG16B: none
/// lost.
pub const counter_16b: litmus.Test = .{
    .name = "hx64 LOCK CMPXCHG16B counter",
    .threads = &.{ &counter16b_prog, &counter16b_prog, &counter16b_prog, &counter16b_prog },
    .observe = &.{.{ .mem = 0 }},
    .only = &.{&.{4 * counter_n}},
};

pub const all64 = [_]*const litmus.Test{ &sb64, &sb_xchg64, &sb_lock64, &mp64, &counter_xadd64, &counter_16b };

/// Whether the long-mode lifter takes a region yet (workstream F).
fn longLifts(gpa: std.mem.Allocator) bool {
    var code: [mem.page_size]u8 align(mem.page_size) = @splat(0x90);
    code[1] = 0x0f;
    code[2] = 0x05;
    const regions = [_]mem.Region{.{ .va = 0x1000, .mem = &code, .exec = true }};
    const map: mem.Map = .{ .regions = &regions };
    const backing = check.mapBacking(&map);
    var region = check.liftAt(gpa, &x86.guest64, &backing, 0x1000, .{}) catch return false;
    region.deinit(gpa);
    return true;
}

test "litmus/x86: long mode, nothing forbidden on any tier it runs" {
    const gpa = std.testing.allocator;
    if (!x86.longRuns()) return error.SkipZigTest;
    const lifts = longLifts(gpa);
    for ([_]litmus.Tier{ .t0, .ir_eval, .native }) |tier| {
        if (tier != .t0 and !lifts) continue;
        if (tier == .native and !@import("../emit/native.zig").available()) continue;
        for (all64) |t| {
            var tally = try litmus.run(gpa, &arch64, t, .{ .iterations = 200, .tier = tier });
            defer tally.deinit(gpa);
            if (tally.forbidden != 0) {
                std.debug.print("{s} ({t}): forbidden outcomes\n", .{ t.name, tier });
                return error.Forbidden;
            }
        }
    }
}

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
