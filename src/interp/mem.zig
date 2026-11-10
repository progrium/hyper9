//! Guest memory for both tiers: the per-vCPU software TLB that generated
//! code checks inline, and the slow path it calls on a miss.
//!
//! The TLB entry layout and the slow-path signatures are final: T0s and
//! every emitter code against them. Behind the slow path is a `View`: a
//! vCPU's copy of its address space's mappings, which vmm/zemu.zig keeps in
//! step with the address space, and the backend's `CodePages`, which says
//! which pages hold code. `Map` is a fixed list of mappings for tests.
//!
//! The inline check, on any host:
//!
//!     e = tlb.read[(va >> 12) & (entries - 1)]   // tlb.write for stores
//!     if (e.tag == va >> 12 and (va & 0xfff) <= page_size - size)
//!         host = va +% e.delta                    // the access
//!     else
//!         slow path
//!
//! An entry is only filled for a page the access is allowed on, so the
//! tag compare is also the permission check. A page with compiled code
//! never gets a write entry, so stores to it reach the slow path.

const std = @import("std");
const ctx_mod = @import("../jit/ctx.zig");
const frontend = @import("../jit/frontend.zig");
const Ctx = ctx_mod.Ctx;

pub const page_size = 4096;
pub const page_shift = 12;
pub const entries = 256;

pub const TlbEntry = extern struct {
    /// The guest virtual page number (va >> 12), or `invalid`.
    tag: u64 = invalid,
    /// host address - guest address, wrapping, for any address in the page.
    delta: u64 = 0,

    pub const invalid: u64 = std.math.maxInt(u64);
};

pub const Tlb = extern struct {
    read: [entries]TlbEntry = @splat(.{}),
    write: [entries]TlbEntry = @splat(.{}),
    /// For T0's instruction fetch (`probe` with `.exec`). Generated code
    /// never looks here. A page with an exec entry is marked as code.
    exec: [entries]TlbEntry = @splat(.{}),

    pub fn flush(t: *Tlb) void {
        t.* = .{};
    }
};

/// Byte offsets for emitters.
pub const tlb_read_off = @offsetOf(Tlb, "read");
pub const tlb_write_off = @offsetOf(Tlb, "write");
pub const tlb_exec_off = @offsetOf(Tlb, "exec");
pub const entry_size = @sizeOf(TlbEntry);

comptime {
    std.debug.assert(entry_size == 16 and tlb_read_off == 0 and tlb_write_off == entries * 16);
    std.debug.assert(tlb_exec_off == 2 * entries * 16);
}

pub const Access = enum(u8) { read = 0, write = 1, exec = 2 };

/// Fault kinds, in Ctx.exit_info bits 8..15.
pub const FaultKind = enum(u8) {
    unmapped = 0,
    permission = 1,
    alignment = 2,
    /// Not a guest fault: compiled code stored to a page holding code
    /// (`View.code_stores` is `.exit`). Nothing was written, and the
    /// page's translations are gone; the dispatcher runs the instruction
    /// at exit_pc in T0, which does the store, and carries on.
    code = 3,
};

/// The slow path for loads: called on a TLB miss or a page-crossing access
/// of 2^size_log2 bytes at `va`. On success it returns `.ok` with the value,
/// zero-extended, in ctx.scratch, and may have filled the TLB. On a fault it
/// returns `.fault` with ctx.exit_addr and exit_info set; the caller sets
/// exit_pc.
pub const SlowLoadFn = *const fn (ctx: *Ctx, va: u64, size_log2: u32) callconv(.c) u32;
/// The slow path for stores, likewise. Nothing is written if it faults.
pub const SlowStoreFn = *const fn (ctx: *Ctx, va: u64, size_log2: u32, value: u64) callconv(.c) u32;
/// The path for the IR's `cas`: compares the 2^size_log2 bytes at `va` with
/// `expected` and stores `new` there if they're equal, atomically, then
/// returns `.ok` with the old value, zero-extended, in ctx.scratch. The
/// access must be naturally aligned. Any fault reports a write.
pub const SlowCasFn = *const fn (ctx: *Ctx, va: u64, size_log2: u32, expected: u64, new: u64) callconv(.c) u32;


// ---------------------------------------------------------------- views

/// A mapping's permissions.
pub const Perms = packed struct(u8) {
    read: bool = true,
    write: bool = false,
    exec: bool = false,
    _: u5 = 0,

    pub fn allows(p: Perms, acc: Access) bool {
        return switch (acc) {
            .read => p.read,
            .write => p.write,
            .exec => p.exec,
        };
    }
};

/// A guest mapping: [va, va+len) is host memory at `host`. Page-aligned.
pub const Mapping = struct {
    va: u64,
    len: u64,
    host: usize,
    perms: Perms,

    pub fn contains(m: Mapping, va: u64) bool {
        return va >= m.va and va - m.va < m.len;
    }
};

/// Which pages of a backend's guest memory (its arena: one range of host
/// memory every address space maps from) hold code that T0 has decoded or
/// T1 has compiled. One bit per page, shared by every vCPU, keyed by the
/// page's place in the arena rather than by guest address, so a store
/// through any mapping of a page finds it.
///
/// A page with its bit set never has a write entry in any vCPU's TLB, so a
/// store to it reaches the slow path, which drops the page's code first.
/// `mark` sweeps every vCPU's write entries for the page, and a slow path
/// filling a write entry checks the bit after it stores the entry, so
/// between them no write entry survives for a code page.
pub const CodePages = struct {
    /// The arena's host address and length.
    base: usize,
    len: usize,
    bits: []std.atomic.Value(usize),
    /// Bumped by every `invalidate`, so a front end's decode cache can
    /// tell that some page lost its code since it last looked.
    epoch: std.atomic.Value(usize) = .init(0), // usize: wasm32 has no 64-bit atomics
    hooks: Hooks,

    pub const Hooks = struct {
        owner: *anyopaque,
        /// Drops the entries for the host page at `host` from one table
        /// of every vCPU's TLB. Called from any thread.
        drop: *const fn (owner: *anyopaque, host: usize, table: Table) void,
        /// Drops the translations from arena page `page`.
        invalidate: *const fn (owner: *anyopaque, page: u64) void,
    };

    pub fn init(gpa: std.mem.Allocator, base: usize, len: usize, hooks: Hooks) !CodePages {
        const pages = len / page_size;
        const bits = try gpa.alloc(std.atomic.Value(usize), (pages + word - 1) / word);
        @memset(bits, .init(0));
        return .{ .base = base, .len = len, .bits = bits, .hooks = hooks };
    }

    pub fn deinit(c: *CodePages, gpa: std.mem.Allocator) void {
        gpa.free(c.bits);
    }

    /// The arena page holding host address `host`, or null outside it.
    pub fn pageOf(c: *const CodePages, host: usize) ?u64 {
        if (host < c.base or host - c.base >= c.len) return null;
        return (host - c.base) >> page_shift;
    }

    pub fn hostOf(c: *const CodePages, page: u64) usize {
        return c.base + @as(usize, @intCast(page << page_shift));
    }

    pub fn isCode(c: *const CodePages, page: u64) bool {
        return c.bits[@intCast(page / word)].load(.seq_cst) & bit(page) != 0;
    }

    const word = @bitSizeOf(usize);

    fn bit(page: u64) usize {
        return @as(usize, 1) << @intCast(page % word);
    }

    /// Says arena page `page` holds code, before anything is decoded or
    /// compiled from it. Its write entries are gone when this returns.
    pub fn mark(c: *CodePages, page: u64) void {
        const old = c.bits[@intCast(page / word)].fetchOr(bit(page), .seq_cst);
        if (old & bit(page) == 0) c.hooks.drop(c.hooks.owner, c.hostOf(page), .write);
    }

    /// The page's code is stale (a store to it, or the host wrote it):
    /// drops its translations, and its bit until something marks it again.
    pub fn invalidate(c: *CodePages, page: u64) void {
        const old = c.bits[@intCast(page / word)].fetchAnd(~bit(page), .seq_cst);
        if (old & bit(page) == 0) return;
        _ = c.epoch.fetchAdd(1, .seq_cst);
        // T0 fetching through an exec entry wouldn't mark the page again.
        c.hooks.drop(c.hooks.owner, c.hostOf(page), .exec);
        c.hooks.invalidate(c.hooks.owner, page);
    }

    /// `invalidate` for every page of host range [host, host+len).
    pub fn invalidateRange(c: *CodePages, host: usize, len: usize) void {
        if (len == 0) return;
        var p = c.pageOf(host) orelse return;
        const last = c.pageOf(host + len - 1) orelse return;
        while (p <= last) : (p += 1) c.invalidate(p);
    }
};

pub const Table = enum { read, write, exec };

/// Drops `t`'s entries in one table for the host page at `host`. Safe
/// from any thread while the TLB's own vCPU runs: an entry is only ever
/// made invalid, which costs that vCPU a slow path at most.
pub fn dropEntries(t: *Tlb, host: usize, table: Table) void {
    const tab = switch (table) {
        .read => &t.read,
        .write => &t.write,
        .exec => &t.exec,
    };
    for (tab) |*e| {
        const tag = ld64(&e.tag, .seq_cst);
        if (tag == TlbEntry.invalid) continue;
        const delta = ld64(&e.delta, .seq_cst);
        if (((tag << page_shift) +% delta) == @as(u64, host)) st64(&e.tag, TlbEntry.invalid, .seq_cst);
    }
}

/// A vCPU's view of its address space, which ctx.space points at. The
/// vmm backend owns `maps` (sorted by address, not overlapping) and
/// replaces it between runs, never while the vCPU runs guest code.
pub const View = struct {
    maps: []const Mapping = &.{},
    /// The backend's code pages, or null if nothing tracks code.
    code: ?*CodePages = null,
    tlb: *Tlb,
    /// What a store to a page holding code does. T0 drops the page's code
    /// and stores. Compiled code can't go on running what it came from, so
    /// under `.exit` the store faults with `FaultKind.code` instead.
    code_stores: enum { store, exit } = .store,

    pub fn find(v: *const View, va: u64) ?*const Mapping {
        var lo: usize = 0;
        var hi: usize = v.maps.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const m = &v.maps[mid];
            if (va < m.va) hi = mid else if (va - m.va >= m.len) lo = mid + 1 else return m;
        }
        return null;
    }

    /// Host bytes for [va, va+len), if they lie in one mapping that allows
    /// `acc`. For T0's own reads, never for writes to code.
    pub fn translate(v: *const View, va: u64, len: u64, acc: Access) ?[]u8 {
        const m = v.find(va) orelse return null;
        if (!m.perms.allows(acc) or len > m.len - (va - m.va)) return null;
        const p: [*]u8 = @ptrFromInt(m.host + @as(usize, @intCast(va - m.va)));
        return p[0..@intCast(len)];
    }

    /// Reads guest code: copies executable bytes from `va` into `buf`,
    /// stopping at the first byte that isn't executable, and returns how
    /// many it copied. The pages read are marked as holding code, so a
    /// later store to them reaches the slow path.
    pub fn fetch(v: *const View, va: u64, buf: []u8) usize {
        var done: usize = 0;
        while (done < buf.len) {
            const a = va +% done;
            const m = v.find(a) orelse break;
            if (!m.perms.exec) break;
            const in_page = page_size - @as(usize, @intCast(a & (page_size - 1)));
            const left_in_map: usize = @intCast(m.len - (a - m.va));
            const n = @min(buf.len - done, in_page, left_in_map);
            const host = m.host + @as(usize, @intCast(a - m.va));
            if (v.code) |c| if (c.pageOf(host)) |pg| c.mark(pg);
            @memcpy(buf[done..][0..n], @as([*]const u8, @ptrFromInt(host))[0..n]);
            done += n;
        }
        return done;
    }

    fn sourceRead(p: *anyopaque, va: u64, buf: []u8) usize {
        const v: *const View = @ptrCast(@alignCast(p));
        return v.fetch(va, buf);
    }

    /// The view as a front end's code source, for lifting.
    pub fn source(v: *View) frontend.Source {
        return .{ .ctx = v, .read = sourceRead };
    }

    /// Lookups for the shared slow path.
    fn lookup(v: *const View, va: u64) ?Mapping {
        return if (v.find(va)) |m| m.* else null;
    }
};

/// The slow path for loads over the View in ctx.space.
pub fn slowLoad(ctx: *Ctx, va: u64, size_log2: u32) callconv(.c) u32 {
    const v: *View = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    return load(ctx, v, va, size_log2);
}

/// `cas` over the View in ctx.space.
pub fn slowCas(ctx: *Ctx, va: u64, size_log2: u32, expected: u64, new: u64) callconv(.c) u32 {
    const v: *View = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    return cas(ctx, v, va, size_log2, expected, new);
}

/// The slow path for stores over the View in ctx.space.
pub fn slowStore(ctx: *Ctx, va: u64, size_log2: u32, value: u64) callconv(.c) u32 {
    const v: *View = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    return store(ctx, v, va, size_log2, value);
}

// ---------------------------------------------------------------- the slow path

const Resolved = union(enum) { ok: usize, fault: FaultKind };

/// 64-bit atomics, where the host has them. wasm32 has none, and runs
/// one vCPU at a time, so plain accesses do there.
const atomic64 = @bitSizeOf(usize) >= 64;

inline fn ld64(p: *const u64, comptime order: std.builtin.AtomicOrder) u64 {
    return if (atomic64) @atomicLoad(u64, p, order) else p.*;
}

inline fn st64(p: *u64, v: u64, comptime order: std.builtin.AtomicOrder) void {
    if (atomic64) @atomicStore(u64, p, v, order) else p.* = v;
}

/// Finds host memory for the part of an access in va's page, checks it,
/// and fills the TLB. `src` is a View or a Map.
fn resolve(src: anytype, tlb: *Tlb, va: u64, acc: Access) Resolved {
    const m = src.lookup(va) orelse return .{ .fault = .unmapped };
    if (!m.perms.allows(acc)) return .{ .fault = .permission };
    const host = m.host + @as(usize, @intCast(va - m.va));
    const page_va = va & ~@as(u64, page_size - 1);
    // Mappings are page-aligned, but a test's Map may not be.
    const whole = page_va >= m.va and page_va + page_size <= m.va + m.len;
    const slot: usize = @intCast((va >> page_shift) & (entries - 1));
    const code: ?*CodePages = if (@TypeOf(src.*) == View) src.code else null;
    const cpage: ?u64 = if (code) |c| c.pageOf(host) else null;
    switch (acc) {
        .read => if (whole) {
            tlb.read[slot] = .{ .tag = va >> page_shift, .delta = @as(u64, host) -% va };
        },
        .write => {
            if (cpage) |pg| if (code.?.isCode(pg)) {
                if (@TypeOf(src.*) == View and src.code_stores == .exit) return .{ .fault = .code };
                code.?.invalidate(pg);
            };
            if (whole) {
                const e = &tlb.write[slot];
                st64(&e.tag, TlbEntry.invalid, .seq_cst);
                st64(&e.delta, @as(u64, host) -% va, .seq_cst);
                st64(&e.tag, va >> page_shift, .seq_cst);
                // CodePages.mark sweeps after it sets the bit; checking it
                // after the entry is in means one of the two sees the other.
                if (cpage) |pg| if (code.?.isCode(pg)) st64(&e.tag, TlbEntry.invalid, .seq_cst);
            }
        },
        .exec => {
            if (cpage) |pg| code.?.mark(pg);
            if (whole) {
                const e = &tlb.exec[slot];
                st64(&e.tag, TlbEntry.invalid, .seq_cst);
                st64(&e.delta, @as(u64, host) -% va, .seq_cst);
                st64(&e.tag, va >> page_shift, .seq_cst);
                // As for writes: an invalidate between the mark and here
                // must not leave an entry behind.
                if (cpage) |pg| if (!code.?.isCode(pg)) st64(&e.tag, TlbEntry.invalid, .seq_cst);
            }
        },
    }
    return .{ .ok = host };
}

fn fault(ctx: *Ctx, va: u64, acc: Access, k: FaultKind) u32 {
    ctx.exit_addr = va;
    ctx.exit_info = @as(u64, @intFromEnum(acc)) | (@as(u64, @intFromEnum(k)) << 8);
    return @intFromEnum(ctx_mod.Exit.fault);
}

/// The host addresses of an access's bytes in its first page and, if it
/// crosses, the second, with every check done before anything is touched.
const Parts = struct { a: usize, b: usize, first: u32 };

fn parts(ctx: *Ctx, src: anytype, va: u64, n: u32, acc: Access) union(enum) { ok: Parts, fault: u32 } {
    const tlb: *Tlb = @ptrFromInt(@as(usize, @intCast(ctx.tlb)));
    const in_page: u32 = @intCast(page_size - (va & (page_size - 1)));
    const first = @min(n, in_page);
    const a = switch (resolve(src, tlb, va, acc)) {
        .ok => |h| h,
        .fault => |k| return .{ .fault = fault(ctx, va, acc, k) },
    };
    var b: usize = 0;
    if (first < n) {
        const va2 = va +% first;
        b = switch (resolve(src, tlb, va2, acc)) {
            .ok => |h| h,
            .fault => |k| return .{ .fault = fault(ctx, va2, acc, k) },
        };
    }
    return .{ .ok = .{ .a = a, .b = b, .first = first } };
}

fn load(ctx: *Ctx, src: anytype, va: u64, size_log2: u32) u32 {
    const n = @as(u32, 1) << @intCast(size_log2);
    const p = switch (parts(ctx, src, va, n, .read)) {
        .ok => |p| p,
        .fault => |r| return r,
    };
    var v: u64 = 0;
    if (p.first == n and p.a % n == 0) {
        // Aligned in one page: single-copy atomic, as on the guest.
        v = switch (size_log2) {
            0 => @atomicLoad(u8, @as(*const u8, @ptrFromInt(p.a)), .unordered),
            1 => @atomicLoad(u16, @as(*const u16, @ptrFromInt(p.a)), .unordered),
            2 => @atomicLoad(u32, @as(*const u32, @ptrFromInt(p.a)), .unordered),
            else => ld64(@as(*const u64, @ptrFromInt(p.a)), .unordered),
        };
    } else {
        const bytes = std.mem.asBytes(&v);
        @memcpy(bytes[0..p.first], @as([*]const u8, @ptrFromInt(p.a))[0..p.first]);
        if (p.first < n) @memcpy(bytes[p.first..n], @as([*]const u8, @ptrFromInt(p.b))[0 .. n - p.first]);
    }
    ctx.scratch = v;
    return 0;
}

fn store(ctx: *Ctx, src: anytype, va: u64, size_log2: u32, value: u64) u32 {
    const n = @as(u32, 1) << @intCast(size_log2);
    const p = switch (parts(ctx, src, va, n, .write)) {
        .ok => |p| p,
        .fault => |r| return r,
    };
    if (p.first == n and p.a % n == 0) {
        switch (size_log2) {
            0 => @atomicStore(u8, @as(*u8, @ptrFromInt(p.a)), @truncate(value), .unordered),
            1 => @atomicStore(u16, @as(*u16, @ptrFromInt(p.a)), @truncate(value), .unordered),
            2 => @atomicStore(u32, @as(*u32, @ptrFromInt(p.a)), @truncate(value), .unordered),
            else => st64(@as(*u64, @ptrFromInt(p.a)), value, .unordered),
        }
    } else {
        const bytes = std.mem.asBytes(&value);
        @memcpy(@as([*]u8, @ptrFromInt(p.a))[0..p.first], bytes[0..p.first]);
        if (p.first < n) @memcpy(@as([*]u8, @ptrFromInt(p.b))[0 .. n - p.first], bytes[p.first..n]);
    }
    return 0;
}

fn cas(ctx: *Ctx, src: anytype, va: u64, size_log2: u32, expected: u64, new: u64) u32 {
    const n = @as(u64, 1) << @intCast(size_log2);
    if (va % n != 0) return fault(ctx, va, .write, .alignment);
    const tlb: *Tlb = @ptrFromInt(@as(usize, @intCast(ctx.tlb)));
    const h = switch (resolve(src, tlb, va, .write)) {
        .ok => |h| h,
        .fault => |k| return fault(ctx, va, .write, k),
    };
    ctx.scratch = casAt(h, size_log2, expected, new);
    return 0;
}

/// An atomic compare-and-swap at host address h; returns the old value.
pub fn casAt(h: usize, size_log2: u32, expected: u64, new: u64) u64 {
    return switch (size_log2) {
        0 => casT(u8, h, expected, new),
        1 => casT(u16, h, expected, new),
        2 => casT(u32, h, expected, new),
        else => if (atomic64) casT(u64, h, expected, new) else blk: {
            // wasm32 runs one vCPU at a time.
            const p: *u64 = @ptrFromInt(h);
            const old = p.*;
            if (old == expected) p.* = new;
            break :blk old;
        },
    };
}

fn casT(comptime T: type, h: usize, expected: u64, new: u64) u64 {
    const p: *T = @ptrFromInt(h);
    return @cmpxchgStrong(T, p, @truncate(expected), @truncate(new), .seq_cst, .seq_cst) orelse @as(T, @truncate(expected));
}

/// The inline fast path, in Zig, for T0 and `ir_eval`: the same check the
/// emitters generate.
pub inline fn fast(tlb: *const Tlb, va: u64, size: u32, comptime write: bool) ?usize {
    const table = if (write) &tlb.write else &tlb.read;
    const e = table[@intCast((va >> page_shift) & (entries - 1))];
    if (e.tag != va >> page_shift or (va & (page_size - 1)) > page_size - size) return null;
    return @intCast(va +% e.delta);
}

/// `fast` for T0's instruction fetch, through the exec table.
pub inline fn fastExec(tlb: *const Tlb, va: u64, size: u32) ?usize {
    const e = tlb.exec[@intCast((va >> page_shift) & (entries - 1))];
    if (e.tag != va >> page_shift or (va & (page_size - 1)) > page_size - size) return null;
    return @intCast(va +% e.delta);
}

/// Probes the page holding `va` for an access, over the View in
/// ctx.space, and fills that access's TLB entry: a host pointer to va's
/// byte, good to the end of its page, or null with ctx.exit_addr and
/// exit_info set as for a fault. For T0, which reads code through it
/// (`.exec`, which marks the page as code) and takes a writable pointer
/// for an atomic read-modify-write (`.write`, which drops the page's code
/// first, or faults with `code` under `View.code_stores == .exit`). An
/// access crossing into the next page probes that page too.
pub fn probe(ctx: *Ctx, va: u64, acc: Access) ?[*]u8 {
    const v: *View = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    const tlb: *Tlb = @ptrFromInt(@as(usize, @intCast(ctx.tlb)));
    return switch (resolve(@as(*const View, v), tlb, va, acc)) {
        .ok => |h| @ptrFromInt(h),
        .fault => |k| {
            _ = fault(ctx, va, acc, k);
            return null;
        },
    };
}

// ---------------------------------------------------------------- Map

/// A guest mapping in a `Map`.
pub const Region = struct {
    va: u64,
    mem: []u8,
    read: bool = true,
    write: bool = false,
    exec: bool = false,
};

/// A fixed list of mappings with no code tracking, for tests and the
/// tracer: ctx.space points at one, with `mapSlowLoad` and `mapSlowStore`
/// as the slow paths.
pub const Map = struct {
    regions: []const Region,

    fn lookup(m: *const Map, va: u64) ?Mapping {
        for (m.regions) |r| if (va >= r.va and va - r.va < r.mem.len) return .{
            .va = r.va,
            .len = r.mem.len,
            .host = @intFromPtr(r.mem.ptr),
            .perms = .{ .read = r.read, .write = r.write, .exec = r.exec },
        };
        return null;
    }
};

pub fn mapSlowLoad(ctx: *Ctx, va: u64, size_log2: u32) callconv(.c) u32 {
    const m: *const Map = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    return load(ctx, m, va, size_log2);
}

pub fn mapSlowStore(ctx: *Ctx, va: u64, size_log2: u32, value: u64) callconv(.c) u32 {
    const m: *const Map = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    return store(ctx, m, va, size_log2, value);
}

pub fn mapSlowCas(ctx: *Ctx, va: u64, size_log2: u32, expected: u64, new: u64) callconv(.c) u32 {
    const m: *const Map = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    return cas(ctx, m, va, size_log2, expected, new);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "slow path fills the TLB, and faults name the address" {
    var page: [2 * page_size]u8 align(page_size) = @splat(0);
    const regions = [_]Region{.{ .va = 0x10000, .mem = page[0..page_size], .write = true }};
    var map: Map = .{ .regions = &regions };
    var tlb: Tlb = .{};
    var c: Ctx = .{ .tlb = @intFromPtr(&tlb), .space = @intFromPtr(&map) };
    try testing.expectEqual(@as(u32, 0), mapSlowStore(&c, 0x10008, 3, 0x1122334455667788));
    try testing.expect(fast(&tlb, 0x10010, 8, true) != null);
    try testing.expectEqual(@as(u32, 0), mapSlowLoad(&c, 0x10008, 2));
    try testing.expectEqual(@as(u64, 0x55667788), c.scratch);
    // Crossing into an unmapped page faults at its first byte there.
    try testing.expectEqual(@as(u32, 5), mapSlowLoad(&c, 0x10ffc, 3));
    try testing.expectEqual(@as(u64, 0x11000), c.exit_addr);
    // A store that would fault writes nothing.
    try testing.expectEqual(@as(u32, 5), mapSlowStore(&c, 0x10ffe, 2, 0xffffffff));
    try testing.expectEqual(@as(u8, 0), page[page_size - 2]);
}

/// A view over three pages: read-write at 0x10000, read-only at 0x11000,
/// and executable at 0x20000, with code tracking over all three.
const TestView = struct {
    pages: [3 * page_size]u8 align(page_size) = @splat(0),
    maps: [3]Mapping = undefined,
    tlb: Tlb = .{},
    code: CodePages = undefined,
    view: View = undefined,
    ctx: Ctx = .{},
    dropped: u32 = 0,
    invalidated: u32 = 0,

    fn init(t: *TestView) !void {
        const base = @intFromPtr(&t.pages);
        t.maps = .{
            .{ .va = 0x10000, .len = page_size, .host = base, .perms = .{ .write = true } },
            .{ .va = 0x11000, .len = page_size, .host = base + page_size, .perms = .{} },
            .{ .va = 0x20000, .len = page_size, .host = base + 2 * page_size, .perms = .{ .exec = true, .write = true } },
        };
        t.code = try .init(testing.allocator, base, t.pages.len, .{ .owner = t, .drop = dropHook, .invalidate = invHook });
        t.view = .{ .maps = &t.maps, .code = &t.code, .tlb = &t.tlb };
        t.ctx = .{ .tlb = @intFromPtr(&t.tlb), .space = @intFromPtr(&t.view) };
    }
    fn deinit(t: *TestView) void {
        t.code.deinit(testing.allocator);
    }
    fn dropHook(p: *anyopaque, host: usize, table: Table) void {
        const t: *TestView = @ptrCast(@alignCast(p));
        if (table == .write) t.dropped += 1;
        dropEntries(&t.tlb, host, table);
    }
    fn invHook(p: *anyopaque, _: u64) void {
        const t: *TestView = @ptrCast(@alignCast(p));
        t.invalidated += 1;
    }
};

test "view: permissions, page crossing, and fault kinds" {
    var t: TestView = .{};
    try t.init();
    defer t.deinit();
    const c = &t.ctx;
    // Write then read across the boundary between the two data pages:
    // the read-only second page refuses the store before any byte lands.
    try testing.expectEqual(@as(u32, 5), slowStore(c, 0x10ffc, 3, 0x1122334455667788));
    try testing.expectEqual(@as(u64, 0x11000), c.exit_addr);
    try testing.expectEqual(@as(u64, 1 | 1 << 8), c.exit_info); // write, permission
    try testing.expectEqual(@as(u8, 0), t.pages[page_size - 4]);
    // Reads across it work, and fill both pages' read entries.
    t.pages[page_size - 1] = 0xaa;
    t.pages[page_size] = 0xbb;
    try testing.expectEqual(@as(u32, 0), slowLoad(c, 0x10fff, 1));
    try testing.expectEqual(@as(u64, 0xbbaa), c.scratch);
    try testing.expect(fast(&t.tlb, 0x10000, 8, false) != null);
    try testing.expect(fast(&t.tlb, 0x11000, 8, false) != null);
    try testing.expect(fast(&t.tlb, 0x11000, 8, true) == null);
    // Unmapped.
    try testing.expectEqual(@as(u32, 5), slowLoad(c, 0x30000, 0));
    try testing.expectEqual(@as(u64, 0 | 0 << 8), c.exit_info);
    // The entry's address check covers page crossing.
    try testing.expect(fast(&t.tlb, 0x10ffc, 8, false) == null);
    // translate and fetch respect permissions.
    try testing.expect(t.view.translate(0x11000, 8, .write) == null);
    try testing.expect(t.view.translate(0x10ff8, 16, .read) == null);
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), t.view.fetch(0x10000, &buf));
    try testing.expectEqual(@as(usize, 8), t.view.fetch(0x20000, &buf));
    try testing.expectEqual(@as(usize, 4), t.view.fetch(0x20ffc, &buf));
}

test "view: code pages get no write entries, and stores to them drop their code" {
    var t: TestView = .{};
    try t.init();
    defer t.deinit();
    const c = &t.ctx;
    // A write entry for the code page, before it holds code.
    try testing.expectEqual(@as(u32, 0), slowStore(c, 0x20000, 2, 0xd503201f));
    try testing.expect(fast(&t.tlb, 0x20000, 4, true) != null);
    // Fetching marks it and sweeps the write entry away.
    var buf: [4]u8 = undefined;
    _ = t.view.fetch(0x20000, &buf);
    try testing.expectEqual(@as(u32, 1), t.dropped);
    try testing.expect(t.code.isCode(2));
    try testing.expect(fast(&t.tlb, 0x20000, 4, true) == null);
    // Compiled code's store faults with `code`, writing nothing.
    t.view.code_stores = .exit;
    try testing.expectEqual(@as(u32, 5), slowStore(c, 0x20004, 2, 0xffffffff));
    try testing.expectEqual(@as(u64, 1 | 3 << 8), c.exit_info);
    try testing.expectEqual(@as(u8, 0), t.pages[2 * page_size + 4]);
    try testing.expectEqual(@as(u32, 0), t.invalidated);
    // T0's store drops the page's code and lands.
    t.view.code_stores = .store;
    const epoch = t.code.epoch.load(.monotonic);
    try testing.expectEqual(@as(u32, 0), slowStore(c, 0x20004, 2, 0xffffffff));
    try testing.expectEqual(@as(u32, 1), t.invalidated);
    try testing.expect(!t.code.isCode(2));
    try testing.expect(t.code.epoch.load(.monotonic) != epoch);
    try testing.expectEqual(@as(u8, 0xff), t.pages[2 * page_size + 4]);
    // Now it's data again, with a write entry.
    try testing.expect(fast(&t.tlb, 0x20000, 4, true) != null);
}

test "view: a store filling a write entry races a mark and loses" {
    // The other half of the protocol: a bit set before the fill's check
    // means the entry doesn't stay, even with no sweep to remove it.
    var t: TestView = .{};
    try t.init();
    defer t.deinit();
    _ = t.code.bits[0].fetchOr(1 << 2, .seq_cst); // set without sweeping
    t.view.code_stores = .store;
    // The store itself invalidates and clears the bit, then fills; set
    // the bit again from the invalidate hook, as a racing mark would.
    t.code.hooks.invalidate = struct {
        fn f(p: *anyopaque, _: u64) void {
            const tv: *TestView = @ptrCast(@alignCast(p));
            _ = tv.code.bits[0].fetchOr(1 << 2, .seq_cst);
        }
    }.f;
    try testing.expectEqual(@as(u32, 0), slowStore(&t.ctx, 0x20000, 2, 1));
    try testing.expect(fast(&t.tlb, 0x20000, 4, true) == null);
}

test "probe: host pointers for T0, exec entries, and code marking" {
    var t: TestView = .{};
    try t.init();
    defer t.deinit();
    const c = &t.ctx;
    // Instruction fetch: an exec entry, and the page is code from now on.
    const p = probe(c, 0x20ff0, .exec).?;
    try testing.expectEqual(@intFromPtr(&t.pages) + 2 * page_size + 0xff0, @intFromPtr(p));
    try testing.expect(fastExec(&t.tlb, 0x20000, 4) != null);
    try testing.expect(t.code.isCode(2));
    // Not executable, or not mapped.
    try testing.expect(probe(c, 0x10000, .exec) == null);
    try testing.expectEqual(@as(u64, 2 | 1 << 8), c.exit_info);
    try testing.expect(probe(c, 0x21000, .exec) == null);
    try testing.expectEqual(@as(u64, 0x21000), c.exit_addr);
    // A writable pointer for an atomic: on a code page it drops the code,
    // and the exec entry with it, so the next fetch marks the page again.
    try testing.expect(probe(c, 0x20008, .write) != null);
    try testing.expect(!t.code.isCode(2));
    try testing.expect(fastExec(&t.tlb, 0x20000, 4) == null);
    _ = probe(c, 0x20000, .exec).?;
    try testing.expect(t.code.isCode(2));
    t.view.code_stores = .exit;
    try testing.expect(probe(c, 0x20008, .write) == null);
    try testing.expectEqual(@as(u64, 1 | 3 << 8), c.exit_info);
}
