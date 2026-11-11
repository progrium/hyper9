//! The 386 instruction inventory (design/zig-interpreter.md, and the
//! 386 plan's first step): finds the code in every 386 binary under the
//! given paths, decodes it with h86's decoder (src/interp/x86/decode.zig),
//! and reports what it uses and what T0 can't run.
//!
//!     zig build x86-inventory -- [--top N] PATH...
//!
//! PATHs are files or directories (searched recursively): 9front 386
//! a.outs and ELF32 executables and shared objects (EM_386), such as an
//! Alpine x86 root or Go's linux/386 programs. Other files are skipped.
//!
//! x86 code can't be swept linearly (it's variable length, and text holds
//! jump tables and padding), so the code is what a recursive descent
//! reaches: from the entry, every function symbol (ELF .symtab and
//! .dynsym, a.out T and t), and the start of each PLT, following direct
//! jumps, branches, and calls, and the instruction after each call or
//! conditional branch. Code reached only through indirect jumps (switch
//! tables) and functions without symbols in stripped binaries are missed.
//!
//! An instruction T0 can't run is one whose x87 or SSE form, or table
//! entry, raises #UD: each distinct x87, SSE, and #UD encoding runs once,
//! with T0's exec.step, in a scratch CPU and memory.

const std = @import("std");
const hcpu = @import("hcpu");
const aout = @import("aout");
const x86 = hcpu.x86;
const dec = x86.decode;
const table = x86.table;
const Cpu = x86.cpu.Cpu;
const Op = table.Op;

const nops = @typeInfo(Op).@"enum".fields.len;

const Text = struct { va: u32, bytes: []const u8 };
const Sym = struct { va: u32, name: []const u8 };

const Image = struct {
    texts: std.ArrayList(Text) = .empty,
    seeds: std.ArrayList(u32) = .empty,
    syms: std.ArrayList(Sym) = .empty,

    fn nearest(img: *const Image, va: u32) ?Sym {
        var best: ?Sym = null;
        for (img.syms.items) |s| if (s.va <= va and (best == null or s.va > best.?.va)) {
            best = s;
        };
        return best;
    }

    /// The bytes from `va` to the end of its text, at most 15.
    fn at(img: *const Image, va: u32) ?[]const u8 {
        for (img.texts.items) |t| {
            if (va >= t.va and va - t.va < t.bytes.len) {
                const off = va - t.va;
                return t.bytes[off..@min(t.bytes.len, off + dec.max_len)];
            }
        }
        return null;
    }
};

fn loadAout(gpa: std.mem.Allocator, bytes: []const u8, img: *Image) !bool {
    const h = aout.parse(bytes) catch return false;
    if (h.arch != .i386) return false;
    const hs = h.arch.headerSize();
    if (@as(usize, h.text) > bytes.len or h.text < hs) return false;
    // The header is the start of text, at UTZERO.
    const base: u32 = @intCast(aout.layout(.i386).utzero);
    try img.texts.append(gpa, .{ .va = base + @as(u32, @intCast(hs)), .bytes = bytes[hs..h.text] });
    try img.seeds.append(gpa, @intCast(h.entry));
    // Symbols: a big-endian value, the type byte | 0x80, and a name.
    const start = @as(usize, h.text) + h.data;
    if (start + h.syms <= bytes.len) {
        const tab = bytes[start..][0..h.syms];
        var i: usize = 0;
        while (i + 5 < tab.len) {
            const value = std.mem.readInt(u32, tab[i..][0..4], .big);
            const ty = tab[i + 4] & 0x7f;
            i += 5;
            const ns = i;
            if (ty == 'z' or ty == 'Z') {
                while (i + 1 < tab.len and (tab[i] != 0 or tab[i + 1] != 0)) i += 2;
                i += 2;
                continue;
            }
            while (i < tab.len and tab[i] != 0) i += 1;
            const name = tab[ns..i];
            i += 1;
            if (ty == 'T' or ty == 't') {
                try img.syms.append(gpa, .{ .va = value, .name = name });
                try img.seeds.append(gpa, value);
            }
        }
    }
    return true;
}

fn loadElf(gpa: std.mem.Allocator, bytes: []const u8, img: *Image) !bool {
    const E = std.elf;
    if (bytes.len < @sizeOf(E.Elf32_Ehdr) or !std.mem.eql(u8, bytes[0..4], "\x7fELF") or bytes[4] != 1 or bytes[5] != 1) return false;
    const hdr = std.mem.bytesAsValue(E.Elf32_Ehdr, bytes[0..@sizeOf(E.Elf32_Ehdr)]);
    if (hdr.e_machine != .@"386") return false;
    if (hdr.e_entry != 0) try img.seeds.append(gpa, hdr.e_entry);
    const shoff: usize = hdr.e_shoff;
    const shnum = hdr.e_shnum;
    if (shoff == 0 or shoff + @as(usize, shnum) * @sizeOf(E.Elf32_Shdr) > bytes.len) return false;
    const shdrs = std.mem.bytesAsSlice(E.Elf32_Shdr, bytes[shoff..][0 .. @as(usize, shnum) * @sizeOf(E.Elf32_Shdr)]);
    const shstr: ?[]const u8 = if (hdr.e_shstrndx < shnum) blk: {
        const s = shdrs[hdr.e_shstrndx];
        if (@as(usize, s.sh_offset) + s.sh_size > bytes.len) break :blk null;
        break :blk bytes[s.sh_offset..][0..s.sh_size];
    } else null;
    for (shdrs) |sh| {
        if (sh.sh_type == E.SHT_PROGBITS and sh.sh_flags & E.SHF_EXECINSTR != 0) {
            const off: usize = sh.sh_offset;
            const size: usize = sh.sh_size;
            if (off + size > bytes.len) continue;
            try img.texts.append(gpa, .{ .va = sh.sh_addr, .bytes = bytes[off..][0..size] });
            // .init, .fini, and the PLTs start with code.
            const name = if (shstr) |t| (if (sh.sh_name < t.len) std.mem.sliceTo(t[sh.sh_name..], 0) else "") else "";
            if (std.mem.startsWith(u8, name, ".plt") or std.mem.eql(u8, name, ".init") or std.mem.eql(u8, name, ".fini"))
                try img.seeds.append(gpa, sh.sh_addr);
            // A PLT's entries are 16 bytes each.
            if (std.mem.startsWith(u8, name, ".plt")) {
                var a: u32 = 16;
                while (a < size) : (a += 16) try img.seeds.append(gpa, sh.sh_addr + a);
            }
        }
        if (sh.sh_type == E.SHT_SYMTAB or sh.sh_type == E.SHT_DYNSYM) {
            const off: usize = sh.sh_offset;
            const size: usize = sh.sh_size;
            if (off + size > bytes.len or sh.sh_link >= shnum) continue;
            const strs = shdrs[sh.sh_link];
            if (@as(usize, strs.sh_offset) + strs.sh_size > bytes.len) continue;
            const strtab = bytes[strs.sh_offset..][0..strs.sh_size];
            const syms = std.mem.bytesAsSlice(E.Elf32_Sym, bytes[off..][0 .. size - size % @sizeOf(E.Elf32_Sym)]);
            for (syms) |s| {
                if (s.st_value == 0 or s.st_name >= strtab.len or s.st_shndx == 0) continue;
                if (s.st_type() != E.STT_FUNC) continue;
                try img.syms.append(gpa, .{ .va = s.st_value, .name = std.mem.sliceTo(strtab[s.st_name..], 0) });
                try img.seeds.append(gpa, s.st_value);
            }
        }
    }
    return img.texts.items.len > 0;
}

// ---------------------------------------------------------------- T0 check

const code_va: u32 = 0x4000_0000;
const data_va: u32 = 0x5000_0000;
const data_len = 1 << 16;

const Mem = struct {
    code: *[4096]u8,
    data: *[data_len]u8,

    pub fn translate(m: *Mem, va: u32, access: x86.cpu.Access) ?[*]u8 {
        if (va >= code_va and va < code_va + 4096) return if (access == .write) null else @ptrCast(&m.code[va - code_va]);
        if (va >= data_va and va < data_va + data_len) return if (access == .exec) null else @ptrCast(&m.data[va - data_va]);
        return null;
    }
};

var scratch_code: [4096]u8 align(4096) = undefined;
var scratch_data: [data_len]u8 align(4096) = undefined;

/// Whether T0 raises #UD for these bytes, with every register pointing
/// into a scratch window, so that memory operands mostly resolve.
fn t0Ud(bytes: []const u8) bool {
    @memset(&scratch_code, 0x90);
    @memcpy(scratch_code[0..bytes.len], bytes);
    @memset(&scratch_data, 0);
    var m: Mem = .{ .code = &scratch_code, .data = &scratch_data };
    var c: Cpu = .{};
    for (&c.r) |*r| r.* = data_va + data_len / 2;
    c.eip = code_va;
    const exit = x86.exec.step(&c, &m) orelse return false;
    return switch (exit) {
        .exception => |v| v == x86.cpu.vec_ud,
        else => false,
    };
}

// ---------------------------------------------------------------- stats

const Count = struct {
    count: u64 = 0,
    files: u32 = 0,
    last_file: u32 = std.math.maxInt(u32),
    where: []const u8 = "",

    fn add(c: *Count, file: u32) void {
        c.count += 1;
        if (c.last_file != file) {
            c.files += 1;
            c.last_file = file;
        }
    }
};

/// A form's key: its name, up to 23 bytes.
const Key = [24]u8;

const Table = std.AutoHashMapUnmanaged(Key, Count);

const Stats = struct {
    files: u32 = 0,
    insts: u64 = 0,
    bytes: u64 = 0,
    undecodable: u64 = 0,
    ops: [nops]Count = @splat(.{}),
    x87: Table = .empty,
    sse: Table = .empty,
    /// #UD in T0, by form.
    missing: Table = .empty,
    /// 66-prefixed integer instructions (16-bit operands), by op.
    op16: [nops]Count = @splat(.{}),
    addr16: Count = .{},
    fs_gs: Count = .{},
    lock: Count = .{},
    rep: Count = .{},
    mmx: Count = .{},
    /// Distinct encodings already run through T0.
    ud_cache: std.AutoHashMapUnmanaged([16]u8, bool) = .empty,
};

fn keyOf(comptime fmt: []const u8, args: anytype) Key {
    var k: Key = @splat(0);
    _ = std.fmt.bufPrint(&k, fmt, args) catch {};
    return k;
}

fn keyStr(k: *const Key) []const u8 {
    return std.mem.sliceTo(k, 0);
}

/// The x87 form: the opcode with /r for memory, or the register form with
/// ST(i)'s field folded (+i) but for the fixed ones.
fn x87Key(i: *const dec.Inst) Key {
    const op: u8 = @truncate(i.opcode);
    if (i.mem) return keyOf("{X:0>2} /{d} m", .{ op, i.reg() });
    const fixed = (op == 0xd9 and i.modrm >= 0xd0 and i.modrm != 0xd8 and (i.modrm < 0xc8 or i.modrm >= 0xd0)) or
        (op == 0xda and i.modrm == 0xe9) or (op == 0xdb and i.modrm >= 0xe0 and i.modrm < 0xe8) or
        (op == 0xde and i.modrm == 0xd9) or (op == 0xdf and i.modrm >= 0xe0 and i.modrm < 0xe8);
    if (fixed) return keyOf("{X:0>2} {X:0>2}", .{ op, i.modrm });
    return keyOf("{X:0>2} {X:0>2}+i", .{ op, i.modrm & 0xf8 });
}

fn pfxName(i: *const dec.Inst) []const u8 {
    return switch (i.rep) {
        .rep => "F3 ",
        .repne => "F2 ",
        .none => if (i.opsize) "66 " else "",
    };
}

/// The SSE form: mandatory prefix, opcode, /r for the groups, and m or r.
fn sseKey(i: *const dec.Inst) Key {
    const op: u8 = @truncate(i.opcode);
    const group = op == 0x71 or op == 0x72 or op == 0x73 or op == 0xae or op == 0x18;
    const mr: []const u8 = if (op == 0x77) "" else if (i.mem) " m" else " r";
    if (group) return keyOf("{s}0F {X:0>2} /{d}{s}", .{ pfxName(i), op, i.reg(), mr });
    return keyOf("{s}0F {X:0>2}{s}", .{ pfxName(i), op, mr });
}

/// MMX: a no-prefix 0F 6x/7x/Dx-Fx integer form, or a conversion to or
/// from an MMX register (0F 2A, 2C, 2D without F3 or F2), but not the
/// SSE moves among them.
fn isMmx(i: *const dec.Inst) bool {
    const op: u8 = @truncate(i.opcode);
    if (i.op != .sse) return false;
    if (i.rep == .none and (op == 0x2a or op == 0x2c or op == 0x2d)) return true;
    if (i.opsize or i.rep != .none) return false;
    return (op >= 0x60 and op <= 0x7f) or op >= 0xd0 or op == 0xc4 or op == 0xc5;
}

fn isInteger(op: Op) bool {
    return switch (op) {
        .x87, .sse, .fwait, .ud, .gp, .nop, .jcc, .jmp, .call, .ret, .loop, .loope, .loopne, .jcxz => false,
        else => true,
    };
}

fn record(gpa: std.mem.Allocator, t: *Table, k: Key, file: u32, path: []const u8, img: *const Image, va: u32) !void {
    const gop = try t.getOrPut(gpa, k);
    if (!gop.found_existing) {
        var where: std.Io.Writer.Allocating = .init(gpa);
        try where.writer.print("{s} 0x{x}", .{ path, va });
        if (img.nearest(va)) |s| try where.writer.print(" ({s}+0x{x})", .{ s.name, va - s.va });
        gop.value_ptr.* = .{ .where = try where.toOwnedSlice() };
    }
    gop.value_ptr.add(file);
}

fn scan(gpa: std.mem.Allocator, st: *Stats, file: u32, path: []const u8, img: *const Image) !void {
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(gpa);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(gpa);
    try work.appendSlice(gpa, img.seeds.items);
    while (work.pop()) |start| {
        var va = start;
        while (true) {
            if ((try seen.getOrPut(gpa, va)).found_existing) break;
            const bytes = img.at(va) orelse break;
            const i = dec.decode(bytes) catch {
                st.undecodable += 1;
                break;
            };
            st.insts += 1;
            st.bytes += i.len;
            const k = @intFromEnum(i.op);
            st.ops[k].add(file);
            if (i.opsize and isInteger(i.op)) st.op16[k].add(file);
            if (i.addr16) st.addr16.add(file);
            if (i.mem and (i.seg == .fs or i.seg == .gs)) st.fs_gs.add(file);
            if (i.lock) st.lock.add(file);
            if (i.rep != .none and i.op != .sse) st.rep.add(file);
            if (isMmx(&i)) st.mmx.add(file);
            switch (i.op) {
                .x87 => try record(gpa, &st.x87, x87Key(&i), file, path, img, va),
                .sse => try record(gpa, &st.sse, sseKey(&i), file, path, img, va),
                else => {},
            }
            if (i.op == .x87 or i.op == .sse or i.op == .ud) {
                var b16: [16]u8 = @splat(0);
                @memcpy(b16[0..i.len], bytes[0..i.len]);
                b16[15] = i.len;
                const gop = try st.ud_cache.getOrPut(gpa, b16);
                if (!gop.found_existing) gop.value_ptr.* = t0Ud(bytes[0..i.len]);
                if (gop.value_ptr.*) {
                    const key = switch (i.op) {
                        .x87 => x87Key(&i),
                        .sse => sseKey(&i),
                        else => switch (i.opcode) {
                            0x0f0b => keyOf("0F 0B (UD2)", .{}),
                            0x0f38, 0x0f3a => keyOf("{s}0F {X:0>2} (SSSE3+)", .{ pfxName(&i), i.opcode & 0xff }),
                            0xc4, 0xc5 => keyOf("{X:0>2} mod 3 (VEX)", .{i.opcode}),
                            else => keyOf("{s}{X:0>4} ud", .{ pfxName(&i), i.opcode }),
                        },
                    };
                    try record(gpa, &st.missing, key, file, path, img, va);
                }
            }
            const next = va +% i.len;
            const target = next +% i.imm;
            switch (i.op) {
                .jcc, .loop, .loope, .loopne, .jcxz => {
                    try work.append(gpa, target);
                },
                .call => try work.append(gpa, target),
                .jmp => {
                    // JMP rel, not a far JMP ptr16:32 (which is .gp).
                    try work.append(gpa, target);
                    break;
                },
                .jmp_ind, .ret, .ud, .int3 => break,
                // HLT and the like: #GP at ring 3, and nothing after.
                .gp => break,
                else => {},
            }
            va = next;
        }
    }
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

const Row = struct { k: Key, c: Count };

fn sorted(gpa: std.mem.Allocator, t: *const Table) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    var it = t.iterator();
    while (it.next()) |e| try rows.append(gpa, .{ .k = e.key_ptr.*, .c = e.value_ptr.* });
    std.mem.sort(Row, rows.items, {}, struct {
        fn gt(_: void, a: Row, b: Row) bool {
            return a.c.count > b.c.count;
        }
    }.gt);
    return rows.items;
}

fn total(t: *const Table) u64 {
    var n: u64 = 0;
    var it = t.valueIterator();
    while (it.next()) |c| n += c.count;
    return n;
}

fn pct(n: u64, d: u64) f64 {
    return if (d == 0) 0 else 100 * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    var top: usize = 40;
    var paths: std.ArrayList([]const u8) = .empty;
    var a: usize = 1;
    while (a < args.len) : (a += 1) {
        if (std.mem.eql(u8, args[a], "--top") and a + 1 < args.len) {
            a += 1;
            top = try std.fmt.parseInt(usize, args[a], 10);
        } else try paths.append(gpa, args[a]);
    }
    if (paths.items.len == 0) {
        std.debug.print("usage: x86inv [--top N] PATH...\n", .{});
        std.process.exit(2);
    }
    var st: Stats = .{};
    for (paths.items) |p| try visit(gpa, io, &st, std.Io.Dir.cwd(), p);

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;
    const n = st.insts;
    try out.print("# 386 inventory\n\nPaths: ", .{});
    for (paths.items) |p| try out.print("{s} ", .{p});
    try out.print("\n\n{d} binaries; {d} instructions reached ({d} bytes); {d} stops at bytes h86 can't decode.\n\n", .{ st.files, n, st.bytes, st.undecodable });
    const nmiss = total(&st.missing);
    try out.print("T0 raises #UD for {d} of them ({d:.4}%), in {d} forms. UD2 is meant to; SSSE3 and later (0F 38, 0F 3A) and VEX (C4 and C5 with mod 3) are past what h86's CPUID reports, so programs that check it don't run them.\n\n", .{ nmiss, pct(nmiss, n), st.missing.count() });

    try out.print("## Features\n\n| feature | instructions | % | binaries |\n| --- | ---: | ---: | ---: |\n", .{});
    const feats = [_]struct { []const u8, Count }{
        .{ "x87", st.ops[@intFromEnum(Op.x87)] },
        .{ "SSE/SSE2 (incl. MMX)", st.ops[@intFromEnum(Op.sse)] },
        .{ "MMX", st.mmx },
        .{ "FWAIT", st.ops[@intFromEnum(Op.fwait)] },
        .{ "16-bit addressing (67)", st.addr16 },
        .{ "FS or GS memory operand", st.fs_gs },
        .{ "LOCK", st.lock },
        .{ "REP/REPNE strings", st.rep },
    };
    for (feats) |f| try out.print("| {s} | {d} | {d:.3} | {d} |\n", .{ f[0], f[1].count, pct(f[1].count, n), f[1].files });
    var c16: u64 = 0;
    for (st.op16) |c| c16 += c.count;
    try out.print("| 16-bit operands (66, integer) | {d} | {d:.3} | |\n", .{ c16, pct(c16, n) });

    try out.print("\n## Unimplemented in T0 (#UD), top {d}\n\n| form | count | binaries | where |\n| --- | ---: | ---: | --- |\n", .{top});
    const ms = try sorted(gpa, &st.missing);
    for (ms[0..@min(top, ms.len)]) |r| try out.print("| {s} | {d} | {d} | {s} |\n", .{ keyStr(&r.k), r.c.count, r.c.files, r.c.where });

    try out.print("\n## Operations by count\n\n| op | count | % | binaries | with 66 |\n| --- | ---: | ---: | ---: | ---: |\n", .{});
    var order: [nops]u16 = undefined;
    for (&order, 0..) |*o, k| o.* = @intCast(k);
    std.mem.sort(u16, &order, &st, struct {
        fn gt(s: *Stats, x: u16, y: u16) bool {
            return s.ops[x].count > s.ops[y].count;
        }
    }.gt);
    for (order) |k| {
        if (st.ops[k].count == 0) continue;
        try out.print("| {t} | {d} | {d:.3} | {d} | {d} |\n", .{ @as(Op, @enumFromInt(k)), st.ops[k].count, pct(st.ops[k].count, n), st.ops[k].files, st.op16[k].count });
    }
    try out.print("\nUnused: ", .{});
    for (0..nops) |k| if (st.ops[k].count == 0) try out.print("{t} ", .{@as(Op, @enumFromInt(k))});

    try out.print("\n\n## x87 forms, top {d}\n\n| form | count | binaries | example |\n| --- | ---: | ---: | --- |\n", .{top});
    const xs = try sorted(gpa, &st.x87);
    for (xs[0..@min(top, xs.len)]) |r| try out.print("| {s} | {d} | {d} | {s} |\n", .{ keyStr(&r.k), r.c.count, r.c.files, r.c.where });
    try out.print("\n{d} x87 forms in all.\n", .{xs.len});

    try out.print("\n## SSE and MMX forms, top {d}\n\n| form | count | binaries | example |\n| --- | ---: | ---: | --- |\n", .{top});
    const ss = try sorted(gpa, &st.sse);
    for (ss[0..@min(top, ss.len)]) |r| try out.print("| {s} | {d} | {d} | {s} |\n", .{ keyStr(&r.k), r.c.count, r.c.files, r.c.where });
    try out.print("\n{d} SSE and MMX forms in all.\n", .{ss.len});
    try out.flush();
}
