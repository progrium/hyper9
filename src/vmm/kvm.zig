//! KVM backend (Linux, arm64 and x86_64). See design/0016-kvm.md.
//!
//! Guest memory is one RAM region at ram_gpa (gphys.zig), mapped once as
//! KVM memory slot 0. On arm64 the tables, kernel half, shim and system
//! register values are HVF's (pt_arm64.zig), set with KVM_SET_ONE_REG. On
//! x86_64 they're pt_amd64.zig's and x86.zig's: the host puts the vCPU in
//! long mode at ring 0 in the amd64 shim, which only saves and restores
//! user state around the doorbell.
//!
//! KVM can't destroy a single vCPU, and the vCPUs a VM ever created count
//! against its limit, so destroyed vCPUs are parked on a free list and
//! reset for their next user.
//!
//! Kicks set kvm_run.immediate_exit and send the vCPU's thread
//! `kickSignal()`, which h9 keeps blocked on vCPU threads except inside
//! KVM_RUN (KVM_SET_SIGNAL_MASK), so it can only interrupt the guest.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const vmm = @import("../vmm.zig");
const abi = @import("kvm_abi.zig");
const gphys = @import("gphys.zig");
const arm64 = @import("../arch/arm64.zig");

const is_x86 = builtin.cpu.arch == .x86_64;
const pt = if (is_x86) @import("pt_amd64.zig") else @import("pt_arm64.zig");
const x86 = @import("x86.zig");
const Shared = if (is_x86) x86.Shared else pt.Shared;

/// The 9front architecture KVM runs here.
const guest_arch: vmm.Arch = if (is_x86) .amd64 else .arm64;

const ram_gpa: u64 = 0x8000_0000;
/// arm64: the doorbell's IPA, never mapped, so the shim's store to it is
/// an MMIO exit.
const doorbell_ipa: u64 = 0x1000_0000;
/// x86: the three pages KVM_SET_TSS_ADDR wants (for real-mode emulation on
/// Intel, which h9 never uses), below 4 GiB and outside RAM.
const tss_addr: u64 = 0xfffb_d000;

/// File descriptors kept back from the vCPU budget for everything else.
const fd_margin = 256;

/// The signal that kicks a vCPU out of KVM_RUN. Embedders must keep it
/// blocked in threads that call into a machine; h9 blocks it in every
/// vCPU thread.
pub fn kickSignal() u32 {
    return @as(u32, std.c.sigrtmin()) + 1;
}

/// Why KVM can't be used here, for `--check` and the CLI's messages, or
/// null if /dev/kvm looks usable.
pub fn whyUnavailable() ?[]const u8 {
    const rc = linux.access("/dev/kvm", linux.R_OK | linux.W_OK);
    return switch (linux.errno(rc)) {
        .SUCCESS => null,
        .NOENT, .NODEV, .NXIO => "no /dev/kvm (no KVM in this kernel, or a VM without nested virtualization)",
        .ACCES, .PERM => "no access to /dev/kvm (is your user in the kvm group?)",
        else => null,
    };
}

fn ioctl(fd: i32, req: u32, arg: usize) vmm.Error!usize {
    return switch (abi.ioctl(fd, req, arg)) {
        .ok => |n| n,
        .err => error.HypervisorFailed,
    };
}

fn checkExtension(fd: i32, cap: usize) usize {
    return switch (abi.ioctl(fd, abi.CHECK_EXTENSION, cap)) {
        .ok => |n| n,
        .err => 0,
    };
}

fn closeFd(fd: i32) void {
    _ = linux.close(fd);
}

var handler_installed: std.atomic.Value(bool) = .init(false);

fn onKick(_: linux.SIG) callconv(.c) void {}

/// The kick signal never reaches its handler (it's blocked again before
/// KVM_RUN returns), but a handler keeps its default action, which would
/// end the process, out of the picture.
fn installHandler() void {
    if (handler_installed.swap(true, .acq_rel)) return;
    const act: linux.Sigaction = .{
        .handler = .{ .handler = onKick },
        .mask = linux.sigemptyset(),
        .flags = linux.SA.RESTART,
    };
    _ = linux.sigaction(@enumFromInt(kickSignal()), &act, null);
}

fn kickSet() linux.sigset_t {
    var set = linux.sigemptyset();
    linux.sigaddset(&set, @enumFromInt(kickSignal()));
    return set;
}

/// Consumes kicks pending on this thread: one that arrived during
/// KVM_RUN stays pending once the signal is blocked again.
fn eatKicks() void {
    const set = kickSet();
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    while (true) {
        const rc = linux.syscall4(.rt_sigtimedwait, @intFromPtr(&set), 0, @intFromPtr(&ts), linux.NSIG / 8);
        if (linux.errno(rc) != .SUCCESS) return;
    }
}

pub const Backend = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    kvm: i32,
    vm: i32,
    ram: gphys.Ram,
    kernel_root: u64 = 0,
    run_size: usize,
    max_vcpus: u32 = 0,
    pid: i32,
    /// Guards the vCPU lists and the kernel tables.
    lock: std.atomic.Mutex = .unlocked,
    /// Every vCPU this VM has created, indexed by slot.
    all: std.ArrayList(*State) = .empty,
    /// Destroyed vCPUs, waiting to be reused.
    parked: std.ArrayList(*State) = .empty,
    next_as_id: std.atomic.Value(u64) = .init(1),
    arch: if (is_x86) X86 else Arm = .{},

    const X86 = struct {
        cpuid: ?*abi.CpuidList = null,
        smep: bool = false,
        smap: bool = false,
    };
    const Arm = struct {
        target: abi.VcpuInit = .{},
    };

    fn lockSpin(b: *Backend) void {
        while (!b.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: vmm.Options) vmm.CreateError!*Backend {
        if (opts.arch != guest_arch) return error.WrongArch;
        const open_rc = linux.open("/dev/kvm", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        const kvm: i32 = switch (linux.errno(open_rc)) {
            .SUCCESS => @intCast(open_rc),
            .NOENT, .NODEV, .NXIO, .ACCES, .PERM => return error.HypervisorUnavailable,
            else => return error.HypervisorFailed,
        };
        errdefer closeFd(kvm);
        if ((ioctl(kvm, abi.GET_API_VERSION, 0) catch 0) != abi.API_VERSION) return error.HypervisorUnavailable;
        if (checkExtension(kvm, abi.CAP_USER_MEMORY) == 0 or checkExtension(kvm, abi.CAP_IMMEDIATE_EXIT) == 0)
            return error.HypervisorUnavailable;

        // arm64: the IPA size HVF uses. The default type asks for 40 bits,
        // which a nested host may not offer.
        const vm_type: usize = if (is_x86) 0 else blk: {
            const ipa = checkExtension(kvm, abi.CAP_ARM_VM_IPA_SIZE);
            if (ipa == 0) break :blk 0; // only the default 40 bits
            if (ipa < pt.ipa_bits) return error.HypervisorUnavailable;
            break :blk abi.vmTypeArmIpaSize(pt.ipa_bits);
        };
        const vm: i32 = @intCast(try ioctl(kvm, abi.CREATE_VM, vm_type));
        errdefer closeFd(vm);
        const run_size = try ioctl(kvm, abi.GET_VCPU_MMAP_SIZE, 0);

        var ram: gphys.Ram = try .init(gpa, io, ram_gpa, opts.memory);
        errdefer ram.deinit();
        const region: abi.UserspaceMemoryRegion = .{
            .slot = 0,
            .flags = 0,
            .guest_phys_addr = ram_gpa,
            .memory_size = ram.mem.len,
            .userspace_addr = @intFromPtr(ram.mem.ptr),
        };
        _ = try ioctl(vm, abi.SET_USER_MEMORY_REGION, @intFromPtr(&region));

        const b = try gpa.create(Backend);
        errdefer gpa.destroy(b);
        b.* = .{ .gpa = gpa, .io = io, .kvm = kvm, .vm = vm, .ram = ram, .run_size = run_size, .pid = linux.getpid() };

        if (is_x86) {
            _ = try ioctl(vm, abi.SET_TSS_ADDR, tss_addr);
            const list = try gpa.create(abi.CpuidList);
            errdefer gpa.destroy(list);
            list.* = .{};
            _ = try ioctl(kvm, abi.GET_SUPPORTED_CPUID, @intFromPtr(list));
            maskCpuid(list, &b.arch);
            b.arch.cpuid = list;
            b.kernel_root = try pt.kernelRoot(&b.ram);
        } else {
            _ = try ioctl(vm, abi.ARM_PREFERRED_TARGET, @intFromPtr(&b.arch.target));
            b.kernel_root = try pt.kernelRoot(&b.ram, doorbell_ipa);
        }
        b.max_vcpus = vcpuLimit(vm);
        installHandler();
        return b;
    }

    pub fn destroy(b: *Backend) void {
        for (b.all.items) |s| s.close();
        b.all.deinit(b.gpa);
        b.parked.deinit(b.gpa);
        closeFd(b.vm);
        closeFd(b.kvm);
        if (is_x86) if (b.arch.cpuid) |c| b.gpa.destroy(c);
        b.ram.deinit();
        b.gpa.destroy(b);
    }

    pub fn maxVcpus(b: *Backend) vmm.Error!u32 {
        return b.max_vcpus;
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

    /// Takes a parked vCPU, or creates one, and resets it. Must be called
    /// on the thread that will run the vCPU.
    pub fn createVcpu(b: *Backend) vmm.CreateError!Vcpu {
        // Block the kick signal on this thread for good; it's unblocked
        // only inside KVM_RUN.
        const kick = kickSet();
        var old: linux.sigset_t = undefined;
        _ = linux.sigprocmask(linux.SIG.BLOCK, &kick, &old);
        // Not linux.sigdelset, which toggles the bit (Zig 0.16).
        var during_run = old;
        for (&during_run, kick) |*w, k| w.* &= ~k;

        const parked = blk: {
            b.lockSpin();
            defer b.lock.unlock();
            break :blk b.parked.pop();
        };
        const s = parked orelse try b.newVcpu();
        errdefer b.park(s);
        try s.reset();
        // struct kvm_signal_mask: the length, then the kernel's sigset.
        var mask: [4 + @sizeOf(linux.sigset_t)]u8 = undefined;
        std.mem.writeInt(u32, mask[0..4], @sizeOf(linux.sigset_t), .little);
        @memcpy(mask[4..], std.mem.asBytes(&during_run));
        _ = try ioctl(s.fd, abi.SET_SIGNAL_MASK, @intFromPtr(&mask));
        s.tid = linux.gettid();
        return .{ .s = s };
    }

    fn park(b: *Backend, s: *State) void {
        b.lockSpin();
        defer b.lock.unlock();
        // On failure the vCPU stays in `all` only, unused until the end.
        b.parked.append(b.gpa, s) catch {};
    }

    /// Creates a vCPU in the next slot, with its shared page.
    fn newVcpu(b: *Backend) vmm.CreateError!*State {
        const s = try b.gpa.create(State);
        errdefer b.gpa.destroy(s);
        b.lockSpin();
        defer b.lock.unlock();
        const slot: u32 = @intCast(b.all.items.len);
        if (slot >= b.max_vcpus) return error.HypervisorFailed;
        try b.all.ensureUnusedCapacity(b.gpa, 1);
        try b.parked.ensureTotalCapacity(b.gpa, b.all.items.len + 1);

        const fd: i32 = @intCast(try ioctl(b.vm, abi.CREATE_VCPU, slot));
        errdefer closeFd(fd);
        const run = std.posix.mmap(null, b.run_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch
            return error.HypervisorFailed;
        errdefer std.posix.munmap(run);
        const page = try b.ram.allocPages(1);
        errdefer b.ram.freePages(page);
        if (is_x86) {
            try pt.mapShared(&b.ram, b.kernel_root, slot, page);
            _ = try ioctl(fd, abi.SET_CPUID2, @intFromPtr(b.arch.cpuid.?));
        } else {
            try pt.mapPage(&b.ram, b.kernel_root, pt.sharedKva(slot), b.ram.gpaOf(page), pt.pteAttrs(false, .{ .write = true }));
        }
        s.* = .{
            .backend = b,
            .fd = fd,
            .run_map = run,
            .run = @ptrCast(run.ptr),
            .slot = slot,
            .shared = @ptrCast(page.ptr),
        };
        b.all.appendAssumeCapacity(s);
        return s;
    }
};

/// The vCPU limit: KVM's, capped by the shared-page slots and by the file
/// descriptors left. Raises the soft descriptor limit to the hard one,
/// since the usual soft 1024 is below x86's vCPU limit.
fn vcpuLimit(vm: i32) u32 {
    var n = checkExtension(vm, abi.CAP_MAX_VCPUS);
    if (n == 0) n = checkExtension(vm, abi.CAP_NR_VCPUS);
    if (n == 0) n = 4;
    const ids = checkExtension(vm, abi.CAP_MAX_VCPU_ID);
    if (ids > 0) n = @min(n, ids);
    n = @min(n, max_slots);
    var rl: linux.rlimit = undefined;
    if (linux.errno(linux.getrlimit(.NOFILE, &rl)) == .SUCCESS) {
        if (rl.cur < rl.max) {
            var raised = rl;
            raised.cur = rl.max;
            if (linux.errno(linux.setrlimit(.NOFILE, &raised)) == .SUCCESS) rl = raised;
        }
        const budget = if (rl.cur > fd_margin) rl.cur - fd_margin else 1;
        n = @min(n, budget);
    }
    return @intCast(@max(n, 1));
}

/// Shared pages sit in the kernel half one after another; this bounds
/// how far they go.
const max_slots = 1024;

/// Clears what h9 hides from the guest in the supported CPUID, and notes
/// whether the CPU has SMEP and SMAP.
fn maskCpuid(list: *abi.CpuidList, a: *Backend.X86) void {
    var n: usize = 0;
    for (list.entries[0..list.nent]) |e| {
        if (x86.cpuidDropped(e.function)) continue;
        var k = e;
        for (x86.cpuid_clear) |m| if (m.function == k.function and k.index == 0) {
            k.eax &= ~m.eax;
            k.ebx &= ~m.ebx;
            k.ecx &= ~m.ecx;
            k.edx &= ~m.edx;
        };
        if (k.function == 7 and k.index == 0) {
            a.smep = k.ebx & x86.cpuid7_smep != 0;
            a.smap = k.ebx & x86.cpuid7_smap != 0;
        }
        list.entries[n] = k;
        n += 1;
    }
    list.nent = @intCast(n);
}

pub const AddressSpace = gphys.AddressSpace(pt);

/// A vCPU's state, kept across its users.
const State = struct {
    backend: *Backend,
    fd: i32,
    run_map: []align(std.heap.page_size_min) u8,
    run: *abi.Run,
    slot: u32,
    shared: *Shared,
    /// The thread running it, for kicks.
    tid: i32 = 0,
    /// The address space last run, and its epoch then; a change means a
    /// TLB flush before the next run.
    as: ?*AddressSpace = null,
    as_id: u64 = 0,
    epoch: u64 = 0,
    /// The vCPU was stopped outside the shim's save path: enter the shim
    /// at `restore` before the next run, so it loads the Ureg.
    reenter: bool = false,

    fn close(s: *State) void {
        std.posix.munmap(s.run_map);
        closeFd(s.fd);
        s.backend.gpa.destroy(s);
    }

    fn sharedKva(s: *const State) u64 {
        return pt.sharedKva(s.slot);
    }

    /// Puts the vCPU in the state a new one starts in: entering the shim,
    /// with no user state from its last user.
    fn reset(s: *State) vmm.Error!void {
        @atomicStore(u8, &s.run.immediate_exit, 0, .seq_cst);
        s.as = null;
        s.as_id = 0;
        s.epoch = 0;
        s.reenter = false;
        s.shared.ureg = .{};
        s.shared.far = 0;
        s.shared.why = 0;
        if (is_x86) {
            s.shared.next_cr3 = 0;
            try s.resetX86();
        } else {
            s.shared.flush = 1;
            try s.resetArm();
        }
    }

    // ---- x86 ----

    fn seg(x: x86.Segment) abi.Segment {
        return .{
            .base = x.base,
            .limit = x.limit,
            .selector = x.selector,
            .type = x.type,
            .present = @intFromBool(x.present),
            .dpl = x.dpl,
            .db = @intFromBool(x.db),
            .s = @intFromBool(x.s),
            .l = @intFromBool(x.l),
            .g = @intFromBool(x.g),
        };
    }

    fn resetX86(s: *State) vmm.Error!void {
        const b = s.backend;
        const kva = s.sharedKva();
        var sr: abi.Sregs = undefined;
        _ = try ioctl(s.fd, abi.GET_SREGS, @intFromPtr(&sr));
        sr.cs = seg(x86.code64);
        sr.ss = seg(x86.data);
        sr.ds = seg(x86.null_data);
        sr.es = seg(x86.null_data);
        sr.fs = seg(x86.null_data);
        var gs = x86.null_data;
        gs.base = kva;
        sr.gs = seg(gs);
        sr.tr = seg(x86.tr(kva + x86.tss_off));
        sr.ldt = .{ .type = 2, .unusable = 1 };
        sr.gdt = .{ .base = kva + x86.gdt_off, .limit = x86.ngdt * 8 - 1 };
        sr.idt = .{ .base = pt.kva_idt, .limit = x86.nvectors * 16 - 1 };
        sr.cr0 = x86.cr0;
        sr.cr2 = 0;
        sr.cr3 = b.kernel_root;
        sr.cr4 = x86.cr4(b.arch.smep, b.arch.smap);
        sr.cr8 = 0;
        sr.efer = x86.efer;
        sr.interrupt_bitmap = @splat(0);
        _ = try ioctl(s.fd, abi.SET_SREGS, @intFromPtr(&sr));

        var msrs: abi.MsrList(6) = .{ .entries = undefined };
        for (x86.msrs(pt.kva_shim), 0..) |m, i| msrs.entries[i] = .{ .index = m[0], .data = m[1] };
        msrs.entries[5] = .{ .index = x86.MSR_FS_BASE, .data = 0 };
        if (try ioctl(s.fd, abi.SET_MSRS, @intFromPtr(&msrs)) != msrs.nmsrs) return error.HypervisorFailed;

        try s.setFpu(&vmm.X86Extra.init.fx);
        try s.enterX86();
    }

    /// Points the vCPU at the shim's `restore`, in ring 0 with GS on the
    /// shared page, keeping the rest of its state.
    fn enterX86(s: *State) vmm.Error!void {
        const regs: abi.Regs = .{
            .rip = pt.kva_shim + x86.shim_restore,
            .rflags = x86.rflags_res1,
            .rsp = s.sharedKva() + x86.stack_top,
        };
        _ = try ioctl(s.fd, abi.SET_REGS, @intFromPtr(&regs));
    }

    /// After a stop in user mode (or in the shim's restore path): back to
    /// ring 0, with the kernel GS base, at `restore`.
    fn reenterX86(s: *State) vmm.Error!void {
        var sr: abi.Sregs = undefined;
        _ = try ioctl(s.fd, abi.GET_SREGS, @intFromPtr(&sr));
        sr.cs = seg(x86.code64);
        sr.ss = seg(x86.data);
        var gs = x86.null_data;
        gs.base = s.sharedKva();
        sr.gs = seg(gs);
        _ = try ioctl(s.fd, abi.SET_SREGS, @intFromPtr(&sr));
        var msrs: abi.MsrList(1) = .{ .entries = .{.{ .index = x86.MSR_KERNEL_GS_BASE, .data = 0 }} };
        if (try ioctl(s.fd, abi.SET_MSRS, @intFromPtr(&msrs)) != 1) return error.HypervisorFailed;
        try s.enterX86();
    }

    /// The x87 and SSE state, through the XSAVE image, whose legacy
    /// region is FXSAVE's layout. KVM_GET_FPU would be the obvious call,
    /// but recent kernels leave MXCSR out of what it returns.
    fn setFpu(s: *State, fx: *const vmm.Fxsave) vmm.Error!void {
        var x: abi.Xsave = .{ .region = @splat(0) };
        const bytes = std.mem.asBytes(&x.region);
        var legacy = fx.*;
        // Reserved MXCSR bits would make the load fail.
        legacy.mxcsr &= 0xffff;
        legacy.mxcsr_mask = 0;
        @memcpy(bytes[0..@sizeOf(vmm.Fxsave)], std.mem.asBytes(&legacy));
        // XSTATE_BV: x87 and SSE come from the image.
        std.mem.writeInt(u64, bytes[abi.xstate_bv_off..][0..8], 3, .little);
        _ = try ioctl(s.fd, abi.SET_XSAVE, @intFromPtr(&x));
    }

    fn getFpu(s: *State, fx: *vmm.Fxsave) vmm.Error!void {
        var x: abi.Xsave = undefined;
        _ = try ioctl(s.fd, abi.GET_XSAVE, @intFromPtr(&x));
        const bytes = std.mem.asBytes(&x.region);
        @memcpy(std.mem.asBytes(fx), bytes[0..@sizeOf(vmm.Fxsave)]);
        const bv = std.mem.readInt(u64, bytes[abi.xstate_bv_off..][0..8], .little);
        // A component in its initial state may not be written out.
        if (bv & 1 == 0) {
            const mxcsr = fx.mxcsr;
            const xmm = fx.xmm;
            fx.* = vmm.X86Extra.init.fx;
            fx.mxcsr = mxcsr;
            fx.xmm = xmm;
        }
        if (bv & 2 == 0) fx.xmm = @splat(0);
        fx.mxcsr_mask = 0xffff;
        fx._r2 = @splat(0);
    }

    fn getMsr(s: *State, index: u32) vmm.Error!u64 {
        var msrs: abi.MsrList(1) = .{ .entries = .{.{ .index = index, .data = 0 }} };
        if (try ioctl(s.fd, abi.GET_MSRS, @intFromPtr(&msrs)) != 1) return error.HypervisorFailed;
        return msrs.entries[0].data;
    }

    fn setMsr(s: *State, index: u32, value: u64) vmm.Error!void {
        var msrs: abi.MsrList(1) = .{ .entries = .{.{ .index = index, .data = value }} };
        if (try ioctl(s.fd, abi.SET_MSRS, @intFromPtr(&msrs)) != 1) return error.HypervisorFailed;
    }

    // ---- arm64 ----

    fn getReg(s: *State, id: u64, comptime T: type) vmm.Error!T {
        var v: T = 0;
        const r: abi.OneReg = .{ .id = id, .addr = @intFromPtr(&v) };
        _ = try ioctl(s.fd, abi.GET_ONE_REG, @intFromPtr(&r));
        return v;
    }

    fn setReg(s: *State, id: u64, comptime T: type, v: T) vmm.Error!void {
        var x = v;
        const r: abi.OneReg = .{ .id = id, .addr = @intFromPtr(&x) };
        _ = try ioctl(s.fd, abi.SET_ONE_REG, @intFromPtr(&r));
    }

    fn resetArm(s: *State) vmm.Error!void {
        const b = s.backend;
        // KVM_ARM_VCPU_INIT again is a full reset.
        _ = try ioctl(s.fd, abi.ARM_VCPU_INIT, @intFromPtr(&b.arch.target));
        for (pt.sysregs(b.kernel_root, s.sharedKva())) |r| {
            // SP_EL1 is a core register in KVM's numbering.
            const id = if (r[0] == pt.SYS_SP_EL1) abi.ARM_SP_EL1 else abi.armSysreg(r[0]);
            try s.setReg(id, u64, r[1]);
        }
        try s.enterArm();
    }

    fn enterArm(s: *State) vmm.Error!void {
        try s.setReg(abi.ARM_PC, u64, pt.kva_shim + pt.shim_enter);
        try s.setReg(abi.ARM_PSTATE, u64, pt.psr_el1h);
    }
};

/// arm64 shim.S offsets: the vectors and the save path run up to the
/// doorbell store (`str x0, [x1]`); `enter` and `restore` follow it.
const arm_shim = if (is_x86) struct {} else struct {
    const save_start = pt.shim_enter + 12; // past `enter`'s three instructions
    const doorbell: usize = blk: {
        @setEvalBranchQuota(10000);
        var i: usize = save_start;
        while (i + 4 <= pt.shim_code.len) : (i += 4) {
            if (std.mem.readInt(u32, pt.shim_code[i..][0..4], .little) == 0xf9000020) break :blk i;
        }
        @compileError("shim.S: no doorbell store");
    };

    /// Whether a stop at shim offset `off` was in the middle of saving a
    /// Ureg, which the shim finishes by ringing the doorbell.
    fn saving(off: u64) bool {
        return off < pt.shim_enter or (off >= save_start and off <= doorbell);
    }
};

pub const Vcpu = struct {
    s: *State,

    /// Parks the vCPU for reuse: KVM can't destroy one alone.
    pub fn destroy(v: *Vcpu) void {
        eatKicks();
        v.s.backend.park(v.s);
    }

    pub fn setAddressSpace(v: *Vcpu, as: *AddressSpace) vmm.Error!void {
        const s = v.s;
        if (s.as == as and s.as_id == as.id) return;
        if (is_x86) {
            s.shared.next_cr3 = as.root;
        } else {
            try s.setReg(abi.armSysreg(pt.SYS_TTBR0_EL1), u64, as.root);
            s.shared.flush = 1;
        }
        s.as = as;
        s.as_id = as.id;
        s.epoch = as.epoch.load(.acquire);
    }

    pub fn getUreg(v: *Vcpu, u: *vmm.Ureg) void {
        u.* = if (is_x86) .{ .amd64 = v.s.shared.ureg } else .{ .arm64 = v.s.shared.ureg };
    }

    pub fn setUreg(v: *Vcpu, u: *const vmm.Ureg) void {
        v.s.shared.ureg = if (is_x86) u.amd64 else u.arm64;
    }

    pub fn getExtra(v: *Vcpu, x: *vmm.Extra) vmm.Error!void {
        const s = v.s;
        if (is_x86) {
            x.* = .{ .amd64 = .{} };
            try s.getFpu(&x.amd64.fx);
            x.amd64.tls = try s.getMsr(x86.MSR_FS_BASE);
        } else {
            x.* = .{ .arm64 = .{} };
            const a = &x.arm64;
            for (&a.v, 0..) |*q, i| q.* = try s.getReg(abi.armV(@intCast(i)), u128);
            a.fpsr = try s.getReg(abi.ARM_FPSR, u32);
            a.fpcr = try s.getReg(abi.ARM_FPCR, u32);
            a.tls = try s.getReg(abi.armSysreg(pt.SYS_TPIDR_EL0), u64);
        }
    }

    pub fn setExtra(v: *Vcpu, x: *const vmm.Extra) vmm.Error!void {
        const s = v.s;
        if (is_x86) {
            try s.setFpu(&x.amd64.fx);
            try s.setMsr(x86.MSR_FS_BASE, x.amd64.tls);
        } else {
            const a = &x.arm64;
            for (a.v, 0..) |q, i| try s.setReg(abi.armV(@intCast(i)), u128, q);
            try s.setReg(abi.ARM_FPSR, u32, @truncate(a.fpsr));
            try s.setReg(abi.ARM_FPCR, u32, @truncate(a.fpcr));
            try s.setReg(abi.armSysreg(pt.SYS_TPIDR_EL0), u64, a.tls);
        }
    }

    /// Safe to call from any thread.
    pub fn kick(v: *Vcpu) void {
        const s = v.s;
        @atomicStore(u8, &s.run.immediate_exit, 1, .seq_cst);
        _ = linux.tgkill(s.backend.pid, s.tid, @enumFromInt(kickSignal()));
    }

    pub fn run(v: *Vcpu) vmm.Error!vmm.Exit {
        const s = v.s;
        const as = s.as orelse return error.BadAddress;
        const epoch = as.epoch.load(.acquire);
        if (epoch != s.epoch) {
            s.epoch = epoch;
            if (is_x86) s.shared.next_cr3 = as.root else s.shared.flush = 1;
        }
        if (s.reenter) {
            if (is_x86) try s.reenterX86() else try s.enterArm();
            s.reenter = false;
        }
        while (true) {
            switch (abi.run(s.fd)) {
                .SUCCESS => {},
                .INTR, .AGAIN => {
                    if (try v.stopped()) return .interrupted;
                    continue;
                },
                else => return error.HypervisorFailed,
            }
            const r = s.run;
            switch (r.exit_reason) {
                abi.EXIT_IO => if (is_x86 and r.exit.io.port == x86.doorbell_port and r.exit.io.direction == abi.EXIT_IO_OUT)
                    return v.decode(),
                abi.EXIT_MMIO => if (!is_x86 and r.exit.mmio.phys_addr & ~@as(u64, 0xfff) == doorbell_ipa and r.exit.mmio.is_write != 0)
                    return v.decode(),
                abi.EXIT_INTR => {
                    if (try v.stopped()) return .interrupted;
                    continue;
                },
                else => {},
            }
            return .{ .other = r.exit_reason };
        }
    }

    /// After KVM_RUN stopped for a kick: clears it, and works out where
    /// the vCPU stopped. In user mode, the registers go to the Ureg and
    /// the next run re-enters the shim, so a changed Ureg takes effect.
    /// In the shim's restore path, the Ureg is already current. In its
    /// save path, the Ureg is half written, so returns false: the caller
    /// runs on to the doorbell instead.
    fn stopped(v: *Vcpu) vmm.Error!bool {
        const s = v.s;
        @atomicStore(u8, &s.run.immediate_exit, 0, .seq_cst);
        eatKicks();
        if (is_x86) {
            var regs: abi.Regs = undefined;
            _ = try ioctl(s.fd, abi.GET_REGS, @intFromPtr(&regs));
            if (regs.rip >= pt.kva_shim) {
                const off = regs.rip - pt.kva_shim;
                if (off <= x86.shim_doorbell) return false;
                if (off != x86.shim_restore) s.reenter = true;
                return true;
            }
            const u = &s.shared.ureg;
            inline for (.{ "ax", "bx", "cx", "dx", "si", "di", "bp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" }) |f| {
                @field(u, f) = @field(regs, if (f[0] == 'r') f else "r" ++ f);
            }
            u.pc = regs.rip;
            u.flags = regs.rflags;
            u.sp = regs.rsp;
            s.reenter = true;
            return true;
        } else {
            const pc = try s.getReg(abi.ARM_PC, u64);
            if (pc >= pt.kva_shim) {
                const off = pc - pt.kva_shim;
                if (arm_shim.saving(off)) return false;
                if (off != pt.shim_enter) s.reenter = true;
                return true;
            }
            const u = &s.shared.ureg;
            for (&u.r, 0..) |*x, i| x.* = try s.getReg(abi.armX(@intCast(i)), u64);
            u.sp = try s.getReg(abi.ARM_SP, u64);
            u.pc = pc;
            u.psr = try s.getReg(abi.ARM_PSTATE, u64);
            s.reenter = true;
            return true;
        }
    }

    fn decode(v: *Vcpu) vmm.Exit {
        const s = v.s.shared;
        if (is_x86) {
            return switch (s.why) {
                x86.why_syscall => .syscall,
                x86.why_trap => if (s.ureg.type == x86.vector_pf)
                    .{ .fault = .{
                        .addr = s.far,
                        .access = if (s.ureg.@"error" & 0x10 != 0) .exec else if (s.ureg.@"error" & 2 != 0) .write else .read,
                        .syndrome = s.ureg.@"error",
                    } }
                else
                    .{ .fault = .{ .addr = s.ureg.pc, .access = .exec, .syndrome = s.ureg.type } },
                else => .{ .other = s.ureg.type },
            };
        }
        switch (s.why) {
            pt.why_el0 => {},
            pt.why_irq => return .interrupted,
            else => return .{ .other = s.ureg.type },
        }
        const esr = s.ureg.type;
        return switch (esr >> 26) {
            arm64.EC_SVC64 => .syscall,
            arm64.EC_IABT_LOWER => .{ .fault = .{ .addr = s.far, .access = .exec, .syndrome = esr } },
            arm64.EC_DABT_LOWER => .{ .fault = .{ .addr = s.far, .access = if (esr & (1 << 6) != 0) .write else .read, .syndrome = esr } },
            else => .{ .fault = .{ .addr = s.ureg.pc, .access = .exec, .syndrome = esr } },
        };
    }
};
