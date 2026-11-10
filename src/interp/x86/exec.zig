//! T0, h86's and hx64's interpreter: fetch, decode, and execute, one
//! instruction at a time, over the integer and string instructions of a
//! ring-3 386 process (`.legacy`) or a ring-3 long-mode amd64 process
//! (`.long`). x87 goes to x87.zig and MMX, SSE, and SSE2 to sse.zig.
//!
//! The two modes are one interpreter, `ExecIn(mode, M)`, with the mode a
//! comptime parameter: a register, an address, and an operand value are
//! a `mode.Word()` (u32 or u64), and the few places the modes differ
//! (REX byte registers, 32-bit writes zero-extending, RIP-relative and
//! FS/GS-based addresses, 128-bit MUL and DIV, CMPXCHG16B, SYSCALL, and
//! the opcodes long mode removes) branch on comptime-known `long`, so the
//! 386 instantiation is h86's code as it was.
//!
//! Every instruction is precise: one that faults leaves the registers as
//! they were before it, with EIP (RIP) at it, so the kernel can fix the
//! fault (grow the stack, fill a page) and run it again. Memory may
//! already hold what an earlier part of it wrote (PUSHA, ENTER), which a
//! rerun writes again. REP string instructions retire an iteration at a
//! time, so a fault or a stop in the middle leaves ECX, ESI, and EDI exact.
//!
//! Guest memory is reached through `mem`, any pointer whose type has
//!
//!     fn translate(m, va: u32, access: cpu.Access) ?[*]u8
//!
//! (va a u64 in long mode) giving the host address of `va` if the guest
//! may access it so, valid to the end of its page, or null for a page
//! fault. Accesses that cross a page translate both pages before they
//! touch either. Aligned loads are acquires and aligned stores releases,
//! so T0 keeps x86's ordering on hosts with weaker ones; LOCK-prefixed
//! instructions (and XCHG with memory) are host atomics.
//!
//! For x87.zig and sse.zig, an `Exec` offers: `c` (the Cpu), `i` (the
//! instruction), `addr` (its memory operand's linear address), `load`,
//! `store`, `load64`, `store64`, `loadBytes`, `storeBytes`, `exc`, and
//! `readReg` and `writeReg`. In long mode `c` is a Cpu64, `i` an Inst64,
//! addresses and values are u64, registers are numbered 0-15, and
//! `writeReg` at size 4 zero-extends.

const std = @import("std");
const builtin = @import("builtin");
const cpu_mod = @import("cpu.zig");
const dec = @import("decode.zig");
const table = @import("table.zig");
const flags = @import("flags.zig");
const x87 = @import("x87.zig");
const sse = @import("sse.zig");

pub const Mode = cpu_mod.Mode;
pub const Cpu = cpu_mod.Cpu;
pub const Cpu64 = cpu_mod.Cpu64;
pub const Exit = cpu_mod.Exit;
pub const Exit64 = cpu_mod.Exit64;
pub const Access = cpu_mod.Access;
pub const Inst = dec.Inst;
pub const Inst64 = dec.Inst64;
pub const Opd = table.Opd;

const page_size = 4096;

/// Ureg.type for a SYSCALL: 9front's VectorSYSCALL (pc/io.h), which the
/// Guest reports for Linux too.
pub const vec_syscall64 = 64;

pub const Options = struct {
    /// Instructions to run at most.
    budget: u64 = std.math.maxInt(u64),
    /// Nonzero asks the interpreter to stop; read every few hundred
    /// instructions and between REP iterations.
    stop: ?*const std.atomic.Value(u32) = null,
    /// Stop (`.stopped`) after this many instructions that don't go on
    /// to the next one: taken jumps, calls, and returns. A tier above uses
    /// it to see where blocks start. 0 is no limit.
    branches: u32 = 0,
};

/// Runs instructions until one exits.
pub fn run(c: *Cpu, mem: anytype, opts: Options) Exit {
    var x: Exec(@TypeOf(mem)) = .{ .c = c, .m = mem, .opts = opts };
    return x.loop();
}

/// Runs one instruction, or returns the exit it took.
pub fn step(c: *Cpu, mem: anytype) ?Exit {
    var x: Exec(@TypeOf(mem)) = .{ .c = c, .m = mem, .opts = .{} };
    x.step() catch return x.exit;
    c.retired += 1;
    return null;
}

/// `run` in `mode`. `mem` translates 64-bit addresses in long mode.
pub fn runIn(comptime mode: Mode, c: *cpu_mod.CpuOf(mode), mem: anytype, opts: Options) cpu_mod.ExitOf(mode) {
    var x: ExecIn(mode, @TypeOf(mem)) = .{ .c = c, .m = mem, .opts = opts };
    return x.loop();
}

/// `step` in `mode`.
pub fn stepIn(comptime mode: Mode, c: *cpu_mod.CpuOf(mode), mem: anytype) ?cpu_mod.ExitOf(mode) {
    var x: ExecIn(mode, @TypeOf(mem)) = .{ .c = c, .m = mem, .opts = .{} };
    x.step() catch return x.exit;
    c.retired += 1;
    return null;
}

/// Runs `inst`, already decoded, as the instruction at the PC, or returns
/// the exit it took: for tests and tools that build instructions by hand.
pub fn execInst(comptime mode: Mode, c: *cpu_mod.CpuOf(mode), mem: anytype, inst: *const dec.InstOf(mode)) ?cpu_mod.ExitOf(mode) {
    var x: ExecIn(mode, @TypeOf(mem)) = .{ .c = c, .m = mem, .opts = .{} };
    x.stepInst(inst) catch return x.exit;
    c.retired += 1;
    return null;
}

/// Decoded instructions by address, direct-mapped: 16384 of them (1 MiB),
/// enough for CPython's hot code, where 2048 missed one fetch in five. Where the memory
/// tracks code (a `codeEpoch` method), an entry holds while the host page
/// is the same and no code has been invalidated since (CodePages.epoch),
/// as ha64's decode cache does. Otherwise it keeps the bytes it was
/// decoded from, and a hit is used only if memory still holds them.
pub const ICache = ICacheOf(.legacy);

/// The ICache of `mode`.
pub fn ICacheOf(comptime mode: Mode) type {
    return struct {
        const IC = @This();
        pub const n = 16384;
        e: [n]Entry = @splat(.{}),
        /// The code epoch the entries of generation `gen` were filled in.
        epoch: usize = 0,
        gen: u32 = 1,

        pub const Entry = struct {
            eip: mode.Word() = 0,
            /// The generation it was filled in; 0 is never valid.
            gen: u32 = 0,
            /// The host address of its first byte.
            host: usize = 0,
            /// The instruction's 15 bytes from memory: bytes 0-7 and 7-14.
            lo: u64 = 0,
            hi: u64 = 0,
            inst: dec.InstOf(mode) = undefined,
        };

        /// An empty cache in place, without a 1 MiB temporary.
        pub fn init(ic: *IC) void {
            @memset(std.mem.asBytes(&ic.e), 0);
            ic.epoch = 0;
            ic.gen = 1;
        }

        /// Drops every entry: a new generation.
        pub fn clear(ic: *IC) void {
            ic.drop();
        }

        /// Starts a new generation, dropping every entry.
        fn drop(ic: *IC) void {
            ic.gen +%= 1;
            if (ic.gen == 0) ic.init();
        }
    };
}

/// Decoded instructions by page, as ha64's decode cache keeps them, for
/// memories that track code (a `codeEpoch` method). A page maps each
/// offset to the instruction decoded there, if any, so a fetch on the page
/// the last one was on is an index, with no translation or hash. A page
/// holds while its host page is the same; the whole cache goes when code
/// is invalidated (CodePages.epoch moves) or `pool` fills. Pages are
/// direct-mapped by virtual page and allocated as first used; one evicted
/// leaves its instructions in `pool` until it is next emptied. An
/// instruction that crosses a page isn't kept here.
pub const PageCache = PageCacheOf(.legacy);

/// The PageCache of `mode`.
pub fn PageCacheOf(comptime mode: Mode) type {
    return struct {
        const PC = @This();
        const W = mode.Word();
        pub const nslots = 1024;
        pub const ninst = 65535;
        gpa: std.mem.Allocator,
        slots: [nslots]?*Page,
        pool: [ninst]dec.InstOf(mode),
        /// Entries of `pool` in use.
        used: u32,
        /// The code epoch the pages of generation `gen` were filled in.
        epoch: usize,
        gen: u32,

        pub const Page = struct {
            vp: W,
            /// The generation it was filled in; 0 is never valid.
            gen: u32,
            /// The host address of the page.
            host: usize,
            /// By offset: 1 + the index in `pool` of the instruction there, or 0.
            idx: [page_size]u16,
        };

        /// An empty cache in place, which allocates pages from `gpa`.
        pub fn init(pc: *PC, gpa: std.mem.Allocator) void {
            pc.gpa = gpa;
            pc.slots = @splat(null);
            pc.used = 0;
            pc.epoch = 0;
            pc.gen = 1;
        }

        pub fn deinit(pc: *PC) void {
            for (&pc.slots) |*s| if (s.*) |p| {
                pc.gpa.destroy(p);
                s.* = null;
            };
        }

        /// Starts a new generation, dropping every page.
        fn drop(pc: *PC) void {
            pc.used = 0;
            pc.gen +%= 1;
            if (pc.gen == 0) {
                for (pc.slots) |s| if (s) |p| {
                    p.gen = 0;
                };
                pc.gen = 1;
            }
        }

        /// The page for `vp` at host page `host`, emptied if it held another,
        /// or null if there's no memory for it.
        fn page(pc: *PC, vp: W, host: usize) ?*Page {
            const s = &pc.slots[@intCast((vp ^ (vp >> 10)) & (nslots - 1))];
            const p = s.* orelse blk: {
                const p = pc.gpa.create(Page) catch return null;
                p.gen = 0;
                s.* = p;
                break :blk p;
            };
            if (p.gen != pc.gen or p.vp != vp or p.host != host) {
                p.vp = vp;
                p.gen = pc.gen;
                p.host = host;
                @memset(&p.idx, 0);
            }
            return p;
        }
    };
}

/// An instruction left: `Exec.exit` says how.
pub const Trap = error{Trap};

/// Serializes LOCK-prefixed accesses that cross a page or aren't aligned,
/// which no host atomic covers, and CMPXCHG16B where the host has no
/// 16-byte compare-and-swap.
var split_lock: std.atomic.Value(u32) = .init(0);
/// A word for MFENCE's full barrier.
var fence_word: u32 = 0;

fn lockSplit() void {
    while (split_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockSplit() void {
    split_lock.store(0, .release);
}

/// Whether the host has a 16-byte compare-and-swap for CMPXCHG16B.
const has_cas128 = switch (builtin.cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .cx16),
    .aarch64 => true,
    else => false,
};

/// A memory operand resolved for a read-modify-write: the host bytes of
/// both pages it touches, translated for writing before anything is.
/// Values are `W`, a u32 or (long mode) a u64.
fn RefOf(comptime W: type) type {
    return struct {
        const R = @This();
        p: [*]u8,
        /// The second page, when the operand crosses into it after `k` bytes.
        q: ?[*]u8 = null,
        k: u32 = 0,

        fn get(r: R, size: u8) W {
            if (r.q == null) return ldW(W, r.p, size);
            var buf: [@sizeOf(W)]u8 = undefined;
            for (0..size) |j| buf[j] = if (j < r.k) r.p[j] else r.q.?[j - r.k];
            return std.mem.readInt(W, &buf, .little) & maskW(W, size);
        }

        fn put(r: R, size: u8, v: W) void {
            if (r.q == null) return stW(W, r.p, size, v);
            for (0..size) |j| {
                const b: u8 = @truncate(v >> @intCast(8 * j));
                if (j < r.k) r.p[j] = b else r.q.?[j - r.k] = b;
            }
        }

        fn aligned(r: R, size: u8) bool {
            return r.q == null and @intFromPtr(r.p) & (size - 1) == 0;
        }
    };
}

const Ref = RefOf(u32);

inline fn ld(p: [*]u8, size: u8) u32 {
    const a = @intFromPtr(p);
    return switch (size) {
        1 => @atomicLoad(u8, &p[0], .acquire),
        2 => if (a & 1 == 0) @atomicLoad(u16, @as(*u16, @ptrCast(@alignCast(p))), .acquire) else std.mem.readInt(u16, p[0..2], .little),
        else => if (a & 3 == 0) @atomicLoad(u32, @as(*u32, @ptrCast(@alignCast(p))), .acquire) else std.mem.readInt(u32, p[0..4], .little),
    };
}

inline fn st(p: [*]u8, size: u8, v: u32) void {
    const a = @intFromPtr(p);
    switch (size) {
        1 => @atomicStore(u8, &p[0], @truncate(v), .release),
        2 => if (a & 1 == 0) @atomicStore(u16, @as(*u16, @ptrCast(@alignCast(p))), @truncate(v), .release) else std.mem.writeInt(u16, p[0..2], @truncate(v), .little),
        else => if (a & 3 == 0) @atomicStore(u32, @as(*u32, @ptrCast(@alignCast(p))), v, .release) else std.mem.writeInt(u32, p[0..4], v, .little),
    }
}

/// CAS of `size` bytes at an aligned host address.
inline fn cas(p: [*]u8, size: u8, old: u32, new: u32) bool {
    return switch (size) {
        1 => @cmpxchgStrong(u8, &p[0], @truncate(old), @truncate(new), .seq_cst, .seq_cst) == null,
        2 => @cmpxchgStrong(u16, @as(*u16, @ptrCast(@alignCast(p))), @truncate(old), @truncate(new), .seq_cst, .seq_cst) == null,
        else => @cmpxchgStrong(u32, @as(*u32, @ptrCast(@alignCast(p))), old, new, .seq_cst, .seq_cst) == null,
    };
}

/// Whether the host has 8-byte atomics (wasm32 and other 32-bit hosts
/// don't: their 8-byte accesses are plain, and their 8-byte CAS takes
/// `split_lock`).
const has_atomic64 = @bitSizeOf(usize) >= 64;

/// `ld`, `st`, and `cas` for a word type: h86's for u32, and with 8-byte
/// accesses for u64.
inline fn ldW(comptime W: type, p: [*]u8, size: u8) W {
    if (W == u32 or size != 8) return ld(p, size);
    if (has_atomic64 and @intFromPtr(p) & 7 == 0) return @atomicLoad(u64, @as(*u64, @ptrCast(@alignCast(p))), .acquire);
    return std.mem.readInt(u64, p[0..8], .little);
}

inline fn stW(comptime W: type, p: [*]u8, size: u8, v: W) void {
    if (W == u32) return st(p, size, v);
    if (size != 8) return st(p, size, @truncate(v));
    if (has_atomic64 and @intFromPtr(p) & 7 == 0) return @atomicStore(u64, @as(*u64, @ptrCast(@alignCast(p))), v, .release);
    std.mem.writeInt(u64, p[0..8], v, .little);
}

inline fn casW(comptime W: type, p: [*]u8, size: u8, old: W, new: W) bool {
    if (W == u32) return cas(p, size, old, new);
    if (size != 8) return cas(p, size, @truncate(old), @truncate(new));
    if (has_atomic64) return @cmpxchgStrong(u64, @as(*u64, @ptrCast(@alignCast(p))), old, new, .seq_cst, .seq_cst) == null;
    lockSplit();
    defer unlockSplit();
    if (std.mem.readInt(u64, p[0..8], .little) != old) return false;
    std.mem.writeInt(u64, p[0..8], new, .little);
    return true;
}

/// The mask and sign bit of a `size`-byte operand in a W.
inline fn maskW(comptime W: type, size: u8) W {
    return if (W == u32) flags.sizeMask(size) else flags.sizeMask64(size);
}

inline fn signW(comptime W: type, size: u8) W {
    return if (W == u32) flags.signBit(size) else flags.signBit64(size);
}

pub inline fn getReg(c: *const Cpu, n: u3, size: u8) u32 {
    return switch (size) {
        1 => if (n < 4) c.r[n] & 0xff else (c.r[n - 4] >> 8) & 0xff,
        2 => c.r[n] & 0xffff,
        else => c.r[n],
    };
}

pub inline fn setReg(c: *Cpu, n: u3, size: u8, v: u32) void {
    switch (size) {
        1 => if (n < 4) {
            c.r[n] = (c.r[n] & ~@as(u32, 0xff)) | (v & 0xff);
        } else {
            c.r[n - 4] = (c.r[n - 4] & ~@as(u32, 0xff00)) | ((v & 0xff) << 8);
        },
        2 => c.r[n] = (c.r[n] & 0xffff_0000) | (v & 0xffff),
        else => c.r[n] = v,
    }
}

/// A long-mode register at `size` bytes. With a REX prefix, byte
/// registers 4-7 are SPL, BPL, SIL, and DIL; without one, AH, CH, DH,
/// and BH.
pub inline fn getReg64(c: *const Cpu64, n: u4, size: u8, rex: bool) u64 {
    return switch (size) {
        1 => if (n < 4 or rex) c.r[n] & 0xff else (c.r[n - 4] >> 8) & 0xff,
        2 => c.r[n] & 0xffff,
        4 => c.r[n] & 0xffff_ffff,
        else => c.r[n],
    };
}

/// Writes a long-mode register: bytes and words merge, and a doubleword
/// zero-extends into the whole register, as the hardware does.
pub inline fn setReg64(c: *Cpu64, n: u4, size: u8, rex: bool, v: u64) void {
    switch (size) {
        1 => if (n < 4 or rex) {
            c.r[n] = (c.r[n] & ~@as(u64, 0xff)) | (v & 0xff);
        } else {
            c.r[n - 4] = (c.r[n - 4] & ~@as(u64, 0xff00)) | ((v & 0xff) << 8);
        },
        2 => c.r[n] = (c.r[n] & ~@as(u64, 0xffff)) | (v & 0xffff),
        4 => c.r[n] = v & 0xffff_ffff,
        else => c.r[n] = v,
    }
}

inline fn sext(v: u32, size: u8) i32 {
    return switch (size) {
        1 => @as(i8, @bitCast(@as(u8, @truncate(v)))),
        2 => @as(i16, @bitCast(@as(u16, @truncate(v)))),
        else => @bitCast(v),
    };
}

inline fn sext64(v: u64, size: u8) i64 {
    return switch (size) {
        1 => @as(i8, @bitCast(@as(u8, @truncate(v)))),
        2 => @as(i16, @bitCast(@as(u16, @truncate(v)))),
        4 => @as(i32, @bitCast(@as(u32, @truncate(v)))),
        else => @bitCast(v),
    };
}

/// h86's T0 over memory `M`.
pub fn Exec(comptime M: type) type {
    return ExecIn(.legacy, M);
}

/// T0 in `mode` over memory `M`.
pub fn ExecIn(comptime mode: Mode, comptime M: type) type {
    return struct {
        const X = @This();
        const long = mode == .long;
        /// A register, address, or operand value.
        const W = mode.Word();
        const SW = if (long) i64 else i32;
        /// Twice W, for products, dividends, and double shifts.
        const DW = if (long) u128 else u64;
        const SDW = if (long) i128 else i64;
        const CpuT = cpu_mod.CpuOf(mode);
        const InstT = dec.InstOf(mode);
        const ExitT = cpu_mod.ExitOf(mode);
        /// A register number: 0-7, or 0-15 with REX.
        const RegN = if (long) u4 else u3;
        const RefT = RefOf(W);
        const ICacheT = ICacheOf(mode);
        const PageCacheT = PageCacheOf(mode);
        const pc_name = if (long) "rip" else "eip";
        /// Whether the Cpu has decode caches (`icache` and `pages`).
        const has_caches = @hasField(CpuT, "icache") and @hasField(CpuT, "pages");

        c: *CpuT,
        m: M,
        opts: Options,
        /// The instruction: a decode-cache entry's, or `ibuf`.
        i: *const InstT = undefined,
        /// An instruction decoded outside the cache.
        ibuf: InstT = undefined,
        /// EIP (RIP) after this instruction, or a branch's target.
        next: W = 0,
        /// The memory operand's linear address.
        addr: W = 0,
        exit: ExitT = .stopped,
        /// Instructions run in this call.
        n: u64 = 0,
        /// The PageCache page the last fetch was on, and its virtual page
        /// (no_vp for none). Kept for one call, which a mapping change ends
        /// (it is a syscall).
        cur: *PageCacheT.Page = undefined,
        cur_vp: W = no_vp,

        const no_vp = std.math.maxInt(W);

        inline fn pc(x: *const X) W {
            return @field(x.c, pc_name);
        }

        inline fn setPc(x: *X, v: W) void {
            @field(x.c, pc_name) = v;
        }

        inline fn mk(size: u8) W {
            return maskW(W, size);
        }

        inline fn sx(v: W, size: u8) SW {
            return if (long) sext64(v, size) else sext(v, size);
        }

        fn loop(x: *X) ExitT {
            return if (x.opts.branches != 0) x.loopFor(true) else x.loopFor(false);
        }

        inline fn loopFor(x: *X, comptime count_branches: bool) ExitT {
            var taken: u32 = 0;
            while (true) {
                if (x.n >= x.opts.budget) return .stopped;
                if (x.n & 255 == 0 and x.stopRequested()) return .stopped;
                const at = x.pc();
                x.step() catch return x.exit;
                x.n += 1;
                x.c.retired += 1;
                if (count_branches and x.pc() != at +% x.i.len) {
                    taken += 1;
                    if (taken >= x.opts.branches) return .stopped;
                }
            }
        }

        fn stopRequested(x: *const X) bool {
            const s = x.opts.stop orelse return false;
            return s.load(.acquire) != 0;
        }

        // ------------------------------------------------------ exits

        /// Raises exception `vector` at this instruction.
        pub fn exc(x: *X, vector: u8) Trap {
            x.exit = .{ .exception = vector };
            x.c.trap = vector;
            x.c.ecode = 0;
            return error.Trap;
        }

        pub fn pageFault(x: *X, va: W, access: Access) Trap {
            x.exit = .{ .fault = .{ .addr = va, .access = access } };
            x.c.trap = cpu_mod.vec_pf;
            // User mode, and a write's W bit.
            x.c.ecode = 4 | @as(u32, if (access == .write) 2 else 0);
            return error.Trap;
        }

        // ------------------------------------------------------ memory

        /// A host pointer to `va`'s byte for an access, good to the end of
        /// its page. Inline as far as a memory's `hit` (a TLB hit) goes.
        pub inline fn ptr(x: *X, va: W, access: Access) Trap![*]u8 {
            if (has_hit) if (x.m.hit(va, access)) |p| return p;
            return x.ptrMiss(va, access);
        }

        noinline fn ptrMiss(x: *X, va: W, access: Access) Trap![*]u8 {
            return x.m.translate(va, access) orelse x.pageFault(va, access);
        }

        /// The bytes of [va, va+size) for writing (or a locked access),
        /// translated, both pages if it crosses.
        inline fn ref(x: *X, va: W, size: u8, access: Access) Trap!RefT {
            const off = va & (page_size - 1);
            if (off + size <= page_size) return .{ .p = try x.ptr(va, access) };
            return x.refSplit(va, access);
        }

        noinline fn refSplit(x: *X, va: W, access: Access) Trap!RefT {
            const off: u32 = @intCast(va & (page_size - 1));
            const p = try x.ptr(va, access);
            const k = page_size - off;
            const q = try x.ptr(va +% k, access);
            return .{ .p = p, .q = q, .k = k };
        }

        pub inline fn load(x: *X, va: W, size: u8) Trap!W {
            const off = va & (page_size - 1);
            if (off + size <= page_size) return ldW(W, try x.ptr(va, .read), size);
            return x.loadSplit(va, size);
        }

        noinline fn loadSplit(x: *X, va: W, size: u8) Trap!W {
            const r = try x.ref(va, size, .read);
            return r.get(size);
        }

        pub inline fn store(x: *X, va: W, size: u8, v: W) Trap!void {
            const off = va & (page_size - 1);
            if (off + size <= page_size) return stW(W, try x.ptr(va, .write), size, v);
            return x.storeSplit(va, size, v);
        }

        noinline fn storeSplit(x: *X, va: W, size: u8, v: W) Trap!void {
            const r = try x.ref(va, size, .write);
            r.put(size, v);
        }

        pub fn load64(x: *X, va: W) Trap!u64 {
            var b: [8]u8 = undefined;
            try x.loadBytes(va, &b);
            return std.mem.readInt(u64, &b, .little);
        }

        pub fn store64(x: *X, va: W, v: u64) Trap!void {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, v, .little);
            try x.storeBytes(va, &b);
        }

        /// Reads `buf.len` bytes (at most a page) at `va`.
        pub fn loadBytes(x: *X, va: W, buf: []u8) Trap!void {
            const off = va & (page_size - 1);
            const p = try x.ptr(va, .read);
            if (off + buf.len <= page_size) return @memcpy(buf, p[0..buf.len]);
            const k: usize = @intCast(page_size - off);
            const q = try x.ptr(va +% @as(W, @intCast(k)), .read);
            @memcpy(buf[0..k], p[0..k]);
            @memcpy(buf[k..], q[0 .. buf.len - k]);
        }

        /// Writes `buf` (at most a page) at `va`, checking both pages
        /// before writing either.
        pub fn storeBytes(x: *X, va: W, buf: []const u8) Trap!void {
            const off = va & (page_size - 1);
            const p = try x.ptr(va, .write);
            if (off + buf.len <= page_size) return @memcpy(p[0..buf.len], buf);
            const k: usize = @intCast(page_size - off);
            const q = try x.ptr(va +% @as(W, @intCast(k)), .write);
            @memcpy(p[0..k], buf[0..k]);
            @memcpy(q[0 .. buf.len - k], buf[k..]);
        }

        // ------------------------------------------------------ operands

        /// The memory operand's offset (no segment base). In long mode,
        /// RIP-relative addresses count from the next instruction, and
        /// 0x67 computes the address in 32 bits.
        fn ea(x: *const X) W {
            const i = x.i;
            var a = i.disp;
            if (long) {
                if (i.rip_rel) a +%= x.next;
                if (i.base != dec.no_reg64) a +%= x.c.r[i.base];
                if (i.index != dec.no_reg64) a +%= x.c.r[i.index] << i.scale;
                if (i.addr32) a &= 0xffff_ffff;
                return a;
            }
            if (i.base != dec.no_reg) a +%= x.c.r[i.base];
            if (i.index != dec.no_reg) a +%= x.c.r[i.index] << i.scale;
            if (i.addr16) a &= 0xffff;
            return a;
        }

        /// The memory operand's linear address, faulting through a null
        /// FS or GS. Long mode has only FS's and GS's bases.
        inline fn linear(x: *X, offset: W) Trap!W {
            if (long) return switch (x.i.seg) {
                .fs => offset +% x.c.fs_base,
                .gs => offset +% x.c.gs_base,
                else => offset,
            };
            const s = @intFromEnum(x.i.seg);
            if (s >= 4) {
                if (x.c.seg_null & (@as(u8, 1) << @intCast(s)) != 0) return x.exc(cpu_mod.vec_gp);
                return offset +% x.c.seg_base[s];
            }
            return offset;
        }

        /// A register at `size` bytes: h86's, or long mode's with REX's
        /// byte registers.
        inline fn rd(x: *const X, n: RegN, size: u8) W {
            if (long) return getReg64(x.c, n, size, x.i.rex.present);
            return getReg(x.c, n, size);
        }

        /// Writes a register; in long mode a doubleword zero-extends.
        inline fn wr(x: *X, n: RegN, size: u8, v: W) void {
            if (long) return setReg64(x.c, n, size, x.i.rex.present, v);
            setReg(x.c, n, size, v);
        }

        pub fn readReg(x: *const X, n: RegN, size: u8) W {
            return x.rd(n, size);
        }

        pub fn writeReg(x: *X, n: RegN, size: u8, v: W) void {
            x.wr(n, size, v);
        }

        fn regOf(x: *const X, comptime o: Opd) RegN {
            return switch (o) {
                .E => x.i.rm(),
                .G => x.i.reg(),
                .Z => x.i.zreg(),
                else => 0, // .A
            };
        }

        fn isMem(x: *const X, comptime o: Opd) bool {
            return (o == .E and x.i.mem) or o == .O;
        }

        /// A segment register's selector. Long mode keeps none: CS and SS
        /// read as 9front's amd64 user selectors and the rest as null.
        fn segSel(x: *const X, n: u3) u16 {
            if (long) return switch (n) {
                1 => amd64_uesel,
                2 => amd64_udsel,
                else => 0,
            };
            return x.c.seg[n];
        }

        /// Reads operand `o` at `size` bytes.
        inline fn get(x: *X, comptime o: Opd, size: u8) Trap!W {
            return switch (o) {
                .E => if (x.i.mem) x.load(x.addr, size) else x.rd(x.i.rm(), size),
                .O => x.load(x.addr, size),
                .G => x.rd(x.i.reg(), size),
                .A => x.rd(0, size),
                .Z => x.rd(x.i.zreg(), size),
                .I => x.i.imm & mk(size),
                .one => 1,
                .CL => x.c.r[1] & 0xff,
                .S => x.segSel(@truncate(x.i.reg())),
                .none => 0,
            };
        }

        /// Writes operand `o`.
        inline fn put(x: *X, comptime o: Opd, size: u8, v: W) Trap!void {
            if (x.isMem(o)) return x.store(x.addr, size, v);
            x.wr(x.regOf(o), size, v);
        }

        /// Reads, changes, and writes operand `o` with `f.apply`, which
        /// may run more than once for a locked operand. Returns the old
        /// value.
        inline fn modify(x: *X, comptime o: Opd, size: u8, f: anytype) Trap!W {
            if (x.isMem(o)) {
                const r = try x.ref(x.addr, size, .write);
                if (x.i.lock) return locked(r, size, f);
                const old = r.get(size);
                r.put(size, f.apply(old));
                return old;
            }
            const n = x.regOf(o);
            const old = x.rd(n, size);
            x.wr(n, size, f.apply(old));
            return old;
        }

        fn locked(r: RefT, size: u8, f: anytype) W {
            if (r.aligned(size)) {
                while (true) {
                    const old = ldW(W, r.p, size);
                    if (casW(W, r.p, size, old, f.apply(old) & mk(size))) return old;
                }
            }
            lockSplit();
            defer unlockSplit();
            const old = r.get(size);
            r.put(size, f.apply(old));
            return old;
        }

        /// A 32-bit register destination an instruction writes without
        /// changing (a shift by 0, a CMOVcc not taken): in long mode its
        /// upper half is still zeroed, as the hardware does.
        inline fn touch32(x: *X, comptime o: Opd, size: u8) void {
            if (long and size == 4 and !x.isMem(o)) {
                const n = x.regOf(o);
                x.wr(n, 4, x.rd(n, 4));
            }
        }

        // ------------------------------------------------------ stack

        inline fn push(x: *X, size: u8, v: W) Trap!void {
            const sp = x.c.r[4] -% size;
            try x.store(sp, size, v);
            x.c.r[4] = sp;
        }

        inline fn pop(x: *X, size: u8) Trap!W {
            const v = try x.load(x.c.r[4], size);
            x.c.r[4] +%= size;
            return v;
        }

        // ------------------------------------------------------ fetch

        const MemT = switch (@typeInfo(M)) {
            .pointer => |p| p.child,
            else => M,
        };
        const tracks_code = @typeInfo(MemT) == .@"struct" and @hasDecl(MemT, "codeEpoch");
        const has_hit = @typeInfo(MemT) == .@"struct" and @hasDecl(MemT, "hit");

        inline fn fetch(x: *X) Trap!*const InstT {
            if (has_caches and tracks_code) if (x.c.pages) |pcache| if (x.m.codeEpoch()) |epoch| {
                const eip = x.pc();
                if (eip >> 12 == x.cur_vp and epoch == pcache.epoch) {
                    const k = x.cur.idx[@intCast(eip & (page_size - 1))];
                    if (k != 0) return &pcache.pool[k - 1];
                }
                return x.fetchPage(pcache, epoch);
            };
            return x.fetchEntry();
        }

        /// A fetch the current page doesn't have: through the PageCache,
        /// decoding it there.
        noinline fn fetchPage(x: *X, pcache: *PageCacheT, epoch: usize) Trap!*const InstT {
            if (epoch != pcache.epoch) {
                pcache.epoch = epoch;
                pcache.drop();
                x.cur_vp = no_vp;
            }
            const eip = x.pc();
            const vp = eip >> 12;
            const off: usize = @intCast(eip & (page_size - 1));
            if (vp != x.cur_vp or x.cur.gen != pcache.gen) {
                const host = @intFromPtr(try x.ptr(eip, .exec)) - off;
                x.cur = pcache.page(vp, host) orelse return x.fetchEntry();
                x.cur_vp = vp;
            }
            const k = x.cur.idx[off];
            if (k != 0) return &pcache.pool[k - 1];
            const base: [*]u8 = @ptrFromInt(x.cur.host);
            const inst = dec.decodeIn(mode, base[off..][0..@min(page_size - off, dec.max_len)]) catch |e| switch (e) {
                error.TooLong => return x.exc(cpu_mod.vec_gp),
                // It crosses the page.
                error.Truncated => return x.fetchEntry(),
            };
            if (pcache.used == PageCacheT.ninst) {
                const host = x.cur.host;
                pcache.drop();
                // Its page is allocated.
                x.cur = pcache.page(vp, host).?;
            }
            const at = pcache.used;
            pcache.pool[at] = inst;
            pcache.used = at + 1;
            x.cur.idx[off] = @intCast(at + 1);
            return &pcache.pool[at];
        }

        /// A fetch through the ICache, or decoded each time.
        noinline fn fetchEntry(x: *X) Trap!*const InstT {
            const eip = x.pc();
            const p = try x.ptr(eip, .exec);
            const avail: usize = @intCast(page_size - (eip & (page_size - 1)));
            if (avail >= dec.max_len) {
                if (!has_caches) {
                    x.ibuf = try x.decodeWhole(p);
                    return &x.ibuf;
                }
                const ic = x.c.icache orelse {
                    x.ibuf = try x.decodeWhole(p);
                    return &x.ibuf;
                };
                const k: usize = @intCast((eip ^ (eip >> 9)) & (ICacheT.n - 1));
                const e = &ic.e[k];
                const host = @intFromPtr(p);
                if (tracks_code) if (x.m.codeEpoch()) |epoch| {
                    if (epoch != ic.epoch) {
                        ic.epoch = epoch;
                        ic.drop();
                    }
                    if (e.eip == eip and e.host == host and e.gen == ic.gen) return &e.inst;
                    e.* = .{ .eip = eip, .gen = ic.gen, .host = host, .inst = try x.decodeWhole(p) };
                    return &e.inst;
                };
                // A hit must still match the bytes in memory, so code
                // written since (by any vCPU or the host) is decoded again.
                // All 15 bytes are compared, as two overlapping words, with
                // builtins only: std is built as the root module is, which
                // is Debug in a Debug h9 even when this module isn't.
                const lo: u64 = @bitCast(p[0..8].*);
                const hi: u64 = @bitCast(p[7..15].*);
                if (e.eip == eip and e.gen != 0 and e.lo == lo and e.hi == hi) return &e.inst;
                e.* = .{ .eip = eip, .gen = ic.gen, .host = host, .inst = try x.decodeWhole(p), .lo = lo, .hi = hi };
                return &e.inst;
            }
            var buf: [dec.max_len]u8 = undefined;
            @memcpy(buf[0..avail], p[0..avail]);
            var len: usize = avail;
            if (x.m.translate(eip +% @as(W, @intCast(avail)), .exec)) |q| {
                @memcpy(buf[avail..], q[0 .. dec.max_len - avail]);
                len = dec.max_len;
            }
            x.ibuf = dec.decodeIn(mode, buf[0..len]) catch |e| switch (e) {
                error.TooLong => return x.exc(cpu_mod.vec_gp),
                error.Truncated => return x.pageFault(eip +% @as(W, @intCast(avail)), .exec),
            };
            return &x.ibuf;
        }

        fn decodeWhole(x: *X, p: [*]u8) Trap!InstT {
            return dec.decodeIn(mode, p[0..dec.max_len]) catch |e| switch (e) {
                error.TooLong => x.exc(cpu_mod.vec_gp),
                error.Truncated => unreachable,
            };
        }

        fn step(x: *X) Trap!void {
            x.i = try x.fetch();
            const i = x.i;
            x.next = x.pc() +% i.len;
            if (i.mem and i.op != .lea and i.op != .nop) x.addr = try x.linear(x.ea());
            try x.exec();
            x.setPc(x.next);
        }

        /// `step` with the instruction given rather than fetched.
        fn stepInst(x: *X, inst: *const InstT) Trap!void {
            x.i = inst;
            x.next = x.pc() +% inst.len;
            if (inst.mem and inst.op != .lea and inst.op != .nop) x.addr = try x.linear(x.ea());
            try x.exec();
            x.setPc(x.next);
        }

        // ------------------------------------------------------ execute

        /// A handler per table entry: `execEntry` with the entry known at
        /// compile time, so its operation and operand forms fold away.
        const Handler = *const fn (x: *X) Trap!void;
        const handlers: [table.entry_count]Handler = blk: {
            @setEvalBranchQuota(100_000);
            var hs: [table.entry_count]Handler = undefined;
            for (0..table.entry_count) |k| hs[k] = struct {
                fn h(x: *X) Trap!void {
                    return x.execEntry(comptime table.entryAt(k));
                }
            }.h;
            break :blk hs;
        };

        fn exec(x: *X) Trap!void {
            return handlers[x.i.entry](x);
        }

        /// Whether long mode removes `op` (PUSHA, POPA, the BCD
        /// instructions, BOUND, INTO, SALC, and the one-byte segment
        /// pushes and pops, which the table marks `inv64` as well).
        fn invalid64(comptime e: *const table.Entry) bool {
            if (e.inv64) return true;
            return switch (e.op) {
                .pusha, .popa, .daa, .das, .aaa, .aas, .aam, .aad, .bound, .into, .salc => true,
                // PUSH and POP of ES, CS, SS, and DS; FS and GS stay.
                .push_sreg, .pop_sreg => e.sreg < 4,
                else => false,
            };
        }

        fn execEntry(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            if (long and comptime invalid64(e)) return x.exc(cpu_mod.vec_ud);
            // LOCK is allowed only on the instructions that take it, with
            // a memory destination.
            const lockable = comptime e.lock;
            if (i.lock and (!lockable or !i.mem)) return x.exc(cpu_mod.vec_ud);
            switch (comptime e.op) {
                .ud => return x.exc(cpu_mod.vec_ud),
                .gp => return x.exc(cpu_mod.vec_gp),
                .nop => {},
                .add, .@"or", .adc, .sbb, .@"and", .sub, .xor, .cmp, .@"test" => try x.alu(e),
                .inc, .dec => {
                    const F = struct {
                        d: W,
                        fn apply(f: @This(), a: W) W {
                            return a +% f.d;
                        }
                    };
                    const d: W = if (i.op == .inc) 1 else std.math.maxInt(W);
                    const a = try x.modify(e.dst, i.size, F{ .d = d });
                    x.c.fl.recordIncDec(if (i.op == .inc) .inc else .dec, i.size, a, a +% d);
                },
                .not => {
                    const F = struct {
                        fn apply(_: @This(), a: W) W {
                            return ~a;
                        }
                    };
                    _ = try x.modify(e.dst, i.size, F{});
                },
                .neg => {
                    const F = struct {
                        fn apply(_: @This(), a: W) W {
                            return 0 -% a;
                        }
                    };
                    const a = try x.modify(e.dst, i.size, F{});
                    x.c.fl.record(.sub, i.size, 0, a, 0 -% a, 0);
                },
                .mul, .imul1 => try x.mul1(e),
                .imul => {
                    const size = i.size;
                    const a = try x.get(e.src, size);
                    const b = if (e.imm != .none) i.imm else x.rd(i.reg(), size);
                    const full: SDW = @as(SDW, sx(a, size)) * @as(SDW, sx(b, size));
                    const lo: W = @truncate(@as(DW, @bitCast(full)));
                    const ovf = full != sx(lo, size);
                    x.wr(i.reg(), size, lo);
                    x.c.fl.record(.mul, size, @intFromBool(ovf), 0, lo, 0);
                },
                .div, .idiv => try x.div(e),
                .rol, .ror, .rcl, .rcr => try x.rotate(e),
                .shl, .shr, .sar => try x.shift(e),
                .shld, .shrd => try x.shiftDouble(e),
                .mov => try x.put(e.dst, i.size, try x.get(e.src, i.size)),
                .movzx, .movsx => {
                    // MOVSXD (long mode's 63) has a doubleword source.
                    const ss: u8 = comptime switch (e.src_size) {
                        .b => 1,
                        .w => 2,
                        else => 4,
                    };
                    const v = try x.get(e.src, ss);
                    x.wr(i.reg(), i.size, if (i.op == .movzx) v else @bitCast(sx(v, ss)));
                },
                .lea => x.wr(i.reg(), i.size, x.ea()),
                .xchg => {
                    const size = i.size;
                    const b = try x.get(e.src, size);
                    const F = struct {
                        b: W,
                        fn apply(f: @This(), _: W) W {
                            return f.b;
                        }
                    };
                    // XCHG with memory is locked whether it says so or not.
                    const a = if (i.mem) locked(try x.ref(x.addr, size, .write), size, F{ .b = b }) else try x.modify(e.dst, size, F{ .b = b });
                    try x.put(e.src, size, a);
                },
                .xadd => {
                    const size = i.size;
                    const b = x.rd(i.reg(), size);
                    const F = struct {
                        b: W,
                        fn apply(f: @This(), a: W) W {
                            return a +% f.b;
                        }
                    };
                    var a: W = undefined;
                    if (i.mem) {
                        a = try x.modify(e.dst, size, F{ .b = b });
                        x.wr(i.reg(), size, a);
                    } else {
                        // The destination is written last, so XADD of a
                        // register with itself leaves the sum.
                        a = x.rd(i.rm(), size);
                        x.wr(i.reg(), size, a);
                        x.wr(i.rm(), size, a +% b);
                    }
                    x.c.fl.record(.add, size, a, b, a +% b, 0);
                },
                .cmpxchg => try x.cmpxchg(),
                .cmpxchg8b => if (long and i.rex.w == 1) try x.cmpxchg16b() else try x.cmpxchg8b(),
                .bswap => {
                    const z = i.zreg();
                    if (long) {
                        x.c.r[z] = if (i.size == 8) @byteSwap(x.c.r[z]) else @byteSwap(@as(u32, @truncate(x.c.r[z])));
                    } else x.c.r[z] = @byteSwap(x.c.r[z]);
                },
                // CBW, CWDE, and CDQE.
                .cbw => x.wr(0, i.size, @bitCast(sx(x.c.r[0], i.size / 2))),
                // CWD, CDQ, and CQO.
                .cwd => x.wr(2, i.size, if (x.c.r[0] & signW(W, i.size) != 0) std.math.maxInt(W) else 0),
                .xlat => {
                    var off = x.c.r[3] +% (x.c.r[0] & 0xff);
                    if (long) {
                        if (i.addr32) off &= 0xffff_ffff;
                    } else if (i.addr16) off &= 0xffff;
                    x.wr(0, 1, try x.load(try x.linear(off), 1));
                },
                .push => {
                    const v = try x.get(e.src, i.size);
                    try x.push(i.size, v);
                },
                .pop => try x.popOp(e),
                .pusha => if (!long) {
                    const size = i.size;
                    const sp = x.c.r[4];
                    var a = sp;
                    for (0..8) |k| {
                        a -%= size;
                        try x.store(a, size, if (k == 4) sp else x.rd(@intCast(k), size));
                    }
                    x.c.r[4] = a;
                },
                .popa => if (!long) {
                    const size = i.size;
                    var v: [8]W = undefined;
                    var a = x.c.r[4];
                    for (0..8) |k| {
                        v[7 - k] = try x.load(a, size);
                        a +%= size;
                    }
                    for (0..8) |k| if (k != 4) x.wr(@intCast(k), size, v[k]);
                    x.c.r[4] = a;
                },
                .pushf => {
                    const v = x.c.fl.get();
                    try x.push(i.size, v);
                },
                .popf => {
                    const v = try x.pop(i.size);
                    const mask = if (i.size == 2) flags.popf_mask & 0xffff else flags.popf_mask;
                    x.c.fl.setMasked(mask, @truncate(v));
                },
                .enter => try x.enter(),
                .leave => {
                    const sp = x.c.r[5];
                    const v = try x.load(sp, i.size);
                    x.c.r[4] = sp +% i.size;
                    x.wr(5, i.size, v);
                },
                .push_sreg => try x.push(i.size, x.segSel(e.sreg)),
                .pop_sreg => {
                    const v = try x.load(x.c.r[4], i.size);
                    try x.loadSeg(e.sreg, @truncate(v));
                    x.c.r[4] +%= i.size;
                },
                .mov_sreg => {
                    const r = i.reg();
                    if (r == 1 or r > 5) return x.exc(cpu_mod.vec_ud);
                    const v = try x.get(e.src, 2);
                    try x.loadSeg(@intCast(r), @truncate(v));
                },
                .mov_from_sreg => {
                    const r = i.reg();
                    if (r > 5) return x.exc(cpu_mod.vec_ud);
                    const v = x.segSel(@intCast(r));
                    if (i.mem) try x.store(x.addr, 2, v) else x.wr(i.rm(), i.size, v);
                },
                .lseg => {
                    const size = i.size;
                    const off = try x.load(x.addr, size);
                    const sel = try x.load(x.addr +% size, 2);
                    try x.loadSeg(e.sreg, @truncate(sel));
                    x.wr(i.reg(), size, off);
                },
                .jcc => if (x.c.fl.cond(i.cc())) x.jump(x.next +% i.imm),
                .jmp => x.jump(x.next +% i.imm),
                .jmp_ind => x.next = try x.get(e.src, i.size),
                .call => {
                    try x.push(i.size, x.next);
                    x.jump(x.next +% i.imm);
                },
                .call_ind => {
                    const t = try x.get(e.src, i.size);
                    try x.push(i.size, x.next);
                    x.next = t;
                },
                .ret => {
                    const t = try x.pop(i.size);
                    x.c.r[4] +%= i.imm;
                    x.next = if (i.size == 2) t & 0xffff else t;
                },
                .loop, .loope, .loopne => {
                    const size = x.countSize();
                    const cx = x.rd(1, size) -% 1;
                    x.wr(1, size, cx);
                    var taken = cx & mk(size) != 0;
                    if (i.op == .loope) taken = taken and x.c.fl.zf();
                    if (i.op == .loopne) taken = taken and !x.c.fl.zf();
                    if (taken) x.jump(x.next +% i.imm);
                },
                .jcxz => {
                    if (x.rd(1, x.countSize()) == 0) x.jump(x.next +% i.imm);
                },
                .setcc => try x.put(e.dst, 1, @intFromBool(x.c.fl.cond(i.cc()))),
                .cmovcc => {
                    const v = try x.get(e.src, i.size);
                    if (x.c.fl.cond(i.cc())) x.wr(i.reg(), i.size, v) else x.touch32(.G, i.size);
                },
                .bt, .bts, .btr, .btc => try x.bitTest(e),
                .bsf, .bsr => {
                    const size = i.size;
                    const v = try x.get(e.src, size);
                    if (v != 0) {
                        const r: W = if (i.op == .bsf) @ctz(v) else @bitSizeOf(W) - 1 - @clz(v);
                        x.wr(i.reg(), size, r);
                    } else x.touch32(.G, size);
                    // As QEMU: ZF from the source, and the rest as a logic
                    // operation on it.
                    x.c.fl.record(.logic, size, 0, 0, v, 0);
                },
                // AH, whatever REX says.
                .lahf => {
                    const v: W = (x.c.fl.get() & 0xd5) | 2;
                    x.c.r[0] = (x.c.r[0] & ~@as(W, 0xff00)) | (v << 8);
                },
                .sahf => x.c.fl.setMasked(flags.SF | flags.ZF | flags.AF | flags.PF | flags.CF, @truncate(x.c.r[0] >> 8)),
                .clc => x.c.fl.setMasked(flags.CF, 0),
                .stc => x.c.fl.setMasked(flags.CF, flags.CF),
                .cmc => x.c.fl.setMasked(flags.CF, if (x.c.fl.cf()) 0 else flags.CF),
                .cld => x.c.fl.bits &= ~flags.DF,
                .std => x.c.fl.bits |= flags.DF,
                .salc => x.wr(0, 1, if (x.c.fl.cf()) 0xff else 0),
                .movs, .cmps, .stos, .lods, .scas => try x.string(),
                .daa, .das => if (!long) x.decimal(),
                .aaa, .aas => if (!long) x.ascii(),
                .aam => if (!long) {
                    const base = i.imm & 0xff;
                    if (base == 0) return x.exc(cpu_mod.vec_de);
                    const al = x.c.r[0] & 0xff;
                    const lo = al % base;
                    setReg(x.c, 0, 2, ((al / base) << 8) | lo);
                    x.c.fl.record(.logic, 1, 0, 0, lo, 0);
                },
                .aad => if (!long) {
                    const base = i.imm & 0xff;
                    const al = (x.c.r[0] & 0xff) +% ((x.c.r[0] >> 8) & 0xff) *% base;
                    setReg(x.c, 0, 2, al & 0xff);
                    x.c.fl.record(.logic, 1, 0, 0, al & 0xff, 0);
                },
                .int3 => {
                    x.setPc(x.next);
                    x.c.retired += 1;
                    x.c.trap = cpu_mod.vec_bp;
                    x.exit = .breakpoint;
                    return error.Trap;
                },
                .int => {
                    // Long mode makes system calls with SYSCALL, so INT $64
                    // and INT 0x80 are #GP there, as any INT n is.
                    if (long) return x.exc(cpu_mod.vec_gp);
                    const v: u8 = @truncate(i.imm);
                    if (v != 64 and v != 0x80) return x.exc(cpu_mod.vec_gp);
                    x.c.eip = x.next;
                    x.c.retired += 1;
                    x.c.trap = v;
                    x.exit = .{ .syscall = v };
                    return error.Trap;
                },
                .into => if (!long) if (x.c.fl.of()) {
                    // A trap: EIP goes past it.
                    x.c.eip = x.next;
                    x.c.retired += 1;
                    return x.exc(cpu_mod.vec_of);
                },
                .bound => if (!long) {
                    const size = i.size;
                    const idx = sext(getReg(x.c, i.reg(), size), size);
                    const lo = sext(try x.load(x.addr, size), size);
                    const hi = sext(try x.load(x.addr +% size, size), size);
                    if (idx < lo or idx > hi) return x.exc(cpu_mod.vec_br);
                },
                .rdtsc => {
                    const t = x.c.retired;
                    x.c.r[0] = @as(u32, @truncate(t));
                    x.c.r[2] = @as(u32, @truncate(t >> 32));
                },
                .fence => _ = @atomicRmw(u32, &fence_word, .Add, 0, .seq_cst),
                .fwait => if (long and !@hasDecl(x87, "long_mode")) return x.exc(cpu_mod.vec_ud) else try x87.fwait(x),
                .x87 => if (long and !@hasDecl(x87, "long_mode")) return x.exc(cpu_mod.vec_ud) else try x87.exec(x),
                .sse => if (long and !@hasDecl(sse, "long_mode")) return x.exc(cpu_mod.vec_ud) else try sse.exec(x),
                // table.Op only grows, and long mode adds ops (SYSCALL) that
                // land in table.zig before T0 handles them. This prong keeps
                // the switch from being exhaustive, so a new tag builds and
                // is #UD here until T0 has its own prong; CPUID sits in it
                // so the prong is never all-handled, which Zig rejects.
                .syscall => {
                    if (!long) return x.exc(cpu_mod.vec_ud);
                    // RCX and R11 are left: the Guest gives them the
                    // return RIP and RFLAGS (Exit64.syscall).
                    x.setPc(x.next);
                    x.c.retired += 1;
                    x.c.trap = vec_syscall64;
                    x.c.ecode = 0;
                    x.exit = .syscall;
                    return error.Trap;
                },
                else => switch (comptime e.op) {
                    .cpuid => x.cpuid(),
                    else => return x.exc(cpu_mod.vec_ud),
                },
            }
        }

        fn jump(x: *X, target: W) void {
            x.next = if (x.i.size == 2) target & 0xffff else target;
        }

        /// The counter LOOP, JECXZ, and REP use: CX or ECX by address size
        /// in h86, RCX or (0x67) ECX in long mode.
        inline fn countSize(x: *const X) u8 {
            if (long) return if (x.i.addr32) 4 else 8;
            return if (x.i.addr16) 2 else 4;
        }

        /// Loads a segment register. h86 has its selector table; long mode
        /// has no selectors, so only null loads (and changes nothing)
        /// into DS, ES, FS, and GS, and anything else is #GP.
        fn loadSeg(x: *X, n: u3, sel: u16) Trap!void {
            if (long) {
                if (sel & ~@as(u16, 3) != 0 or n == 1 or n == 2) return x.exc(cpu_mod.vec_gp);
                return;
            }
            x.c.loadSeg(@enumFromInt(n), sel) catch return x.exc(cpu_mod.vec_gp);
        }

        fn alu(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            const size = i.size;
            const b = try x.get(e.src, size);
            const fl = &x.c.fl;
            switch (i.op) {
                .cmp => {
                    const a = try x.get(e.dst, size);
                    fl.record(.sub, size, a, b, a -% b, 0);
                },
                .@"test" => {
                    const a = try x.get(e.dst, size);
                    fl.record(.logic, size, 0, 0, a & b, 0);
                },
                else => {
                    const cin: u1 = if (i.op == .adc or i.op == .sbb) @intFromBool(fl.cf()) else 0;
                    const F = struct {
                        op: table.Op,
                        b: W,
                        cin: u1,
                        fn apply(f: @This(), a: W) W {
                            return switch (f.op) {
                                .add, .adc => a +% f.b +% f.cin,
                                .sub, .sbb => a -% f.b -% f.cin,
                                .@"and" => a & f.b,
                                .@"or" => a | f.b,
                                .xor => a ^ f.b,
                                else => unreachable,
                            };
                        }
                    };
                    const f: F = .{ .op = i.op, .b = b, .cin = cin };
                    const a = try x.modify(e.dst, size, f);
                    const res = f.apply(a);
                    switch (i.op) {
                        .add, .adc => fl.record(.add, size, a, b, res, cin),
                        .sub, .sbb => fl.record(.sub, size, a, b, res, cin),
                        else => fl.record(.logic, size, 0, 0, res, 0),
                    }
                },
            }
        }

        fn mul1(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            const size = i.size;
            const b = try x.get(e.src, size);
            const a = x.rd(0, size);
            const bits: std.math.Log2Int(DW) = @intCast(size * 8);
            var lo: W = undefined;
            var hi: W = undefined;
            var ovf: bool = undefined;
            if (i.op == .mul) {
                const p: DW = @as(DW, a) * b;
                lo = @truncate(p & mk(size));
                hi = @truncate(p >> bits);
                ovf = hi != 0;
            } else {
                const p: SDW = @as(SDW, sx(a, size)) * sx(b, size);
                const u: DW = @bitCast(p);
                lo = @truncate(u & mk(size));
                hi = @truncate((u >> bits) & mk(size));
                ovf = p != sx(lo, size);
            }
            switch (size) {
                1 => x.wr(0, 2, (hi << 8) | lo),
                else => {
                    x.wr(0, size, lo);
                    x.wr(2, size, hi);
                },
            }
            x.c.fl.record(.mul, size, @intFromBool(ovf), 0, lo, 0);
        }

        fn div(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            const size = i.size;
            const d = try x.get(e.src, size);
            if (d == 0) return x.exc(cpu_mod.vec_de);
            const bits: std.math.Log2Int(DW) = @intCast(size * 8);
            const n: DW = switch (size) {
                1 => x.c.r[0] & 0xffff,
                2 => ((x.c.r[2] & 0xffff) << 16) | (x.c.r[0] & 0xffff),
                4 => (@as(DW, x.c.r[2] & 0xffff_ffff) << 32) | (x.c.r[0] & 0xffff_ffff),
                else => if (long) (@as(DW, x.c.r[2]) << 64) | x.c.r[0] else unreachable,
            };
            var q: W = undefined;
            var r: W = undefined;
            if (i.op == .div) {
                const qq = n / d;
                if (qq > mk(size)) return x.exc(cpu_mod.vec_de);
                q = @intCast(qq);
                r = @intCast(n % d);
            } else {
                // Wide enough that the most negative dividend over -1
                // doesn't overflow before the range check.
                const SN = if (long) i130 else i128;
                const sn: SN = switch (size) {
                    1 => @as(i16, @bitCast(@as(u16, @truncate(n)))),
                    2 => @as(i32, @bitCast(@as(u32, @truncate(n)))),
                    4 => @as(i64, @bitCast(@as(u64, @truncate(n)))),
                    else => if (long) @as(i128, @bitCast(n)) else unreachable,
                };
                const sd: SN = sx(d, size);
                const qq = @divTrunc(sn, sd);
                const max: SN = @as(SN, 1) << @intCast(bits - 1);
                if (qq >= max or qq < -max) return x.exc(cpu_mod.vec_de);
                const US = std.meta.Int(.unsigned, @bitSizeOf(SN));
                q = @truncate(@as(US, @bitCast(qq)));
                r = @truncate(@as(US, @bitCast(@rem(sn, sd))));
            }
            switch (size) {
                1 => x.wr(0, 2, ((r & 0xff) << 8) | (q & 0xff)),
                else => {
                    x.wr(0, size, q);
                    x.wr(2, size, r);
                },
            }
        }

        /// A shift or rotate count's mask: 5 bits, or 6 at 64 bits.
        inline fn countMask(size: u8) W {
            return if (size == 8) 63 else 31;
        }

        fn shift(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            const size = i.size;
            const count = (try x.get(e.src, 1)) & countMask(size);
            if (count == 0) {
                // No change, but the operand is still checked.
                if (x.isMem(e.dst)) _ = try x.ref(x.addr, size, .write);
                x.touch32(e.dst, size);
                return;
            }
            const F = struct {
                op: table.Op,
                n: std.math.Log2Int(W),
                size: u8,
                fn apply(f: @This(), a: W) W {
                    return switch (f.op) {
                        .shl => a << f.n,
                        .shr => (a & mk(f.size)) >> f.n,
                        else => @bitCast(sx(a, f.size) >> f.n),
                    };
                }
            };
            const f: F = .{ .op = i.op, .n = @intCast(count), .size = size };
            const a = try x.modify(e.dst, size, f);
            const res = f.apply(a);
            const pre = (F{ .op = i.op, .n = @intCast(count - 1), .size = size }).apply(a);
            x.c.fl.record(if (i.op == .shl) .shl else .shr, size, pre, 0, res, 0);
        }

        fn shiftDouble(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            const size = i.size;
            const count: W = (if (e.imm == .b) i.imm else x.c.r[1]) & countMask(size);
            if (count == 0) {
                if (x.isMem(e.dst)) _ = try x.ref(x.addr, size, .write);
                x.touch32(e.dst, size);
                return;
            }
            const b = x.rd(i.reg(), size);
            const F = struct {
                left: bool,
                n: std.math.Log2Int(DW),
                b: W,
                size: u8,
                fn apply(f: @This(), a: W) W {
                    const bits: std.math.Log2Int(DW) = @intCast(f.size * 8);
                    const m = mk(f.size);
                    if (f.left) {
                        const v: DW = (@as(DW, a & m) << bits) | (f.b & m);
                        return @truncate((v << f.n) >> bits);
                    }
                    const v: DW = (@as(DW, f.b & m) << bits) | (a & m);
                    return @truncate(v >> f.n);
                }
            };
            const left = i.op == .shld;
            const f: F = .{ .left = left, .n = @intCast(count), .b = b, .size = size };
            const a = try x.modify(e.dst, size, f);
            const res = f.apply(a) & mk(size);
            const pre = (F{ .left = left, .n = @intCast(count - 1), .b = b, .size = size }).apply(a);
            x.c.fl.record(if (left) .shl else .shr, size, pre, 0, res, 0);
        }

        fn rotate(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            const size = i.size;
            const bits: u32 = @as(u32, size) * 8;
            const raw: u32 = @intCast((try x.get(e.src, 1)) & countMask(size));
            const rc = i.op == .rcl or i.op == .rcr;
            const n: u32 = if (rc) raw % (bits + 1) else raw % bits;
            if (raw == 0 or (rc and n == 0)) {
                if (x.isMem(e.dst)) _ = try x.ref(x.addr, size, .write);
                x.touch32(e.dst, size);
                return;
            }
            const cin: DW = @intFromBool(x.c.fl.cf());
            const F = struct {
                op: table.Op,
                n: u32,
                bits: u32,
                cin: DW,
                fn apply(f: @This(), a0: W) W {
                    const m: DW = (@as(DW, 1) << @intCast(f.bits)) - 1;
                    const a: DW = a0 & m;
                    const b: std.math.Log2Int(DW) = @intCast(f.bits);
                    switch (f.op) {
                        .rol => return @truncate(((a << @intCast(f.n)) | (a >> @intCast(f.bits - f.n))) & m),
                        .ror => return @truncate(((a >> @intCast(f.n)) | (a << @intCast(f.bits - f.n))) & m),
                        .rcl => {
                            const v: DW = (f.cin << b) | a;
                            const w = (@as(DW, 1) << (b + 1)) - 1;
                            const rv = ((v << @intCast(f.n)) | (v >> @intCast(f.bits + 1 - f.n))) & w;
                            return @truncate(rv & m);
                        },
                        else => {
                            const v: DW = (f.cin << b) | a;
                            const w = (@as(DW, 1) << (b + 1)) - 1;
                            const rv = ((v >> @intCast(f.n)) | (v << @intCast(f.bits + 1 - f.n))) & w;
                            return @truncate(rv & m);
                        },
                    }
                }
            };
            const f: F = .{ .op = i.op, .n = n, .bits = bits, .cin = cin };
            const a = try x.modify(e.dst, size, f);
            const res = f.apply(a);
            const sb = signW(W, size);
            var cf: bool = undefined;
            var of: bool = undefined;
            switch (i.op) {
                .rol => {
                    cf = res & 1 != 0;
                    of = (res & sb != 0) != cf;
                },
                .ror => {
                    cf = res & sb != 0;
                    of = ((res ^ (res << 1)) & sb) != 0;
                },
                .rcl => {
                    // The carry out is the bit rotated past the top.
                    cf = (a >> @intCast(bits - n)) & 1 != 0;
                    of = (res & sb != 0) != cf;
                },
                else => {
                    cf = if (n == 1) a & 1 != 0 else (a >> @intCast(n - 1)) & 1 != 0;
                    of = ((res ^ (res << 1)) & sb) != 0;
                },
            }
            x.c.fl.setMasked(flags.CF | flags.OF, (if (cf) flags.CF else 0) | (if (of) flags.OF else 0));
        }

        fn popOp(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            const size = i.size;
            const old_sp = x.c.r[4];
            const v = try x.load(old_sp, size);
            if (!x.isMem(e.dst)) {
                x.c.r[4] = old_sp +% size;
                x.wr(x.regOf(e.dst), size, v);
                return;
            }
            // An ESP-based destination's address uses ESP after the pop.
            x.c.r[4] = old_sp +% size;
            x.addr = x.linear(x.ea()) catch |err| {
                x.c.r[4] = old_sp;
                return err;
            };
            x.store(x.addr, size, v) catch |err| {
                x.c.r[4] = old_sp;
                return err;
            };
        }

        fn enter(x: *X) Trap!void {
            const i = x.i;
            const size = i.size;
            const level = i.imm2 & 31;
            var sp = x.c.r[4];
            var bp = x.c.r[5];
            sp -%= size;
            try x.store(sp, size, bp);
            const frame = sp;
            if (level > 0) {
                var k: u32 = 1;
                while (k < level) : (k += 1) {
                    bp -%= size;
                    const v = try x.load(bp, size);
                    sp -%= size;
                    try x.store(sp, size, v);
                }
                sp -%= size;
                try x.store(sp, size, frame);
            }
            x.wr(5, size, frame);
            x.c.r[4] = sp -% (i.imm & 0xffff);
        }

        fn cmpxchg(x: *X) Trap!void {
            const i = x.i;
            const size = i.size;
            const acc = x.rd(0, size);
            const src = x.rd(i.reg(), size);
            var old: W = undefined;
            if (i.mem) {
                const r = try x.ref(x.addr, size, .write);
                if (i.lock and r.aligned(size)) {
                    old = acc;
                    while (true) {
                        if (casW(W, r.p, size, acc, src)) break;
                        old = ldW(W, r.p, size);
                        if (old != acc) break;
                    }
                } else {
                    if (i.lock) lockSplit();
                    defer if (i.lock) unlockSplit();
                    old = r.get(size);
                    // The destination is written either way, as on hardware.
                    r.put(size, if (old == acc) src else old);
                }
            } else {
                // In long mode a 32-bit destination is written (and
                // zero-extended) only when equal, and EAX only when not.
                old = x.rd(i.rm(), size);
                if (old == acc) x.wr(i.rm(), size, src);
            }
            if (old != acc) x.wr(0, size, old);
            x.c.fl.record(.sub, size, acc, old, acc -% old, 0);
        }

        /// CMPXCHG8B: EDX:EAX against the 8 bytes, ECX:EBX in if equal.
        fn cmpxchg8b(x: *X) Trap!void {
            const c = x.c;
            const want: u64 = (@as(u64, c.r[2] & 0xffff_ffff) << 32) | (c.r[0] & 0xffff_ffff);
            const new: u64 = (@as(u64, c.r[1] & 0xffff_ffff) << 32) | (c.r[3] & 0xffff_ffff);
            const r = try x.ref(x.addr, 8, .write);
            var old: u64 = undefined;
            if (@bitSizeOf(usize) >= 64 and r.q == null and @intFromPtr(r.p) & 7 == 0) {
                const p: *u64 = @ptrCast(@alignCast(r.p));
                old = @cmpxchgStrong(u64, p, want, new, .seq_cst, .seq_cst) orelse want;
            } else {
                lockSplit();
                defer unlockSplit();
                var b: [8]u8 = undefined;
                for (0..8) |j| b[j] = if (r.q == null or j < r.k) r.p[j] else r.q.?[j - r.k];
                old = std.mem.readInt(u64, &b, .little);
                std.mem.writeInt(u64, &b, if (old == want) new else old, .little);
                for (0..8) |j| {
                    if (r.q == null or j < r.k) r.p[j] = b[j] else r.q.?[j - r.k] = b[j];
                }
            }
            if (old == want) {
                c.fl.setMasked(flags.ZF, flags.ZF);
            } else {
                c.r[0] = @as(u32, @truncate(old));
                c.r[2] = @as(u32, @truncate(old >> 32));
                c.fl.setMasked(flags.ZF, 0);
            }
        }

        /// CMPXCHG16B (long mode): RDX:RAX against the 16 bytes, which
        /// must be 16-aligned (#GP otherwise), and RCX:RBX in if equal.
        fn cmpxchg16b(x: *X) Trap!void {
            if (!long) unreachable;
            const c = x.c;
            if (x.addr & 15 != 0) return x.exc(cpu_mod.vec_gp);
            const want: u128 = (@as(u128, c.r[2]) << 64) | c.r[0];
            const new: u128 = (@as(u128, c.r[1]) << 64) | c.r[3];
            // Aligned, so on one page.
            const r = try x.ref(x.addr, 16, .write);
            var old: u128 = undefined;
            if (has_cas128) {
                const p: *u128 = @ptrCast(@alignCast(r.p));
                old = @cmpxchgStrong(u128, p, want, new, .seq_cst, .seq_cst) orelse want;
            } else {
                lockSplit();
                defer unlockSplit();
                old = std.mem.readInt(u128, r.p[0..16], .little);
                if (old == want) std.mem.writeInt(u128, r.p[0..16], new, .little);
            }
            if (old == want) {
                c.fl.setMasked(flags.ZF, flags.ZF);
            } else {
                c.r[0] = @truncate(old);
                c.r[2] = @truncate(old >> 64);
                c.fl.setMasked(flags.ZF, 0);
            }
        }

        fn bitTest(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            const size = i.size;
            const bits: W = @as(W, size) * 8;
            var bit: W = undefined;
            if (e.src == .I) {
                bit = i.imm & (bits - 1);
            } else {
                const off = x.rd(i.reg(), size);
                bit = off & (bits - 1);
                // A register bit offset reaches outside a memory operand.
                if (i.mem) {
                    const words: SW = sx(off, size) >> @intCast(@ctz(bits));
                    x.addr +%= @bitCast(words *% @as(SW, size));
                }
            }
            const mask = @as(W, 1) << @intCast(bit);
            var old: W = undefined;
            if (i.op == .bt) {
                old = try x.get(e.dst, size);
            } else {
                const F = struct {
                    op: table.Op,
                    mask: W,
                    fn apply(f: @This(), a: W) W {
                        return switch (f.op) {
                            .bts => a | f.mask,
                            .btr => a & ~f.mask,
                            else => a ^ f.mask,
                        };
                    }
                };
                old = try x.modify(e.dst, size, F{ .op = i.op, .mask = mask });
            }
            x.c.fl.setMasked(flags.CF, if (old & mask != 0) flags.CF else 0);
        }

        // ------------------------------------------------------ strings

        fn string(x: *X) Trap!void {
            const i = x.i;
            const size = i.size;
            const asize = x.countSize();
            const am = mk(asize);
            const c = x.c;
            const delta: W = if (c.fl.df()) 0 -% @as(W, size) else size;
            const src_base: W = blk: {
                if (i.op != .movs and i.op != .cmps and i.op != .lods) break :blk 0;
                if (long) break :blk switch (i.seg) {
                    .fs => c.fs_base,
                    .gs => c.gs_base,
                    else => 0,
                };
                const s = @intFromEnum(i.seg);
                if (s >= 4) {
                    if (c.seg_null & (@as(u8, 1) << @intCast(s)) != 0) return x.exc(cpu_mod.vec_gp);
                    break :blk c.seg_base[s];
                }
                break :blk 0;
            };
            if (i.rep == .none) {
                try x.stringOnce(size, delta, am, src_base);
                return;
            }
            var iter: u32 = 0;
            while (x.rd(1, asize) != 0) {
                if (iter & 4095 == 4095 and x.stopRequested()) {
                    // Stop between iterations, at this instruction.
                    x.next = x.pc();
                    x.exit = .stopped;
                    return error.Trap;
                }
                iter +%= 1;
                if (try x.stringBulk(size, am, src_base)) continue;
                try x.stringOnce(size, delta, am, src_base);
                x.wr(1, asize, x.rd(1, asize) -% 1);
                if (i.op == .cmps or i.op == .scas) {
                    const zf = c.fl.zf();
                    if ((i.rep == .rep and !zf) or (i.rep == .repne and zf)) break;
                }
            }
        }

        /// One iteration of a string instruction.
        fn stringOnce(x: *X, size: u8, delta: W, am: W, src_base: W) Trap!void {
            const c = x.c;
            const si = c.r[6] & am;
            const di = c.r[7] & am;
            switch (x.i.op) {
                .movs => {
                    const v = try x.load(si +% src_base, size);
                    try x.store(di, size, v);
                    x.advance(6, delta, am);
                    x.advance(7, delta, am);
                },
                .stos => {
                    try x.store(di, size, x.rd(0, size));
                    x.advance(7, delta, am);
                },
                .lods => {
                    x.wr(0, size, try x.load(si +% src_base, size));
                    x.advance(6, delta, am);
                },
                .cmps => {
                    const a = try x.load(si +% src_base, size);
                    const b = try x.load(di, size);
                    c.fl.record(.sub, size, a, b, a -% b, 0);
                    x.advance(6, delta, am);
                    x.advance(7, delta, am);
                },
                .scas => {
                    const a = x.rd(0, size);
                    const b = try x.load(di, size);
                    c.fl.record(.sub, size, a, b, a -% b, 0);
                    x.advance(7, delta, am);
                },
                else => unreachable,
            }
        }

        /// Steps ESI or EDI. In long mode a 32-bit address size writes
        /// ESI or EDI, zero-extending.
        fn advance(x: *X, reg: u3, delta: W, am: W) void {
            const c = x.c;
            if (long) {
                c.r[reg] = (c.r[reg] +% delta) & am;
                return;
            }
            c.r[reg] = (c.r[reg] & ~am) | ((c.r[reg] +% delta) & am);
        }

        /// REP MOVS and REP STOS forward, a page's worth at a time where
        /// the pages allow. Returns false to do one iteration instead.
        fn stringBulk(x: *X, size: u8, am: W, src_base: W) Trap!bool {
            const i = x.i;
            const c = x.c;
            if ((i.op != .movs and i.op != .stos) or c.fl.df() or am != std.math.maxInt(W)) return false;
            const di = c.r[7];
            var n = c.r[1];
            const dst_room = (page_size - (di & (page_size - 1))) / size;
            n = @min(n, dst_room);
            if (n < 2) return false;
            const dp = try x.ptr(di, .write);
            const nn: usize = @intCast(n);
            if (i.op == .stos) {
                const v = x.rd(0, size);
                switch (size) {
                    1 => @memset(dp[0..nn], @truncate(v)),
                    else => for (0..nn) |k| stW(W, dp + k * size, size, v),
                }
                c.r[7] = di +% n * size;
                c.r[1] -%= n;
                return true;
            }
            const si = c.r[6] +% src_base;
            n = @min(n, (page_size - (si & (page_size - 1))) / size);
            if (n < 2) return false;
            const nn2: usize = @intCast(n);
            const sp = try x.ptr(si, .read);
            const len = nn2 * size;
            const s = @intFromPtr(sp);
            const d = @intFromPtr(dp);
            if (d + len <= s or s + len <= d) {
                @memcpy(dp[0..len], sp[0..len]);
            } else {
                // Overlapping: element by element, as the CPU does.
                for (0..nn2) |k| stW(W, dp + k * size, size, ldW(W, sp + k * size, size));
            }
            c.r[6] +%= @as(W, @intCast(len));
            c.r[7] = di +% @as(W, @intCast(len));
            c.r[1] -%= n;
            return true;
        }

        // ------------------------------------------------------ BCD

        fn decimal(x: *X) void {
            if (long) unreachable;
            const c = x.c;
            const old_al = c.r[0] & 0xff;
            const old_cf = c.fl.cf();
            var al = old_al;
            var cf = false;
            var af = false;
            const sub = x.i.op == .das;
            if (al & 0xf > 9 or c.fl.af()) {
                cf = old_cf or (if (sub) al < 6 else al + 6 > 0xff);
                al = (if (sub) al -% 6 else al +% 6) & 0xff;
                af = true;
            }
            if (old_al > 0x99 or old_cf) {
                al = (if (sub) al -% 0x60 else al +% 0x60) & 0xff;
                cf = true;
            }
            setReg(c, 0, 1, al);
            var f: u32 = 0;
            if (cf) f |= flags.CF;
            if (af) f |= flags.AF;
            if (al == 0) f |= flags.ZF;
            if (al & 0x80 != 0) f |= flags.SF;
            if (flags.parity(al)) f |= flags.PF;
            c.fl.setMasked(flags.arith, f);
        }

        fn ascii(x: *X) void {
            if (long) unreachable;
            const c = x.c;
            var ax = c.r[0] & 0xffff;
            var f: u32 = 0;
            if (ax & 0xf > 9 or c.fl.af()) {
                if (x.i.op == .aaa) {
                    ax = (ax +% 0x106) & 0xffff;
                } else {
                    // AX - 6, with AL's borrow reaching AH, then AH - 1.
                    ax = (ax -% 6) -% 0x100;
                    ax &= 0xffff;
                }
                f = flags.AF | flags.CF;
            }
            ax &= 0xff0f;
            setReg(c, 0, 2, ax);
            const al = ax & 0xff;
            if (al == 0) f |= flags.ZF;
            if (flags.parity(al)) f |= flags.PF;
            c.fl.setMasked(flags.arith, f);
        }

        // ------------------------------------------------------ CPUID

        fn cpuid(x: *X) void {
            const c = x.c;
            const r = if (long) cpuidLeaf64(@truncate(c.r[0])) else cpuidLeaf(c.r[0]);
            c.r[0] = r[0];
            c.r[3] = r[1];
            c.r[1] = r[2];
            c.r[2] = r[3];
        }
    };
}

/// 9front's amd64 user code and data selectors (arch/amd64.zig UESEL and
/// UDSEL), which long mode's CS and SS read as.
const amd64_uesel: u16 = (5 << 3) | 3;
const amd64_udsel: u16 = (4 << 3) | 3;

/// CPUID: a family 6 CPU with the features of h9's AT_HWCAP for i386
/// (FPU, TSC, CX8, CMOV, MMX, FXSR, SSE, and SSE2, among others), and no
/// SSE3 or later, AVX, or OSXSAVE. Returns EAX, EBX, ECX, EDX.
pub fn cpuidLeaf(leaf: u32) [4]u32 {
    const brand = "h86 386 interpreter\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    return switch (leaf) {
        // "GenuineIntel", as v86 reports.
        0 => .{ 1, 0x756e6547, 0x6c65746e, 0x49656e69 },
        // Family 6; 64-byte CLFLUSH lines, one logical processor.
        1 => .{ 0x0000_06f1, (1 << 16) | (8 << 8), 0, 0x078bfbff },
        0x8000_0000 => .{ 0x8000_0004, 0, 0, 0 },
        0x8000_0002, 0x8000_0003, 0x8000_0004 => brandLeaf(brand, leaf),
        else => .{ 0, 0, 0, 0 },
    };
}

/// CPUID for hx64: x86-64-v1, which is h86's leaf 1 with CMPXCHG16B
/// (CX16), and leaf 0x80000001 with SYSCALL, NX, long mode, and
/// LAHF/SAHF. No SSE3 or later, POPCNT, AVX, or OSXSAVE.
pub fn cpuidLeaf64(leaf: u32) [4]u32 {
    const brand = "hx64 amd64 interpreter\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const cx16: u32 = 1 << 13;
    const lahf_lm: u32 = 1 << 0;
    const syscall: u32 = 1 << 11;
    const nx: u32 = 1 << 20;
    const lm: u32 = 1 << 29;
    return switch (leaf) {
        0 => .{ 1, 0x756e6547, 0x6c65746e, 0x49656e69 },
        1 => .{ 0x0000_06f1, (1 << 16) | (8 << 8), cx16, 0x078bfbff },
        0x8000_0000 => .{ 0x8000_0004, 0, 0, 0 },
        0x8000_0001 => .{ 0, 0, lahf_lm, syscall | nx | lm },
        0x8000_0002, 0x8000_0003, 0x8000_0004 => brandLeaf(brand, leaf),
        else => .{ 0, 0, 0, 0 },
    };
}

/// One of the brand string's three leaves (0x80000002-4).
fn brandLeaf(brand: []const u8, leaf: u32) [4]u32 {
    const k = (leaf - 0x8000_0002) * 16;
    var v: [4]u32 = undefined;
    for (&v, 0..) |*w, j| w.* = std.mem.readInt(u32, brand[k + 4 * j ..][0..4], .little);
    return v;
}

// ---------------------------------------------------------------- tests

/// Flat test memory: `pages` pages from `base`, all permissions.
pub const TestMem = struct {
    base: u32,
    mem: []u8,
    ro_page: ?u32 = null,

    pub fn translate(m: *TestMem, va: u32, access: Access) ?[*]u8 {
        if (va < m.base or va - m.base >= m.mem.len) return null;
        if (access == .write and m.ro_page != null and va & ~@as(u32, 0xfff) == m.ro_page.?) return null;
        return m.mem.ptr + (va - m.base);
    }
};

fn runCode(code: []const u8, c: *Cpu) !Exit {
    var buf: [3 * page_size]u8 align(page_size) = @splat(0);
    @memcpy(buf[0..code.len], code);
    var m: TestMem = .{ .base = 0x10000, .mem = &buf };
    c.eip = 0x10000;
    c.r[4] = 0x10000 + 3 * page_size;
    return run(c, &m, .{ .budget = 1000 });
}

test "a loop, a call, and a syscall" {
    var c: Cpu = .{};
    // movl $10, %ecx; xorl %eax, %eax; l: addl %ecx, %eax; loop l;
    // call f; int $64; f: incl %eax; ret
    const code = [_]u8{ 0xb9, 10, 0, 0, 0, 0x31, 0xc0, 0x01, 0xc8, 0xe2, 0xfc, 0xe8, 2, 0, 0, 0, 0xcd, 0x40, 0x40, 0xc3 };
    const e = try runCode(&code, &c);
    try std.testing.expectEqual(Exit{ .syscall = 64 }, e);
    try std.testing.expectEqual(@as(u32, 56), c.r[0]);
    try std.testing.expectEqual(@as(u32, 0x10012), c.eip);
}

test "divide by zero and #UD" {
    var c: Cpu = .{};
    // xorl %ecx, %ecx; divl %ecx
    try std.testing.expectEqual(Exit{ .exception = 0 }, try runCode(&.{ 0x31, 0xc9, 0xf7, 0xf1 }, &c));
    try std.testing.expectEqual(@as(u32, 0x10002), c.eip);
    try std.testing.expectEqual(Exit{ .exception = 6 }, try runCode(&.{ 0x0f, 0x0b }, &c));
    // idiv INT_MIN / -1 overflows.
    c = .{};
    try std.testing.expectEqual(Exit{ .exception = 0 }, try runCode(&.{ 0xb8, 0, 0, 0, 0x80, 0x99, 0xb9, 0xff, 0xff, 0xff, 0xff, 0xf7, 0xf9 }, &c));
}

test "rep movsb across pages and a fault resumes exactly" {
    var c: Cpu = .{};
    // movl $0x10ff0, %esi; movl $0x11ff8, %edi; movl $0x40, %ecx; rep movsb; int3
    const code = [_]u8{ 0xbe, 0xf0, 0x0f, 0x01, 0, 0xbf, 0xf8, 0x1f, 0x01, 0, 0xb9, 0x40, 0, 0, 0, 0xf3, 0xa4, 0xcc };
    var buf: [3 * page_size]u8 align(page_size) = @splat(0);
    @memcpy(buf[0..code.len], &code);
    for (0..0x40) |k| buf[0xff0 + k] = @intCast(k + 1);
    var m: TestMem = .{ .base = 0x10000, .mem = &buf, .ro_page = 0x12000 };
    c.eip = 0x10000;
    c.r[4] = 0x13000;
    const e = run(&c, &m, .{});
    try std.testing.expectEqual(Exit{ .fault = .{ .addr = 0x12000, .access = .write } }, e);
    try std.testing.expectEqual(@as(u32, 0x40 - 8), c.r[1]);
    try std.testing.expectEqual(@as(u32, 0x1000f), c.eip);
    m.ro_page = null;
    try std.testing.expectEqual(Exit.breakpoint, run(&c, &m, .{}));
    try std.testing.expectEqualSlices(u8, buf[0xff0..0x1030], buf[0x1ff8..0x2038]);
    try std.testing.expectEqual(@as(u32, 0), c.r[1]);
}

test "a store into the code takes effect at the next instruction" {
    var c: Cpu = .{};
    var ic: ICache = .{};
    c.icache = &ic;
    // Runs a MOV, patches its immediate, and runs it again, with the
    // decoded-instruction cache on:
    //   0: b8 01 00 00 00        movl $1, %eax
    //   5: 85 db                 testl %ebx, %ebx
    //   7: 75 0b                 jne done
    //   9: 43                    incl %ebx
    //   a: c6 05 01 00 01 00 07  movb $7, 0x10001
    //  11: eb ed                 jmp 0
    //  13: cc                    done: int3
    const code = [_]u8{ 0xb8, 1, 0, 0, 0, 0x85, 0xdb, 0x75, 0x0a, 0x43, 0xc6, 0x05, 0x01, 0x00, 0x01, 0x00, 0x07, 0xeb, 0xed, 0xcc };
    try std.testing.expectEqual(Exit.breakpoint, try runCode(&code, &c));
    try std.testing.expectEqual(@as(u32, 7), c.r[0]);
}

// ------------------------------------------------- long-mode tests (hx64)
//
// These build Inst64s by hand, through h86's table entries, and run them
// with execInst, so they test T0 apart from the long-mode decoder.

/// Flat test memory for long mode, at a base above 4 GiB.
pub const TestMem64 = struct {
    base: u64,
    mem: []u8,
    ro_page: ?u64 = null,

    pub fn translate(m: *TestMem64, va: u64, access: Access) ?[*]u8 {
        if (va < m.base or va - m.base >= m.mem.len) return null;
        if (access == .write and m.ro_page != null and va & ~@as(u64, 0xfff) == m.ro_page.?) return null;
        return m.mem.ptr + @as(usize, @intCast(va - m.base));
    }
};

const base64: u64 = 0x7_0000_0000;

/// An Inst64 for `opcode` (with `modrm`) from h86's table entry, at
/// operand size `size`, `len` bytes long.
fn ti(opcode: u16, modrm: u8, size: u8, len: u8) Inst64 {
    const e = table.entry(table.slot(opcode), modrm);
    return .{ .op = e.op, .entry = table.entryIndex(e), .opcode = opcode, .len = len, .size = size, .modrm = modrm };
}

/// `ti` with a REX prefix of `rex` (0x40-0x4f).
fn tr(opcode: u16, modrm: u8, size: u8, len: u8, rex: u8) Inst64 {
    var i = ti(opcode, modrm, size, len);
    i.rex = dec.Rex.of(rex);
    return i;
}

const T64 = struct {
    buf: [4 * page_size]u8 align(page_size) = @splat(0),
    m: TestMem64 = undefined,
    c: Cpu64 = .{},

    fn init(t: *T64) void {
        t.m = .{ .base = base64, .mem = &t.buf };
        t.c.rip = base64;
        t.c.r[4] = base64 + 4 * page_size;
    }

    fn run(t: *T64, i: Inst64) ?Exit64 {
        return execInst(.long, &t.c, &t.m, &i);
    }

    fn q(t: *T64, va: u64) u64 {
        return std.mem.readInt(u64, t.buf[@intCast(va - base64)..][0..8], .little);
    }

    fn setq(t: *T64, va: u64, v: u64) void {
        std.mem.writeInt(u64, t.buf[@intCast(va - base64)..][0..8], v, .little);
    }
};

test "a 32-bit write zeroes the upper half of a 64-bit register, and narrower ones merge" {
    var t: T64 = .{};
    t.init();
    t.c.r[0] = 0xffff_ffff_ffff_ffff;
    t.c.r[1] = 0x1234_5678_0000_0005;
    // movl %ecx, %eax (89 c8)
    try std.testing.expect(t.run(ti(0x89, 0xc8, 4, 2)) == null);
    try std.testing.expectEqual(@as(u64, 5), t.c.r[0]);
    try std.testing.expectEqual(base64 + 2, t.c.rip);
    // movw %cx, %ax and movb %cl, %al merge.
    t.c.r[0] = 0xffff_ffff_ffff_ffff;
    _ = t.run(ti(0x89, 0xc8, 2, 3));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_0005), t.c.r[0]);
    // movq %rcx, %rax (48 89 c8)
    _ = t.run(tr(0x89, 0xc8, 8, 3, 0x48));
    try std.testing.expectEqual(t.c.r[1], t.c.r[0]);
    // movb %ah, %al without REX; movb %spl, %al with it (88 e0).
    t.c.r[0] = 0xab00;
    t.c.r[4] = 0x77;
    _ = t.run(ti(0x88, 0xe0, 1, 2));
    try std.testing.expectEqual(@as(u64, 0xabab), t.c.r[0]);
    _ = t.run(tr(0x88, 0xe0, 1, 3, 0x40));
    try std.testing.expectEqual(@as(u64, 0xab77), t.c.r[0]);
    // movl %r9d, %r8d (45 89 c8) reaches the high registers.
    t.c.r[8] = 0xffff_ffff_ffff_ffff;
    t.c.r[9] = 0x1_0000_0002;
    _ = t.run(tr(0x89, 0xc8, 4, 3, 0x45));
    try std.testing.expectEqual(@as(u64, 2), t.c.r[8]);
}

test "64-bit arithmetic and its flags" {
    var t: T64 = .{};
    t.init();
    // addq %rcx, %rax with a carry out of bit 63.
    t.c.r[0] = 0xffff_ffff_ffff_ffff;
    t.c.r[1] = 2;
    _ = t.run(tr(0x01, 0xc8, 8, 3, 0x48));
    try std.testing.expectEqual(@as(u64, 1), t.c.r[0]);
    try std.testing.expect(t.c.fl.cf() and !t.c.fl.zf() and !t.c.fl.of());
    // The same at 32 bits: EAX's carry, and RAX zero-extended.
    t.c.r[0] = 0xffff_ffff_ffff_ffff;
    _ = t.run(ti(0x01, 0xc8, 4, 2));
    try std.testing.expectEqual(@as(u64, 1), t.c.r[0]);
    try std.testing.expect(t.c.fl.cf());
    // subq $1, %rax from 0x8000000000000000 overflows (48 83 e8 01).
    t.c.r[0] = 0x8000_0000_0000_0000;
    var i = tr(0x83, 0xe8, 8, 4, 0x48);
    i.imm = 1;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 0x7fff_ffff_ffff_ffff), t.c.r[0]);
    try std.testing.expect(t.c.fl.of() and !t.c.fl.cf());
    // andq $-16, %rsp: the imm32's sign-extension reaches bit 63.
    t.c.r[4] = 0x7fff_ffff_ffff_fff7;
    i = tr(0x83, 0xe4, 8, 4, 0x48);
    i.imm = 0xffff_ffff_ffff_fff0;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 0x7fff_ffff_ffff_fff0), t.c.r[4]);
    // incq, negq, notq.
    t.c.r[3] = 0xffff_ffff;
    _ = t.run(tr(0xff, 0xc3, 8, 3, 0x48));
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), t.c.r[3]);
    _ = t.run(tr(0xf7, 0xdb, 8, 3, 0x48));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_0000_0000), t.c.r[3]);
    try std.testing.expect(t.c.fl.cf() and t.c.fl.sf());
    _ = t.run(tr(0xf7, 0xd3, 8, 3, 0x48));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff), t.c.r[3]);
    // cmpq and a signed condition at 64 bits.
    t.c.r[0] = 1;
    t.c.r[1] = 0xffff_ffff_ffff_ffff;
    _ = t.run(tr(0x39, 0xc8, 8, 3, 0x48));
    try std.testing.expect(t.c.fl.cond(@intFromEnum(flags.Cond.g)) and t.c.fl.cond(@intFromEnum(flags.Cond.b)));
}

test "MUL, IMUL, DIV, and IDIV at 128 bits" {
    var t: T64 = .{};
    t.init();
    // mulq %rcx: 2^63 * 6 = 3 * 2^64.
    t.c.r[0] = 0x8000_0000_0000_0000;
    t.c.r[1] = 6;
    _ = t.run(tr(0xf7, 0xe1, 8, 3, 0x48));
    try std.testing.expectEqual(@as(u64, 0), t.c.r[0]);
    try std.testing.expectEqual(@as(u64, 3), t.c.r[2]);
    try std.testing.expect(t.c.fl.cf() and t.c.fl.of());
    // imulq %rcx: -2 * 6 = -12, RDX all ones, no overflow.
    t.c.r[0] = @bitCast(@as(i64, -2));
    _ = t.run(tr(0xf7, 0xe9, 8, 3, 0x48));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -12))), t.c.r[0]);
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), t.c.r[2]);
    try std.testing.expect(!t.c.fl.cf());
    // imulq %rcx, %rax (48 0f af c1) overflowing.
    t.c.r[0] = 0x4000_0000_0000_0000;
    t.c.r[1] = 4;
    _ = t.run(tr(0x0faf, 0xc1, 8, 4, 0x48));
    try std.testing.expectEqual(@as(u64, 0), t.c.r[0]);
    try std.testing.expect(t.c.fl.of());
    // mull %ecx zero-extends EAX and EDX.
    t.c.r[0] = 0xffff_ffff_ffff_ffff;
    t.c.r[1] = 0xffff_ffff_0000_0002;
    t.c.r[2] = 0xffff_ffff_ffff_ffff;
    _ = t.run(ti(0xf7, 0xe1, 4, 2));
    try std.testing.expectEqual(@as(u64, 0xffff_fffe), t.c.r[0]);
    try std.testing.expectEqual(@as(u64, 1), t.c.r[2]);
    // divq %rcx: (3 * 2^64 + 7) / 2^63.
    t.c.r[2] = 3;
    t.c.r[0] = 7;
    t.c.r[1] = 0x8000_0000_0000_0000;
    _ = t.run(tr(0xf7, 0xf1, 8, 3, 0x48));
    try std.testing.expectEqual(@as(u64, 6), t.c.r[0]);
    try std.testing.expectEqual(@as(u64, 7), t.c.r[2]);
    // A quotient that doesn't fit is #DE, with RIP at the DIV.
    t.c.r[2] = 1;
    t.c.r[1] = 1;
    const rip = t.c.rip;
    try std.testing.expectEqual(Exit64{ .exception = cpu_mod.vec_de }, t.run(tr(0xf7, 0xf1, 8, 3, 0x48)).?);
    try std.testing.expectEqual(rip, t.c.rip);
    // A DIV by zero is #DE too.
    t.c.r[1] = 0;
    try std.testing.expectEqual(Exit64{ .exception = cpu_mod.vec_de }, t.run(tr(0xf7, 0xf1, 8, 3, 0x48)).?);
    // idivq: -7 / 2 = -3 rem -1; INT64_MIN / -1 is #DE.
    t.c.r[0] = @bitCast(@as(i64, -7));
    t.c.r[2] = 0xffff_ffff_ffff_ffff;
    t.c.r[1] = 2;
    _ = t.run(tr(0xf7, 0xf9, 8, 3, 0x48));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -3))), t.c.r[0]);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), t.c.r[2]);
    t.c.r[0] = 0x8000_0000_0000_0000;
    t.c.r[2] = 0xffff_ffff_ffff_ffff;
    t.c.r[1] = 0xffff_ffff_ffff_ffff;
    try std.testing.expectEqual(Exit64{ .exception = cpu_mod.vec_de }, t.run(tr(0xf7, 0xf9, 8, 3, 0x48)).?);
    // cqo and cdqe (48 99, 48 98); cltd zero-extends EDX.
    t.c.r[0] = 0x8000_0000;
    _ = t.run(tr(0x98, 0, 8, 2, 0x48));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_8000_0000), t.c.r[0]);
    _ = t.run(tr(0x99, 0, 8, 2, 0x48));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), t.c.r[2]);
    _ = t.run(ti(0x99, 0, 4, 1));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff), t.c.r[2]);
}

test "shifts and rotates at 64 bits, and a shift by 0 still zero-extends" {
    var t: T64 = .{};
    t.init();
    // shlq $63, %rax (48 c1 e0 3f): the count isn't masked to 5 bits.
    t.c.r[0] = 3;
    var i = tr(0xc1, 0xe0, 8, 4, 0x48);
    i.imm = 63;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), t.c.r[0]);
    try std.testing.expect(t.c.fl.cf());
    // sarq %cl, %rax with CL = 63.
    t.c.r[1] = 63;
    _ = t.run(tr(0xd3, 0xf8, 8, 3, 0x48));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), t.c.r[0]);
    // shrq $1 then rolq $4.
    _ = t.run(tr(0xd1, 0xe8, 8, 3, 0x48));
    try std.testing.expectEqual(@as(u64, 0x7fff_ffff_ffff_ffff), t.c.r[0]);
    i = tr(0xc1, 0xc0, 8, 4, 0x48);
    i.imm = 4;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_fff7), t.c.r[0]);
    // rclq $1 brings CF in at the bottom and bit 63 out.
    t.c.fl.setMasked(flags.CF, 0);
    _ = t.run(tr(0xd1, 0xd0, 8, 3, 0x48));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffee), t.c.r[0]);
    try std.testing.expect(t.c.fl.cf());
    // shldq $8, %rcx, %rax.
    t.c.r[0] = 0x0011_2233_4455_6677;
    t.c.r[1] = 0x8899_aabb_ccdd_eeff;
    i = tr(0x0fa4, 0xc8, 8, 5, 0x48);
    i.imm = 8;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), t.c.r[0]);
    // shll $0, %eax changes no flags but zeroes RAX's upper half.
    t.c.r[0] = 0xffff_ffff_ffff_ffff;
    i = ti(0xc1, 0xe0, 4, 3);
    i.imm = 0;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 0xffff_ffff), t.c.r[0]);
}

test "CMOVcc, BSF, BSWAP, and SETcc in long mode" {
    var t: T64 = .{};
    t.init();
    // cmovel %ecx, %eax not taken still zero-extends; cmovneq taken.
    t.c.r[0] = 0xffff_ffff_ffff_ffff;
    t.c.r[1] = 7;
    t.c.fl.set(flags.res1);
    _ = t.run(ti(0x0f44, 0xc1, 4, 3));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff), t.c.r[0]);
    _ = t.run(tr(0x0f45, 0xc1, 8, 4, 0x48));
    try std.testing.expectEqual(@as(u64, 7), t.c.r[0]);
    // bsrq and bsfq.
    t.c.r[1] = 0x8000_0000_0000_0010;
    _ = t.run(tr(0x0fbd, 0xc1, 8, 4, 0x48));
    try std.testing.expectEqual(@as(u64, 63), t.c.r[0]);
    _ = t.run(tr(0x0fbc, 0xc1, 8, 4, 0x48));
    try std.testing.expectEqual(@as(u64, 4), t.c.r[0]);
    // bswapq %rax and bswapl %eax.
    t.c.r[0] = 0x0102_0304_0506_0708;
    _ = t.run(tr(0x0fc8, 0, 8, 3, 0x48));
    try std.testing.expectEqual(@as(u64, 0x0807_0605_0403_0201), t.c.r[0]);
    _ = t.run(ti(0x0fc8, 0, 4, 2));
    try std.testing.expectEqual(@as(u64, 0x0102_0304), t.c.r[0]);
    // sete %sil (40 0f 94 c6) writes SIL, not DH.
    t.c.r[6] = 0xff00;
    t.c.r[2] = 0;
    t.c.fl.set(flags.ZF | flags.res1);
    _ = t.run(tr(0x0f94, 0xc6, 1, 4, 0x40));
    try std.testing.expectEqual(@as(u64, 0xff01), t.c.r[6]);
    try std.testing.expectEqual(@as(u64, 0), t.c.r[2]);
}

test "PUSH, POP, CALL, and RET move 8 bytes" {
    var t: T64 = .{};
    t.init();
    const top = t.c.r[4];
    // pushq %rbx; popq %r12 (41 5c).
    t.c.r[3] = 0x1122_3344_5566_7788;
    _ = t.run(ti(0x53, 0, 8, 1));
    try std.testing.expectEqual(top - 8, t.c.r[4]);
    try std.testing.expectEqual(t.c.r[3], t.q(top - 8));
    var i = tr(0x58, 0, 8, 2, 0x41);
    i.opcode = 0x5c;
    _ = t.run(i);
    try std.testing.expectEqual(t.c.r[3], t.c.r[12]);
    try std.testing.expectEqual(top, t.c.r[4]);
    // pushq $-1 (6a ff): 8 bytes of ones.
    i = ti(0x6a, 0, 8, 2);
    i.imm = 0xffff_ffff_ffff_ffff;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), t.q(top - 8));
    t.c.r[4] = top;
    // call +0x100 (e8): the return address is 8 bytes, then ret.
    t.c.rip = base64 + 0x10;
    i = ti(0xe8, 0, 8, 5);
    i.imm = 0x100;
    _ = t.run(i);
    try std.testing.expectEqual(base64 + 0x115, t.c.rip);
    try std.testing.expectEqual(base64 + 0x15, t.q(top - 8));
    _ = t.run(ti(0xc3, 0, 8, 1));
    try std.testing.expectEqual(base64 + 0x15, t.c.rip);
    try std.testing.expectEqual(top, t.c.r[4]);
    // A backward jmp sign-extends to 64 bits.
    i = ti(0xeb, 0, 8, 2);
    i.imm = @bitCast(@as(i64, -0x17));
    _ = t.run(i);
    try std.testing.expectEqual(base64, t.c.rip);
    // pushfq; popfq.
    t.c.fl.set(flags.CF | flags.res1);
    _ = t.run(ti(0x9c, 0, 8, 1));
    try std.testing.expectEqual(@as(u64, flags.CF | flags.res1), t.q(top - 8));
    t.c.fl.set(flags.res1);
    _ = t.run(ti(0x9d, 0, 8, 1));
    try std.testing.expect(t.c.fl.cf());
    // leaveq.
    t.c.r[5] = top - 16;
    t.setq(top - 16, 0xabcd);
    _ = t.run(ti(0xc9, 0, 8, 1));
    try std.testing.expectEqual(@as(u64, 0xabcd), t.c.r[5]);
    try std.testing.expectEqual(top - 8, t.c.r[4]);
}

test "a RIP-relative load reads past the instruction, and FS and GS add their bases" {
    var t: T64 = .{};
    t.init();
    t.setq(base64 + 0x107, 0xfeed_face_cafe_beef);
    // movq 0x100(%rip), %rax (48 8b 05 00 01 00 00): 7 bytes long.
    var i = tr(0x8b, 0x05, 8, 7, 0x48);
    i.mem = true;
    i.rip_rel = true;
    i.disp = 0x100;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 0xfeed_face_cafe_beef), t.c.r[0]);
    // leaq -7(%rip), %rcx gives the instruction's own address.
    t.c.rip = base64 + 0x40;
    i = tr(0x8d, 0x0d, 8, 7, 0x48);
    i.mem = true;
    i.rip_rel = true;
    i.disp = @bitCast(@as(i64, -7));
    _ = t.run(i);
    try std.testing.expectEqual(base64 + 0x40, t.c.r[1]);
    // movq %fs:0x10, %rdx with FS's base.
    t.c.fs_base = base64 + 0x200;
    t.setq(base64 + 0x210, 42);
    i = tr(0x8b, 0x14, 8, 9, 0x48);
    i.mem = true;
    i.seg = .fs;
    i.disp = 0x10;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 42), t.c.r[2]);
    // movq %rdx, %gs:(%rbx) stores through GS's base.
    t.c.gs_base = base64 + 0x300;
    t.c.r[3] = 8;
    i = tr(0x89, 0x13, 8, 4, 0x48);
    i.mem = true;
    i.seg = .gs;
    i.base = 3;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 42), t.q(base64 + 0x308));
    // 67: a 32-bit address, so 0x1_0000_0000 + 0x10 wraps to 0x10.
    t.c.r[3] = 0xffff_fff8;
    i = tr(0x8d, 0x43, 8, 5, 0x48);
    i.mem = true;
    i.addr32 = true;
    i.base = 3;
    i.disp = 0x18;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 0x10), t.c.r[0]);
    // An 8-byte load across into an unmapped page faults at its address.
    t.m.mem = t.buf[0 .. 2 * page_size];
    i = tr(0x8b, 0x00, 8, 3, 0x48);
    i.mem = true;
    i.base = 0;
    t.c.r[0] = base64 + 2 * page_size - 4;
    try std.testing.expectEqual(Exit64{ .fault = .{ .addr = base64 + 2 * page_size, .access = .read } }, t.run(i).?);
}

test "string instructions on RSI, RDI, and RCX" {
    var t: T64 = .{};
    t.init();
    for (0..64) |k| t.buf[0x100 + k] = @intCast(k + 1);
    // rep movsq: 8 quadwords.
    t.c.r[6] = base64 + 0x100;
    t.c.r[7] = base64 + 0x800;
    t.c.r[1] = 8;
    var i = tr(0xa5, 0, 8, 3, 0x48);
    i.rep = .rep;
    _ = t.run(i);
    try std.testing.expectEqualSlices(u8, t.buf[0x100..0x140], t.buf[0x800..0x840]);
    try std.testing.expectEqual(@as(u64, 0), t.c.r[1]);
    try std.testing.expectEqual(base64 + 0x140, t.c.r[6]);
    try std.testing.expectEqual(base64 + 0x840, t.c.r[7]);
    // std; rep stosq backward, one at a time.
    t.c.fl.bits |= flags.DF;
    t.c.r[0] = 0x0101_0101_0101_0101;
    t.c.r[1] = 2;
    t.c.r[7] = base64 + 0x908;
    i = tr(0xab, 0, 8, 3, 0x48);
    i.rep = .rep;
    _ = t.run(i);
    try std.testing.expectEqual(t.c.r[0], t.q(base64 + 0x908));
    try std.testing.expectEqual(t.c.r[0], t.q(base64 + 0x900));
    try std.testing.expectEqual(base64 + 0x8f8, t.c.r[7]);
    t.c.fl.bits &= ~flags.DF;
    // repne scasb finds a byte.
    t.c.r[0] = 5;
    t.c.r[7] = base64 + 0x100;
    t.c.r[1] = 100;
    i = ti(0xae, 0, 1, 2);
    i.rep = .repne;
    _ = t.run(i);
    try std.testing.expectEqual(base64 + 0x105, t.c.r[7]);
    try std.testing.expectEqual(@as(u64, 95), t.c.r[1]);
    // With 67, stosb uses EDI and writes it zero-extended.
    t.c.r[7] = 0xffff_ffff_0000_0000;
    t.m.base = 0;
    t.m.mem = t.buf[0..];
    i = ti(0xaa, 0, 1, 2);
    i.addr32 = true;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 1), t.c.r[7]);
    try std.testing.expectEqual(@as(u8, 5), t.buf[0]);
}

test "CMPXCHG16B, CMPXCHG8B, and locked 8-byte operations" {
    var t: T64 = .{};
    t.init();
    const a = base64 + 0x400;
    t.setq(a, 1);
    t.setq(a + 8, 2);
    // cmpxchg16b (%rsi), equal: RCX:RBX goes in.
    t.c.r[6] = a;
    t.c.r[0] = 1;
    t.c.r[2] = 2;
    t.c.r[3] = 3;
    t.c.r[1] = 4;
    var i = tr(0x0fc7, 0x0e, 8, 4, 0x48);
    i.mem = true;
    i.base = 6;
    i.lock = true;
    _ = t.run(i);
    try std.testing.expect(t.c.fl.zf());
    try std.testing.expectEqual(@as(u64, 3), t.q(a));
    try std.testing.expectEqual(@as(u64, 4), t.q(a + 8));
    // Not equal: RDX:RAX gets the memory.
    _ = t.run(i);
    try std.testing.expect(!t.c.fl.zf());
    try std.testing.expectEqual(@as(u64, 3), t.c.r[0]);
    try std.testing.expectEqual(@as(u64, 4), t.c.r[2]);
    // Misaligned is #GP.
    t.c.r[6] = a + 8;
    try std.testing.expectEqual(Exit64{ .exception = cpu_mod.vec_gp }, t.run(i).?);
    // cmpxchg8b compares EDX:EAX only.
    t.c.r[6] = a;
    t.c.r[0] = 0xffff_ffff_0000_0003;
    t.c.r[2] = 0;
    t.c.r[3] = 9;
    t.c.r[1] = 0;
    i = ti(0x0fc7, 0x0e, 4, 3);
    i.mem = true;
    i.base = 6;
    _ = t.run(i);
    try std.testing.expect(t.c.fl.zf());
    try std.testing.expectEqual(@as(u64, 9), t.q(a));
    // lock xaddq %rax, (%rsi) and xchgq.
    t.c.r[0] = 1;
    i = tr(0x0fc1, 0x06, 8, 5, 0x48);
    i.mem = true;
    i.base = 6;
    i.lock = true;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 9), t.c.r[0]);
    try std.testing.expectEqual(@as(u64, 10), t.q(a));
    t.c.r[0] = 0x1_0000_0000;
    i = tr(0x87, 0x06, 8, 3, 0x48);
    i.mem = true;
    i.base = 6;
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 10), t.c.r[0]);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), t.q(a));
    // cmpxchgl %ecx, %ebx: equal writes EBX zero-extended, not EAX.
    t.c.r[0] = 0xffff_ffff_0000_0005;
    t.c.r[3] = 0xaaaa_aaaa_0000_0005;
    t.c.r[1] = 6;
    _ = t.run(ti(0x0fb1, 0xcb, 4, 3));
    try std.testing.expectEqual(@as(u64, 6), t.c.r[3]);
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_0000_0005), t.c.r[0]);
}

test "LAHF and SAHF use AH whatever REX says, and CPUID reports long mode" {
    var t: T64 = .{};
    t.init();
    t.c.fl.set(flags.CF | flags.ZF | flags.res1);
    t.c.r[0] = 0xffff_ffff_ffff_00ff;
    _ = t.run(tr(0x9f, 0, 8, 2, 0x48));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_43ff), t.c.r[0]);
    t.c.r[0] = 0x0100;
    _ = t.run(ti(0x9e, 0, 4, 1));
    try std.testing.expect(t.c.fl.cf() and !t.c.fl.zf());
    // CPUID: CX16 in leaf 1, LM, SYSCALL, and LAHF in 0x80000001, and
    // nothing past SSE2.
    t.c.r[0] = 0xffff_ffff_0000_0001;
    _ = t.run(ti(0x0fa2, 0, 4, 2));
    try std.testing.expect(t.c.r[1] & (1 << 13) != 0);
    try std.testing.expect(t.c.r[1] & 1 == 0 and t.c.r[1] & (1 << 28) == 0);
    try std.testing.expect(t.c.r[2] & (1 << 26) != 0);
    t.c.r[0] = 0x8000_0001;
    _ = t.run(ti(0x0fa2, 0, 4, 2));
    try std.testing.expect(t.c.r[2] & (1 << 29) != 0 and t.c.r[2] & (1 << 11) != 0);
    try std.testing.expect(t.c.r[1] & 1 != 0);
}

test "INT 0x80 in long mode raises #GP, and the removed opcodes #UD" {
    var t: T64 = .{};
    t.init();
    var i = ti(0xcd, 0, 4, 2);
    i.imm = 0x80;
    try std.testing.expectEqual(Exit64{ .exception = cpu_mod.vec_gp }, t.run(i).?);
    try std.testing.expectEqual(base64, t.c.rip);
    try std.testing.expectEqual(Exit64{ .exception = cpu_mod.vec_ud }, t.run(ti(0x60, 0, 8, 1)).?);
    try std.testing.expectEqual(Exit64{ .exception = cpu_mod.vec_ud }, t.run(ti(0x27, 0, 4, 1)).?);
    try std.testing.expectEqual(Exit64{ .exception = cpu_mod.vec_ud }, t.run(ti(0x1e, 0, 8, 1)).?);
    // int3 leaves RIP past it.
    try std.testing.expectEqual(Exit64.breakpoint, t.run(ti(0xcc, 0, 4, 1)).?);
    try std.testing.expectEqual(base64 + 1, t.c.rip);
}

test "LOOP and JRCXZ count RCX, or ECX under 67" {
    var t: T64 = .{};
    t.init();
    t.c.r[1] = 0x1_0000_0000;
    var i = ti(0xe2, 0, 8, 2);
    i.imm = @bitCast(@as(i64, -2));
    _ = t.run(i);
    try std.testing.expectEqual(@as(u64, 0xffff_ffff), t.c.r[1]);
    try std.testing.expectEqual(base64, t.c.rip);
    t.c.r[1] = 0x1_0000_0000;
    i = ti(0xe3, 0, 8, 2);
    i.imm = 0x10;
    _ = t.run(i);
    try std.testing.expectEqual(base64 + 2, t.c.rip);
    i.addr32 = true;
    _ = t.run(i);
    try std.testing.expectEqual(base64 + 0x14, t.c.rip);
}

fn runCode64(t: *T64, code: []const u8) Exit64 {
    @memcpy(t.buf[0..code.len], code);
    return runIn(.long, &t.c, &t.m, .{ .budget = 1000 });
}

test "a long-mode program runs through the decoder: a loop, a call, and SYSCALL" {
    var t: T64 = .{};
    t.init();
    //  0: 48 c7 c1 0a 00 00 00   movq $10, %rcx
    //  7: 31 c0                  xorl %eax, %eax
    //  9: 48 01 c8               l: addq %rcx, %rax
    // 12: e2 fb                  loop l
    // 14: e8 02 00 00 00         call f
    // 19: 0f 05                  syscall
    // 21: 48 ff c0               f: incq %rax
    // 24: c3                     ret
    const code = [_]u8{ 0x48, 0xc7, 0xc1, 10, 0, 0, 0, 0x31, 0xc0, 0x48, 0x01, 0xc8, 0xe2, 0xfb, 0xe8, 2, 0, 0, 0, 0x0f, 0x05, 0x48, 0xff, 0xc0, 0xc3 };
    try std.testing.expectEqual(Exit64.syscall, runCode64(&t, &code));
    try std.testing.expectEqual(@as(u64, 56), t.c.r[0]);
    try std.testing.expectEqual(base64 + 21, t.c.rip);
    try std.testing.expectEqual(@as(u64, vec_syscall64), t.c.trap);
}

test "a long-mode program: MOVABS, a RIP-relative store, R8-R15, and MOVSXD" {
    var t: T64 = .{};
    t.init();
    //  0: 49 b8 88 77 66 55 44 33 22 11   movabsq $0x1122334455667788, %r8
    // 10: 4c 89 05 f7 0f 00 00            movq %r8, 0xff7(%rip)  (0x1008)
    // 17: 4c 8b 0d f0 0f 00 00            movq 0xff0(%rip), %r9  (0x1008)
    // 24: 4d 63 d1                        movslq %r9d, %r10
    // 27: cc                              int3
    const code = [_]u8{ 0x49, 0xb8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x4c, 0x89, 0x05, 0xf7, 0x0f, 0, 0, 0x4c, 0x8b, 0x0d, 0xf0, 0x0f, 0, 0, 0x4d, 0x63, 0xd1, 0xcc };
    try std.testing.expectEqual(Exit64.breakpoint, runCode64(&t, &code));
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), t.q(base64 + 0x1008));
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), t.c.r[9]);
    try std.testing.expectEqual(@as(u64, 0x5566_7788), t.c.r[10]);
    try std.testing.expectEqual(base64 + 28, t.c.rip);
}
