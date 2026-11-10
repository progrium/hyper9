//! Building a Linux process image (design/0018-linux-personality.md,
//! "Loading"): a fresh address space with the stack, the vDSO, the
//! program and its interpreter, and the initial stack with argv, envp and
//! auxv. The process model commits it only once it's built.

const std = @import("std");
const vmm = @import("../vmm.zig");
const mm = @import("mm.zig");
const elf = @import("elf.zig");

pub const Error = elf.Error || mm.Error || vmm.CreateError;

pub const Program = struct {
    mm: *mm.Mm,
    entry: u64,
    sp: u64,
    vdso: u64,
};

pub const Args = struct {
    arch: vmm.Arch,
    /// The program, checked by elf.check.
    exe: *const elf.Image,
    /// Its PT_INTERP, if it has one, checked.
    interp: ?*const elf.Image = null,
    /// The path exec was given (AT_EXECFN) and the mapping's name.
    path: []const u8,
    argv: []const []const u8,
    envp: []const []const u8,
    hwcap: u64 = 0,
    hwcap2: u64 = 0,
    random: [16]u8,
};

/// The CPU features a Linux program is told about (AT_HWCAP): on arm64,
/// FP and ASIMD, which every backend has, and CPUID, the emulated ID
/// registers that say the same; the rest are left for the program to
/// discover by trying (design/0018, "Loading"). On amd64 and i386,
/// AT_HWCAP is CPUID.1:EDX, the baseline x86-64 features, which both the
/// emulator has (design/0105-linux-i386.md). `backend` adds the
/// optional features it runs (vmm.Backend.hwcaps).
pub fn hwcap(arch: vmm.Arch, backend: vmm.Backend) u64 {
    return baseHwcap(arch) | backend.hwcaps(arch);
}

fn baseHwcap(arch: vmm.Arch) u64 {
    return switch (arch) {
        .arm64 => (1 << 0) | (1 << 1) | hwcap_cpuid, // HWCAP_FP | HWCAP_ASIMD | HWCAP_CPUID
        else => 0x078bfbff,
    };
}

pub fn build(gpa: std.mem.Allocator, backend: vmm.Backend, a: Args) Error!Program {
    const m = try mm.Mm.create(gpa, backend, .of(a.arch));
    errdefer m.put();
    // The stack: 8 MiB below the top, growing down within it.
    try m.insert(.{ .start = m.lay.stack_top - m.lay.stack_size, .end = m.lay.stack_top, .prot = .rw, .kind = .stack });
    // The vDSO, on arm64 only: it holds __kernel_rt_sigreturn.
    var vdso: u64 = 0;
    if (a.arch == .arm64) {
        vdso = m.findFree(vmm.page_size) orelse return error.NoSpace;
        try m.insert(.{ .start = vdso, .end = vdso + vmm.page_size, .prot = .{ .read = true, .exec = true }, .kind = .vdso });
        const img = elf.vdsoImage();
        try m.hostWrite(vdso, &img);
    }
    const base: ?u64 = if (a.exe.ehdr.type == 3) m.lay.pie_base else null;
    const exe = try elf.load(m, a.exe, base, a.path);
    m.brk_start = std.mem.alignForward(u64, exe.end, vmm.page_size);
    // A little randomness-free gap, as Linux leaves one, so a heap that
    // grows doesn't run into the image's last page.
    m.brk = m.brk_start;
    var entry = exe.entry;
    var interp_base: u64 = 0;
    if (a.interp) |ii| {
        const l = try elf.load(m, ii, null, std.fs.path.basename(ii.interp orelse "ld.so"));
        interp_base = l.bias + ii.lo;
        entry = l.entry;
    }
    const sp = try elf.buildStack(m, a.argv, a.envp, .{
        .exe = exe,
        .phnum = a.exe.ehdr.phnum,
        .phent = a.exe.ehdr.phentsize,
        .interp_base = interp_base,
        .vdso = vdso,
        .hwcap = if (a.hwcap != 0) a.hwcap else hwcap(a.arch, backend),
        .hwcap2 = a.hwcap2,
        .random = a.random,
        .execfn = a.path,
        .arch = a.arch,
    });
    return .{ .mm = m, .entry = entry, .sp = sp, .vdso = vdso };
}

/// The registers a Linux program starts with: zero but for the stack and
/// the entry point (and on x86 the user selectors).
pub fn initRegs(arch: vmm.Arch, entry: u64, sp: u64) vmm.Ureg {
    var u = vmm.Ureg.initExec(arch, entry, sp, 0);
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
    if (h & vmm.hwcap_arm64_aes != 0) v |= @as(u64, if (h & vmm.hwcap_arm64_pmull != 0) 2 else 1) << 4;
    if (h & vmm.hwcap_arm64_sha1 != 0) v |= 1 << 8;
    if (h & vmm.hwcap_arm64_sha2 != 0) v |= 1 << 12;
    if (h & vmm.hwcap_arm64_crc32 != 0) v |= 1 << 16;
    if (h & vmm.hwcap_arm64_atomics != 0) v |= 2 << 20;
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
    try std.testing.expectEqual(@as(u64, 0x21_0000), emulateIdRead(0xd5380600, vmm.hwcap_arm64_crc32 | vmm.hwcap_arm64_atomics).?.value);
    try std.testing.expectEqual(@as(u64, 0x21_1120), emulateIdRead(0xd5380600, 0x1f8).?.value);
    // mrs x1, mpidr_el1
    try std.testing.expectEqual(@as(u64, 0x8000_0000), emulateIdRead(0xd53800a1, 0).?.value);
    // mrs x0, tpidr_el0 isn't one; nor is a nop.
    try std.testing.expect(emulateIdRead(0xd53bd040, 0) == null);
    try std.testing.expect(emulateIdRead(0xd503201f, 0) == null);
}
