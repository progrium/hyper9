//! Loads a 9front a.out into an address space, following sysexec in
//! 9front's port/sysproc.c.

const std = @import("std");
const aout = @import("aout.zig");
const engine = @import("../../engine.zig");
const segment = @import("../../segment.zig");

const page = engine.page_size;

/// sys/include/tos.h, with 8-byte pointers (arm64, amd64).
pub const Tos = extern struct {
    prof: extern struct { pp: u64, next: u64, last: u64, first: u64, pid: u32, what: u32 },
    cyclefreq: u64,
    kcycles: i64,
    pcycles: i64,
    pid: u32,
    clock: u32,
};

/// tos.h with 4-byte pointers (386).
pub const Tos32 = extern struct {
    prof: extern struct { pp: u32, next: u32, last: u32, first: u32, pid: u32, what: u32 },
    cyclefreq: u64 align(4),
    kcycles: i64 align(4),
    pcycles: i64 align(4),
    pid: u32,
    clock: u32,
};

fn tosSize(arch: aout.Arch) usize {
    return if (arch == .i386) @sizeOf(Tos32) else @sizeOf(Tos);
}

fn tosPidOffset(arch: aout.Arch) usize {
    return if (arch == .i386) @offsetOf(Tos32, "pid") else @offsetOf(Tos, "pid");
}

pub const Image = struct {
    arch: aout.Arch,
    entry: u64,
    sp: u64,
    tos: u64,
    /// Text, data (data and bss) and stack, attached to the address space.
    segs: segment.Segs,
};

pub const Error = error{BadExec} || aout.ParseError;

fn pageRound(x: u64) u64 {
    return std.mem.alignForward(u64, x, page);
}

/// Loads `bytes` into `as`, which must have no segments in the way, and
/// sets up the stack with `argv` and a Tos for `pid`. On error nothing is
/// left attached to `as`.
pub fn load(gpa: std.mem.Allocator, b: engine.Engine, as: engine.AddressSpace, bytes: []const u8, argv: []const []const u8, pid: u32) !Image {
    const h = try aout.parse(bytes);
    const l = aout.layout(h.arch);

    const hsize = h.arch.headerSize();
    const text_end = l.utzero + hsize + h.text;
    if (h.entry < l.utzero + hsize or h.entry >= text_end) return error.BadExec;
    const file_text = hsize + h.text;
    if (bytes.len < file_text + h.data) return error.BadExec;

    const adata = std.mem.alignForward(u64, text_end, l.data_align);
    const ebss = pageRound(adata + h.data + h.bss);
    const stack_base = l.ustktop - l.stack_size;
    if (ebss >= stack_base) return error.BadExec;

    // The stack's first pages: Tos, then argument strings, then argv[],
    // then argc at SP, with room below for the program to start.
    var nbytes: usize = 0;
    for (argv) |a| nbytes += a.len + 1;
    const w: usize = @intCast(h.arch.wordSize());
    const ssize = tosSize(h.arch) + std.mem.alignForward(usize, nbytes, w) + w * (argv.len + 2);
    if (ssize > l.stack_size / 2) return error.BadExec;
    const stack_len = pageRound(ssize + segment.stack_slack);

    var segs: segment.Segs = .{ .stack_floor = stack_base, .ustktop = l.ustktop, .seg_max = l.seg_max };
    errdefer segs.release(as);

    const text = try segment.Segment.create(gpa, b, .text, .{ .exec = true }, l.utzero, pageRound(file_text));
    @memcpy(text.chunks.items[0].mem[0..file_text], bytes[0..file_text]);
    try text.attach(as);
    segs.text = text;

    const data = try segment.Segment.create(gpa, b, .data, .{ .write = true }, adata, ebss - adata);
    if (h.data > 0) @memcpy(data.chunks.items[0].mem[0..h.data], bytes[file_text..][0..h.data]);
    try data.attach(as);
    segs.data = data;

    const stack = try segment.Segment.create(gpa, b, .stack, .{ .write = true }, l.ustktop - stack_len, stack_len);
    const top = buildStack(h.arch, stack.chunks.items[0].mem, stack.base, argv, pid);
    try stack.attach(as);
    segs.stack = stack;

    return .{ .arch = h.arch, .entry = h.entry, .sp = top.sp, .tos = top.tos, .segs = segs };
}

/// Lays out Tos, the argument strings, argv[] and argc at the top of
/// `stack`, which is mapped at `base`, in `arch`'s word size. Returns the
/// SP and the Tos address.
fn buildStack(arch: aout.Arch, stack: []u8, base: u64, argv: []const []const u8, pid: u32) struct { sp: u64, tos: u64 } {
    const top = stack.len;
    const tos_off = top - tosSize(arch);
    @memset(stack[tos_off..top], 0);
    std.mem.writeInt(u32, stack[tos_off + tosPidOffset(arch) ..][0..4], pid, .little);

    var strs = tos_off;
    for (argv) |a| strs -= a.len + 1;
    const strs_start = strs;
    const nbytes = tos_off - strs_start;

    const w: usize = @intCast(arch.wordSize());
    const ssize = w * (argv.len + 1) + std.mem.alignForward(usize, nbytes, w);
    const argv_off = tos_off - ssize;
    var p = strs_start;
    for (argv, 0..) |a, i| {
        @memcpy(stack[p..][0..a.len], a);
        stack[p + a.len] = 0;
        writeWord(stack[argv_off + w * i ..], w, base + p);
        p += a.len + 1;
    }
    writeWord(stack[argv_off + w * argv.len ..], w, 0);
    const argc_off = argv_off - w;
    writeWord(stack[argc_off..], w, argv.len);
    return .{ .sp = base + argc_off, .tos = base + tos_off };
}

fn writeWord(b: []u8, w: usize, v: u64) void {
    if (w == 4) std.mem.writeInt(u32, b[0..4], @intCast(v), .little) else std.mem.writeInt(u64, b[0..8], v, .little);
}

/// Sets the pid in a process's Tos, as fork and exec must (libc's getpid
/// reads it from there).
pub fn setTosPid(as: engine.AddressSpace, arch: aout.Arch, tos: u64, pid: u32) void {
    const b = as.translate(tos + tosPidOffset(arch), 4) orelse return;
    std.mem.writeInt(u32, b[0..4], pid, .little);
}

test "Tos layout matches tos.h" {
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Tos));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Tos, "cyclefreq"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(Tos, "pid"));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Tos32));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Tos32, "cyclefreq"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(Tos32, "pid"));
}

test "386 stack: 4-byte argv and argc under Tos" {
    var stack: [256]u8 align(8) = @splat(0xaa);
    const base: u64 = 0xdffff000 - 256;
    const r = buildStack(.i386, &stack, base, &.{ "echo", "hi" }, 7);
    try std.testing.expectEqual(base + 256 - 56, r.tos);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, stack[256 - 56 + 48 ..][0..4], .little));
    const sp: usize = @intCast(r.sp - base);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, stack[sp..][0..4], .little));
    const a0: usize = @intCast(std.mem.readInt(u32, stack[sp + 4 ..][0..4], .little) - base);
    try std.testing.expectEqualStrings("echo", std.mem.sliceTo(stack[a0..], 0));
    const a1: usize = @intCast(std.mem.readInt(u32, stack[sp + 8 ..][0..4], .little) - base);
    try std.testing.expectEqualStrings("hi", std.mem.sliceTo(stack[a1..], 0));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, stack[sp + 12 ..][0..4], .little));
}
