//! Guest-physical memory for the hypervisor backends (HVF, KVM, WHP): one RAM
//! region, mapped into the VM once at `base`, handed out in 4K pages for
//! user pages, page tables and shared pages alike, first-fit from a list of
//! freed ranges and otherwise from the end.
//!
//! Also the address space the backends share: user mappings over page
//! tables of one of the `pt_*.zig` formats, which supply `mapPage`,
//! `unmapPage`, `newRoot`, `freeRoot` and `userAttrs`.

const std = @import("std");
const builtin = @import("builtin");
const vmm = @import("../vmm.zig");

const is_windows = builtin.os.tag == .windows;

pub const Ram = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Guest-physical address of `mem[0]`.
    base: u64,
    mem: []align(std.heap.page_size_min) u8,
    /// Pages past `next` have never been handed out.
    next: usize = 0,
    /// Freed ranges below `next`, sorted and coalesced.
    free: std.ArrayList(Range) = .empty,
    /// Root tables kept for reuse as roots only, by formats that need a
    /// dead root to stay one (pt_amd64.zig).
    spare_roots: std.ArrayList(u64) = .empty,
    lock: std.Io.Mutex = .init,
    /// The backend's vCPUs, for `AddressSpace.shootdown`.
    runners: Runners = .{},

    const Range = struct { off: usize, len: usize };

    /// Reserves the region for a memory cap of `want` bytes (null for the
    /// default). The caller maps `mem` into the VM at `base`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, base: u64, want: ?u64) vmm.Error!Ram {
        const size = want orelse vmm.default_memory;
        if (size > vmm.max_memory) return error.OutOfGuestMemory;
        const len = std.mem.alignForward(usize, @intCast(size), vmm.page_size);
        if (len < 16 * vmm.page_size) return error.OutOfGuestMemory;
        // Zeroed either way: fresh anonymous pages, or VirtualAlloc's.
        const mem = if (is_windows)
            std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), len) catch
                return error.OutOfGuestMemory
        else
            std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch
                return error.OutOfGuestMemory;
        return .{ .gpa = gpa, .io = io, .base = base, .mem = mem };
    }

    pub fn deinit(r: *Ram) void {
        if (is_windows) std.heap.page_allocator.free(r.mem) else std.posix.munmap(r.mem);
        r.free.deinit(r.gpa);
        r.spare_roots.deinit(r.gpa);
    }

    /// Returns zeroed pages backed by guest-physical memory.
    pub fn allocPages(r: *Ram, n: usize) vmm.Error![]align(vmm.page_size) u8 {
        const len = n * vmm.page_size;
        if (len == 0) return error.BadAddress;
        const off = blk: {
            r.lock.lockUncancelable(r.io);
            defer r.lock.unlock(r.io);
            for (r.free.items, 0..) |*f, i| if (f.len >= len) {
                const off = f.off;
                f.off += len;
                f.len -= len;
                if (f.len == 0) _ = r.free.orderedRemove(i);
                break :blk off;
            };
            if (r.next + len > r.mem.len) return error.OutOfGuestMemory;
            r.next += len;
            break :blk r.next - len;
        };
        const mem: []align(vmm.page_size) u8 = @alignCast(r.mem[off..][0..len]);
        // Freed pages are dirty; never-used ones are already zero.
        @memset(mem, 0);
        return mem;
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
        var f: Range = .{ .off = off, .len = len };
        if (i < r.free.items.len and f.off + f.len == r.free.items[i].off) {
            f.len += r.free.items[i].len;
            _ = r.free.orderedRemove(i);
        }
        if (i > 0 and r.free.items[i - 1].off + r.free.items[i - 1].len == f.off) {
            i -= 1;
            f.off = r.free.items[i].off;
            f.len += r.free.items[i].len;
            _ = r.free.orderedRemove(i);
        }
        if (f.off + f.len == r.next) {
            r.next = f.off;
            return;
        }
        // On allocation failure the range is lost, which is only a leak.
        r.free.insert(r.gpa, i, f) catch {};
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

    pub fn takeRoot(r: *Ram) ?u64 {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        return r.spare_roots.pop();
    }
};

/// One process's address space over page tables of format `pt`.
/// What each of a backend's vCPUs is running, so an `unmap` can wait until
/// none still reaches the pages it removed (design/0049-linux-threads.md,
/// "TLB shootdown"). A vCPU takes a slot when it's made, says which space
/// it's entering before it reads the space's epoch, and counts each run
/// as it leaves. Everything is sequentially consistent, so a vCPU that
/// enters after a shootdown has looked reads the epoch `unmap` bumped.
pub const Runners = struct {
    taken: std.atomic.Value(u64) = .init(0),
    slots: [64]Slot = @splat(.{}),

    pub const Index = u6;

    const Slot = struct {
        as: std.atomic.Value(?*const anyopaque) = .init(null),
        runs: std.atomic.Value(u64) = .init(0),
        /// The backend's kick for this vCPU, and its argument.
        kick: ?*const fn (u64) void = null,
        arg: u64 = 0,
    };

    pub fn take(rs: *Runners, kick: *const fn (u64) void, arg: u64) vmm.CreateError!Index {
        while (true) {
            const t = rs.taken.load(.seq_cst);
            if (t == std.math.maxInt(u64)) return error.HypervisorFailed;
            const i: Index = @intCast(@ctz(~t));
            if (rs.taken.cmpxchgWeak(t, t | (@as(u64, 1) << i), .seq_cst, .seq_cst) == null) {
                rs.slots[i].kick = kick;
                rs.slots[i].arg = arg;
                return i;
            }
        }
    }

    /// Sets the argument once the vCPU's own handle exists.
    pub fn setArg(rs: *Runners, i: Index, arg: u64) void {
        rs.slots[i].arg = arg;
    }

    pub fn release(rs: *Runners, i: Index) void {
        rs.slots[i].as.store(null, .seq_cst);
        _ = rs.taken.fetchAnd(~(@as(u64, 1) << i), .seq_cst);
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
    /// run; the next one flushes its TLB first.
    fn shootdown(rs: *Runners, as: *const anyopaque) void {
        var wait: [64]struct { i: Index, runs: u64 } = undefined;
        var n: usize = 0;
        for (&rs.slots, 0..) |*sl, i| {
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
            as.regions.deinit(as.ram.gpa);
            as.ram.gpa.destroy(as);
        }
    };
}
