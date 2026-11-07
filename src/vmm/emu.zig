//! Emulator backend (Unicorn). Built with -Demu=unicorn. See DESIGN.md,
//! "Emulator backend (emu)".
//!
//! User mode only: each vCPU is a Unicorn engine running at EL0 (arm64), in
//! flat 64-bit mode (amd64) or in flat 32-bit protected mode (386), with no
//! MMU and no guest kernel. Hooks turn
//! syscall instructions, invalid memory accesses and CPU exceptions into
//! vmm exits, doing the shim's job. Address-space pages are host memory
//! mapped straight into the engine with uc_mem_map_ptr, so the host and the
//! guest share them.

const std = @import("std");
const vmm = @import("../vmm.zig");
const arm64 = @import("../arch/arm64.zig");
const amd64 = @import("../arch/amd64.zig");
const ia32 = @import("../arch/i386.zig");
const uc = @import("unicorn");

/// Unicorn's runtime version, e.g. "2.1".
pub fn version(buf: []u8) []const u8 {
    var major: c_uint = 0;
    var minor: c_uint = 0;
    _ = uc.uc_version(&major, &minor);
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ major, minor }) catch buf[0..0];
}

fn open(arch: vmm.Arch) vmm.Error!*uc.uc_engine {
    const a: uc.uc_arch, const mode: uc.uc_mode = switch (arch) {
        .arm64 => .{ uc.UC_ARCH_ARM64, uc.UC_MODE_ARM },
        .amd64 => .{ uc.UC_ARCH_X86, uc.UC_MODE_64 },
        // Unicorn's 32-bit mode starts in protected mode with every segment
        // based at 0, which is the flat model 9front's GDT gives user code.
        .i386 => .{ uc.UC_ARCH_X86, uc.UC_MODE_32 },
    };
    var engine: ?*uc.uc_engine = null;
    if (uc.uc_open(a, mode, &engine) != uc.UC_ERR_OK) return error.HypervisorFailed;
    // QEMU reserves a 1 GiB translation buffer per engine by default, and
    // Windows commits that against the pagefile, so a few dozen engines
    // (one per process) run it out. When the buffer fills, Unicorn flushes
    // and reuses it, so a smaller one only costs retranslation.
    if (uc.uc_ctl(engine, uc_ctl_set_tcg_buffer_size, @as(u32, tcg_buffer_size)) != uc.UC_ERR_OK) {
        _ = uc.uc_close(engine);
        return error.HypervisorFailed;
    }
    return engine.?;
}

const tcg_buffer_size: u32 = 32 << 20;
// uc_ctl_set_tcg_buffer_size is a macro: UC_CTL_WRITE(UC_CTL_TCG_BUFFER_SIZE, 1).
const uc_ctl_set_tcg_buffer_size: c_uint = uc.UC_CTL_TCG_BUFFER_SIZE | (1 << 26) | (1 << 30);

fn check(err: uc.uc_err) vmm.Error!void {
    if (err != uc.UC_ERR_OK) return error.HypervisorFailed;
}

fn prot(p: vmm.Perms) u32 {
    var r: u32 = 0;
    if (p.read) r |= uc.UC_PROT_READ;
    if (p.write) r |= uc.UC_PROT_WRITE;
    if (p.exec) r |= uc.UC_PROT_EXEC;
    return r;
}

/// Frees pages from `Backend.allocPages` without free's 0xaa fill in safe
/// builds, which would touch every page first.
fn freeRaw(mem: []align(vmm.page_size) u8) void {
    std.heap.page_allocator.rawFree(mem, .fromByteUnits(vmm.page_size), @returnAddress());
}

pub const Backend = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arch: vmm.Arch,
    lock: std.Io.Mutex = .init,
    /// Live allocations: address to length.
    allocs: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    /// Bytes handed out, against the cap in `limit`.
    used: u64 = 0,
    limit: u64,
    guest: GuestLock = .{},

    pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: vmm.Options) vmm.CreateError!*Backend {
        // Fail here, not at the first vCPU, if Unicorn lacks the architecture.
        _ = uc.uc_close(try open(opts.arch));
        const b = try gpa.create(Backend);
        const limit = opts.memory orelse vmm.default_memory;
        if (limit > vmm.max_memory) return error.OutOfGuestMemory;
        b.* = .{ .gpa = gpa, .io = io, .arch = opts.arch, .limit = limit };
        return b;
    }

    pub fn destroy(b: *Backend) void {
        var it = b.allocs.iterator();
        while (it.next()) |e| freeRaw(@as([*]align(vmm.page_size) u8, @ptrFromInt(e.key_ptr.*))[0..e.value_ptr.*]);
        b.allocs.deinit(b.gpa);
        b.gpa.destroy(b);
    }

    /// No hardware limit; this keeps the number in line with HVF's.
    pub fn maxVcpus(_: *Backend) vmm.Error!u32 {
        return 64;
    }

    /// Returns zeroed pages.
    pub fn allocPages(b: *Backend, n: usize) vmm.Error![]align(vmm.page_size) u8 {
        {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            const len = n * vmm.page_size;
            if (b.used + len > b.limit) return error.OutOfGuestMemory;
            b.used += len;
        }
        errdefer {
            b.lock.lockUncancelable(b.io);
            b.used -= n * vmm.page_size;
            b.lock.unlock(b.io);
        }
        // rawAlloc skips the 0xaa fill that alignedAlloc does in safe
        // builds. Fresh pages from the OS are zero, and pages nothing
        // touches stay unbacked on the host: a Go program reserves several
        // hundred MB of brk at start, and zeroing it by hand cost seconds.
        const len = n * vmm.page_size;
        const raw = std.heap.page_allocator.rawAlloc(len, .fromByteUnits(vmm.page_size), @returnAddress()) orelse
            return error.OutOfGuestMemory;
        const mem: []align(vmm.page_size) u8 = @alignCast(raw[0..len]);
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.allocs.put(b.gpa, @intFromPtr(mem.ptr), mem.len) catch {
            freeRaw(mem);
            return error.OutOfGuestMemory;
        };
        return mem;
    }

    /// Returns a whole allocation from `allocPages`.
    pub fn freePages(b: *Backend, mem: []align(vmm.page_size) u8) void {
        {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            const len = (b.allocs.fetchRemove(@intFromPtr(mem.ptr)) orelse return).value;
            std.debug.assert(len == mem.len);
            b.used -= len;
        }
        freeRaw(mem);
    }

    pub fn newAddressSpace(b: *Backend) vmm.CreateError!*AddressSpace {
        const as = try b.gpa.create(AddressSpace);
        as.* = .{ .backend = b };
        return as;
    }

    pub fn createVcpu(b: *Backend) vmm.CreateError!Vcpu {
        const s = try b.gpa.create(State);
        errdefer b.gpa.destroy(s);
        s.* = .{ .backend = b, .arch = b.arch, .engine = try open(b.arch), .ureg = switch (b.arch) {
            inline else => |a| @unionInit(vmm.Ureg, @tagName(a), .{}),
        } };
        errdefer _ = uc.uc_close(s.engine);
        try s.addHooks();
        return .{ .s = s };
    }
};

/// The emulator keeps the mappings itself; vCPUs copy them into their
/// engines when they switch to the address space or it changes.
pub const AddressSpace = struct {
    backend: *Backend,
    regions: std.ArrayList(Region) = .empty,
    /// Bumped on every change, so vCPUs know to remap.
    generation: u64 = 1,
    /// Bumped by `codeChanged`, so vCPUs drop their translated blocks.
    code: std.atomic.Value(u64) = .init(0),
    /// Guards `regions` against `copy` on another thread (/proc/n/mem).
    lock: std.atomic.Mutex = .unlocked,

    const Region = struct { va: u64, mem: []align(vmm.page_size) u8, perms: vmm.Perms };

    fn lockSpin(as: *AddressSpace) void {
        while (!as.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn map(as: *AddressSpace, va: u64, mem: []align(vmm.page_size) u8, perms: vmm.Perms) vmm.CreateError!void {
        if (va % vmm.page_size != 0 or mem.len % vmm.page_size != 0 or mem.len == 0) return error.BadAddress;
        as.lockSpin();
        defer as.lock.unlock();
        for (as.regions.items) |r| {
            if (va < r.va + r.mem.len and r.va < va + mem.len) return error.BadAddress;
        }
        try as.regions.append(as.backend.gpa, .{ .va = va, .mem = mem, .perms = perms });
        as.generation += 1;
    }

    pub fn unmap(as: *AddressSpace, va: u64) void {
        as.lockSpin();
        defer as.lock.unlock();
        for (as.regions.items, 0..) |r, i| if (r.va == va) {
            _ = as.regions.swapRemove(i);
            as.generation += 1;
            return;
        };
    }

    pub fn translate(as: *AddressSpace, va: u64, len: u64) ?[]u8 {
        as.lockSpin();
        defer as.lock.unlock();
        return as.find(va, len);
    }

    fn find(as: *AddressSpace, va: u64, len: u64) ?[]u8 {
        for (as.regions.items) |r| {
            if (va >= r.va and va - r.va <= r.mem.len and len <= r.mem.len - (va - r.va)) {
                return r.mem[va - r.va ..][0..len];
            }
        }
        return null;
    }

    /// `translate` and a copy under the lock; see vmm.AddressSpace.copy.
    pub fn copy(as: *AddressSpace, va: u64, buf: []u8, write: bool) bool {
        as.lockSpin();
        defer as.lock.unlock();
        const mem = as.find(va, buf.len) orelse return false;
        if (write) @memcpy(mem, buf) else @memcpy(buf, mem);
        return true;
    }

    /// The host wrote code: vCPUs running this space flush their
    /// translated blocks before their next run. The whole cache goes, as
    /// `sync` flushes it; design/0010-self-host.md leaves flushing only
    /// the written range (uc_ctl_remove_cache) until stepping shows the
    /// need.
    pub fn codeChanged(as: *AddressSpace, _: u64, _: u64) void {
        _ = as.code.fetchAdd(1, .release);
    }

    pub fn destroy(as: *AddressSpace) void {
        as.regions.deinit(as.backend.gpa);
        as.backend.gpa.destroy(as);
    }
};

/// Unicorn generates code for a single-threaded context (its
/// `curr_cflags` never sets CF_PARALLEL), so a guest's atomic instructions
/// (x86 LOCK-prefixed ones, arm64 exclusives and LSE atomics) become plain
/// loads and stores. Engines running at once on memory they share, such as
/// a Go program's processes, race through them: Go's runtime fails with
/// "unlock of unlocked lock". So a backend runs guest code on one engine at
/// a time, through a fair (ticket) lock held across each `uc_emu_start`.
/// Kernel calls run outside it, so processes still block and wait in the
/// kernel in parallel.
///
/// The lock is only passed on at an exit (a syscall, a fault or a kick),
/// not on a timer: stopping an engine from another thread with
/// `uc_emu_stop` can leave its PC at an earlier block than the one it
/// stopped at, so resuming would run instructions twice. A guest that
/// spins without syscalls holds the others off until it makes one, as Go
/// and libc do between short bursts of spinning.
const GuestLock = struct {
    next: std.atomic.Value(u32) = .init(0),
    serving: std.atomic.Value(u32) = .init(0),

    fn acquire(g: *GuestLock, io: std.Io) void {
        const ticket = g.next.fetchAdd(1, .acq_rel);
        while (true) {
            const cur = g.serving.load(.acquire);
            if (cur == ticket) return;
            io.futexWaitUncancelable(u32, &g.serving.raw, cur);
        }
    }

    fn release(g: *GuestLock, io: std.Io) void {
        _ = g.serving.fetchAdd(1, .acq_rel);
        // Tickets are served in order, so every waiter has to look.
        if (g.next.load(.acquire) -% g.serving.load(.acquire) > 0) io.futexWake(u32, &g.serving.raw, std.math.maxInt(u32));
    }
};

/// Why the engine last stopped, as seen by the hooks.
const Stop = union(enum) {
    none,
    syscall,
    fault: vmm.Fault,
    /// A breakpoint instruction (BRK, INT3).
    breakpoint,
    /// A CPU exception other than a syscall (arm64 EXCP_* or x86 vector).
    exception: u32,
};

/// Heap state behind a Vcpu, so the hooks have a stable pointer.
const State = struct {
    backend: *Backend,
    arch: vmm.Arch,
    engine: *uc.uc_engine,
    ureg: vmm.Ureg,
    as: ?*AddressSpace = null,
    mapped: std.ArrayList(AddressSpace.Region) = .empty,
    generation: u64 = 0,
    /// The space's `code` when this engine last flushed its blocks.
    code: u64 = 0,
    stop: Stop = .none,
    kicked: std.atomic.Value(bool) = .init(false),
    /// Set from just before `kicked` is checked until uc_emu_start returns.
    in_run: std.atomic.Value(bool) = .init(false),

    fn addHooks(s: *State) vmm.Error!void {
        var h: uc.uc_hook = 0;
        try check(uc.uc_hook_add(s.engine, &h, uc.UC_HOOK_MEM_INVALID, @ptrCast(@constCast(&onMemInvalid)), s, 1, 0));
        try check(uc.uc_hook_add(s.engine, &h, uc.UC_HOOK_INTR, @ptrCast(@constCast(&onIntr)), s, 1, 0));
        if (s.arch == .amd64) {
            try check(uc.uc_hook_add(s.engine, &h, uc.UC_HOOK_INSN, @ptrCast(@constCast(&onSyscall)), s, 1, 0, @as(c_int, uc.UC_X86_INS_SYSCALL)));
        }
    }

    fn halt(s: *State, why: Stop) void {
        s.stop = why;
        _ = uc.uc_emu_stop(s.engine);
    }

    fn onIntr(_: ?*uc.uc_engine, intno: u32, data: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(data));
        if (s.arch == .arm64 and intno == arm64_excp_swi) return s.halt(.syscall);
        // INT $64; Unicorn has already moved EIP past it.
        if (s.arch == .i386 and intno == ia32.vector_syscall) return s.halt(.syscall);
        // BRK, with the PC left at it; INT3, with EIP past it as for INT $64.
        if (s.arch == .arm64 and intno == arm64_excp_bkpt) return s.halt(.breakpoint);
        if (s.arch != .arm64 and intno == x86_vector_bp) return s.halt(.breakpoint);
        s.halt(.{ .exception = intno });
    }

    fn onSyscall(_: ?*uc.uc_engine, data: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(data));
        s.halt(.syscall);
    }

    fn onMemInvalid(_: ?*uc.uc_engine, kind: uc.uc_mem_type, addr: u64, _: c_int, _: i64, data: ?*anyopaque) callconv(.c) bool {
        const s: *State = @ptrCast(@alignCast(data));
        const access: @FieldType(vmm.Fault, "access") = switch (kind) {
            uc.UC_MEM_WRITE_UNMAPPED, uc.UC_MEM_WRITE_PROT => .write,
            uc.UC_MEM_FETCH_UNMAPPED, uc.UC_MEM_FETCH_PROT => .exec,
            else => .read,
        };
        s.stop = .{ .fault = .{ .addr = addr, .access = access, .syndrome = @intCast(kind) } };
        return false; // Unicorn stops with an error, leaving the PC at the access
    }

    /// Makes the engine's mappings match the address space.
    fn sync(s: *State) vmm.Error!void {
        const as = s.as orelse return;
        const code = as.code.load(.acquire);
        if (s.generation == as.generation) {
            if (s.code != code) {
                // The host wrote code (codeChanged).
                try check(uc.uc_ctl(s.engine, uc_ctl_tb_flush));
                s.code = code;
            }
            return;
        }
        as.lockSpin();
        defer as.lock.unlock();
        for (s.mapped.items) |r| try check(uc.uc_mem_unmap(s.engine, r.va, r.mem.len));
        s.mapped.clearRetainingCapacity();
        for (as.regions.items) |r| {
            try check(uc.uc_mem_map_ptr(s.engine, r.va, r.mem.len, prot(r.perms), r.mem.ptr));
            s.mapped.append(s.backend.gpa, r) catch return error.OutOfGuestMemory;
        }
        // Translated blocks may hold code from the old mappings.
        try check(uc.uc_ctl(s.engine, uc_ctl_tb_flush));
        s.generation = as.generation;
        s.code = code;
    }

    fn writeRegs(s: *State) vmm.Error!void {
        switch (s.ureg) {
            .arm64 => |*u| {
                var vals: [arm64_regs.len]u64 = undefined;
                @memcpy(vals[0..31], &u.r);
                vals[31] = u.sp;
                vals[32] = u.pc;
                vals[33] = u.psr & arm64_nzcv; // EL0t, interrupts unmasked
                try writeBatch(s.engine, &arm64_regs, &vals);
            },
            .amd64 => |*u| {
                var vals: [amd64_regs.len]u64 = undefined;
                inline for (amd64_fields, 0..) |f, i| vals[i] = @field(u, f);
                vals[amd64_fields.len] = u.flags | amd64_flags_res1;
                try writeBatch(s.engine, &amd64_regs, &vals);
            },
            // The selectors stay in the Ureg as initExec and notify set
            // them; the engine's flat segments never change.
            .i386 => |*u| {
                var vals: [i386_regs.len]u32 = undefined;
                inline for (i386_fields, 0..) |f, i| vals[i] = @field(u, f);
                vals[i386_fields.len] = u.flags | @as(u32, @truncate(amd64_flags_res1));
                try writeBatch32(s.engine, &i386_regs, &vals);
            },
        }
    }

    fn readRegs(s: *State) vmm.Error!void {
        switch (s.ureg) {
            .arm64 => |*u| {
                var vals: [arm64_regs.len]u64 = undefined;
                try readBatch(s.engine, &arm64_regs, &vals);
                @memcpy(&u.r, vals[0..31]);
                u.sp = vals[31];
                u.pc = vals[32];
                u.psr = vals[33];
            },
            .amd64 => |*u| {
                var vals: [amd64_regs.len]u64 = undefined;
                try readBatch(s.engine, &amd64_regs, &vals);
                inline for (amd64_fields, 0..) |f, i| @field(u, f) = vals[i];
                u.flags = vals[amd64_fields.len];
            },
            .i386 => |*u| {
                var vals: [i386_regs.len]u32 = undefined;
                try readBatch32(s.engine, &i386_regs, &vals);
                inline for (i386_fields, 0..) |f, i| @field(u, f) = vals[i];
                u.flags = vals[i386_fields.len];
            },
        }
    }

    fn run(s: *State) vmm.Error!vmm.Exit {
        if (s.as == null) return error.BadAddress;
        // `in_run` is set before `kicked` is checked, so a kick either is
        // seen here or finds `in_run` set and repeats its stop request
        // until this run ends (see `kick`).
        s.in_run.store(true, .seq_cst);
        defer s.in_run.store(false, .release);
        if (s.kicked.swap(false, .seq_cst)) return .interrupted;
        try s.sync();
        try s.writeRegs();
        s.stop = .none;
        s.backend.guest.acquire(s.backend.io);
        // A kick while this waited for the lock may have stopped nothing,
        // since `kick` stops repeating its request after a while.
        if (s.kicked.swap(false, .seq_cst)) {
            s.backend.guest.release(s.backend.io);
            return .interrupted;
        }
        const err = uc.uc_emu_start(s.engine, s.ureg.pc(), std.math.maxInt(u64), 0, 0);
        s.backend.guest.release(s.backend.io);
        s.in_run.store(false, .release);
        try s.readRegs();
        const stop = s.stop;
        s.stop = .none;
        switch (stop) {
            .syscall => {
                s.setSyscallType();
                return .syscall;
            },
            .fault => |f| return .{ .fault = f },
            .breakpoint => {
                s.setBreakpointType();
                return .breakpoint;
            },
            .exception => |n| return s.exception(n),
            .none => {},
        }
        if (err != uc.UC_ERR_OK) {
            // Errors no hook saw, such as an invalid instruction on amd64.
            const pc = s.ureg.pc();
            return switch (err) {
                uc.UC_ERR_INSN_INVALID => .{ .fault = .{ .addr = pc, .access = .exec, .syndrome = @intCast(err) } },
                else => .{ .other = @intCast(err) },
            };
        }
        if (s.kicked.swap(false, .acquire)) return .interrupted;
        return .halted;
    }

    /// Fills Ureg.type the way the real kernel does for a syscall.
    fn setSyscallType(s: *State) void {
        switch (s.ureg) {
            .arm64 => |*u| u.type = @as(u64, arm64.EC_SVC64) << 26,
            .amd64 => |*u| u.type = amd64_vector_syscall,
            .i386 => |*u| u.trap = ia32.vector_syscall,
        }
    }

    /// Fills Ureg.type as the real kernel does for a breakpoint: the
    /// ESR on arm64 (class BRK64, the BRK's immediate unknown here), the
    /// vector on x86.
    fn setBreakpointType(s: *State) void {
        switch (s.ureg) {
            .arm64 => |*u| u.type = @as(u64, arm64.EC_BRK64) << 26,
            .amd64 => |*u| u.type = x86_vector_bp,
            .i386 => |*u| u.trap = x86_vector_bp,
        }
    }

    fn exception(s: *State, n: u32) vmm.Exit {
        const pc = s.ureg.pc();
        switch (s.ureg) {
            .arm64 => |*u| u.type = n,
            .amd64 => |*u| u.type = n,
            .i386 => |*u| u.trap = n,
        }
        return .{ .fault = .{ .addr = pc, .access = .exec, .syndrome = n } };
    }
};

// Unicorn makes newly generated code visible with __builtin___clear_cache,
// which resolves to compiler-rt's __clear_cache. Zig's (0.16) arm64 port
// of it leaves out the `dsb ish` after the `ic ivau` loop that LLVM's has,
// so the invalidation may not finish before the `isb`, and a freshly
// translated block can run stale: with several engines generating code at
// once, Linux arm64 guests hit illegal instructions in Unicorn's code
// buffer. This strong definition overrides compiler-rt's weak one. Apple
// targets use sys_icache_invalidate and Windows FlushInstructionCache.
comptime {
    const builtin = @import("builtin");
    if (builtin.cpu.arch == .aarch64 and !builtin.os.tag.isDarwin() and builtin.os.tag != .windows) {
        @export(&clearCache, .{ .name = "__clear_cache", .linkage = .strong });
    }
}

fn clearCache(start: usize, end: usize) callconv(.c) void {
    const ctr = asm volatile ("mrs %[ctr], ctr_el0"
        : [ctr] "=r" (-> u64),
    );
    // CTR_EL0.IDC: no clean to the point of unification needed.
    if ((ctr >> 28) & 1 == 0) {
        const line = @as(usize, 4) << @intCast((ctr >> 16) & 15);
        var a = start & ~(line - 1);
        while (a < end) : (a += line) asm volatile ("dc cvau, %[a]"
            :
            : [a] "r" (a),
            : .{ .memory = true });
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    // CTR_EL0.DIC: no invalidation to the point of unification needed.
    if ((ctr >> 29) & 1 == 0) {
        const line = @as(usize, 4) << @intCast(ctr & 15);
        var a = start & ~(line - 1);
        while (a < end) : (a += line) asm volatile ("ic ivau, %[a]"
            :
            : [a] "r" (a),
            : .{ .memory = true });
        asm volatile ("dsb ish" ::: .{ .memory = true });
    }
    asm volatile ("isb sy" ::: .{ .memory = true });
}

// uc_ctl_flush_tb is a macro: UC_CTL_WRITE(UC_CTL_TB_FLUSH, 0).
const uc_ctl_tb_flush: c_uint = uc.UC_CTL_TB_FLUSH | (1 << 30);

// QEMU's arm64 exception numbers, as passed to UC_HOOK_INTR.
const arm64_excp_swi = 2;
const arm64_excp_bkpt = 7;
// x86 #BP, which INT3 raises.
const x86_vector_bp = 3;
const arm64_nzcv: u64 = 0xf000_0000;
// pc/io.h VectorSYSCALL, which 9front puts in Ureg.type for syscalls.
const amd64_vector_syscall = 64;
const amd64_flags_res1: u64 = 1 << 1;

const arm64_regs = blk: {
    var r: [34]c_int = undefined;
    for (0..29) |i| r[i] = uc.UC_ARM64_REG_X0 + @as(c_int, @intCast(i));
    r[29] = uc.UC_ARM64_REG_X29;
    r[30] = uc.UC_ARM64_REG_X30;
    r[31] = uc.UC_ARM64_REG_SP;
    r[32] = uc.UC_ARM64_REG_PC;
    r[33] = uc.UC_ARM64_REG_PSTATE;
    break :blk r;
};

const amd64_fields = [_][]const u8{ "ax", "bx", "cx", "dx", "si", "di", "bp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "pc", "sp" };
const amd64_regs = [_]c_int{
    uc.UC_X86_REG_RAX, uc.UC_X86_REG_RBX,    uc.UC_X86_REG_RCX, uc.UC_X86_REG_RDX,
    uc.UC_X86_REG_RSI, uc.UC_X86_REG_RDI,    uc.UC_X86_REG_RBP, uc.UC_X86_REG_R8,
    uc.UC_X86_REG_R9,  uc.UC_X86_REG_R10,    uc.UC_X86_REG_R11, uc.UC_X86_REG_R12,
    uc.UC_X86_REG_R13, uc.UC_X86_REG_R14,    uc.UC_X86_REG_R15, uc.UC_X86_REG_RIP,
    uc.UC_X86_REG_RSP, uc.UC_X86_REG_EFLAGS,
};

const i386_fields = [_][]const u8{ "ax", "bx", "cx", "dx", "si", "di", "bp", "pc", "sp" };
const i386_regs = [_]c_int{
    uc.UC_X86_REG_EAX, uc.UC_X86_REG_EBX,    uc.UC_X86_REG_ECX, uc.UC_X86_REG_EDX,
    uc.UC_X86_REG_ESI, uc.UC_X86_REG_EDI,    uc.UC_X86_REG_EBP, uc.UC_X86_REG_EIP,
    uc.UC_X86_REG_ESP, uc.UC_X86_REG_EFLAGS,
};

comptime {
    std.debug.assert(amd64_regs.len == amd64_fields.len + 1);
    std.debug.assert(i386_regs.len == i386_fields.len + 1);
}

fn writeBatch(e: *uc.uc_engine, comptime regs: []const c_int, vals: []u64) vmm.Error!void {
    var ptrs: [regs.len]?*anyopaque = undefined;
    for (&ptrs, vals) |*p, *v| p.* = v;
    try check(uc.uc_reg_write_batch(e, regs.ptr, @ptrCast(&ptrs), regs.len));
}

// 32-bit registers in 32-bit mode: Unicorn reads and writes 4 bytes.
fn writeBatch32(e: *uc.uc_engine, comptime regs: []const c_int, vals: []u32) vmm.Error!void {
    var ptrs: [regs.len]?*anyopaque = undefined;
    for (&ptrs, vals) |*p, *v| p.* = v;
    try check(uc.uc_reg_write_batch(e, regs.ptr, @ptrCast(&ptrs), regs.len));
}

fn readBatch32(e: *uc.uc_engine, comptime regs: []const c_int, vals: []u32) vmm.Error!void {
    var ptrs: [regs.len]?*anyopaque = undefined;
    for (&ptrs, vals) |*p, *v| p.* = v;
    try check(uc.uc_reg_read_batch(e, regs.ptr, @ptrCast(&ptrs), regs.len));
}

fn readBatch(e: *uc.uc_engine, comptime regs: []const c_int, vals: []u64) vmm.Error!void {
    var ptrs: [regs.len]?*anyopaque = undefined;
    for (&ptrs, vals) |*p, *v| p.* = v;
    try check(uc.uc_reg_read_batch(e, regs.ptr, @ptrCast(&ptrs), regs.len));
}

/// XMM registers there are in `arch`'s mode: XMM8-XMM15 exist only in
/// 64-bit mode.
fn xmmCount(arch: vmm.Arch) usize {
    return if (arch == .amd64) 16 else 8;
}

/// Assembles the FXSAVE image from Unicorn's registers, which has no
/// single one for it: the x87 control, status and tag words, the last
/// opcode and instruction and data pointers, the stack registers in ST
/// order, MXCSR and the XMM registers. The pointers are kept as Unicorn
/// has them, as offsets without selectors.
fn getFxsave(e: *uc.uc_engine, comptime arch: vmm.Arch, fx: *vmm.Fxsave) vmm.Error!void {
    fx.* = .{};
    try check(uc.uc_reg_read(e, uc.UC_X86_REG_FPCW, &fx.fcw));
    try check(uc.uc_reg_read(e, uc.UC_X86_REG_FPSW, &fx.fsw));
    // The full tag word has two bits per physical register, 3 meaning
    // empty; FXSAVE keeps one, set for a register that isn't.
    var tag: u16 = 0;
    try check(uc.uc_reg_read(e, uc.UC_X86_REG_FPTAG, &tag));
    for (0..8) |i| {
        if ((tag >> @intCast(2 * i)) & 3 != 3) fx.ftw |= @as(u8, 1) << @intCast(i);
    }
    try check(uc.uc_reg_read(e, uc.UC_X86_REG_FOP, &fx.fop));
    try check(uc.uc_reg_read(e, uc.UC_X86_REG_FIP, &fx.fip));
    try check(uc.uc_reg_read(e, uc.UC_X86_REG_FDP, &fx.fdp));
    // ST0-ST7 are relative to TOP, as FXSAVE stores them.
    for (&fx.st, 0..) |*st, i| try check(uc.uc_reg_read(e, uc.UC_X86_REG_ST0 + @as(c_int, @intCast(i)), st[0..10]));
    try check(uc.uc_reg_read(e, uc.UC_X86_REG_MXCSR, &fx.mxcsr));
    fx.mxcsr_mask = 0xffff;
    for (fx.xmm[0..xmmCount(arch)], 0..) |*q, i| try check(uc.uc_reg_read(e, uc.UC_X86_REG_XMM0 + @as(c_int, @intCast(i)), q));
}

/// Loads an FXSAVE image into Unicorn's registers; see getFxsave.
fn setFxsave(e: *uc.uc_engine, comptime arch: vmm.Arch, fx: *const vmm.Fxsave) vmm.Error!void {
    try check(uc.uc_reg_write(e, uc.UC_X86_REG_FPCW, &fx.fcw));
    // The status word carries TOP, which places ST0-ST7: set it first.
    try check(uc.uc_reg_write(e, uc.UC_X86_REG_FPSW, &fx.fsw));
    for (&fx.st, 0..) |*st, i| try check(uc.uc_reg_write(e, uc.UC_X86_REG_ST0 + @as(c_int, @intCast(i)), st[0..10]));
    // Unicorn only keeps whether each register is empty.
    var tag: u16 = 0;
    for (0..8) |i| {
        if (fx.ftw & (@as(u8, 1) << @intCast(i)) == 0) tag |= @as(u16, 3) << @intCast(2 * i);
    }
    try check(uc.uc_reg_write(e, uc.UC_X86_REG_FPTAG, &tag));
    try check(uc.uc_reg_write(e, uc.UC_X86_REG_FOP, &fx.fop));
    try check(uc.uc_reg_write(e, uc.UC_X86_REG_FIP, &fx.fip));
    try check(uc.uc_reg_write(e, uc.UC_X86_REG_FDP, &fx.fdp));
    // MXCSR's reserved bits would make FXRSTOR fault; keep them clear.
    const mxcsr: u32 = fx.mxcsr & 0xffff;
    try check(uc.uc_reg_write(e, uc.UC_X86_REG_MXCSR, &mxcsr));
    for (fx.xmm[0..xmmCount(arch)], 0..) |*q, i| try check(uc.uc_reg_write(e, uc.UC_X86_REG_XMM0 + @as(c_int, @intCast(i)), q));
}

pub const Vcpu = struct {
    s: *State,

    pub fn destroy(v: *Vcpu) void {
        const s = v.s;
        _ = uc.uc_close(s.engine);
        s.mapped.deinit(s.backend.gpa);
        s.backend.gpa.destroy(s);
    }

    pub fn setAddressSpace(v: *Vcpu, as: *AddressSpace) vmm.Error!void {
        if (v.s.as == as) return;
        v.s.as = as;
        v.s.generation = 0;
    }

    pub fn getUreg(v: *Vcpu, u: *vmm.Ureg) void {
        u.* = v.s.ureg;
    }

    pub fn setUreg(v: *Vcpu, u: *const vmm.Ureg) void {
        std.debug.assert(std.meta.activeTag(u.*) == v.s.arch);
        v.s.ureg = u.*;
    }

    pub fn getExtra(v: *Vcpu, x: *vmm.Extra) vmm.Error!void {
        const e = v.s.engine;
        switch (v.s.arch) {
            .arm64 => {
                x.* = .{ .arm64 = .{} };
                const a = &x.arm64;
                for (&a.v, 0..) |*q, i| try check(uc.uc_reg_read(e, uc.UC_ARM64_REG_Q0 + @as(c_int, @intCast(i)), q));
                try check(uc.uc_reg_read(e, uc.UC_ARM64_REG_FPCR, &a.fpcr));
                try check(uc.uc_reg_read(e, uc.UC_ARM64_REG_FPSR, &a.fpsr));
                try check(uc.uc_reg_read(e, uc.UC_ARM64_REG_TPIDR_EL0, &a.tls));
            },
            inline .amd64, .i386 => |a| {
                x.* = @unionInit(vmm.Extra, @tagName(a), .{});
                const t = &@field(x, @tagName(a));
                try getFxsave(e, a, &t.fx);
                if (a == .amd64) try check(uc.uc_reg_read(e, uc.UC_X86_REG_FS_BASE, &t.tls));
            },
        }
    }

    pub fn setExtra(v: *Vcpu, x: *const vmm.Extra) vmm.Error!void {
        const e = v.s.engine;
        std.debug.assert(x.arch() == v.s.arch);
        switch (x.*) {
            .arm64 => |*a| {
                for (&a.v, 0..) |*q, i| try check(uc.uc_reg_write(e, uc.UC_ARM64_REG_Q0 + @as(c_int, @intCast(i)), q));
                try check(uc.uc_reg_write(e, uc.UC_ARM64_REG_FPCR, &a.fpcr));
                try check(uc.uc_reg_write(e, uc.UC_ARM64_REG_FPSR, &a.fpsr));
                try check(uc.uc_reg_write(e, uc.UC_ARM64_REG_TPIDR_EL0, &a.tls));
            },
            inline .amd64, .i386 => |*t, a| {
                try setFxsave(e, a, &t.fx);
                if (a == .amd64) try check(uc.uc_reg_write(e, uc.UC_X86_REG_FS_BASE, &t.tls));
            },
        }
    }

    /// Safe from any thread. A kick before `run` makes the next run return
    /// `.interrupted` at once.
    pub fn kick(v: *Vcpu) void {
        const s = v.s;
        s.kicked.store(true, .seq_cst);
        _ = uc.uc_emu_stop(s.engine);
        // uc_emu_start clears Unicorn's stop request, so a stop landing
        // just before it is lost. Repeat it until the run has seen the kick
        // (taking `kicked`) or ended. The bound only guards against a run
        // stuck outside Unicorn; a running engine stops within microseconds.
        var tries: u32 = 0;
        while (s.in_run.load(.seq_cst) and s.kicked.load(.seq_cst) and tries < 10_000) : (tries += 1) {
            std.Thread.yield() catch {};
            if (tries % 16 == 15) _ = uc.uc_emu_stop(s.engine);
        }
    }

    pub fn run(v: *Vcpu) vmm.Error!vmm.Exit {
        return v.s.run();
    }
};
