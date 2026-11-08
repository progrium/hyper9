//! v86 backend: 386 guests on v86's CPU core, in the web host's wasm
//! memory. See design/0012-browser-host.md, "The v86 backend".
//!
//! v86.wasm and h9.wasm share one linear memory, so v86's guest RAM, its
//! register block and h9's heap are all addresses here: an address
//! space's pages are slices of guest RAM, and the backend reads and
//! writes v86's registers in place. The JS host (src/web/h9-web.js)
//! instantiates v86 and passes its exports through as imports.
//!
//! A small guest kernel, src/arch/i386/shim.S, runs at ring 0. Every
//! trap, INT $64, and Linux's int 0x80 pushes a 9front Ureg on its stack and halts, which
//! ends v86's run loop; the backend reads the Ureg there. Resuming writes
//! the Ureg back and runs the shim's iret path. One v86 CPU runs every
//! vCPU: a vCPU is a context (Ureg, FXSAVE image, address space) that
//! `run` installs.

const std = @import("std");
const vmm = @import("../vmm.zig");
const ia32 = @import("../arch/i386.zig");
const coro = @import("../web/coro.zig");

/// The shim, assembled by build.zig.
const shim = @embedFile("shim_i386");

// v86's imports, through the JS host. main_loop runs guest code for a
// slice of about 1 ms, or until the CPU halts with interrupts off.
const js = struct {
    extern "v86" fn init(memory: u32) u32;
    extern "v86" fn main_loop() void;
    extern "v86" fn reset_cpu() void;
    extern "v86" fn full_clear_tlb() void;
    extern "v86" fn update_state_flags() void;
    extern "v86" fn get_eflags() i32;
    extern "v86" fn jit_dirty_cache(start: u32, end: u32) void;
};

/// v86's register block (v86 0.5.473's src/rust/cpu/global_pointers.rs),
/// at fixed addresses in the shared memory. Not a stable ABI:
/// scripts/pins.sh records the offsets with the release, and the web
/// tests check them against the pinned v86.wasm.
const regs = struct {
    const reg32 = 64; // 8 x i32: EAX ECX EDX EBX ESP EBP ESI EDI
    const segment_access_bytes = 512; // 8 x u8
    const instruction_pointer = 556;
    const cr = 580; // 8 x i32
    const cpl = 612;
    const in_hlt = 616;
    const sreg = 668; // 8 x u16: ES CS SS DS FS GS
    const segment_is_null = 724; // 8 x u8
    const segment_offsets = 736; // 8 x i32
    const segment_limits = 768; // 8 x u32
    const is_32 = 804;
    const stack_size_32 = 808;
    const memory_size = 812;
};

const ES = 0;
const CS = 1;
const SS = 2;
const DS = 3;
const FS = 4;
const GS = 5;

fn reg(comptime T: type, comptime off: usize) *volatile T {
    return @ptrFromInt(off);
}

fn reg32(i: usize) *volatile u32 {
    return @ptrFromInt(regs.reg32 + 4 * i);
}

// The shim's layout in guest-physical memory (src/arch/i386/shim.S).
const shim_base = 0x1000;
const kzero = 0xF000_0000;
/// How long `run` keeps the CPU across exits before it lets the other
/// coroutines run: about one of main_loop's slices.
const slice_ns = 2 * std.time.ns_per_ms;

fn monoNs() u64 {
    var t: std.os.wasi.timestamp_t = 0;
    _ = std.os.wasi.clock_time_get(.MONOTONIC, 1, &t);
    return t;
}

/// The shim's GDT entry for Linux TLS, as linux/signal.zig's
/// i386_tls_entry: selector 0x33.
const tls_entry = 6;
const cr2_slot = 0x500;
const fx_area = 0x6800;
const kstack_top = 0x8000;
/// The page table that maps the low 1 MiB at KZERO, supervisor only, in
/// every address space.
const kernel_pt = 0x9000;
const boot_pd = 0xA000;
/// Below this, guest RAM is the shim's; pages for address spaces come
/// from above it.
const reserved = 1 << 20;

const ureg_size = @sizeOf(ia32.Ureg);
const ureg_at = kstack_top - ureg_size;

const PTE_P = 1;
const PTE_W = 2;
const PTE_U = 4;

/// Guest RAM when no cap is given: a browser tab's memory is scarcer than
/// a host's, and wasm32 addresses 4 GiB in all, h9's heap included.
pub const default_memory: u64 = 256 << 20;
pub const max_memory: u64 = 2 << 30;

/// The one live backend: there's one v86 CPU per Worker.
var live: ?*Backend = null;

pub const Backend = struct {
    gpa: std.mem.Allocator,
    /// Guest RAM: guest-physical 0 is ram[0].
    ram: []align(vmm.page_size) u8,
    /// Free page ranges above `reserved`, by address.
    free: std.ArrayList(Range) = .empty,
    used: u64 = 0,
    /// The installed context: CR3 and the generation of its address space,
    /// and whose FP state the CPU holds.
    cur_as: ?*AddressSpace = null,
    cur_gen: u64 = 0,
    fp_owner: ?*State = null,
    /// The shim's entry points, as guest-virtual addresses.
    restore: u32,
    fxsave: u32,
    fxrstor: u32,
    /// The shim's GDT, and the TLS base its Linux TLS entry holds
    /// (design/linux-i386.md, "TLS").
    gdt: u32,
    gdt_tls: u32 = 0,
    /// When `run` last let the other coroutines run, in monotonic ns.
    yielded: u64 = 0,

    const Range = struct { start: usize, len: usize };

    pub fn create(gpa: std.mem.Allocator, _: std.Io, opts: vmm.Options) vmm.CreateError!*Backend {
        if (opts.arch != .i386) return error.WrongArch;
        if (live != null) return error.HypervisorUnavailable;
        const size = opts.memory orelse default_memory;
        if (size > max_memory or size < 2 * reserved) return error.OutOfGuestMemory;
        const base = js.init(@intCast(size));
        if (base == 0) return error.HypervisorUnavailable;
        const ram: [*]align(vmm.page_size) u8 = @ptrFromInt(base);
        const b = try gpa.create(Backend);
        errdefer gpa.destroy(b);
        b.* = .{
            .gpa = gpa,
            .ram = ram[0..@intCast(size)],
            .restore = kzero + shim_base + std.mem.readInt(u32, shim[4..8], .little),
            .fxsave = kzero + shim_base + std.mem.readInt(u32, shim[8..12], .little),
            .fxrstor = kzero + shim_base + std.mem.readInt(u32, shim[12..16], .little),
            .gdt = shim_base + std.mem.readInt(u32, shim[16..20], .little),
        };
        try b.free.append(gpa, .{ .start = reserved, .len = b.ram.len - reserved });
        try b.boot();
        live = b;
        return b;
    }

    /// Loads the shim and runs it to its first halt: protected mode,
    /// paging, the descriptor tables, then ring 0 at KZERO.
    fn boot(b: *Backend) vmm.Error!void {
        @memset(b.ram[0..reserved], 0);
        @memcpy(b.ram[shim_base..][0..shim.len], shim);
        // The low 1 MiB, supervisor, at 0 (for the switch to paging) and
        // at KZERO.
        const pt = b.words(kernel_pt);
        for (pt[0..256], 0..) |*e, i| e.* = @as(u32, @intCast(i << 12)) | PTE_P | PTE_W;
        const pd = b.words(boot_pd);
        pd[0] = kernel_pt | PTE_P | PTE_W;
        pd[kzero >> 22] = kernel_pt | PTE_P | PTE_W;
        js.reset_cpu();
        reg(u16, regs.sreg + 2 * CS).* = 0;
        reg(i32, regs.segment_offsets + 4 * CS).* = 0;
        reg(u32, regs.instruction_pointer).* = shim_base;
        var i: u32 = 0;
        while (reg(u8, regs.in_hlt).* == 0) : (i += 1) {
            if (i > 1000) return error.HypervisorFailed;
            js.main_loop();
        }
        if (reg(u32, regs.instruction_pointer).* < kzero) return error.HypervisorFailed;
        b.cur_as = null;
        b.fp_owner = null;
    }

    fn words(b: *Backend, at: usize) *[1024]u32 {
        return @ptrCast(@alignCast(b.ram[at..][0..vmm.page_size]));
    }

    pub fn destroy(b: *Backend) void {
        b.free.deinit(b.gpa);
        live = null;
        b.gpa.destroy(b);
    }

    /// vCPUs are contexts on one CPU, so they cost only memory.
    pub fn maxVcpus(_: *Backend) vmm.Error!u32 {
        return 1 << 16;
    }

    /// Returns zeroed pages of guest RAM, first fit.
    pub fn allocPages(b: *Backend, n: usize) vmm.Error![]align(vmm.page_size) u8 {
        const len = n * vmm.page_size;
        if (len == 0) return error.BadAddress;
        for (b.free.items, 0..) |*r, i| {
            if (r.len < len) continue;
            const start = r.start;
            r.start += len;
            r.len -= len;
            if (r.len == 0) _ = b.free.orderedRemove(i);
            b.used += len;
            const mem: []align(vmm.page_size) u8 = @alignCast(b.ram[start..][0..len]);
            @memset(mem, 0);
            return mem;
        }
        return error.OutOfGuestMemory;
    }

    /// Returns pages to the free list. Code v86 compiled from them is
    /// dropped, since h9's writes to them don't go through v86.
    pub fn freePages(b: *Backend, mem: []align(vmm.page_size) u8) void {
        const start = b.phys(mem.ptr);
        js.jit_dirty_cache(@intCast(start), @intCast(start + mem.len));
        b.used -= mem.len;
        var i: usize = 0;
        while (i < b.free.items.len and b.free.items[i].start < start) i += 1;
        // Merge with the neighbours where they touch.
        const prev_touch = i > 0 and b.free.items[i - 1].start + b.free.items[i - 1].len == start;
        const next_touch = i < b.free.items.len and start + mem.len == b.free.items[i].start;
        if (prev_touch and next_touch) {
            b.free.items[i - 1].len += mem.len + b.free.items[i].len;
            _ = b.free.orderedRemove(i);
        } else if (prev_touch) {
            b.free.items[i - 1].len += mem.len;
        } else if (next_touch) {
            b.free.items[i].start = start;
            b.free.items[i].len += mem.len;
        } else {
            // Out of memory for the list: the pages are lost, not reused.
            b.free.insert(b.gpa, i, .{ .start = start, .len = mem.len }) catch {};
        }
    }

    fn phys(b: *Backend, p: [*]const u8) usize {
        return @intFromPtr(p) - @intFromPtr(b.ram.ptr);
    }

    pub fn newAddressSpace(b: *Backend) vmm.CreateError!*AddressSpace {
        const pd = try b.allocPages(1);
        errdefer b.freePages(pd);
        const as = try b.gpa.create(AddressSpace);
        as.* = .{ .backend = b, .pd = pd };
        as.dir()[kzero >> 22] = kernel_pt | PTE_P | PTE_W;
        return as;
    }

    pub fn createVcpu(b: *Backend) vmm.CreateError!Vcpu {
        const s = try b.gpa.create(State);
        s.* = .{ .backend = b };
        return .{ .s = s };
    }

    /// Runs the shim from `entry` (one of its helpers) to its halt.
    fn runShim(_: *Backend, entry: u32) vmm.Error!void {
        reg32(4).* = kzero + kstack_top;
        reg(u32, regs.instruction_pointer).* = entry;
        reg(u8, regs.in_hlt).* = 0;
        var i: u32 = 0;
        while (reg(u8, regs.in_hlt).* == 0) : (i += 1) {
            if (i > 100) return error.HypervisorFailed;
            js.main_loop();
        }
    }

    /// Saves the CPU's FP state into its owner's context.
    fn saveFp(b: *Backend, s: *State) vmm.Error!void {
        try b.runShim(b.fxsave);
        @memcpy(std.mem.asBytes(&s.fx), b.ram[fx_area..][0..@sizeOf(vmm.Fxsave)]);
        b.fp_owner = null;
    }

    fn loadFp(b: *Backend, s: *State) vmm.Error!void {
        @memcpy(b.ram[fx_area..][0..@sizeOf(vmm.Fxsave)], std.mem.asBytes(&s.fx));
        try b.runShim(b.fxrstor);
        b.fp_owner = s;
    }

    /// Points CR3 at the address space, flushing v86's TLB when it
    /// changes or lost a mapping.
    fn install(b: *Backend, as: *AddressSpace) void {
        if (b.cur_as == as and b.cur_gen == as.generation) return;
        reg(u32, regs.cr + 4 * 3).* = @intCast(b.phys(as.pd.ptr));
        js.full_clear_tlb();
        b.cur_as = as;
        b.cur_gen = as.generation;
    }

    /// Sets the Linux TLS entry's base. The restore path reloads %gs, so
    /// the next run sees it.
    fn setTls(b: *Backend, base: u32) void {
        if (b.gdt_tls == base) return;
        const d: u64 = 0xffff | (@as(u64, base & 0xffffff) << 16) | (@as(u64, 0xf3) << 40) | (@as(u64, 0xcf) << 48) | (@as(u64, base >> 24) << 56);
        std.mem.writeInt(u64, b.ram[b.gdt + 8 * tls_entry ..][0..8], d, .little);
        b.gdt_tls = base;
    }

    /// Writes the Ureg at the top of the kernel stack and points the CPU
    /// at the shim's restore path, which pops it and returns to user mode.
    fn writeUreg(b: *Backend, u: *const ia32.Ureg) void {
        @memcpy(b.ram[ureg_at..][0..ureg_size], std.mem.asBytes(u));
        reg32(4).* = kzero + ureg_at;
        reg(u32, regs.instruction_pointer).* = b.restore;
        // With interrupts off, main_loop treats a halted CPU as dead and
        // returns at once; v86 exports nothing that clears the halt.
        reg(u8, regs.in_hlt).* = 0;
    }

    /// The exit for a trap: the Ureg the shim pushed.
    fn exit(b: *Backend, s: *State) vmm.Exit {
        // A trap in the shim itself (an iret that faults on a bad Ureg,
        // say) pushes a shorter frame elsewhere on the kernel stack.
        if (reg32(4).* != kzero + ureg_at) return .{ .other = 0x386 };
        @memcpy(std.mem.asBytes(&s.ureg), b.ram[ureg_at..][0..ureg_size]);
        const u = &s.ureg;
        return switch (u.trap) {
            ia32.vector_syscall, ia32.vector_linux => .syscall,
            // Without PAE's NX bit a fetch fault looks like a read, except
            // that it faults at the PC.
            14 => blk: {
                const addr = std.mem.readInt(u32, b.ram[cr2_slot..][0..4], .little);
                break :blk .{ .fault = .{
                    .addr = addr,
                    .access = if (u.ecode & 2 != 0) .write else if (addr == u.pc) .exec else .read,
                    .syndrome = u.ecode,
                } };
            },
            else => .{ .fault = .{ .addr = u.pc, .access = .exec, .syndrome = u.trap } },
        };
    }

    /// Takes a context that's still in user mode at the end of a slice:
    /// builds its Ureg from v86's registers, then puts the CPU back in
    /// ring 0, as v86's own set_state does, so the next run goes through
    /// the restore path like any other.
    fn preempt(_: *Backend, s: *State) void {
        const sreg: *volatile [8]u16 = @ptrFromInt(regs.sreg);
        const segoff: *volatile [8]i32 = @ptrFromInt(regs.segment_offsets);
        s.ureg = .{
            .ax = reg32(0).*,
            .cx = reg32(1).*,
            .dx = reg32(2).*,
            .bx = reg32(3).*,
            .sp = reg32(4).*,
            .bp = reg32(5).*,
            .si = reg32(6).*,
            .di = reg32(7).*,
            .pc = reg(u32, regs.instruction_pointer).* -% @as(u32, @bitCast(segoff[CS])),
            .cs = sreg[CS],
            .ss = sreg[SS],
            .ds = sreg[DS],
            .es = sreg[ES],
            .fs = sreg[FS],
            .gs = sreg[GS],
            .flags = @bitCast(js.get_eflags()),
        };
        reg(u8, regs.cpl).* = 0;
        const access: *volatile [8]u8 = @ptrFromInt(regs.segment_access_bytes);
        const isnull: *volatile [8]u8 = @ptrFromInt(regs.segment_is_null);
        const limits: *volatile [8]u32 = @ptrFromInt(regs.segment_limits);
        sreg[CS] = 0x10;
        sreg[SS] = 0x08;
        access[CS] = 0x9a;
        access[SS] = 0x92;
        isnull[CS] = 0;
        isnull[SS] = 0;
        segoff[CS] = 0;
        segoff[SS] = 0;
        limits[CS] = 0xffff_ffff;
        limits[SS] = 0xffff_ffff;
        reg(i32, regs.is_32).* = 1;
        reg(i32, regs.stack_size_32).* = 1;
        js.full_clear_tlb();
        js.update_state_flags();
    }

};

/// A two-level 386 page directory, as 9front's pc kernel uses.
pub const AddressSpace = struct {
    backend: *Backend,
    pd: []align(vmm.page_size) u8,
    /// Page tables, by directory index.
    tables: std.AutoHashMapUnmanaged(u32, []align(vmm.page_size) u8) = .empty,
    regions: std.ArrayList(Region) = .empty,
    /// Bumped when a mapping goes, so a CPU running the space flushes its TLB.
    generation: u64 = 1,

    const Region = struct { va: u64, mem: []align(vmm.page_size) u8, perms: vmm.Perms };

    fn dir(as: *AddressSpace) *[1024]u32 {
        return @ptrCast(as.pd.ptr);
    }

    pub fn destroy(as: *AddressSpace) void {
        const b = as.backend;
        if (b.cur_as == as) b.cur_as = null;
        var it = as.tables.valueIterator();
        while (it.next()) |t| b.freePages(t.*);
        as.tables.deinit(b.gpa);
        as.regions.deinit(b.gpa);
        b.freePages(as.pd);
        b.gpa.destroy(as);
    }

    fn table(as: *AddressSpace, va: u32) vmm.CreateError!*[1024]u32 {
        const di = va >> 22;
        if (as.tables.get(di)) |t| return @ptrCast(t.ptr);
        const t = try as.backend.allocPages(1);
        errdefer as.backend.freePages(t);
        try as.tables.put(as.backend.gpa, di, t);
        as.dir()[di] = @as(u32, @intCast(as.backend.phys(t.ptr))) | PTE_P | PTE_W | PTE_U;
        return @ptrCast(t.ptr);
    }

    pub fn map(as: *AddressSpace, va: u64, mem: []align(vmm.page_size) u8, perms: vmm.Perms) vmm.CreateError!void {
        if (va % vmm.page_size != 0 or mem.len % vmm.page_size != 0 or mem.len == 0) return error.BadAddress;
        if (va + mem.len > kzero) return error.BadAddress;
        for (as.regions.items) |r| {
            if (va < r.va + r.mem.len and r.va < va + mem.len) return error.BadAddress;
        }
        const b = as.backend;
        try as.regions.ensureUnusedCapacity(b.gpa, 1);
        const base: u32 = @intCast(b.phys(mem.ptr));
        var off: u32 = 0;
        while (off < mem.len) : (off += vmm.page_size) {
            const v: u32 = @intCast(va + off);
            const t = try as.table(v);
            t[(v >> 12) & 1023] = (base + off) | PTE_P | PTE_U | (if (perms.write) @as(u32, PTE_W) else 0);
        }
        // The loader wrote this text around v86; drop anything compiled
        // from these pages before it runs (design: "The JIT and host writes").
        if (perms.exec) js.jit_dirty_cache(base, base + @as(u32, @intCast(mem.len)));
        as.regions.appendAssumeCapacity(.{ .va = va, .mem = mem, .perms = perms });
    }

    pub fn unmap(as: *AddressSpace, va: u64) void {
        for (as.regions.items, 0..) |r, i| if (r.va == va) {
            var off: u64 = 0;
            while (off < r.mem.len) : (off += vmm.page_size) {
                const v: u32 = @intCast(va + off);
                if (as.tables.get(v >> 22)) |t| @as(*[1024]u32, @ptrCast(t.ptr))[(v >> 12) & 1023] = 0;
            }
            _ = as.regions.swapRemove(i);
            as.generation += 1;
            return;
        };
    }

    /// Nothing to wait for: the web host has one vCPU, which is the caller
    /// (design/0049-linux-threads.md, "TLB shootdown").
    pub fn shootdown(_: *AddressSpace) void {}

    pub fn translate(as: *AddressSpace, va: u64, len: u64) ?[]u8 {
        for (as.regions.items) |r| {
            if (va >= r.va and va - r.va <= r.mem.len and len <= r.mem.len - (va - r.va)) {
                return r.mem[@intCast(va - r.va)..][0..@intCast(len)];
            }
        }
        return null;
    }
    /// A debugger's read or write of the space (/proc/n/mem), whatever
    /// the pages' permissions. Single-threaded, so no lock.
    pub fn copy(as: *AddressSpace, va: u64, buf: []u8, write: bool) bool {
        const mem = as.translate(va, buf.len) orelse return false;
        if (write) @memcpy(mem, buf) else @memcpy(buf, mem);
        return true;
    }

    /// The host wrote code (a breakpoint): drop what v86 compiled from it.
    pub fn codeChanged(as: *AddressSpace, va: u64, len: u64) void {
        const mem = as.translate(va, len) orelse return;
        const start: u32 = @intCast(as.backend.phys(mem.ptr));
        js.jit_dirty_cache(start, start + @as(u32, @intCast(len)));
    }
};

/// A vCPU's context.
const State = struct {
    backend: *Backend,
    as: ?*AddressSpace = null,
    ureg: ia32.Ureg = .{},
    fx: vmm.Fxsave = vmm.X86Extra.init.fx,
    /// The Linux TLS entry's base for this context.
    tls: u32 = 0,
    kicked: bool = false,
};

pub const Vcpu = struct {
    s: *State,

    pub fn destroy(v: *Vcpu) void {
        const b = v.s.backend;
        if (b.fp_owner == v.s) b.fp_owner = null;
        b.gpa.destroy(v.s);
    }

    pub fn setAddressSpace(v: *Vcpu, as: *AddressSpace) vmm.Error!void {
        v.s.as = as;
    }

    pub fn getUreg(v: *Vcpu, u: *vmm.Ureg) void {
        u.* = .{ .i386 = v.s.ureg };
    }

    pub fn setUreg(v: *Vcpu, u: *const vmm.Ureg) void {
        v.s.ureg = u.i386;
    }

    pub fn getExtra(v: *Vcpu, x: *vmm.Extra) vmm.Error!void {
        const s = v.s;
        if (s.backend.fp_owner == s) try s.backend.saveFp(s);
        x.* = .{ .i386 = .{ .fx = s.fx, .tls = s.tls } };
    }

    pub fn setExtra(v: *Vcpu, x: *const vmm.Extra) vmm.Error!void {
        const s = v.s;
        s.fx = x.i386.fx;
        // FXRSTOR faults on MXCSR's reserved bits.
        s.fx.mxcsr &= 0xffff;
        s.tls = @truncate(x.i386.tls);
        if (s.backend.fp_owner == s) s.backend.fp_owner = null;
    }

    /// Makes the next run, or the one in progress at its next slice,
    /// return `.interrupted`. Everything runs on one thread, so a running
    /// vCPU is between slices whenever another coroutine kicks it.
    pub fn kick(v: *Vcpu) void {
        v.s.kicked = true;
    }

    pub fn run(v: *Vcpu) vmm.Error!vmm.Exit {
        const s = v.s;
        const b = s.backend;
        if (s.kicked) {
            s.kicked = false;
            return .interrupted;
        }
        const as = s.as orelse return error.BadAddress;
        // A context that makes a syscall every few instructions (a loop
        // around sigsetjmp, say) halts long before its slice ends, so it's
        // never preempted below: let the others run once a slice has
        // passed, as a timer interrupt would.
        const now = monoNs();
        if (now -% b.yielded > slice_ns) {
            coro.yield();
            b.yielded = monoNs();
            if (s.kicked) {
                s.kicked = false;
                return .interrupted;
            }
        }
        if (b.fp_owner != s) {
            if (b.fp_owner) |o| try b.saveFp(o);
            try b.loadFp(s);
        }
        b.install(as);
        b.setTls(s.tls);
        b.writeUreg(&s.ureg);
        js.main_loop();
        if (reg(u8, regs.in_hlt).* != 0) return b.exit(s);
        // The slice ended in guest code: preempt it, as a timer interrupt
        // would, and let everything else run before it goes on.
        b.preempt(s);
        coro.yield();
        b.yielded = monoNs();
        s.kicked = false;
        return .interrupted;
    }
};

