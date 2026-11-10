//! The code cache: translations of guest code, how they find each other,
//! and how they go away.
//!
//! - **One cache per backend,** in one codemem.Region filled by a bump
//!   pointer and shared by every vCPU.
//! - **Translations are keyed by guest PC and the arena page holding it**
//!   (mem.CodePages' numbering), so two address spaces with the same text
//!   at the same address share them, and one whose mappings changed can't
//!   hit a stale one. A translation that runs into a second guest page
//!   also records that page, and a lookup checks it too.
//! - **Chaining.** A translation's direct exits (`exit.chain`) each have a
//!   chain site: one patchable jump, which first falls through to the exit
//!   and, once the dispatcher has seen where it goes, jumps straight to the
//!   target's chain entry. Only targets on a guest page the source itself
//!   was translated from are linked, since that's all that's sure to map
//!   the same way in every space sharing the source.
//! - **The jump cache.** Each vCPU has 1024 direct-mapped entries from guest
//!   PC to translation, for indirect branches and for the dispatcher. A
//!   change to the vCPU's mappings clears it (vmm/zemu.zig).
//! - **Invalidation.** `invalidatePage` drops every translation from an
//!   arena page: out of the lookup table and every jump cache, and every
//!   jump patched into it reset. Its code stays until the next flush, since
//!   a vCPU may still be inside it.
//! - **Flushing.** When the region is full, `insert` fails with `Full`, and
//!   the vmm layer stops every vCPU (kick and wait) and calls `reset`.
//!
//! The chain-site contract with the emitters:
//!
//! - arm64: the site is one `B` at a 4-byte boundary, unlinked as `b .+4`.
//! - x86-64: the site is `jmp rel32` (E9) with the rel32 4-byte aligned,
//!   unlinked as `jmp .+5`.
//!
//! In both, the unlinked fall-through is the exit sequence, which sets
//! ctx.exit_pc to the target and ctx.exit_info to the site's own executable
//! address (PC-relative, so code can be copied anywhere), then leaves with
//! `.chain`. A linked jump lands on the target's chain entry with the
//! context register and stack as at the site.

const std = @import("std");
const builtin = @import("builtin");
const codemem = @import("codemem.zig");
const ctx_mod = @import("ctx.zig");
const mem = @import("../interp/mem.zig");
const Ctx = ctx_mod.Ctx;

pub const max_chains = 2;
pub const no_page = std.math.maxInt(u64);

/// A direct exit, as an emitter reports it: the site's offset from the
/// start of the code, and the guest PC it leaves for.
pub const Chain = struct { site: u32, pc: u64 };

pub const Tb = struct {
    pc: u64,
    /// The arena page holding `pc`.
    page: u64,
    /// The second guest page the translation read, if any, and its arena
    /// page.
    va2: u64 = no_page,
    page2: u64 = no_page,
    /// Where it is in the region.
    off: u32,
    len: u32,
    chain_entry: u32,
    /// The chain entry's executable address.
    chain_addr: u64 = 0,
    entry: ctx_mod.EntryFn,
    outs: [max_chains]Out = @splat(.{}),
    nouts: u8 = 0,
    /// Sites in other translations linked to this one.
    ins: std.ArrayList(In) = .empty,
    valid: std.atomic.Value(bool) = .init(true),

    pub const Out = struct {
        /// Region offset of the site.
        site: u32 = 0,
        pc: u64 = 0,
        to: ?*Tb = null,
    };
    const In = struct { from: *Tb, slot: u8 };

    pub fn isValid(t: *const Tb) bool {
        return t.valid.load(.acquire);
    }

    /// Whether guest PC `pc` lies on a guest page this translation came
    /// from, as seen from wherever `pc` was (`t.pc`'s page or `va2`).
    fn samePages(t: *const Tb, pc: u64) bool {
        const p = pc >> mem.page_shift;
        return p == t.pc >> mem.page_shift or (t.va2 != no_page and p == t.va2 >> mem.page_shift);
    }
};

// ---------------------------------------------------------------- jump cache

/// The layout is the runtime ABI's (ctx.JumpEntry), so generated code can
/// look up `exit.indirect` inline through Ctx.jump.
pub const jump_entries = ctx_mod.jump_entries;

pub const JumpEntry = extern struct {
    pc: u64 = invalid,
    tb: u64 = 0,
    code: u64 = 0,
    pub const invalid: u64 = std.math.maxInt(u64);
};

comptime {
    std.debug.assert(@sizeOf(JumpEntry) == @sizeOf(ctx_mod.JumpEntry) and @offsetOf(JumpEntry, "code") == @offsetOf(ctx_mod.JumpEntry, "code"));
}

/// A vCPU's jump cache. Only its own vCPU fills it; any thread may clear
/// an entry.
pub const JumpCache = extern struct {
    e: [jump_entries]JumpEntry = @splat(.{}),

    pub fn index(pc: u64) usize {
        return ctx_mod.jumpIndex(pc);
    }

    pub fn clear(j: *JumpCache) void {
        for (&j.e) |*e| st64(&e.pc, JumpEntry.invalid);
    }

    fn get(j: *const JumpCache, pc: u64) ?*Tb {
        const e = &j.e[index(pc)];
        if (ld64(&e.pc) != pc) return null;
        const tb: *Tb = @ptrFromInt(@as(usize, @intCast(ld64(&e.tb))));
        return tb;
    }

    fn put(j: *JumpCache, tb: *Tb) void {
        const e = &j.e[index(tb.pc)];
        st64(&e.pc, JumpEntry.invalid);
        st64(&e.tb, @intFromPtr(tb));
        st64(&e.code, tb.chain_addr);
        st64(&e.pc, tb.pc);
    }

    fn drop(j: *JumpCache, tb: *Tb) void {
        const e = &j.e[index(tb.pc)];
        if (ld64(&e.tb) == @intFromPtr(tb)) st64(&e.pc, JumpEntry.invalid);
    }
};

const atomic64 = @bitSizeOf(usize) >= 64;

inline fn ld64(p: *const u64) u64 {
    return if (atomic64) @atomicLoad(u64, p, .acquire) else p.*;
}

inline fn st64(p: *u64, v: u64) void {
    if (atomic64) @atomicStore(u64, p, v, .release) else p.* = v;
}

// ---------------------------------------------------------------- chain sites

/// Patching chain sites in the region: one aligned 32-bit store, which is
/// atomic for instruction fetch on both hosts (a `B` to a `B` on arm64; a
/// rel32 on x86-64), so a vCPU running past the site sees the old jump or
/// the new one.
pub const Patcher = struct {
    patch: *const fn (r: *codemem.Region, site: u32, target: ?u32) void,

    pub const host: ?Patcher = switch (builtin.cpu.arch) {
        .aarch64 => .{ .patch = arm64Patch },
        .x86_64 => .{ .patch = x64Patch },
        else => null,
    };
};

fn store32(r: *codemem.Region, off: u32, v: u32) void {
    r.beginWrite();
    const w = r.writable(off, 4);
    @atomicStore(u32, @as(*u32, @ptrCast(@alignCast(w.ptr))), v, .release);
    r.commit(off, 4);
}

fn arm64Patch(r: *codemem.Region, site: u32, target: ?u32) void {
    std.debug.assert(site % 4 == 0);
    const words: i64 = if (target) |t| (@as(i64, t) - @as(i64, site)) >> 2 else 1;
    store32(r, site, 0x14000000 | @as(u32, @truncate(@as(u64, @bitCast(words)))) & 0x03ffffff);
}

fn x64Patch(r: *codemem.Region, site: u32, target: ?u32) void {
    std.debug.assert((site + 1) % 4 == 0);
    const rel: i64 = if (target) |t| @as(i64, t) - @as(i64, site + 5) else 0;
    store32(r, site + 1, @bitCast(@as(i32, @intCast(rel))));
}

// ---------------------------------------------------------------- the cache

pub const Key = struct { pc: u64, page: u64 };

pub const Error = error{ Full, OutOfMemory };

pub const Cache = struct {
    gpa: std.mem.Allocator,
    region: codemem.Region,
    patcher: Patcher,
    /// Guards everything below, and patching.
    lock: std.atomic.Mutex = .unlocked,
    map: std.AutoHashMapUnmanaged(Key, *Tb) = .empty,
    /// Arena page to the translations reading it.
    pages: std.AutoHashMapUnmanaged(u64, std.ArrayList(*Tb)) = .empty,
    /// Every translation since the last reset, valid or not, in region
    /// order, for finding a site's translation.
    order: std.ArrayList(*Tb) = .empty,
    /// Tbs, `pages`' lists, and `ins`, freed at reset.
    tbs: std.heap.ArenaAllocator,
    jumps: std.ArrayList(*JumpCache) = .empty,
    /// Counts, for tests and stats.
    flushes: u64 = 0,
    invalidated: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, size: usize) (codemem.Error)!Cache {
        const p = Patcher.host orelse return error.JitUnavailable;
        return .{ .gpa = gpa, .region = try .init(size), .patcher = p, .tbs = .init(gpa) };
    }

    pub fn deinit(c: *Cache) void {
        c.map.deinit(c.gpa);
        c.pages.deinit(c.gpa);
        c.order.deinit(c.gpa);
        c.jumps.deinit(c.gpa);
        c.tbs.deinit();
        c.region.deinit();
    }

    fn lockSpin(c: *Cache) void {
        while (!c.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn addJumpCache(c: *Cache, j: *JumpCache) !void {
        c.lockSpin();
        defer c.lock.unlock();
        try c.jumps.append(c.gpa, j);
    }

    pub fn removeJumpCache(c: *Cache, j: *JumpCache) void {
        c.lockSpin();
        defer c.lock.unlock();
        for (c.jumps.items, 0..) |x, i| if (x == j) {
            _ = c.jumps.swapRemove(i);
            return;
        };
    }

    /// What `insert` takes besides the code.
    pub const New = struct {
        pc: u64,
        page: u64,
        va2: u64 = no_page,
        page2: u64 = no_page,
        /// Offsets from the start of `code`.
        entry: u32 = 0,
        chain_entry: u32 = 0,
        chains: []const Chain = &.{},
    };

    /// Copies a translation into the region and makes it findable. Fails
    /// with `Full` when the region is: flush and try again. If `code` (a
    /// mem.CodePages) says a page it was translated from has lost its code
    /// since, the translation is stale; it's still returned, to run once,
    /// but nothing can find it.
    pub fn insert(c: *Cache, code: []const u8, n: New, pages: ?*const mem.CodePages) Error!*Tb {
        std.debug.assert(n.chains.len <= max_chains);
        c.lockSpin();
        defer c.lock.unlock();
        const off = c.region.alloc(code.len, 16) orelse return error.Full;
        c.region.write(off, code);
        const tb = try c.tbs.allocator().create(Tb);
        tb.* = .{
            .pc = n.pc,
            .page = n.page,
            .va2 = n.va2,
            .page2 = n.page2,
            .off = off,
            .len = @intCast(code.len),
            .chain_entry = off + n.chain_entry,
            .chain_addr = @intFromPtr(c.region.entry(off + n.chain_entry)),
            .entry = c.region.entry(off + n.entry),
            .nouts = @intCast(n.chains.len),
        };
        for (n.chains, 0..) |ch, i| tb.outs[i] = .{ .site = off + ch.site, .pc = ch.pc };
        try c.order.append(c.gpa, tb);
        const stale = if (pages) |p| !p.isCode(n.page) or (n.page2 != no_page and !p.isCode(n.page2)) else false;
        if (stale) {
            tb.valid.store(false, .release);
            return tb;
        }
        try c.addToPage(n.page, tb);
        if (n.page2 != no_page and n.page2 != n.page) try c.addToPage(n.page2, tb);
        // A newer translation of the same key replaces the old one, which
        // can only happen when two vCPUs compile it at once.
        if (c.map.get(.{ .pc = n.pc, .page = n.page })) |old| c.dropLocked(old);
        try c.map.put(c.gpa, .{ .pc = n.pc, .page = n.page }, tb);
        return tb;
    }

    fn addToPage(c: *Cache, page: u64, tb: *Tb) !void {
        const gop = try c.pages.getOrPut(c.gpa, page);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(c.tbs.allocator(), tb);
    }

    /// The translation for `pc` on arena page `page`, through `j` first.
    /// `page2Of` gives the arena page now at a guest page's address (null
    /// if it isn't executable), for checking a two-page translation's
    /// second page.
    pub fn lookup(c: *Cache, j: *JumpCache, pc: u64, page: u64, view: ?*const mem.View) ?*Tb {
        if (j.get(pc)) |tb| {
            if (tb.page == page and tb.isValid() and secondOk(tb, view)) return tb;
        }
        c.lockSpin();
        const tb = c.map.get(.{ .pc = pc, .page = page });
        c.lock.unlock();
        const t = tb orelse return null;
        if (!secondOk(t, view)) return null;
        j.put(t);
        return t;
    }

    fn secondOk(tb: *const Tb, view: ?*const mem.View) bool {
        if (tb.va2 == no_page) return true;
        const v = view orelse return false;
        const host = v.translate(tb.va2, 1, .exec) orelse return false;
        const c = v.code orelse return false;
        return c.pageOf(@intFromPtr(host.ptr)) == tb.page2;
    }

    /// The translation whose code holds executable address `addr` (a
    /// chain site from ctx.exit_info), if it's still valid.
    pub fn tbAt(c: *Cache, addr: u64) ?*Tb {
        const base = @intFromPtr(c.region.exec(0));
        if (addr < base or addr - base >= c.region.len) return null;
        const off: u32 = @intCast(addr - base);
        c.lockSpin();
        defer c.lock.unlock();
        const items = c.order.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const t = items[mid];
            if (off < t.off) hi = mid else if (off - t.off >= t.len) lo = mid + 1 else return if (t.isValid()) t else null;
        }
        return null;
    }

    /// After `from` left by its chain site at executable address `site`
    /// for `to`, makes the site jump to `to` directly, if that's safe.
    /// Returns whether it linked.
    pub fn link(c: *Cache, from: *Tb, site: u64, to: *Tb) bool {
        const off: u32 = @intCast(site - @intFromPtr(c.region.exec(0)));
        if (!from.samePages(to.pc)) return false;
        c.lockSpin();
        defer c.lock.unlock();
        // Either may have been dropped since the caller looked.
        if (!from.isValid() or !to.isValid()) return false;
        for (from.outs[0..from.nouts], 0..) |*o, i| {
            if (o.site != off) continue;
            if (o.pc != to.pc or o.to != null) return false;
            to.ins.append(c.tbs.allocator(), .{ .from = from, .slot = @intCast(i) }) catch return false;
            o.to = to;
            c.patcher.patch(&c.region, o.site, to.chain_entry);
            return true;
        }
        return false;
    }

    /// Drops every translation read from arena page `page`.
    pub fn invalidatePage(c: *Cache, page: u64) void {
        c.lockSpin();
        defer c.lock.unlock();
        const list = c.pages.fetchRemove(page) orelse return;
        for (list.value.items) |tb| if (tb.isValid()) c.dropLocked(tb);
    }

    fn dropLocked(c: *Cache, tb: *Tb) void {
        tb.valid.store(false, .release);
        c.invalidated += 1;
        if (c.map.get(.{ .pc = tb.pc, .page = tb.page })) |t| if (t == tb) {
            _ = c.map.remove(.{ .pc = tb.pc, .page = tb.page });
        };
        // Out of the other page's list, if it has one.
        for ([_]u64{ tb.page, tb.page2 }) |p| {
            if (p == no_page) continue;
            if (c.pages.getPtr(p)) |l| {
                for (l.items, 0..) |x, i| if (x == tb) {
                    _ = l.swapRemove(i);
                    break;
                };
            }
        }
        // Jumps into it go back to their exits.
        for (tb.ins.items) |in| {
            const o = &in.from.outs[in.slot];
            if (o.to != tb) continue;
            o.to = null;
            c.patcher.patch(&c.region, o.site, null);
        }
        tb.ins.clearRetainingCapacity();
        // Its own links go from the targets' lists. Its sites stay patched,
        // which is harmless: nothing enters it anymore except a vCPU
        // already inside, which carries on as it would have.
        for (tb.outs[0..tb.nouts]) |*o| {
            const to = o.to orelse continue;
            for (to.ins.items, 0..) |in, i| if (in.from == tb) {
                _ = to.ins.swapRemove(i);
                break;
            };
        }
        for (c.jumps.items) |j| j.drop(tb);
    }

    /// Empties the cache. Only with every vCPU out of compiled code and
    /// kept out until this returns.
    pub fn reset(c: *Cache) void {
        c.lockSpin();
        defer c.lock.unlock();
        c.map.clearRetainingCapacity();
        c.pages.clearRetainingCapacity();
        c.order.clearRetainingCapacity();
        _ = c.tbs.reset(.retain_capacity);
        c.region.reset();
        for (c.jumps.items) |j| j.clear();
        c.flushes += 1;
    }
};

// ---------------------------------------------------------------- runtime

/// Ctx.exit_request bits, set by other threads (and by a vCPU's own slow
/// path or dispatcher).
pub const req_kick: u32 = 1;
pub const req_sync: u32 = 2;

/// A vCPU's JIT state around its Ctx, which the vmm layer (vmm/zemu.zig)
/// embeds and a Guest's run loop finds from the Ctx it's given.
pub const Runtime = struct {
    ctx: Ctx = .{},
    jump: JumpCache = .{},
    /// The backend's cache, or null when this host or build runs T0 only.
    cache: ?*Cache = null,
    /// Set by `requestFlush`; the vmm layer flushes when it sees it.
    flush_wanted: ?*std.atomic.Value(bool) = null,

    /// Points ctx.jump at the jump cache. Call it once the Runtime is in
    /// its final place.
    pub fn bind(rt: *Runtime) void {
        rt.ctx.jump = @intFromPtr(&rt.jump);
    }

    pub fn of(ctx: *Ctx) *Runtime {
        return @fieldParentPtr("ctx", ctx);
    }

    pub fn view(rt: *Runtime) *mem.View {
        return @ptrFromInt(@as(usize, @intCast(rt.ctx.space)));
    }

    /// The cache is full: asks for a flush, and for this vCPU to leave
    /// guest code so it can happen. The caller returns `.interrupted`.
    pub fn requestFlush(rt: *Runtime) void {
        if (rt.flush_wanted) |f| f.store(true, .seq_cst);
        _ = @atomicRmw(u32, &rt.ctx.exit_request, .Or, req_sync, .seq_cst);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Hand-written x86-64 translations that follow the emitter contract, so
/// the cache's chaining runs for real on x86-64 hosts.
const x64 = struct {
    const off_retired = @offsetOf(Ctx, "retired");
    const off_exit_pc = @offsetOf(Ctx, "exit_pc");
    const off_exit_info = @offsetOf(Ctx, "exit_info");
    const off_exit_request = @offsetOf(Ctx, "exit_request");

    /// A region that counts itself in ctx.retired, then either chains to
    /// `next` or leaves with `exit`. Returns the code, its chain entry, and
    /// its chain site.
    const Built = struct { code: std.ArrayList(u8), chain_entry: u32, site: ?u32 };

    fn build(gpa: std.mem.Allocator, next: ?u64, exit: ctx_mod.Exit, exit_pc: u64) !Built {
        var b: std.ArrayList(u8) = .empty;
        errdefer b.deinit(gpa);
        try b.appendSlice(gpa, &.{ 0x53, 0x48, 0x89, 0xfb }); // push rbx; mov rbx, rdi
        const chain_entry: u32 = @intCast(b.items.len);
        try b.appendSlice(gpa, &.{ 0x48, 0x83, 0x43, off_retired, 0x01 }); // add qword [rbx+retired], 1
        // A kick leaves here, as `poll` would.
        try b.appendSlice(gpa, &.{ 0x83, 0x7b, off_exit_request, 0x00 }); // cmp dword [rbx+exit_request], 0
        try b.appendSlice(gpa, &.{ 0x74, 0x15 }); // je +21 (over the interrupted exit)
        try movExitPc(gpa, &b, exit_pc); // 14 bytes
        try b.appendSlice(gpa, &.{ 0xb8, 7, 0, 0, 0, 0x5b, 0xc3 }); // mov eax, interrupted; pop rbx; ret
        var site: ?u32 = null;
        if (next) |pc| {
            while ((b.items.len + 1) % 4 != 0) try b.append(gpa, 0x90);
            site = @intCast(b.items.len);
            try b.appendSlice(gpa, &.{ 0xe9, 0, 0, 0, 0 }); // jmp .+5: the site
            // lea rax, [rip - (here + 7 - site)]; mov [rbx+exit_info], rax
            const disp: i32 = -@as(i32, @intCast(b.items.len + 7 - site.?));
            try b.appendSlice(gpa, &.{ 0x48, 0x8d, 0x05 });
            try b.appendSlice(gpa, std.mem.asBytes(&disp));
            try b.appendSlice(gpa, &.{ 0x48, 0x89, 0x43, off_exit_info });
            try movExitPc(gpa, &b, pc);
            try b.appendSlice(gpa, &.{ 0xb8, @intFromEnum(ctx_mod.Exit.chain), 0, 0, 0, 0x5b, 0xc3 });
        } else {
            try movExitPc(gpa, &b, exit_pc);
            try b.appendSlice(gpa, &.{ 0xb8, @intCast(@intFromEnum(exit)), 0, 0, 0, 0x5b, 0xc3 });
        }
        return .{ .code = b, .chain_entry = chain_entry, .site = site };
    }

    fn movExitPc(gpa: std.mem.Allocator, b: *std.ArrayList(u8), pc: u64) !void {
        try b.appendSlice(gpa, &.{ 0x48, 0xb8 }); // mov rax, imm64
        try b.appendSlice(gpa, std.mem.asBytes(&pc));
        try b.appendSlice(gpa, &.{ 0x48, 0x89, 0x43, off_exit_pc }); // mov [rbx+exit_pc], rax
    }

    fn insert(c: *Cache, pc: u64, page: u64, next: ?u64, exit: ctx_mod.Exit) !*Tb {
        var bl = try build(testing.allocator, next, exit, pc);
        defer bl.code.deinit(testing.allocator);
        var chains: [1]Chain = undefined;
        if (bl.site) |s| chains[0] = .{ .site = s, .pc = next.? };
        return c.insert(bl.code.items, .{
            .pc = pc,
            .page = page,
            .chain_entry = bl.chain_entry,
            .chains = chains[0..@intFromBool(bl.site != null)],
        }, null);
    }
};

/// The dispatcher's loop in miniature: run from `pc` until something
/// other than a chain, linking chains as it goes. Returns the exit and how
/// many times it entered compiled code.
fn dispatch(c: *Cache, j: *JumpCache, cx: *Ctx, pc0: u64, page: u64) struct { exit: ctx_mod.Exit, entries: u32 } {
    var pc = pc0;
    var from: ?struct { tb: *Tb, site: u64 } = null;
    var entries: u32 = 0;
    while (true) {
        const tb = c.lookup(j, pc, page, null) orelse return .{ .exit = .undef, .entries = entries };
        if (from) |f| _ = c.link(f.tb, f.site, tb);
        entries += 1;
        const e: ctx_mod.Exit = @enumFromInt(tb.entry(cx));
        if (e != .chain) return .{ .exit = e, .entries = entries };
        pc = cx.exit_pc;
        from = if (c.tbAt(cx.exit_info)) |t| .{ .tb = t, .site = cx.exit_info } else null;
    }
}

fn testCache() !Cache {
    if (builtin.cpu.arch != .x86_64 or !codemem.available()) return error.SkipZigTest;
    return Cache.init(testing.allocator, codemem.granule);
}

test "chaining: linked once, then straight through; invalidation unlinks" {
    var c = try testCache();
    defer c.deinit();
    var j: JumpCache = .{};
    try c.addJumpCache(&j);
    // Three translations on one page: 0x1000 -> 0x1040 -> 0x1080, which
    // leaves with svc.
    _ = try x64.insert(&c, 0x1000, 7, 0x1040, .chain);
    const b = try x64.insert(&c, 0x1040, 7, 0x1080, .chain);
    _ = try x64.insert(&c, 0x1080, 7, null, .svc);
    var cx: Ctx = .{};
    const r1 = dispatch(&c, &j, &cx, 0x1000, 7);
    try testing.expectEqual(ctx_mod.Exit.svc, r1.exit);
    try testing.expectEqual(@as(u32, 3), r1.entries);
    try testing.expectEqual(@as(u64, 3), cx.retired);
    try testing.expectEqual(@as(u64, 0x1080), cx.exit_pc);
    // Now one entry runs all three.
    const r2 = dispatch(&c, &j, &cx, 0x1000, 7);
    try testing.expectEqual(ctx_mod.Exit.svc, r2.exit);
    try testing.expectEqual(@as(u32, 1), r2.entries);
    try testing.expectEqual(@as(u64, 6), cx.retired);
    // A different arena page is a different key.
    try testing.expect(c.lookup(&j, 0x1000, 8, null) == null);
    // Dropping the page drops all three, and unpatches A's jump into B.
    c.invalidatePage(7);
    try testing.expect(!b.isValid());
    try testing.expect(c.lookup(&j, 0x1000, 7, null) == null);
    try testing.expect(c.lookup(&j, 0x1040, 7, null) == null);
    try testing.expectEqual(@as(u64, 3), c.invalidated);
    // Translated again, they start unlinked.
    _ = try x64.insert(&c, 0x1000, 7, 0x1040, .chain);
    _ = try x64.insert(&c, 0x1040, 7, 0x1080, .chain);
    _ = try x64.insert(&c, 0x1080, 7, null, .svc);
    try testing.expectEqual(@as(u32, 3), dispatch(&c, &j, &cx, 0x1000, 7).entries);
}

test "invalidating the target alone resets the jump into it" {
    var c = try testCache();
    defer c.deinit();
    var j: JumpCache = .{};
    try c.addJumpCache(&j);
    // A on page 1 chains to B, which straddles into page 2 (its va2).
    _ = try x64.insert(&c, 0x1ff0, 1, 0x1ff8, .chain);
    var bl = try x64.build(testing.allocator, null, .brk, 0x1ff8);
    defer bl.code.deinit(testing.allocator);
    _ = try c.insert(bl.code.items, .{ .pc = 0x1ff8, .page = 1, .va2 = 0x2000, .page2 = 2, .chain_entry = bl.chain_entry }, null);
    // With no view to check B's second page against, B isn't found.
    var cx: Ctx = .{};
    try testing.expectEqual(ctx_mod.Exit.undef, dispatch(&c, &j, &cx, 0x1ff0, 1).exit);
    // Dropping page 2 drops B and leaves A.
    c.invalidatePage(2);
    try testing.expect(c.lookup(&j, 0x1ff0, 1, null) != null);
    _ = try x64.insert(&c, 0x1ff8, 1, null, .brk);
    try testing.expectEqual(@as(u32, 2), dispatch(&c, &j, &cx, 0x1ff0, 1).entries);
    try testing.expectEqual(@as(u32, 1), dispatch(&c, &j, &cx, 0x1ff0, 1).entries);
    // A newer translation of B's key replaces it, and A's jump into the
    // old one goes back to its exit.
    _ = try x64.insert(&c, 0x1ff8, 1, null, .svc);
    const r = dispatch(&c, &j, &cx, 0x1ff0, 1);
    try testing.expectEqual(ctx_mod.Exit.svc, r.exit);
    try testing.expectEqual(@as(u32, 2), r.entries);
}

test "jump cache: hits, and dropped translations leave every vCPU's" {
    var c = try testCache();
    defer c.deinit();
    var j1: JumpCache = .{};
    var j2: JumpCache = .{};
    try c.addJumpCache(&j1);
    try c.addJumpCache(&j2);
    const t = try x64.insert(&c, 0x4000, 3, null, .svc);
    try testing.expectEqual(t, c.lookup(&j1, 0x4000, 3, null).?);
    try testing.expectEqual(t, c.lookup(&j2, 0x4000, 3, null).?);
    try testing.expectEqual(t, j1.get(0x4000).?);
    c.invalidatePage(3);
    try testing.expect(j1.get(0x4000) == null);
    try testing.expect(j2.get(0x4000) == null);
    c.removeJumpCache(&j2);
}

test "full: insert fails until reset, which empties everything" {
    var c = try testCache();
    defer c.deinit();
    var j: JumpCache = .{};
    try c.addJumpCache(&j);
    var n: u64 = 0;
    while (true) : (n += 1) {
        _ = x64.insert(&c, 0x10000 + n * 64, n % 5, null, .svc) catch |e| switch (e) {
            error.Full => break,
            else => return e,
        };
    }
    try testing.expect(n > 100);
    _ = c.lookup(&j, 0x10000, 0, null).?;
    c.reset();
    try testing.expect(c.lookup(&j, 0x10000, 0, null) == null);
    try testing.expectEqual(@as(?*Tb, null), j.get(0x10000));
    try testing.expectEqual(@as(u64, 1), c.flushes);
    _ = try x64.insert(&c, 0x10000, 0, null, .svc);
}

test "vCPUs run chained code while another thread invalidates and retranslates" {
    if (builtin.cpu.arch != .x86_64 or !codemem.available()) return error.SkipZigTest;
    // Room for every retranslation below: dropped code stays until a flush,
    // which needs the runners stopped.
    var c = try Cache.init(testing.allocator, 1 << 20);
    defer c.deinit();
    const n = 4;
    // A ring of 8 translations on page 9, each chaining to the next; the
    // last leaves with svc. Each runner dispatches round after round while
    // the main thread drops and retranslates the page.
    const pcs = [_]u64{ 0x9000, 0x9040, 0x9080, 0x90c0, 0x9100, 0x9140, 0x9180, 0x91c0 };
    const Ring = struct {
        fn fill(cc: *Cache) !void {
            for (pcs, 0..) |pc, i| {
                const next: ?u64 = if (i + 1 < pcs.len) pcs[i + 1] else null;
                _ = try x64.insert(cc, pc, 9, next, .svc);
            }
        }
    };
    try Ring.fill(&c);
    const Runner = struct {
        c: *Cache,
        j: JumpCache = .{},
        cx: Ctx = .{},
        rounds: u64 = 0,
        bad: u64 = 0,
        stop: std.atomic.Value(bool) = .init(false),
        fn main(r: *@This()) void {
            while (!r.stop.load(.acquire)) {
                const before = r.cx.retired;
                const res = dispatch(r.c, &r.j, &r.cx, pcs[0], 9);
                // Mid-retranslation a lookup can miss; that's an undef.
                if (res.exit == .svc) {
                    if (r.cx.retired - before != pcs.len or r.cx.exit_pc != pcs[pcs.len - 1]) r.bad += 1;
                    @atomicStore(u64, &r.rounds, r.rounds + 1, .release);
                }
            }
        }
    };
    var runners: [n]Runner = undefined;
    var threads: [n]std.Thread = undefined;
    for (&runners) |*r| {
        r.* = .{ .c = &c };
        try c.addJumpCache(&r.j);
    }
    for (&threads, &runners) |*t, *r| t.* = try std.Thread.spawn(.{}, Runner.main, .{r});
    for (0..300) |_| {
        c.invalidatePage(9);
        try Ring.fill(&c);
    }
    // With the ring whole again, every runner gets through a round, however
    // the threads were scheduled while it was being dropped.
    for (&runners) |*r| while (@atomicLoad(u64, &r.rounds, .acquire) == 0) std.atomic.spinLoopHint();
    for (&runners) |*r| r.stop.store(true, .release);
    for (threads) |t| t.join();
    for (runners) |r| {
        try testing.expectEqual(@as(u64, 0), r.bad);
        try testing.expect(r.rounds > 0);
    }
    try testing.expectEqual(@as(u64, 300 * pcs.len), c.invalidated);
}
