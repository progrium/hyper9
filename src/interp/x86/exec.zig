//! T0, h86's interpreter: fetch, decode, and execute, one instruction at
//! a time, over the integer and string instructions of a ring-3 386
//! process. x87 goes to x87.zig and MMX, SSE, and SSE2 to sse.zig.
//!
//! Every instruction is precise: one that faults leaves the registers as
//! they were before it, with EIP at it, so the kernel can fix the fault
//! (grow the stack, fill a page) and run it again. Memory may already
//! hold what an earlier part of it wrote (PUSHA, ENTER), which a rerun
//! writes again. REP string instructions retire an iteration at a time,
//! so a fault or a stop in the middle leaves ECX, ESI, and EDI exact.
//!
//! Guest memory is reached through `mem`, any pointer whose type has
//!
//!     fn translate(m, va: u32, access: cpu.Access) ?[*]u8
//!
//! giving the host address of `va` if the guest may access it so, valid
//! to the end of its page, or null for a page fault. Accesses that cross
//! a page translate both pages before they touch either. Aligned loads
//! are acquires and aligned stores releases, so T0 keeps x86's ordering
//! on hosts with weaker ones; LOCK-prefixed instructions (and XCHG with
//! memory) are host atomics.
//!
//! For x87.zig and sse.zig, an `Exec` offers: `c` (the Cpu), `i` (the
//! instruction), `addr` (its memory operand's linear address), `load`,
//! `store`, `load64`, `store64`, `loadBytes`, `storeBytes`, `exc`, and
//! `readReg` and `writeReg`.

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const dec = @import("decode.zig");
const table = @import("table.zig");
const flags = @import("flags.zig");
const x87 = @import("x87.zig");
const sse = @import("sse.zig");

pub const Mode = cpu_mod.Mode;
pub const Cpu = cpu_mod.Cpu;
pub const Exit = cpu_mod.Exit;
pub const Access = cpu_mod.Access;
pub const Inst = dec.Inst;
pub const Opd = table.Opd;

const page_size = 4096;

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

/// `run` in `mode`. Long mode (hx64) doesn't execute yet: its first
/// instruction raises #UD, with RIP at it. `mem` translates 64-bit
/// addresses there.
pub fn runIn(comptime mode: Mode, c: *cpu_mod.CpuOf(mode), mem: anytype, opts: Options) cpu_mod.ExitOf(mode) {
    return switch (mode) {
        .legacy => run(c, mem, opts),
        .long => .{ .exception = cpu_mod.vec_ud },
    };
}

/// `step` in `mode`; long mode as `runIn`.
pub fn stepIn(comptime mode: Mode, c: *cpu_mod.CpuOf(mode), mem: anytype) ?cpu_mod.ExitOf(mode) {
    return switch (mode) {
        .legacy => step(c, mem),
        .long => .{ .exception = cpu_mod.vec_ud },
    };
}

/// Decoded instructions by address, direct-mapped: 16384 of them (1 MiB),
/// enough for CPython's hot code, where 2048 missed one fetch in five. Where the memory
/// tracks code (a `codeEpoch` method), an entry holds while the host page
/// is the same and no code has been invalidated since (CodePages.epoch),
/// as ha64's decode cache does. Otherwise it keeps the bytes it was
/// decoded from, and a hit is used only if memory still holds them.
pub const ICache = struct {
    pub const n = 16384;
    e: [n]Entry = @splat(.{}),
    /// The code epoch the entries of generation `gen` were filled in.
    epoch: usize = 0,
    gen: u32 = 1,

    pub const Entry = struct {
        eip: u32 = 0,
        /// The generation it was filled in; 0 is never valid.
        gen: u32 = 0,
        /// The host address of its first byte.
        host: usize = 0,
        /// The instruction's 15 bytes from memory: bytes 0-7 and 7-14.
        lo: u64 = 0,
        hi: u64 = 0,
        inst: Inst = undefined,
    };

    /// An empty cache in place, without a 1 MiB temporary.
    pub fn init(ic: *ICache) void {
        @memset(std.mem.asBytes(&ic.e), 0);
        ic.epoch = 0;
        ic.gen = 1;
    }

    /// Drops every entry: a new generation.
    pub fn clear(ic: *ICache) void {
        ic.drop();
    }

    /// Starts a new generation, dropping every entry.
    fn drop(ic: *ICache) void {
        ic.gen +%= 1;
        if (ic.gen == 0) ic.init();
    }
};

/// Decoded instructions by page, as ha64's decode cache keeps them, for
/// memories that track code (a `codeEpoch` method). A page maps each
/// offset to the instruction decoded there, if any, so a fetch on the page
/// the last one was on is an index, with no translation or hash. A page
/// holds while its host page is the same; the whole cache goes when code
/// is invalidated (CodePages.epoch moves) or `pool` fills. Pages are
/// direct-mapped by virtual page and allocated as first used; one evicted
/// leaves its instructions in `pool` until it is next emptied. An
/// instruction that crosses a page isn't kept here.
pub const PageCache = struct {
    pub const nslots = 1024;
    pub const ninst = 65535;
    gpa: std.mem.Allocator,
    slots: [nslots]?*Page,
    pool: [ninst]Inst,
    /// Entries of `pool` in use.
    used: u32,
    /// The code epoch the pages of generation `gen` were filled in.
    epoch: usize,
    gen: u32,

    pub const Page = struct {
        vp: u32,
        /// The generation it was filled in; 0 is never valid.
        gen: u32,
        /// The host address of the page.
        host: usize,
        /// By offset: 1 + the index in `pool` of the instruction there, or 0.
        idx: [page_size]u16,
    };

    /// An empty cache in place, which allocates pages from `gpa`.
    pub fn init(pc: *PageCache, gpa: std.mem.Allocator) void {
        pc.gpa = gpa;
        pc.slots = @splat(null);
        pc.used = 0;
        pc.epoch = 0;
        pc.gen = 1;
    }

    pub fn deinit(pc: *PageCache) void {
        for (&pc.slots) |*s| if (s.*) |p| {
            pc.gpa.destroy(p);
            s.* = null;
        };
    }

    /// Starts a new generation, dropping every page.
    fn drop(pc: *PageCache) void {
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
    fn page(pc: *PageCache, vp: u32, host: usize) ?*Page {
        const s = &pc.slots[(vp ^ (vp >> 10)) & (nslots - 1)];
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

/// An instruction left: `Exec.exit` says how.
pub const Trap = error{Trap};

/// Serializes LOCK-prefixed accesses that cross a page or aren't aligned,
/// which no host atomic covers.
var split_lock: std.atomic.Value(u32) = .init(0);
/// A word for MFENCE's full barrier.
var fence_word: u32 = 0;

fn lockSplit() void {
    while (split_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockSplit() void {
    split_lock.store(0, .release);
}

/// A memory operand resolved for a read-modify-write: the host bytes of
/// both pages it touches, translated for writing before anything is.
const Ref = struct {
    p: [*]u8,
    /// The second page, when the operand crosses into it after `k` bytes.
    q: ?[*]u8 = null,
    k: u32 = 0,

    fn get(r: Ref, size: u8) u32 {
        if (r.q == null) return ld(r.p, size);
        var buf: [4]u8 = undefined;
        for (0..size) |j| buf[j] = if (j < r.k) r.p[j] else r.q.?[j - r.k];
        return std.mem.readInt(u32, &buf, .little) & flags.sizeMask(size);
    }

    fn put(r: Ref, size: u8, v: u32) void {
        if (r.q == null) return st(r.p, size, v);
        for (0..size) |j| {
            const b: u8 = @truncate(v >> @intCast(8 * j));
            if (j < r.k) r.p[j] = b else r.q.?[j - r.k] = b;
        }
    }

    fn aligned(r: Ref, size: u8) bool {
        return r.q == null and @intFromPtr(r.p) & (size - 1) == 0;
    }
};

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

inline fn sext(v: u32, size: u8) i32 {
    return switch (size) {
        1 => @as(i8, @bitCast(@as(u8, @truncate(v)))),
        2 => @as(i16, @bitCast(@as(u16, @truncate(v)))),
        else => @bitCast(v),
    };
}

pub fn Exec(comptime M: type) type {
    return struct {
        const X = @This();

        c: *Cpu,
        m: M,
        opts: Options,
        /// The instruction: a decode-cache entry's, or `ibuf`.
        i: *const Inst = undefined,
        /// An instruction decoded outside the cache.
        ibuf: Inst = undefined,
        /// EIP after this instruction, or a branch's target.
        next: u32 = 0,
        /// The memory operand's linear address.
        addr: u32 = 0,
        exit: Exit = .stopped,
        /// Instructions run in this call.
        n: u64 = 0,
        /// The PageCache page the last fetch was on, and its virtual page
        /// (no_vp for none). Kept for one call, which a mapping change ends
        /// (it is a syscall).
        cur: *PageCache.Page = undefined,
        cur_vp: u32 = no_vp,

        const no_vp = std.math.maxInt(u32);

        fn loop(x: *X) Exit {
            return if (x.opts.branches != 0) x.loopFor(true) else x.loopFor(false);
        }

        inline fn loopFor(x: *X, comptime count_branches: bool) Exit {
            var taken: u32 = 0;
            while (true) {
                if (x.n >= x.opts.budget) return .stopped;
                if (x.n & 255 == 0 and x.stopRequested()) return .stopped;
                const at = x.c.eip;
                x.step() catch return x.exit;
                x.n += 1;
                x.c.retired += 1;
                if (count_branches and x.c.eip != at +% x.i.len) {
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

        pub fn pageFault(x: *X, va: u32, access: Access) Trap {
            x.exit = .{ .fault = .{ .addr = va, .access = access } };
            x.c.trap = cpu_mod.vec_pf;
            // User mode, and a write's W bit.
            x.c.ecode = 4 | @as(u32, if (access == .write) 2 else 0);
            return error.Trap;
        }

        // ------------------------------------------------------ memory

        /// A host pointer to `va`'s byte for an access, good to the end of
        /// its page. Inline as far as a memory's `hit` (a TLB hit) goes.
        pub inline fn ptr(x: *X, va: u32, access: Access) Trap![*]u8 {
            if (has_hit) if (x.m.hit(va, access)) |p| return p;
            return x.ptrMiss(va, access);
        }

        noinline fn ptrMiss(x: *X, va: u32, access: Access) Trap![*]u8 {
            return x.m.translate(va, access) orelse x.pageFault(va, access);
        }

        /// The bytes of [va, va+size) for writing (or a locked access),
        /// translated, both pages if it crosses.
        inline fn ref(x: *X, va: u32, size: u8, access: Access) Trap!Ref {
            const off = va & (page_size - 1);
            if (off + size <= page_size) return .{ .p = try x.ptr(va, access) };
            return x.refSplit(va, access);
        }

        noinline fn refSplit(x: *X, va: u32, access: Access) Trap!Ref {
            const off = va & (page_size - 1);
            const p = try x.ptr(va, access);
            const k = page_size - off;
            const q = try x.ptr(va +% k, access);
            return .{ .p = p, .q = q, .k = k };
        }

        pub inline fn load(x: *X, va: u32, size: u8) Trap!u32 {
            const off = va & (page_size - 1);
            if (off + size <= page_size) return ld(try x.ptr(va, .read), size);
            return x.loadSplit(va, size);
        }

        noinline fn loadSplit(x: *X, va: u32, size: u8) Trap!u32 {
            const r = try x.ref(va, size, .read);
            return r.get(size);
        }

        pub inline fn store(x: *X, va: u32, size: u8, v: u32) Trap!void {
            const off = va & (page_size - 1);
            if (off + size <= page_size) return st(try x.ptr(va, .write), size, v);
            return x.storeSplit(va, size, v);
        }

        noinline fn storeSplit(x: *X, va: u32, size: u8, v: u32) Trap!void {
            const r = try x.ref(va, size, .write);
            r.put(size, v);
        }

        pub fn load64(x: *X, va: u32) Trap!u64 {
            var b: [8]u8 = undefined;
            try x.loadBytes(va, &b);
            return std.mem.readInt(u64, &b, .little);
        }

        pub fn store64(x: *X, va: u32, v: u64) Trap!void {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, v, .little);
            try x.storeBytes(va, &b);
        }

        /// Reads `buf.len` bytes (at most a page) at `va`.
        pub fn loadBytes(x: *X, va: u32, buf: []u8) Trap!void {
            const off = va & (page_size - 1);
            const p = try x.ptr(va, .read);
            if (off + buf.len <= page_size) return @memcpy(buf, p[0..buf.len]);
            const k = page_size - off;
            const q = try x.ptr(va +% @as(u32, @intCast(k)), .read);
            @memcpy(buf[0..k], p[0..k]);
            @memcpy(buf[k..], q[0 .. buf.len - k]);
        }

        /// Writes `buf` (at most a page) at `va`, checking both pages
        /// before writing either.
        pub fn storeBytes(x: *X, va: u32, buf: []const u8) Trap!void {
            const off = va & (page_size - 1);
            const p = try x.ptr(va, .write);
            if (off + buf.len <= page_size) return @memcpy(p[0..buf.len], buf);
            const k = page_size - off;
            const q = try x.ptr(va +% @as(u32, @intCast(k)), .write);
            @memcpy(p[0..k], buf[0..k]);
            @memcpy(q[0 .. buf.len - k], buf[k..]);
        }

        // ------------------------------------------------------ operands

        /// The memory operand's offset (no segment base).
        fn ea(x: *const X) u32 {
            const i = x.i;
            var a = i.disp;
            if (i.base != dec.no_reg) a +%= x.c.r[i.base];
            if (i.index != dec.no_reg) a +%= x.c.r[i.index] << i.scale;
            if (i.addr16) a &= 0xffff;
            return a;
        }

        /// The memory operand's linear address, faulting through a null
        /// FS or GS.
        inline fn linear(x: *X, offset: u32) Trap!u32 {
            const s = @intFromEnum(x.i.seg);
            if (s >= 4) {
                if (x.c.seg_null & (@as(u8, 1) << @intCast(s)) != 0) return x.exc(cpu_mod.vec_gp);
                return offset +% x.c.seg_base[s];
            }
            return offset;
        }

        pub fn readReg(x: *const X, n: u3, size: u8) u32 {
            return getReg(x.c, n, size);
        }

        pub fn writeReg(x: *X, n: u3, size: u8, v: u32) void {
            setReg(x.c, n, size, v);
        }

        fn regOf(x: *const X, comptime o: Opd) u3 {
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

        /// Reads operand `o` at `size` bytes.
        inline fn get(x: *X, comptime o: Opd, size: u8) Trap!u32 {
            return switch (o) {
                .E => if (x.i.mem) x.load(x.addr, size) else getReg(x.c, x.i.rm(), size),
                .O => x.load(x.addr, size),
                .G => getReg(x.c, x.i.reg(), size),
                .A => getReg(x.c, 0, size),
                .Z => getReg(x.c, x.i.zreg(), size),
                .I => x.i.imm & flags.sizeMask(size),
                .one => 1,
                .CL => x.c.r[1] & 0xff,
                .S => x.c.seg[x.i.reg()],
                .none => 0,
            };
        }

        /// Writes operand `o`.
        inline fn put(x: *X, comptime o: Opd, size: u8, v: u32) Trap!void {
            if (x.isMem(o)) return x.store(x.addr, size, v);
            setReg(x.c, x.regOf(o), size, v);
        }

        /// Reads, changes, and writes operand `o` with `f.apply`, which
        /// may run more than once for a locked operand. Returns the old
        /// value.
        inline fn modify(x: *X, comptime o: Opd, size: u8, f: anytype) Trap!u32 {
            if (x.isMem(o)) {
                const r = try x.ref(x.addr, size, .write);
                if (x.i.lock) return locked(r, size, f);
                const old = r.get(size);
                r.put(size, f.apply(old));
                return old;
            }
            const n = x.regOf(o);
            const old = getReg(x.c, n, size);
            setReg(x.c, n, size, f.apply(old));
            return old;
        }

        fn locked(r: Ref, size: u8, f: anytype) u32 {
            if (r.aligned(size)) {
                while (true) {
                    const old = ld(r.p, size);
                    if (cas(r.p, size, old, f.apply(old) & flags.sizeMask(size))) return old;
                }
            }
            lockSplit();
            defer unlockSplit();
            const old = r.get(size);
            r.put(size, f.apply(old));
            return old;
        }

        // ------------------------------------------------------ stack

        inline fn push(x: *X, size: u8, v: u32) Trap!void {
            const sp = x.c.r[4] -% size;
            try x.store(sp, size, v);
            x.c.r[4] = sp;
        }

        inline fn pop(x: *X, size: u8) Trap!u32 {
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

        inline fn fetch(x: *X) Trap!*const Inst {
            if (tracks_code) if (x.c.pages) |pc| if (x.m.codeEpoch()) |epoch| {
                const eip = x.c.eip;
                if (eip >> 12 == x.cur_vp and epoch == pc.epoch) {
                    const k = x.cur.idx[eip & (page_size - 1)];
                    if (k != 0) return &pc.pool[k - 1];
                }
                return x.fetchPage(pc, epoch);
            };
            return x.fetchEntry();
        }

        /// A fetch the current page doesn't have: through the PageCache,
        /// decoding it there.
        noinline fn fetchPage(x: *X, pc: *PageCache, epoch: usize) Trap!*const Inst {
            if (epoch != pc.epoch) {
                pc.epoch = epoch;
                pc.drop();
                x.cur_vp = no_vp;
            }
            const eip = x.c.eip;
            const vp = eip >> 12;
            const off = eip & (page_size - 1);
            if (vp != x.cur_vp or x.cur.gen != pc.gen) {
                const host = @intFromPtr(try x.ptr(eip, .exec)) - off;
                x.cur = pc.page(vp, host) orelse return x.fetchEntry();
                x.cur_vp = vp;
            }
            const k = x.cur.idx[off];
            if (k != 0) return &pc.pool[k - 1];
            const base: [*]u8 = @ptrFromInt(x.cur.host);
            const inst = dec.decode(base[off..][0..@min(page_size - off, dec.max_len)]) catch |e| switch (e) {
                error.TooLong => return x.exc(cpu_mod.vec_gp),
                // It crosses the page.
                error.Truncated => return x.fetchEntry(),
            };
            if (pc.used == PageCache.ninst) {
                const host = x.cur.host;
                pc.drop();
                // Its page is allocated.
                x.cur = pc.page(vp, host).?;
            }
            const at = pc.used;
            pc.pool[at] = inst;
            pc.used = at + 1;
            x.cur.idx[off] = @intCast(at + 1);
            return &pc.pool[at];
        }

        /// A fetch through the ICache, or decoded each time.
        noinline fn fetchEntry(x: *X) Trap!*const Inst {
            const eip = x.c.eip;
            const p = try x.ptr(eip, .exec);
            const avail = page_size - (eip & (page_size - 1));
            if (avail >= dec.max_len) {
                const ic = x.c.icache orelse {
                    x.ibuf = try x.decodeWhole(p);
                    return &x.ibuf;
                };
                const k = (eip ^ (eip >> 9)) & (ICache.n - 1);
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
            if (x.m.translate(eip +% avail, .exec)) |q| {
                @memcpy(buf[avail..], q[0 .. dec.max_len - avail]);
                len = dec.max_len;
            }
            x.ibuf = dec.decode(buf[0..len]) catch |e| switch (e) {
                error.TooLong => return x.exc(cpu_mod.vec_gp),
                error.Truncated => return x.pageFault(eip +% avail, .exec),
            };
            return &x.ibuf;
        }

        fn decodeWhole(x: *X, p: [*]u8) Trap!Inst {
            return dec.decode(p[0..dec.max_len]) catch |e| switch (e) {
                error.TooLong => x.exc(cpu_mod.vec_gp),
                error.Truncated => unreachable,
            };
        }

        fn step(x: *X) Trap!void {
            x.i = try x.fetch();
            const i = x.i;
            x.next = x.c.eip +% i.len;
            if (i.mem and i.op != .lea and i.op != .nop) x.addr = try x.linear(x.ea());
            try x.exec();
            x.c.eip = x.next;
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

        fn execEntry(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
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
                        d: u32,
                        fn apply(f: @This(), a: u32) u32 {
                            return a +% f.d;
                        }
                    };
                    const d: u32 = if (i.op == .inc) 1 else 0xffff_ffff;
                    const a = try x.modify(e.dst, i.size, F{ .d = d });
                    x.c.fl.recordIncDec(if (i.op == .inc) .inc else .dec, i.size, a, a +% d);
                },
                .not => {
                    const F = struct {
                        fn apply(_: @This(), a: u32) u32 {
                            return ~a;
                        }
                    };
                    _ = try x.modify(e.dst, i.size, F{});
                },
                .neg => {
                    const F = struct {
                        fn apply(_: @This(), a: u32) u32 {
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
                    const b = if (e.imm != .none) i.imm else getReg(x.c, i.reg(), size);
                    const full: i64 = @as(i64, sext(a, size)) * @as(i64, sext(b, size));
                    const lo: u32 = @truncate(@as(u64, @bitCast(full)));
                    const ovf = full != sext(lo, size);
                    setReg(x.c, i.reg(), size, lo);
                    x.c.fl.record(.mul, size, @intFromBool(ovf), 0, lo, 0);
                },
                .div, .idiv => try x.div(e),
                .rol, .ror, .rcl, .rcr => try x.rotate(e),
                .shl, .shr, .sar => try x.shift(e),
                .shld, .shrd => try x.shiftDouble(e),
                .mov => try x.put(e.dst, i.size, try x.get(e.src, i.size)),
                .movzx, .movsx => {
                    const ss: u8 = if (e.src_size == .b) 1 else 2;
                    const v = try x.get(e.src, ss);
                    setReg(x.c, i.reg(), i.size, if (i.op == .movzx) v else @bitCast(sext(v, ss)));
                },
                .lea => setReg(x.c, i.reg(), i.size, x.ea()),
                .xchg => {
                    const size = i.size;
                    const b = try x.get(e.src, size);
                    const F = struct {
                        b: u32,
                        fn apply(f: @This(), _: u32) u32 {
                            return f.b;
                        }
                    };
                    // XCHG with memory is locked whether it says so or not.
                    const a = if (i.mem) locked(try x.ref(x.addr, size, .write), size, F{ .b = b }) else try x.modify(e.dst, size, F{ .b = b });
                    try x.put(e.src, size, a);
                },
                .xadd => {
                    const size = i.size;
                    const b = getReg(x.c, i.reg(), size);
                    const F = struct {
                        b: u32,
                        fn apply(f: @This(), a: u32) u32 {
                            return a +% f.b;
                        }
                    };
                    var a: u32 = undefined;
                    if (i.mem) {
                        a = try x.modify(e.dst, size, F{ .b = b });
                        setReg(x.c, i.reg(), size, a);
                    } else {
                        // The destination is written last, so XADD of a
                        // register with itself leaves the sum.
                        a = getReg(x.c, i.rm(), size);
                        setReg(x.c, i.reg(), size, a);
                        setReg(x.c, i.rm(), size, a +% b);
                    }
                    x.c.fl.record(.add, size, a, b, a +% b, 0);
                },
                .cmpxchg => try x.cmpxchg(),
                .cmpxchg8b => try x.cmpxchg8b(),
                .bswap => x.c.r[i.zreg()] = @byteSwap(x.c.r[i.zreg()]),
                .cbw => if (i.size == 2) {
                    setReg(x.c, 0, 2, @bitCast(sext(x.c.r[0], 1)));
                } else {
                    x.c.r[0] = @bitCast(sext(x.c.r[0], 2));
                },
                .cwd => if (i.size == 2) {
                    setReg(x.c, 2, 2, if (x.c.r[0] & 0x8000 != 0) 0xffff else 0);
                } else {
                    x.c.r[2] = if (x.c.r[0] & 0x8000_0000 != 0) 0xffff_ffff else 0;
                },
                .xlat => {
                    var off = x.c.r[3] +% (x.c.r[0] & 0xff);
                    if (i.addr16) off &= 0xffff;
                    setReg(x.c, 0, 1, try x.load(try x.linear(off), 1));
                },
                .push => {
                    const v = try x.get(e.src, i.size);
                    try x.push(i.size, v);
                },
                .pop => try x.popOp(e),
                .pusha => {
                    const size = i.size;
                    const sp = x.c.r[4];
                    var a = sp;
                    for (0..8) |k| {
                        a -%= size;
                        try x.store(a, size, if (k == 4) sp else getReg(x.c, @intCast(k), size));
                    }
                    x.c.r[4] = a;
                },
                .popa => {
                    const size = i.size;
                    var v: [8]u32 = undefined;
                    var a = x.c.r[4];
                    for (0..8) |k| {
                        v[7 - k] = try x.load(a, size);
                        a +%= size;
                    }
                    for (0..8) |k| if (k != 4) setReg(x.c, @intCast(k), size, v[k]);
                    x.c.r[4] = a;
                },
                .pushf => {
                    const v = x.c.fl.get();
                    try x.push(i.size, v);
                },
                .popf => {
                    const v = try x.pop(i.size);
                    const mask = if (i.size == 2) flags.popf_mask & 0xffff else flags.popf_mask;
                    x.c.fl.setMasked(mask, v);
                },
                .enter => try x.enter(),
                .leave => {
                    const sp = x.c.r[5];
                    const v = try x.load(sp, i.size);
                    x.c.r[4] = sp +% i.size;
                    setReg(x.c, 5, i.size, v);
                },
                .push_sreg => try x.push(i.size, x.c.seg[e.sreg]),
                .pop_sreg => {
                    const v = try x.load(x.c.r[4], i.size);
                    x.c.loadSeg(@enumFromInt(e.sreg), @truncate(v)) catch return x.exc(cpu_mod.vec_gp);
                    x.c.r[4] +%= i.size;
                },
                .mov_sreg => {
                    const r = i.reg();
                    if (r == 1 or r > 5) return x.exc(cpu_mod.vec_ud);
                    const v = try x.get(e.src, 2);
                    x.c.loadSeg(@enumFromInt(r), @truncate(v)) catch return x.exc(cpu_mod.vec_gp);
                },
                .mov_from_sreg => {
                    const r = i.reg();
                    if (r > 5) return x.exc(cpu_mod.vec_ud);
                    const v = x.c.seg[r];
                    if (i.mem) try x.store(x.addr, 2, v) else setReg(x.c, i.rm(), i.size, v);
                },
                .lseg => {
                    const size = i.size;
                    const off = try x.load(x.addr, size);
                    const sel = try x.load(x.addr +% size, 2);
                    x.c.loadSeg(@enumFromInt(e.sreg), @truncate(sel)) catch return x.exc(cpu_mod.vec_gp);
                    setReg(x.c, i.reg(), size, off);
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
                    const size: u8 = if (i.addr16) 2 else 4;
                    const cx = getReg(x.c, 1, size) -% 1;
                    setReg(x.c, 1, size, cx);
                    var taken = cx & flags.sizeMask(size) != 0;
                    if (i.op == .loope) taken = taken and x.c.fl.zf();
                    if (i.op == .loopne) taken = taken and !x.c.fl.zf();
                    if (taken) x.jump(x.next +% i.imm);
                },
                .jcxz => {
                    const size: u8 = if (i.addr16) 2 else 4;
                    if (getReg(x.c, 1, size) == 0) x.jump(x.next +% i.imm);
                },
                .setcc => try x.put(e.dst, 1, @intFromBool(x.c.fl.cond(i.cc()))),
                .cmovcc => {
                    const v = try x.get(e.src, i.size);
                    if (x.c.fl.cond(i.cc())) setReg(x.c, i.reg(), i.size, v);
                },
                .bt, .bts, .btr, .btc => try x.bitTest(e),
                .bsf, .bsr => {
                    const size = i.size;
                    const v = try x.get(e.src, size);
                    if (v != 0) {
                        const r: u32 = if (i.op == .bsf) @ctz(v) else 31 - @clz(v);
                        setReg(x.c, i.reg(), size, r);
                    }
                    // As QEMU: ZF from the source, and the rest as a logic
                    // operation on it.
                    x.c.fl.record(.logic, size, 0, 0, v, 0);
                },
                .lahf => setReg(x.c, 4, 1, (x.c.fl.get() & 0xd5) | 2),
                .sahf => x.c.fl.setMasked(flags.SF | flags.ZF | flags.AF | flags.PF | flags.CF, getReg(x.c, 4, 1)),
                .clc => x.c.fl.setMasked(flags.CF, 0),
                .stc => x.c.fl.setMasked(flags.CF, flags.CF),
                .cmc => x.c.fl.setMasked(flags.CF, if (x.c.fl.cf()) 0 else flags.CF),
                .cld => x.c.fl.bits &= ~flags.DF,
                .std => x.c.fl.bits |= flags.DF,
                .salc => setReg(x.c, 0, 1, if (x.c.fl.cf()) 0xff else 0),
                .movs, .cmps, .stos, .lods, .scas => try x.string(),
                .daa, .das => x.decimal(),
                .aaa, .aas => x.ascii(),
                .aam => {
                    const base = i.imm & 0xff;
                    if (base == 0) return x.exc(cpu_mod.vec_de);
                    const al = x.c.r[0] & 0xff;
                    const lo = al % base;
                    setReg(x.c, 0, 2, ((al / base) << 8) | lo);
                    x.c.fl.record(.logic, 1, 0, 0, lo, 0);
                },
                .aad => {
                    const base = i.imm & 0xff;
                    const al = (x.c.r[0] & 0xff) +% ((x.c.r[0] >> 8) & 0xff) *% base;
                    setReg(x.c, 0, 2, al & 0xff);
                    x.c.fl.record(.logic, 1, 0, 0, al & 0xff, 0);
                },
                .int3 => {
                    x.c.eip = x.next;
                    x.c.retired += 1;
                    x.c.trap = cpu_mod.vec_bp;
                    x.exit = .breakpoint;
                    return error.Trap;
                },
                .int => {
                    const v: u8 = @truncate(i.imm);
                    if (v != 64 and v != 0x80) return x.exc(cpu_mod.vec_gp);
                    x.c.eip = x.next;
                    x.c.retired += 1;
                    x.c.trap = v;
                    x.exit = .{ .syscall = v };
                    return error.Trap;
                },
                .into => if (x.c.fl.of()) {
                    // A trap: EIP goes past it.
                    x.c.eip = x.next;
                    x.c.retired += 1;
                    return x.exc(cpu_mod.vec_of);
                },
                .bound => {
                    const size = i.size;
                    const idx = sext(getReg(x.c, i.reg(), size), size);
                    const lo = sext(try x.load(x.addr, size), size);
                    const hi = sext(try x.load(x.addr +% size, size), size);
                    if (idx < lo or idx > hi) return x.exc(cpu_mod.vec_br);
                },
                .cpuid => x.cpuid(),
                .rdtsc => {
                    const t = x.c.retired;
                    x.c.r[0] = @truncate(t);
                    x.c.r[2] = @truncate(t >> 32);
                },
                .fence => _ = @atomicRmw(u32, &fence_word, .Add, 0, .seq_cst),
                .fwait => try x87.fwait(x),
                .x87 => try x87.exec(x),
                .sse => try sse.exec(x),
            }
        }

        fn jump(x: *X, target: u32) void {
            x.next = if (x.i.size == 2) target & 0xffff else target;
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
                        b: u32,
                        cin: u1,
                        fn apply(f: @This(), a: u32) u32 {
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
            const a = getReg(x.c, 0, size);
            var lo: u32 = undefined;
            var hi: u32 = undefined;
            var ovf: bool = undefined;
            if (i.op == .mul) {
                const p: u64 = @as(u64, a) * b;
                const bits: u6 = @intCast(size * 8);
                lo = @truncate(p & flags.sizeMask(size));
                hi = @truncate(p >> bits);
                ovf = hi != 0;
            } else {
                const p: i64 = @as(i64, sext(a, size)) * sext(b, size);
                const bits: u6 = @intCast(size * 8);
                const u: u64 = @bitCast(p);
                lo = @truncate(u & flags.sizeMask(size));
                hi = @truncate((u >> bits) & flags.sizeMask(size));
                ovf = p != sext(lo, size);
            }
            switch (size) {
                1 => setReg(x.c, 0, 2, (hi << 8) | lo),
                2 => {
                    setReg(x.c, 0, 2, lo);
                    setReg(x.c, 2, 2, hi);
                },
                else => {
                    x.c.r[0] = lo;
                    x.c.r[2] = hi;
                },
            }
            x.c.fl.record(.mul, size, @intFromBool(ovf), 0, lo, 0);
        }

        fn div(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            const size = i.size;
            const d = try x.get(e.src, size);
            if (d == 0) return x.exc(cpu_mod.vec_de);
            const bits: u6 = @intCast(size * 8);
            const n: u64 = switch (size) {
                1 => x.c.r[0] & 0xffff,
                2 => ((x.c.r[2] & 0xffff) << 16) | (x.c.r[0] & 0xffff),
                else => (@as(u64, x.c.r[2]) << 32) | x.c.r[0],
            };
            var q: u32 = undefined;
            var r: u32 = undefined;
            if (i.op == .div) {
                const qq = n / d;
                if (qq > flags.sizeMask(size)) return x.exc(cpu_mod.vec_de);
                q = @intCast(qq);
                r = @intCast(n % d);
            } else {
                const sn: i128 = switch (size) {
                    1 => @as(i16, @bitCast(@as(u16, @truncate(n)))),
                    2 => @as(i32, @bitCast(@as(u32, @truncate(n)))),
                    else => @as(i64, @bitCast(n)),
                };
                const sd: i128 = sext(d, size);
                const qq = @divTrunc(sn, sd);
                const max: i128 = @as(i128, 1) << @intCast(bits - 1);
                if (qq >= max or qq < -max) return x.exc(cpu_mod.vec_de);
                q = @truncate(@as(u128, @bitCast(qq)));
                r = @truncate(@as(u128, @bitCast(@rem(sn, sd))));
            }
            switch (size) {
                1 => setReg(x.c, 0, 2, ((r & 0xff) << 8) | (q & 0xff)),
                2 => {
                    setReg(x.c, 0, 2, q);
                    setReg(x.c, 2, 2, r);
                },
                else => {
                    x.c.r[0] = q;
                    x.c.r[2] = r;
                },
            }
        }

        fn shift(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            const size = i.size;
            const count = (try x.get(e.src, 1)) & 31;
            if (count == 0) {
                // No change, but the operand is still checked.
                if (x.isMem(e.dst)) _ = try x.ref(x.addr, size, .write);
                return;
            }
            const F = struct {
                op: table.Op,
                n: u5,
                size: u8,
                fn apply(f: @This(), a: u32) u32 {
                    return switch (f.op) {
                        .shl => a << f.n,
                        .shr => (a & flags.sizeMask(f.size)) >> f.n,
                        else => @bitCast(sext(a, f.size) >> f.n),
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
            const count: u32 = (if (e.imm == .b) i.imm else x.c.r[1]) & 31;
            if (count == 0) {
                if (x.isMem(e.dst)) _ = try x.ref(x.addr, size, .write);
                return;
            }
            const b = getReg(x.c, i.reg(), size);
            const F = struct {
                left: bool,
                n: u6,
                b: u32,
                size: u8,
                fn apply(f: @This(), a: u32) u32 {
                    const bits: u6 = @intCast(f.size * 8);
                    const m = flags.sizeMask(f.size);
                    if (f.left) {
                        const v: u64 = (@as(u64, a & m) << bits) | (f.b & m);
                        return @truncate((v << f.n) >> bits);
                    }
                    const v: u64 = (@as(u64, f.b & m) << bits) | (a & m);
                    return @truncate(v >> f.n);
                }
            };
            const left = i.op == .shld;
            const f: F = .{ .left = left, .n = @intCast(count), .b = b, .size = size };
            const a = try x.modify(e.dst, size, f);
            const res = f.apply(a) & flags.sizeMask(size);
            const pre = (F{ .left = left, .n = @intCast(count - 1), .b = b, .size = size }).apply(a);
            x.c.fl.record(if (left) .shl else .shr, size, pre, 0, res, 0);
        }

        fn rotate(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            const size = i.size;
            const bits: u32 = @as(u32, size) * 8;
            const raw = (try x.get(e.src, 1)) & 31;
            const rc = i.op == .rcl or i.op == .rcr;
            const n: u32 = if (rc) raw % (bits + 1) else raw % bits;
            if (raw == 0 or (rc and n == 0)) {
                if (x.isMem(e.dst)) _ = try x.ref(x.addr, size, .write);
                return;
            }
            const cin: u64 = @intFromBool(x.c.fl.cf());
            const F = struct {
                op: table.Op,
                n: u32,
                bits: u32,
                cin: u64,
                fn apply(f: @This(), a0: u32) u32 {
                    const m: u64 = (@as(u64, 1) << @intCast(f.bits)) - 1;
                    const a: u64 = a0 & m;
                    const b: u6 = @intCast(f.bits);
                    switch (f.op) {
                        .rol => return @truncate(((a << @intCast(f.n)) | (a >> @intCast(f.bits - f.n))) & m),
                        .ror => return @truncate(((a >> @intCast(f.n)) | (a << @intCast(f.bits - f.n))) & m),
                        .rcl => {
                            const v: u64 = (f.cin << b) | a;
                            const w = (@as(u64, 1) << (b + 1)) - 1;
                            const rv = ((v << @intCast(f.n)) | (v >> @intCast(f.bits + 1 - f.n))) & w;
                            return @truncate(rv & m);
                        },
                        else => {
                            const v: u64 = (f.cin << b) | a;
                            const w = (@as(u64, 1) << (b + 1)) - 1;
                            const rv = ((v >> @intCast(f.n)) | (v << @intCast(f.bits + 1 - f.n))) & w;
                            return @truncate(rv & m);
                        },
                    }
                }
            };
            const f: F = .{ .op = i.op, .n = n, .bits = bits, .cin = cin };
            const a = try x.modify(e.dst, size, f);
            const res = f.apply(a);
            const sb = flags.signBit(size);
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
                setReg(x.c, x.regOf(e.dst), size, v);
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
            setReg(x.c, 5, size, frame);
            x.c.r[4] = sp -% (i.imm & 0xffff);
        }

        fn cmpxchg(x: *X) Trap!void {
            const i = x.i;
            const size = i.size;
            const acc = getReg(x.c, 0, size);
            const src = getReg(x.c, i.reg(), size);
            var old: u32 = undefined;
            if (i.mem) {
                const r = try x.ref(x.addr, size, .write);
                if (i.lock and r.aligned(size)) {
                    old = acc;
                    while (true) {
                        if (cas(r.p, size, acc, src)) break;
                        old = ld(r.p, size);
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
                old = getReg(x.c, i.rm(), size);
                if (old == acc) setReg(x.c, i.rm(), size, src);
            }
            if (old != acc) setReg(x.c, 0, size, old);
            x.c.fl.record(.sub, size, acc, old, acc -% old, 0);
        }

        fn cmpxchg8b(x: *X) Trap!void {
            const c = x.c;
            const want: u64 = (@as(u64, c.r[2]) << 32) | c.r[0];
            const new: u64 = (@as(u64, c.r[1]) << 32) | c.r[3];
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
                c.r[0] = @truncate(old);
                c.r[2] = @truncate(old >> 32);
                c.fl.setMasked(flags.ZF, 0);
            }
        }

        fn bitTest(x: *X, comptime e: *const table.Entry) Trap!void {
            const i = x.i;
            const size = i.size;
            const bits: u32 = @as(u32, size) * 8;
            var bit: u32 = undefined;
            if (e.src == .I) {
                bit = i.imm & (bits - 1);
            } else {
                const off = getReg(x.c, i.reg(), size);
                bit = off & (bits - 1);
                // A register bit offset reaches outside a memory operand.
                if (i.mem) {
                    const words: i32 = sext(off, size) >> @intCast(@ctz(bits));
                    x.addr +%= @bitCast(words *% @as(i32, size));
                }
            }
            const mask = @as(u32, 1) << @intCast(bit);
            var old: u32 = undefined;
            if (i.op == .bt) {
                old = try x.get(e.dst, size);
            } else {
                const F = struct {
                    op: table.Op,
                    mask: u32,
                    fn apply(f: @This(), a: u32) u32 {
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
            const asize: u8 = if (i.addr16) 2 else 4;
            const am = flags.sizeMask(asize);
            const c = x.c;
            const delta: u32 = if (c.fl.df()) 0 -% @as(u32, size) else size;
            const src_base: u32 = blk: {
                const s = @intFromEnum(i.seg);
                if (s >= 4 and (i.op == .movs or i.op == .cmps or i.op == .lods)) {
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
            while (getReg(c, 1, asize) != 0) {
                if (iter & 4095 == 4095 and x.stopRequested()) {
                    // Stop between iterations, at this instruction.
                    x.next = c.eip;
                    x.exit = .stopped;
                    return error.Trap;
                }
                iter +%= 1;
                if (try x.stringBulk(size, am, src_base)) continue;
                try x.stringOnce(size, delta, am, src_base);
                setReg(c, 1, asize, getReg(c, 1, asize) -% 1);
                if (i.op == .cmps or i.op == .scas) {
                    const zf = c.fl.zf();
                    if ((i.rep == .rep and !zf) or (i.rep == .repne and zf)) break;
                }
            }
        }

        /// One iteration of a string instruction.
        fn stringOnce(x: *X, size: u8, delta: u32, am: u32, src_base: u32) Trap!void {
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
                    try x.store(di, size, getReg(c, 0, size));
                    x.advance(7, delta, am);
                },
                .lods => {
                    setReg(c, 0, size, try x.load(si +% src_base, size));
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
                    const a = getReg(c, 0, size);
                    const b = try x.load(di, size);
                    c.fl.record(.sub, size, a, b, a -% b, 0);
                    x.advance(7, delta, am);
                },
                else => unreachable,
            }
        }

        fn advance(x: *X, reg: u3, delta: u32, am: u32) void {
            const c = x.c;
            c.r[reg] = (c.r[reg] & ~am) | ((c.r[reg] +% delta) & am);
        }

        /// REP MOVS and REP STOS forward, a page's worth at a time where
        /// the pages allow. Returns false to do one iteration instead.
        fn stringBulk(x: *X, size: u8, am: u32, src_base: u32) Trap!bool {
            const i = x.i;
            const c = x.c;
            if ((i.op != .movs and i.op != .stos) or c.fl.df() or am != 0xffff_ffff) return false;
            const di = c.r[7];
            var n = c.r[1];
            const dst_room = (page_size - (di & (page_size - 1))) / size;
            n = @min(n, dst_room);
            if (n < 2) return false;
            const dp = try x.ptr(di, .write);
            if (i.op == .stos) {
                const v = getReg(c, 0, size);
                switch (size) {
                    1 => @memset(dp[0..n], @truncate(v)),
                    else => for (0..n) |k| st(dp + k * size, size, v),
                }
                c.r[7] = di +% n * size;
                c.r[1] -%= n;
                return true;
            }
            const si = c.r[6] +% src_base;
            n = @min(n, (page_size - (si & (page_size - 1))) / size);
            if (n < 2) return false;
            const sp = try x.ptr(si, .read);
            const len = n * size;
            const s = @intFromPtr(sp);
            const d = @intFromPtr(dp);
            if (d + len <= s or s + len <= d) {
                @memcpy(dp[0..len], sp[0..len]);
            } else {
                // Overlapping: element by element, as the CPU does.
                for (0..n) |k| st(dp + k * size, size, ld(sp + k * size, size));
            }
            c.r[6] +%= len;
            c.r[7] = di +% len;
            c.r[1] -%= n;
            return true;
        }

        // ------------------------------------------------------ BCD

        fn decimal(x: *X) void {
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
            const r = cpuidLeaf(c.r[0]);
            c.r[0] = r[0];
            c.r[3] = r[1];
            c.r[1] = r[2];
            c.r[2] = r[3];
        }
    };
}

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
        0x8000_0002, 0x8000_0003, 0x8000_0004 => blk: {
            const k = (leaf - 0x8000_0002) * 16;
            var v: [4]u32 = undefined;
            for (&v, 0..) |*w, j| w.* = std.mem.readInt(u32, brand[k + 4 * j ..][0..4], .little);
            break :blk v;
        },
        else => .{ 0, 0, 0, 0 },
    };
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

test "long mode raises #UD until T0 runs it" {
    var c: cpu_mod.Cpu64 = .{ .rip = 0x1000 };
    var m: TestMem = .{ .base = 0, .mem = &.{} };
    try std.testing.expectEqual(cpu_mod.Exit64{ .exception = cpu_mod.vec_ud }, runIn(.long, &c, &m, .{}));
    try std.testing.expectEqual(@as(u64, 0x1000), c.rip);
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
