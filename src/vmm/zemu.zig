//! The emulator backend on h9's own CPUs (-Demu=zig): ha64 for arm64
//! binaries and h86 for 386 binaries, picked by architecture at create.
//! amd64 binaries need Unicorn (-Demu=unicorn).
//!
//! This file is the part both share: guest memory, address spaces, vCPUs,
//! kicks, and shootdowns. What's particular to an architecture is a Guest
//! (ha64.zig, h86.zig): its register file and the loop that runs it.
//!
//! There is no guest lock. Every vCPU runs guest code at once, and other
//! threads reach a running vCPU only through its Ctx's exit-request word,
//! which guest code checks at every `poll` (T1) and every block (T0):
//!
//! - A kick sets `req_kick`, and `run` returns `.interrupted`.
//! - A shootdown or a code-cache flush sets `req_sync`, and the vCPU leaves
//!   guest code, catches up with its address space, and carries on without
//!   returning. The thread that asked waits until the vCPU has left (its
//!   `seq` moves), which is the "wait" of kick-and-wait.
//!
//! A vCPU's `seq` is odd while it's in guest code. It makes `seq` odd before
//! it looks at its address space's generation, and a shootdown bumps the
//! generation before it looks at `seq`, so either the vCPU sees the change
//! or the shootdown sees the vCPU and waits for it.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const vmm = @import("../vmm.zig");
const Arena = @import("arena.zig");
const mem = @import("vcpu").mem;
const ctx_mod = @import("vcpu").ctx;
const Ctx = ctx_mod.Ctx;
const cache = @import("vcpu").cache;
const codemem = @import("vcpu").codemem;
const ha64 = @import("ha64.zig");
const h86 = @import("h86.zig");

pub fn version(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "zig ({s})", .{if (build_options.jit) "jit" else "interpreter"}) catch "zig";
}

/// Ctx.exit_request bits.
pub const req_kick = cache.req_kick;
pub const req_sync = cache.req_sync;

/// The web host (design/0012-browser-host.md): one thread, whose
/// coroutines take turns, so a vCPU leaves guest code on a budget of
/// instructions as well as on requests (see State.run).
const web = builtin.os.tag == .wasi;
/// Guest memory there, as v86's: a tab's memory is scarcer than a host's,
/// and wasm32 addresses 4 GiB in all, h9's heap and v86's included.
const web_default_memory: u64 = 256 << 20;
const web_max_memory: u64 = 2 << 30;
/// Guest instructions between looks at the clock, and how long a vCPU
/// keeps the thread before the other coroutines get a turn (v86.zig's
/// slice).
const web_budget: i64 = 64 * 1024;
const web_slice_ns = 2 * std.time.ns_per_ms;
const coro = if (web) @import("../web/coro.zig") else struct {};
/// The web host's T1, whose regions are keyed by this backend's arena pages.
const wasm_t1 = @import("vcpu").wasm_t1;

fn monoNs() u64 {
    var t: std.os.wasi.timestamp_t = 0;
    _ = std.os.wasi.clock_time_get(.MONOTONIC, 1, &t);
    return t;
}

/// The code cache's size, per backend: 64 MiB, or H9_EMU_CACHE bytes
/// (tests that need it to fill, tests/a64.zig).
const cache_size = 64 << 20;

fn cacheSize() usize {
    if (!builtin.link_libc) return cache_size;
    const v = std.c.getenv("H9_EMU_CACHE") orelse return cache_size;
    return std.fmt.parseInt(usize, std.mem.span(v), 0) catch cache_size;
}

/// Whether this process can generate code: codemem.available(), unless
/// H9_EMU_NO_CODEGEN=1 says to act as a host that refuses it would (iOS,
/// or a hardened runtime without the JIT entitlement), so that the
/// fallback to T0 can be tested anywhere.
fn codegenAvailable() bool {
    if (builtin.link_libc) if (std.c.getenv("H9_EMU_NO_CODEGEN")) |v| {
        if (std.mem.eql(u8, std.mem.span(v), "1")) return false;
    };
    return codemem.available();
}

/// H9_EMU_DETERMINISTIC=1: a Guest with a `deterministic` flag derives
/// its counter from instructions retired (design/0019's deterministic
/// mode), set at create like the tier.
fn deterministicFromEnv() bool {
    if (!builtin.link_libc) return false;
    const v = std.c.getenv("H9_EMU_DETERMINISTIC") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "1");
}

const Impl = Emu(ha64, h86);
pub const Backend = Impl.EmuBackend;
pub const AddressSpace = Impl.EmuSpace;
pub const Vcpu = Impl.EmuVcpu;

/// The backend over two Guests, one per architecture. A Guest is a type
/// (in practice a file, ha64.zig or h86.zig) with:
///
///     pub const arch: vmm.Arch;
///     /// False until its T0 runs programs: create fails with WrongArch.
///     pub const ready: bool;
///     /// The register file, default-initialized at createVcpu.
///     pub const Cpu: type;
///     pub fn getUreg(cpu: *const Cpu, u: *vmm.Ureg) void;
///     pub fn setUreg(cpu: *Cpu, u: *const vmm.Ureg) void;
///     pub fn getExtra(cpu: *const Cpu, x: *vmm.Extra) vmm.Error!void;
///     pub fn setExtra(cpu: *Cpu, x: *const vmm.Extra) vmm.Error!void;
///     /// Runs guest code until an exit, filling the Ureg's trap fields as
///     /// the real kernel would. Returns `.interrupted`, leaving it set,
///     /// as soon as it sees ctx.exit_request nonzero: at least at every
///     /// block, so a spinning guest sees it within one iteration.
///     pub fn run(cpu: *Cpu, ctx: *Ctx) vmm.Error!vmm.Exit;
///     /// Optional: frees what the Cpu owns, when its vCPU is destroyed.
///     pub fn deinit(cpu: *Cpu) void;
///     /// Optional: which tier runs guest code, an enum with t0 and t1.
///     /// H9_EMU_TIER=t0 or t1 sets it at create (`applyTier`); unset, the
///     /// Guest's own default stands.
///     pub var tier: enum { t0, t1, ... };
///
/// The ctx is a `cache.Runtime`'s (`cache.Runtime.of(ctx)`), which holds
/// the vCPU's jump cache and the backend's code cache, null when the host
/// or build can't generate code. When `insert` says the cache is full, the
/// Guest calls `requestFlush` and returns `.interrupted`; the flush happens
/// here, with every vCPU out of guest code.
///
/// `run`'s ctx comes with `cpu` pointing at the Cpu, `tlb` at the vCPU's
/// TLB, `space` at its `mem.View`, and the slow paths `mem.slowLoad` and
/// `mem.slowStore`. `frontend`, `interp`, and `helpers` are the Guest's to
/// set. T0 reads code through `mem.fastExec` and `mem.probe(.exec)`, and a
/// lifter through `View.source`, which mark the pages read as holding
/// code; `mem.probe(.write)` gives a host pointer for an atomic.
/// Guest instructions retired by every vCPU so far, for benchmarks: a
/// Guest with `retired(cpu) u64` counts here. (A usize on the web host,
/// which has no 64-bit atomics.)
pub var retired_total: std.atomic.Value(if (web) usize else u64) = .init(0);

/// H9_EMU_TIER, if set: "t0" or "t1".
pub fn tierFromEnv() ?[]const u8 {
    if (!builtin.link_libc) return null;
    const v = std.c.getenv("H9_EMU_TIER") orelse return null;
    return std.mem.span(v);
}

/// Sets Guest G's `tier` from `name` ("t0" or "t1"), if G has one. Returns
/// false if the name isn't one of G's tiers.
pub fn applyTier(comptime G: type, name: []const u8) bool {
    if (!@hasDecl(G, "tier")) return true;
    G.tier = std.meta.stringToEnum(@TypeOf(G.tier), name) orelse return false;
    return true;
}

pub fn Emu(comptime A64: type, comptime X86: type) type {
    return struct {
        pub const Cpu = union(enum) {
            arm64: A64.Cpu,
            i386: X86.Cpu,
        };

        fn Guest(comptime a: std.meta.Tag(Cpu)) type {
            return switch (a) {
                .arm64 => A64,
                .i386 => X86,
            };
        }

        pub const EmuBackend = struct {
            gpa: std.mem.Allocator,
            io: std.Io,
            arch: vmm.Arch,
            /// Guards `arena` and `used`.
            lock: std.Io.Mutex = .init,
            arena: Arena,
            used: u64 = 0,
            limit: u64,
            /// Which arena pages hold code.
            code: mem.CodePages,
            /// Every vCPU, for sweeps and shootdowns.
            vcpus: std.ArrayList(*State) = .empty,
            vcpus_lock: std.atomic.Mutex = .unlocked,
            /// kickAndWait calls holding vCPU pointers outside vcpus_lock;
            /// a vCPU isn't freed until there are none.
            kickers: std.atomic.Value(u32) = .init(0),
            /// The code cache, if this host and build generate code.
            jit: ?*cache.Cache = null,
            flush_wanted: std.atomic.Value(bool) = .init(false),
            /// Nonzero while a flush has every vCPU held out of guest code.
            stopping: std.atomic.Value(u32) = .init(0),
            /// Serializes flushes.
            world: std.Io.Mutex = .init,
            /// On the web, when a vCPU last let the other coroutines run,
            /// in monotonic ns.
            yielded: u64 = 0,

            pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: vmm.Options) vmm.CreateError!*EmuBackend {
                switch (opts.arch) {
                    // Until a Guest runs programs, its architecture is
                    // one this backend can't run, as for amd64.
                    .arm64 => if (!A64.ready) return error.WrongArch,
                    .i386 => if (!X86.ready) return error.WrongArch,
                    .amd64 => return error.WrongArch,
                }
                if (opts.arch == .arm64 and @hasDecl(A64, "deterministic")) A64.deterministic = deterministicFromEnv();
                if (tierFromEnv()) |t| {
                    const ok = switch (opts.arch) {
                        .arm64 => applyTier(A64, t),
                        .i386 => applyTier(X86, t),
                        .amd64 => unreachable,
                    };
                    if (!ok) std.log.warn("H9_EMU_TIER={s}: not t0 or t1; using the default", .{t});
                }
                const limit = opts.memory orelse if (web) web_default_memory else vmm.default_memory;
                if (limit > (if (web) web_max_memory else vmm.max_memory)) return error.OutOfGuestMemory;
                // Twice the cap in address space, as emu.zig does, so freed
                // ranges scattered through it don't run allocations out. Not
                // on the web, where the arena is real memory in a 4 GiB space.
                var arena = Arena.init(std.mem.alignForward(usize, @intCast(if (web) limit else 2 * limit), vmm.page_size)) catch return error.OutOfGuestMemory;
                errdefer arena.deinit(gpa);
                const b = try gpa.create(EmuBackend);
                errdefer gpa.destroy(b);
                b.* = .{ .gpa = gpa, .io = io, .arch = opts.arch, .limit = limit, .arena = arena, .code = undefined };
                b.code = try .init(gpa, @intFromPtr(arena.mem.ptr), arena.mem.len, .{
                    .owner = b,
                    .drop = dropEntries,
                    .invalidate = invalidate,
                });
                errdefer b.code.deinit(gpa);
                if (build_options.jit and !web and codegenAvailable()) {
                    const c = try gpa.create(cache.Cache);
                    if (cache.Cache.init(gpa, cacheSize())) |v| {
                        c.* = v;
                        b.jit = c;
                    } else |_| gpa.destroy(c);
                }
                return b;
            }

            pub fn destroy(b: *EmuBackend) void {
                std.debug.assert(b.vcpus.items.len == 0);
                if (web) wasm_t1.reset();
                b.vcpus.deinit(b.gpa);
                if (build_options.jit) {
                    if (b.jit) |c| {
                        c.deinit();
                        b.gpa.destroy(c);
                    }
                }
                b.code.deinit(b.gpa);
                b.arena.deinit(b.gpa);
                b.gpa.destroy(b);
            }

            /// No hardware limit; this keeps the number in line with HVF's.
            pub fn maxVcpus(_: *EmuBackend) vmm.Error!u32 {
                return 64;
            }

            /// Zeroed pages from the arena. Pages nothing touches stay
            /// unbacked on the host.
            pub fn allocPages(b: *EmuBackend, n: usize) vmm.Error![]align(vmm.page_size) u8 {
                const len = n * vmm.page_size;
                if (len == 0) return error.BadAddress;
                b.lock.lockUncancelable(b.io);
                defer b.lock.unlock(b.io);
                if (b.used + len > b.limit) return error.OutOfGuestMemory;
                const m = b.arena.alloc(b.gpa, len) catch return error.OutOfGuestMemory;
                b.used += len;
                return m;
            }

            /// Pages from `allocPages`, no longer mapped. Whatever was
            /// compiled from them goes, so new contents never run stale code.
            pub fn freePages(b: *EmuBackend, m: []align(vmm.page_size) u8) void {
                if (m.len == 0) return;
                b.code.invalidateRange(@intFromPtr(m.ptr), m.len);
                b.lock.lockUncancelable(b.io);
                defer b.lock.unlock(b.io);
                b.used -= m.len;
                b.arena.freePages(b.gpa, m);
            }

            pub fn newAddressSpace(b: *EmuBackend) vmm.CreateError!*EmuSpace {
                const as = try b.gpa.create(EmuSpace);
                as.* = .{ .backend = b };
                return as;
            }

            pub fn createVcpu(b: *EmuBackend) vmm.CreateError!EmuVcpu {
                const s = try b.gpa.create(State);
                errdefer b.gpa.destroy(s);
                s.* = .{ .backend = b, .cpu = switch (b.arch) {
                    .arm64 => .{ .arm64 = .{} },
                    .i386 => .{ .i386 = .{} },
                    .amd64 => unreachable,
                } };
                s.view = .{ .code = &b.code, .tlb = &s.tlb };
                s.rt.cache = b.jit;
                s.rt.flush_wanted = &b.flush_wanted;
                if (build_options.jit) if (b.jit) |c| try c.addJumpCache(&s.rt.jump);
                errdefer if (build_options.jit) if (b.jit) |c| c.removeJumpCache(&s.rt.jump);
                b.lockVcpus();
                defer b.vcpus_lock.unlock();
                try b.vcpus.append(b.gpa, s);
                return .{ .s = s };
            }

            /// On the web: lets every other coroutine run. Only between
            /// runs of guest code, so no vCPU is ever in it while another
            /// coroutine runs, and kickAndWait never waits.
            fn yieldThread(b: *EmuBackend) void {
                coro.yield();
                b.yielded = monoNs();
            }

            fn lockVcpus(b: *EmuBackend) void {
                while (!b.vcpus_lock.tryLock()) std.atomic.spinLoopHint();
            }

            fn dropEntries(p: *anyopaque, host: usize, table: mem.Table) void {
                const b: *EmuBackend = @ptrCast(@alignCast(p));
                b.lockVcpus();
                defer b.vcpus_lock.unlock();
                for (b.vcpus.items) |s| mem.dropEntries(&s.tlb, host, table);
            }

            fn invalidate(p: *anyopaque, page: u64) void {
                const b: *EmuBackend = @ptrCast(@alignCast(p));
                if (build_options.jit) if (b.jit) |c| c.invalidatePage(page);
                if (web) wasm_t1.invalidatePage(page);
            }

            /// Empties the code cache if someone asked, with every vCPU
            /// but `self` (which isn't in guest code) held out of it.
            fn flushCache(b: *EmuBackend, self: ?*State) void {
                b.world.lockUncancelable(b.io);
                defer b.world.unlock(b.io);
                if (!b.flush_wanted.swap(false, .seq_cst)) return;
                b.stopping.store(1, .seq_cst);
                b.kickAndWait(self, struct {
                    fn wants(_: @This(), _: *State) bool {
                        return true;
                    }
                }{});
                if (std.debug.runtime_safety) {
                    b.lockVcpus();
                    defer b.vcpus_lock.unlock();
                    for (b.vcpus.items) |x| std.debug.assert(!x.running.load(.seq_cst));
                }
                if (build_options.jit) if (b.jit) |c| c.reset();
                b.stopping.store(0, .seq_cst);
                b.io.futexWake(u32, &b.stopping.raw, std.math.maxInt(u32));
            }

            /// Asks each vCPU that `pick` picks and that is in guest code
            /// (other than `self`) to leave it, and waits until each has.
            /// Each sees whatever changed before this was called before it
            /// runs another guest instruction.
            fn kickAndWait(b: *EmuBackend, self: ?*State, pick: anytype) void {
                const Wait = struct { s: *State, seq: u32 };
                var stack: [64]Wait = undefined;
                var heap: []Wait = &.{};
                defer if (heap.len != 0) b.gpa.free(heap);
                var n: usize = 0;
                {
                    b.lockVcpus();
                    defer b.vcpus_lock.unlock();
                    // Room to wait for every one of them: a vCPU not waited
                    // for could still be reading what the caller changes.
                    const waits: []Wait = if (b.vcpus.items.len <= stack.len) &stack else blk: {
                        heap = b.gpa.alloc(Wait, b.vcpus.items.len) catch @panic("zemu: out of memory in a shootdown");
                        break :blk heap;
                    };
                    for (b.vcpus.items) |s| {
                        if (s == self or !pick.wants(s)) continue;
                        const seq = s.seq.load(.seq_cst);
                        if (seq & 1 == 0) continue;
                        _ = @atomicRmw(u32, &s.rt.ctx.exit_request, .Or, req_sync, .seq_cst);
                        waits[n] = .{ .s = s, .seq = seq };
                        n += 1;
                    }
                    // Raised under the lock, so a destroy that removes one
                    // of these afterwards waits for the waits below.
                    _ = b.kickers.fetchAdd(1, .seq_cst);
                }
                defer _ = b.kickers.fetchSub(1, .seq_cst);
                const waits: []Wait = if (heap.len != 0) heap else &stack;
                // A vCPU may leave guest code for its own reasons and be
                // destroyed (its thread exiting) before the wait reads its
                // seq; EmuVcpu.destroy waits out `kickers`, so the pointers
                // stay good.
                for (waits[0..n]) |w| {
                    while (w.s.seq.load(.seq_cst) == w.seq) {
                        b.io.futexWaitTimeout(u32, &w.s.seq.raw, w.seq, .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }) catch {};
                    }
                }
            }
        };

        /// The mappings, which each vCPU running the space copies into its
        /// View before it runs guest code whenever `generation` has moved.
        pub const EmuSpace = struct {
            backend: *EmuBackend,
            regions: std.ArrayList(Region) = .empty,
            /// Bumped on every change. A usize: wasm32 has no 64-bit atomics.
            generation: std.atomic.Value(usize) = .init(1),
            /// Guards `regions`: a process's threads change and read them
            /// at once.
            lock: std.atomic.Mutex = .unlocked,

            const Region = struct { va: u64, mem: []align(vmm.page_size) u8, perms: vmm.Perms };

            fn lockSpin(as: *EmuSpace) void {
                while (!as.lock.tryLock()) std.atomic.spinLoopHint();
            }

            pub fn destroy(as: *EmuSpace) void {
                as.regions.deinit(as.backend.gpa);
                as.backend.gpa.destroy(as);
            }

            pub fn map(as: *EmuSpace, va: u64, m: []align(vmm.page_size) u8, perms: vmm.Perms) vmm.CreateError!void {
                if (va % vmm.page_size != 0 or m.len % vmm.page_size != 0 or m.len == 0) return error.BadAddress;
                if (va +% m.len < va) return error.BadAddress;
                // Only the backend's own memory: a host pointer from
                // anywhere else would let guest code reach outside the
                // sandbox (A1 saw a kernel bug pass a null slice).
                const arena = as.backend.arena.mem;
                const lo = @intFromPtr(arena.ptr);
                const p = @intFromPtr(m.ptr);
                if (p < lo or p - lo > arena.len or m.len > arena.len - (p - lo)) return error.BadAddress;
                as.lockSpin();
                defer as.lock.unlock();
                for (as.regions.items) |r| {
                    if (va < r.va + r.mem.len and r.va < va + m.len) return error.BadAddress;
                }
                try as.regions.append(as.backend.gpa, .{ .va = va, .mem = m, .perms = perms });
                _ = as.generation.fetchAdd(1, .seq_cst);
            }

            pub fn unmap(as: *EmuSpace, va: u64) void {
                as.lockSpin();
                defer as.lock.unlock();
                for (as.regions.items, 0..) |r, i| if (r.va == va) {
                    _ = as.regions.swapRemove(i);
                    _ = as.generation.fetchAdd(1, .seq_cst);
                    return;
                };
            }

            fn find(as: *EmuSpace, va: u64, len: u64) ?[]u8 {
                for (as.regions.items) |r| {
                    if (va >= r.va and va - r.va <= r.mem.len and len <= r.mem.len - (va - r.va)) {
                        return r.mem[@intCast(va - r.va)..][0..@intCast(len)];
                    }
                }
                return null;
            }

            pub fn translate(as: *EmuSpace, va: u64, len: u64) ?[]u8 {
                as.lockSpin();
                defer as.lock.unlock();
                return as.find(va, len);
            }

            pub fn copy(as: *EmuSpace, va: u64, buf: []u8, write: bool) bool {
                as.lockSpin();
                defer as.lock.unlock();
                const m = as.find(va, buf.len) orelse return false;
                if (write) {
                    // The host may be writing code (a breakpoint).
                    as.backend.code.invalidateRange(@intFromPtr(m.ptr), m.len);
                    @memcpy(m, buf);
                } else @memcpy(buf, m);
                return true;
            }

            /// The host wrote code: what was decoded or compiled from those
            /// pages goes now, for every space mapping them.
            pub fn codeChanged(as: *EmuSpace, va: u64, len: u64) void {
                as.lockSpin();
                defer as.lock.unlock();
                for (as.regions.items) |r| {
                    const lo = @max(va, r.va);
                    const hi = @min(va +| len, r.va + r.mem.len);
                    if (lo < hi) as.backend.code.invalidateRange(@intFromPtr(r.mem.ptr) + @as(usize, @intCast(lo - r.va)), @intCast(hi - lo));
                }
            }

            /// Kicks every vCPU running this space and waits until each has
            /// left guest code. Each looks at the space again before its
            /// next guest instruction, so none can reach what `unmap`
            /// removed. The caller's own vCPU isn't in guest code.
            pub fn shootdown(as: *EmuSpace) void {
                as.backend.kickAndWait(null, struct {
                    as: *EmuSpace,
                    fn wants(p: @This(), s: *State) bool {
                        return s.as.load(.seq_cst) == p.as;
                    }
                }{ .as = as });
            }
        };

        const State = struct {
            backend: *EmuBackend,
            cpu: Cpu,
            /// The Ctx, and the jump cache with it.
            rt: cache.Runtime = .{},
            tlb: mem.Tlb = .{},
            view: mem.View = undefined,
            as: std.atomic.Value(?*EmuSpace) = .init(null),
            /// The view's mappings, and the space's generation they're from.
            maps: std.ArrayList(mem.Mapping) = .empty,
            generation: usize = 0,
            /// Odd while in guest code.
            seq: std.atomic.Value(u32) = .init(0),
            /// While inside the Guest's run, for checking flushes.
            running: std.atomic.Value(bool) = .init(false),

            fn enter(s: *State) void {
                _ = s.seq.fetchAdd(1, .seq_cst);
            }

            fn leave(s: *State) void {
                _ = s.seq.fetchAdd(1, .seq_cst);
                // Only a shootdown waits on seq, and it raises `kickers`
                // before the re-read of seq its wait makes: with both
                // seq_cst, either that re-read sees the new seq or this
                // sees it waiting. A futex wake is a
                // system call, most of a bare exit's cost otherwise.
                if (s.backend.kickers.load(.seq_cst) != 0)
                    s.backend.io.futexWake(u32, &s.seq.raw, std.math.maxInt(u32));
            }

            /// Brings the view up to date with the space. Called in guest
            /// code (seq odd), before running any.
            fn sync(s: *State) vmm.Error!void {
                const as = s.as.load(.monotonic).?;
                if (as.generation.load(.seq_cst) == s.generation) return;
                as.lockSpin();
                defer as.lock.unlock();
                const gpa = s.backend.gpa;
                // A mapping gone or changed may be in the TLB; a new one
                // can't be.
                var dropped = s.generation == 0;
                if (!dropped) {
                    outer: for (s.maps.items) |old| {
                        for (as.regions.items) |r| {
                            if (r.va == old.va and @intFromPtr(r.mem.ptr) == old.host and r.mem.len == old.len and perms(r.perms) == old.perms) continue :outer;
                        }
                        dropped = true;
                        break;
                    }
                }
                s.maps.clearRetainingCapacity();
                s.maps.ensureTotalCapacity(gpa, as.regions.items.len) catch return error.OutOfGuestMemory;
                for (as.regions.items) |r| s.maps.appendAssumeCapacity(.{ .va = r.va, .len = r.mem.len, .host = @intFromPtr(r.mem.ptr), .perms = perms(r.perms) });
                std.mem.sortUnstable(mem.Mapping, s.maps.items, {}, struct {
                    fn lt(_: void, a: mem.Mapping, b: mem.Mapping) bool {
                        return a.va < b.va;
                    }
                }.lt);
                s.view.maps = s.maps.items;
                if (dropped) {
                    s.tlb.flush();
                    s.rt.jump.clear();
                }
                s.generation = as.generation.load(.seq_cst);
            }

            fn perms(p: vmm.Perms) mem.Perms {
                return .{ .read = p.read, .write = p.write, .exec = p.exec };
            }

            fn run(s: *State) vmm.Error!vmm.Exit {
                if (s.as.load(.monotonic) == null) return error.BadAddress;
                const b = s.backend;
                const cx = &s.rt.ctx;
                s.rt.bind();
                cx.tlb = @intFromPtr(&s.tlb);
                cx.space = @intFromPtr(&s.view);
                cx.slow_load = @intFromPtr(&mem.slowLoad);
                cx.slow_store = @intFromPtr(&mem.slowStore);
                cx.slow_cas = @intFromPtr(&mem.slowCas);
                // A guest that makes a syscall every few instructions never
                // spends a budget: let the others run once a slice has
                // passed, as a timer interrupt would.
                if (web and monoNs() -% b.yielded > web_slice_ns) b.yieldThread();
                while (true) {
                    if (web) cx.budget = web_budget;
                    s.enter();
                    if (b.stopping.load(.seq_cst) != 0) {
                        // A flush is emptying the cache: wait it out.
                        s.leave();
                        while (b.stopping.load(.seq_cst) != 0) b.io.futexWaitUncancelable(u32, &b.stopping.raw, 1);
                        continue;
                    }
                    if (@atomicLoad(u32, &cx.exit_request, .seq_cst) & req_kick != 0) {
                        _ = @atomicRmw(u32, &cx.exit_request, .And, ~req_kick, .seq_cst);
                        s.leave();
                        return .interrupted;
                    }
                    s.sync() catch |e| {
                        s.leave();
                        return e;
                    };
                    const exit = switch (s.cpu) {
                        inline else => |*c, a| blk: {
                            cx.cpu = @intFromPtr(c);
                            if (std.debug.runtime_safety) s.running.store(true, .seq_cst);
                            defer if (std.debug.runtime_safety) s.running.store(false, .seq_cst);
                            const G = Guest(a);
                            if (!@hasDecl(G, "retired")) break :blk G.run(c, cx);
                            const before = G.retired(c);
                            defer _ = retired_total.fetchAdd(@truncate(G.retired(c) -% before), .monotonic);
                            break :blk G.run(c, cx);
                        },
                    } catch |e| {
                        s.leave();
                        return e;
                    };
                    s.leave();
                    if (exit != .interrupted) return exit;
                    if (web and cx.budget <= 0 and @atomicLoad(u32, &cx.exit_request, .seq_cst) == 0) {
                        // The budget ran out. Past a slice, preempt: the
                        // others run, then the caller sees `.interrupted`.
                        if (monoNs() -% b.yielded <= web_slice_ns) continue;
                        b.yieldThread();
                        _ = @atomicRmw(u32, &cx.exit_request, .And, ~req_kick, .seq_cst);
                        return .interrupted;
                    }
                    const req = @atomicRmw(u32, &cx.exit_request, .And, ~(req_kick | req_sync), .seq_cst);
                    if (b.flush_wanted.load(.seq_cst)) b.flushCache(s);
                    if (req & req_kick != 0) return .interrupted;
                    // A sync, a flush, or nothing: catch up and go on.
                }
            }
        };

        pub const EmuVcpu = struct {
            s: *State,

            pub fn destroy(v: *EmuVcpu) void {
                const s = v.s;
                const b = s.backend;
                {
                    b.lockVcpus();
                    defer b.vcpus_lock.unlock();
                    for (b.vcpus.items, 0..) |x, i| if (x == s) {
                        _ = b.vcpus.swapRemove(i);
                        break;
                    };
                }
                // A shootdown that saw this vCPU may still read its seq.
                while (b.kickers.load(.seq_cst) != 0) std.atomic.spinLoopHint();
                if (build_options.jit) if (b.jit) |c| c.removeJumpCache(&s.rt.jump);
                switch (s.cpu) {
                    inline else => |*c, a| if (@hasDecl(Guest(a), "deinit")) Guest(a).deinit(c),
                }
                s.maps.deinit(b.gpa);
                b.gpa.destroy(s);
            }

            pub fn setAddressSpace(v: *EmuVcpu, as: *EmuSpace) vmm.Error!void {
                if (v.s.as.load(.monotonic) == as) return;
                v.s.as.store(as, .seq_cst);
                v.s.generation = 0;
            }

            pub fn run(v: *EmuVcpu) vmm.Error!vmm.Exit {
                return v.s.run();
            }

            pub fn getUreg(v: *EmuVcpu, u: *vmm.Ureg) void {
                switch (v.s.cpu) {
                    inline else => |*c, a| Guest(a).getUreg(c, u),
                }
            }

            pub fn setUreg(v: *EmuVcpu, u: *const vmm.Ureg) void {
                switch (v.s.cpu) {
                    inline else => |*c, a| Guest(a).setUreg(c, u),
                }
            }

            pub fn getExtra(v: *EmuVcpu, x: *vmm.Extra) vmm.Error!void {
                return switch (v.s.cpu) {
                    inline else => |*c, a| Guest(a).getExtra(c, x),
                };
            }

            pub fn setExtra(v: *EmuVcpu, x: *const vmm.Extra) vmm.Error!void {
                return switch (v.s.cpu) {
                    inline else => |*c, a| Guest(a).setExtra(c, x),
                };
            }

            /// Safe from any thread. Before `run`, the next run returns
            /// `.interrupted` at once; during one, guest code leaves at its
            /// next check.
            pub fn kick(v: *EmuVcpu) void {
                _ = @atomicRmw(u32, &v.s.rt.ctx.exit_request, .Or, req_kick, .seq_cst);
            }
        };
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A guest for testing the shared layer: a few ops over two registers,
/// through the TLB and slow paths as a real T0's loads and stores go, with
/// the exit-request check before every op.
const Toy = struct {
    pub const arch: vmm.Arch = .arm64;
    pub const ready = true;

    pub const Op = union(enum) {
        /// r[0] = mem64[addr]
        load: u64,
        /// mem64[addr] = r[0]
        store: u64,
        add: u64,
        /// Back to op 0 (a loop).
        again,
        svc,
        /// Asks for a code-cache flush, as a full cache would.
        flush,
    };

    pub const Cpu = struct {
        prog: []const Op = &.{},
        pc: usize = 0,
        r: [2]u64 = .{ 0, 0 },
        ureg: vmm.Ureg = .{ .arm64 = .{} },
        /// Ops run, across runs.
        steps: u64 = 0,
    };

    pub fn getUreg(c: *const Cpu, u: *vmm.Ureg) void {
        u.* = c.ureg;
    }
    pub fn setUreg(c: *Cpu, u: *const vmm.Ureg) void {
        c.ureg = u.*;
    }
    pub fn getExtra(_: *const Cpu, x: *vmm.Extra) vmm.Error!void {
        x.* = .{ .arm64 = .{} };
    }
    pub fn setExtra(_: *Cpu, _: *const vmm.Extra) vmm.Error!void {}

    pub fn run(c: *Cpu, ctx: *Ctx) vmm.Error!vmm.Exit {
        const tlb: *const mem.Tlb = @ptrFromInt(@as(usize, @intCast(ctx.tlb)));
        while (true) {
            if (@atomicLoad(u32, &ctx.exit_request, .monotonic) != 0) return .interrupted;
            const op = c.prog[c.pc];
            switch (op) {
                .load => |a| {
                    if (mem.fast(tlb, a, 8, false)) |h| {
                        c.r[0] = @atomicLoad(u64, @as(*const u64, @ptrFromInt(h)), .unordered);
                    } else {
                        if (mem.slowLoad(ctx, a, 3) != 0) return fault(ctx);
                        c.r[0] = ctx.scratch;
                    }
                },
                .store => |a| {
                    if (mem.fast(tlb, a, 8, true)) |h| {
                        @atomicStore(u64, @as(*u64, @ptrFromInt(h)), c.r[0], .unordered);
                    } else if (mem.slowStore(ctx, a, 3, c.r[0]) != 0) return fault(ctx);
                },
                .add => |n| c.r[0] +%= n,
                .again => {
                    c.pc = 0;
                    c.steps += 1;
                    continue;
                },
                .svc => {
                    c.pc += 1;
                    c.steps += 1;
                    return .syscall;
                },
                .flush => {
                    c.pc += 1;
                    c.steps += 1;
                    cache.Runtime.of(ctx).requestFlush();
                    return .interrupted;
                },
            }
            c.pc += 1;
            c.steps += 1;
        }
    }

    fn fault(ctx: *Ctx) vmm.Exit {
        const acc: mem.Access = @enumFromInt(@as(u8, @truncate(ctx.exit_info)));
        return .{ .fault = .{ .addr = ctx.exit_addr, .access = switch (acc) {
            .read => .read,
            .write => .write,
            .exec => .exec,
        }, .syndrome = ctx.exit_info } };
    }
};

const T = Emu(Toy, Toy);

test "applyTier sets a Guest's tier by name" {
    const G = struct {
        pub var tier: enum { t0, t1 } = .t0;
    };
    try testing.expect(applyTier(G, "t1"));
    try testing.expectEqual(.t1, G.tier);
    try testing.expect(!applyTier(G, "t2"));
    try testing.expectEqual(.t1, G.tier);
    try testing.expect(applyTier(struct {}, "t1"));
}

fn testBackend() !*T.EmuBackend {
    return T.EmuBackend.create(testing.allocator, testing.io, .{ .arch = .arm64, .memory = 64 << 20 });
}

test "address spaces: map, translate, copy, and unmap" {
    const b = try testBackend();
    defer b.destroy();
    const as = try b.newAddressSpace();
    defer as.destroy();
    const m = try b.allocPages(2);
    defer b.freePages(m);
    try as.map(0x10000, m, .{ .write = true });
    try testing.expectError(error.BadAddress, as.map(0x11000, m, .{}));
    try testing.expectError(error.BadAddress, as.map(0x10001, m, .{}));
    // Memory that isn't the backend's.
    var outside: [vmm.page_size]u8 align(vmm.page_size) = undefined;
    try testing.expectError(error.BadAddress, as.map(0x40000, &outside, .{}));
    try testing.expectError(error.BadAddress, as.map(0x40000, @as([*]align(vmm.page_size) u8, @ptrFromInt(vmm.page_size))[0..vmm.page_size], .{}));
    try testing.expect(as.translate(0x10ff8, 16) != null);
    try testing.expect(as.translate(0x11ff8, 16) == null);
    var buf: [4]u8 = .{ 1, 2, 3, 4 };
    try testing.expect(as.copy(0x11000, &buf, true));
    try testing.expectEqual(@as(u8, 3), m[0x1002]);
    as.unmap(0x10000);
    try testing.expect(as.translate(0x10000, 1) == null);
    try testing.expectError(error.WrongArch, T.EmuBackend.create(testing.allocator, testing.io, .{ .arch = .amd64 }));
}

test "vcpus: run through the view, fault exactly, and stop on a kick" {
    const b = try testBackend();
    defer b.destroy();
    const as = try b.newAddressSpace();
    defer as.destroy();
    const m = try b.allocPages(1);
    defer b.freePages(m);
    try as.map(0x10000, m, .{ .write = true });
    var v = try b.createVcpu();
    defer v.destroy();
    try testing.expectError(error.BadAddress, v.run());
    try v.setAddressSpace(as);
    const prog = [_]Toy.Op{ .{ .load = 0x10008 }, .{ .add = 5 }, .{ .store = 0x10008 }, .svc, .{ .store = 0x20000 } };
    v.s.cpu.arm64.prog = &prog;
    try testing.expectEqual(vmm.Exit.syscall, try v.run());
    try testing.expectEqual(@as(u8, 5), m[8]);
    // The store went through the TLB's write entry once filled.
    try testing.expect(mem.fast(&v.s.tlb, 0x10008, 8, true) != null);
    const e = try v.run();
    try testing.expectEqual(@as(u64, 0x20000), e.fault.addr);
    try testing.expect(e.fault.access == .write);
    // A kick before run.
    v.kick();
    try testing.expectEqual(vmm.Exit.interrupted, try v.run());
    try testing.expectEqual(@as(u32, 0), v.s.rt.ctx.exit_request);
    // Unmapping is seen at the next run, with the TLB flushed.
    v.s.cpu.arm64.pc = 0;
    as.unmap(0x10000);
    const e2 = try v.run();
    try testing.expectEqual(@as(u64, 0x10008), e2.fault.addr);
    try testing.expectEqual(@as(u64, 0), e2.fault.syndrome >> 8); // unmapped
}

/// A vCPU on its own thread, running `prog` until it exits with anything
/// but `.interrupted` or is told to stop.
const Runner = struct {
    v: T.EmuVcpu,
    exit: vmm.Exit = .halted,
    interrupts: u32 = 0,
    stop: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),

    fn main(r: *Runner) void {
        r.started.store(true, .release);
        while (true) {
            const e = r.v.run() catch |err| std.debug.panic("run: {t}", .{err});
            if (e == .interrupted) {
                r.interrupts += 1;
                if (r.stop.load(.acquire)) return;
                continue;
            }
            r.exit = e;
            return;
        }
    }
};

test "kick and shootdown with every vCPU running at once" {
    const b = try testBackend();
    defer b.destroy();
    const as = try b.newAddressSpace();
    defer as.destroy();
    const n = 4;
    const data = try b.allocPages(1);
    defer b.freePages(data);
    try as.map(0x10000, data, .{ .write = true });
    // Each vCPU counts in its own word, forever.
    var progs: [n][4]Toy.Op = undefined;
    var runners: [n]Runner = undefined;
    var threads: [n]std.Thread = undefined;
    for (0..n) |i| {
        const a = 0x10000 + 8 * i;
        progs[i] = .{ .{ .load = a }, .{ .add = 1 }, .{ .store = a }, .again };
        runners[i] = .{ .v = try b.createVcpu() };
        try runners[i].v.setAddressSpace(as);
        runners[i].v.s.cpu.arm64.prog = &progs[i];
    }
    defer for (&runners) |*r| r.v.destroy();
    for (0..n) |i| threads[i] = try std.Thread.spawn(.{}, Runner.main, .{&runners[i]});
    const words: *[n]u64 = @ptrCast(data[0 .. 8 * n]);
    // Every one is counting.
    for (0..n) |i| while (@atomicLoad(u64, &words[i], .monotonic) < 1000) std.atomic.spinLoopHint();
    // A kick makes run return; the runner goes straight back in.
    runners[0].v.kick();
    while (@atomicLoad(u32, &runners[0].interrupts, .monotonic) == 0) std.atomic.spinLoopHint();
    // Unmap the page under them. Once shootdown returns, no vCPU can still
    // store to it: each faults at its next access instead.
    as.unmap(0x10000);
    as.shootdown();
    var after: [n]u64 = undefined;
    for (0..n) |i| after[i] = @atomicLoad(u64, &words[i], .monotonic);
    for (&threads) |t| t.join();
    for (0..n) |i| {
        try testing.expectEqual(after[i], words[i]);
        try testing.expect(runners[i].exit == .fault);
        try testing.expectEqual(@as(u64, 0x10000 + 8 * i), runners[i].exit.fault.addr);
    }
}

test "a page that turns out to hold code loses every vCPU's write entries" {
    const b = try testBackend();
    defer b.destroy();
    const as = try b.newAddressSpace();
    defer as.destroy();
    const m = try b.allocPages(1);
    defer b.freePages(m);
    try as.map(0x10000, m, .{ .write = true, .exec = true });
    var v1 = try b.createVcpu();
    defer v1.destroy();
    var v2 = try b.createVcpu();
    defer v2.destroy();
    try v1.setAddressSpace(as);
    try v2.setAddressSpace(as);
    const prog = [_]Toy.Op{ .{ .store = 0x10010 }, .svc };
    v1.s.cpu.arm64.prog = &prog;
    try testing.expectEqual(vmm.Exit.syscall, try v1.run());
    try testing.expect(mem.fast(&v1.s.tlb, 0x10010, 8, true) != null);
    // v2 reads the page as code.
    v2.s.cpu.arm64.prog = &.{.svc};
    _ = try v2.run();
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), v2.s.view.fetch(0x10000, &buf));
    try testing.expect(mem.fast(&v1.s.tlb, 0x10010, 8, true) == null);
    // v1's next store takes the slow path, which drops the code.
    v1.s.cpu.arm64.pc = 0;
    try testing.expectEqual(vmm.Exit.syscall, try v1.run());
    try testing.expect(!b.code.isCode(b.code.pageOf(@intFromPtr(m.ptr)).?));
    // The host writing code drops it too.
    _ = v2.s.view.fetch(0x10000, &buf);
    const epoch = b.code.epoch.load(.monotonic);
    as.codeChanged(0x10000, 4);
    try testing.expect(b.code.epoch.load(.monotonic) != epoch);
}

test "a full cache is flushed with every other vCPU held out of guest code" {
    const b = try testBackend();
    defer b.destroy();
    const c = b.jit orelse return error.SkipZigTest;
    const as = try b.newAddressSpace();
    defer as.destroy();
    const data = try b.allocPages(1);
    defer b.freePages(data);
    try as.map(0x10000, data, .{ .write = true });
    const n = 4;
    var progs: [n][4]Toy.Op = undefined;
    var runners: [n]Runner = undefined;
    var threads: [n]std.Thread = undefined;
    for (0..n) |i| {
        const a = 0x10000 + 8 * i;
        progs[i] = .{ .{ .load = a }, .{ .add = 1 }, .{ .store = a }, .again };
        runners[i] = .{ .v = try b.createVcpu() };
        try runners[i].v.setAddressSpace(as);
        runners[i].v.s.cpu.arm64.prog = &progs[i];
    }
    defer for (&runners) |*r| r.v.destroy();
    for (0..n) |i| threads[i] = try std.Thread.spawn(.{}, Runner.main, .{&runners[i]});
    const words: *[n]u64 = @ptrCast(data[0 .. 8 * n]);
    for (0..n) |i| while (@atomicLoad(u64, &words[i], .monotonic) < 100) std.atomic.spinLoopHint();
    // A fifth vCPU asks for flushes, round after round, while the others
    // keep counting. flushCache asserts that none of them is in guest code
    // when the cache is reset.
    var v = try b.createVcpu();
    defer v.destroy();
    try v.setAddressSpace(as);
    const prog = [_]Toy.Op{ .flush, .svc };
    v.s.cpu.arm64.prog = &prog;
    for (0..50) |_| {
        v.s.cpu.arm64.pc = 0;
        try testing.expectEqual(vmm.Exit.syscall, try v.run());
    }
    try testing.expectEqual(@as(u64, 50), c.flushes);
    // Everyone is still counting.
    var before: [n]u64 = undefined;
    for (0..n) |i| before[i] = @atomicLoad(u64, &words[i], .monotonic);
    for (0..n) |i| while (@atomicLoad(u64, &words[i], .monotonic) == before[i]) std.atomic.spinLoopHint();
    for (&runners) |*r| {
        r.stop.store(true, .release);
        r.v.kick();
    }
    for (&threads) |t| t.join();
}
