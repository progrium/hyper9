//! Hypervisor.framework backend (macOS, arm64).
//!
//! Guest memory is one RAM region at ram_ipa (gphys.zig), with the arm64
//! tables and kernel half of pt_arm64.zig. This file holds only HVF's calls.

const std = @import("std");
const vmm = @import("../vmm.zig");
const arm64 = @import("../arch/arm64.zig");

const pt = @import("pt_arm64.zig");
const gphys = @import("gphys.zig");
const Shared = pt.Shared;

const ram_ipa: u64 = 0x8000_0000;
const doorbell_ipa: u64 = 0x1000_0000; // never mapped, so stores exit to the host

// ---- Hypervisor.framework ----

const hv_return_t = i32;
const HV_SUCCESS: hv_return_t = 0;
const HV_DENIED: hv_return_t = @bitCast(@as(u32, 0xfae94007));
const HV_UNSUPPORTED: hv_return_t = @bitCast(@as(u32, 0xfae9400f));

const HvExit = extern struct {
    reason: u32,
    syndrome: u64,
    virtual_address: u64,
    physical_address: u64,
};
const EXIT_CANCELED = 0;
const EXIT_EXCEPTION = 1;
const EXIT_VTIMER = 2;

const REG_X0 = 0;
const REG_PC = 31;
const REG_FPCR = 32;
const REG_FPSR = 33;
const REG_CPSR = 34;


extern "c" fn hv_vm_create(config: ?*anyopaque) hv_return_t;
extern "c" fn hv_vm_destroy() hv_return_t;
extern "c" fn hv_vm_map(addr: *anyopaque, ipa: u64, size: usize, flags: u64) hv_return_t;
extern "c" fn hv_vm_get_max_vcpu_count(max: *u32) hv_return_t;
extern "c" fn hv_vcpu_create(vcpu: *u64, exit: **HvExit, config: ?*anyopaque) hv_return_t;
extern "c" fn hv_vcpu_destroy(vcpu: u64) hv_return_t;
extern "c" fn hv_vcpu_run(vcpu: u64) hv_return_t;
extern "c" fn hv_vcpu_get_reg(vcpu: u64, reg: u32, value: *u64) hv_return_t;
extern "c" fn hv_vcpu_set_reg(vcpu: u64, reg: u32, value: u64) hv_return_t;
extern "c" fn hv_vcpu_set_sys_reg(vcpu: u64, reg: u16, value: u64) hv_return_t;
extern "c" fn hv_vcpu_get_sys_reg(vcpu: u64, reg: u16, value: *u64) hv_return_t;
// hv_simd_fp_uchar16_t is a 16-byte vector, passed in a SIMD register.
extern "c" fn hv_vcpu_get_simd_fp_reg(vcpu: u64, reg: u32, value: *@Vector(16, u8)) hv_return_t;
extern "c" fn hv_vcpu_set_simd_fp_reg(vcpu: u64, reg: u32, value: @Vector(16, u8)) hv_return_t;
extern "c" fn hv_vcpus_exit(vcpus: [*]const u64, count: u32) hv_return_t;

fn check(r: hv_return_t) vmm.Error!void {
    return switch (r) {
        HV_SUCCESS => {},
        HV_UNSUPPORTED, HV_DENIED => error.HypervisorUnavailable,
        else => error.HypervisorFailed,
    };
}

pub const Backend = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    ram: gphys.Ram,
    kernel_root: u64 = 0,
    slots: pt.Slots = .{},
    next_as_id: std.atomic.Value(u64) = .init(1),

    pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: vmm.Options) vmm.CreateError!*Backend {
        if (opts.arch != .arm64) return error.WrongArch;
        try check(hv_vm_create(null));
        errdefer _ = hv_vm_destroy();

        var ram: gphys.Ram = try .init(gpa, io, ram_ipa, opts.memory);
        errdefer ram.deinit();
        try check(hv_vm_map(ram.mem.ptr, ram_ipa, ram.mem.len, 0b111));

        const b = try gpa.create(Backend);
        errdefer gpa.destroy(b);
        b.* = .{ .gpa = gpa, .io = io, .ram = ram };
        b.kernel_root = try pt.kernelRoot(&b.ram, doorbell_ipa);
        return b;
    }

    pub fn destroy(b: *Backend) void {
        _ = hv_vm_destroy();
        b.ram.deinit();
        b.gpa.destroy(b);
    }

    pub fn maxVcpus(_: *Backend) vmm.Error!u32 {
        var n: u32 = 0;
        try check(hv_vm_get_max_vcpu_count(&n));
        return n;
    }

    pub fn allocPages(b: *Backend, n: usize) vmm.Error![]align(vmm.page_size) u8 {
        return b.ram.allocPages(n);
    }

    pub fn freePages(b: *Backend, mem: []align(vmm.page_size) u8) void {
        b.ram.freePages(mem);
    }

    pub fn newAddressSpace(b: *Backend) vmm.CreateError!*AddressSpace {
        return AddressSpace.create(&b.ram, b.next_as_id.fetchAdd(1, .monotonic) + 1, b.kernel_root);
    }

    /// Must be called on the thread that will run the vCPU.
    pub fn createVcpu(b: *Backend) vmm.CreateError!Vcpu {
        const index, const shared = try b.slots.take(&b.ram, b.kernel_root);
        errdefer b.slots.release(&b.ram, b.kernel_root, index, shared);

        const runner = try b.ram.runners.take(kickId, 0);
        errdefer b.ram.runners.release(runner);
        var v: Vcpu = .{ .id = 0, .exit = undefined, .shared = shared, .backend = b, .slot = index, .runner = runner };
        try check(hv_vcpu_create(&v.id, &v.exit, null));
        errdefer _ = hv_vcpu_destroy(v.id);
        b.ram.runners.setArg(runner, v.id);
        for (pt.sysregs(b.kernel_root, pt.sharedKva(index))) |r| try check(hv_vcpu_set_sys_reg(v.id, r[0], r[1]));
        return v;
    }
};

pub const AddressSpace = gphys.AddressSpace(pt);

/// A shootdown's kick (gphys.Runners): the vCPU's id.
fn kickId(id: u64) void {
    var x = id;
    _ = hv_vcpus_exit(@ptrCast(&x), 1);
}

pub const Vcpu = struct {
    id: u64,
    exit: *HvExit,
    shared: *Shared,
    backend: *Backend,
    slot: pt.Slots.Index,
    runner: gphys.Runners.Index,
    fresh: bool = true,
    /// The address space last run, and its epoch then; a change means a
    /// TLB flush before the next run.
    as: ?*AddressSpace = null,
    as_id: u64 = 0,
    epoch: u64 = 0,

    pub fn destroy(v: *Vcpu) void {
        _ = hv_vcpu_destroy(v.id);
        const b = v.backend;
        b.ram.runners.release(v.runner);
        b.slots.release(&b.ram, b.kernel_root, v.slot, v.shared);
    }

    pub fn setAddressSpace(v: *Vcpu, as: *AddressSpace) vmm.Error!void {
        if (v.as == as and v.as_id == as.id) return;
        try check(hv_vcpu_set_sys_reg(v.id, pt.SYS_TTBR0_EL1, as.root));
        v.as = as;
        v.as_id = as.id;
        v.epoch = as.epoch.load(.acquire);
        v.shared.flush = 1;
    }

    pub fn getUreg(v: *Vcpu, u: *vmm.Ureg) void {
        u.* = .{ .arm64 = v.shared.ureg };
    }

    pub fn setUreg(v: *Vcpu, u: *const vmm.Ureg) void {
        v.shared.ureg = u.arm64;
    }

    pub fn getExtra(v: *Vcpu, x: *vmm.Extra) vmm.Error!void {
        x.* = .{ .arm64 = .{} };
        const a = &x.arm64;
        for (&a.v, 0..) |*q, i| {
            var b: @Vector(16, u8) = undefined;
            try check(hv_vcpu_get_simd_fp_reg(v.id, @intCast(i), &b));
            q.* = @bitCast(b);
        }
        try check(hv_vcpu_get_reg(v.id, REG_FPCR, &a.fpcr));
        try check(hv_vcpu_get_reg(v.id, REG_FPSR, &a.fpsr));
        try check(hv_vcpu_get_sys_reg(v.id, pt.SYS_TPIDR_EL0, &a.tls));
    }

    pub fn setExtra(v: *Vcpu, x: *const vmm.Extra) vmm.Error!void {
        const a = &x.arm64;
        for (a.v, 0..) |q, i| try check(hv_vcpu_set_simd_fp_reg(v.id, @intCast(i), @bitCast(q)));
        try check(hv_vcpu_set_reg(v.id, REG_FPCR, a.fpcr));
        try check(hv_vcpu_set_reg(v.id, REG_FPSR, a.fpsr));
        try check(hv_vcpu_set_sys_reg(v.id, pt.SYS_TPIDR_EL0, a.tls));
    }

    /// Safe to call from any thread.
    pub fn kick(v: *Vcpu) void {
        _ = hv_vcpus_exit(@ptrCast(&v.id), 1);
    }

    pub fn run(v: *Vcpu) vmm.Error!vmm.Exit {
        const as = v.as orelse return error.BadAddress;
        const rs = &v.backend.ram.runners;
        rs.enter(v.runner, as);
        defer rs.leave(v.runner);
        const epoch = as.epoch.load(.seq_cst);
        if (epoch != v.epoch) {
            v.epoch = epoch;
            v.shared.flush = 1;
        }
        if (v.fresh) {
            // Enter through the shim, which loads the Ureg (and flushes).
            try check(hv_vcpu_set_reg(v.id, REG_PC, pt.kva_shim + pt.shim_enter));
            try check(hv_vcpu_set_reg(v.id, REG_CPSR, pt.psr_el1h));
            v.fresh = false;
        }
        while (true) {
            try check(hv_vcpu_run(v.id));
            switch (v.exit.reason) {
                EXIT_CANCELED => {
                    if (try v.stopped()) return .interrupted;
                    continue;
                },
                EXIT_VTIMER => continue,
                EXIT_EXCEPTION => {
                    const ec = v.exit.syndrome >> 26;
                    if (ec == arm64.EC_DABT_LOWER and v.exit.physical_address & ~@as(u64, 0xfff) == doorbell_ipa) {
                        var pc: u64 = 0;
                        try check(hv_vcpu_get_reg(v.id, REG_PC, &pc));
                        try check(hv_vcpu_set_reg(v.id, REG_PC, pc + 4));
                        return v.decode();
                    }
                    return .{ .other = v.exit.syndrome };
                },
                else => return .{ .other = v.exit.reason },
            }
        }
    }

    /// After a kick stopped the vCPU: works out where. In user mode its
    /// registers are live in HVF, not in the shared page, so they go to
    /// the Ureg and the next run re-enters the shim; otherwise a changed
    /// Ureg (a signal frame) would be ignored, and a pool vCPU would run
    /// on in the last process's registers under the next one's tables,
    /// with no TLB flush. In the shim's restore path the Ureg is already
    /// current. In its save path it's half written, so returns false: the
    /// caller runs on to the doorbell instead.
    fn stopped(v: *Vcpu) vmm.Error!bool {
        var pc: u64 = 0;
        try check(hv_vcpu_get_reg(v.id, REG_PC, &pc));
        if (pc >= pt.kva_shim) {
            const off = pc - pt.kva_shim;
            if (pt.shimSaving(off)) return false;
            if (off != pt.shim_enter) v.fresh = true;
            return true;
        }
        const u = &v.shared.ureg;
        for (&u.r, 0..) |*x, i| try check(hv_vcpu_get_reg(v.id, REG_X0 + @as(u32, @intCast(i)), x));
        try check(hv_vcpu_get_sys_reg(v.id, pt.SYS_SP_EL0, &u.sp));
        u.pc = pc;
        try check(hv_vcpu_get_reg(v.id, REG_CPSR, &u.psr));
        v.fresh = true;
        return true;
    }

    fn decode(v: *Vcpu) vmm.Exit {
        const s = v.shared;
        switch (s.why) {
            pt.why_el0 => {},
            pt.why_irq => return .interrupted,
            else => return .{ .other = s.ureg.type },
        }
        const esr = s.ureg.type;
        return switch (esr >> 26) {
            arm64.EC_SVC64 => .syscall,
            arm64.EC_BRK64, arm64.EC_BKPT_LOWER, arm64.EC_BKPT_SAME => .breakpoint,
            arm64.EC_IABT_LOWER => .{ .fault = .{ .addr = s.far, .access = .exec, .syndrome = esr } },
            arm64.EC_DABT_LOWER => .{ .fault = .{ .addr = s.far, .access = if (esr & (1 << 6) != 0) .write else .read, .syndrome = esr } },
            else => .{ .fault = .{ .addr = s.ureg.pc, .access = .exec, .syndrome = esr } },
        };
    }
};
