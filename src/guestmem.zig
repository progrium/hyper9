//! Guest memory as the kernel sees it (DESIGN.md, seam rule 7). drawterm's
//! validaddr is a no-op, so these checks are the only thing between a guest
//! pointer and host memory.

const std = @import("std");
const vmm = @import("vmm.zig");

pub const Error = error{BadAddress};

/// drawterm's `long` is 32 bits, so one kernel call moves less than 2 GiB.
pub const max_chunk: usize = 1 << 30;

/// Calls `f(ctx, piece)` for each host slice backing guest [va, va+len), in
/// order, each within one mapping and at most `max_chunk` long. Stops early
/// when `f` returns fewer bytes than it was given (a short read or write) and
/// returns the total. Any unmapped byte in the range is `BadAddress`, checked
/// before `f` sees anything.
pub fn each(as: vmm.AddressSpace, va: u64, len: u64, ctx: anytype, comptime f: anytype) !usize {
    if (len == 0) return 0;
    if (va +% len < va) return error.BadAddress;
    // Validate the whole range first, so a bad tail fails before any I/O.
    var off: u64 = 0;
    while (off < len) {
        const piece = spanAt(as, va + off, len - off) orelse return error.BadAddress;
        off += piece.len;
    }
    var total: usize = 0;
    off = 0;
    while (off < len) {
        // Checked above, but a Linux thread's remap can unmap the range
        // for a moment since: fail, don't trust the first look.
        const piece = spanAt(as, va + off, len - off) orelse return error.BadAddress;
        var p: usize = 0;
        while (p < piece.len) {
            const chunk = piece[p..][0..@min(piece.len - p, max_chunk)];
            const n = try f(ctx, chunk);
            total += n;
            if (n < chunk.len) return total;
            p += chunk.len;
        }
        off += piece.len;
    }
    return total;
}

/// The host slice backing all of guest [va, va+len), or null if it isn't
/// one contiguous run of host memory (or isn't mapped).
pub fn contiguous(as: vmm.AddressSpace, va: u64, len: u64) ?[]u8 {
    if (va +% len < va) return null;
    const s = spanAt(as, va, len) orelse return null;
    return if (s.len == len) s else null;
}

/// Copies guest [va, va+dst.len) into `dst`.
pub fn read(as: vmm.AddressSpace, va: u64, dst: []u8) Error!void {
    var d = dst;
    _ = each(as, va, dst.len, &d, struct {
        fn f(x: *[]u8, src: []u8) Error!usize {
            @memcpy(x.*[0..src.len], src);
            x.* = x.*[src.len..];
            return src.len;
        }
    }.f) catch return error.BadAddress;
}

/// The longest host slice starting at guest `va`, up to `len` bytes, that
/// is contiguous on the host. It grows a page at a time and stops where the
/// next page isn't mapped or isn't adjacent in host memory.
fn spanAt(as: vmm.AddressSpace, va: u64, len: u64) ?[]u8 {
    if (as.translate(va, len)) |s| return s;
    const first = @min(len, vmm.page_size - va % vmm.page_size);
    const head = as.translate(va, first) orelse return null;
    var n: u64 = first;
    while (n < len) {
        const step = @min(len - n, vmm.page_size);
        const next = as.translate(va + n, step) orelse break;
        if (next.ptr != head.ptr + @as(usize, @intCast(n))) break;
        n += step;
    }
    return head.ptr[0..@intCast(n)];
}

/// Copies a NUL-terminated guest string into `buf`. Fails with BadAddress
/// if it's unmapped before the NUL, or doesn't fit (the kernel's own limit
/// for names is far below any sane `buf`).
pub fn string(as: vmm.AddressSpace, va: u64, buf: []u8) Error![:0]u8 {
    var i: usize = 0;
    while (i < buf.len) {
        const avail = @min(buf.len - i, vmm.page_size - (va + i) % vmm.page_size);
        const src = as.translate(va + i, avail) orelse return error.BadAddress;
        if (std.mem.indexOfScalar(u8, src, 0)) |z| {
            @memcpy(buf[i..][0..z], src[0..z]);
            buf[i + z] = 0;
            return buf[0 .. i + z :0];
        }
        if (i + src.len >= buf.len) return error.BadAddress;
        @memcpy(buf[i..][0..src.len], src);
        i += src.len;
    }
    return error.BadAddress;
}

/// Copies a NUL-terminated guest string of any length up to `max` bytes
/// into new memory. Fails with BadAddress if it's unmapped before the NUL
/// or longer than `max`.
pub fn stringAlloc(as: vmm.AddressSpace, va: u64, gpa: std.mem.Allocator, max: usize) (Error || std.mem.Allocator.Error)![:0]u8 {
    var n: usize = 0;
    while (true) {
        const avail = vmm.page_size - (va +% n) % vmm.page_size;
        const src = as.translate(va +% n, avail) orelse return error.BadAddress;
        if (std.mem.indexOfScalar(u8, src, 0)) |z| {
            n += z;
            break;
        }
        n += src.len;
        if (n > max) return error.BadAddress;
    }
    if (n > max) return error.BadAddress;
    const out = try gpa.allocSentinel(u8, n, 0);
    errdefer gpa.free(out);
    // Another thread sharing the memory may change it meanwhile; the copy
    // is still NUL-terminated.
    try read(as, va, out[0..n]);
    return out;
}

/// Copies `data` out to guest memory at `va`.
pub fn write(as: vmm.AddressSpace, va: u64, data: []const u8) Error!void {
    var src = data;
    _ = each(as, va, data.len, &src, struct {
        fn f(s: *[]const u8, dst: []u8) Error!usize {
            @memcpy(dst, s.*[0..dst.len]);
            s.* = s.*[dst.len..];
            return dst.len;
        }
    }.f) catch return error.BadAddress;
}

/// Reads a little-endian word of `size` bytes (4 or 8) from guest memory,
/// zero-extended: a pointer or a syscall argument slot.
pub fn readWord(as: vmm.AddressSpace, va: u64, size: u64) Error!u64 {
    if (size == 4) {
        var b: [4]u8 = undefined;
        try read(as, va, &b);
        return std.mem.readInt(u32, &b, .little);
    }
    return readU64(as, va);
}

/// Reads a little-endian u64 from guest memory.
pub fn readU64(as: vmm.AddressSpace, va: u64) Error!u64 {
    var b: [8]u8 = undefined;
    try read(as, va, &b);
    return std.mem.readInt(u64, &b, .little);
}

const testing = std.testing;

/// A fake address space over two separate host buffers mapped at adjacent
/// guest pages, so ranges that cross the boundary aren't contiguous on the
/// host.
const Fake = struct {
    a: [vmm.page_size]u8 align(vmm.page_size) = @splat(0),
    gap: [vmm.page_size]u8 align(vmm.page_size) = undefined,
    b: [vmm.page_size]u8 align(vmm.page_size) = @splat(0),
    const base: u64 = 0x10000;

    fn translate(f: *Fake, va: u64, len: u64) ?[]u8 {
        if (va >= base and va + len <= base + vmm.page_size) return f.a[va - base ..][0..len];
        const b0 = base + vmm.page_size;
        if (va >= b0 and va + len <= b0 + vmm.page_size) return f.b[va - b0 ..][0..len];
        return null;
    }
};

fn fakeSpace(f: *Fake) vmm.AddressSpace {
    return vmm.AddressSpace.initFake(f, Fake.translate);
}

test "string copies across a mapping boundary and rejects unterminated" {
    var f: Fake = .{};
    const as = fakeSpace(&f);
    @memcpy(f.a[vmm.page_size - 3 ..], "abc");
    @memcpy(f.b[0..3], "de\x00");
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("abcde", try string(as, Fake.base + vmm.page_size - 3, &buf));
    try testing.expectError(error.BadAddress, string(as, Fake.base + vmm.page_size - 3, buf[0..4]));
    @memset(&f.b, 'x');
    try testing.expectError(error.BadAddress, string(as, Fake.base + vmm.page_size - 3, &buf));
    try testing.expectError(error.BadAddress, string(as, 0x1000, &buf));
}

test "each splits at mapping boundaries and checks the whole range first" {
    var f: Fake = .{};
    const as = fakeSpace(&f);
    const Ctx = struct {
        calls: usize = 0,
        total: usize = 0,
        fn cb(c: *@This(), s: []u8) Error!usize {
            c.calls += 1;
            c.total += s.len;
            return s.len;
        }
    };
    var c: Ctx = .{};
    try testing.expectEqual(@as(usize, 20), try each(as, Fake.base + vmm.page_size - 10, 20, &c, Ctx.cb));
    try testing.expectEqual(@as(usize, 2), c.calls);
    // The range runs off the end of the second page: nothing is touched.
    c = .{};
    try testing.expectError(error.BadAddress, each(as, Fake.base + 2 * vmm.page_size - 4, 8, &c, Ctx.cb));
    try testing.expectEqual(@as(usize, 0), c.calls);
    try testing.expectError(error.BadAddress, each(as, std.math.maxInt(u64) - 2, 8, &c, Ctx.cb));
}

test "contiguous only covers one host run" {
    var f: Fake = .{};
    const as = fakeSpace(&f);
    try testing.expectEqual(@as(usize, 16), contiguous(as, Fake.base, 16).?.len);
    try testing.expect(contiguous(as, Fake.base + vmm.page_size - 4, 8) == null);
    try testing.expect(contiguous(as, 0x1000, 8) == null);
}

test "write and readU64 across the boundary" {
    var f: Fake = .{};
    const as = fakeSpace(&f);
    const va = Fake.base + vmm.page_size - 4;
    try write(as, va, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try testing.expectEqual(@as(u64, 0x0807060504030201), try readU64(as, va));
}
