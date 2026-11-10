//! Check mode in the vmm backend (-Djit-check): instead of running T0 or
//! compiled code, a Guest's T1 loop lifts each region and runs it through
//! `check.Checker`, which runs the region and T0 from the same state on
//! shadows, panics if they differ, and commits the agreed result. So
//!
//!     zig build integration -Demu=zig -Djit-check
//!
//! runs the integration suite with every region of every guest program
//! checked against T0. Each region is optimized (opt.zig) as dispatch.zig
//! does; with the T1 tier on (H9_EMU_TIER=t1) it runs as this host's
//! generated code, the tier's own, and otherwise in ir_eval. It's slow,
//! and one region at a time: a lock is held across each.
//!
//! Other vCPUs' T0 steps and the kernel write guest memory outside that
//! lock, so a region doesn't run on live memory. Both tiers start from one
//! snapshot of each page, taken as the region first touches it (lifting
//! reads code from it too), so a store landing between the T1 run and the
//! T0 run can't make them differ. Before the agreed result is committed,
//! the snapshot is compared with live memory: if anything wrote a page the
//! region touched, the region runs again from a fresh snapshot (a race
//! doesn't repeat; a lifter bug does), and after a few tries T0 takes the
//! instruction instead. A divergence on a snapshot nothing else changed is
//! the lifter's, and panics. The commit writes only the 8-byte words the
//! region changed, each atomically, so a neighbour's stores to the same
//! page aren't lost.
//!
//! `run` stands in for dispatch.run, with its results: ha64's and h86's
//! T1 loops (src/vmm/ha64.zig, h86.zig) call it in check mode and hand
//! `.t0` to T0 as they do for compiled code. Every exception goes that
//! way: the checked region leaves the Cpu exact at the instruction, and T0
//! raises it again with its architectural detail.

const std = @import("std");
const check = @import("../check.zig");
const ir = @import("../ir.zig");
const opt = @import("../opt.zig");
const ctx_mod = @import("../ctx.zig");
const dispatch = @import("../dispatch.zig");
const mem = @import("../../interp/mem.zig");
const Native = @import("../emit/native.zig").Native;
const fe = @import("../frontend.zig");

const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;

pub const a64_guest = &check.a64.guest;
pub const x86_guest = &check.x86.guest;
pub const x64_guest = &check.x86.guest64;

/// A Backing over the vmm's View: the address space a vCPU runs in.
pub fn viewBacking(v: *mem.View) check.Backing {
    return .{ .ctx = v, .page = viewPage };
}

fn viewPage(p: *anyopaque, vp: u64) ?check.Backing.Page {
    const v: *const mem.View = @ptrCast(@alignCast(p));
    const va = vp << mem.page_shift;
    const m = v.find(va) orelse return null;
    return .{ .host = @ptrFromInt(m.host + @as(usize, @intCast(va - m.va))), .read = m.perms.read, .write = m.perms.write, .exec = m.perms.exec };
}

/// The pages a region has touched, as they were when it first touched
/// each: what both tiers' shadows copy from, and what `commit` compares
/// with live memory.
pub const Snapshot = struct {
    gpa: std.mem.Allocator,
    view: *mem.View,
    pages: std.AutoArrayHashMapUnmanaged(u64, *Page) = .empty,
    free: std.ArrayList(*Page) = .empty,
    oom: bool = false,
    /// The page `get` found last: lifting reads code a byte at a time.
    last_vp: u64 = std.math.maxInt(u64),
    last: ?*Page = null,

    const page_size = mem.page_size;

    pub const Page = struct {
        /// The shadows' backing: the snapshot, then what T1 committed.
        data: [page_size]u8 align(page_size),
        /// The snapshot as taken.
        orig: [page_size]u8 align(page_size),
        live: [*]u8,
        read: bool,
        write: bool,
        exec: bool,
    };

    fn deinit(s: *Snapshot) void {
        s.reset();
        for (s.free.items) |p| s.gpa.destroy(p);
        s.free.deinit(s.gpa);
        s.pages.deinit(s.gpa);
    }

    /// Forgets every page, for the next region.
    fn reset(s: *Snapshot) void {
        for (s.pages.values()) |p| s.free.append(s.gpa, p) catch s.gpa.destroy(p);
        s.pages.clearRetainingCapacity();
        s.oom = false;
        s.last = null;
        s.last_vp = std.math.maxInt(u64);
    }

    fn backing(s: *Snapshot) check.Backing {
        return .{ .ctx = s, .page = page };
    }

    fn page(p: *anyopaque, vp: u64) ?check.Backing.Page {
        const s: *Snapshot = @ptrCast(@alignCast(p));
        const pg = s.get(vp) orelse return null;
        return .{ .host = &pg.data, .read = pg.read, .write = pg.write, .exec = pg.exec };
    }

    fn get(s: *Snapshot, vp: u64) ?*Page {
        if (vp == s.last_vp) if (s.last) |pg| return pg;
        const pg = s.find(vp) orelse return null;
        s.last_vp = vp;
        s.last = pg;
        return pg;
    }

    fn find(s: *Snapshot, vp: u64) ?*Page {
        if (s.pages.get(vp)) |pg| return pg;
        const live = viewPage(s.view, vp) orelse return null;
        const pg = s.free.pop() orelse s.gpa.create(Page) catch {
            s.oom = true;
            return null;
        };
        pg.live = live.host;
        pg.read = live.read;
        pg.write = live.write;
        pg.exec = live.exec;
        copyLive(&pg.orig, live.host);
        pg.data = pg.orig;
        s.pages.put(s.gpa, vp, pg) catch {
            s.free.append(s.gpa, pg) catch s.gpa.destroy(pg);
            s.oom = true;
            return null;
        };
        return pg;
    }

    /// Copies a live page. Another vCPU's stores may land meanwhile, and
    /// tear what's copied: `unchanged` sees that as a race.
    fn copyLive(to: *align(page_size) [page_size]u8, from: [*]u8) void {
        @memcpy(to, from[0..page_size]);
    }

    /// Whether live memory still holds the snapshot of every page. (The
    /// compares and copies here go through memcpy and memcmp, which are
    /// optimized in any build: this module's own loops aren't in a Debug
    /// h9 on hosts whose Debug builds use Zig's own backend.)
    fn unchanged(s: *const Snapshot) bool {
        for (s.pages.values()) |pg| if (!check.samePage(&pg.orig, pg.live[0..page_size])) return false;
        return true;
    }

    /// Writes the words T1 changed (in its shadow `sh`) to live memory;
    /// invalidates the code pages among them, since committed stores
    /// bypass the slow path.
    fn commit(s: *Snapshot, sh: *const check.Shadow, code: ?*mem.CodePages) void {
        var it = sh.pages.iterator();
        while (it.next()) |e| {
            const c = e.value_ptr.*;
            if (!c.write) continue;
            const pg = s.pages.get(e.key_ptr.*) orelse continue;
            if (check.samePage(&pg.orig, &c.data)) continue;
            // A chunk at a time, through memcmp, then the words of the
            // chunks that differ.
            const chunk = 64;
            var off: usize = 0;
            while (off < page_size) : (off += chunk) {
                if (check.memcmp(pg.orig[off..].ptr, c.data[off..].ptr, chunk) == 0) continue;
                const o: *const [chunk / 8]u64 = @ptrCast(@alignCast(pg.orig[off..][0..chunk]));
                const d: *const [chunk / 8]u64 = @ptrCast(@alignCast(c.data[off..][0..chunk]));
                const f: [*]u64 = @ptrCast(@alignCast(pg.live + off));
                for (o, d, 0..) |a, b, i| if (a != b) @atomicStore(u64, &f[i], b, .seq_cst);
            }
            if (code) |cp| if (cp.pageOf(@intFromPtr(pg.live))) |n| if (cp.isCode(n)) cp.invalidate(n);
        }
    }
};

var lock: std.atomic.Mutex = .unlocked;
/// Instructions a region may run before it comes back to look for kicks.
const slice = 1 << 16;
/// Takes the lock: a short spin, then yielding the host CPU, since the
/// holder may be one of more vCPUs than there are host CPUs.
fn acquire() void {
    var spins: u32 = 0;
    while (!lock.tryLock()) {
        spins += 1;
        if (spins < 64) std.atomic.spinLoopHint() else std.Thread.yield() catch {};
    }
}

/// Runs of a region whose pages something else wrote, before T0 takes it.
const tries = 8;

/// Per-vCPU check state, kept by the Guest's Cpu.
pub const State = struct {
    checker: ?check.Checker = null,
    snap: ?*Snapshot = null,
    view: ?*mem.View = null,
    native: ?Native = null,
    native_tried: bool = false,
    /// Regions lifted and optimized (and compiled), by entry PC, each with
    /// the code bytes it was lifted from: lifting each time a region runs
    /// costs far more than checking it.
    regions: std.AutoHashMapUnmanaged(u64, *Cached) = .empty,
    /// Bumped when `native`'s code memory fills and starts again, which
    /// leaves every compiled entry before it stale.
    native_gen: u32 = 0,

    pub fn deinit(s: *State) void {
        s.dropChecker();
        if (s.native) |*n| n.deinit();
        s.native = null;
        s.native_tried = false;
        s.regions.deinit(std.heap.smp_allocator);
        s.regions = .empty;
    }

    fn dropChecker(s: *State) void {
        if (s.checker) |*c| c.deinit();
        s.checker = null;
        if (s.snap) |sn| {
            sn.deinit();
            sn.gpa.destroy(sn);
        }
        s.snap = null;
        s.dropRegions();
    }

    fn dropRegions(s: *State) void {
        var it = s.regions.valueIterator();
        while (it.next()) |c| c.*.destroy();
        s.regions.clearRetainingCapacity();
    }

    /// The region at `pc`, from the cache if the code it was lifted from
    /// is still there, or lifted (and compiled) now; null if nothing lifts.
    fn region(s: *State, g: *const check.Guest, sn: *Snapshot, src: fe.Source, pc: u64) ?*Cached {
        const gpa = std.heap.smp_allocator;
        if (s.regions.get(pc)) |c| {
            if (c.same(sn)) {
                s.compile(c);
                return c;
            }
            _ = s.regions.remove(pc);
            c.destroy();
        }
        if (s.regions.count() >= max_regions) s.dropRegions();
        const c = gpa.create(Cached) catch @panic("jit check: out of memory");
        c.* = .{ .gpa = gpa, .reg = .{ .entry_pc = pc } };
        var rec: Recorder = .{ .c = c, .inner = src };
        var b = ir.Builder.init(gpa, &c.reg);
        g.frontend.lift(&b, rec.source(), pc, .{}) catch {
            c.destroy();
            return null;
        };
        if (ir.verify(&c.reg)) |err| std.debug.panic("jit check: region at {x} doesn't verify: {s} at %{d}", .{ pc, err.msg, err.inst });
        opt.run(gpa, &c.reg) catch @panic("jit check: out of memory");
        if (ir.verify(&c.reg)) |err| std.debug.panic("jit check: region at {x} doesn't verify after opt: {s} at %{d}", .{ pc, err.msg, err.inst });
        s.compile(c);
        s.regions.put(gpa, pc, c) catch @panic("jit check: out of memory");
        return c;
    }

    /// Compiles `c` for this host if it isn't, or its code went stale.
    fn compile(s: *State, c: *Cached) void {
        const n = &(s.native orelse return);
        if (c.entry != null and c.gen == s.native_gen) return;
        if (c.declined) return;
        const used = n.code.used;
        const f = n.compile(c.gpa, &c.reg) catch null;
        if (n.code.used < used) s.native_gen +%= 1;
        c.entry = f;
        c.gen = s.native_gen;
        c.declined = f == null;
    }
};

const max_regions = 1 << 15;

/// A lifted region, and the code it was lifted from.
const Cached = struct {
    gpa: std.mem.Allocator,
    reg: ir.Region,
    /// Generated code for it, compiled in `gen` of the State's Native.
    entry: ?ctx_mod.EntryFn = null,
    gen: u32 = 0,
    /// The emitter declined it: ir_eval runs it.
    declined: bool = false,
    /// The lifter's reads: where, how many bytes it asked for and got, and
    /// the bytes (in `bytes`, in order).
    reads: std.ArrayList(Read) = .empty,
    bytes: std.ArrayList(u8) = .empty,

    const Read = struct { va: u64, want: u32, got: u32 };

    fn destroy(c: *Cached) void {
        c.reg.deinit(c.gpa);
        c.reads.deinit(c.gpa);
        c.bytes.deinit(c.gpa);
        c.gpa.destroy(c);
    }

    /// Whether the snapshot holds the code it was lifted from, as the
    /// lifter read it (through Backing.readCode: executable pages).
    fn same(c: *const Cached, sn: *Snapshot) bool {
        var at: usize = 0;
        for (c.reads.items) |r| {
            var va = r.va;
            var left: usize = r.got;
            // What it read, a page at a time.
            while (left > 0) {
                const pg = sn.get(va >> mem.page_shift) orelse return false;
                if (!pg.exec) return false;
                const off: usize = @intCast(va & (mem.page_size - 1));
                const k = @min(left, mem.page_size - off);
                if (check.memcmp(pg.data[off..].ptr, c.bytes.items[at..].ptr, k) != 0) return false;
                at += k;
                left -= k;
                va +%= k;
            }
            // Where it stopped short, it still must.
            if (r.got < r.want) if (sn.get(va >> mem.page_shift)) |pg| if (pg.exec) return false;
        }
        return true;
    }

    fn tier(c: *const Cached) check.Tier1 {
        if (c.entry) |f| return .{ .entry = f };
        return .{ .ir_eval = &c.reg };
    }
};

/// A Source that records what the lifter reads into a Cached.
const Recorder = struct {
    c: *Cached,
    inner: fe.Source,

    fn source(r: *Recorder) fe.Source {
        return .{ .ctx = r, .read = read };
    }

    fn read(p: *anyopaque, va: u64, buf: []u8) usize {
        const r: *Recorder = @ptrCast(@alignCast(p));
        const n = r.inner.readAll(va, buf);
        const c = r.c;
        c.reads.append(c.gpa, .{ .va = va, .want = @intCast(buf.len), .got = @intCast(n) }) catch @panic("jit check: out of memory");
        c.bytes.appendSlice(c.gpa, buf[0..n]) catch @panic("jit check: out of memory");
        return n;
    }
};

/// Checked regions from the PC (in `cpu`, the front end's Cpu) until one
/// leaves for the Guest, as dispatch.run would. With `native`, each region
/// runs as generated code where this host's emitter takes it.
pub fn run(s: *State, g: *const check.Guest, cpu: *anyopaque, ctx: *Ctx, native: bool) dispatch.Result {
    const gpa = std.heap.smp_allocator;
    const v: *mem.View = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    if (s.view != v) {
        s.dropChecker();
        s.view = v;
    }
    if (s.checker == null) {
        const sn = gpa.create(Snapshot) catch @panic("jit check: out of memory");
        sn.* = .{ .gpa = gpa, .view = v };
        s.snap = sn;
        s.checker = check.Checker.init(gpa, g, sn.backing()) catch @panic("jit check: out of memory");
    }
    if (native and !s.native_tried) {
        s.native_tried = true;
        s.native = Native.init() catch null;
    }
    const r = s.checker.?.r;
    const sn = s.snap.?;
    const bytes: [*]u8 = @ptrCast(cpu);
    // arm64's instructions are 4-aligned; x86's, in either mode, aren't.
    const pc_align: u64 = if (g == a64_guest) 4 else 1;
    var raced: u32 = 0;
    while (true) {
        if (@atomicLoad(u32, &ctx.exit_request, .monotonic) != 0 or ctx.budget <= 0) return .interrupted;
        const pc = getPc(g, bytes);
        if (pc & (pc_align - 1) != 0) return .t0;
        sn.reset();
        const back = sn.backing();
        // Nothing to lift (code it can't read, say): T0 takes the fault.
        const cached = s.region(g, sn, back.source(), pc) orelse return .t0;
        const tier = cached.tier();

        // The check's own Ctx doesn't see kicks: a slice of budget brings
        // a guest loop back here to look for them.
        const budget = @min(ctx.budget, slice);
        acquire();
        const agreed = r.check(tier, bytes[0..g.cpu_size], .{ .budget = budget, .helpers = ctx.helpers, .retired = ctx.retired }) catch |err| {
            lock.unlock();
            std.debug.panic("jit check: {t}", .{err});
        };
        if (sn.oom) {
            lock.unlock();
            @panic("jit check: out of memory");
        }
        if (!sn.unchanged()) {
            // Something else wrote a page the region touched: run it again
            // on what's there now.
            lock.unlock();
            raced += 1;
            if (raced < tries) continue;
            return .t0;
        }
        if (!agreed) {
            std.debug.print("jit check: T1 and T0 diverge\n{s}\n", .{r.report.items});
            @panic("jit check: T1 and T0 diverge");
        }
        sn.commit(&r.shadow[check.Run.t1], v.code);
        lock.unlock();
        raced = 0;
        const entry = retiredOf(g, bytes);
        @memcpy(bytes[0..g.cpu_size], r.cpu[check.Run.t1]);
        // T0 counts Cpu.retired again in each call.interp: ctx's count is
        // the one that holds, as the vmm keeps it (ha64 has none).
        if (entry) |e| setRetired(g, bytes, e +% r.out[check.Run.t1].retired);
        const out = r.out[check.Run.t1];
        const c1 = &r.ctx[check.Run.t1];
        const n = out.retired;
        ctx.retired +%= n;
        if (ctx.budget != std.math.maxInt(i64)) ctx.budget -%= @bitCast(n);
        setPc(g, bytes, c1.exit_pc);
        switch (out.exit) {
            .chain, .indirect, .interrupted => if (c1.exit_pc == pc and n == 0) return .t0,
            .svc => return .svc,
            // The Cpu is at the instruction: T0 raises it again.
            .fault, .undef, .brk => return .t0,
            else => |e| std.debug.panic("jit check: region left with {t}", .{e}),
        }
    }
}

/// The x86 Cpu's own retired count, which RDTSC reads.
fn retiredOf(g: *const check.Guest, b: [*]u8) ?u64 {
    if (g == x86_guest) return @as(*const check.x86.Cpu, @ptrCast(@alignCast(b))).retired;
    if (g == x64_guest) return @as(*const check.x86.Cpu64, @ptrCast(@alignCast(b))).retired;
    return null;
}

fn setRetired(g: *const check.Guest, b: [*]u8, v: u64) void {
    if (g == x86_guest) @as(*check.x86.Cpu, @ptrCast(@alignCast(b))).retired = v;
    if (g == x64_guest) @as(*check.x86.Cpu64, @ptrCast(@alignCast(b))).retired = v;
}

fn getPc(g: *const check.Guest, b: [*]u8) u64 {
    return if (g.pc_bytes == 4) std.mem.readInt(u32, b[g.pc_off..][0..4], .little) else std.mem.readInt(u64, b[g.pc_off..][0..8], .little);
}

fn setPc(g: *const check.Guest, b: [*]u8, v: u64) void {
    if (g.pc_bytes == 4) std.mem.writeInt(u32, b[g.pc_off..][0..4], @truncate(v), .little) else std.mem.writeInt(u64, b[g.pc_off..][0..8], v, .little);
}

test "jit check: the snapshot sees a store that lands after it, and the commit keeps it" {
    const gpa = std.testing.allocator;
    var pages: [2 * mem.page_size]u8 align(mem.page_size) = @splat(0);
    const maps = [_]mem.Mapping{.{ .va = 0x10000, .len = pages.len, .host = @intFromPtr(&pages), .perms = .{ .write = true } }};
    var tlb: mem.Tlb = .{};
    var v: mem.View = .{ .maps = &maps, .tlb = &tlb };
    var sn: Snapshot = .{ .gpa = gpa, .view = &v };
    defer sn.deinit();
    const vp = 0x10000 >> mem.page_shift;
    const live: *[mem.page_size / 8]u64 = @ptrCast(pages[0..mem.page_size]);

    // Nothing else stores: unchanged.
    _ = sn.get(vp).?;
    try std.testing.expect(sn.unchanged());
    // Another vCPU stores after the snapshot: the region runs again.
    live[1] = 7;
    try std.testing.expect(!sn.unchanged());

    // T1 stores word 0; another vCPU stored word 2 meanwhile. The commit
    // writes word 0 alone, and word 2 keeps the other store.
    sn.reset();
    var sh = check.Shadow.init(gpa, sn.backing());
    defer sh.deinit();
    const c = sh.get(vp).?;
    std.mem.writeInt(u64, c.data[0..8], 0x1122, .little);
    live[2] = 9;
    sn.commit(&sh, null);
    try std.testing.expectEqual(@as(u64, 0x1122), live[0]);
    try std.testing.expectEqual(@as(u64, 7), live[1]);
    try std.testing.expectEqual(@as(u64, 9), live[2]);
}
