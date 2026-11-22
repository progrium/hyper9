//! Guest-physical memory for the hypervisor backends (HVF, KVM, WHP) and
//! the native backend: one RAM region, mapped into the VM once at `base`,
//! handed out in 4K pages for user pages, page tables and shared pages
//! alike, first-fit from a list of freed ranges and otherwise from the end.
//!
//! The host backs the region's pages only once they're touched, and freed
//! memory goes back to it. Each free range keeps the span of it that may
//! be dirty; once that span reaches `release_min`, it's released
//! (`Release`), and its pages read as zero, unbacked, until they're used
//! again. A smaller dirty span stays, and what's handed out of it is
//! zeroed then, so a program that frees and reallocates a little at a time
//! doesn't pay a syscall and a refault for each. Never-used pages and
//! released ones are already zero, so handing them out doesn't touch them.
//!
//! Also the address space the backends share: user mappings over page
//! tables of one of the `pt_*.zig` formats, which supply `mapPage`,
//! `unmapPage`, `newRoot`, `freeRoot` and `userAttrs`.

const std = @import("std");
const builtin = @import("builtin");
const vmm = @import("../vmm.zig");

const is_windows = builtin.os.tag == .windows;

/// The most ASIDs a page-table format may ask for.
const max_asids = 256;

pub const Ram = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Guest-physical address of `mem[0]`.
    base: u64,
    mem: []align(std.heap.page_size_min) u8,
    /// Pages past `next` aren't handed out.
    next: usize = 0,
    /// The span at or past `next` that may be dirty: pages freed from the
    /// end without being released. Past it they're zero.
    tail: Span = .{},
    /// Freed ranges below `next`, sorted and coalesced.
    free: std.ArrayList(Range) = .empty,
    /// How freed memory goes back to the host.
    release: Release = .anon,
    /// Where the usable region ends: `mem.len`, unless a release at the
    /// end lost the pages past it.
    end: ?usize = null,
    /// Root tables kept for reuse as roots only, by formats that need a
    /// dead root to stay one (pt_amd64.zig).
    spare_roots: std.ArrayList(u64) = .empty,
    lock: std.Io.Mutex = .init,
    /// ASIDs in use, for formats that tag TLB entries with one
    /// (pt_arm64.zig's `asids`); 0 is never handed out.
    asid_used: std.bit_set.StaticBitSet(max_asids) = .initEmpty(),
    /// Where the next ASID search starts: ASIDs go round, so a freed one
    /// is handed out again only after the others have been.
    asid_next: usize = 1,
    /// Bumped each time the search wraps, and so before any ASID is used
    /// again: a vCPU that sees it change flushes its TLB before it runs.
    asid_gen: std.atomic.Value(u64) = .init(0),
    /// The backend's vCPUs, for `AddressSpace.shootdown`.
    runners: Runners = .{},

    /// A free range, and the span of it that may be dirty: every byte
    /// outside `dirty` is zero.
    const Range = struct { off: usize, len: usize, dirty: Span = .{} };

    /// Offsets [lo, hi), empty when lo >= hi.
    const Span = struct {
        lo: usize = 0,
        hi: usize = 0,

        fn empty(x: Span) bool {
            return x.lo >= x.hi;
        }

        fn len(x: Span) usize {
            return if (x.empty()) 0 else x.hi - x.lo;
        }

        /// The smallest span covering both.
        fn join(x: Span, y: Span) Span {
            if (x.empty()) return y;
            if (y.empty()) return x;
            return .{ .lo = @min(x.lo, y.lo), .hi = @max(x.hi, y.hi) };
        }

        /// The part of `x` at or past `at`.
        fn from(x: Span, at: usize) Span {
            const y: Span = .{ .lo = @max(x.lo, at), .hi = x.hi };
            return if (y.empty()) .{} else y;
        }

        /// The part of `x` within [lo, hi).
        fn within(x: Span, lo: usize, hi: usize) Span {
            const y: Span = .{ .lo = @max(x.lo, lo), .hi = @min(x.hi, hi) };
            return if (y.empty()) .{} else y;
        }
    };

    /// Free memory that may be dirty is released to the host once a free
    /// range (or the free end of the region) holds this much.
    pub const release_min: usize = 32 << 20;

    /// How a range of the region goes back to the host. Each way leaves
    /// the range reading as zero, with no host memory behind it until it's
    /// touched.
    pub const Release = union(enum) {
        /// Private anonymous memory (KVM): madvise(MADV_DONTNEED), on Linux
        /// only; elsewhere it's kept, and zeroed by the caller.
        anon,
        /// A shared memory file mapped at `mem` (native): its pages are
        /// punched out of the file, so every mapping of them goes.
        memfd: i32,
        /// The backend's own, for memory mapped into the VM by host
        /// address (HVF, WHP): `f` gets the range as offsets in `mem`,
        /// aligned to the host's page size. It returns `.kept` if nothing
        /// changed (the caller zeroes the range itself), and `.lost` if
        /// the range can no longer be used, which then is never handed out
        /// again.
        custom: struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, off: usize, len: usize) Outcome },
        /// Freed memory is zeroed by hand, never released.
        none,

        pub const Outcome = enum { released, kept, lost };
    };

    /// Reserves the region for a memory cap of `want` bytes (null for the
    /// default). The caller maps `mem` into the VM at `base`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, base: u64, want: ?u64) vmm.Error!Ram {
        const size = want orelse vmm.default_memory;
        if (size > vmm.max_memory) return error.OutOfGuestMemory;
        const len = std.mem.alignForward(usize, @intCast(size), vmm.page_size);
        if (len < 16 * vmm.page_size) return error.OutOfGuestMemory;
        // Zeroed either way: fresh anonymous pages, or VirtualAlloc's.
        const mem = if (is_windows)
            // rawAlloc, not alignedAlloc, which fills the region with
            // undefined (0xaa) in safe builds and so dirties every page.
            @as([*]align(std.heap.page_size_min) u8, @alignCast(std.heap.page_allocator.rawAlloc(len, .fromByteUnits(std.heap.page_size_min), @returnAddress()) orelse
                return error.OutOfGuestMemory))[0..len]
        else
            std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch
                return error.OutOfGuestMemory;
        return .{ .gpa = gpa, .io = io, .base = base, .mem = mem };
    }

    pub fn deinit(r: *Ram) void {
        // rawFree, as free would fill every page with undefined first.
        if (is_windows) std.heap.page_allocator.rawFree(r.mem, .fromByteUnits(std.heap.page_size_min), @returnAddress()) else std.posix.munmap(r.mem);
        r.free.deinit(r.gpa);
        r.spare_roots.deinit(r.gpa);
    }

    /// Returns zeroed pages backed by guest-physical memory.
    pub fn allocPages(r: *Ram, n: usize) vmm.Error![]align(vmm.page_size) u8 {
        const len = n * vmm.page_size;
        if (len == 0) return error.BadAddress;
        // The part that may be dirty: zeroed outside the lock.
        var z: Span = .{};
        const off = blk: {
            r.lock.lockUncancelable(r.io);
            defer r.lock.unlock(r.io);
            for (r.free.items, 0..) |*f, i| if (f.len >= len) {
                const off = f.off;
                z = f.dirty.within(off, off + len);
                f.off += len;
                f.len -= len;
                f.dirty = f.dirty.from(f.off);
                if (f.len == 0) _ = r.free.orderedRemove(i);
                break :blk off;
            };
            if (r.next + len > (r.end orelse r.mem.len)) return error.OutOfGuestMemory;
            const off = r.next;
            r.next += len;
            z = r.tail.within(off, r.next);
            r.tail = r.tail.from(r.next);
            break :blk off;
        };
        if (!z.empty()) @memset(r.mem[z.lo..z.hi], 0);
        return @alignCast(r.mem[off..][0..len]);
    }

    /// Returns pages from `allocPages` (all of them, or any page-aligned
    /// part). They must no longer be mapped anywhere.
    pub fn freePages(r: *Ram, mem: []align(vmm.page_size) u8) void {
        if (mem.len == 0) return;
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        r.freeLocked(@intFromPtr(mem.ptr) - @intFromPtr(r.mem.ptr), mem.len);
    }

    fn freeLocked(r: *Ram, off: usize, len: usize) void {
        var i: usize = 0;
        while (i < r.free.items.len and r.free.items[i].off < off) i += 1;
        var f: Range = .{ .off = off, .len = len, .dirty = .{ .lo = off, .hi = off + len } };
        if (i < r.free.items.len and f.off + f.len == r.free.items[i].off) {
            f.len += r.free.items[i].len;
            f.dirty = f.dirty.join(r.free.items[i].dirty);
            _ = r.free.orderedRemove(i);
        }
        if (i > 0 and r.free.items[i - 1].off + r.free.items[i - 1].len == f.off) {
            i -= 1;
            f.off = r.free.items[i].off;
            f.len += r.free.items[i].len;
            f.dirty = f.dirty.join(r.free.items[i].dirty);
            _ = r.free.orderedRemove(i);
        }
        if (f.off + f.len == r.next) {
            r.next = f.off;
            const d = r.tail.join(f.dirty);
            r.tail = d;
            if (d.len() >= release_min) {
                r.tail = .{};
                // Lost: nothing past it can be handed out again, so the
                // end of the region stops there.
                if (!r.releaseLocked(d.lo, d.len())) r.end = d.lo;
            }
            return;
        }
        if (f.dirty.len() >= release_min) {
            // Lost: the range is never handed out again.
            if (!r.releaseLocked(f.dirty.lo, f.dirty.len())) return;
            f.dirty = .{};
        }
        // On allocation failure the range is lost, which is only a leak.
        r.free.insert(r.gpa, i, f) catch {};
    }

    /// Gives [off, off+len) back to the host, which leaves it zero. The
    /// parts of host pages at either end (16K on Apple silicon, larger
    /// than the guest's) are zeroed by hand, as is all of it if the host
    /// keeps it. Returns false if the range is lost.
    fn releaseLocked(r: *Ram, off: usize, len: usize) bool {
        const hp = std.heap.pageSize();
        const base = @intFromPtr(r.mem.ptr);
        const lo = std.mem.alignForward(usize, base + off, hp) - base;
        const hi = std.mem.alignBackward(usize, base + off + len, hp) - base;
        if (hi <= lo) {
            @memset(r.mem[off..][0..len], 0);
            return true;
        }
        @memset(r.mem[off..lo], 0);
        @memset(r.mem[hi .. off + len], 0);
        switch (releaseHost(r.release, r.mem, lo, hi - lo)) {
            .released => {},
            .kept => @memset(r.mem[lo..hi], 0),
            .lost => return false,
        }
        return true;
    }

    /// The guest-physical address of host memory in the region.
    pub fn gpaOf(r: *const Ram, mem: []const u8) u64 {
        return r.base + (@intFromPtr(mem.ptr) - @intFromPtr(r.mem.ptr));
    }

    /// The page at guest-physical `pa`.
    pub fn page(r: *const Ram, pa: u64) *align(vmm.page_size) [vmm.page_size]u8 {
        return @alignCast(r.mem[pa - r.base ..][0..vmm.page_size]);
    }

    /// The page table at guest-physical `pa`.
    pub fn table(r: *const Ram, pa: u64) *[512]u64 {
        return @ptrCast(r.page(pa));
    }

    /// A zeroed page for a table; returns its guest-physical address.
    pub fn allocTable(r: *Ram) vmm.Error!u64 {
        return r.gpaOf(try r.allocPages(1));
    }

    pub fn freeTable(r: *Ram, pa: u64) void {
        r.freePages(r.page(pa));
    }

    /// Keeps a root table for `takeRoot`. On allocation failure it's
    /// leaked rather than freed.
    pub fn keepRoot(r: *Ram, pa: u64) void {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        r.spare_roots.append(r.gpa, pa) catch {};
    }

    /// A free ASID below `n`, or 0 (shared, flushed on every entry) if
    /// there's none.
    ///
    /// A reused ASID can still tag entries from its last owner on some
    /// host CPU, and the flush a vCPU does when it switches spaces didn't
    /// reliably remove them on arm64 KVM: a process went on to use the
    /// last owner's translations (a forked rc returned through a freed
    /// heap word, 0xcafebabe). So, as Linux does on an ASID rollover,
    /// reuse waits for the search to wrap, and the wrap makes every vCPU
    /// flush before it runs again (`asid_gen`).
    pub fn allocAsid(r: *Ram, n: usize) u16 {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        const top = @min(n, max_asids);
        if (top <= 1) return 0;
        if (r.asid_next >= top) {
            r.asid_next = 1;
            _ = r.asid_gen.fetchAdd(1, .seq_cst);
        }
        var i = r.asid_next;
        var tried: usize = 0;
        while (tried < top - 1) : (tried += 1) {
            if (!r.asid_used.isSet(i)) {
                r.asid_used.set(i);
                r.asid_next = i + 1;
                return @intCast(i);
            }
            i += 1;
            if (i >= top) {
                i = 1;
                _ = r.asid_gen.fetchAdd(1, .seq_cst);
            }
        }
        return 0;
    }

    pub fn freeAsid(r: *Ram, a: u16) void {
        if (a == 0) return;
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        r.asid_used.unset(a);
    }

    pub fn takeRoot(r: *Ram) ?u64 {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        return r.spare_roots.pop();
    }
};

fn releaseHost(how: Ram.Release, mem: []u8, off: usize, len: usize) Ram.Release.Outcome {
    switch (how) {
        .none => return .kept,
        .custom => |c| return c.f(c.ctx, off, len),
        .anon => {
            // Only Linux's MADV_DONTNEED zeroes private anonymous pages;
            // macOS's leaves them as they were.
            if (builtin.os.tag != .linux) return .kept;
            const p: [*]align(std.heap.page_size_min) u8 = @alignCast(mem.ptr + off);
            std.posix.madvise(p, len, std.posix.MADV.DONTNEED) catch return .kept;
            return .released;
        },
        .memfd => |fd| {
            if (builtin.os.tag != .linux) return .kept;
            const linux = std.os.linux;
            const FALLOC_FL_KEEP_SIZE = 0x01;
            const FALLOC_FL_PUNCH_HOLE = 0x02;
            const rc = linux.fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, @intCast(off), @intCast(len));
            return if (linux.errno(rc) == .SUCCESS) .released else .kept;
        },
    }
}

/// One process's address space over page tables of format `pt`.
/// What each of a backend's vCPUs is running, so an `unmap` can wait until
/// none still reaches the pages it removed (design/epoch-0/linux-threads.md,
/// "TLB shootdown"). A vCPU takes a slot when it's made, says which space
/// it's entering before it reads the space's epoch, and counts each run
/// as it leaves. Everything is sequentially consistent, so a vCPU that
/// enters after a shootdown has looked reads the epoch `unmap` bumped.
pub const Runners = struct {
    /// One bit per slot, in words of 64.
    taken: [words]std.atomic.Value(u64) = @splat(.init(0)),
    slots: [capacity]Slot = @splat(.{}),

    /// As many vCPUs as any backend runs at once: KVM's limit is capped
    /// at this (kvm.zig's max_slots), HVF's and WHP's are 64.
    pub const capacity = 1024;
    const words = capacity / 64;

    pub const Index = std.math.IntFittingRange(0, capacity - 1);

    const Slot = struct {
        as: std.atomic.Value(?*const anyopaque) = .init(null),
        runs: std.atomic.Value(u64) = .init(0),
        /// The backend's kick for this vCPU, and its argument.
        kick: ?*const fn (u64) void = null,
        arg: u64 = 0,
    };

    pub fn take(rs: *Runners, kick: *const fn (u64) void, arg: u64) vmm.CreateError!Index {
        for (&rs.taken, 0..) |*w, wi| while (true) {
            const t = w.load(.seq_cst);
            if (t == std.math.maxInt(u64)) break;
            const b: u6 = @intCast(@ctz(~t));
            if (w.cmpxchgWeak(t, t | (@as(u64, 1) << b), .seq_cst, .seq_cst) == null) {
                const i: Index = @intCast(wi * 64 + b);
                rs.slots[i].kick = kick;
                rs.slots[i].arg = arg;
                return i;
            }
        };
        return error.HypervisorFailed;
    }

    /// Sets the argument once the vCPU's own handle exists.
    pub fn setArg(rs: *Runners, i: Index, arg: u64) void {
        rs.slots[i].arg = arg;
    }

    pub fn release(rs: *Runners, i: Index) void {
        rs.slots[i].as.store(null, .seq_cst);
        _ = rs.taken[i / 64].fetchAnd(~(@as(u64, 1) << @intCast(i % 64)), .seq_cst);
    }

    /// Call before reading the space's epoch for a run.
    pub fn enter(rs: *Runners, i: Index, as: *const anyopaque) void {
        rs.slots[i].as.store(as, .seq_cst);
    }

    /// Call once the hypervisor's run has returned.
    pub fn leave(rs: *Runners, i: Index) void {
        _ = rs.slots[i].runs.fetchAdd(1, .seq_cst);
        rs.slots[i].as.store(null, .seq_cst);
    }

    /// Kicks every vCPU running `as` and waits until each has left its
    /// run; the next one flushes its TLB first. Slots go 64 at a time, so
    /// the wait list stays small on the stack.
    fn shootdown(rs: *Runners, as: *const anyopaque) void {
        for (0..words) |wi| {
            if (rs.taken[wi].load(.seq_cst) == 0) continue;
            var wait: [64]struct { i: Index, runs: u64 } = undefined;
            var n: usize = 0;
            for (rs.slots[wi * 64 ..][0..64], wi * 64..) |*sl, i| {
                if (sl.as.load(.seq_cst) != as) continue;
                const runs = sl.runs.load(.seq_cst);
                // Checked again: it may have finished that run already.
                if (sl.as.load(.seq_cst) != as) continue;
                if (sl.kick) |k| k(sl.arg);
                wait[n] = .{ .i = @intCast(i), .runs = runs };
                n += 1;
            }
            for (wait[0..n]) |w| {
                const sl = &rs.slots[w.i];
                while (sl.as.load(.seq_cst) == as and sl.runs.load(.seq_cst) == w.runs) std.atomic.spinLoopHint();
            }
        }
    }
};

pub fn AddressSpace(comptime pt: type) type {
    return struct {
        const Self = @This();

        ram: *Ram,
        /// The root table's guest-physical address (TTBR0, CR3).
        root: u64,
        /// Unique for the backend's life, so a vCPU can tell a new space at
        /// a reused address from the one it last ran.
        id: u64,
        /// The space's ASID (pt_arm64.zig's `asids`), or 0: shared, so a
        /// vCPU flushes its TLB every time it enters the space.
        asid: u16 = 0,
        /// Bumped by `unmap`, so vCPUs that ran this space flush their TLBs.
        epoch: std.atomic.Value(u64) = .init(0),
        lock: std.atomic.Mutex = .unlocked,
        /// Sorted by va and disjoint, so lookups are binary searches: a
        /// Linux process can have thousands of mappings, and a linear scan
        /// per map made allocation-heavy programs quadratic.
        regions: std.ArrayList(Region) = .empty,

        const Region = struct { va: u64, mem: []u8 };

        /// The number of regions that start at or below `va`.
        fn upperBound(as: *const Self, va: u64) usize {
            var lo: usize = 0;
            var hi: usize = as.regions.items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (as.regions.items[mid].va <= va) lo = mid + 1 else hi = mid;
            }
            return lo;
        }

        /// The region holding `va`, if one does.
        fn find(as: *const Self, va: u64) ?Region {
            const i = as.upperBound(va);
            if (i == 0) return null;
            const g = as.regions.items[i - 1];
            return if (va - g.va <= g.mem.len) g else null;
        }

        /// `kernel_root` is the kernel half's root, for formats whose user
        /// and kernel halves share one root table.
        pub fn create(ram: *Ram, id: u64, kernel_root: u64) vmm.CreateError!*Self {
            const as = try ram.gpa.create(Self);
            errdefer ram.gpa.destroy(as);
            as.* = .{ .ram = ram, .root = try pt.newRoot(ram, kernel_root), .id = id };
            // A recycled ASID may still tag the last owner's entries: a
            // vCPU switching to this space flushes before it runs (the
            // shim's flush), which removes them everywhere.
            if (@hasDecl(pt, "asids")) as.asid = ram.allocAsid(pt.asids);
            return as;
        }

        fn lockSpin(as: *Self) void {
            while (!as.lock.tryLock()) std.atomic.spinLoopHint();
        }

        /// Maps backend-allocated memory at a page-aligned user address.
        pub fn map(as: *Self, va: u64, mem: []align(vmm.page_size) u8, perms: vmm.Perms) vmm.CreateError!void {
            if (va % vmm.page_size != 0 or mem.len % vmm.page_size != 0 or mem.len == 0) return error.BadAddress;
            if (va >= pt.user_top or mem.len > pt.user_top - va) return error.BadAddress;
            const r = as.ram;
            as.lockSpin();
            defer as.lock.unlock();
            const at = as.upperBound(va);
            if (at > 0) {
                const g = as.regions.items[at - 1];
                if (va < g.va + g.mem.len) return error.BadAddress;
            }
            if (at < as.regions.items.len and as.regions.items[at].va < va + mem.len) return error.BadAddress;
            try as.regions.ensureUnusedCapacity(r.gpa, 1);
            const pa = r.gpaOf(mem);
            var off: u64 = 0;
            while (off < mem.len) : (off += vmm.page_size) {
                pt.mapPage(r, as.root, va + off, pa + off, pt.userAttrs(perms)) catch |e| {
                    var u: u64 = 0;
                    while (u < off) : (u += vmm.page_size) pt.unmapPage(r, as.root, va + u);
                    return e;
                };
            }
            as.regions.insertAssumeCapacity(at, .{ .va = va, .mem = mem });
        }

        /// Removes the mapping made by `map` at `va`. The pages stay allocated.
        pub fn unmap(as: *Self, va: u64) void {
            as.lockSpin();
            defer as.lock.unlock();
            const i = as.upperBound(va);
            if (i == 0) return;
            const g = as.regions.items[i - 1];
            if (g.va != va) return;
            var off: u64 = 0;
            while (off < g.mem.len) : (off += vmm.page_size) pt.unmapPage(as.ram, as.root, va + off);
            _ = as.regions.orderedRemove(i - 1);
            _ = as.epoch.fetchAdd(1, .seq_cst);
        }

        /// Returns once no vCPU other than the caller's can still reach
        /// what `unmap` removed: see `Runners`.
        pub fn shootdown(as: *Self) void {
            as.ram.runners.shootdown(as);
        }

        /// Host view of [va, va+len) if it lies within one mapping.
        pub fn translate(as: *Self, va: u64, len: u64) ?[]u8 {
            as.lockSpin();
            defer as.lock.unlock();
            const g = as.find(va) orelse return null;
            if (len > g.mem.len - (va - g.va)) return null;
            return g.mem[va - g.va ..][0..len];
        }

        /// `translate` and a copy under the lock; see vmm.AddressSpace.copy.
        pub fn copy(as: *Self, va: u64, buf: []u8, write: bool) bool {
            as.lockSpin();
            defer as.lock.unlock();
            const g = as.find(va) orelse return false;
            if (buf.len > g.mem.len - (va - g.va)) return false;
            const mem = g.mem[va - g.va ..][0..buf.len];
            if (write) @memcpy(mem, buf) else @memcpy(buf, mem);
            return true;
        }

        /// The host wrote code: vCPUs that ran this space flush their TLB
        /// and I-cache (the shim's flush) before their next run, as after
        /// an unmap.
        pub fn codeChanged(as: *Self, _: u64, _: u64) void {
            _ = as.epoch.fetchAdd(1, .release);
        }

        /// Frees the page tables; the mapped pages belong to the caller.
        pub fn destroy(as: *Self) void {
            pt.freeRoot(as.ram, as.root);
            as.ram.freeAsid(as.asid);
            as.regions.deinit(as.ram.gpa);
            as.ram.gpa.destroy(as);
        }
    };
}

fn noKick(_: u64) void {}

test "Runners has a slot for every vCPU KVM allows, past the first 64" {
    const rs = try std.testing.allocator.create(Runners);
    defer std.testing.allocator.destroy(rs);
    rs.* = .{};
    for (0..Runners.capacity) |i| try std.testing.expectEqual(@as(Runners.Index, @intCast(i)), try rs.take(noKick, 0));
    try std.testing.expectError(error.HypervisorFailed, rs.take(noKick, 0));
    rs.release(70);
    try std.testing.expectEqual(@as(Runners.Index, 70), try rs.take(noKick, 0));
    // A shootdown waits only for slots running the space.
    var as: u8 = 0;
    rs.enter(130, &as);
    rs.leave(130);
    rs.shootdown(&as);
}

test "Ram: a big free goes back to the host and reads as zero; a small one is zeroed on reuse" {
    // `.anon` releases on Linux only.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Ram = try .init(std.testing.allocator, std.testing.io, 0, 128 << 20);
    defer r.deinit();
    const Count = struct {
        var n: usize = 0;
        var bytes: usize = 0;
        fn f(ctx: *anyopaque, off: usize, len: usize) Ram.Release.Outcome {
            const rr: *Ram = @ptrCast(@alignCast(ctx));
            n += 1;
            bytes += len;
            return releaseHost(.anon, rr.mem, off, len);
        }
    };
    r.release = .{ .custom = .{ .ctx = &r, .f = Count.f } };
    const pages = Ram.release_min / vmm.page_size;

    // A small free in the middle stays dirty, and is zeroed when handed out.
    const a = try r.allocPages(4);
    const b = try r.allocPages(1);
    @memset(a, 0xaa);
    r.freePages(a);
    try std.testing.expectEqual(0, Count.n);
    const a2 = try r.allocPages(4);
    try std.testing.expectEqual(a.ptr, a2.ptr);
    for (a2) |x| try std.testing.expectEqual(0, x);

    // A big one is released, and later handed out without being written.
    const big = try r.allocPages(pages);
    const c = try r.allocPages(1);
    @memset(big, 0xbb);
    r.freePages(big);
    try std.testing.expectEqual(1, Count.n);
    try std.testing.expect(r.free.items[0].dirty.empty());
    const big2 = try r.allocPages(pages);
    try std.testing.expectEqual(big.ptr, big2.ptr);
    for (big2) |x| try std.testing.expectEqual(0, x);

    // Small frees add up: the range goes once its dirty span reaches the minimum.
    r.freePages(big2[0 .. big2.len / 2]);
    try std.testing.expectEqual(1, Count.n);
    r.freePages(@alignCast(big2[big2.len / 2 ..]));
    try std.testing.expectEqual(2, Count.n);

    // Freeing the end of the region moves `next` back, and releases what
    // was there once it's big enough; a small dirty end stays dirty.
    r.freePages(c);
    try std.testing.expectEqual(5 * vmm.page_size, r.next);
    try std.testing.expectEqual(2, Count.n);
    try std.testing.expectEqual(vmm.page_size, r.tail.len());
    r.freePages(a2);
    r.freePages(b);
    try std.testing.expectEqual(0, r.next);
    try std.testing.expectEqual(0, r.free.items.len);
    try std.testing.expectEqual(3, Count.n);
    try std.testing.expect(r.tail.empty());
    const all = try r.allocPages(pages + 6);
    for (all) |x| try std.testing.expectEqual(0, x);
}

test "Ram: a small free at the end is zeroed when the end is handed out again" {
    var r: Ram = try .init(std.testing.allocator, std.testing.io, 0, 1 << 20);
    defer r.deinit();
    r.release = .none;
    const a = try r.allocPages(2);
    @memset(a, 0xcc);
    r.freePages(a);
    try std.testing.expectEqual(0, r.next);
    const b = try r.allocPages(3);
    for (b) |x| try std.testing.expectEqual(0, x);
}

test "Ram: a lost range is never handed out again" {
    var r: Ram = try .init(std.testing.allocator, std.testing.io, 0, 2 * Ram.release_min);
    defer r.deinit();
    const Lose = struct {
        fn f(_: *anyopaque, _: usize, _: usize) Ram.Release.Outcome {
            return .lost;
        }
    };
    r.release = .{ .custom = .{ .ctx = &r, .f = Lose.f } };
    const pages = Ram.release_min / vmm.page_size;
    const a = try r.allocPages(pages);
    const b = try r.allocPages(1);
    r.freePages(a);
    try std.testing.expectEqual(0, r.free.items.len);
    r.freePages(b);
    try std.testing.expectEqual(0, r.free.items.len);
    try std.testing.expect((try r.allocPages(1)).ptr != a.ptr);
}

test "Ram: a range lost at the end ends the region there" {
    var r: Ram = try .init(std.testing.allocator, std.testing.io, 0, 2 * Ram.release_min);
    defer r.deinit();
    const Lose = struct {
        fn f(_: *anyopaque, _: usize, _: usize) Ram.Release.Outcome {
            return .lost;
        }
    };
    r.release = .{ .custom = .{ .ctx = &r, .f = Lose.f } };
    r.freePages(try r.allocPages(Ram.release_min / vmm.page_size));
    try std.testing.expectError(error.OutOfGuestMemory, r.allocPages(1));
}

test "Ram: handing out released pages leaves them unbacked, beside a small dirty span" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Ram = try .init(std.testing.allocator, std.testing.io, 0, 128 << 20);
    defer r.deinit();
    const n = 2 * Ram.release_min / vmm.page_size;
    const big = try r.allocPages(n);
    const guard = try r.allocPages(1);
    defer r.freePages(guard);
    @memset(big, 0xdd);
    r.freePages(big);
    const one = try r.allocPages(1);
    @memset(one, 0xee);
    r.freePages(one);
    const again = try r.allocPages(n);
    try std.testing.expectEqual(big.ptr, again.ptr);
    var vec: [n]u8 = undefined;
    try std.posix.mincore(again.ptr, again.len, &vec);
    var resident: usize = 0;
    for (vec) |v| resident += v & 1;
    // Only the dirty page was written, to zero it.
    try std.testing.expect(resident <= 1);
    try std.testing.expectEqual(0, again[0]);
    try std.testing.expectEqual(0, again[again.len - 1]);
}
