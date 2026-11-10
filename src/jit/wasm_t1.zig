//! T1 on the web host: dispatch.zig's job for wasm, where compiling is
//! asynchronous and costs a module per batch, so regions are compiled only
//! once they're hot, many at a time.
//!
//! - **Hot entries.** The dispatcher counts entries to each block it sees
//!   (keyed by PC and arena page, as cache.zig's translations). T0 runs
//!   cold code, stopping after `cold_branches` taken branches, so a
//!   block's head comes back here to be counted (`.cold`): a sample of
//!   them, since a stint's later blocks aren't. At `hot` entries the
//!   block is lifted, and its IR waits in a queue.
//! - **Batches.** A full queue, or one that has waited `patience`
//!   dispatcher visits, becomes one module (emit/wasm.zig, a function per
//!   region) with chain cells, and h9-web.js's `jit_compile` compiles it
//!   off the thread and installs its regions in table slots this file
//!   hands out. Guest code keeps running in T0 meanwhile; a batch's status
//!   word says when its slots are live.
//! - **Chain cells.** Each batch has a u32 cell per distinct chain target.
//!   A cell holds the target's slot once the target is live and lies on a
//!   guest page its source came from (as cache.zig links only within those
//!   pages), and 0 otherwise, which leaves to this dispatcher with
//!   `.chain`. Cells are relinked whenever a batch installs or a region goes.
//! - **Invalidation.** `invalidatePage` (from zemu's CodePages callback)
//!   drops every region from an arena page: its slot is nulled, cells
//!   pointing at it are cleared, and a region still queued or compiling is
//!   dropped when its batch settles. Compiled code can't store to code (the
//!   View's `code_stores = .exit`), so no region is running then.
//! - **Flushing.** Past `max_slots` slots or `max_entries` blocks, every
//!   region and count goes at the next dispatcher entry.
//!
//! The imports and exports h9.wasm has for it (h9-web.js's wasmJit):
//!
//! - imports h9.jit_compile(ptr, len, base, n, status) and
//!   h9.jit_drop(base, n);
//! - exports jit_eval, jit_slow_load, jit_slow_store, jit_slow_cas,
//!   jit_interp, jit_helper, and jit_ext, which the modules import, and
//!   jit_table_base(n), which the host calls once with the table's size
//!   before h9 starts: slots from there on are the JIT's.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const ir_eval = @import("ir_eval.zig");
const ctx_mod = @import("ctx.zig");
const fe = @import("frontend.zig");
const opt = @import("opt.zig");
const wasm = @import("emit/wasm.zig");
const mem = @import("../interp/mem.zig");

const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;

const on_wasm = builtin.cpu.arch == .wasm32;

pub const Config = struct {
    frontend: fe.Frontend,
    limits: fe.Limits = .{},
    /// As dispatch.Config's.
    pc_off: usize,
    pc_bytes: u8 = 8,
    pc_align: u8 = 4,
    optimize: bool = true,
};

/// What the Guest does next:
///
/// - `.svc`: a system call; the PC is past it.
/// - `.interrupted`: an exit request or a spent budget.
/// - `.t0`: run the instruction at the PC in T0 (an exception, a store to
///   code, something that can't be compiled), then call `run` again.
/// - `.cold`: run T0 from the PC through `cold_branches` taken branches,
///   then call `run` again.
pub const Result = enum { svc, interrupted, t0, cold };

pub const Stats = struct {
    /// Blocks lifted, modules built, and modules installed or failed.
    lifted: u64 = 0,
    batches: u64 = 0,
    installed: u64 = 0,
    failed: u64 = 0,
    /// Entries into compiled code, and cold blocks handed to T0.
    entries: u64 = 0,
    /// How compiled code left: an unlinked chain, an indirect branch.
    chains: u64 = 0,
    indirect: u64 = 0,
    cold: u64 = 0,
    t0: u64 = 0,
    flushes: u64 = 0,
};

/// Entries before a block is compiled.
pub var hot: u32 = 50;
/// Dispatcher visits, across all vCPUs, before anything is compiled: a
/// short-lived program (rc starting up, echo) never pays for a compile.
pub var warmup: u64 = 0;
/// Regions per module, at most.
pub var batch_max: u32 = 64;
/// Dispatcher visits a queued region waits for others before its batch
/// is built anyway.
pub var patience: u32 = 2000;
/// Taken branches T0 runs on a `.cold` return before it comes back: each
/// round trip costs a lookup, so cold code runs a few blocks per visit
/// and only a stint's first block is counted.
pub var cold_branches: u32 = 8;
const max_slots = 1 << 16;
const max_entries = 1 << 17;
const recent_n = 4096;

fn recentSlot(pc: u64) *?*Entry {
    return &st.recent[@intCast((pc ^ (pc >> 12)) & (recent_n - 1))];
}

fn lookup(key: Key) ?*Entry {
    const r = recentSlot(key.pc);
    if (r.*) |e| if (e.key.pc == key.pc and e.key.page == key.page) return e;
    const e = st.map.get(key) orelse return null;
    r.* = e;
    return e;
}

pub var stats: Stats = .{};

const no_page = std.math.maxInt(u64);
const Key = struct { pc: u64, page: u64 };

const Entry = struct {
    key: Key,
    va2: u64 = no_page,
    page2: u64 = no_page,
    hits: u32 = 0,
    state: enum { cold, queued, pending, live, failed } = .cold,
    /// Gone from the map (invalidated or flushed); freed with its batch.
    dead: bool = false,
    /// While queued.
    region: ?*ir.Region = null,
    /// While pending or live.
    batch: ?*Batch = null,
    slot: u32 = 0,

    /// The arena page `pc` is on, if it's on a guest page this entry's
    /// code came from.
    fn pageFor(e: *const Entry, pc: u64) ?u64 {
        const p = pc >> mem.page_shift;
        if (p == e.key.pc >> mem.page_shift) return e.key.page;
        if (e.va2 != no_page and p == e.va2 >> mem.page_shift) return e.page2;
        return null;
    }
};

const Batch = struct {
    base: u32,
    entries: []*Entry,
    /// Chain cell k's target PC, and the key it links to (null: never).
    cells: []u32,
    targets: []?Key,
    /// h9-web.js writes 1 (installed) or -1 (failed or dropped).
    status: i32 = 0,
    /// Regions not yet dead; at 0 the batch's slots go.
    live: u32,
    /// Dropped whole (a flush) while compiling: freed once it settles.
    dropped: bool = false,
};

const State = struct {
    gpa: std.mem.Allocator = undefined,
    /// The first slot the JIT may use; 0 before the host says (no T1).
    table_base: u32 = 0,
    /// Free slot ranges, and the next never-used slot.
    free: std.ArrayList(Range) = .empty,
    next_slot: u32 = 0,
    used_slots: u32 = 0,
    map: std.AutoHashMapUnmanaged(Key, *Entry) = .empty,
    /// The map's recent hits, direct-mapped by PC, in front of it.
    recent: [recent_n]?*Entry = @splat(null),
    /// Entries by arena page (both of an entry's pages).
    pages: std.AutoHashMapUnmanaged(u64, std.ArrayList(*Entry)) = .empty,
    queue: std.ArrayList(*Entry) = .empty,
    queued_at: u64 = 0,
    visits: u64 = 0,
    pending: std.ArrayList(*Batch) = .empty,
    batches: std.ArrayList(*Batch) = .empty,
    flush_wanted: bool = false,
    /// Bumped whenever a live region goes; a vCPU's jump cache, whose
    /// entries hold slots, is cleared when it last saw an older one.
    jump_gen: u32 = 0,
    jump_seen: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    /// The jump cache the last run used, and the generation it had then.
    last_jump: usize = 0,
    last_gen: u32 = 0,
    /// H9_JIT_HOT and H9_JIT_PATIENCE read.
    tuned: bool = false,

    const Range = struct { base: u32, n: u32 };
};

var st: State = .{};

/// Whether T1 can run here: on wasm32, once the host gave the table.
pub fn available() bool {
    return on_wasm and st.table_base != 0;
}

/// Forgets every region (a backend's arena pages are its own). With
/// H9_JIT_STATS set, prints the counts first.
pub fn reset() void {
    st.flush_wanted = true;
    if (on_wasm and std.c.getenv("H9_JIT_STATS") != null)
        std.debug.print("wasm T1: {d} lifted, {d} batches ({d} installed, {d} failed), {d} entries ({d} unlinked chains, {d} indirect), {d} cold, {d} to T0, {d} flushes\n", .{ stats.lifted, stats.batches, stats.installed, stats.failed, stats.entries, stats.chains, stats.indirect, stats.cold, stats.t0, stats.flushes });
}

/// Drops every region compiled from arena page `page`.
pub fn invalidatePage(page: u64) void {
    if (!available()) return;
    const kv = st.pages.fetchRemove(page) orelse return;
    var list = kv.value;
    defer list.deinit(st.gpa);
    var any = false;
    for (list.items) |e| {
        if (e.dead) continue;
        kill(e);
        any = true;
    }
    if (any) relink();
}

/// Takes `e` out of the map and its other page's list, and its slot out
/// of service.
fn kill(e: *Entry) void {
    e.dead = true;
    _ = st.map.remove(e.key);
    if (recentSlot(e.key.pc).* == e) recentSlot(e.key.pc).* = null;
    for ([_]u64{ e.key.page, e.page2 }) |p| {
        if (p == no_page) continue;
        if (st.pages.getPtr(p)) |l| {
            for (l.items, 0..) |x, i| if (x == e) {
                _ = l.swapRemove(i);
                break;
            };
        }
    }
    switch (e.state) {
        .cold, .failed => st.gpa.destroy(e),
        .queued => {
            for (st.queue.items, 0..) |x, i| if (x == e) {
                _ = st.queue.orderedRemove(i);
                break;
            };
            freeRegion(e.region.?);
            st.gpa.destroy(e);
        },
        // Freed with the batch.
        .pending => {},
        .live => {
            const b = e.batch.?;
            st.jump_gen +%= 1;
            if (on_wasm) host.jit_drop(e.slot, 1);
            b.live -= 1;
            if (b.live == 0) freeBatch(b);
        },
    }
}

fn freeRegion(r: *ir.Region) void {
    r.deinit(st.gpa);
    st.gpa.destroy(r);
}

/// A batch with no live regions: its slots go back, and it goes.
fn freeBatch(b: *Batch) void {
    for (st.batches.items, 0..) |x, i| if (x == b) {
        _ = st.batches.swapRemove(i);
        break;
    };
    for (b.entries) |e| {
        std.debug.assert(e.dead);
        st.gpa.destroy(e);
    }
    freeSlots(b.base, @intCast(b.entries.len));
    st.gpa.free(b.entries);
    st.gpa.free(b.cells);
    st.gpa.free(b.targets);
    st.gpa.destroy(b);
}

fn allocSlots(n: u32) ?u32 {
    for (st.free.items, 0..) |*r, i| if (r.n >= n) {
        const base = r.base;
        r.base += n;
        r.n -= n;
        if (r.n == 0) _ = st.free.orderedRemove(i);
        st.used_slots += n;
        return base;
    };
    if (st.next_slot - st.table_base + n > max_slots) return null;
    const base = st.next_slot;
    st.next_slot += n;
    st.used_slots += n;
    return base;
}

fn freeSlots(base: u32, n: u32) void {
    st.used_slots -= n;
    st.free.append(st.gpa, .{ .base = base, .n = n }) catch {};
}

/// Everything goes: live regions' slots, counts, the queue. Batches still
/// compiling stay until they settle, then go.
fn flush() void {
    st.flush_wanted = false;
    stats.flushes += 1;
    for (st.queue.items) |e| {
        freeRegion(e.region.?);
        e.region = null;
        e.state = .cold;
    }
    st.queue.clearRetainingCapacity();
    var it = st.map.valueIterator();
    while (it.next()) |p| {
        const e = p.*;
        e.dead = true;
        switch (e.state) {
            .cold, .failed, .queued => st.gpa.destroy(e),
            .pending, .live => {},
        }
    }
    st.map.clearRetainingCapacity();
    st.recent = @splat(null);
    var pit = st.pages.valueIterator();
    while (pit.next()) |l| l.deinit(st.gpa);
    st.pages.clearRetainingCapacity();
    for (st.pending.items) |b| b.dropped = true;
    st.jump_gen +%= 1;
    while (st.batches.items.len > 0) {
        const b = st.batches.items[st.batches.items.len - 1];
        if (on_wasm) host.jit_drop(b.base, @intCast(b.entries.len));
        freeBatch(b);
    }
}

/// Batches whose compiles have settled: their regions go live, or fail.
fn settle(s: *Stats) void {
    var i: usize = 0;
    var changed = false;
    while (i < st.pending.items.len) {
        const b = st.pending.items[i];
        const status = @atomicLoad(i32, &b.status, .acquire);
        if (status == 0) {
            i += 1;
            continue;
        }
        _ = st.pending.swapRemove(i);
        if (b.dropped) {
            // A flush took it: nothing's in the map. The slots may have
            // been installed; null them.
            if (status == 1 and on_wasm) host.jit_drop(b.base, @intCast(b.entries.len));
            for (b.entries) |e| st.gpa.destroy(e);
            freeSlots(b.base, @intCast(b.entries.len));
            st.gpa.free(b.entries);
            st.gpa.free(b.cells);
            st.gpa.free(b.targets);
            st.gpa.destroy(b);
            continue;
        }
        if (status == 1) s.installed += 1 else s.failed += 1;
        var live: u32 = 0;
        for (b.entries, 0..) |e, k| {
            if (e.dead) {
                if (status == 1 and on_wasm) host.jit_drop(b.base + @as(u32, @intCast(k)), 1);
                continue;
            }
            e.state = if (status == 1) .live else .failed;
            if (status == 1) live += 1;
        }
        if (status == 1 and live > 0) {
            b.live = live;
            st.batches.append(st.gpa, b) catch {
                // Can't track it: drop its regions.
                for (b.entries) |e| if (!e.dead) {
                    e.state = .failed;
                };
                if (on_wasm) host.jit_drop(b.base, @intCast(b.entries.len));
                b.live = 0;
            };
            changed = true;
        }
        if (status != 1 or live == 0 or b.live == 0) {
            // Failed entries stay in the map, so T0 keeps them; the rest go.
            for (b.entries) |e| if (e.dead) st.gpa.destroy(e);
            freeSlots(b.base, @intCast(b.entries.len));
            st.gpa.free(b.entries);
            st.gpa.free(b.cells);
            st.gpa.free(b.targets);
            st.gpa.destroy(b);
        } else {
            for (b.entries) |e| e.batch = b;
        }
    }
    if (changed) relink();
}

/// Points every live batch's cells at their targets' slots, where those
/// are live, and clears the rest.
fn relink() void {
    for (st.batches.items) |b| {
        for (b.cells, b.targets) |*cell, t| {
            var v: u32 = 0;
            if (t) |k| if (st.map.get(k)) |e| if (e.state == .live) {
                v = e.slot;
            };
            @atomicStore(u32, cell, v, .release);
        }
    }
}

/// Runs compiled code from the Cpu's PC, as dispatch.run does.
pub fn run(gpa: std.mem.Allocator, cx: *Ctx, cfg: Config) Result {
    st.gpa = gpa;
    if (on_wasm and !st.tuned) {
        st.tuned = true;
        if (std.c.getenv("H9_JIT_HOT")) |v| hot = std.fmt.parseInt(u32, std.mem.span(v), 10) catch hot;
        if (std.c.getenv("H9_JIT_PATIENCE")) |v| patience = std.fmt.parseInt(u32, std.mem.span(v), 10) catch patience;
        if (std.c.getenv("H9_JIT_COLD")) |v| cold_branches = std.fmt.parseInt(u32, std.mem.span(v), 10) catch cold_branches;
        if (std.c.getenv("H9_JIT_WARMUP")) |v| warmup = std.fmt.parseInt(u64, std.mem.span(v), 10) catch warmup;
    }
    if (st.flush_wanted or st.used_slots > max_slots - batch_max or st.map.count() > max_entries) flush();
    settle(&stats);
    const jump: ?*[ctx_mod.jump_entries]ctx_mod.JumpEntry = if (cx.jump != 0) @ptrFromInt(@as(usize, @intCast(cx.jump))) else null;
    if (jump) |j| if (@intFromPtr(j) != st.last_jump or st.last_gen != st.jump_gen) {
        st.last_jump = @intFromPtr(j);
        st.last_gen = st.jump_gen;
        const gop = st.jump_seen.getOrPut(gpa, @intFromPtr(j)) catch return cold();
        if (!gop.found_existing or gop.value_ptr.* != st.jump_gen) {
            for (j) |*x| x.pc = std.math.maxInt(u64);
            gop.value_ptr.* = st.jump_gen;
        }
    };
    const view: *mem.View = @ptrFromInt(@as(usize, @intCast(cx.space)));
    const pc_addr = @as(usize, @intCast(cx.cpu)) + cfg.pc_off;
    view.code_stores = .exit;
    defer view.code_stores = .store;
    while (true) {
        if (@atomicLoad(u32, &cx.exit_request, .seq_cst) != 0 or cx.budget <= 0) return .interrupted;
        const pc = getPc(pc_addr, cfg.pc_bytes);
        const page = codePage(view, pc, cfg.pc_align) orelse {
            stats.t0 += 1;
            return .t0;
        };
        st.visits += 1;
        if (st.queue.items.len > 0 and st.visits - st.queued_at > patience) build(cfg);
        const key: Key = .{ .pc = pc, .page = page };
        const e = lookup(key) orelse blk: {
            const n = gpa.create(Entry) catch return cold();
            n.* = .{ .key = key };
            st.map.put(gpa, key, n) catch {
                gpa.destroy(n);
                return cold();
            };
            addPage(page, n) catch {};
            break :blk n;
        };
        if (e.state != .live) {
            if (e.state == .cold) {
                e.hits += 1;
                if (e.hits >= hot and st.visits >= warmup) queue(e, view, cfg);
            }
            return cold();
        }
        stats.entries += 1;
        if (jump) |j| {
            // So compiled code finds it too (emit/wasm.zig's Options.jump).
            const x = &j[ctx_mod.jumpIndex(pc)];
            x.* = .{ .pc = pc, .tb = 0, .code = e.slot };
        }
        const f: ctx_mod.EntryFn = @ptrFromInt(e.slot);
        const x: Exit = @enumFromInt(f(cx));
        setPc(pc_addr, cfg.pc_bytes, cx.exit_pc);
        switch (x) {
            .chain => stats.chains += 1,
            .indirect => stats.indirect += 1,
            .svc => return .svc,
            .interrupted => return .interrupted,
            else => {
                stats.t0 += 1;
                return .t0;
            },
        }
    }
}

fn cold() Result {
    stats.cold += 1;
    return .cold;
}

fn addPage(page: u64, e: *Entry) !void {
    const gop = try st.pages.getOrPut(st.gpa, page);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(st.gpa, e);
}

fn getPc(addr: usize, bytes: u8) u64 {
    if (bytes == 8) return @as(*const u64, @ptrFromInt(addr)).*;
    return @as(*const u32, @ptrFromInt(addr)).*;
}

fn setPc(addr: usize, bytes: u8, v: u64) void {
    if (bytes == 8) @as(*u64, @ptrFromInt(addr)).* = v else @as(*u32, @ptrFromInt(addr)).* = @truncate(v);
}

fn codePage(view: *mem.View, pc: u64, pc_align: u8) ?u64 {
    if (pc & (pc_align - 1) != 0) return null;
    const code = view.code orelse return null;
    const h = view.translate(pc, 1, .exec) orelse return null;
    return code.pageOf(@intFromPtr(h.ptr));
}

/// A Source over the view that notes a second guest page, as dispatch.zig's.
const Reader = struct {
    view: *mem.View,
    first: u64,
    second: u64 = no_page,

    fn read(p: *anyopaque, va: u64, buf: []u8) usize {
        const r: *Reader = @ptrCast(@alignCast(p));
        const n = r.view.fetch(va, buf);
        if (n > 0) {
            const last = (va + n - 1) >> mem.page_shift;
            if (last != r.first) r.second = last;
        }
        return n;
    }
};

/// Lifts a hot block and queues it; a block that can't be lifted is
/// left to T0 for good.
fn queue(e: *Entry, view: *mem.View, cfg: Config) void {
    lift(e, view, cfg) catch {
        e.state = .failed;
        return;
    };
    if (st.queue.items.len == 0) st.queued_at = st.visits;
    st.queue.append(st.gpa, e) catch {
        freeRegion(e.region.?);
        e.region = null;
        e.state = .failed;
        return;
    };
    e.state = .queued;
    stats.lifted += 1;
    if (st.queue.items.len >= batch_max) build(cfg);
}

fn lift(e: *Entry, view: *mem.View, cfg: Config) !void {
    const gpa = st.gpa;
    const r = try gpa.create(ir.Region);
    r.* = .{ .entry_pc = e.key.pc };
    errdefer freeRegion(r);
    var b = ir.Builder.init(gpa, r);
    var rd: Reader = .{ .view = view, .first = e.key.pc >> mem.page_shift };
    var limits = cfg.limits;
    limits.max_pages = @min(limits.max_pages, 2);
    try cfg.frontend.lift(&b, .{ .ctx = &rd, .read = Reader.read }, e.key.pc, limits);
    if (ir.verify(r) != null) return error.Invalid;
    if (cfg.optimize) {
        try opt.run(gpa, r);
        if (ir.verify(r) != null) return error.Invalid;
    }
    if (rd.second != no_page) {
        const va2 = rd.second << mem.page_shift;
        e.va2 = va2;
        e.page2 = codePage(view, va2, 1) orelse return error.Unsupported;
        try addPage(e.page2, e);
    }
    e.region = r;
}

/// The queue as one module, sent to the host to compile.
fn build(cfg: Config) void {
    _ = cfg;
    const gpa = st.gpa;
    const entries = gpa.dupe(*Entry, st.queue.items) catch return;
    st.queue.clearRetainingCapacity();
    buildBatch(entries) catch {
        for (entries) |e| {
            if (e.region) |r| freeRegion(r);
            e.region = null;
            e.state = .failed;
        }
        gpa.free(entries);
    };
}

fn buildBatch(entries: []*Entry) !void {
    const gpa = st.gpa;
    const n: u32 = @intCast(entries.len);
    var nchains: usize = 0;
    const regions = try gpa.alloc(*const ir.Region, n);
    defer gpa.free(regions);
    for (entries, regions) |e, *r| {
        r.* = e.region.?;
        for (e.region.?.insts.items) |i| if (i.op == .@"exit.chain") {
            nchains += 1;
        };
    }
    // The cells' address goes into the code, so they come first: one per
    // chain at most.
    const cells = try gpa.alloc(u32, @max(nchains, 1));
    errdefer gpa.free(cells);
    @memset(cells, 0);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var wb: wasm.Batch = .{};
    defer wb.deinit(gpa);
    try wasm.emitBatch(gpa, regions, .{ .cells = @intCast(@intFromPtr(cells.ptr)), .jump = true, .ext_io = @intCast(@intFromPtr(&ext_io)) }, &out, &wb);
    // Which key each cell links to: the target on a page its sources came
    // from, if every source in the batch that uses it agrees.
    const targets = try gpa.alloc(?Key, cells.len);
    errdefer gpa.free(targets);
    @memset(targets, null);
    for (wb.chains.items, 0..) |tpc, k| {
        var want: ?Key = null;
        var ok = true;
        for (entries) |e| {
            const uses = for (e.region.?.insts.items) |i| {
                if (i.op == .@"exit.chain" and i.aux == tpc) break true;
            } else false;
            if (!uses) continue;
            const p = e.pageFor(tpc) orelse {
                ok = false;
                break;
            };
            const key: Key = .{ .pc = tpc, .page = p };
            if (want) |w| {
                if (w.pc != key.pc or w.page != key.page) ok = false;
            } else want = key;
        }
        targets[k] = if (ok) want else null;
    }
    const base = allocSlots(n) orelse {
        st.flush_wanted = true;
        return error.Full;
    };
    errdefer freeSlots(base, n);
    const b = try gpa.create(Batch);
    errdefer gpa.destroy(b);
    b.* = .{ .base = base, .entries = entries, .cells = cells, .targets = targets, .live = n };
    try st.pending.append(gpa, b);
    for (entries, 0..) |e, k| {
        freeRegion(e.region.?);
        e.region = null;
        e.state = .pending;
        e.slot = base + @as(u32, @intCast(k));
        e.batch = b;
    }
    stats.batches += 1;
    if (on_wasm) host.jit_compile(out.items.ptr, @intCast(out.items.len), base, n, &b.status);
}

// ---------------------------------------------------------------- h9.wasm's side

const host = if (on_wasm) struct {
    extern "h9" fn jit_compile(ptr: [*]const u8, len: u32, base: u32, n: u32, status: *i32) void;
    extern "h9" fn jit_drop(base: u32, n: u32) void;
} else struct {};

comptime {
    if (on_wasm) {
        @export(&jit_table_base, .{ .name = "jit_table_base" });
        @export(&jit_eval, .{ .name = "jit_eval" });
        @export(&jit_slow_load, .{ .name = "jit_slow_load" });
        @export(&jit_slow_store, .{ .name = "jit_slow_store" });
        @export(&jit_slow_cas, .{ .name = "jit_slow_cas" });
        @export(&jit_interp, .{ .name = "jit_interp" });
        @export(&jit_helper, .{ .name = "jit_helper" });
        @export(&jit_ext, .{ .name = "jit_ext" });
    }
}

fn jit_table_base(n: u32) callconv(.c) void {
    // Slot 0 is the null function pointer, so never the JIT's.
    st.table_base = @max(n, 1);
    st.next_slot = st.table_base;
}

fn jit_eval(code: u64, a: u64, b: u64, c: u64, aux: u64) callconv(.c) u64 {
    return ir_eval.evalOpC(code, a, b, c, aux);
}

fn jit_slow_load(cx: *Ctx, va: u64, size_log2: u32) callconv(.c) u32 {
    const f: mem.SlowLoadFn = @ptrFromInt(@as(usize, @intCast(cx.slow_load)));
    return f(cx, va, size_log2);
}

fn jit_slow_store(cx: *Ctx, va: u64, size_log2: u32, v: u64) callconv(.c) u32 {
    const f: mem.SlowStoreFn = @ptrFromInt(@as(usize, @intCast(cx.slow_store)));
    return f(cx, va, size_log2, v);
}

fn jit_slow_cas(cx: *Ctx, va: u64, size_log2: u32, expected: u64, new: u64) callconv(.c) u32 {
    const f: mem.SlowCasFn = @ptrFromInt(@as(usize, @intCast(cx.slow_cas)));
    return f(cx, va, size_log2, expected, new);
}

fn jit_interp(cx: *Ctx, handle: u64, pc: u64) callconv(.c) u32 {
    const f: ctx_mod.InterpFn = @ptrFromInt(@as(usize, @intCast(cx.interp)));
    return f(cx, handle, pc);
}

/// Where FP and vector ops stage their operands for jit_ext.
var ext_io: [48]u8 align(16) = undefined;

fn jit_ext(cx: *Ctx, code: u64, io: [*]u8, aux: u64, aux2: u64) callconv(.c) void {
    ir_eval.evalExtC(cx, code, io, aux, aux2);
}

fn jit_helper(cx: *Ctx, index: u64, a: u64, b: u64, c: u64) callconv(.c) u64 {
    const hs: [*]const ctx_mod.HelperFn = @ptrFromInt(@as(usize, @intCast(cx.helpers)));
    return hs[@intCast(index)](cx, a, b, c);
}
