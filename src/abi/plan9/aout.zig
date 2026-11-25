//! Plan 9 a.out header parsing (sys/include/a.out.h).

const std = @import("std");

pub const HDR_MAGIC: u32 = 0x00008000;

fn magic(f: u32, b: u32) u32 {
    return f | ((((4 * b) + 0) * b) + 7);
}

pub const I_MAGIC = magic(0, 11); // 386
pub const S_MAGIC = magic(HDR_MAGIC, 26); // amd64
pub const R_MAGIC = magic(HDR_MAGIC, 28); // arm64

pub const Arch = enum {
    arm64,
    amd64,
    i386,

    /// The architecture's 9front name, as in $cputype and /$cputype/bin.
    pub fn name(a: Arch) []const u8 {
        return switch (a) {
            .i386 => "386",
            else => @tagName(a),
        };
    }

    /// Parses a 9front architecture name.
    pub fn fromName(s: []const u8) ?Arch {
        if (std.mem.eql(u8, s, "386")) return .i386;
        if (std.mem.eql(u8, s, "i386")) return null;
        return std.meta.stringToEnum(Arch, s);
    }

    /// Bytes in a user pointer, a syscall argument slot and a stack word.
    pub fn wordSize(a: Arch) u64 {
        return if (a == .i386) 4 else 8;
    }

    /// The a.out header's size: 40 bytes for the 64-bit magics (with
    /// HDR_MAGIC and a 64-bit entry point), 32 for 386.
    pub fn headerSize(a: Arch) usize {
        return if (a == .i386) 32 else 40;
    }
};

pub const Layout = struct {
    utzero: u64,
    ustktop: u64,
    stack_size: u64,
    data_align: u64,
    /// 9front's SEGMAXSIZE: the largest segment segattach makes.
    seg_max: u64,
};

pub fn layout(arch: Arch) Layout {
    return switch (arch) {
        .arm64 => .{ .utzero = 0x10000, .ustktop = 0x7FFFF0000, .stack_size = 16 << 20, .data_align = 64 << 10, .seg_max = 8 << 30 },
        .amd64 => .{ .utzero = 0x200000, .ustktop = 0x7FFFFFFFF000, .stack_size = 16 << 20, .data_align = 2 << 20, .seg_max = 64 << 30 },
        // pc/mem.h: USTKTOP is VMAP-BY2PG, with VMAP at 0xE0000000;
        // SEGMAXSIZE is SEGMAPSIZE (1984) times PTEMAPMEM (1 MiB).
        .i386 => .{ .utzero = 0x1000, .ustktop = 0xDFFFF000, .stack_size = 16 << 20, .data_align = 4 << 10, .seg_max = 1984 << 20 },
    };
}

/// Size of the header for 64-bit magics: eight words plus a 64-bit entry.
/// 386's is 32 bytes (`Arch.headerSize`); this is the largest.
pub const header_size = 40;

pub const Header = struct {
    arch: Arch,
    text: u32,
    data: u32,
    bss: u32,
    syms: u32,
    spsz: u32,
    pcsz: u32,
    entry: u64,
};

pub const ParseError = error{ Truncated, BadMagic };

pub fn parse(bytes: []const u8) ParseError!Header {
    if (bytes.len < 32) return error.Truncated;
    const w = struct {
        fn at(b: []const u8, i: usize) u32 {
            return std.mem.readInt(u32, b[i * 4 ..][0..4], .big);
        }
    }.at;
    const arch: Arch = switch (w(bytes, 0)) {
        R_MAGIC => .arm64,
        S_MAGIC => .amd64,
        I_MAGIC => .i386,
        else => return error.BadMagic,
    };
    if (bytes.len < arch.headerSize()) return error.Truncated;
    return .{
        .arch = arch,
        .text = w(bytes, 1),
        .data = w(bytes, 2),
        .bss = w(bytes, 3),
        .syms = w(bytes, 4),
        .spsz = w(bytes, 6),
        .pcsz = w(bytes, 7),
        .entry = if (arch == .i386) w(bytes, 5) else std.mem.readInt(u64, bytes[32..40], .big),
    };
}

/// Writes an a.out header into the first `h.arch.headerSize()` bytes of
/// `out`. Used by tests and fixture generators.
pub fn writeHeader(out: []u8, h: Header) void {
    const m: u32 = switch (h.arch) {
        .arm64 => R_MAGIC,
        .amd64 => S_MAGIC,
        .i386 => I_MAGIC,
    };
    const words = [8]u32{ m, h.text, h.data, h.bss, h.syms, @truncate(h.entry), h.spsz, h.pcsz };
    for (words, 0..) |v, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], v, .big);
    if (h.arch != .i386) std.mem.writeInt(u64, out[32..40], h.entry, .big);
}

/// Writes the header of a text-only a.out whose entry point is the start of
/// text into the first `arch.headerSize()` bytes of `out`. Used by tests
/// and fixture generators.
pub fn writeTextHeader(out: []u8, arch: Arch, text_len: usize) void {
    writeHeader(out, .{
        .arch = arch,
        .text = @intCast(text_len),
        .data = 0,
        .bss = 0,
        .syms = 0,
        .spsz = 0,
        .pcsz = 0,
        .entry = layout(arch).utzero + arch.headerSize(),
    });
}

pub const Symbol = struct { name: []const u8, value: u64 };

/// The text symbol containing `addr`, from the a.out's symbol table: the
/// `T`, `t`, `L` or `l` symbol with the highest value not above `addr`.
pub fn symbolize(bytes: []const u8, addr: u64) ?Symbol {
    const h = parse(bytes) catch return null;
    const start = h.arch.headerSize() + @as(usize, h.text) + h.data;
    if (start + h.syms > bytes.len) return null;
    const tab = bytes[start..][0..h.syms];
    var best: ?Symbol = null;
    var i: usize = 0;
    // Entries are a big-endian value (64-bit with HDR_MAGIC, 32-bit on
    // 386), a type byte with 0x80 set and a NUL-terminated name; z and Z
    // names are 16-bit pairs ended by 0 0.
    const vsize: usize = if (h.arch == .i386) 4 else 8;
    while (i + vsize + 1 < tab.len) {
        const value: u64 = if (vsize == 4) std.mem.readInt(u32, tab[i..][0..4], .big) else std.mem.readInt(u64, tab[i..][0..8], .big);
        const ty = tab[i + vsize] & 0x7f;
        i += vsize + 1;
        const name_start = i;
        if (ty == 'z' or ty == 'Z') {
            while (i + 1 < tab.len and (tab[i] != 0 or tab[i + 1] != 0)) i += 2;
            i += 2;
            continue;
        }
        while (i < tab.len and tab[i] != 0) i += 1;
        const name = tab[name_start..i];
        i += 1;
        switch (ty) {
            'T', 't', 'L', 'l' => if (value <= addr and (best == null or value > best.?.value)) {
                best = .{ .name = name, .value = value };
            },
            else => {},
        }
    }
    return best;
}

test "symbolize" {
    var buf: [header_size + 4 + 44]u8 = @splat(0);
    writeHeader(buf[0..header_size], .{ .arch = .arm64, .text = 4, .data = 0, .bss = 0, .syms = 44, .spsz = 0, .pcsz = 0, .entry = 0x10028 });
    var p: usize = header_size + 4;
    for ([_]struct { u64, u8, []const u8 }{ .{ 0x10028, 'T', "main" }, .{ 0x10100, 't', "helper" }, .{ 0x20000, 'D', "data" } }) |e| {
        std.mem.writeInt(u64, buf[p..][0..8], e[0], .big);
        buf[p + 8] = e[1] | 0x80;
        @memcpy(buf[p + 9 ..][0..e[2].len], e[2]);
        p += 9 + e[2].len + 1;
    }
    try std.testing.expectEqualStrings("main", symbolize(&buf, 0x10030).?.name);
    try std.testing.expectEqualStrings("helper", symbolize(&buf, 0x10200).?.name);
    try std.testing.expectEqual(@as(?Symbol, null), symbolize(&buf, 0x100));
}

test "magic values" {
    try std.testing.expectEqual(@as(u32, 0x8C47), R_MAGIC);
    try std.testing.expectEqual(@as(u32, 0x8A97), S_MAGIC);
    try std.testing.expectEqual(@as(u32, 0x01EB), I_MAGIC);
}

test "386 header round trip" {
    const h: Header = .{ .arch = .i386, .text = 0x40, .data = 8, .bss = 16, .syms = 0, .spsz = 0, .pcsz = 0, .entry = 0x1020 };
    var buf: [32]u8 = undefined;
    writeHeader(&buf, h);
    try std.testing.expectEqualDeep(h, try parse(&buf));
    try std.testing.expectError(error.Truncated, parse(buf[0..31]));
}

test "symbolize 386" {
    var buf: [32 + 4 + 20]u8 = @splat(0);
    writeHeader(&buf, .{ .arch = .i386, .text = 4, .data = 0, .bss = 0, .syms = 20, .spsz = 0, .pcsz = 0, .entry = 0x1020 });
    var p: usize = 32 + 4;
    for ([_]struct { u32, u8, []const u8 }{ .{ 0x1020, 'T', "main" }, .{ 0x1100, 't', "f" } }) |e| {
        std.mem.writeInt(u32, buf[p..][0..4], e[0], .big);
        buf[p + 4] = e[1] | 0x80;
        @memcpy(buf[p + 5 ..][0..e[2].len], e[2]);
        p += 5 + e[2].len + 1;
    }
    try std.testing.expectEqualStrings("main", symbolize(&buf, 0x1030).?.name);
    try std.testing.expectEqualStrings("f", symbolize(&buf, 0x1100).?.name);
}

test "arch names" {
    try std.testing.expectEqualStrings("386", Arch.i386.name());
    try std.testing.expectEqual(Arch.i386, Arch.fromName("386").?);
    try std.testing.expectEqual(Arch.amd64, Arch.fromName("amd64").?);
    try std.testing.expectEqual(@as(?Arch, null), Arch.fromName("i386"));
}

test "header round trip" {
    const h: Header = .{ .arch = .arm64, .text = 0x40, .data = 8, .bss = 16, .syms = 0, .spsz = 0, .pcsz = 0, .entry = 0x10028 };
    var buf: [header_size]u8 = undefined;
    writeHeader(&buf, h);
    try std.testing.expectEqualDeep(h, try parse(&buf));
}

test "rejects bad input" {
    var buf = @as([header_size]u8, @splat(0));
    try std.testing.expectError(error.BadMagic, parse(&buf));
    try std.testing.expectError(error.Truncated, parse(buf[0..10]));
}
