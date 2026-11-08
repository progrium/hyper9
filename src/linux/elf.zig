//! The ELF loader for the Linux personality (design/0018-linux-personality.md,
//! "The ELF loader"): static and dynamic ELF64 executables of the
//! machine's architecture, the Linux initial stack and auxv, and a minimal
//! vDSO on arm64.
//!
//! `check` validates an image, and the interpreter's, before exec tears
//! down anything, so a failed execve returns to its caller.

const std = @import("std");
const vmm = @import("../vmm.zig");
const mm = @import("mm.zig");

const page = vmm.page_size;

pub const Error = error{
    /// Not an ELF file at all (exec tries other formats).
    NotElf,
    /// An ELF file h9 can't run: wrong class, endianness, architecture or
    /// type, or a bad header (ENOEXEC).
    BadElf,
} || mm.Error;

const PT_LOAD = 1;
const PT_DYNAMIC = 2;
const PT_INTERP = 3;
const PT_PHDR = 6;
const PT_GNU_STACK = 0x6474e551;
const ET_EXEC = 2;
const ET_DYN = 3;
const EM_X86_64 = 62;
const EM_AARCH64 = 183;

pub const Ehdr = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

pub const Phdr = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    @"align": u64,
};

pub fn isElf(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\x7fELF");
}

/// The architecture an ELF binary is for, or null if it isn't one h9
/// runs (design/0018: arm64 and amd64).
pub fn machineArch(bytes: []const u8) ?vmm.Arch {
    if (!isElf(bytes) or bytes.len < @sizeOf(Ehdr)) return null;
    return switch (std.mem.readInt(u16, bytes[18..20], .little)) {
        EM_AARCH64 => .arm64,
        EM_X86_64 => .amd64,
        else => null,
    };
}

/// A validated image: its header and program headers, copied out.
pub const Image = struct {
    bytes: []const u8,
    ehdr: Ehdr,
    phdrs: []align(1) const Phdr,
    /// PT_INTERP's path, without the NUL.
    interp: ?[]const u8 = null,
    /// The span of its PT_LOAD segments, page-aligned, before the bias.
    lo: u64,
    hi: u64,
    exec_stack: bool = false,
};

/// Validates an ELF64 executable or shared object for `arch`.
pub fn check(bytes: []const u8, arch: vmm.Arch) Error!Image {
    if (!isElf(bytes)) return error.NotElf;
    if (bytes.len < @sizeOf(Ehdr)) return error.BadElf;
    const eh = std.mem.bytesToValue(Ehdr, bytes[0..@sizeOf(Ehdr)]);
    if (eh.ident[4] != 2 or eh.ident[5] != 1) return error.BadElf; // ELFCLASS64, little-endian
    const machine: u16 = switch (arch) {
        .arm64 => EM_AARCH64,
        .amd64 => EM_X86_64,
        .i386 => return error.BadElf,
    };
    if (eh.machine != machine) return error.BadElf;
    if (eh.type != ET_EXEC and eh.type != ET_DYN) return error.BadElf;
    if (eh.phentsize != @sizeOf(Phdr) or eh.phnum == 0 or eh.phnum > 128) return error.BadElf;
    const ph_end = std.math.add(u64, eh.phoff, @as(u64, eh.phnum) * @sizeOf(Phdr)) catch return error.BadElf;
    if (ph_end > bytes.len) return error.BadElf;
    const phdrs = std.mem.bytesAsSlice(Phdr, bytes[@intCast(eh.phoff)..@intCast(ph_end)]);
    var img: Image = .{ .bytes = bytes, .ehdr = eh, .phdrs = phdrs, .lo = std.math.maxInt(u64), .hi = 0 };
    for (phdrs) |ph| switch (ph.type) {
        PT_LOAD => {
            if (ph.filesz > ph.memsz) return error.BadElf;
            const fend = std.math.add(u64, ph.offset, ph.filesz) catch return error.BadElf;
            if (fend > bytes.len) return error.BadElf;
            if (ph.vaddr % page != ph.offset % page) return error.BadElf;
            const vend = std.math.add(u64, ph.vaddr, ph.memsz) catch return error.BadElf;
            if (vend > mm.user_top) return error.BadElf;
            img.lo = @min(img.lo, ph.vaddr - ph.vaddr % page);
            img.hi = @max(img.hi, std.mem.alignForward(u64, vend, page));
        },
        PT_INTERP => {
            const end = std.math.add(u64, ph.offset, ph.filesz) catch return error.BadElf;
            if (end > bytes.len or ph.filesz < 2) return error.BadElf;
            const s = bytes[@intCast(ph.offset)..@intCast(end)];
            img.interp = std.mem.sliceTo(s, 0);
            if (img.interp.?.len == 0) return error.BadElf;
        },
        PT_GNU_STACK => img.exec_stack = ph.flags & 1 != 0,
        else => {},
    };
    if (img.hi == 0) return error.BadElf;
    if (eh.type == ET_EXEC and img.lo < mm.min_addr) return error.BadElf;
    if (img.hi - img.lo > mm.mmap_base / 2) return error.BadElf;
    return img;
}

/// Where an image was loaded.
pub const Loaded = struct {
    /// Added to the image's addresses (0 for ET_EXEC).
    bias: u64,
    entry: u64,
    /// The program headers' address in memory, for AT_PHDR.
    phdr: u64,
    end: u64,
};

/// Maps `img`'s segments into `m`. A PIE goes at `base`, or for the
/// interpreter (base null) wherever mmap would put it.
pub fn load(m: *mm.Mm, img: *const Image, base: ?u64, name: []const u8) Error!Loaded {
    const span = img.hi - img.lo;
    const bias: u64 = if (img.ehdr.type == ET_EXEC) 0 else blk: {
        const at = base orelse (m.findFree(span) orelse return error.NoSpace);
        break :blk at - img.lo;
    };
    var phdr: u64 = 0;
    var prev_end: u64 = 0;
    for (img.phdrs) |ph| {
        if (ph.type == PT_PHDR) phdr = bias + ph.vaddr;
        if (ph.type != PT_LOAD or ph.memsz == 0) continue;
        const prot: mm.Prot = .{ .read = ph.flags & 4 != 0, .write = ph.flags & 2 != 0, .exec = ph.flags & 1 != 0 };
        var start = bias + ph.vaddr - ph.vaddr % page;
        const end = std.mem.alignForward(u64, bias + ph.vaddr + ph.memsz, page);
        // Segments that share a page: the page takes both permissions.
        if (start < prev_end) {
            if (m.find(start)) |v| {
                const both: mm.Prot = .{ .read = v.prot.read or prot.read, .write = v.prot.write or prot.write, .exec = v.prot.exec or prot.exec };
                try m.protect(start, prev_end, both);
            }
            start = prev_end;
        }
        if (start < end) try m.insert(.{
            .start = start,
            .end = end,
            .prot = prot,
            .kind = .file,
            .name = .init(name),
            .offset = ph.offset - ph.offset % page + (start - (bias + ph.vaddr - ph.vaddr % page)),
        });
        prev_end = @max(prev_end, end);
        if (ph.filesz > 0) try m.hostWrite(bias + ph.vaddr, img.bytes[@intCast(ph.offset)..][0..@intCast(ph.filesz)]);
        // The file's tail of the last page (the start of the bss) may
        // hold bytes past filesz in a page that's zero already.
        if (phdr == 0 and ph.offset <= img.ehdr.phoff and img.ehdr.phoff + @as(u64, img.ehdr.phnum) * @sizeOf(Phdr) <= ph.offset + ph.filesz) {
            phdr = bias + ph.vaddr + (img.ehdr.phoff - ph.offset);
        }
    }
    return .{ .bias = bias, .entry = bias + img.ehdr.entry, .phdr = phdr, .end = bias + img.hi };
}

// auxv keys.
const AT_NULL = 0;
const AT_PHDR = 3;
const AT_PHENT = 4;
const AT_PHNUM = 5;
const AT_PAGESZ = 6;
const AT_BASE = 7;
const AT_FLAGS = 8;
const AT_ENTRY = 9;
const AT_UID = 11;
const AT_EUID = 12;
const AT_GID = 13;
const AT_EGID = 14;
const AT_PLATFORM = 15;
const AT_HWCAP = 16;
const AT_CLKTCK = 17;
const AT_SECURE = 23;
const AT_RANDOM = 25;
const AT_HWCAP2 = 26;
const AT_EXECFN = 31;
const AT_SYSINFO_EHDR = 33;

pub const StackInfo = struct {
    exe: Loaded,
    phnum: u64,
    interp_base: u64,
    vdso: u64,
    hwcap: u64,
    hwcap2: u64,
    random: [16]u8,
    execfn: []const u8,
    arch: vmm.Arch,
};

/// Builds the initial stack at the top of the stack VMA and returns SP.
pub fn buildStack(m: *mm.Mm, argv: []const []const u8, envp: []const []const u8, info: StackInfo) Error!u64 {
    const platform = switch (info.arch) {
        .arm64 => "aarch64",
        else => "x86_64",
    };
    // Strings, from the top down: execfn, envp, argv, platform, random.
    var size: u64 = info.execfn.len + 1 + platform.len + 1 + 16;
    for (argv) |a| size += a.len + 1;
    for (envp) |e| size += e.len + 1;
    const nauxv = 20;
    const words = 1 + argv.len + 1 + envp.len + 1 + 2 * nauxv;
    const total = std.mem.alignForward(u64, size, 16) + words * 8 + 16;
    if (total > mm.stack_size / 4) return error.NoSpace;

    const top = mm.stack_top;
    var buf = try m.gpa.alloc(u8, @intCast(std.mem.alignForward(u64, total, page)));
    defer m.gpa.free(buf);
    @memset(buf, 0);
    const base = top - buf.len;
    var at = buf.len;
    const put = struct {
        fn s(b: []u8, pos: *usize, str: []const u8) u64 {
            pos.* -= str.len + 1;
            @memcpy(b[pos.*..][0..str.len], str);
            b[pos.* + str.len] = 0;
            return pos.*;
        }
    };
    const execfn = base + put.s(buf, &at, info.execfn);
    var env_ptrs = try m.gpa.alloc(u64, envp.len);
    defer m.gpa.free(env_ptrs);
    var i = envp.len;
    while (i > 0) {
        i -= 1;
        env_ptrs[i] = base + put.s(buf, &at, envp[i]);
    }
    var arg_ptrs = try m.gpa.alloc(u64, argv.len);
    defer m.gpa.free(arg_ptrs);
    i = argv.len;
    while (i > 0) {
        i -= 1;
        arg_ptrs[i] = base + put.s(buf, &at, argv[i]);
    }
    const plat = base + put.s(buf, &at, platform);
    at -= 16;
    @memcpy(buf[at..][0..16], &info.random);
    const random = base + at;
    at &= ~@as(usize, 15);

    var auxv: [nauxv * 2]u64 = undefined;
    var n: usize = 0;
    const av = struct {
        fn add(a: []u64, k: *usize, key: u64, val: u64) void {
            a[k.*] = key;
            a[k.* + 1] = val;
            k.* += 2;
        }
    };
    av.add(&auxv, &n, AT_PHDR, info.exe.phdr);
    av.add(&auxv, &n, AT_PHENT, @sizeOf(Phdr));
    av.add(&auxv, &n, AT_PHNUM, info.phnum);
    av.add(&auxv, &n, AT_PAGESZ, page);
    av.add(&auxv, &n, AT_BASE, info.interp_base);
    av.add(&auxv, &n, AT_FLAGS, 0);
    av.add(&auxv, &n, AT_ENTRY, info.exe.entry);
    av.add(&auxv, &n, AT_UID, 0);
    av.add(&auxv, &n, AT_EUID, 0);
    av.add(&auxv, &n, AT_GID, 0);
    av.add(&auxv, &n, AT_EGID, 0);
    av.add(&auxv, &n, AT_HWCAP, info.hwcap);
    av.add(&auxv, &n, AT_HWCAP2, info.hwcap2);
    av.add(&auxv, &n, AT_CLKTCK, 100);
    av.add(&auxv, &n, AT_SECURE, 0);
    av.add(&auxv, &n, AT_RANDOM, random);
    av.add(&auxv, &n, AT_PLATFORM, plat);
    av.add(&auxv, &n, AT_EXECFN, execfn);
    if (info.vdso != 0) av.add(&auxv, &n, AT_SYSINFO_EHDR, info.vdso);
    av.add(&auxv, &n, AT_NULL, 0);

    const nwords = 1 + argv.len + 1 + envp.len + 1 + n;
    at -= nwords * 8;
    at &= ~@as(usize, 15);
    const sp_off = at;
    var w = sp_off;
    const wr = struct {
        fn word(b: []u8, pos: *usize, v: u64) void {
            std.mem.writeInt(u64, b[pos.*..][0..8], v, .little);
            pos.* += 8;
        }
    };
    wr.word(buf, &w, argv.len);
    for (arg_ptrs) |p| wr.word(buf, &w, p);
    wr.word(buf, &w, 0);
    for (env_ptrs) |p| wr.word(buf, &w, p);
    wr.word(buf, &w, 0);
    for (auxv[0..n]) |v| wr.word(buf, &w, v);

    try m.hostWrite(base, buf);
    return base + sp_off;
}

/// The vDSO image: one page holding a minimal ELF shared object whose
/// only symbol is `__kernel_rt_sigreturn` (arm64), the return address of
/// signal handlers installed without SA_RESTORER. It exports no clock, so
/// libc and Go make real syscalls for time.
pub const vdso_sigreturn_off: u64 = 0x300;

pub fn vdsoImage() [page]u8 {
    var b: [page]u8 = @splat(0);
    const hash_off = 0xc0;
    const versym_off = 0xd8;
    const sym_off = 0xe0;
    const verdef_off = 0x110;
    const str_off = 0x150;
    const dyn_off = 0x190;
    const strtab = "\x00__kernel_rt_sigreturn\x00LINUX_2.6.39\x00linux-vdso.so.1\x00";
    const name_ver = 23;
    const name_base = 36;
    const ndyn = 9;
    var eh: Ehdr = .{
        .ident = .{ 0x7f, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .type = ET_DYN,
        .machine = EM_AARCH64,
        .version = 1,
        .entry = 0,
        .phoff = @sizeOf(Ehdr),
        .shoff = 0,
        .flags = 0,
        .ehsize = @sizeOf(Ehdr),
        .phentsize = @sizeOf(Phdr),
        .phnum = 2,
        .shentsize = 0,
        .shnum = 0,
        .shstrndx = 0,
    };
    @memcpy(b[0..@sizeOf(Ehdr)], std.mem.asBytes(&eh));
    const phs = [2]Phdr{
        .{ .type = PT_LOAD, .flags = 5, .offset = 0, .vaddr = 0, .paddr = 0, .filesz = page, .memsz = page, .@"align" = page },
        .{ .type = PT_DYNAMIC, .flags = 4, .offset = dyn_off, .vaddr = dyn_off, .paddr = dyn_off, .filesz = ndyn * 16, .memsz = ndyn * 16, .@"align" = 8 },
    };
    @memcpy(b[@sizeOf(Ehdr)..][0 .. 2 * @sizeOf(Phdr)], std.mem.sliceAsBytes(&phs));
    // DT_HASH: nbucket 1, nchain 2, bucket[0] = 1, chain = {0, 0}.
    for ([_]u32{ 1, 2, 1, 0, 0 }, 0..) |v, i| std.mem.writeInt(u32, b[hash_off + 4 * i ..][0..4], v, .little);
    // Elf64_Sym: name u32, info u8, other u8, shndx u16, value u64, size u64.
    const sym = sym_off + 24; // symbol 0 is null
    std.mem.writeInt(u32, b[sym..][0..4], 1, .little);
    b[sym + 4] = 0x12; // STB_GLOBAL, STT_FUNC
    std.mem.writeInt(u16, b[sym + 6 ..][0..2], 1, .little);
    std.mem.writeInt(u64, b[sym + 8 ..][0..8], vdso_sigreturn_off, .little);
    std.mem.writeInt(u64, b[sym + 16 ..][0..8], 8, .little);
    @memcpy(b[str_off..][0..strtab.len], strtab);
    // Symbol versions, as Linux's vDSO has them: Go's lookup expects a
    // version definition (and faults without one). Symbol 1 is
    // LINUX_2.6.39, version index 2; index 1 is the object's base.
    std.mem.writeInt(u16, b[versym_off + 2 ..][0..2], 2, .little);
    // Elf64_Verdef: version, flags, ndx, cnt u16; hash, aux, next u32;
    // then its Elf64_Verdaux: name, next u32.
    for ([_]struct { flags: u16, ndx: u16, name: u32, next: u32 }{
        .{ .flags = 1, .ndx = 1, .name = name_base, .next = 28 },
        .{ .flags = 0, .ndx = 2, .name = name_ver, .next = 0 },
    }, 0..) |d, i| {
        const o = verdef_off + 28 * i;
        std.mem.writeInt(u16, b[o..][0..2], 1, .little);
        std.mem.writeInt(u16, b[o + 2 ..][0..2], d.flags, .little);
        std.mem.writeInt(u16, b[o + 4 ..][0..2], d.ndx, .little);
        std.mem.writeInt(u16, b[o + 6 ..][0..2], 1, .little);
        std.mem.writeInt(u32, b[o + 8 ..][0..4], elfHash(std.mem.sliceTo(strtab[d.name..], 0)), .little);
        std.mem.writeInt(u32, b[o + 12 ..][0..4], 20, .little);
        std.mem.writeInt(u32, b[o + 16 ..][0..4], d.next, .little);
        std.mem.writeInt(u32, b[o + 20 ..][0..4], d.name, .little);
    }
    const DT_HASH = 4;
    const DT_STRTAB = 5;
    const DT_SYMTAB = 6;
    const DT_STRSZ = 10;
    const DT_SYMENT = 11;
    const DT_VERSYM = 0x6ffffff0;
    const DT_VERDEF = 0x6ffffffc;
    const DT_VERDEFNUM = 0x6ffffffd;
    for ([ndyn][2]u64{
        .{ DT_HASH, hash_off },     .{ DT_STRTAB, str_off }, .{ DT_SYMTAB, sym_off },
        .{ DT_STRSZ, strtab.len },  .{ DT_SYMENT, 24 },      .{ DT_VERSYM, versym_off },
        .{ DT_VERDEF, verdef_off }, .{ DT_VERDEFNUM, 2 },    .{ 0, 0 },
    }, 0..) |d, i| {
        std.mem.writeInt(u64, b[dyn_off + 16 * i ..][0..8], d[0], .little);
        std.mem.writeInt(u64, b[dyn_off + 16 * i + 8 ..][0..8], d[1], .little);
    }
    // mov x8, #139 (rt_sigreturn); svc #0
    std.mem.writeInt(u32, b[vdso_sigreturn_off..][0..4], 0xd2801168, .little);
    std.mem.writeInt(u32, b[vdso_sigreturn_off + 4 ..][0..4], 0xd4000001, .little);
    return b;
}

/// The SysV ELF hash of a name, as symbol version definitions carry.
fn elfHash(name: []const u8) u32 {
    var h: u32 = 0;
    for (name) |ch| {
        h = (h << 4) +% ch;
        const g = h & 0xf0000000;
        if (g != 0) h ^= g >> 24;
        h &= ~g;
    }
    return h;
}

test "elf hash of the vDSO version" {
    // Go's vdso_linux_arm64.go has this one.
    try std.testing.expectEqual(@as(u32, 0x75fcb89), elfHash("LINUX_2.6.39"));
}

test "vdso has its symbol" {
    const v = vdsoImage();
    try std.testing.expect(isElf(&v));
    try std.testing.expectEqual(@as(u32, 0xd2801168), std.mem.readInt(u32, v[vdso_sigreturn_off..][0..4], .little));
}
