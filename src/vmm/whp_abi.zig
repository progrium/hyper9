//! The parts of the Windows Hypervisor Platform API (WinHvPlatform.h,
//! WinHvPlatformDefs.h) the WHP backend uses, x86_64 only.
//!
//! WinHvPlatform.dll exists only where the Windows Hypervisor Platform
//! feature is enabled, so h9.exe doesn't import it: `load` finds it with
//! LoadLibraryExW in the system directory and looks each function up.
//! Zig's MinGW has no import library for it either.
//!
//! The sizes are asserted below, from the C_ASSERTs in MinGW's
//! winhvplatformdefs.h; the enum values and field offsets were checked
//! against that header with a C compile of static asserts.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const HRESULT = i32;
pub const PartitionHandle = *opaque {};

pub fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

pub const E_ACCESSDENIED: HRESULT = @bitCast(@as(u32, 0x80070005));

// ---- Capabilities ----

pub const CapabilityCode = enum(u32) {
    hypervisor_present = 0x0000_0000,
    features = 0x0000_0001,
    processor_vendor = 0x0000_1000,
    processor_features = 0x0000_1001,
    processor_xsave_features = 0x0000_1003,
    _,
};

/// WHV_X64_PROCESSOR_FEATURES bits h9 reads.
pub const ProcessorFeatures = struct {
    pub const smep: u64 = 1 << 23;
    pub const smap: u64 = 1 << 35;
};

// ---- Partition properties ----

pub const PropertyCode = enum(u32) {
    extended_vm_exits = 0x0000_0001,
    exception_exit_bitmap = 0x0000_0002,
    processor_features = 0x0000_1001,
    cpuid_result_list = 0x0000_1004,
    local_apic_emulation_mode = 0x0000_1005,
    processor_xsave_features = 0x0000_1006,
    processor_count = 0x0000_1fff,
    _,
};

// ---- Memory ----

pub const MapGpaRangeFlags = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    track_dirty_pages: bool = false,
    _: u28 = 0,
};

// ---- Registers ----

pub const RegisterName = enum(u32) {
    rax = 0x00,
    rcx = 0x01,
    rdx = 0x02,
    rbx = 0x03,
    rsp = 0x04,
    rbp = 0x05,
    rsi = 0x06,
    rdi = 0x07,
    r8 = 0x08,
    r9 = 0x09,
    r10 = 0x0a,
    r11 = 0x0b,
    r12 = 0x0c,
    r13 = 0x0d,
    r14 = 0x0e,
    r15 = 0x0f,
    rip = 0x10,
    rflags = 0x11,
    es = 0x12,
    cs = 0x13,
    ss = 0x14,
    ds = 0x15,
    fs = 0x16,
    gs = 0x17,
    ldtr = 0x18,
    tr = 0x19,
    idtr = 0x1a,
    gdtr = 0x1b,
    cr0 = 0x1c,
    cr2 = 0x1d,
    cr3 = 0x1e,
    cr4 = 0x1f,
    cr8 = 0x20,
    xmm0 = 0x1000,
    xmm1 = 0x1001,
    xmm2 = 0x1002,
    xmm3 = 0x1003,
    xmm4 = 0x1004,
    xmm5 = 0x1005,
    xmm6 = 0x1006,
    xmm7 = 0x1007,
    xmm8 = 0x1008,
    xmm9 = 0x1009,
    xmm10 = 0x100a,
    xmm11 = 0x100b,
    xmm12 = 0x100c,
    xmm13 = 0x100d,
    xmm14 = 0x100e,
    xmm15 = 0x100f,
    fp_mmx0 = 0x1010,
    fp_mmx1 = 0x1011,
    fp_mmx2 = 0x1012,
    fp_mmx3 = 0x1013,
    fp_mmx4 = 0x1014,
    fp_mmx5 = 0x1015,
    fp_mmx6 = 0x1016,
    fp_mmx7 = 0x1017,
    fp_control_status = 0x1018,
    xmm_control_status = 0x1019,
    tsc = 0x2000,
    efer = 0x2001,
    kernel_gs_base = 0x2002,
    apic_base = 0x2003,
    pat = 0x2004,
    sysenter_cs = 0x2005,
    sysenter_eip = 0x2006,
    sysenter_esp = 0x2007,
    star = 0x2008,
    lstar = 0x2009,
    cstar = 0x200a,
    sfmask = 0x200b,
    _,

    pub fn xmm(i: usize) RegisterName {
        return @enumFromInt(@intFromEnum(RegisterName.xmm0) + i);
    }
    pub fn fpMmx(i: usize) RegisterName {
        return @enumFromInt(@intFromEnum(RegisterName.fp_mmx0) + i);
    }
};

/// WHV_X64_SEGMENT_REGISTER.
pub const SegmentRegister = extern struct {
    base: u64,
    limit: u32,
    selector: u16,
    /// Type 0-3, S 4, DPL 5-6, P 7, AVL 12, L 13, D/B 14, G 15.
    attributes: u16,
};

/// WHV_X64_TABLE_REGISTER.
pub const TableRegister = extern struct {
    pad: [3]u16 = @splat(0),
    limit: u16,
    base: u64,
};

/// WHV_X64_FP_CONTROL_STATUS_REGISTER.
pub const FpControlStatus = extern struct {
    fp_control: u16,
    fp_status: u16,
    /// The abridged tag word, as FXSAVE stores it.
    fp_tag: u8,
    reserved: u8 = 0,
    last_fp_op: u16,
    last_fp_rip: u64,
};

/// WHV_X64_XMM_CONTROL_STATUS_REGISTER.
pub const XmmControlStatus = extern struct {
    last_fp_rdp: u64,
    xmm_status_control: u32,
    xmm_status_control_mask: u32,
};

/// WHV_REGISTER_VALUE: 16 bytes, 16-byte aligned.
pub const RegisterValue = extern union {
    reg128: u128,
    reg64: u64,
    reg32: u32,
    segment: SegmentRegister,
    table: TableRegister,
    fp_control_status: FpControlStatus,
    xmm_control_status: XmmControlStatus,

    pub fn of64(v: u64) RegisterValue {
        var r: RegisterValue = .{ .reg128 = 0 };
        r.reg64 = v;
        return r;
    }
};

// ---- Running ----

pub const ExitReason = enum(u32) {
    none = 0x0000_0000,
    memory_access = 0x0000_0001,
    x64_io_port_access = 0x0000_0002,
    unrecoverable_exception = 0x0000_0004,
    invalid_vp_register_value = 0x0000_0005,
    unsupported_feature = 0x0000_0006,
    x64_interrupt_window = 0x0000_0007,
    x64_halt = 0x0000_0008,
    x64_apic_eoi = 0x0000_0009,
    x64_msr_access = 0x0000_1000,
    x64_cpuid = 0x0000_1001,
    exception = 0x0000_1002,
    x64_rdtsc = 0x0000_1003,
    canceled = 0x0000_2001,
    _,
};

/// WHV_X64_VP_EXIT_CONTEXT (WHV_VP_EXIT_CONTEXT).
pub const VpExitContext = extern struct {
    execution_state: u16,
    /// InstructionLength in bits 0-3, Cr8 in bits 4-7.
    instruction_length_cr8: u8,
    reserved: u8,
    reserved2: u32,
    cs: SegmentRegister,
    rip: u64,
    rflags: u64,

    pub fn instructionLength(c: *const VpExitContext) u64 {
        return c.instruction_length_cr8 & 0xf;
    }
};

/// WHV_X64_IO_PORT_ACCESS_CONTEXT.
pub const IoPortAccessContext = extern struct {
    instruction_byte_count: u8,
    reserved: [3]u8,
    instruction_bytes: [16]u8,
    /// IsWrite in bit 0, AccessSize in bits 1-3, StringOp 4, RepPrefix 5.
    access_info: u32,
    port_number: u16,
    reserved2: [3]u16,
    rax: u64,
    rcx: u64,
    rsi: u64,
    rdi: u64,
    ds: SegmentRegister,
    es: SegmentRegister,

    pub fn isWrite(c: *const IoPortAccessContext) bool {
        return c.access_info & 1 != 0;
    }
};

/// WHV_RUN_VP_EXIT_CONTEXT, x86_64.
pub const RunVpExitContext = extern struct {
    exit_reason: ExitReason,
    reserved: u32,
    vp_context: VpExitContext,
    u: extern union {
        io_port_access: IoPortAccessContext,
        as_u64: [22]u64,
    },
};

comptime {
    const assert = std.debug.assert;
    assert(@sizeOf(SegmentRegister) == 16);
    assert(@sizeOf(TableRegister) == 16);
    assert(@offsetOf(TableRegister, "limit") == 6);
    assert(@sizeOf(FpControlStatus) == 16);
    assert(@sizeOf(XmmControlStatus) == 16);
    assert(@sizeOf(RegisterValue) == 16);
    assert(@alignOf(RegisterValue) == 16);
    assert(@sizeOf(VpExitContext) == 40);
    assert(@offsetOf(VpExitContext, "rip") == 24);
    assert(@sizeOf(IoPortAccessContext) == 96);
    assert(@offsetOf(IoPortAccessContext, "port_number") == 24);
    assert(@offsetOf(IoPortAccessContext, "rax") == 32);
    assert(@sizeOf(RunVpExitContext) == 224);
    assert(@offsetOf(RunVpExitContext, "vp_context") == 8);
    assert(@offsetOf(RunVpExitContext, "u") == 48);
}

// ---- The functions, looked up at run time ----

const cc: std.builtin.CallingConvention = .winapi;

pub const Api = struct {
    WHvGetCapability: *const fn (code: CapabilityCode, buf: *anyopaque, size: u32, written: ?*u32) callconv(cc) HRESULT,
    WHvCreatePartition: *const fn (partition: *?PartitionHandle) callconv(cc) HRESULT,
    WHvSetupPartition: *const fn (partition: PartitionHandle) callconv(cc) HRESULT,
    WHvDeletePartition: *const fn (partition: PartitionHandle) callconv(cc) HRESULT,
    WHvSetPartitionProperty: *const fn (partition: PartitionHandle, code: PropertyCode, buf: *const anyopaque, size: u32) callconv(cc) HRESULT,
    WHvMapGpaRange: *const fn (partition: PartitionHandle, source: *anyopaque, gpa: u64, size: u64, flags: MapGpaRangeFlags) callconv(cc) HRESULT,
    WHvUnmapGpaRange: *const fn (partition: PartitionHandle, gpa: u64, size: u64) callconv(cc) HRESULT,
    WHvCreateVirtualProcessor: *const fn (partition: PartitionHandle, index: u32, flags: u32) callconv(cc) HRESULT,
    WHvDeleteVirtualProcessor: *const fn (partition: PartitionHandle, index: u32) callconv(cc) HRESULT,
    WHvRunVirtualProcessor: *const fn (partition: PartitionHandle, index: u32, exit: *RunVpExitContext, size: u32) callconv(cc) HRESULT,
    WHvCancelRunVirtualProcessor: *const fn (partition: PartitionHandle, index: u32, flags: u32) callconv(cc) HRESULT,
    WHvGetVirtualProcessorRegisters: *const fn (partition: PartitionHandle, index: u32, names: [*]const RegisterName, count: u32, values: [*]RegisterValue) callconv(cc) HRESULT,
    WHvSetVirtualProcessorRegisters: *const fn (partition: PartitionHandle, index: u32, names: [*]const RegisterName, count: u32, values: [*]const RegisterValue) callconv(cc) HRESULT,
};

const LOAD_LIBRARY_SEARCH_SYSTEM32: u32 = 0x0000_0800;

extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?windows.HANDLE, flags: u32) callconv(cc) ?windows.HMODULE;
extern "kernel32" fn GetProcAddress(module: windows.HMODULE, name: [*:0]const u8) callconv(cc) ?*const anyopaque;

var api: Api = undefined;
var loaded: enum(u8) { not_yet, ok, missing } = .not_yet;
var load_lock: std.atomic.Mutex = .unlocked;

/// Loads WinHvPlatform.dll from the system directory (never from beside
/// h9.exe or the current directory) and looks up every function. Null if
/// the DLL or any function is missing: the feature isn't enabled, or
/// Windows is too old. The DLL stays loaded for the life of the process.
pub fn load() ?*const Api {
    while (!load_lock.tryLock()) std.atomic.spinLoopHint();
    defer load_lock.unlock();
    switch (loaded) {
        .ok => return &api,
        .missing => return null,
        .not_yet => {},
    }
    loaded = .missing;
    const dll = LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("WinHvPlatform.dll"), null, LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return null;
    inline for (@typeInfo(Api).@"struct".fields) |f| {
        const p = GetProcAddress(dll, f.name) orelse return null;
        @field(api, f.name) = @ptrCast(@alignCast(p));
    }
    loaded = .ok;
    return &api;
}

comptime {
    std.debug.assert(builtin.os.tag == .windows and builtin.cpu.arch == .x86_64);
}
