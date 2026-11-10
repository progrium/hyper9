//! A Linux process's address space (design/0018-linux-personality.md,
//! "Memory"): a sorted list of VMAs over the vmm's address space, with
//! pages allocated on first touch.
//!
//! Pages come from the backend in chunks of `chunk_size`, aligned to it.
//! A chunk is allocated the first time any page in it is touched, by the
//! guest (a fault) or by the host (a syscall's buffer, the ELF loader),
//! and from then on every page of it that lies inside a VMA is mapped with
//! that VMA's permissions, as runs of pages that share them. Pages of a
//! chunk outside every VMA are unmapped and kept zero, so a later mapping
//! there starts zeroed; a chunk with no page in a VMA is freed. So a
//! `PROT_NONE` reservation, however large, costs nothing until it's
//! touched, and a change of permissions or an unmap of part of a mapping
//! only remaps the chunks it covers.
//!
//! The vmm interface maps and unmaps whole regions, so each run in a chunk
//! is its own region: a change to a chunk unmaps its runs and maps the new
//! ones. While threads share the Mm, only the runs whose pages change are
//! unmapped, and new pages get runs of their own, since a run unmapped and
//! mapped again is briefly missing for the other threads. design/0018 plans range `unmap` and `protect` in the vmm and a
//! virtual-TLB emulator for allocation-heavy programs; this layer is
//! written so that only `remap` would change.
//!
//! An Mm is reference counted: a vfork child shares its parent's until it
//! execs or exits, and threads share it for good (design/0049-linux-
//! threads.md). `lock` guards the VMAs and chunks for each step; `op`
//! serializes the calls that change the layout (mmap, munmap, mprotect,
//! brk, mremap), which look before they change it. While other processes
//! share the Mm, a change that removes or narrows access is shot down on
//! their vCPUs, and only then are pages freed.

const std = @import("std");
const vmm = @import("../vmm.zig");
const gm = @import("../guestmem.zig");

const page = vmm.page_size;
pub const chunk_size: u64 = 1 << 20;
pub const pages_per_chunk = chunk_size / page;

/// Where things go in a Linux address space, by architecture.
pub const Layout = struct {
    /// The top of the user address space.
    user_top: u64,
    /// Where the stack ends (exclusive), and how much of it is reserved.
    stack_top: u64,
    stack_size: u64 = 8 << 20,
    /// mmap allocates downward from here, below the stack and a gap.
    mmap_base: u64,
    /// Where a PIE executable is loaded (Linux's ELF_ET_DYN_BASE).
    pie_base: u64,

    /// 47 bits on arm64 and amd64, as on amd64 Linux, which arm64's 48-bit
    /// space also holds. i386 gets Linux's 3 GiB, below the emulator's
    /// descriptor table at the top (design/0105-linux-i386.md), with PIEs at 4 MiB as Linux puts them.
    pub fn of(arch: vmm.Arch) Layout {
        const top: u64 = if (arch == .i386) 0xC000_0000 else 1 << 47;
        return .{
            .user_top = top,
            .stack_top = top - page,
            .mmap_base = top - page - (8 << 20) - (128 << 20),
            .pie_base = if (arch == .i386) 0x40_0000 else 0x5555_5555_4000 & ~(chunk_size - 1),
        };
    }
};

/// The 64-bit layout, the largest: what a Linux address may be at most.
pub const user_top: u64 = Layout.of(.amd64).user_top;
/// Nothing is mapped below this, so a null pointer always faults.
pub const min_addr: u64 = 0x10000;

pub const Prot = packed struct(u3) {
    read: bool = false,
    write: bool = false,
    exec: bool = false,

    pub const none: Prot = .{};
    pub const rw: Prot = .{ .read = true, .write = true };

    /// From mmap's PROT_* bits.
    pub fn fromLinux(p: u64) Prot {
        return .{ .read = p & 1 != 0, .write = p & 2 != 0, .exec = p & 4 != 0 };
    }

    fn perms(p: Prot) ?vmm.Perms {
        if (!p.read and !p.write and !p.exec) return null;
        // A writable or executable page is readable on both architectures.
        return .{ .read = true, .write = p.write, .exec = p.exec };
    }

    fn eql(a: Prot, b: Prot) bool {
        return @as(u3, @bitCast(a)) == @as(u3, @bitCast(b));
    }
};

pub const Kind = enum { anon, file, heap, stack, vdso, shm };

pub const Vma = struct {
    start: u64,
    end: u64,
    prot: Prot,
    kind: Kind = .anon,
    /// MAP_SHARED: the same pages after fork.
    shared: bool = false,
    /// A MAP_PRIVATE file mapping over the file's shared pages (overlays),
    /// which sees later writes to the file until a page is written, when
    /// that page becomes a private copy, as on Linux.
    cow: bool = false,
    /// Fills the rest of a shared mapping's chunks (`insertShared`), so no
    /// other mapping lands in them. Not the guest's: unmapped with the
    /// mapping, and not in /proc/n/maps.
    pad: bool = false,
    /// For /proc/n/maps: the file's path, or empty.
    name: Name = .{},
    /// The file offset of `start`, for /proc/n/maps.
    offset: u64 = 0,
    /// A private file mapping filled on first touch: each chunk's pages in
    /// it are read from the file when the chunk is allocated (`populate`),
    /// rather than all of them at mmap, which for a shared library is
    /// mostly pages no one reads. Held by the Mm (`Mm.srcs`).
    src: ?*Src = null,

    pub const Name = struct {
        buf: [96]u8 = undefined,
        len: u8 = 0,

        pub fn init(s: []const u8) Name {
            var n: Name = .{};
            const l = @min(s.len, n.buf.len);
            @memcpy(n.buf[0..l], s[s.len - l ..]);
            n.len = @intCast(l);
            return n;
        }
        pub fn slice(n: *const Name) []const u8 {
            return n.buf[0..n.len];
        }
    };
};

const Run = struct { va: u64, len: u64, perms: vmm.Perms = .{} };

/// The file behind lazily filled private mappings (`Vma.src`), reference
/// counted: an Mm holds one for each Src its VMAs use, and drops it when
/// the last of them is unmapped.
pub const Src = struct {
    refs: std.atomic.Value(u32) = .init(1),
    /// Reads the file at `off` into `dst`, with zeros past its end or
    /// after a failed read.
    fill: *const fn (s: *Src, dst: []u8, off: u64) void,
    /// Frees it, after its last reference.
    free: *const fn (s: *Src) void,

    pub fn get(s: *Src) *Src {
        _ = s.refs.fetchAdd(1, .acq_rel);
        return s;
    }

    /// Drops a reference, outside any Mm's lock: the last frees it, which
    /// may close a file.
    pub fn put(s: *Src) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) s.free(s);
    }
};

/// A chunk's pages. Shared by the Mms of a fork for MAP_SHARED mappings,
/// and freed by the last. A shared file mapping's (shmfile.zig) are held
/// by the file's table too, whose `release` it calls when no Mm maps them.
pub const Pages = struct {
    mem: []align(page) u8,
    refs: std.atomic.Value(u32) = .init(1),
    /// The table's entry, for a shared file mapping's or a System V
    /// segment's pages.
    file: ?*anyopaque = null,
    /// Called, outside any Mm's lock, when no Mm maps a table's pages any
    /// more (only the table's reference is left).
    release: ?*const fn (p: *Pages) void = null,
};

/// Shared file pages standing in for part of a chunk's own (`insertFile`):
/// a shared file mapping at any page, or a copy-on-write private one,
/// beside private pages in the same chunk. A chunk with overlays is
/// copied by fork, its overlays with it, rather than shared whole.
const Overlay = struct {
    /// The part of the chunk it covers, as offsets in it, page aligned.
    lo: u64,
    hi: u64,
    /// A file chunk's pages (shmfile.zig), with a reference held.
    pages: *Pages,
    /// Where `lo` is in `pages.mem`.
    poff: u64,
};

/// A chunk in one Mm.
const Chunk = struct {
    pages: *Pages,
    mem: []align(page) u8,
    /// The regions of it mapped in the address space now.
    runs: [pages_per_chunk]Run = undefined,
    nruns: u16 = 0,
    /// Shared file mappings that don't sit at their offset's place in a
    /// chunk of their own, such as Wine's at 0x7ffe0000 beside private
    /// pages: their pages replace `mem`'s there. Sorted, not overlapping.
    overlays: std.ArrayList(Overlay) = .empty,

    const Backing = struct { mem: []u8, end: u64, overlay: bool };

    /// The memory behind chunk offset `off`, up to where that memory
    /// ends (an overlay's edge or the chunk's end), as `end`.
    fn backing(c: *const Chunk, off: u64) Backing {
        for (c.overlays.items) |o| {
            if (off < o.lo) return .{ .mem = c.mem[@intCast(off)..@intCast(o.lo)], .end = o.lo, .overlay = false };
            if (off < o.hi) return .{ .mem = o.pages.mem[@intCast(o.poff + (off - o.lo))..][0..@intCast(o.hi - off)], .end = o.hi, .overlay = true };
        }
        return .{ .mem = c.mem[@intCast(off)..], .end = chunk_size, .overlay = false };
    }
};

pub const Error = error{ OutOfMemory, BadAddress, NoSpace };

pub const Mm = struct {
    gpa: std.mem.Allocator,
    backend: vmm.Backend,
    /// Where things go, for the process's architecture.
    lay: Layout,
    as: vmm.AddressSpace,
    refs: std.atomic.Value(u32) = .init(1),
    /// Sorted by start, not overlapping.
    vmas: std.ArrayList(Vma) = .empty,
    /// Allocated chunks, by `va / chunk_size`.
    chunks: std.AutoHashMapUnmanaged(u64, *Chunk) = .empty,
    /// The heap: [brk_start, brk) is a VMA once it's grown.
    brk_start: u64 = 0,
    brk: u64 = 0,
    /// Bytes of chunks allocated, for /proc/n/status.
    allocated: @import("../web.zig").Atomic(u64) = .init(0),
    lock: std.atomic.Mutex = .unlocked,
    op: std.Io.Mutex = .init,
    /// Pages no chunk holds any more, freed by `settle` once no vCPU can
    /// reach them. Guarded by `lock`.
    doomed: std.ArrayList(*Pages) = .empty,
    /// File table pages this Mm stopped mapping, for their `release` once
    /// `settle` has shot them down. Guarded by `lock`.
    unmapped_files: std.ArrayList(*Pages) = .empty,
    /// Bumped by every `remap`, which unmaps a chunk's runs before mapping
    /// them again: a vCPU touching the chunk meanwhile faults on a page
    /// that's allowed. `fault` returns it, so a repeated fault counts as
    /// real only if no remap came between. Guarded by `lock`.
    remaps: u64 = 0,
    /// The Srcs of lazily filled mappings (`Vma.src`), with a reference
    /// each. Guarded by `lock`.
    srcs: std.ArrayList(*Src) = .empty,
    /// Srcs no VMA uses any more, put by `settle`. Guarded by `lock`.
    dead_srcs: std.ArrayList(*Src) = .empty,

    /// Holds off other threads' layout changes (`op`).
    pub fn opLock(m: *Mm, io: std.Io) void {
        m.op.lockUncancelable(io);
    }

    pub fn opUnlock(m: *Mm, io: std.Io) void {
        m.op.unlock(io);
    }

    pub fn create(gpa: std.mem.Allocator, backend: vmm.Backend, lay: Layout) (Error || vmm.CreateError)!*Mm {
        const m = try gpa.create(Mm);
        errdefer gpa.destroy(m);
        m.* = .{ .gpa = gpa, .backend = backend, .lay = lay, .as = try backend.newAddressSpace() };
        return m;
    }

    pub fn get(m: *Mm) *Mm {
        _ = m.refs.fetchAdd(1, .acq_rel);
        return m;
    }

    /// Drops a reference; the last frees the pages and the address space.
    pub fn put(m: *Mm) void {
        if (m.refs.fetchSub(1, .acq_rel) != 1) return;
        var it = m.chunks.iterator();
        while (it.next()) |e| {
            const c = e.value_ptr.*;
            for (c.runs[0..c.nruns]) |r| m.as.unmap(r.va);
            m.dropChunk(c);
        }
        m.chunks.deinit(m.gpa);
        m.vmas.deinit(m.gpa);
        for (m.doomed.items) |p| m.freeP(p);
        m.doomed.deinit(m.gpa);
        for (m.unmapped_files.items) |p| p.release.?(p);
        m.unmapped_files.deinit(m.gpa);
        for (m.srcs.items) |s| s.put();
        m.srcs.deinit(m.gpa);
        for (m.dead_srcs.items) |s| s.put();
        m.dead_srcs.deinit(m.gpa);
        m.as.destroy();
        m.gpa.destroy(m);
    }

    fn dropChunk(m: *Mm, c: *Chunk) void {
        _ = m.allocated.fetchSub(c.mem.len, .acq_rel);
        const p = c.pages;
        for (c.overlays.items) |o| m.dropRef(o.pages);
        c.overlays.deinit(m.gpa);
        m.gpa.destroy(c);
        m.dropRef(p);
    }

    /// Drops this Mm's reference to `p`, freeing the pages once no vCPU
    /// can reach them, or handing a file table's back to it.
    fn dropRef(m: *Mm, p: *Pages) void {
        const was = p.refs.fetchSub(1, .acq_rel);
        if (p.release) |f| {
            // The table's reference is the last: it may drop the pages.
            if (was == 2) m.unmapped_files.append(m.gpa, p) catch {
                m.as.shootdown();
                f(p);
            };
            return;
        }
        if (was != 1) return;
        // Another thread's vCPU may still reach them until `settle`.
        m.doomed.append(m.gpa, p) catch {
            m.as.shootdown();
            m.freeP(p);
        };
    }

    fn freeP(m: *Mm, p: *Pages) void {
        m.backend.freePages(p.mem);
        m.gpa.destroy(p);
    }

    /// After a change, with `lock` released: if other processes share the
    /// Mm and the change narrowed access or freed pages, shoots it down on
    /// their vCPUs; then frees the pages.
    fn settle(m: *Mm, narrowed: bool) void {
        m.lockSpin();
        var list = m.doomed;
        m.doomed = .empty;
        var files = m.unmapped_files;
        m.unmapped_files = .empty;
        var srcs = m.dead_srcs;
        m.dead_srcs = .empty;
        m.lock.unlock();
        if ((narrowed or list.items.len > 0 or files.items.len > 0) and m.refs.load(.acquire) > 1) m.as.shootdown();
        for (list.items) |p| m.freeP(p);
        list.deinit(m.gpa);
        for (files.items) |p| p.release.?(p);
        files.deinit(m.gpa);
        for (srcs.items) |s| s.put();
        srcs.deinit(m.gpa);
    }

    /// A hold on the pages behind a guest buffer, taken by `pin` and
    /// released by `unpin`. While it's held, a munmap, mremap, or exit on
    /// another thread sharing the Mm can unmap the range but can't free its
    /// host memory, so a blocking kernel read or write into the slice can't
    /// land in freed memory (the cross-thread use-after-free a backing
    /// syscall buffer would otherwise allow).
    pub const Pinned = struct {
        /// The contiguous host slice backing the range, as
        /// `guestmem.contiguous` returns it.
        s: []u8,
        held: std.ArrayList(*Pages) = .empty,
    };

    /// Resolves guest [va, va+len) to one contiguous host slice and holds a
    /// reference to the pages of every chunk behind it, so the memory stays
    /// valid until `unpin` even if the range is unmapped meanwhile. Returns
    /// null when the range isn't one contiguous mapped run (as
    /// `guestmem.contiguous` does), so the caller falls back to a bounce
    /// buffer. The slice and the references are taken under one lock, so a
    /// concurrent unmap either loses the race (and the pin keeps the pages)
    /// or wins it (and this returns null), with no window in between.
    pub fn pin(m: *Mm, va: u64, len: u64) ?Pinned {
        if (len == 0) return null;
        m.lockSpin();
        defer m.lock.unlock();
        return m.pinLocked(va, len) catch null;
    }

    fn pinLocked(m: *Mm, va: u64, len: u64) Error!Pinned {
        const s = gm.contiguous(m.as, va, len) orelse return error.BadAddress;
        var held: std.ArrayList(*Pages) = .empty;
        // On failure, give back the references already taken; each page
        // still has its chunk's reference, so a plain drop can't free it.
        errdefer {
            for (held.items) |p| _ = p.refs.fetchSub(1, .acq_rel);
            held.deinit(m.gpa);
        }
        const end = va + len;
        var ci = va / chunk_size;
        while (ci * chunk_size < end) : (ci += 1) {
            const c = m.chunks.get(ci) orelse continue;
            const cs = ci * chunk_size;
            const lo = @max(va, cs) - cs;
            const hi = @min(end, cs + chunk_size) - cs;
            try held.append(m.gpa, c.pages);
            _ = c.pages.refs.fetchAdd(1, .acq_rel);
            for (c.overlays.items) |o| {
                if (o.hi <= lo or o.lo >= hi) continue;
                try held.append(m.gpa, o.pages);
                _ = o.pages.refs.fetchAdd(1, .acq_rel);
            }
        }
        return .{ .s = s, .held = held };
    }

    /// Releases a pin from `pin`, freeing any pages whose last reference it
    /// held (the range was unmapped while it was pinned).
    pub fn unpin(m: *Mm, pn: *Pinned) void {
        defer pn.held = .empty;
        if (pn.held.items.len == 0) return;
        defer m.settle(false);
        m.lockSpin();
        defer m.lock.unlock();
        for (pn.held.items) |p| m.dropRef(p);
        pn.held.deinit(m.gpa);
    }

    /// Adds a chunk over `p` (taking a reference) at index `ci`, mapped.
    fn addChunk(m: *Mm, ci: u64, p: *Pages) Error!*Chunk {
        const c = try m.gpa.create(Chunk);
        c.* = .{ .pages = p, .mem = p.mem };
        _ = p.refs.fetchAdd(1, .acq_rel);
        m.chunks.put(m.gpa, ci, c) catch {
            _ = p.refs.fetchSub(1, .acq_rel);
            m.gpa.destroy(c);
            return error.OutOfMemory;
        };
        _ = m.allocated.fetchAdd(c.mem.len, .acq_rel);
        m.remap(ci, c) catch |e| {
            for (c.runs[0..c.nruns]) |r| m.as.unmap(r.va);
            _ = m.chunks.remove(ci);
            _ = m.allocated.fetchSub(c.mem.len, .acq_rel);
            _ = p.refs.fetchSub(1, .acq_rel);
            m.gpa.destroy(c);
            return e;
        };
        return c;
    }

    fn newPages(m: *Mm) Error!*Pages {
        const mem = m.backend.allocPages(pages_per_chunk) catch return error.NoSpace;
        const p = m.gpa.create(Pages) catch {
            m.backend.freePages(mem);
            return error.OutOfMemory;
        };
        // The creator's reference is dropped by addChunk's caller.
        p.* = .{ .mem = mem, .refs = .init(0) };
        return p;
    }

    fn lockSpin(m: *Mm) void {
        while (!m.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// The VMA holding `va`, if any.
    pub fn find(m: *Mm, va: u64) ?*Vma {
        const i = m.indexAfter(va);
        if (i == 0) return null;
        const v = &m.vmas.items[i - 1];
        return if (va < v.end) v else null;
    }

    /// The index of the first VMA starting after `va`.
    fn indexAfter(m: *const Mm, va: u64) usize {
        var lo: usize = 0;
        var hi: usize = m.vmas.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (m.vmas.items[mid].start <= va) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Whether [start, end) is free of VMAs.
    pub fn isFree(m: *const Mm, start: u64, end: u64) bool {
        const i = m.indexAfter(start);
        if (i > 0 and m.vmas.items[i - 1].end > start) return false;
        if (i < m.vmas.items.len and m.vmas.items[i].start < end) return false;
        return true;
    }

    /// A free range of `len` bytes, as high as possible below `mmap_base`.
    pub fn findFree(m: *const Mm, len: u64) ?u64 {
        var top: u64 = m.lay.mmap_base;
        var i = m.indexAfter(top);
        // A VMA straddling mmap_base (a stack that grew) lowers the top.
        if (i > 0 and m.vmas.items[i - 1].end > top) top = m.vmas.items[i - 1].start;
        while (true) {
            const below: u64 = if (i > 0) m.vmas.items[i - 1].end else min_addr;
            if (top >= below + len and top - len >= min_addr) return top - len;
            if (i == 0) return null;
            i -= 1;
            top = @min(top, m.vmas.items[i].start);
        }
    }

    /// Splits the VMA containing `va` at `va`, if one straddles it.
    fn splitAt(m: *Mm, va: u64) Error!void {
        const i = m.indexAfter(va);
        if (i == 0) return;
        const v = m.vmas.items[i - 1];
        if (va <= v.start or va >= v.end) return;
        var hi = v;
        hi.start = va;
        if (v.kind == .file) hi.offset = v.offset + (va - v.start);
        m.vmas.items[i - 1].end = va;
        try m.vmas.insert(m.gpa, i, hi);
    }

    /// Adds a VMA over [v.start, v.end), which must be free.
    pub fn insert(m: *Mm, v: Vma) Error!void {
        std.debug.assert(v.start % page == 0 and v.end % page == 0 and v.start < v.end);
        defer m.settle(false);
        m.lockSpin();
        defer m.lock.unlock();
        if (!m.isFree(v.start, v.end)) return error.BadAddress;
        if (v.src) |s| {
            try m.srcs.ensureUnusedCapacity(m.gpa, 1);
            try m.vmas.insert(m.gpa, m.indexAfter(v.start), v);
            if (std.mem.indexOfScalar(*Src, m.srcs.items, s) == null) m.srcs.appendAssumeCapacity(s.get());
            // Chunks allocated already won't be filled by `populate`.
            m.fillAllocated(v, v.start, v.end);
        } else try m.vmas.insert(m.gpa, m.indexAfter(v.start), v);
        try m.refreshRange(v.start, v.end);
    }

    /// Reads the file pages of lazy VMA `v` over [start, end) into the
    /// chunks there that are allocated, past any overlays.
    fn fillAllocated(m: *Mm, v: Vma, start: u64, end: u64) void {
        const s = v.src.?;
        var ci = start / chunk_size;
        while (ci * chunk_size < end) : (ci += 1) {
            const c = m.chunks.get(ci) orelse continue;
            const cs = ci * chunk_size;
            var lo = @max(start, cs) - cs;
            const hi = @min(end, cs + chunk_size) - cs;
            while (lo < hi) {
                const b = c.backing(lo);
                const e = @min(hi, b.end);
                if (!b.overlay) s.fill(s, b.mem[0..@intCast(e - lo)], v.offset + (cs + lo - v.start));
                lo = e;
            }
        }
    }

    /// Reads the file pages of the lazy VMAs over chunk `ci` into `mem`,
    /// its new pages.
    fn fillNew(m: *Mm, ci: u64, mem: []u8) void {
        if (m.srcs.items.len == 0) return;
        const cs = ci * chunk_size;
        const ce = cs + chunk_size;
        var i = m.indexAfter(cs);
        if (i > 0 and m.vmas.items[i - 1].end > cs) i -= 1;
        while (i < m.vmas.items.len and m.vmas.items[i].start < ce) : (i += 1) {
            const v = m.vmas.items[i];
            const s = v.src orelse continue;
            const lo = @max(v.start, cs);
            const hi = @min(v.end, ce);
            if (lo >= hi) continue;
            s.fill(s, mem[@intCast(lo - cs)..@intCast(hi - cs)], v.offset + (lo - v.start));
        }
    }

    /// Moves the Srcs no VMA uses any more to `dead_srcs`, for `settle`:
    /// of `which`, or of all if it's null.
    fn dropSrcs(m: *Mm, which: ?[]const *Src) void {
        var i: usize = 0;
        while (i < m.srcs.items.len) {
            const s = m.srcs.items[i];
            const check = if (which) |w| std.mem.indexOfScalar(*Src, w, s) != null else true;
            const used = !check or for (m.vmas.items) |v| {
                if (v.src == s) break true;
            } else false;
            if (used) {
                i += 1;
                continue;
            }
            if (m.dead_srcs.append(m.gpa, s)) |_| {
                _ = m.srcs.swapRemove(i);
            } else |_| i += 1;
        }
    }

    /// Removes every VMA in [start, end), splitting at the ends, and
    /// zeroes the pages that were there.
    pub fn unmap(m: *Mm, start: u64, end: u64) Error!void {
        if (start >= end) return;
        defer m.settle(true);
        m.lockSpin();
        defer m.lock.unlock();
        try m.splitAt(start);
        try m.splitAt(end);
        var i = m.indexAfter(start);
        if (i > 0 and m.vmas.items[i - 1].start >= start) i -= 1;
        // The Srcs of the lazy VMAs removed, to see if others use them.
        var gone: [8]*Src = undefined;
        var nlazy: usize = 0;
        while (i < m.vmas.items.len and m.vmas.items[i].start < end) {
            const v = m.vmas.items[i];
            if (v.end <= start) {
                i += 1;
                continue;
            }
            _ = m.vmas.orderedRemove(i);
            if (v.src) |s| {
                if (std.mem.indexOfScalar(*Src, gone[0..@min(nlazy, gone.len)], s) == null) {
                    if (nlazy < gone.len) gone[nlazy] = s;
                    nlazy += 1;
                }
            }
            // Shared pages are others' too; a chunk of them goes when
            // nothing maps it, and is never reused for another mapping.
            if (!v.shared) m.zero(v.start, v.end);
        }
        if (nlazy > 0) m.dropSrcs(if (nlazy <= gone.len) gone[0..nlazy] else null);
        m.dropPads(start, end);
        try m.trimOverlays(start, end);
        try m.refreshRange(start - start % chunk_size, std.mem.alignForward(u64, end, chunk_size));
    }

    /// Takes the overlays out of [start, end), splitting any that
    /// straddle its ends, after their VMAs went.
    fn trimOverlays(m: *Mm, start: u64, end: u64) Error!void {
        var ci = start / chunk_size;
        while (ci * chunk_size < end) : (ci += 1) {
            const c = m.chunks.get(ci) orelse continue;
            if (c.overlays.items.len == 0) continue;
            const cs = ci * chunk_size;
            try m.trimChunk(ci, c, @max(start, cs) - cs, @min(end, cs + chunk_size) - cs);
        }
    }

    /// trimOverlays within one chunk, [lo, hi) as offsets in it.
    fn trimChunk(m: *Mm, ci: u64, c: *Chunk, lo: u64, hi: u64) Error!void {
        {
            var changed = false;
            var i: usize = 0;
            while (i < c.overlays.items.len) {
                const o = c.overlays.items[i];
                if (o.hi <= lo or o.lo >= hi) {
                    i += 1;
                    continue;
                }
                changed = true;
                if (o.lo < lo and o.hi > hi) {
                    // The middle goes: two overlays over the same pages.
                    try c.overlays.insert(m.gpa, i + 1, .{ .lo = hi, .hi = o.hi, .pages = o.pages, .poff = o.poff + (hi - o.lo) });
                    _ = o.pages.refs.fetchAdd(1, .acq_rel);
                    c.overlays.items[i].hi = lo;
                    i += 2;
                } else if (o.lo < lo) {
                    c.overlays.items[i].hi = lo;
                    i += 1;
                } else if (o.hi > hi) {
                    c.overlays.items[i].lo = hi;
                    c.overlays.items[i].poff = o.poff + (hi - o.lo);
                    i += 1;
                } else {
                    _ = c.overlays.orderedRemove(i);
                    m.dropRef(o.pages);
                }
            }
            if (changed) m.dropRuns(ci, c, lo, hi);
        }
    }

    /// The overlay under chunk offset `off`, if any.
    fn overlayAt(c: *const Chunk, off: u64) ?*Overlay {
        for (c.overlays.items) |*o| if (off >= o.lo and off < o.hi) return o;
        return null;
    }

    /// A write to a copy-on-write page (`Vma.cow`): the page becomes the
    /// chunk's own, with the file's contents as they are now.
    fn breakCow(m: *Mm, ci: u64, c: *Chunk, off_in: u64) Error!void {
        const off = off_in - off_in % page;
        const o = overlayAt(c, off) orelse return;
        @memcpy(c.mem[@intCast(off)..][0..page], o.pages.mem[@intCast(o.poff + (off - o.lo))..][0..page]);
        try m.trimChunk(ci, c, off, off + page);
        try m.remap(ci, c);
    }

    /// Breaks copy-on-write for the pages of [va, end) in `cow` VMAs,
    /// before the host writes them for the guest.
    fn unshare(m: *Mm, va: u64, end: u64) Error!void {
        var at = va - va % page;
        while (at < end) : (at += page) {
            const c = m.chunks.get(at / chunk_size) orelse continue;
            if (c.overlays.items.len == 0) {
                at = (at / chunk_size + 1) * chunk_size - page;
                continue;
            }
            const v = m.find(at) orelse continue;
            if (v.cow) try m.breakCow(at / chunk_size, c, at % chunk_size);
        }
    }

    /// Unmaps the runs of chunk `ci` that overlap [lo, hi) (chunk offsets),
    /// whose memory changed, so `remap` maps them anew.
    fn dropRuns(m: *Mm, ci: u64, c: *Chunk, lo: u64, hi: u64) void {
        const cs = ci * chunk_size;
        var kept: u16 = 0;
        for (c.runs[0..c.nruns]) |r| {
            if (r.va < cs + hi and r.va + r.len > cs + lo) {
                m.as.unmap(r.va);
                continue;
            }
            c.runs[kept] = r;
            kept += 1;
        }
        c.nruns = kept;
    }

    /// Adds a file VMA at any page, MAP_SHARED or copy-on-write
    /// (`Vma.cow`), `v.offset` its file offset,
    /// over chunks that may hold other mappings: each piece of it within
    /// one chunk and one file chunk is an overlay of the file chunk's
    /// pages, from `pagesFor(ctx, file_chunk_index)`, which takes a
    /// reference to them for the overlay, under the table's lock, so a
    /// process unmapping them meanwhile can't free them.
    pub fn insertFile(m: *Mm, v: Vma, ctx: anytype, comptime pagesFor: fn (@TypeOf(ctx), u64) Error!*Pages) Error!void {
        std.debug.assert((v.shared or v.cow) and v.kind == .file and v.start % page == 0 and v.end % page == 0 and v.start < v.end and v.offset % page == 0);
        defer m.settle(false);
        m.lockSpin();
        defer m.lock.unlock();
        if (!m.isFree(v.start, v.end)) return error.BadAddress;
        try m.vmas.insert(m.gpa, m.indexAfter(v.start), v);
        errdefer {
            const i = m.indexAfter(v.start) - 1;
            _ = m.vmas.orderedRemove(i);
            m.trimOverlays(v.start, v.end) catch {};
            m.refreshRange(v.start - v.start % chunk_size, std.mem.alignForward(u64, v.end, chunk_size)) catch {};
        }
        var at = v.start;
        while (at < v.end) {
            const ci = at / chunk_size;
            const cs = ci * chunk_size;
            const fo = v.offset + (at - v.start);
            const hi = @min(v.end, cs + chunk_size, at + (chunk_size - fo % chunk_size));
            const c = try m.populate(at);
            try c.overlays.ensureUnusedCapacity(m.gpa, 1);
            const pg = try pagesFor(ctx, fo / chunk_size);
            var i: usize = 0;
            while (i < c.overlays.items.len and c.overlays.items[i].lo < at - cs) i += 1;
            c.overlays.insertAssumeCapacity(i, .{ .lo = at - cs, .hi = hi - cs, .pages = pg, .poff = fo % chunk_size });
            m.dropRuns(ci, c, at - cs, hi - cs);
            try m.remap(ci, c);
            at = hi;
        }
    }

    /// Removes the padding of the chunks overlapping [start, end) where
    /// it's all that's left.
    fn dropPads(m: *Mm, start: u64, end: u64) void {
        var ci = start / chunk_size;
        while (ci * chunk_size < end) : (ci += 1) {
            const cs = ci * chunk_size;
            const ce = cs + chunk_size;
            var i = m.indexAfter(cs);
            if (i > 0 and m.vmas.items[i - 1].end > cs) i -= 1;
            var only_pads = true;
            var any = false;
            var j = i;
            while (j < m.vmas.items.len and m.vmas.items[j].start < ce) : (j += 1) {
                any = true;
                if (!m.vmas.items[j].pad) only_pads = false;
            }
            if (!any or !only_pads) continue;
            while (i < m.vmas.items.len and m.vmas.items[i].start < ce) _ = m.vmas.orderedRemove(i);
        }
    }

    /// Adds a MAP_SHARED VMA, `v.shared` set, and pads the rest of its
    /// chunks so their pages serve only it. For a file mapping, `pagesFor`
    /// gives each chunk's pages, shared with every process mapping the
    /// same part of the file; `v.start` must then sit at the file
    /// offset's place in a chunk; it takes a reference to them, under the
    /// table's lock, so a process unmapping them meanwhile can't free
    /// them, and the chunk takes its own. An anonymous one's pages come on
    /// first touch, as any.
    pub fn insertShared(m: *Mm, v: Vma, ctx: anytype, comptime pagesFor: ?fn (@TypeOf(ctx), u64) Error!*Pages) Error!void {
        std.debug.assert(v.shared and v.start % page == 0 and v.end % page == 0 and v.start < v.end);
        defer m.settle(false);
        m.lockSpin();
        defer m.lock.unlock();
        const lo = v.start - v.start % chunk_size;
        const hi = std.mem.alignForward(u64, v.end, chunk_size);
        if (!m.isFree(lo, hi)) return error.BadAddress;
        var ci = lo / chunk_size;
        while (ci * chunk_size < hi) : (ci += 1) if (m.chunks.contains(ci)) return error.BadAddress;
        try m.vmas.ensureUnusedCapacity(m.gpa, 3);
        var pad = v;
        pad.pad = true;
        pad.prot = .none;
        pad.name = .{};
        if (lo < v.start) {
            pad.start = lo;
            pad.end = v.start;
            m.vmas.insertAssumeCapacity(m.indexAfter(lo), pad);
        }
        m.vmas.insertAssumeCapacity(m.indexAfter(v.start), v);
        if (v.end < hi) {
            pad.start = v.end;
            pad.end = hi;
            m.vmas.insertAssumeCapacity(m.indexAfter(v.end), pad);
        }
        errdefer {
            var k: usize = 0;
            while (k < m.vmas.items.len) {
                const x = m.vmas.items[k];
                if (x.start >= lo and x.end <= hi) _ = m.vmas.orderedRemove(k) else k += 1;
            }
            var cj = lo / chunk_size;
            while (cj * chunk_size < hi) : (cj += 1) if (m.chunks.fetchRemove(cj)) |e| {
                for (e.value.runs[0..e.value.nruns]) |r| m.as.unmap(r.va);
                m.dropChunk(e.value);
            };
        }
        if (pagesFor) |f| {
            ci = lo / chunk_size;
            while (ci * chunk_size < hi) : (ci += 1) {
                const p = try f(ctx, ci);
                defer m.dropRef(p);
                _ = try m.addChunk(ci, p);
            }
        }
    }

    /// Changes the protection of [start, end), which must be covered by
    /// VMAs (else BadAddress, as Linux's ENOMEM).
    pub fn protect(m: *Mm, start: u64, end: u64, prot: Prot) Error!void {
        if (start >= end) return;
        defer m.settle(true);
        m.lockSpin();
        defer m.lock.unlock();
        if (!m.covered(start, end)) return error.BadAddress;
        try m.splitAt(start);
        try m.splitAt(end);
        for (m.vmas.items) |*v| {
            if (v.start >= start and v.end <= end) v.prot = prot;
        }
        m.merge();
        try m.refreshRange(start, end);
    }

    /// Whether a VMA holds `va`, for another thread than the one that
    /// changes the VMAs.
    pub fn mapped(m: *Mm, va: u64) bool {
        m.lockSpin();
        defer m.lock.unlock();
        return m.find(va) != null;
    }

    /// Whether VMAs cover all of [start, end).
    pub fn covered(m: *Mm, start: u64, end: u64) bool {
        var at = start;
        while (at < end) {
            const v = m.find(at) orelse return false;
            at = v.end;
        }
        return true;
    }

    /// Joins neighbouring anonymous VMAs that only a split separated.
    fn merge(m: *Mm) void {
        var i: usize = 1;
        while (i < m.vmas.items.len) {
            const a = &m.vmas.items[i - 1];
            const b = m.vmas.items[i];
            if (a.end == b.start and a.prot.eql(b.prot) and a.kind == b.kind and a.kind != .file and a.kind != .shm and a.shared == b.shared and a.pad == b.pad) {
                a.end = b.end;
                _ = m.vmas.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Zeroes the allocated pages in [start, end).
    fn zero(m: *Mm, start: u64, end: u64) void {
        var ci = start / chunk_size;
        while (ci * chunk_size < end) : (ci += 1) {
            const c = m.chunks.get(ci) orelse continue;
            const cs = ci * chunk_size;
            var lo = @max(start, cs) - cs;
            const hi = @min(end, cs + chunk_size) - cs;
            while (lo < hi) {
                const b = c.backing(lo);
                const e = @min(hi, b.end);
                if (!b.overlay) @memset(b.mem[0..@intCast(e - lo)], 0);
                lo = e;
            }
        }
    }

    /// Remaps the allocated chunks overlapping [start, end) to match the
    /// VMAs, and frees those no VMA touches any more.
    fn refreshRange(m: *Mm, start: u64, end: u64) Error!void {
        var ci = start / chunk_size;
        while (ci * chunk_size < end) : (ci += 1) {
            const c = m.chunks.get(ci) orelse continue;
            try m.remap(ci, c);
        }
    }

    /// Maps a chunk's in-VMA pages as runs that share permissions.
    fn remap(m: *Mm, ci: u64, c: *Chunk) Error!void {
        m.remaps +%= 1;
        if (m.refs.load(.acquire) > 1) return m.remapShared(ci, c);
        for (c.runs[0..c.nruns]) |r| m.as.unmap(r.va);
        c.nruns = 0;
        const cs = ci * chunk_size;
        var any = false;
        var p: u64 = 0;
        while (p < pages_per_chunk) {
            const va = cs + p * page;
            const v = m.find(va) orelse {
                p += 1;
                continue;
            };
            any = true;
            var run_end = @min(v.end, cs + chunk_size);
            // Neighbouring VMAs with the same page permissions share one
            // run, so a heap of many small mappings (musl's malloc makes one
            // per group) stays a region per chunk, not one per mapping.
            while (run_end < cs + chunk_size) {
                const w = m.find(run_end) orelse break;
                if (!std.meta.eql(w.prot.perms(), v.prot.perms())) break;
                run_end = @min(w.end, cs + chunk_size);
            }
            const b = c.backing(p * page);
            run_end = @min(run_end, cs + b.end);
            const n = (run_end - va) / page;
            if (v.prot.perms()) |perms_v| {
                var perms = perms_v;
                // Copy-on-write file pages fault on a write (`fault`).
                if (b.overlay and v.cow) perms.write = false;
                m.as.map(va, @alignCast(b.mem[0..@intCast(n * page)]), perms) catch return error.OutOfMemory;
                c.runs[c.nruns] = .{ .va = va, .len = n * page, .perms = perms };
                c.nruns += 1;
            }
            p += n;
        }
        if (!any) {
            _ = m.chunks.remove(ci);
            m.dropChunk(c);
        }
    }

    /// `remap` while other threads share the Mm, and run guest code while
    /// this one changes the layout. Unmapping a run and mapping it again
    /// leaves its pages unmapped in between, where another thread's access
    /// faults or, in a syscall, fails with EFAULT, so runs whose pages keep
    /// their permissions stay mapped as they are, and only pages outside
    /// them are mapped, as new runs that don't merge with the kept ones.
    fn remapShared(m: *Mm, ci: u64, c: *Chunk) Error!void {
        const cs = ci * chunk_size;
        var want: [pages_per_chunk]?vmm.Perms = undefined;
        var any = false;
        for (&want, 0..) |*w, p| {
            const v = m.find(cs + p * page);
            w.* = if (v) |x| x.prot.perms() else null;
            if (v != null) any = true;
            if (w.* != null and v.?.cow and overlayAt(c, p * page) != null) w.*.?.write = false;
        }
        if (!any) {
            for (c.runs[0..c.nruns]) |r| m.as.unmap(r.va);
            c.nruns = 0;
            _ = m.chunks.remove(ci);
            m.dropChunk(c);
            return;
        }
        var in_run: [pages_per_chunk]bool = @splat(false);
        var kept: u16 = 0;
        for (c.runs[0..c.nruns]) |r| {
            const first: usize = @intCast((r.va - cs) / page);
            const n: usize = @intCast(r.len / page);
            const same = for (want[first..][0..n]) |w| {
                if (w == null or !std.meta.eql(w.?, r.perms)) break false;
            } else true;
            if (!same) {
                m.as.unmap(r.va);
                continue;
            }
            @memset(in_run[first..][0..n], true);
            c.runs[kept] = r;
            kept += 1;
        }
        c.nruns = kept;
        var p: usize = 0;
        while (p < pages_per_chunk) {
            const perms = want[p] orelse {
                p += 1;
                continue;
            };
            if (in_run[p]) {
                p += 1;
                continue;
            }
            const off = p * page;
            const b = c.backing(off);
            const limit: usize = @intCast(b.end / page);
            var q = p + 1;
            while (q < limit and !in_run[q] and want[q] != null and std.meta.eql(want[q].?, perms)) q += 1;
            m.as.map(cs + off, @alignCast(b.mem[0..@intCast((q - p) * page)]), perms) catch return error.OutOfMemory;
            c.runs[c.nruns] = .{ .va = cs + off, .len = (q - p) * page, .perms = perms };
            c.nruns += 1;
            p = q;
        }
    }

    /// Allocates the chunk holding `va` if it isn't yet, and maps it.
    fn populate(m: *Mm, va: u64) Error!*Chunk {
        const ci = va / chunk_size;
        if (m.chunks.get(ci)) |c| return c;
        const p = try m.newPages();
        m.fillNew(ci, p.mem);
        return m.addChunk(ci, p) catch |e| {
            // A failed addChunk leaves the pages unreferenced.
            if (p.refs.load(.acquire) == 0) {
                m.backend.freePages(p.mem);
                m.gpa.destroy(p);
            }
            return e;
        };
    }

    pub const Access = enum { read, write, exec };

    /// Serves a guest fault at `va`: allocates the page's chunk if the
    /// VMA allows the access. Returns null for a real fault (SIGSEGV), and
    /// otherwise `remaps` as of now, for the caller to retry. A fault on a
    /// page that's allocated and allowed is a vCPU's stale view, after
    /// another thread mapped it, or a touch inside another thread's remap
    /// of the chunk; the caller gives up only if the same fault repeats
    /// with no remap in between.
    pub fn fault(m: *Mm, va: u64, access: Access) Error!?u64 {
        m.lockSpin();
        defer m.lock.unlock();
        const v = m.find(va) orelse return null;
        const ok = switch (access) {
            .read => v.prot.read or v.prot.write or v.prot.exec,
            .write => v.prot.write,
            .exec => v.prot.exec,
        };
        if (!ok) return null;
        const c = m.chunks.get(va / chunk_size) orelse try m.populate(va);
        if (access == .write and v.cow) try m.breakCow(va / chunk_size, c, va % chunk_size);
        return m.remaps;
    }

    /// Makes [va, va+len) ready for the host to read (or with `write`, to
    /// write) on the guest's behalf, as a syscall's buffer: every page
    /// must be in a VMA that allows it, and is allocated if it isn't yet.
    /// BadAddress is EFAULT.
    pub fn touch(m: *Mm, va: u64, len: u64, write: bool) Error!void {
        if (len == 0) return;
        m.lockSpin();
        defer m.lock.unlock();
        try m.touchLocked(va, len, write);
    }

    fn touchLocked(m: *Mm, va: u64, len: u64, write: bool) Error!void {
        const end = std.math.add(u64, va, len) catch return error.BadAddress;
        var at = va;
        while (at < end) {
            const v = m.find(at) orelse return error.BadAddress;
            if (write and !v.prot.write) return error.BadAddress;
            if (!write and !(v.prot.read or v.prot.write or v.prot.exec)) return error.BadAddress;
            at = @min(v.end, end);
        }
        var ci = va / chunk_size;
        while (ci * chunk_size < end) : (ci += 1) _ = try m.populate(ci * chunk_size);
        if (write) try m.unshare(va, end);
    }

    /// The host's view of [va, va+len), which must lie in one chunk, as
    /// `touch` checks it: for a futex word or a piece of a string. The
    /// slice stays valid while a VMA covers it, since a remap moves no
    /// memory, where a translate through the address space can miss in
    /// another thread's remap.
    pub fn hostSlice(m: *Mm, va: u64, len: u64, write: bool) Error![]u8 {
        const end = std.math.add(u64, va, len) catch return error.BadAddress;
        if (len == 0 or (end - 1) / chunk_size != va / chunk_size) return error.BadAddress;
        m.lockSpin();
        defer m.lock.unlock();
        try m.touchLocked(va, len, write);
        const c = m.chunks.get(va / chunk_size).?;
        const off = va % chunk_size;
        const b = c.backing(off);
        if (len > b.end - off) return error.BadAddress;
        return b.mem[0..@intCast(len)];
    }

    /// Copies between guest [va, va+buf.len) and `buf` for a syscall, as
    /// `touch` checks it (`to_guest` needs write access), through the
    /// chunks' own memory under the lock. Unlike a copy through the
    /// address space, another thread's remap can't make it miss.
    pub fn copy(m: *Mm, va: u64, buf: []u8, to_guest: bool) Error!void {
        if (buf.len == 0) return;
        m.lockSpin();
        defer m.lock.unlock();
        try m.touchLocked(va, buf.len, to_guest);
        var at = va;
        const end = va + buf.len;
        while (at < end) {
            const c = m.chunks.get(at / chunk_size).?;
            const cs = at - at % chunk_size;
            const b = c.backing(at - cs);
            const hi = @min(end, cs + b.end);
            const g = b.mem[0..@intCast(hi - at)];
            const h = buf[@intCast(at - va)..@intCast(hi - va)];
            if (to_guest) @memcpy(g, h) else @memcpy(h, g);
            at = hi;
        }
    }

    /// The host's view of [va, va+len), allocating as needed but ignoring
    /// the VMA's protection: for the loader, which writes read-only text.
    /// Calls `f(ctx, host_slice, offset)` for each piece.
    pub fn hostEach(m: *Mm, va: u64, len: u64, ctx: anytype, comptime f: fn (@TypeOf(ctx), []u8, u64) void) Error!void {
        var at = va;
        const end = va + len;
        m.lockSpin();
        defer m.lock.unlock();
        while (at < end) {
            if (m.find(at) == null) return error.BadAddress;
            _ = try m.populate(at);
            try m.unshare(at, @min(end, (at / chunk_size + 1) * chunk_size));
            const c = m.chunks.get(at / chunk_size).?;
            const cs = at - at % chunk_size;
            const b = c.backing(at - cs);
            const hi = @min(end, cs + b.end);
            f(ctx, b.mem[0..@intCast(hi - at)], at - va);
            at = hi;
        }
    }

    /// Copies `data` to `va` from the host, through `hostEach`.
    pub fn hostWrite(m: *Mm, va: u64, data: []const u8) Error!void {
        try m.hostEach(va, data.len, data, struct {
            fn f(d: []const u8, dst: []u8, off: u64) void {
                @memcpy(dst, d[@intCast(off)..][0..dst.len]);
            }
        }.f);
    }

    /// Grows or shrinks the heap (brk). Returns the new break, or the old
    /// one if it can't move, as Linux does.
    pub fn setBrk(m: *Mm, want: u64) u64 {
        if (want < m.brk_start) return m.brk;
        const old_end = std.mem.alignForward(u64, m.brk, page);
        const new_end = std.mem.alignForward(u64, want, page);
        if (new_end > old_end) {
            if (!m.isFree(old_end, new_end) or new_end > m.lay.mmap_base) return m.brk;
            m.lockSpin();
            const v = m.find(old_end -| 1);
            if (v != null and v.?.kind == .heap and v.?.end == old_end) {
                v.?.end = new_end;
                m.refreshRange(old_end - chunk_size, new_end) catch {
                    v.?.end = old_end;
                    m.lock.unlock();
                    return m.brk;
                };
                m.lock.unlock();
            } else {
                m.lock.unlock();
                m.insert(.{ .start = old_end, .end = new_end, .prot = .rw, .kind = .heap }) catch return m.brk;
            }
        } else if (new_end < old_end) {
            m.unmap(new_end, old_end) catch return m.brk;
        }
        m.brk = want;
        return m.brk;
    }

    /// A private copy for fork: the same VMAs, with the allocated pages
    /// copied, except MAP_SHARED ones, whose pages are shared. (mmap
    /// aligns shared mappings to chunks, so a chunk is all shared or not.)
    pub fn fork(m: *Mm) (Error || vmm.CreateError)!*Mm {
        const n = try create(m.gpa, m.backend, m.lay);
        errdefer n.put();
        m.lockSpin();
        defer m.lock.unlock();
        try n.vmas.appendSlice(n.gpa, m.vmas.items);
        try n.srcs.ensureTotalCapacity(n.gpa, m.srcs.items.len);
        for (m.srcs.items) |s| n.srcs.appendAssumeCapacity(s.get());
        n.brk_start = m.brk_start;
        n.brk = m.brk;
        // A shared mapping's chunks that no one has touched yet are made
        // now, so parent and child share them too, as PostgreSQL's
        // shared buffers need.
        for (m.vmas.items) |v| {
            if (!v.shared or v.pad) continue;
            var ci = v.start / chunk_size;
            while (ci * chunk_size < v.end) : (ci += 1) {
                if (m.chunks.contains(ci)) continue;
                const p = try m.newPages();
                _ = m.addChunk(ci, p) catch |err| {
                    m.freeP(p);
                    return err;
                };
            }
        }
        var it = m.chunks.iterator();
        while (it.next()) |e| {
            const ci = e.key_ptr.*;
            const c = e.value_ptr.*;
            // A chunk with overlays has private pages around them.
            const shared = c.overlays.items.len == 0 and if (m.find(ci * chunk_size)) |v| v.shared else false;
            if (shared) {
                _ = try n.addChunk(ci, c.pages);
                continue;
            }
            const p = try n.newPages();
            copySparse(p.mem, c.mem);
            const nc = n.addChunk(ci, p) catch |err| {
                if (p.refs.load(.acquire) == 0) {
                    n.backend.freePages(p.mem);
                    n.gpa.destroy(p);
                }
                return err;
            };
            if (c.overlays.items.len == 0) continue;
            // The overlays' file pages are shared, as MAP_SHARED is.
            try nc.overlays.ensureTotalCapacity(n.gpa, c.overlays.items.len);
            for (c.overlays.items) |o| {
                _ = o.pages.refs.fetchAdd(1, .acq_rel);
                nc.overlays.appendAssumeCapacity(o);
            }
            n.dropRuns(ci, nc, 0, chunk_size);
            try n.remap(ci, nc);
        }
        return n;
    }

    /// MADV_DONTNEED: private pages in [start, end) read as zero again,
    /// or a private file mapping's as the file's. Shared ones keep their
    /// contents, as Linux's do.
    pub fn discard(m: *Mm, start: u64, end: u64) void {
        m.lockSpin();
        defer m.lock.unlock();
        for (m.vmas.items) |v| {
            if (v.end <= start or v.start >= end or v.shared) continue;
            if (v.src != null)
                m.fillAllocated(v, @max(v.start, start), @min(v.end, end))
            else
                m.zero(@max(v.start, start), @min(v.end, end));
        }
    }

    /// Copies the allocated pages of [src, src+len) to dst, for mremap's
    /// move. dst must be in a VMA already; pages never allocated at src
    /// are left unallocated at dst, zero or, in a lazily filled mapping
    /// moved with its file offset, the file's as at src.
    pub fn copyRange(m: *Mm, src: u64, dst: u64, len: u64) Error!void {
        m.lockSpin();
        defer m.lock.unlock();
        const lazy = if (m.find(dst)) |v| v.src != null else false;
        var off: u64 = 0;
        while (off < len) : (off += page) {
            const sc = m.chunks.get((src + off) / chunk_size) orelse continue;
            const so = (src + off) % chunk_size;
            const from = sc.backing(so).mem[0..page];
            // A lazy mapping's new chunk is filled from the file, so a
            // page the guest zeroed is copied too.
            if (!lazy and std.mem.allEqual(u8, from, 0)) continue;
            const dc = try m.populate(dst + off);
            const do = (dst + off) % chunk_size;
            @memcpy(dc.backing(do).mem[0..page], from);
        }
    }

    /// The pages under va and its offset in them, if va is in a shared
    /// mapping: what processes sharing the pages key a futex on.
    pub fn sharedAt(m: *Mm, va: u64) ?struct { pages: *Pages, off: u64 } {
        m.lockSpin();
        defer m.lock.unlock();
        const v = m.find(va) orelse return null;
        if (!v.shared) return null;
        const c = m.chunks.get(va / chunk_size) orelse return null;
        const off = va % chunk_size;
        for (c.overlays.items) |o| if (off >= o.lo and off < o.hi) return .{ .pages = o.pages, .off = o.poff + (off - o.lo) };
        return .{ .pages = c.pages, .off = off };
    }

    /// Bytes of guest memory allocated.
    pub fn bytes(m: *const Mm) u64 {
        return m.allocated.load(.acquire);
    }

    /// /proc/n/maps.
    pub fn mapsText(m: *Mm, w: *std.Io.Writer) void {
        m.lockSpin();
        defer m.lock.unlock();
        for (m.vmas.items) |v| {
            if (v.pad) continue;
            const name: []const u8 = switch (v.kind) {
                .heap => "[heap]",
                .stack => "[stack]",
                .vdso => "[vdso]",
                .file, .shm => v.name.slice(),
                .anon => "",
            };
            w.print("{x:0>8}-{x:0>8} {c}{c}{c}{c} {x:0>8} 00:00 0", .{
                v.start,                                v.end,
                @as(u8, if (v.prot.read) 'r' else '-'), @as(u8, if (v.prot.write) 'w' else '-'),
                @as(u8, if (v.prot.exec) 'x' else '-'), @as(u8, if (v.shared) 's' else 'p'),
                v.offset,
            }) catch return;
            if (name.len > 0) w.print("{s: >20}{s}", .{ "", name }) catch return;
            w.writeAll("\n") catch return;
        }
    }
};

/// As segment.zig's: copies the non-zero pages of `src` into fresh `dst`.
fn copySparse(dst: []u8, src: []const u8) void {
    var off: usize = 0;
    while (off < src.len) : (off += page) {
        const p: []const u8 = src[off..][0..page];
        const words: []const u64 = @alignCast(std.mem.bytesAsSlice(u64, p));
        for (words) |w| {
            if (w != 0) {
                @memcpy(dst[off..][0..page], p);
                break;
            }
        }
    }
}

const testing = std.testing;

/// A translate-only address space over one run of host memory, for the
/// pin tests; `pin` resolves a buffer through `guestmem.contiguous`, which
/// only needs `translate`.
const FakeAs = struct {
    base: u64,
    mem: []align(page) u8,
    fn translate(f: *FakeAs, va: u64, len: u64) ?[]u8 {
        if (va < f.base) return null;
        const off = va - f.base;
        if (off > f.mem.len or len > f.mem.len - off) return null;
        return f.mem[@intCast(off)..][0..@intCast(len)];
    }
};

/// Builds an Mm holding a single chunk that maps `mem` at `va`, with the
/// one reference a live chunk holds. The backend is never used: these
/// tests drive `pin`/`unpin`/`dropRef` without allocating or freeing
/// pages through it.
fn pinFixture(m: *Mm, fake: *FakeAs, chunk: *Chunk, pages: *Pages, va: u64, mem: []align(page) u8) !void {
    fake.* = .{ .base = va, .mem = mem };
    m.* = .{
        .gpa = testing.allocator,
        .backend = undefined,
        .lay = .of(.amd64),
        .as = vmm.AddressSpace.initFake(fake, FakeAs.translate),
    };
    pages.* = .{ .mem = mem };
    chunk.* = .{ .pages = pages, .mem = mem };
    try m.chunks.put(testing.allocator, va / chunk_size, chunk);
}

test "pin holds a guest buffer's pages across a concurrent unmap" {
    const gpa = testing.allocator;
    const mem = try gpa.alignedAlloc(u8, .fromByteUnits(page), page);
    defer gpa.free(mem);
    @memset(mem, 0);
    const va: u64 = chunk_size; // chunk index 1, chunk-aligned.

    var fake: FakeAs = undefined;
    var m: Mm = undefined;
    var chunk: Chunk = undefined;
    var pages: Pages = undefined;
    try pinFixture(&m, &fake, &chunk, &pages, va, mem);
    defer m.chunks.deinit(gpa);
    defer m.doomed.deinit(gpa);

    // Pin the page, as io() does before a blocking read or write.
    var pinned = m.pin(va, page) orelse return error.PinFailed;
    try testing.expectEqual(mem.ptr, pinned.s.ptr);
    try testing.expectEqual(@as(usize, page), pinned.s.len);
    try testing.expectEqual(@as(u32, 2), pages.refs.load(.acquire));

    // Another thread unmaps the range, dropping the chunk's reference.
    // Without the pin this would free `mem`; with it the page survives and
    // isn't even scheduled to be freed.
    m.dropRef(&pages);
    try testing.expectEqual(@as(u32, 1), pages.refs.load(.acquire));
    try testing.expectEqual(@as(usize, 0), m.doomed.items.len);

    // The host slice is still ours: a kernel read or write into it is safe.
    @memset(pinned.s, 0xAB);

    // Releasing the pin drops its reference; only now are the pages doomed.
    // (unpin would free them through the backend; here the last reference
    // is dropped by hand so the stack-allocated Pages isn't destroyed.)
    pinned.held.deinit(gpa);
    m.dropRef(&pages);
    try testing.expectEqual(@as(u32, 0), pages.refs.load(.acquire));
    try testing.expectEqual(@as(usize, 1), m.doomed.items.len);
    try testing.expectEqual(&pages, m.doomed.items[0]);
}

test "unpin releases its reference and frees nothing when the mapping stays" {
    const gpa = testing.allocator;
    const mem = try gpa.alignedAlloc(u8, .fromByteUnits(page), page);
    defer gpa.free(mem);
    @memset(mem, 0);
    const va: u64 = chunk_size;

    var fake: FakeAs = undefined;
    var m: Mm = undefined;
    var chunk: Chunk = undefined;
    var pages: Pages = undefined;
    try pinFixture(&m, &fake, &chunk, &pages, va, mem);
    defer m.chunks.deinit(gpa);
    defer m.doomed.deinit(gpa);

    var pinned = m.pin(va, page) orelse return error.PinFailed;
    try testing.expectEqual(@as(u32, 2), pages.refs.load(.acquire));

    // No unmap raced the I/O: unpin drops the pin's reference and the
    // chunk still maps the page, so nothing is freed.
    m.unpin(&pinned);
    try testing.expectEqual(@as(u32, 1), pages.refs.load(.acquire));
    try testing.expectEqual(@as(usize, 0), m.doomed.items.len);
    try testing.expectEqual(@as(usize, 0), pinned.held.items.len);
}

test "pin returns null for a buffer that isn't one contiguous mapped run" {
    const gpa = testing.allocator;
    const mem = try gpa.alignedAlloc(u8, .fromByteUnits(page), page);
    defer gpa.free(mem);
    @memset(mem, 0);
    const va: u64 = chunk_size;

    var fake: FakeAs = undefined;
    var m: Mm = undefined;
    var chunk: Chunk = undefined;
    var pages: Pages = undefined;
    try pinFixture(&m, &fake, &chunk, &pages, va, mem);
    defer m.chunks.deinit(gpa);
    defer m.doomed.deinit(gpa);

    // Past the one mapped page: not translatable, so no pin and no stray
    // reference left behind.
    try testing.expectEqual(@as(?Mm.Pinned, null), m.pin(va, 2 * page));
    try testing.expectEqual(@as(u32, 1), pages.refs.load(.acquire));
}
