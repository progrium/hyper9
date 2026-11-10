//! The arm64 instruction inventory (design/0019-zig-interpreter.md): decodes
//! the text of every arm64 binary under the given paths with ha64's own
//! decoder (src/interp/a64/decode.zig) and reports which micro-ops they
//! use, and every instruction word nothing implements.
//!
//!     zig build a64-inventory -- [--top N] PATH...
//!
//! PATHs are files or directories (searched recursively): 9front a.outs
//! (arm64 magic) and ELF executables and shared objects (EM_AARCH64), such
//! as an Alpine root. Other files are skipped.
//!
//! Text holds data too: literal pools, jump tables, and padding. A linear
//! sweep tells most of it apart: a word is code from the entry, a symbol,
//! or a branch target, until an unconditional branch, a return, or an
//! exception call; the words after are data until the next one of those
//! starts code again. LDR (literal) targets are always data. Only the code
//! words count, and unimplemented ones are listed with their file,
//! address, and nearest symbol (a.out symbol tables, ELF .symtab).

const std = @import("std");
const dec = @import("a64decode");
const aout = @import("aout");

const Kind = dec.Kind;

const Stats = struct {
    files: u32 = 0,
    words: u64 = 0,
    code: u64 = 0,
    data: u64 = 0,
    counts: [dec.nkinds]u64 = @splat(0),
    users: [dec.nkinds]u32 = @splat(0),
    /// Unimplemented code words by pattern (the word with its register
    /// fields masked).
    missing: std.AutoHashMapUnmanaged(u32, Missing) = .empty,
    missing_simd: u64 = 0,
    missing_other: u64 = 0,
};

const Missing = struct {
    count: u64 = 0,
    files: u32 = 0,
    last_file: u32 = std.math.maxInt(u32),
    example: u32,
    where: []const u8,
};

/// Whether `w` is in the groups simd_decode.zig owns: FP and AdvSIMD data
/// processing, and the SIMD structure loads and stores.
fn isSimdGroup(w: u32) bool {
    const op0 = (w >> 25) & 0xf;
    if (op0 & 0b0111 == 0b0111) return true;
    if (op0 & 0b0101 == 0b0100 and (w >> 26) & 1 == 1 and (w >> 28) & 3 == 0) return true;
    return false;
}

/// Masks Rd/Rt (4:0), Rn (9:5), and Rm/Rs (20:16): enough to group the
/// encodings of one instruction form.
fn pattern(w: u32) u32 {
    return w & ~@as(u32, 0x001f03ff);
}

const Text = struct {
    va: u64,
    bytes: []const u8,
};

const Sym = struct { va: u64, name: []const u8 };

const Image = struct {
    texts: std.ArrayList(Text) = .empty,
    entry: u64 = 0,
    syms: std.ArrayList(Sym) = .empty,

    fn nearest(img: *const Image, va: u64) ?Sym {
        var best: ?Sym = null;
        for (img.syms.items) |s| if (s.va <= va and (best == null or s.va > best.?.va)) {
            best = s;
        };
        return best;
    }
};

fn loadAout(gpa: std.mem.Allocator, bytes: []const u8, img: *Image) !bool {
    const h = aout.parse(bytes) catch return false;
    if (h.arch != .arm64) return false;
    const hs = h.arch.headerSize();
    if (hs + @as(usize, h.text) > bytes.len or h.text < hs) return false;
    const base = aout.layout(.arm64).utzero;
    // The header is mapped as the start of text.
    try img.texts.append(gpa, .{ .va = base + hs, .bytes = bytes[hs..h.text] });
    img.entry = h.entry;
    // Symbols: value, type byte | 0x80, NUL-terminated name.
    const start = hs + @as(usize, h.text) + h.data;
    if (start + h.syms <= bytes.len) {
        const tab = bytes[start..][0..h.syms];
        var i: usize = 0;
        while (i + 9 < tab.len) {
            const value = std.mem.readInt(u64, tab[i..][0..8], .big);
            const ty = tab[i + 8] & 0x7f;
            i += 9;
            const ns = i;
            if (ty == 'z' or ty == 'Z') {
                while (i + 1 < tab.len and (tab[i] != 0 or tab[i + 1] != 0)) i += 2;
                i += 2;
                continue;
            }
            while (i < tab.len and tab[i] != 0) i += 1;
            const name = tab[ns..i];
            i += 1;
            if (ty == 'T' or ty == 't' or ty == 'L' or ty == 'l') try img.syms.append(gpa, .{ .va = value, .name = name });
        }
    }
    return true;
}

fn loadElf(gpa: std.mem.Allocator, bytes: []const u8, img: *Image) !bool {
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..4], "\x7fELF") or bytes[4] != 2 or bytes[5] != 1) return false;
    const hdr = std.mem.bytesAsValue(std.elf.Elf64_Ehdr, bytes[0..@sizeOf(std.elf.Elf64_Ehdr)]);
    if (hdr.e_machine != .AARCH64) return false;
    img.entry = hdr.e_entry;
    const shoff: usize = @intCast(hdr.e_shoff);
    const shnum = hdr.e_shnum;
    if (shoff == 0 or shoff + @as(usize, shnum) * @sizeOf(std.elf.Elf64_Shdr) > bytes.len) return false;
    const shdrs = std.mem.bytesAsSlice(std.elf.Elf64_Shdr, bytes[shoff..][0 .. @as(usize, shnum) * @sizeOf(std.elf.Elf64_Shdr)]);
    for (shdrs) |sh| {
        if (sh.sh_type == std.elf.SHT_PROGBITS and sh.sh_flags & std.elf.SHF_EXECINSTR != 0) {
            const off: usize = @intCast(sh.sh_offset);
            const size: usize = @intCast(sh.sh_size);
            if (off + size > bytes.len) continue;
            try img.texts.append(gpa, .{ .va = sh.sh_addr, .bytes = bytes[off..][0 .. size & ~@as(usize, 3)] });
        }
        if (sh.sh_type == std.elf.SHT_SYMTAB or sh.sh_type == std.elf.SHT_DYNSYM) {
            const off: usize = @intCast(sh.sh_offset);
            const size: usize = @intCast(sh.sh_size);
            if (off + size > bytes.len or sh.sh_link >= shnum) continue;
            const strs = shdrs[sh.sh_link];
            const soff: usize = @intCast(strs.sh_offset);
            const ssize: usize = @intCast(strs.sh_size);
            if (soff + ssize > bytes.len) continue;
            const strtab = bytes[soff..][0..ssize];
            const syms = std.mem.bytesAsSlice(std.elf.Elf64_Sym, bytes[off..][0 .. size - size % @sizeOf(std.elf.Elf64_Sym)]);
            for (syms) |s| {
                if (s.st_value == 0 or s.st_name >= strtab.len) continue;
                const name = std.mem.sliceTo(strtab[s.st_name..], 0);
                // Mapping symbols ($x code, $d data) aren't names.
                if (name.len > 0 and name[0] == '$') continue;
                if (s.st_type() == std.elf.STT_FUNC or s.st_type() == std.elf.STT_NOTYPE)
                    try img.syms.append(gpa, .{ .va = s.st_value, .name = name });
            }
        }
    }
    return img.texts.items.len > 0;
}

fn inText(img: *const Image, va: u64) ?struct { t: usize, i: usize } {
    for (img.texts.items, 0..) |t, ti| {
        if (va >= t.va and va - t.va + 4 <= t.bytes.len and (va - t.va) % 4 == 0) return .{ .t = ti, .i = @intCast((va - t.va) / 4) };
    }
    return null;
}

fn word(t: Text, i: usize) u32 {
    return std.mem.readInt(u32, t.bytes[i * 4 ..][0..4], .little);
}

fn scan(gpa: std.mem.Allocator, st: *Stats, file_index: u32, path: []const u8, img: *const Image) !void {
    // Pass 1: starts (entry, symbols, branch targets) and literal targets.
    var starts: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer starts.deinit(gpa);
    var literals: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer literals.deinit(gpa);
    try starts.put(gpa, img.entry, {});
    for (img.syms.items) |s| try starts.put(gpa, s.va, {});
    for (img.texts.items) |t| {
        try starts.put(gpa, t.va, {});
        for (0..t.bytes.len / 4) |i| {
            const va = t.va + i * 4;
            const o = dec.decode(word(t, i), va);
            const r = dec.regs(o);
            switch (r.ctrl) {
                .jump, .cond, .call => try starts.put(gpa, o.imm, {}),
                else => {},
            }
            // The instruction after a call or conditional branch runs.
            if (r.ctrl == .call or r.ctrl == .call_indirect or r.ctrl == .cond) try starts.put(gpa, va + 4, {});
            // ADR targets are code (jump tables' bases are data; their
            // entries are offsets to code we can't follow).
            const info = dec.info(o.k);
            if (info.modes and o.x == 4 and r.mem == .load) {
                try literals.put(gpa, o.imm, {});
                const size: u64 = switch (o.k) {
                    .ldr_x_m, .ldr_vd_m => 8,
                    .ldr_vq_m => 16,
                    else => 4,
                };
                var a: u64 = 4;
                while (a < size) : (a += 4) try literals.put(gpa, o.imm + a, {});
            }
        }
    }
    // Pass 2: the linear sweep.
    var used: [dec.nkinds]bool = @splat(false);
    for (img.texts.items) |t| {
        var live = true;
        for (0..t.bytes.len / 4) |i| {
            const va = t.va + i * 4;
            st.words += 1;
            if (starts.contains(va)) live = true;
            if (!live or literals.contains(va)) {
                st.data += 1;
                continue;
            }
            st.code += 1;
            const w = word(t, i);
            const o = dec.decode(w, va);
            const k = @intFromEnum(o.k);
            if (k < dec.nkinds) {
                st.counts[k] += 1;
                used[k] = true;
            }
            if (o.k == .undef) {
                if (isSimdGroup(w)) st.missing_simd += 1 else st.missing_other += 1;
                const gop = try st.missing.getOrPut(gpa, pattern(w));
                if (!gop.found_existing) {
                    var where: std.Io.Writer.Allocating = .init(gpa);
                    try where.writer.print("{s} 0x{x}", .{ path, va });
                    if (img.nearest(va)) |s| try where.writer.print(" ({s}+0x{x})", .{ s.name, va - s.va });
                    gop.value_ptr.* = .{ .example = w, .where = try where.toOwnedSlice() };
                }
                gop.value_ptr.count += 1;
                if (gop.value_ptr.last_file != file_index) {
                    gop.value_ptr.files += 1;
                    gop.value_ptr.last_file = file_index;
                }
            }
            switch (dec.regs(o).ctrl) {
                .jump, .indirect, .ret, .brk, .undef => live = false,
                else => {},
            }
        }
    }
    for (used, 0..) |u, k| if (u) {
        st.users[k] += 1;
    };
}

fn visit(gpa: std.mem.Allocator, io: std.Io, st: *Stats, dir: std.Io.Dir, path: []const u8) !void {
    const stat = dir.statFile(io, path, .{}) catch return;
    if (stat.kind == .directory) {
        var d = dir.openDir(io, path, .{ .iterate = true }) catch return;
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file and e.kind != .directory) continue;
            const sub = try std.fs.path.join(gpa, &.{ path, e.name });
            try visit(gpa, io, st, dir, sub);
        }
        return;
    }
    if (stat.kind != .file or stat.size < 64 or stat.size > 256 << 20) return;
    const bytes = dir.readFileAlloc(io, path, gpa, .limited(256 << 20)) catch return;
    var img: Image = .{};
    if (!(try loadAout(gpa, bytes, &img)) and !(try loadElf(gpa, bytes, &img))) {
        gpa.free(bytes);
        return;
    }
    st.files += 1;
    try scan(gpa, st, st.files, path, &img);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    var top: usize = 60;
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--top") and i + 1 < args.len) {
            i += 1;
            top = try std.fmt.parseInt(usize, args[i], 10);
        } else try paths.append(gpa, args[i]);
    }
    if (paths.items.len == 0) {
        std.debug.print("usage: a64inv [--top N] PATH...\n", .{});
        std.process.exit(2);
    }
    var st: Stats = .{};
    for (paths.items) |p| try visit(gpa, io, &st, std.Io.Dir.cwd(), p);

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;
    try out.print("# arm64 inventory\n\n{d} binaries, {d} text words: {d} code, {d} data.\n", .{ st.files, st.words, st.code, st.data });
    const unimpl = st.missing_simd + st.missing_other;
    try out.print("Unimplemented code words: {d} ({d:.3}%), {d} of them FP/AdvSIMD (A2's), {d} other.\n\n", .{
        unimpl, if (st.code == 0) 0 else 100 * @as(f64, @floatFromInt(unimpl)) / @as(f64, @floatFromInt(st.code)), st.missing_simd, st.missing_other,
    });

    try out.print("## Micro-ops by count\n\n| kind | count | binaries |\n| --- | ---: | ---: |\n", .{});
    var order: [dec.nkinds]u16 = undefined;
    for (&order, 0..) |*o, k| o.* = @intCast(k);
    std.mem.sort(u16, &order, &st, struct {
        fn gt(s: *Stats, a: u16, b: u16) bool {
            return s.counts[a] > s.counts[b];
        }
    }.gt);
    for (order) |k| {
        if (st.counts[k] == 0) continue;
        try out.print("| {t} | {d} | {d} |\n", .{ @as(Kind, @enumFromInt(k)), st.counts[k], st.users[k] });
    }
    try out.print("\nUnused: ", .{});
    for (0..dec.nkinds) |k| if (st.counts[k] == 0) try out.print("{t} ", .{@as(Kind, @enumFromInt(k))});

    try out.print("\n\n## Unimplemented patterns (registers masked), top {d}\n\n| pattern | group | count | binaries | example | where |\n| --- | --- | ---: | ---: | --- | --- |\n", .{top});
    var ms: std.ArrayList(struct { p: u32, m: Missing }) = .empty;
    var it = st.missing.iterator();
    while (it.next()) |e| try ms.append(gpa, .{ .p = e.key_ptr.*, .m = e.value_ptr.* });
    std.mem.sort(@TypeOf(ms.items[0]), ms.items, {}, struct {
        fn gt(_: void, a: @TypeOf(ms.items[0]), b: @TypeOf(ms.items[0])) bool {
            return a.m.count > b.m.count;
        }
    }.gt);
    for (ms.items[0..@min(top, ms.items.len)]) |e| {
        try out.print("| {x:0>8} | {s} | {d} | {d} | {x:0>8} | {s} |\n", .{ e.p, if (isSimdGroup(e.m.example)) "simd" else "other", e.m.count, e.m.files, e.m.example, e.m.where });
    }
    try out.flush();
}
