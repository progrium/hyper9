//! Windows Hypervisor Platform backend (Windows, x86_64). See
//! design/0017-whp.md.
//!
//! It runs the amd64 shim, page tables and CPU state that the KVM backend
//! runs on x86_64 (x86.zig, pt_amd64.zig, src/arch/amd64/shim.S), setting
//! the state through WHP's register calls instead of KVM's ioctls. Guest
//! memory is one RAM region at ram_gpa (gphys.zig), mapped into the
//! partition once.
//!
//! WinHvPlatform.dll is loaded at run time (whp_abi.load), so h9.exe starts
//! on machines without the feature and `auto` falls back to the emulator.
//!
//! As on KVM, destroyed vCPUs are parked and reset for their next user,
//! which keeps their shared pages mapped in the kernel half.

const std = @import("std");
const vmm = @import("../vmm.zig");
const gphys = @import("gphys.zig");
const pt = @import("pt_amd64.zig");
const x86 = @import("x86.zig");
const abi = @import("whp_abi.zig");

/// KVM's: guest RAM starts at 2 GiB.
const ram_gpa: u64 = 0x8000_0000;

/// The partition's processor count, fixed before WHvSetupPartition, and so
/// the vCPU limit: HVF's measured limit, which the vCPU pool is shaped
/// around. WHP's own limit is an open issue in the proposal.
pub const processor_count: u32 = 64;

fn check(hr: abi.HRESULT) vmm.Error!void {
    if (abi.succeeded(hr)) return;
    return switch (hr) {
        abi.E_ACCESSDENIED => error.HypervisorUnavailable,
        else => error.HypervisorFailed,
    };
}

pub const Backend = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    api: *const abi.Api,
    partition: abi.PartitionHandle,
    ram: gphys.Ram,
    kernel_root: u64 = 0,
    cr4: u64,
    /// Guards the vCPU lists and the kernel tables.
    lock: std.atomic.Mutex = .unlocked,
    /// Every vCPU this partition has created, indexed by processor index,
    /// which is also its shared-page slot.
    all: std.ArrayList(*State) = .empty,
    /// Destroyed vCPUs, waiting to be reused.
    parked: std.ArrayList(*State) = .empty,
    next_as_id: std.atomic.Value(u64) = .init(1),

    fn lockSpin(b: *Backend) void {
        while (!b.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: vmm.Options) vmm.CreateError!*Backend {
        if (opts.arch != .amd64) return error.WrongArch;
        const api = abi.load() orelse return error.HypervisorUnavailable;

        var present: u32 = 0;
        if (!abi.succeeded(api.WHvGetCapability(.hypervisor_present, &present, @sizeOf(u32), null)) or present == 0)
            return error.HypervisorUnavailable;
        // SMEP and SMAP where the CPU has them; without the capability,
        // neither.
        var features: u64 = 0;
        if (!abi.succeeded(api.WHvGetCapability(.processor_features, &features, @sizeOf(u64), null))) features = 0;

        var part: ?abi.PartitionHandle = null;
        try check(api.WHvCreatePartition(&part));
        const p = part.?;
        errdefer _ = api.WHvDeletePartition(p);
        const count: u32 = processor_count;
        try check(api.WHvSetPartitionProperty(p, .processor_count, &count, @sizeOf(u32)));
        // Hide XSAVE and AVX from CPUID, as KVM's CPUID mask does, so user
        // code uses only state the FXSAVE image carries. CR4.OSXSAVE stays
        // clear either way, which is what keeps AVX off; this only stops a
        // program from seeing features it can't use, so a host that
        // refuses it is fine.
        const no_xsave: u64 = 0;
        _ = api.WHvSetPartitionProperty(p, .processor_xsave_features, &no_xsave, @sizeOf(u64));
        try check(api.WHvSetupPartition(p));

        var ram: gphys.Ram = try .init(gpa, io, ram_gpa, opts.memory);
        errdefer ram.deinit();
        try check(api.WHvMapGpaRange(p, ram.mem.ptr, ram_gpa, ram.mem.len, .{ .read = true, .write = true, .execute = true }));

        const b = try gpa.create(Backend);
        errdefer gpa.destroy(b);
        b.* = .{
            .gpa = gpa,
            .io = io,
            .api = api,
            .partition = p,
            .ram = ram,
            .cr4 = x86.cr4(features & abi.ProcessorFeatures.smep != 0, features & abi.ProcessorFeatures.smap != 0),
        };
        b.kernel_root = try pt.kernelRoot(&b.ram);
        return b;
    }

    pub fn destroy(b: *Backend) void {
        for (b.all.items) |s| {
            _ = b.api.WHvDeleteVirtualProcessor(b.partition, s.slot);
            b.gpa.destroy(s);
        }
        b.all.deinit(b.gpa);
        b.parked.deinit(b.gpa);
        _ = b.api.WHvDeletePartition(b.partition);
        b.ram.deinit();
        b.gpa.destroy(b);
    }

    pub fn maxVcpus(_: *Backend) vmm.Error!u32 {
        return processor_count;
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

    /// Takes a parked vCPU, or creates one, and resets it. WHP doesn't tie
    /// a vCPU to a thread, but h9's rule (create, run and destroy on one
    /// thread) holds anyway.
    pub fn createVcpu(b: *Backend) vmm.CreateError!Vcpu {
        const parked = blk: {
            b.lockSpin();
            defer b.lock.unlock();
            break :blk b.parked.pop();
        };
        const s = parked orelse try b.newVcpu();
        errdefer b.park(s);
        try s.reset();
        s.runner = try b.ram.runners.take(kickState, @intFromPtr(s));
        return .{ .s = s };
    }

    fn park(b: *Backend, s: *State) void {
        b.lockSpin();
        defer b.lock.unlock();
        // On failure the vCPU stays in `all` only, unused until the end.
        b.parked.append(b.gpa, s) catch {};
    }

    /// Creates a vCPU at the next processor index, with its shared page.
    fn newVcpu(b: *Backend) vmm.CreateError!*State {
        const s = try b.gpa.create(State);
        errdefer b.gpa.destroy(s);
        b.lockSpin();
        defer b.lock.unlock();
        const slot: u32 = @intCast(b.all.items.len);
        if (slot >= processor_count) return error.HypervisorFailed;
        try b.all.ensureUnusedCapacity(b.gpa, 1);
        try b.parked.ensureTotalCapacity(b.gpa, b.all.items.len + 1);

        const page = try b.ram.allocPages(1);
        errdefer b.ram.freePages(page);
        // A failure past here leaves the page mapped in the kernel half,
        // unused: the slot is never handed out again.
        try pt.mapShared(&b.ram, b.kernel_root, slot, page);
        try check(b.api.WHvCreateVirtualProcessor(b.partition, slot, 0));
        s.* = .{ .backend = b, .slot = slot, .shared = @ptrCast(page.ptr) };
        b.all.appendAssumeCapacity(s);
        return s;
    }
};

pub const AddressSpace = gphys.AddressSpace(pt);

/// WHV_X64_SEGMENT_REGISTER's attributes: the descriptor's access byte
/// and flags nibble, as VMX lays them out.
fn segment(x: x86.Segment) abi.RegisterValue {
    const attrs: u16 = @as(u16, x.type) |
        @as(u16, @intFromBool(x.s)) << 4 |
        @as(u16, x.dpl) << 5 |
        @as(u16, @intFromBool(x.present)) << 7 |
        @as(u16, @intFromBool(x.l)) << 13 |
        @as(u16, @intFromBool(x.db)) << 14 |
        @as(u16, @intFromBool(x.g)) << 15;
    return .{ .segment = .{ .base = x.base, .limit = x.limit, .selector = x.selector, .attributes = attrs } };
}

fn tableReg(base: u64, limit: u16) abi.RegisterValue {
    return .{ .table = .{ .base = base, .limit = limit } };
}

fn msrName(index: u32) abi.RegisterName {
    return switch (index) {
        x86.MSR_STAR => .star,
        x86.MSR_LSTAR => .lstar,
        x86.MSR_CSTAR => .cstar,
        x86.MSR_SFMASK => .sfmask,
        x86.MSR_KERNEL_GS_BASE => .kernel_gs_base,
        else => unreachable,
    };
}

/// The FXSAVE image's registers and FS (whose base is the TLS pointer), in
/// the order getExtra and setExtra use.
const extra_names = blk: {
    var n: [8 + 1 + 16 + 1 + 1]abi.RegisterName = undefined;
    for (0..8) |i| n[i] = abi.RegisterName.fpMmx(i);
    n[8] = .fp_control_status;
    for (0..16) |i| n[9 + i] = abi.RegisterName.xmm(i);
    n[25] = .xmm_control_status;
    n[26] = .fs;
    break :blk n;
};

/// The general registers in WHP's order (rax to r15), then RIP and RFLAGS:
/// what a stop in user mode copies into the Ureg.
const user_names = blk: {
    var n: [18]abi.RegisterName = undefined;
    for (0..16) |i| n[i] = @enumFromInt(i);
    n[16] = .rip;
    n[17] = .rflags;
    break :blk n;
};

/// A vCPU's state, kept across its users.
/// Kicks the vCPU whose State is at `arg`, from any thread; also a
/// shootdown's kick (gphys.Runners).
fn kickState(arg: u64) void {
    const s: *State = @ptrFromInt(arg);
    s.kicked.store(true, .seq_cst);
    _ = s.backend.api.WHvCancelRunVirtualProcessor(s.backend.partition, s.slot, 0);
}

const State = struct {
    backend: *Backend,
    /// The processor index, which is also the shared-page slot.
    slot: u32,
    /// Its slot in the backend's gphys.Runners, while in use.
    runner: gphys.Runners.Index = 0,
    shared: *x86.Shared,
    /// Set by `kick`, checked before entering the guest: a cancel that
    /// arrives while the vCPU isn't running may not stop the next run.
    kicked: std.atomic.Value(bool) = .init(false),
    /// The address space last run, and its epoch then; a change means the
    /// shim reloads CR3 before the next return to user mode.
    as: ?*AddressSpace = null,
    as_id: u64 = 0,
    epoch: u64 = 0,
    /// The vCPU was stopped outside the shim's save path: enter the shim
    /// at `restore` before the next run, so it loads the Ureg.
    reenter: bool = false,

    fn sharedKva(s: *const State) u64 {
        return pt.sharedKva(s.slot);
    }

    fn setRegs(s: *const State, names: []const abi.RegisterName, values: []const abi.RegisterValue) vmm.Error!void {
        const b = s.backend;
        try check(b.api.WHvSetVirtualProcessorRegisters(b.partition, s.slot, names.ptr, @intCast(names.len), values.ptr));
    }

    fn getRegs(s: *const State, names: []const abi.RegisterName, values: []abi.RegisterValue) vmm.Error!void {
        const b = s.backend;
        try check(b.api.WHvGetVirtualProcessorRegisters(b.partition, s.slot, names.ptr, @intCast(names.len), values.ptr));
    }

    /// Puts the vCPU in the state a new one starts in: long mode, ring 0,
    /// at the shim's `restore`, with no user state from its last user.
    fn reset(s: *State) vmm.Error!void {
        const b = s.backend;
        s.kicked.store(false, .seq_cst);
        s.as = null;
        s.as_id = 0;
        s.epoch = 0;
        s.reenter = false;
        s.shared.ureg = .{};
        s.shared.far = 0;
        s.shared.why = 0;
        s.shared.next_cr3 = 0;

        const kva = s.sharedKva();
        var gs = x86.null_data;
        gs.base = kva;
        // Not present, which WHP takes as unusable.
        const ldt: x86.Segment = .{ .selector = 0, .limit = 0, .type = 2, .s = false, .present = false, .g = false };
        const msrs = x86.msrs(pt.kva_shim);
        var names: [16 + msrs.len]abi.RegisterName = undefined;
        var values: [names.len]abi.RegisterValue = undefined;
        const fixed = [16]struct { abi.RegisterName, abi.RegisterValue }{
            .{ .cr0, .of64(x86.cr0) },
            .{ .cr3, .of64(b.kernel_root) },
            .{ .cr4, .of64(b.cr4) },
            .{ .efer, .of64(x86.efer) },
            .{ .cs, segment(x86.code64) },
            .{ .ss, segment(x86.data) },
            .{ .ds, segment(x86.null_data) },
            .{ .es, segment(x86.null_data) },
            .{ .gs, segment(gs) },
            .{ .tr, segment(x86.tr(kva + x86.tss_off)) },
            .{ .ldtr, segment(ldt) },
            .{ .gdtr, tableReg(kva + x86.gdt_off, x86.ngdt * 8 - 1) },
            .{ .idtr, tableReg(pt.kva_idt, x86.nvectors * 16 - 1) },
            .{ .rip, .of64(pt.kva_shim + x86.shim_restore) },
            .{ .rsp, .of64(kva + x86.stack_top) },
            .{ .rflags, .of64(x86.rflags_res1) },
        };
        for (fixed, 0..) |f, i| {
            names[i] = f[0];
            values[i] = f[1];
        }
        for (msrs, fixed.len..) |m, i| {
            names[i] = msrName(m[0]);
            values[i] = .of64(m[1]);
        }
        try s.setRegs(&names, &values);
        // The FPU at its reset values, and FS with a zero base.
        try s.setExtra(&vmm.X86Extra.init);
    }

    /// After a stop in user mode (or in the shim's restore path): back to
    /// ring 0, with the kernel GS base, at `restore`.
    fn reenterShim(s: *State) vmm.Error!void {
        const kva = s.sharedKva();
        var gs = x86.null_data;
        gs.base = kva;
        try s.setRegs(&.{ .cs, .ss, .gs, .kernel_gs_base, .rip, .rsp, .rflags }, &.{
            segment(x86.code64),
            segment(x86.data),
            segment(gs),
            .of64(0),
            .of64(pt.kva_shim + x86.shim_restore),
            .of64(kva + x86.stack_top),
            .of64(x86.rflags_res1),
        });
    }

    fn setExtra(s: *State, t: *const vmm.X86Extra) vmm.Error!void {
        var vals: [extra_names.len]abi.RegisterValue = undefined;
        for (vals[0..8], t.fx.st) |*r, st| {
            var bytes: [16]u8 = @splat(0);
            @memcpy(bytes[0..10], st[0..10]);
            r.* = .{ .reg128 = @bitCast(bytes) };
        }
        vals[8] = .{ .fp_control_status = .{
            .fp_control = t.fx.fcw,
            .fp_status = t.fx.fsw,
            .fp_tag = t.fx.ftw,
            .last_fp_op = t.fx.fop,
            .last_fp_rip = t.fx.fip,
        } };
        for (vals[9..25], t.fx.xmm) |*r, q| r.* = .{ .reg128 = q };
        vals[25] = .{
            .xmm_control_status = .{
                .last_fp_rdp = t.fx.fdp,
                // Reserved MXCSR bits would make the load fail, as on KVM.
                .xmm_status_control = t.fx.mxcsr & 0xffff,
                // Read-only in hardware; WHP may ignore or check it.
                .xmm_status_control_mask = 0,
            },
        };
        var fs = x86.null_data;
        fs.base = t.tls;
        vals[26] = segment(fs);
        try s.setRegs(&extra_names, &vals);
    }
};

pub const Vcpu = struct {
    s: *State,

    /// Parks the vCPU for reuse, keeping its processor and shared page.
    pub fn destroy(v: *Vcpu) void {
        v.s.backend.ram.runners.release(v.s.runner);
        v.s.backend.park(v.s);
    }

    pub fn setAddressSpace(v: *Vcpu, as: *AddressSpace) vmm.Error!void {
        const s = v.s;
        if (s.as == as and s.as_id == as.id) return;
        s.shared.next_cr3 = as.root;
        s.as = as;
        s.as_id = as.id;
        s.epoch = as.epoch.load(.acquire);
    }

    pub fn getUreg(v: *Vcpu, u: *vmm.Ureg) void {
        u.* = .{ .amd64 = v.s.shared.ureg };
    }

    pub fn setUreg(v: *Vcpu, u: *const vmm.Ureg) void {
        v.s.shared.ureg = u.amd64;
    }

    /// The FXSAVE image and FS base, in one batch.
    pub fn getExtra(v: *Vcpu, x: *vmm.Extra) vmm.Error!void {
        var vals: [extra_names.len]abi.RegisterValue = undefined;
        try v.s.getRegs(&extra_names, &vals);
        x.* = .{ .amd64 = .{} };
        const t = &x.amd64;
        for (&t.fx.st, vals[0..8]) |*st, r| {
            const bytes: [16]u8 = @bitCast(r.reg128);
            st.* = @splat(0);
            @memcpy(st[0..10], bytes[0..10]);
        }
        const fcs = vals[8].fp_control_status;
        t.fx.fcw = fcs.fp_control;
        t.fx.fsw = fcs.fp_status;
        t.fx.ftw = fcs.fp_tag;
        t.fx.fop = fcs.last_fp_op;
        t.fx.fip = fcs.last_fp_rip;
        for (&t.fx.xmm, vals[9..25]) |*q, r| q.* = r.reg128;
        const xcs = vals[25].xmm_control_status;
        t.fx.fdp = xcs.last_fp_rdp;
        t.fx.mxcsr = xcs.xmm_status_control;
        // KVM reports this too, so the two backends' images match.
        t.fx.mxcsr_mask = 0xffff;
        t.tls = vals[26].segment.base;
    }

    pub fn setExtra(v: *Vcpu, x: *const vmm.Extra) vmm.Error!void {
        try v.s.setExtra(&x.amd64);
    }

    /// Safe to call from any thread.
    pub fn kick(v: *Vcpu) void {
        kickState(@intFromPtr(v.s));
    }

    pub fn run(v: *Vcpu) vmm.Error!vmm.Exit {
        const s = v.s;
        const b = s.backend;
        const as = s.as orelse return error.BadAddress;
        const rs = &b.ram.runners;
        rs.enter(s.runner, as);
        defer rs.leave(s.runner);
        const epoch = as.epoch.load(.seq_cst);
        if (epoch != s.epoch) {
            s.epoch = epoch;
            s.shared.next_cr3 = as.root;
        }
        if (s.reenter) {
            try s.reenterShim();
            s.reenter = false;
        }
        if (s.kicked.swap(false, .seq_cst)) return .interrupted;
        while (true) {
            var exit: abi.RunVpExitContext = undefined;
            try check(b.api.WHvRunVirtualProcessor(b.partition, s.slot, &exit, @sizeOf(abi.RunVpExitContext)));
            switch (exit.exit_reason) {
                .x64_io_port_access => {
                    const io = &exit.u.io_port_access;
                    if (io.port_number != x86.doorbell_port or !io.isWrite())
                        return .{ .other = @intFromEnum(exit.exit_reason) };
                    // WHP leaves RIP on the `out`; the shim continues past
                    // it, at `restore`, on the next run.
                    const rip = exit.vp_context.rip + exit.vp_context.instructionLength();
                    try s.setRegs(&.{.rip}, &.{.of64(rip)});
                    return decode(s.shared);
                },
                .canceled => {
                    s.kicked.store(false, .seq_cst);
                    if (try v.stopped(exit.vp_context.rip)) return .interrupted;
                    continue;
                },
                .none => continue,
                else => return .{ .other = @intFromEnum(exit.exit_reason) },
            }
        }
    }

    /// After a run canceled by a kick at `rip`: works out where the vCPU
    /// stopped. In user mode, the registers go to the Ureg and the next
    /// run re-enters the shim, so a changed Ureg takes effect. In the
    /// shim's restore path, the Ureg is already current. In its save path,
    /// the Ureg is half written, so returns false: the caller runs on to
    /// the doorbell instead. KVM's `stopped`, through WHP's register calls.
    fn stopped(v: *Vcpu, rip: u64) vmm.Error!bool {
        const s = v.s;
        if (rip >= pt.kva_shim) {
            const off = rip - pt.kva_shim;
            if (off <= x86.shim_doorbell) return false;
            if (off != x86.shim_restore) s.reenter = true;
            return true;
        }
        var vals: [user_names.len]abi.RegisterValue = undefined;
        try s.getRegs(&user_names, &vals);
        const u = &s.shared.ureg;
        u.ax = vals[0].reg64;
        u.cx = vals[1].reg64;
        u.dx = vals[2].reg64;
        u.bx = vals[3].reg64;
        u.sp = vals[4].reg64;
        u.bp = vals[5].reg64;
        u.si = vals[6].reg64;
        u.di = vals[7].reg64;
        u.r8 = vals[8].reg64;
        u.r9 = vals[9].reg64;
        u.r10 = vals[10].reg64;
        u.r11 = vals[11].reg64;
        u.r12 = vals[12].reg64;
        u.r13 = vals[13].reg64;
        u.r14 = vals[14].reg64;
        u.r15 = vals[15].reg64;
        u.pc = vals[16].reg64;
        u.flags = vals[17].reg64;
        s.reenter = true;
        return true;
    }
};

/// The exit the shim's doorbell reports, as KVM decodes it.
fn decode(s: *const x86.Shared) vmm.Exit {
    return switch (s.why) {
        x86.why_syscall => .syscall,
        x86.why_trap => if (s.ureg.type == x86.vector_pf)
            .{ .fault = .{
                .addr = s.far,
                .access = if (s.ureg.@"error" & 0x10 != 0) .exec else if (s.ureg.@"error" & 2 != 0) .write else .read,
                .syndrome = s.ureg.@"error",
            } }
        else if (s.ureg.type == x86.vector_bp)
            .breakpoint
        else
            .{ .fault = .{ .addr = s.ureg.pc, .access = .exec, .syndrome = s.ureg.type } },
        else => .{ .other = s.ureg.type },
    };
}
