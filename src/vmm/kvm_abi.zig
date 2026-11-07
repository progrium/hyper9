//! The parts of Linux's KVM API (include/uapi/linux/kvm.h and the arch
//! headers) that vmm/kvm.zig uses, declared here so h9 needs no headers or
//! library to build: static musl builds keep working.

const std = @import("std");
const linux = std.os.linux;

pub const API_VERSION = 12;

const KVMIO = 0xAE;

fn io(nr: u8) u32 {
    return linux.IOCTL.IO(KVMIO, nr);
}
fn ior(nr: u8, comptime T: type) u32 {
    return linux.IOCTL.IOR(KVMIO, nr, T);
}
fn iow(nr: u8, comptime T: type) u32 {
    return linux.IOCTL.IOW(KVMIO, nr, T);
}
fn iowr(nr: u8, comptime T: type) u32 {
    return linux.IOCTL.IOWR(KVMIO, nr, T);
}

// System ioctls (on /dev/kvm).
pub const GET_API_VERSION = io(0x00);
pub const CREATE_VM = io(0x01);
pub const CHECK_EXTENSION = io(0x03);
pub const GET_VCPU_MMAP_SIZE = io(0x04);
pub const GET_SUPPORTED_CPUID = iowr(0x05, Cpuid2);

// VM ioctls.
pub const CREATE_VCPU = io(0x41);
pub const SET_USER_MEMORY_REGION = iow(0x46, UserspaceMemoryRegion);
pub const SET_TSS_ADDR = io(0x47);
pub const ARM_PREFERRED_TARGET = ior(0xaf, VcpuInit);

// vCPU ioctls.
pub const RUN = io(0x80);
pub const GET_REGS = ior(0x81, Regs);
pub const SET_REGS = iow(0x82, Regs);
pub const GET_SREGS = ior(0x83, Sregs);
pub const SET_SREGS = iow(0x84, Sregs);
pub const GET_MSRS = iowr(0x88, Msrs);
pub const SET_MSRS = iow(0x89, Msrs);
pub const SET_SIGNAL_MASK = iow(0x8b, SignalMask);
pub const GET_FPU = ior(0x8c, Fpu);
pub const SET_FPU = iow(0x8d, Fpu);
pub const SET_CPUID2 = iow(0x90, Cpuid2);
pub const GET_ONE_REG = iow(0xab, OneReg);
pub const SET_ONE_REG = iow(0xac, OneReg);
pub const ARM_VCPU_INIT = iow(0xae, VcpuInit);

// Capabilities, for CHECK_EXTENSION.
pub const CAP_USER_MEMORY = 3;
pub const CAP_NR_VCPUS = 9;
pub const CAP_MAX_VCPUS = 66;
pub const CAP_MAX_VCPU_ID = 128;
pub const CAP_IMMEDIATE_EXIT = 136;
pub const CAP_ARM_VM_IPA_SIZE = 165;

/// KVM_VM_TYPE_ARM_IPA_SIZE.
pub fn vmTypeArmIpaSize(bits: u8) usize {
    return bits;
}

// Exit reasons (kvm_run.exit_reason).
pub const EXIT_UNKNOWN = 0;
pub const EXIT_EXCEPTION = 1;
pub const EXIT_IO = 2;
pub const EXIT_HLT = 5;
pub const EXIT_MMIO = 6;
pub const EXIT_SHUTDOWN = 8;
pub const EXIT_FAIL_ENTRY = 9;
pub const EXIT_INTR = 10;
pub const EXIT_INTERNAL_ERROR = 17;
pub const EXIT_SYSTEM_EVENT = 24;

pub const EXIT_IO_OUT = 1;

pub const UserspaceMemoryRegion = extern struct {
    slot: u32,
    flags: u32,
    guest_phys_addr: u64,
    memory_size: u64,
    userspace_addr: u64,
};

/// The start of struct kvm_run, the vCPU's mmapped page, and the exits
/// that h9 reads from its union.
pub const Run = extern struct {
    request_interrupt_window: u8,
    immediate_exit: u8,
    _pad1: [6]u8,
    exit_reason: u32,
    ready_for_interrupt_injection: u8,
    if_flag: u8,
    flags: u16,
    cr8: u64,
    apic_base: u64,
    exit: extern union {
        io: extern struct {
            direction: u8,
            size: u8,
            port: u16,
            count: u32,
            data_offset: u64,
        },
        mmio: extern struct {
            phys_addr: u64,
            data: [8]u8,
            len: u32,
            is_write: u8,
        },
        fail_entry: extern struct {
            hardware_entry_failure_reason: u64,
            cpu: u32,
        },
        internal: extern struct {
            suberror: u32,
        },
        _pad: [256]u8,
    },

    comptime {
        std.debug.assert(@offsetOf(Run, "exit_reason") == 8);
        std.debug.assert(@offsetOf(Run, "exit") == 32);
    }
};

/// struct kvm_signal_mask: the length, followed by `len` bytes of sigset.
pub const SignalMask = extern struct {
    len: u32,
};

// ---- x86 ----

pub const Regs = extern struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    rsp: u64 = 0,
    rbp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
    rflags: u64 = 0,
};

pub const Segment = extern struct {
    base: u64 = 0,
    limit: u32 = 0,
    selector: u16 = 0,
    type: u8 = 0,
    present: u8 = 0,
    dpl: u8 = 0,
    db: u8 = 0,
    s: u8 = 0,
    l: u8 = 0,
    g: u8 = 0,
    avl: u8 = 0,
    unusable: u8 = 0,
    _pad: u8 = 0,
};

pub const Dtable = extern struct {
    base: u64 = 0,
    limit: u16 = 0,
    _pad: [3]u16 = @splat(0),
};

pub const Sregs = extern struct {
    cs: Segment,
    ds: Segment,
    es: Segment,
    fs: Segment,
    gs: Segment,
    ss: Segment,
    tr: Segment,
    ldt: Segment,
    gdt: Dtable,
    idt: Dtable,
    cr0: u64,
    cr2: u64,
    cr3: u64,
    cr4: u64,
    cr8: u64,
    efer: u64,
    apic_base: u64,
    interrupt_bitmap: [4]u64,

    comptime {
        std.debug.assert(@sizeOf(Sregs) == 312);
    }
};

pub const Fpu = extern struct {
    fpr: [8][16]u8,
    fcw: u16,
    fsw: u16,
    ftwx: u8,
    _pad1: u8,
    last_opcode: u16,
    last_ip: u64,
    last_dp: u64,
    xmm: [16][16]u8,
    mxcsr: u32,
    _pad2: u32,

    comptime {
        std.debug.assert(@sizeOf(Fpu) == 416);
    }
};

pub const MsrEntry = extern struct {
    index: u32,
    _reserved: u32 = 0,
    data: u64,
};

/// struct kvm_msrs with room for `n` entries.
pub fn MsrList(comptime n: usize) type {
    return extern struct {
        nmsrs: u32 = n,
        _pad: u32 = 0,
        entries: [n]MsrEntry,
    };
}

pub const Msrs = extern struct {
    nmsrs: u32,
    _pad: u32,
};

pub const CpuidEntry = extern struct {
    function: u32,
    index: u32,
    flags: u32,
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    _pad: [3]u32 = @splat(0),
};

pub const max_cpuid_entries = 256;

/// struct kvm_cpuid2 with room for `max_cpuid_entries`.
pub const CpuidList = extern struct {
    nent: u32 = max_cpuid_entries,
    _pad: u32 = 0,
    entries: [max_cpuid_entries]CpuidEntry = undefined,
};

pub const Cpuid2 = extern struct {
    nent: u32,
    _pad: u32,
};

// ---- arm64 ----

pub const VcpuInit = extern struct {
    target: u32 = 0,
    features: [7]u32 = @splat(0),
};

pub const OneReg = extern struct {
    id: u64,
    addr: u64,
};

const REG_ARM64: u64 = 0x6000_0000_0000_0000;
const REG_SIZE_U32: u64 = 0x0020_0000_0000_0000;
const REG_SIZE_U64: u64 = 0x0030_0000_0000_0000;
const REG_SIZE_U128: u64 = 0x0040_0000_0000_0000;
const REG_ARM_CORE: u64 = 0x0010 << 16;
const REG_ARM64_SYSREG: u64 = 0x0013 << 16;

/// A core register: `off` is the byte offset in arm64's struct kvm_regs.
fn core(size: u64, off: u64) u64 {
    return REG_ARM64 | size | REG_ARM_CORE | (off / 4);
}

// struct kvm_regs: user_pt_regs (regs[31], sp, pc, pstate), sp_el1,
// elr_el1, spsr[5], then fp_regs (vregs[32], fpsr, fpcr), 16-aligned.
pub fn armX(n: u5) u64 {
    return core(REG_SIZE_U64, @as(u64, n) * 8);
}
pub const ARM_SP = core(REG_SIZE_U64, 31 * 8);
pub const ARM_PC = core(REG_SIZE_U64, 32 * 8);
pub const ARM_PSTATE = core(REG_SIZE_U64, 33 * 8);
pub const ARM_SP_EL1 = core(REG_SIZE_U64, 34 * 8);
const fp_regs_off = 336;
pub fn armV(n: u5) u64 {
    return core(REG_SIZE_U128, fp_regs_off + @as(u64, n) * 16);
}
pub const ARM_FPSR = core(REG_SIZE_U32, fp_regs_off + 512);
pub const ARM_FPCR = core(REG_SIZE_U32, fp_regs_off + 516);

/// A system register in the op0:op1:CRn:CRm:op2 encoding HVF's
/// constants use too.
pub fn armSysreg(enc: u16) u64 {
    return REG_ARM64 | REG_SIZE_U64 | REG_ARM64_SYSREG | enc;
}

// ---- calls ----

/// ioctl(2), retrying on EINTR. Returns the result, or the errno.
pub fn ioctl(fd: i32, req: u32, arg: usize) union(enum) { ok: usize, err: linux.E } {
    while (true) {
        const rc = linux.ioctl(fd, req, arg);
        switch (linux.errno(rc)) {
            .SUCCESS => return .{ .ok = rc },
            .INTR => continue,
            else => |e| return .{ .err = e },
        }
    }
}

/// KVM_RUN. EINTR is returned, not retried.
pub fn run(fd: i32) linux.E {
    return linux.errno(linux.ioctl(fd, RUN, 0));
}
