//! arm64 stage-1 translation for the hypervisor backends (HVF, KVM): a 4K
//! granule with 48-bit VAs in both halves. User code runs at EL0 under
//! TTBR0. The shim, the doorbell page and the per-vCPU shared pages live at
//! fixed kernel addresses under TTBR1, which every vCPU shares.
//!
//! Also the system register values the host sets for the shim, which are
//! the same whichever hypervisor sets them.

const std = @import("std");
const vmm = @import("../vmm.zig");
const arm64 = @import("../arch/arm64.zig");
const gphys = @import("gphys.zig");

pub const shim_code = @embedFile("shim_arm64");

// shim.S finds the doorbell at the page after the vectors.
pub const kva_shim: u64 = 0xFFFF_FFFF_F000_0000;
pub const kva_doorbell: u64 = kva_shim + 0x1000;
pub const kva_shared: u64 = kva_shim + 0x10000;

/// The per-vCPU page the shim saves into; layout is fixed by shim.S.
pub const Shared = extern struct {
    ureg: arm64.Ureg,
    far: u64,
    why: u64,
    /// Set by the host to make the shim flush the TLB and I-cache before
    /// it returns to EL0.
    flush: u64,
};
comptime {
    std.debug.assert(@offsetOf(arm64.Ureg, "sp") == 248);
    std.debug.assert(@offsetOf(arm64.Ureg, "type") == 272);
    std.debug.assert(@offsetOf(Shared, "far") == 280);
    std.debug.assert(@offsetOf(Shared, "why") == 288);
    std.debug.assert(@offsetOf(Shared, "flush") == 296);
}
/// shim.S's entry point after the vectors, which restores the Ureg from the
/// shared page and ERETs, flushing first if asked.
pub const shim_enter = 0x800;
/// EL1h with DAIF masked, for entering the shim.
pub const psr_el1h: u64 = 0x3c5;
pub const why_el0 = 1;
pub const why_irq = 3;

/// System registers, in the op0:op1:CRn:CRm:op2 encoding that HVF's
/// hv_sys_reg_t and KVM's KVM_REG_ARM64_SYSREG both use.
pub const SYS_TPIDR_EL0: u16 = 0xde82;
pub const SYS_SCTLR_EL1: u16 = 0xc080;
pub const SYS_CPACR_EL1: u16 = 0xc082;
pub const SYS_TTBR0_EL1: u16 = 0xc100;
pub const SYS_TTBR1_EL1: u16 = 0xc101;
pub const SYS_TCR_EL1: u16 = 0xc102;
pub const SYS_SP_EL0: u16 = 0xc208;
pub const SYS_MAIR_EL1: u16 = 0xc510;
pub const SYS_VBAR_EL1: u16 = 0xc600;
pub const SYS_SP_EL1: u16 = 0xe208;

/// The IPA size the tables and the VM use: HVF's default.
pub const ipa_bits = 36;

pub const TCR: u64 = 16 | // T0SZ
    (1 << 8) | (1 << 10) | (3 << 12) | // TTBR0 walks: write-back, inner shareable
    (16 << 16) | // T1SZ
    (1 << 24) | (1 << 26) | (3 << 28) | // TTBR1 walks: write-back, inner shareable
    (2 << 30) | // TG1 = 4K (TG0 = 0 is 4K)
    (1 << 32); // IPS = 36 bits

pub const MAIR: u64 = 0xff; // attr 0: normal memory, write-back

pub const SCTLR: u64 = (1 << 29) | (1 << 28) | (1 << 23) | (1 << 22) | (1 << 20) | (1 << 11) | (1 << 8) | (1 << 7) | // RES1
    (1 << 0) | (1 << 2) | (1 << 12); // M, C, I

/// CPACR_EL1: no FP/SIMD traps.
pub const CPACR: u64 = 3 << 20;

/// The system registers the host sets on every vCPU, given its shared
/// page, and the kernel tables' root.
pub fn sysregs(kernel_root: u64, shared_kva: u64) [7]struct { u16, u64 } {
    return .{
        .{ SYS_VBAR_EL1, kva_shim },
        .{ SYS_MAIR_EL1, MAIR },
        .{ SYS_TCR_EL1, TCR },
        .{ SYS_TTBR1_EL1, kernel_root },
        .{ SYS_CPACR_EL1, CPACR },
        .{ SYS_SP_EL1, shared_kva },
        .{ SYS_SCTLR_EL1, SCTLR },
    };
}

const PTE_VALID: u64 = 0b11; // page (L3) or table (L0-L2)
const PTE_AF: u64 = 1 << 10;
const PTE_ISH: u64 = 3 << 8;
const PTE_USER: u64 = 1 << 6;
const PTE_RDONLY: u64 = 1 << 7;
const PTE_PXN: u64 = 1 << 53;
const PTE_UXN: u64 = 1 << 54;
const PTE_ADDR: u64 = 0x0000_FFFF_FFFF_F000;

/// User addresses are below this (TTBR0's 48 bits).
pub const user_top: u64 = 1 << 48;

pub fn pteAttrs(user: bool, perms: vmm.Perms) u64 {
    var d = PTE_VALID | PTE_AF | PTE_ISH;
    if (!perms.write) d |= PTE_RDONLY;
    if (user) {
        d |= PTE_USER | PTE_PXN;
        if (!perms.exec) d |= PTE_UXN;
    } else {
        d |= PTE_UXN;
        if (!perms.exec) d |= PTE_PXN;
    }
    return d;
}

pub fn userAttrs(perms: vmm.Perms) u64 {
    return pteAttrs(true, perms);
}

/// TTBR0 and TTBR1 are separate roots, so a user root starts empty.
pub fn newRoot(ram: *gphys.Ram, _: u64) vmm.Error!u64 {
    return ram.allocTable();
}

pub fn freeRoot(ram: *gphys.Ram, root: u64) void {
    freeTables(ram, root, 0);
}

/// The caller serializes changes to the tables under `root`.
pub fn mapPage(ram: *gphys.Ram, root: u64, va: u64, pa: u64, attrs: u64) vmm.Error!void {
    var t = root;
    var shift: u6 = 39;
    while (shift > 12) : (shift -= 9) {
        const e = &ram.table(t)[(va >> shift) & 511];
        if (e.* & PTE_VALID == 0) @atomicStore(u64, e, (try ram.allocTable()) | PTE_VALID, .release);
        t = e.* & PTE_ADDR;
    }
    @atomicStore(u64, &ram.table(t)[(va >> 12) & 511], (pa & PTE_ADDR) | attrs, .release);
}

pub fn unmapPage(ram: *gphys.Ram, root: u64, va: u64) void {
    var t = root;
    var shift: u6 = 39;
    while (shift > 12) : (shift -= 9) {
        const e = ram.table(t)[(va >> shift) & 511];
        if (e & PTE_VALID == 0) return;
        t = e & PTE_ADDR;
    }
    @atomicStore(u64, &ram.table(t)[(va >> 12) & 511], 0, .release);
}

/// Frees the table at `pa` and the tables below it, not the pages they map.
fn freeTables(ram: *gphys.Ram, pa: u64, level: u2) void {
    if (level < 3) for (ram.table(pa)) |e| {
        if (e & PTE_VALID != 0) freeTables(ram, e & PTE_ADDR, level + 1);
    };
    ram.freeTable(pa);
}

/// The kernel half: the shim, the doorbell page, and a root for TTBR1.
/// The doorbell's IPA is never mapped, so stores to it exit to the host.
pub fn kernelRoot(ram: *gphys.Ram, doorbell_ipa: u64) vmm.Error!u64 {
    const root = try ram.allocTable();
    const shim = try ram.allocPages(1);
    @memcpy(shim[0..shim_code.len], shim_code);
    try mapPage(ram, root, kva_shim, ram.gpaOf(shim), pteAttrs(false, .{ .exec = true }));
    try mapPage(ram, root, kva_doorbell, doorbell_ipa, pteAttrs(false, .{ .write = true }));
    return root;
}

/// Shared-page slots for vCPUs, one bit each, and the kernel mappings of
/// their pages.
pub const Slots = struct {
    words: [max / 64]u64 = @splat(0),
    lock: std.atomic.Mutex = .unlocked,

    /// More than either hypervisor's vCPU limit (HVF's 64, KVM's 512 on
    /// arm64 without a vGIC).
    pub const max = 1024;
    pub const Index = std.math.IntFittingRange(0, max - 1);

    fn lockSpin(s: *Slots) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Takes a slot and maps a fresh shared page for it.
    pub fn take(s: *Slots, ram: *gphys.Ram, kernel_root: u64) vmm.Error!struct { Index, *Shared } {
        s.lockSpin();
        defer s.lock.unlock();
        const i: Index = for (s.words, 0..) |w, n| {
            if (w != std.math.maxInt(u64)) break @intCast(n * 64 + @ctz(~w));
        } else return error.HypervisorFailed;
        const page = try ram.allocPages(1);
        errdefer ram.freePages(page);
        try mapPage(ram, kernel_root, sharedKva(i), ram.gpaOf(page), pteAttrs(false, .{ .write = true }));
        s.words[i / 64] |= @as(u64, 1) << @intCast(i % 64);
        return .{ i, @ptrCast(page.ptr) };
    }

    pub fn release(s: *Slots, ram: *gphys.Ram, kernel_root: u64, i: Index, shared: *Shared) void {
        s.lockSpin();
        defer s.lock.unlock();
        unmapPage(ram, kernel_root, sharedKva(i));
        ram.freePages(@as([*]align(vmm.page_size) u8, @ptrCast(@alignCast(shared)))[0..vmm.page_size]);
        s.words[i / 64] &= ~(@as(u64, 1) << @intCast(i % 64));
    }
};

pub fn sharedKva(slot: u64) u64 {
    return kva_shared + slot * vmm.page_size;
}
