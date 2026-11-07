//! The amd64 CPU state the host sets up for the amd64 shim
//! (src/arch/amd64/shim.S), as plain values: the control registers, the
//! descriptor table images, the SYSCALL MSRs and the CPUID mask. KVM sets
//! them through its own calls, and WHP (design/0017-whp.md) can set the
//! same state through its own.
//!
//! The shim runs in ring 0 in long mode from the kernel half. User code
//! enters it with SYSCALL, or through the IDT on an exception, which
//! switches to the vCPU's shared page as a stack (IST1). It saves the
//! registers there and rings the doorbell, an OUT to `doorbell_port`.

const std = @import("std");
const amd64 = @import("../arch/amd64.zig");

pub const shim_code = @embedFile("shim_amd64");

/// shim.S's layout: the exception stubs at 0, 16 bytes each, the SYSCALL
/// entry, and the doorbell, after which `restore` loads the Ureg and
/// IRETQs. Below the doorbell the shim is saving a Ureg, past it loading
/// one. A vCPU's first run starts at `restore`.
pub const shim_vectors = 0x000;
pub const shim_syscall = 0x200;
pub const shim_doorbell = 0x600;
pub const shim_restore = shim_doorbell + 2;
/// The OUT port the shim rings.
pub const doorbell_port: u16 = 0x99;
/// Exceptions the shim handles: vectors 0-31. The IDT ends there.
pub const nvectors = 32;

/// The per-vCPU page the shim saves into and runs on; layout is fixed by
/// shim.S.
pub const Shared = extern struct {
    ureg: amd64.Ureg,
    /// CR2 at a page fault.
    far: u64,
    why: u64,
    /// Set by the host to a root table's address; the shim loads it into
    /// CR3 (which also flushes the TLB) before it returns to user mode.
    next_cr3: u64,
    /// The page's own kernel address, for the shim's stack.
    self: u64,
};
comptime {
    std.debug.assert(@offsetOf(Shared, "far") == 184);
    std.debug.assert(@offsetOf(Shared, "why") == 192);
    std.debug.assert(@offsetOf(Shared, "next_cr3") == 200);
    std.debug.assert(@offsetOf(Shared, "self") == 208);
}
/// The GDT and TSS live in the shared page too, past the Shared struct,
/// and IST1 is the top of the page.
pub const gdt_off = 0x800;
pub const tss_off = 0x880;
pub const stack_top = 0x1000;

pub const why_syscall = 1;
pub const why_trap = 2;
/// An exception in the shim itself.
pub const why_shim = 3;

/// 9front's pc64 VectorSYSCALL, which the shim puts in Ureg.type.
pub const vector_syscall = 64;
pub const vector_pf = 14;

// pc64/mem.h's GDT: the same selectors as 9front's, so user code sees
// UESEL and UDSEL.
pub const kesel: u16 = 1 << 3;
pub const kdsel: u16 = 2 << 3;
pub const ue32sel: u16 = (3 << 3) | 3;
pub const udsel: u16 = amd64.UDSEL;
pub const uesel: u16 = amd64.UESEL;
pub const tsssel: u16 = 8 << 3;
pub const ngdt = 10;

/// A segment as the host loads it into a vCPU's hidden segment state.
pub const Segment = struct {
    base: u64 = 0,
    limit: u32 = 0xffff_ffff,
    selector: u16,
    /// The descriptor's type field, with the accessed bit set.
    type: u4,
    /// Code or data (as opposed to a system segment).
    s: bool = true,
    dpl: u2 = 0,
    present: bool = true,
    /// 64-bit code.
    l: bool = false,
    db: bool = false,
    g: bool = true,
};

pub const code64: Segment = .{ .selector = kesel, .type = 0xb, .l = true };
pub const data: Segment = .{ .selector = kdsel, .type = 0x3, .db = true };
/// DS, ES, FS and GS hold the null selector, as user mode leaves them;
/// FS and GS have their bases set apart.
pub const null_data: Segment = .{ .selector = 0, .type = 0x3, .db = true };

pub fn tr(tss_base: u64) Segment {
    return .{ .base = tss_base, .limit = @sizeOf(Tss) - 1, .selector = tsssel, .type = 0xb, .s = false, .g = false };
}

/// The GDT image: pc64's layout, with the 64-bit TSS in entries 8-9.
pub fn gdt(tss_base: u64) [ngdt]u64 {
    var g: [ngdt]u64 = @splat(0);
    g[1] = 0x00209b0000000000; // KESEG: 64-bit code, DPL 0
    g[2] = 0x00cf93000000ffff; // KDSEG: data, DPL 0
    g[3] = 0x00cffb000000ffff; // UE32SEG: 32-bit code, DPL 3
    g[4] = 0x00cff3000000ffff; // UDSEG: data, DPL 3
    g[5] = 0x0020fb0000000000; // UESEG: 64-bit code, DPL 3
    const limit: u64 = @sizeOf(Tss) - 1;
    g[8] = (limit & 0xffff) | ((tss_base & 0xffffff) << 16) | (@as(u64, 0x8b) << 40) | ((tss_base >> 24 & 0xff) << 56);
    g[9] = tss_base >> 32;
    return g;
}

/// The 64-bit TSS. Only IST1 is used: every exception switches to it.
pub const Tss = extern struct {
    _r0: u32 align(4) = 0,
    rsp0_lo: u32 = 0,
    rsp0_hi: u32 = 0,
    rsp1: [2]u32 = @splat(0),
    rsp2: [2]u32 = @splat(0),
    _r1: [2]u32 = @splat(0),
    ist1_lo: u32 = 0,
    ist1_hi: u32 = 0,
    ist2_7: [12]u32 = @splat(0),
    _r2: [2]u32 = @splat(0),
    _r3: u16 = 0,
    /// Past the limit: no I/O permission bitmap, so user I/O faults.
    iomap: u16 = @sizeOf(Tss),

    pub fn init(stack: u64) Tss {
        return .{
            .rsp0_lo = @truncate(stack),
            .rsp0_hi = @truncate(stack >> 32),
            .ist1_lo = @truncate(stack),
            .ist1_hi = @truncate(stack >> 32),
        };
    }

    comptime {
        std.debug.assert(@sizeOf(Tss) == 104);
        std.debug.assert(@offsetOf(Tss, "ist1_lo") == 0x24);
    }
};

/// An IDT entry: an interrupt gate to `handler` in the kernel code
/// segment, on IST1, reachable only from ring 0 (so INT n from user mode
/// is a #GP).
pub fn idtGate(handler: u64) [2]u64 {
    const lo = (handler & 0xffff) |
        (@as(u64, kesel) << 16) |
        (@as(u64, 1) << 32) | // IST1
        (@as(u64, 0x8e) << 40) | // present, DPL 0, 64-bit interrupt gate
        ((handler >> 16 & 0xffff) << 48);
    return .{ lo, handler >> 32 };
}

// Control registers and EFER.
pub const CR0_PE: u64 = 1 << 0;
pub const CR0_MP: u64 = 1 << 1;
pub const CR0_ET: u64 = 1 << 4;
pub const CR0_NE: u64 = 1 << 5;
pub const CR0_WP: u64 = 1 << 16;
pub const CR0_PG: u64 = 1 << 31;
pub const cr0 = CR0_PE | CR0_MP | CR0_ET | CR0_NE | CR0_WP | CR0_PG;

pub const CR4_PAE: u64 = 1 << 5;
pub const CR4_OSFXSR: u64 = 1 << 9;
pub const CR4_OSXMMEXCPT: u64 = 1 << 10;
pub const CR4_SMEP: u64 = 1 << 20;
pub const CR4_SMAP: u64 = 1 << 21;

/// CR4 for a CPU with or without SMEP and SMAP.
pub fn cr4(smep: bool, smap: bool) u64 {
    var v = CR4_PAE | CR4_OSFXSR | CR4_OSXMMEXCPT;
    if (smep) v |= CR4_SMEP;
    if (smap) v |= CR4_SMAP;
    return v;
}

pub const EFER_SCE: u64 = 1 << 0;
pub const EFER_LME: u64 = 1 << 8;
pub const EFER_LMA: u64 = 1 << 10;
pub const EFER_NXE: u64 = 1 << 11;
pub const efer = EFER_SCE | EFER_LME | EFER_LMA | EFER_NXE;

/// RFLAGS bit 1 is always set.
pub const rflags_res1: u64 = 1 << 1;

// MSRs.
pub const MSR_STAR: u32 = 0xc000_0081;
pub const MSR_LSTAR: u32 = 0xc000_0082;
pub const MSR_CSTAR: u32 = 0xc000_0083;
pub const MSR_SFMASK: u32 = 0xc000_0084;
pub const MSR_FS_BASE: u32 = 0xc000_0100;
pub const MSR_GS_BASE: u32 = 0xc000_0101;
pub const MSR_KERNEL_GS_BASE: u32 = 0xc000_0102;

/// SYSCALL loads CS from STAR[47:32] and SS from the next selector.
/// SYSRET's selectors (STAR[63:48]) are 9front's, though the shim
/// returns with IRETQ.
pub const star: u64 = (@as(u64, ue32sel) << 48) | (@as(u64, kesel) << 32);
/// RFLAGS bits SYSCALL clears: IF, TF, DF, AC and NT.
pub const sfmask: u64 = (1 << 9) | (1 << 8) | (1 << 10) | (1 << 18) | (1 << 14);

/// The MSRs the host sets on every vCPU, with the shim at `shim_kva`.
/// GS_BASE (the shared page while the shim runs) is set with the
/// segment state; KERNEL_GS_BASE is what SWAPGS swaps in for user mode.
pub fn msrs(shim_kva: u64) [5]struct { u32, u64 } {
    return .{
        .{ MSR_STAR, star },
        .{ MSR_LSTAR, shim_kva + shim_syscall },
        .{ MSR_CSTAR, 0 },
        .{ MSR_SFMASK, sfmask },
        .{ MSR_KERNEL_GS_BASE, 0 },
    };
}

/// CPUID bits to clear before the guest sees them: XSAVE and the AVX
/// families, so user code uses only state that FXSAVE's image (h9's
/// vmm.Extra) carries across vCPUs.
pub const CpuidMask = struct { function: u32, eax: u32 = 0, ebx: u32 = 0, ecx: u32 = 0, edx: u32 = 0 };
pub const cpuid_clear = [_]CpuidMask{
    // FMA (12), XSAVE (26), OSXSAVE (27), AVX (28), F16C (29).
    .{ .function = 1, .ecx = (1 << 12) | (1 << 26) | (1 << 27) | (1 << 28) | (1 << 29) },
    // AVX2 (5) and the AVX-512 bits in EBX; the AVX-512 and VAES/VPCLMUL
    // bits in ECX; AVX-512 and AMX in EDX.
    .{
        .function = 7,
        .ebx = (1 << 5) | (1 << 16) | (1 << 17) | (1 << 21) | (1 << 26) | (1 << 27) | (1 << 28) | (1 << 30) | (1 << 31),
        .ecx = (1 << 1) | (1 << 6) | (1 << 9) | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 14),
        .edx = (1 << 2) | (1 << 3) | (1 << 8) | (1 << 22) | (1 << 23) | (1 << 24),
    },
};

/// CPUID leaves dropped: 0xD describes XSAVE's state components.
pub fn cpuidDropped(function: u32) bool {
    return function == 0xd;
}

/// Leaf 7 EBX bits for SMEP and SMAP.
pub const cpuid7_smep: u32 = 1 << 7;
pub const cpuid7_smap: u32 = 1 << 20;
