//! Loads a 9front a.out into an address space, following sysexec in
//! 9front's port/sysproc.c: text, data, and bss as mappings in an Mm
//! (src/kern/mm.zig), filled from the a.out as they're touched, and the
//! stack in an Mm of its own (src/segment.zig, design/memory-model.md).

const std = @import("std");
const aout = @import("aout.zig");
const engine = @import("../../engine.zig");
const segment = @import("../../segment.zig");
const kmm = @import("../../kern/mm.zig");

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
    /// Text, data and bss, and the stack, mapped into the address space.
    space: segment.Space,
};

/// OutOfGuestMemory for pages the machine's --memory hasn't room for.
pub const Error = error{ BadExec, OutOfGuestMemory, OutOfMemory, BadAddress } || aout.ParseError;

fn pageRound(x: u64) u64 {
    return std.mem.alignForward(u64, x, page);
}

/// The a.out's text and initialized data, which its mappings' pages are
/// filled from as they're touched (`kmm.Src`): a copy of those bytes of
/// the file exec read, held while any process maps them. A mapping's
/// offset is the address it's at, so `fill` serves each page from where
/// the a.out puts it: text from the file's start at UTZERO, data from
/// just past the text at the data segment's base, and zeros elsewhere
/// (the end of text's last page, and the bss in data's last).
const AoutSrc = struct {
    src: kmm.Src = .{ .fill = fill, .free = free },
    gpa: std.mem.Allocator,
    bytes: []u8,
    utzero: u64,
    ntext: u64,
    adata: u64,

    fn fill(s: *kmm.Src, dst: []u8, va: u64) usize {
        const a: *AoutSrc = @fieldParentPtr("src", s);
        @memset(dst, 0);
        piece(dst, va, a.utzero, a.bytes[0..@intCast(a.ntext)]);
        piece(dst, va, a.adata, a.bytes[@intCast(a.ntext)..]);
        return dst.len;
    }

    /// Copies the part of `src`, at `base`, that [va, va+dst.len) holds.
    fn piece(dst: []u8, va: u64, base: u64, src: []const u8) void {
        const lo = @max(va, base);
        const hi = @min(va + dst.len, base + src.len);
        if (lo >= hi) return;
        @memcpy(dst[@intCast(lo - va)..@intCast(hi - va)], src[@intCast(lo - base)..@intCast(hi - base)]);
    }

    fn free(s: *kmm.Src) void {
        const a: *AoutSrc = @fieldParentPtr("src", s);
        a.gpa.free(a.bytes);
        a.gpa.destroy(a);
    }
};

/// Where an a.out's segments go, as 9front's sysexec lays them out.
const Layout = struct {
    h: aout.Header,
    l: aout.Layout,
    /// [utzero, text_top) is text, [adata, data_top) the initialized data
    /// and the start of the bss, and [data_top, ebss) the rest of it.
    text_top: u64,
    adata: u64,
    data_top: u64,
    ebss: u64,
    /// The bytes of the file that text covers, its header included.
    file_text: u64,
};

fn layoutOf(bytes: []const u8) (error{BadExec} || aout.ParseError)!Layout {
    const h = try aout.parse(bytes);
    const l = aout.layout(h.arch);
    const hsize = h.arch.headerSize();
    const text_end = l.utzero + hsize + h.text;
    if (h.entry < l.utzero + hsize or h.entry >= text_end) return error.BadExec;
    const file_text = hsize + h.text;
    if (bytes.len < file_text + h.data) return error.BadExec;
    const adata = std.mem.alignForward(u64, text_end, l.data_align);
    const ebss = pageRound(adata + h.data + h.bss);
    if (ebss >= l.ustktop - l.stack_size) return error.BadExec;
    return .{
        .h = h,
        .l = l,
        .text_top = l.utzero + pageRound(file_text),
        .adata = adata,
        .data_top = @min(adata + pageRound(h.data), ebss),
        .ebss = ebss,
        .file_text = file_text,
    };
}

/// The spans the image in `bytes` takes (text, data and bss, and the
/// stack), for exec to keep only the segattach segments clear of them
/// (`inherited`).
pub fn imageSpans(bytes: []const u8) (error{BadExec} || aout.ParseError)![3]segment.Span {
    const y = try layoutOf(bytes);
    return .{
        .{ .lo = y.l.utzero, .hi = y.text_top },
        .{ .lo = y.adata, .hi = y.ebss },
        .{ .lo = y.l.ustktop - y.l.stack_size, .hi = y.l.ustktop },
    };
}

/// Loads `bytes` into `as`, which must have nothing mapped in the way,
/// and sets up the stack with `argv` and a Tos for `pid`. Text and the
/// initialized data are filled from the a.out as they're touched. With
/// `keep` (exec's), the image goes into it, an Mm in `as` holding the
/// segattach segments exec carries over (`inherited`), which is the
/// caller's again on error. On error nothing else is left mapped in `as`.
pub fn load(gpa: std.mem.Allocator, b: engine.Engine, as: engine.AddressSpace, bytes: []const u8, argv: []const []const u8, pid: u32, keep: ?*kmm.Mm) Error!Image {
    return loadIn(gpa, b, as, bytes, argv, pid, keep) catch |e| switch (e) {
        error.NoSpace => error.OutOfGuestMemory,
        else => |x| x,
    };
}

fn loadIn(gpa: std.mem.Allocator, b: engine.Engine, as: engine.AddressSpace, bytes: []const u8, argv: []const []const u8, pid: u32, keep: ?*kmm.Mm) (Error || kmm.Error)!Image {
    const y = try layoutOf(bytes);
    const h = y.h;
    const l = y.l;
    const stack_base = l.ustktop - l.stack_size;

    // The stack's first pages: Tos, then argument strings, then argv[],
    // then argc at SP, with room below for the program to start.
    var nbytes: usize = 0;
    for (argv) |a| nbytes += a.len + 1;
    const w: usize = @intCast(h.arch.wordSize());
    const ssize = tosSize(h.arch) + std.mem.alignForward(usize, nbytes, w) + w * (argv.len + 2);
    if (ssize > l.stack_size / 2) return error.BadExec;
    const stack_len = pageRound(ssize);

    const mm = keep orelse try kmm.Mm.createIn(gpa, b, h.arch, as);
    errdefer if (keep == null) {
        mm.detach(as);
        mm.put();
    };
    const src = try gpa.create(AoutSrc);
    src.* = .{
        .gpa = gpa,
        .bytes = gpa.dupe(u8, bytes[0..@intCast(y.file_text + h.data)]) catch |e| {
            gpa.destroy(src);
            return e;
        },
        .utzero = l.utzero,
        .ntext = y.file_text,
        .adata = y.adata,
    };
    // The mappings hold it from here.
    defer src.src.put();
    const text = segment.Label.of(.text);
    const data = segment.Label.of(.data);
    try mm.insert(.{ .start = l.utzero, .end = y.text_top, .prot = .{ .read = true, .exec = true }, .kind = .file, .offset = l.utzero, .src = &src.src, .label = text });
    errdefer mm.unmap(l.utzero, y.text_top) catch {};
    if (y.data_top > y.adata) try mm.insert(.{ .start = y.adata, .end = y.data_top, .prot = .rw, .kind = .file, .offset = y.adata, .src = &src.src, .label = data });
    errdefer if (y.data_top > y.adata) mm.unmap(y.adata, y.data_top) catch {};
    if (y.ebss > y.data_top) try mm.insert(.{ .start = y.data_top, .end = y.ebss, .prot = .rw, .label = data });
    errdefer if (y.ebss > y.data_top) mm.unmap(y.data_top, y.ebss) catch {};
    mm.brk_start = y.adata;
    mm.brk = y.ebss;

    const st = try kmm.Mm.createIn(gpa, b, h.arch, as);
    errdefer {
        st.detach(as);
        st.put();
    }
    try st.insert(.{ .start = stack_base, .end = l.ustktop, .prot = .rw, .kind = .stack, .label = segment.Label.of(.stack) });
    const top_mem = try gpa.alloc(u8, @intCast(stack_len));
    defer gpa.free(top_mem);
    @memset(top_mem, 0);
    const base = l.ustktop - stack_len;
    const top = buildStack(h.arch, top_mem, base, argv, pid);
    try st.hostWrite(base, top_mem);

    return .{ .arch = h.arch, .entry = h.entry, .sp = top.sp, .tos = top.tos, .space = .{ .mm = mm, .stack = st, .lay = l } };
}

/// For exec: an Mm in `as` holding `old`'s segattach segments but those
/// with SG_CEXEC and any that overlap the new image's `spans`, for `load`
/// to put the image in, or null if there are none to keep. It's a fork
/// of the old Mm with the rest unmapped, so a `shared` segment stays the
/// same pages and a `memory` one is the new image's own copy.
pub fn inherited(old: *const segment.Space, as: engine.AddressSpace, spans: [3]segment.Span) kmm.Error!?*kmm.Mm {
    var buf: [64]kmm.Vma = undefined;
    const keep = for (old.mm.labelled(&buf)) |v| {
        if (inheritable(v, spans)) break true;
    } else false;
    if (!keep) return null;
    const n = try old.mm.forkInto(as);
    errdefer {
        n.detach(as);
        n.put();
    }
    var all: [64]kmm.Vma = undefined;
    for (n.snapshot(&all, false)) |v| if (!inheritable(v, spans)) try n.unmap(v.start, v.end);
    n.brk_start = 0;
    n.brk = 0;
    return n;
}

fn inheritable(v: kmm.Vma, spans: [3]segment.Span) bool {
    const l = segment.Label.get(v) orelse return false;
    const k = l.kindOf();
    if (k != .shared and k != .memory) return false;
    if (l.cexec) return false;
    for (spans) |sp| if (v.start < sp.hi and sp.lo < v.end) return false;
    return true;
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
/// reads it from there). After rfork, the write makes the stack's page
/// the child's own, so the parent's Tos keeps its pid.
pub fn setTosPid(space: *const segment.Space, arch: aout.Arch, tos: u64, pid: u32) void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, pid, .little);
    space.stack.hostWrite(tos + tosPidOffset(arch), &b) catch {};
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
