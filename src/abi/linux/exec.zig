//! Building a Linux process image (design/epoch-0/linux-personality.md,
//! "Loading"): a fresh address space with the stack, the vDSO, the
//! program and its interpreter, and the initial stack with argv, envp and
//! auxv. The process model commits it only once it's built.

const std = @import("std");
const engine = @import("../../engine.zig");
const mm = @import("mm.zig");
const elf = @import("elf.zig");
const vclock = @import("vclock.zig");

pub const Error = elf.Error || mm.Error || engine.CreateError;

pub const Program = struct {
    mm: *mm.Mm,
    entry: u64,
    sp: u64,
    vdso: u64,
};

pub const Args = struct {
    arch: engine.Arch,
    /// The program, checked by elf.check.
    exe: *const elf.Image,
    /// Its PT_INTERP, if it has one, checked.
    interp: ?*const elf.Image = null,
    /// The files `exe` and `interp` were read from, to fill their
    /// segments' pages from as they're touched (elf.load); null to copy
    /// them in. build takes its own references.
    exe_src: ?*mm.Src = null,
    interp_src: ?*mm.Src = null,
    /// The path exec was given (AT_EXECFN) and the mapping's name.
    path: []const u8,
    argv: []const []const u8,
    envp: []const []const u8,
    hwcap: u64 = 0,
    hwcap2: u64 = 0,
    random: [16]u8,
};

/// The CPU features a Linux program is told about (AT_HWCAP): on arm64,
/// FP and ASIMD, which every engine has, and CPUID, the emulated ID
/// registers that say the same; the rest are left for the program to
/// discover by trying (design/0018, "Loading"). On amd64 and i386,
/// AT_HWCAP is CPUID.1:EDX, the baseline x86-64 features, which both the
/// emulator has (design/epoch-0/linux-i386.md). `engine` adds the
/// optional features it runs (engine.Engine.hwcaps).
pub fn hwcap(arch: engine.Arch, eng: engine.Engine) u64 {
    return baseHwcap(arch) | eng.hwcaps(arch);
}

fn baseHwcap(arch: engine.Arch) u64 {
    return switch (arch) {
        .arm64 => (1 << 0) | (1 << 1) | hwcap_cpuid, // HWCAP_FP | HWCAP_ASIMD | HWCAP_CPUID
        else => 0x078bfbff,
    };
}

pub fn build(gpa: std.mem.Allocator, eng: engine.Engine, a: Args) Error!Program {
    const m = try mm.Mm.create(gpa, eng, a.arch);
    errdefer m.put();
    // The stack: 8 MiB below the top, growing down within it.
    try m.insert(.{ .start = mm.layout(m).stack_top - mm.layout(m).stack_size, .end = mm.layout(m).stack_top, .prot = .rw, .kind = .stack });
    // The vDSO: on arm64, it holds __kernel_rt_sigreturn; on amd64, the
    // clock (vclock.zig), after its clock page, where the engine can
    // give it one.
    var vdso: u64 = 0;
    if (a.arch == .arm64) {
        vdso = mm.findFree(m, engine.page_size) orelse return error.NoSpace;
        try m.insert(.{ .start = vdso, .end = vdso + engine.page_size, .prot = .{ .read = true, .exec = true }, .kind = .vdso });
        const img = elf.vdsoImage();
        try m.hostWrite(vdso, &img);
    } else if (a.arch == .amd64 and vclock.supported(eng)) {
        const vvar = mm.findFree(m, 2 * engine.page_size) orelse return error.NoSpace;
        try m.insertFile(.{ .start = vvar, .end = vvar + engine.page_size, .prot = .{ .read = true }, .kind = .file, .shared = true, .name = .init("[vvar]") }, eng, vclock.pagesFor);
        vdso = vvar + engine.page_size;
        try m.insert(.{ .start = vdso, .end = vdso + engine.page_size, .prot = .{ .read = true, .exec = true }, .kind = .vdso });
        const img = vclock.image();
        try m.hostWrite(vdso, &img);
    }
    const base: ?u64 = if (a.exe.ehdr.type == 3) mm.layout(m).pie_base else null;
    const exe = try elf.load(m, a.exe, base, a.path, a.exe_src);
    m.brk_start = std.mem.alignForward(u64, exe.end, engine.page_size);
    // A little randomness-free gap, as Linux leaves one, so a heap that
    // grows doesn't run into the image's last page.
    m.brk = m.brk_start;
    var entry = exe.entry;
    var interp_base: u64 = 0;
    if (a.interp) |ii| {
        // Named by its path, as Linux's /proc/n/maps names it.
        const l = try elf.load(m, ii, null, a.exe.interp orelse "ld.so", a.interp_src);
        interp_base = l.bias + ii.lo;
        entry = l.entry;
    }
    const sp = try elf.buildStack(m, a.argv, a.envp, .{
        .exe = exe,
        .phnum = a.exe.ehdr.phnum,
        .phent = a.exe.ehdr.phentsize,
        .interp_base = interp_base,
        .vdso = vdso,
        .hwcap = if (a.hwcap != 0) a.hwcap else hwcap(a.arch, eng),
        .hwcap2 = a.hwcap2,
        .random = a.random,
        .execfn = a.path,
        .arch = a.arch,
    });
    return .{ .mm = m, .entry = entry, .sp = sp, .vdso = vdso };
}

/// The registers a Linux program starts with: zero but for the stack and
/// the entry point (and on x86 the user selectors).
pub fn initRegs(arch: engine.Arch, entry: u64, sp: u64) engine.Ureg {
    var u = engine.Ureg.initExec(arch, entry, sp, 0);
    switch (u) {
        .amd64 => |*r| r.flags = 0x202,
        .i386 => |*r| r.flags = 0x202,
        else => {},
    }
    return u;
}

/// HWCAP_CPUID: EL0 reads of the ID registers are emulated
/// (`emulateIdRead`), as Linux tells programs that check before they read
/// them.
pub const hwcap_cpuid: u64 = 1 << 11;

/// The value Linux gives an EL0 `mrs` of an ID register (its
/// emulate_mrs, Documentation/arch/arm64/cpu-feature-registers.rst), for
/// the `mrs` encoding `insn`, or null if it isn't one: the program gets
/// SIGILL then, as on Linux. Zig and LLVM read MIDR_EL1 and the
/// ID_AA64 registers to pick the host CPU's features, and an unhandled
/// read was a fault.
///
/// The values say what `hwcap`, the program's AT_HWCAP, says: MIDR is an
/// implementer-0 Armv8 part (as /proc/cpuinfo's), MPIDR has only its RES1
/// bit, ID_AA64ISAR0 has the fields of the optional features `hwcap`
/// names, and every other feature register reads 0, which is Armv8.0
/// with FP and Advanced SIMD (their fields are 0 when implemented).
pub fn emulateIdRead(insn: u32, hwcap_bits: u64) ?struct { rt: u5, value: u64 } {
    // MRS Xt, (op0 3, op1 0, CRn 0, CRm, op2): the ID space Linux emulates.
    if (insn & 0xffff_f000 != 0xd538_0000) return null;
    const crm: u4 = @truncate(insn >> 8);
    const op2: u3 = @truncate(insn >> 5);
    const rt: u5 = @truncate(insn);
    const value: u64 = switch (crm) {
        0 => switch (op2) {
            0 => 0x000f_0000, // MIDR_EL1: architecture 0xf (see the ID registers)
            5 => 0x8000_0000, // MPIDR_EL1
            6 => 0, // REVIDR_EL1
            else => return null,
        },
        6 => if (op2 == 0) isar0(hwcap_bits) else 0,
        // ID_AA64PFR0 and up, and the AArch32 ones, which read as 0 on an
        // AArch64-only CPU's EL0 as Linux sanitizes them.
        1...5, 7 => 0,
        else => return null,
    };
    return .{ .rt = rt, .value = value };
}

/// ID_AA64ISAR0_EL1 for the AT_HWCAP bits `h`: AES (bits 7:4) 1, or 2
/// with PMULL; SHA1 (11:8) 1; SHA2 (15:12) 1; CRC32 (19:16) 1; and Atomic
/// (23:20) 2.
fn isar0(h: u64) u64 {
    var v: u64 = 0;
    if (h & engine.hwcap_arm64_aes != 0) v |= @as(u64, if (h & engine.hwcap_arm64_pmull != 0) 2 else 1) << 4;
    if (h & engine.hwcap_arm64_sha1 != 0) v |= 1 << 8;
    if (h & engine.hwcap_arm64_sha2 != 0) v |= 1 << 12;
    if (h & engine.hwcap_arm64_crc32 != 0) v |= 1 << 16;
    if (h & engine.hwcap_arm64_atomics != 0) v |= 2 << 20;
    return v;
}

test "emulateIdRead decodes mrs of the ID registers" {
    // mrs x3, midr_el1
    const midr = emulateIdRead(0xd5380003, 0).?;
    try std.testing.expectEqual(@as(u5, 3), midr.rt);
    try std.testing.expectEqual(@as(u64, 0x000f_0000), midr.value);
    // mrs x0, id_aa64isar0_el1 (CRm 6, op2 0)
    try std.testing.expectEqual(@as(u64, 0), emulateIdRead(0xd5380600, 0).?.value);
    // ID_AA64ISAR0 says what AT_HWCAP does.
    try std.testing.expectEqual(@as(u64, 0x21_0000), emulateIdRead(0xd5380600, engine.hwcap_arm64_crc32 | engine.hwcap_arm64_atomics).?.value);
    try std.testing.expectEqual(@as(u64, 0x21_1120), emulateIdRead(0xd5380600, 0x1f8).?.value);
    // mrs x1, mpidr_el1
    try std.testing.expectEqual(@as(u64, 0x8000_0000), emulateIdRead(0xd53800a1, 0).?.value);
    // mrs x0, tpidr_el0 isn't one; nor is a nop.
    try std.testing.expect(emulateIdRead(0xd53bd040, 0) == null);
    try std.testing.expect(emulateIdRead(0xd503201f, 0) == null);
}
