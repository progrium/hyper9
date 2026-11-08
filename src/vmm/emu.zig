//! Emulator backend (Unicorn). Built with -Demu=unicorn. See DESIGN.md,
//! "Emulator backend (emu)".
//!
//! User mode only: each vCPU is a Unicorn engine running at EL0 (arm64), in
//! flat 64-bit mode (amd64) or in flat 32-bit protected mode (386), with no
//! MMU and no guest kernel. Hooks turn
//! syscall instructions, invalid memory accesses and CPU exceptions into
//! vmm exits, doing the shim's job. Guest pages come from one reserved
//! range of host memory (arena.zig), mapped into each engine once as its
//! physical memory, so the host and the guest share them. Engines run in
//! Unicorn's virtual-TLB mode: a fill hook translates a guest address
//! through the address space's regions, so a change to the address space
//! never changes Unicorn's memory map, whose every change rebuilds it
//! (design/0018-linux-personality.md, "The emulator in virtual-TLB mode").

const std = @import("std");
const vmm = @import("../vmm.zig");
const arm64 = @import("../arch/arm64.zig");
const amd64 = @import("../arch/amd64.zig");
const ia32 = @import("../arch/i386.zig");
const uc = @import("unicorn");
const Arena = @import("arena.zig");

/// Unicorn's runtime version, e.g. "2.1".
pub fn version(buf: []u8) []const u8 {
    var major: c_uint = 0;
    var minor: c_uint = 0;
    _ = uc.uc_version(&major, &minor);
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ major, minor }) catch buf[0..0];
}

/// Where the arena sits in each engine's physical address space.
const phys_base: u64 = 1 << 32;
/// Physical pages with nothing behind them, which a fill hook hands out
/// for an address the guest may not touch: the access then reaches the
/// unmapped-memory hook with its offset in the page intact, which the
/// fill hook alone can't give (it sees only the page).
const trap_base: u64 = 0;
const trap_slots = 8;

/// Where a 386 engine's GDT is, in every address space: the top page,
/// above any user mapping (9front's stack ends at 0xDFFFF000 and a Linux
/// process's address space at 0xC0000000). It holds the TLS segment Linux
/// programs load %gs with (design/linux-i386.md, "TLS"). Each engine has
/// its own page, which the fill hook maps here read-only.
const gdt_va: u64 = 0xFFFF_F000;
/// Its entries: the null one, then up to Linux's TLS entry.
const gdt_entries = 7;

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

/// How long an engine runs guest code while another waits for the guest
/// lock, before it's asked to stop (design/0049-linux-threads.md).
const slice_ns = 1 * std.time.ns_per_ms;
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

pub const Backend = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arch: vmm.Arch,
    lock: std.Io.Mutex = .init,
    /// Where guest pages come from, under `lock`.
    arena: Arena,
    /// Bytes handed out, against the cap in `limit`.
    used: u64 = 0,
    limit: u64,
    guest: GuestLock = .{},
    /// The engine holding `guest`, which a waiter asks to stop when its
    /// slice is up.
    holder: std.atomic.Value(?*State) = .init(null),

    /// Takes the guest lock for `s` (null: for a shootdown). A waiter that
    /// sees the same holder for a whole slice asks it to stop at its next
    /// block (design/0049-linux-threads.md, "Time-slicing").
    fn acquireGuest(b: *Backend, s: ?*State) void {
        const g = &b.guest;
        const ticket = g.next.fetchAdd(1, .acq_rel);
        while (true) {
            const cur = g.serving.load(.acquire);
            if (cur == ticket) break;
            b.io.futexWaitTimeout(u32, &g.serving.raw, cur, .{ .duration = .{ .raw = .fromNanoseconds(slice_ns), .clock = .awake } }) catch {};
            if (g.serving.load(.acquire) == cur) {
                if (b.holder.load(.acquire)) |h| h.stop_req.store(true, .release);
            }
        }
        b.holder.store(s, .release);
    }

    fn releaseGuest(b: *Backend) void {
        b.holder.store(null, .release);
        b.guest.release(b.io);
    }

    pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: vmm.Options) vmm.CreateError!*Backend {
        // Fail here, not at the first vCPU, if Unicorn lacks the architecture.
        _ = uc.uc_close(try open(opts.arch));
        const limit = opts.memory orelse vmm.default_memory;
        if (limit > vmm.max_memory) return error.OutOfGuestMemory;
        // Twice the cap in address space, so freed ranges scattered
        // through it don't run allocations out before the cap does.
        var arena = Arena.init(std.mem.alignForward(usize, @intCast(2 * limit), vmm.page_size)) catch return error.OutOfGuestMemory;
        errdefer arena.deinit(gpa);
        const b = try gpa.create(Backend);
        b.* = .{ .gpa = gpa, .io = io, .arch = opts.arch, .limit = limit, .arena = arena };
        return b;
    }

    pub fn destroy(b: *Backend) void {
        b.arena.deinit(b.gpa);
        b.gpa.destroy(b);
    }

    /// No hardware limit; this keeps the number in line with HVF's.
    pub fn maxVcpus(_: *Backend) vmm.Error!u32 {
        return 64;
    }

    /// Returns zeroed pages. Pages nothing touches stay unbacked on the
    /// host: a Go program reserves several hundred MB of brk at start.
    pub fn allocPages(b: *Backend, n: usize) vmm.Error![]align(vmm.page_size) u8 {
        const len = n * vmm.page_size;
        if (len == 0) return error.BadAddress;
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        if (b.used + len > b.limit) return error.OutOfGuestMemory;
        const mem = b.arena.alloc(b.gpa, len) catch return error.OutOfGuestMemory;
        b.used += len;
        return mem;
    }

    /// Returns pages from `allocPages`, no longer mapped.
    pub fn freePages(b: *Backend, mem: []align(vmm.page_size) u8) void {
        if (mem.len == 0) return;
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.used -= mem.len;
        b.arena.freePages(b.gpa, mem);
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
        errdefer if (s.gdt) |g| b.freePages(g);
        if (b.arch == .i386) {
            s.gdt = try b.allocPages(1);
            // Flat 32-bit ring-0 code and data, which the engine runs
            // with (see below).
            std.mem.writeInt(u64, s.gdt.?[8..16], 0x00cf9b00_0000ffff, .little);
            std.mem.writeInt(u64, s.gdt.?[16..24], 0x00cf9300_0000ffff, .little);
            s.setTlsDesc(0);
            var gdtr: uc.uc_x86_mmr = .{ .selector = 0, .base = gdt_va, .limit = gdt_entries * 8 - 1, .flags = 0 };
            try check(uc.uc_reg_write(s.engine, uc.UC_X86_REG_GDTR, &gdtr));
        }
        try check(uc.uc_ctl(s.engine, uc_ctl_tlb_type, @as(c_int, uc.UC_TLB_VIRTUAL)));
        try check(uc.uc_mem_map_ptr(s.engine, phys_base, b.arena.mem.len, uc.UC_PROT_ALL, b.arena.mem.ptr));
        try s.addHooks();
        if (b.arch == .i386) {
            // Unicorn's 32-bit mode leaves the segment caches empty and
            // sets the 32-bit flags by hand, but any segment load (as of
            // %gs) recomputes them from the caches, which would make the
            // stack 16-bit. Loading real descriptors makes them stick.
            inline for (.{ .{ uc.UC_X86_REG_CS, 0x08 }, .{ uc.UC_X86_REG_SS, 0x10 }, .{ uc.UC_X86_REG_DS, 0x10 }, .{ uc.UC_X86_REG_ES, 0x10 } }) |r| {
                var v: u16 = r[1];
                try check(uc.uc_reg_write(s.engine, r[0], &v));
            }
        }
        if (b.arch == .arm64) {
            // CNTKCTL_EL1: EL0 may read the counter and its frequency, as
            // Linux allows (Go's procyield reads both).
            var r: uc.uc_arm64_cp_reg = .{ .crn = 14, .crm = 1, .op0 = 3, .op1 = 0, .op2 = 0, .val = 3 };
            try check(uc.uc_reg_write(s.engine, uc.UC_ARM64_REG_CP_REG, &r));
        }
        return .{ .s = s };
    }
};

/// The emulator keeps the mappings itself; vCPUs copy them into their
/// engines when they switch to the address space or it changes, under the
/// guest lock, so no engine runs with mappings older than a change made
/// before it took the lock.
pub const AddressSpace = struct {
    backend: *Backend,
    regions: std.ArrayList(Region) = .empty,
    /// Bumped on every change, so vCPUs know to remap.
    generation: std.atomic.Value(u64) = .init(1),
    /// Bumped by `codeChanged`, so vCPUs drop their translated blocks.
    code: std.atomic.Value(u64) = .init(0),
    /// Guards `regions`: threads of one process change and read them at
    /// once (design/0049-linux-threads.md).
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
        _ = as.generation.fetchAdd(1, .release);
    }

    pub fn unmap(as: *AddressSpace, va: u64) void {
        as.lockSpin();
        defer as.lock.unlock();
        for (as.regions.items, 0..) |r, i| if (r.va == va) {
            _ = as.regions.swapRemove(i);
            _ = as.generation.fetchAdd(1, .release);
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
    /// translated blocks before their next run. The whole cache goes;
    /// design/0010-self-host.md leaves flushing only the written range
    /// (uc_ctl_remove_cache) until stepping shows the need.
    pub fn codeChanged(as: *AddressSpace, _: u64, _: u64) void {
        _ = as.code.fetchAdd(1, .release);
    }

    /// One engine runs at a time, under the guest lock, and syncs its
    /// mappings after taking it: so once this has taken and passed on the
    /// lock, no engine still runs with the old ones.
    pub fn shootdown(as: *AddressSpace) void {
        as.backend.acquireGuest(null);
        as.backend.releaseGuest();
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
/// The lock is passed on at an exit (a syscall, a fault or a kick), and
/// when a waiter has waited a slice (`Backend.acquireGuest`), so a guest
/// that spins without syscalls doesn't hold the others off. The holder
/// stops itself, from a block hook on its own thread: stopping an engine
/// from another thread with `uc_emu_stop` can leave its PC at an earlier
/// block than the one it stopped at, so resuming would run instructions
/// twice (design/0049-linux-threads.md, "Time-slicing on the emulator").
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
    /// A kick, or the end of the engine's slice.
    preempted,
};

/// Heap state behind a Vcpu, so the hooks have a stable pointer.
const State = struct {
    backend: *Backend,
    arch: vmm.Arch,
    engine: *uc.uc_engine,
    ureg: vmm.Ureg,
    as: ?*AddressSpace = null,
    /// The address space's regions as of the last sync, sorted by
    /// address, which the fill hook searches.
    mapped: std.ArrayList(AddressSpace.Region) = .empty,
    /// The pages of the trap entries handed out since the TLB was last
    /// flushed, by slot.
    trap_va: [trap_slots]u64 = @splat(0),
    ntrap: u32 = 0,
    generation: u64 = 0,
    /// The space's `code` when this engine last flushed its blocks.
    code: u64 = 0,
    stop: Stop = .none,
    /// The vector of the last syscall exit on 386: INT $64 (9front's) or
    /// int 0x80 (Linux's).
    sys_vector: u32 = ia32.vector_syscall,
    /// 386: this engine's GDT page (see `gdt_va`), the TLS base its entry
    /// holds, and the %gs selector last loaded, or null to load it again.
    gdt: ?[]align(vmm.page_size) u8 = null,
    tls: u32 = 0,
    gs: ?u32 = null,
    kicked: std.atomic.Value(bool) = .init(false),
    /// Asks the engine to stop at its next block: set by a kick and by a
    /// guest-lock waiter whose slice is up, and seen by `onBlock` on the
    /// engine's own thread. Stopping from another thread with
    /// uc_emu_stop can leave the PC at an earlier block.
    stop_req: std.atomic.Value(bool) = .init(false),

    fn addHooks(s: *State) vmm.Error!void {
        var h: uc.uc_hook = 0;
        try check(uc.uc_hook_add(s.engine, &h, uc.UC_HOOK_BLOCK, @ptrCast(@constCast(&onBlock)), s, 1, 0));
        try check(uc.uc_hook_add(s.engine, &h, uc.UC_HOOK_MEM_INVALID, @ptrCast(@constCast(&onMemInvalid)), s, 1, 0));
        try check(uc.uc_hook_add(s.engine, &h, uc.UC_HOOK_TLB_FILL, @ptrCast(@constCast(&onTlbFill)), s, 1, 0));
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
        // INT $64, or Linux's int 0x80; Unicorn has already moved EIP past it.
        if (s.arch == .i386 and (intno == ia32.vector_syscall or intno == ia32.vector_linux)) {
            s.sys_vector = intno;
            return s.halt(.syscall);
        }
        // BRK, with the PC left at it; INT3, with EIP past it as for INT $64.
        if (s.arch == .arm64 and intno == arm64_excp_bkpt) return s.halt(.breakpoint);
        if (s.arch != .arm64 and intno == x86_vector_bp) return s.halt(.breakpoint);
        s.halt(.{ .exception = intno });
    }

    fn onBlock(_: ?*uc.uc_engine, _: u64, _: u32, data: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(data));
        if (!s.stop_req.load(.monotonic)) return;
        s.stop_req.store(false, .monotonic);
        if (s.stop == .none) s.halt(.preempted);
    }

    fn onSyscall(_: ?*uc.uc_engine, data: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(data));
        s.halt(.syscall);
    }

    /// Translates a guest page for the TLB. An address the guest may not
    /// access this way gets a trap page instead (see `trap_base`).
    fn onTlbFill(_: ?*uc.uc_engine, va: u64, kind: uc.uc_mem_type, out: *uc.uc_tlb_entry, data: ?*anyopaque) callconv(.c) bool {
        const s: *State = @ptrCast(@alignCast(data));
        if (s.gdt) |g| if (va & ~@as(u64, vmm.page_size - 1) == gdt_va and kind == uc.UC_MEM_READ) {
            out.paddr = phys_base + s.backend.arena.offsetOf(g.ptr) + (va - gdt_va);
            out.perms = uc.UC_PROT_READ;
            return true;
        };
        if (s.find(va)) |r| {
            const ok = switch (kind) {
                uc.UC_MEM_WRITE => r.perms.write,
                uc.UC_MEM_FETCH => r.perms.exec,
                else => r.perms.read,
            };
            if (ok) {
                out.paddr = phys_base + s.backend.arena.offsetOf(r.mem.ptr) + (va - r.va);
                out.perms = @intCast(prot(r.perms));
                return true;
            }
        }
        const slot: u64 = @min(s.ntrap, trap_slots - 1);
        s.trap_va[slot] = va;
        s.ntrap += 1;
        out.paddr = trap_base + slot * vmm.page_size;
        out.perms = uc.UC_PROT_ALL;
        return true;
    }

    /// The region holding `va`, by binary search.
    fn find(s: *State, va: u64) ?*const AddressSpace.Region {
        const items = s.mapped.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const r = &items[mid];
            if (va < r.va) hi = mid else if (va - r.va >= r.mem.len) lo = mid + 1 else return r;
        }
        return null;
    }

    /// An access to a trap page: `paddr` is the trap page's address with
    /// the access's offset in the page.
    fn onMemInvalid(_: ?*uc.uc_engine, kind: uc.uc_mem_type, paddr: u64, _: c_int, _: i64, data: ?*anyopaque) callconv(.c) bool {
        const s: *State = @ptrCast(@alignCast(data));
        const access: @FieldType(vmm.Fault, "access") = switch (kind) {
            uc.UC_MEM_WRITE_UNMAPPED, uc.UC_MEM_WRITE_PROT => .write,
            uc.UC_MEM_FETCH_UNMAPPED, uc.UC_MEM_FETCH_PROT => .exec,
            else => .read,
        };
        const off = paddr -% trap_base;
        const slot = off / vmm.page_size;
        const addr = if (slot < trap_slots) s.trap_va[slot] + off % vmm.page_size else paddr;
        s.stop = .{ .fault = .{ .addr = addr, .access = access, .syndrome = @intCast(kind) } };
        return false; // Unicorn stops with an error, leaving the PC at the access
    }

    /// Makes the engine's view match the address space: the regions the
    /// fill hook searches, and its TLB and translated blocks where a
    /// change could leave them stale.
    fn sync(s: *State) vmm.Error!void {
        // Trap entries name their slots, which start over after a flush.
        if (s.ntrap > 0) {
            try check(uc.uc_ctl(s.engine, uc_ctl_tlb_flush));
            s.ntrap = 0;
        }
        const as = s.as orelse return;
        const code = as.code.load(.acquire);
        if (s.code != code) {
            // The host wrote code (codeChanged).
            try check(uc.uc_ctl(s.engine, uc_ctl_tb_flush));
            s.code = code;
        }
        if (s.generation == as.generation.load(.acquire)) return;
        as.lockSpin();
        defer as.lock.unlock();
        const gpa = s.backend.gpa;
        // A region gone or changed may be in the TLB; a new one can't be.
        // Translated blocks are keyed by physical address, so only an
        // executable region's own are dropped with it, found through the
        // old mappings while the fill hook still has them.
        var dropped = false;
        {
            var have: std.AutoHashMapUnmanaged(u64, AddressSpace.Region) = .empty;
            defer have.deinit(gpa);
            have.ensureTotalCapacity(gpa, @intCast(as.regions.items.len)) catch return error.OutOfGuestMemory;
            for (as.regions.items) |r| have.putAssumeCapacity(r.va, r);
            for (s.mapped.items) |r| {
                if (have.get(r.va)) |w| {
                    if (w.mem.ptr == r.mem.ptr and w.mem.len == r.mem.len and w.perms == r.perms) continue;
                }
                dropped = true;
                if (r.perms.exec) try check(uc.uc_ctl(s.engine, uc_ctl_tb_remove, r.va, r.va + r.mem.len));
            }
        }
        s.mapped.clearRetainingCapacity();
        s.mapped.appendSlice(gpa, as.regions.items) catch return error.OutOfGuestMemory;
        std.mem.sortUnstable(AddressSpace.Region, s.mapped.items, {}, struct {
            fn lt(_: void, a: AddressSpace.Region, b: AddressSpace.Region) bool {
                return a.va < b.va;
            }
        }.lt);
        if (dropped) try check(uc.uc_ctl(s.engine, uc_ctl_tlb_flush));
        s.generation = as.generation.load(.acquire);
    }

    /// Sets the TLS entry's base: a flat 4 GiB, 32-bit, writable data
    /// segment for user mode, already accessed (so the CPU never writes
    /// the read-only page), as set_thread_area makes it.
    fn setTlsDesc(s: *State, base: u32) void {
        const g = s.gdt orelse return;
        const d: u64 = 0xffff | (@as(u64, base & 0xffffff) << 16) | (@as(u64, 0xf3) << 40) | (@as(u64, 0xcf) << 48) | (@as(u64, base >> 24) << 56);
        std.mem.writeInt(u64, g[8 * sig_tls_entry ..][0..8], d, .little);
        s.tls = base;
        // A loaded %gs keeps the old base until it's loaded again.
        s.gs = null;
    }

    /// Loads %gs from the Ureg, which reads its descriptor from the GDT:
    /// the null selector, or the TLS one. Anything else would fault the
    /// load, so it becomes null.
    fn loadGs(s: *State, sel: u32) vmm.Error!void {
        if (s.gs == sel) return;
        var v: u16 = if (sel == (sig_tls_entry << 3) | 3) @intCast(sel) else 0;
        if (uc.uc_reg_write(s.engine, uc.UC_X86_REG_GS, &v) != uc.UC_ERR_OK) {
            v = 0;
            try check(uc.uc_reg_write(s.engine, uc.UC_X86_REG_GS, &v));
        }
        s.gs = v;
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
                try s.loadGs(u.gs);
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
                // A Linux program loads %gs itself.
                var gs: u16 = 0;
                try check(uc.uc_reg_read(s.engine, uc.UC_X86_REG_GS, &gs));
                u.gs = gs;
                s.gs = gs;
            },
        }
    }

    fn run(s: *State) vmm.Error!vmm.Exit {
        if (s.as == null) return error.BadAddress;
        if (s.kicked.swap(false, .seq_cst)) return .interrupted;
        try s.writeRegs();
        s.stop = .none;
        const b = s.backend;
        b.acquireGuest(s);
        // A kick from here on sets `stop_req`, which the first block sees.
        if (s.kicked.swap(false, .seq_cst)) {
            b.releaseGuest();
            return .interrupted;
        }
        s.sync() catch |e| {
            b.releaseGuest();
            return e;
        };
        const err = uc.uc_emu_start(s.engine, s.ureg.pc(), std.math.maxInt(u64), 0, 0);
        b.releaseGuest();
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
            .preempted => {
                // A kick's request is taken here; a slice's needs no more.
                _ = s.kicked.swap(false, .acquire);
                return .interrupted;
            },
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
            .i386 => |*u| u.trap = s.sys_vector,
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
// uc_ctl_remove_cache: UC_CTL_WRITE(UC_CTL_TB_REMOVE_CACHE, 2).
const uc_ctl_tb_remove: c_uint = uc.UC_CTL_TB_REMOVE_CACHE | (2 << 26) | (1 << 30);
// uc_ctl_flush_tlb: UC_CTL_WRITE(UC_CTL_TLB_FLUSH, 0).
const uc_ctl_tlb_flush: c_uint = uc.UC_CTL_TLB_FLUSH | (1 << 30);
// uc_ctl_tlb_mode: UC_CTL_WRITE(UC_CTL_TLB_TYPE, 1).
const uc_ctl_tlb_type: c_uint = uc.UC_CTL_TLB_TYPE | (1 << 26) | (1 << 30);

// QEMU's arm64 exception numbers, as passed to UC_HOOK_INTR.
const arm64_excp_swi = 2;
const arm64_excp_bkpt = 7;
// i386 Linux's TLS entry in the GDT (linux/signal.zig).
const sig_tls_entry = 6;
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
        if (s.gdt) |g| s.backend.freePages(g);
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
                if (a == .i386) t.tls = v.s.tls;
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
                if (a == .i386 and t.tls != v.s.tls) v.s.setTlsDesc(@truncate(t.tls));
            },
        }
    }

    /// Safe from any thread. A kick before `run` makes the next run return
    /// `.interrupted` at once; during one, the engine stops at its next
    /// block (`onBlock`).
    pub fn kick(v: *Vcpu) void {
        const s = v.s;
        s.kicked.store(true, .seq_cst);
        s.stop_req.store(true, .seq_cst);
    }

    pub fn run(v: *Vcpu) vmm.Error!vmm.Exit {
        return v.s.run();
    }
};
