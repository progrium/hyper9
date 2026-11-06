//! A process's memory segments: text, data (data and bss together) and
//! stack, plus up to five that segattach adds (`shared` and `memory`), each
//! a set of pages from the backend's allocator that it can free again. See
//! DESIGN.md, "Process model", and design/0004-segattach.md.
//!
//! A segment can be attached to several address spaces (rfork with RFMEM
//! shares text, data and bss), and a change to it, such as brk growing the
//! data, is mapped into all of them. It's freed when the last one detaches.
//!
//! Pages come in chunks, one backend allocation and one mapping each, so a
//! segment grows without copying. Semaphore wait lists (src/kern/sema.c)
//! are keyed by the host address of the guest word, so they rely on a
//! segment's pages never moving while it's shared; copy-on-write or
//! compaction would have to change that key (design/0003-semaphores.md). The stack grows down on demand, as
//! 9front's does: it starts with what the arguments need plus some
//! headroom, and `Segs.growStack` extends it on faults and at syscalls.

const std = @import("std");
const vmm = @import("vmm.zig");

const page = vmm.page_size;

/// Copies `src` into `dst`, which is freshly allocated and so zero, a page
/// at a time, skipping pages of `src` that are zero. A Go program reserves
/// several hundred MB of brk it never touches, which rfork would otherwise
/// write in full; reading an untouched page costs the host next to nothing.
fn copySparse(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len == src.len and src.len % page == 0);
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

pub const Kind = enum {
    text,
    data,
    stack,
    /// segattach's `shared` class: the same pages in rfork children.
    shared,
    /// segattach's `memory` class: copied by rfork like the bss, or shared
    /// with RFMEM.
    memory,
};

/// Headroom kept below a stack address when the stack grows to cover it.
pub const stack_slack: u64 = 64 << 10;
/// Smallest step the data segment's mapping grows by.
pub const min_grow: u64 = 64 << 10;

pub const Error = vmm.CreateError;

pub const Segment = struct {
    gpa: std.mem.Allocator,
    backend: vmm.Backend,
    kind: Kind,
    perms: vmm.Perms,
    /// [base, top) is mapped: data grows `top` up, the stack grows `base` down.
    base: u64,
    top: u64,
    /// The break, for data: brk moves it, and `top` follows it up in steps
    /// of at least `min_grow`, so a run of small sbrks maps few chunks.
    brk: u64,
    /// Detached at exec (segattach's SG_CEXEC).
    cexec: bool = false,
    /// Sorted by address and contiguous, covering [base, top).
    chunks: std.ArrayList(Chunk) = .empty,
    attached: std.ArrayList(vmm.AddressSpace) = .empty,
    lock: std.atomic.Mutex = .unlocked,

    const Chunk = struct { va: u64, mem: []align(page) u8 };

    /// A segment of `len` zeroed bytes at `base`, attached to nothing yet;
    /// `len` may be 0.
    pub fn create(gpa: std.mem.Allocator, backend: vmm.Backend, kind: Kind, perms: vmm.Perms, base: u64, len: u64) Error!*Segment {
        std.debug.assert(base % page == 0 and len % page == 0);
        const s = try gpa.create(Segment);
        s.* = .{ .gpa = gpa, .backend = backend, .kind = kind, .perms = perms, .base = base, .top = base + len, .brk = base + len };
        errdefer s.free();
        if (len > 0) {
            try s.chunks.ensureUnusedCapacity(gpa, 1);
            s.chunks.appendAssumeCapacity(.{ .va = base, .mem = try backend.allocPages(len / page) });
        }
        return s;
    }

    /// Frees a segment that's attached to nothing.
    fn free(s: *Segment) void {
        std.debug.assert(s.attached.items.len == 0);
        for (s.chunks.items) |c| s.backend.freePages(c.mem);
        s.chunks.deinit(s.gpa);
        s.attached.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    fn lockSpin(s: *Segment) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// The mapped range.
    fn span(s: *Segment) Span {
        s.lockSpin();
        defer s.lock.unlock();
        return .{ .lo = s.base, .hi = s.top };
    }

    /// How many address spaces it's attached to.
    fn refs(s: *Segment) usize {
        s.lockSpin();
        defer s.lock.unlock();
        return s.attached.items.len;
    }

    /// Maps the segment into `as`. A segment attached to nothing is freed
    /// if this fails, so callers can hand over a fresh one.
    pub fn attach(s: *Segment, as: vmm.AddressSpace) Error!void {
        s.lockSpin();
        attachLocked(s, as) catch |e| {
            const orphan = s.attached.items.len == 0;
            s.lock.unlock();
            if (orphan) s.free();
            return e;
        };
        s.lock.unlock();
    }

    fn attachLocked(s: *Segment, as: vmm.AddressSpace) Error!void {
        try s.attached.ensureUnusedCapacity(s.gpa, 1);
        for (s.chunks.items, 0..) |c, i| {
            as.map(c.va, c.mem, s.perms) catch |e| {
                for (s.chunks.items[0..i]) |m| as.unmap(m.va);
                return e;
            };
        }
        s.attached.appendAssumeCapacity(as);
    }

    /// Unmaps the segment from `as`, and frees it if that was the last.
    pub fn detach(s: *Segment, as: vmm.AddressSpace) void {
        s.lockSpin();
        for (s.attached.items, 0..) |a, i| if (std.meta.eql(a, as)) {
            for (s.chunks.items) |c| as.unmap(c.va);
            _ = s.attached.swapRemove(i);
            break;
        };
        const last = s.attached.items.len == 0;
        s.lock.unlock();
        if (last) s.free();
    }

    /// A private copy of the segment's pages, attached to nothing (rfork's
    /// eager copy).
    pub fn copy(s: *Segment) Error!*Segment {
        s.lockSpin();
        defer s.lock.unlock();
        const n = try create(s.gpa, s.backend, s.kind, s.perms, s.base, s.top - s.base);
        n.brk = s.brk;
        n.cexec = s.cexec;
        for (s.chunks.items) |c| copySparse(n.chunks.items[0].mem[c.va - s.base ..][0..c.mem.len], c.mem);
        return n;
    }

    /// Adds zeroed pages at [va, va+len) and maps them everywhere the
    /// segment is attached. The caller holds the lock and keeps the chunks
    /// contiguous.
    fn addChunkLocked(s: *Segment, va: u64, len: u64, at: usize) Error!void {
        try s.chunks.ensureUnusedCapacity(s.gpa, 1);
        const mem = try s.backend.allocPages(len / page);
        for (s.attached.items, 0..) |as, i| {
            as.map(va, mem, s.perms) catch |e| {
                for (s.attached.items[0..i]) |m| m.unmap(va);
                s.backend.freePages(mem);
                return e;
            };
        }
        s.chunks.insertAssumeCapacity(at, .{ .va = va, .mem = mem });
    }

    fn growUpLocked(s: *Segment, top: u64) Error!void {
        if (top <= s.top) return;
        try s.addChunkLocked(s.top, top - s.top, s.chunks.items.len);
        s.top = top;
    }

    fn growDownLocked(s: *Segment, base: u64) Error!void {
        if (base >= s.base) return;
        try s.addChunkLocked(base, s.base - base, 0);
        s.base = base;
    }

    /// Zeroes [from, to) within the mapped part of the segment.
    fn zeroLocked(s: *Segment, from: u64, to: u64) void {
        for (s.chunks.items) |c| {
            const lo = @max(from, c.va);
            const hi = @min(to, c.va + c.mem.len);
            if (lo < hi) @memset(c.mem[lo - c.va .. hi - c.va], 0);
        }
    }

    /// Frees the chunks that lie wholly at or above `top`. A chunk that
    /// straddles it stays, so the segment may end above `top`.
    fn shrinkLocked(s: *Segment, top: u64) void {
        while (s.chunks.items.len > 0) {
            const c = s.chunks.items[s.chunks.items.len - 1];
            if (c.va < top) break;
            for (s.attached.items) |as| as.unmap(c.va);
            s.backend.freePages(c.mem);
            _ = s.chunks.pop();
            s.top = c.va;
        }
    }

    /// Ends the mapping exactly at `top` (page-aligned, within the
    /// segment): frees the chunks above it, and splits one that straddles
    /// it by copying its lower part into a new chunk, which replaces it in
    /// every address space. Only for a segment no other process can be
    /// writing, since a write to the old chunk during the copy is lost.
    fn cutLocked(s: *Segment, top: u64) Error!void {
        std.debug.assert(top % page == 0 and top >= s.base);
        s.shrinkLocked(top);
        if (s.top > top) {
            const at = s.chunks.items.len - 1;
            const old = s.chunks.items[at];
            const mem = try s.backend.allocPages((top - old.va) / page);
            @memcpy(mem, old.mem[0..mem.len]);
            for (s.attached.items, 0..) |as, i| {
                as.unmap(old.va);
                as.map(old.va, mem, s.perms) catch |e| {
                    // Put the old chunk back where it was taken out.
                    as.map(old.va, old.mem, s.perms) catch {};
                    for (s.attached.items[0..i]) |m| {
                        m.unmap(old.va);
                        m.map(old.va, old.mem, s.perms) catch {};
                    }
                    s.backend.freePages(mem);
                    return e;
                };
            }
            s.backend.freePages(old.mem);
            s.chunks.items[at] = .{ .va = old.va, .mem = mem };
            s.top = top;
        }
        s.brk = @min(s.brk, s.top);
    }

    /// Moves the break to `want` (9front's ibrk), mapping up to `limit`.
    /// With `headroom`, the mapping grows ahead of the break in steps of at
    /// least `min_grow`, so a run of small sbrks maps few chunks (brk_);
    /// without, the segment ends exactly at the break (segbrk). Memory
    /// above the break reads as zero when it grows back.
    fn moveBreakLocked(s: *Segment, want: u64, limit: u64, headroom: bool) BrkError!void {
        std.debug.assert(want % page == 0 and want >= s.base and want <= limit);
        if (want >= s.brk) {
            if (want > s.top) {
                var top = want;
                if (headroom) {
                    const step = std.mem.alignForward(u64, std.math.clamp((s.top - s.base) / 2, min_grow, 4 << 20), page);
                    top = @min(@max(want, s.top + step), limit);
                }
                s.growUpLocked(top) catch {
                    // Without the headroom, if that's what didn't fit.
                    if (top == want) return error.NoVmem;
                    s.growUpLocked(want) catch return error.NoVmem;
                };
            }
            s.brk = want;
            return;
        }
        // A shared segment's pages may already be in another process's
        // syscall, so 9front refuses to shrink it.
        if (s.attached.items.len > 1) return error.InUse;
        if (headroom) {
            s.shrinkLocked(want);
        } else {
            s.cutLocked(want) catch return error.NoVmem;
        }
        s.zeroLocked(want, s.brk);
        s.brk = want;
    }
};

pub const BrkError = error{
    /// Out of range, or out of memory ("virtual memory allocation failed").
    NoVmem,
    /// Shrinking a segment shared with other processes.
    InUse,
    /// Growing into another segment ("segments overlap").
    Overlap,
};

/// The errors of segattach and the other segment calls, as 9front's.
pub const SegError = error{
    /// "bad arg in system call"
    BadArg,
    /// "virtual memory allocation failed"
    NoVmem,
    /// "segments overlap"
    Overlap,
    /// "device or object already in use"
    InUse,
};

/// The error string for a segment call's error.
pub fn errorString(e: SegError) []const u8 {
    return switch (e) {
        error.BadArg => "bad arg in system call",
        error.NoVmem => "virtual memory allocation failed",
        error.Overlap => "segments overlap",
        error.InUse => "device or object already in use",
    };
}

/// segattach's attribute bits that h9 uses (9front's portdat.h); the rest
/// are ignored, as 9front ignores what a class doesn't use.
pub const SG_RONLY = 0o040;
pub const SG_CEXEC = 0o100;

/// Slots for segattach's segments: 9front has ten, of which text, data,
/// bss, stack and exec's temporary stack use five.
pub const max_extra = 5;

/// An address range [lo, hi).
pub const Span = struct {
    lo: u64,
    hi: u64,

    fn overlaps(a: Span, b: Span) bool {
        return a.lo < b.hi and b.lo < a.hi;
    }
};

/// Where segattach puts a segment, as 9front's segattach: `va` is rounded
/// down to a page and `len` up so the segment covers [va, va+len). With
/// `va` 0, it picks a hole: just below `floor` (the stack's lowest
/// address), stepping below each range in `used` that's in the way. The
/// segment may not start at 0, reach past `top` (USTKTOP) or overlap
/// `used`.
pub fn place(used: []const Span, floor: u64, top: u64, va_in: u64, len_in: u64) SegError!Span {
    var va = va_in;
    if (va != 0 and va >= top) return error.BadArg;
    const rlen = std.math.add(u64, len_in, va % page) catch return error.BadArg;
    if (rlen > std.math.maxInt(u64) - page) return error.BadArg;
    const len = std.mem.alignForward(u64, rlen, page);
    if (len == 0) return error.BadArg;
    if (va == 0) {
        var below = floor;
        while (true) {
            if (len >= below) return error.NoVmem;
            va = below - len;
            below = (overlap(used, .{ .lo = va, .hi = va + len }) orelse break).lo;
        }
    }
    va = std.mem.alignBackward(u64, va, page);
    const end = std.math.add(u64, va, len) catch return error.BadArg;
    if (va == 0 or end > top) return error.BadArg;
    const sp: Span = .{ .lo = va, .hi = end };
    if (overlap(used, sp) != null) return error.Overlap;
    return sp;
}

fn overlap(used: []const Span, sp: Span) ?Span {
    for (used) |u| if (u.overlaps(sp)) return u;
    return null;
}

/// One process's segments.
pub const Segs = struct {
    text: ?*Segment = null,
    data: ?*Segment = null,
    stack: ?*Segment = null,
    /// segattach's segments, by slot; a detach leaves its slot empty, and
    /// the next attach takes the first empty one, as on 9front.
    extra: [max_extra]?*Segment = @splat(null),
    /// Lowest address the stack may grow down to; brk stops below it.
    stack_floor: u64 = 0,
    /// The top of the stack (USTKTOP), which no segment may reach past.
    ustktop: u64 = 0,
    /// The largest segment segattach makes (SEGMAXSIZE).
    seg_max: u64 = 0,
    /// Guards the slots against `segmentText`, which another thread calls
    /// for /proc/n/segment. Only the process's own thread changes them.
    lock: std.atomic.Mutex = .unlocked,

    fn lockSpin(s: *Segs) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Detaches every segment from `as`.
    pub fn release(s: *Segs, as: vmm.AddressSpace) void {
        s.lockSpin();
        defer s.lock.unlock();
        s.releaseLocked(as);
    }

    fn releaseLocked(s: *Segs, as: vmm.AddressSpace) void {
        inline for (.{ "text", "data", "stack" }) |f| if (@field(s, f)) |seg| {
            seg.detach(as);
            @field(s, f) = null;
        };
        for (&s.extra) |*slot| if (slot.*) |seg| {
            seg.detach(as);
            slot.* = null;
        };
    }

    /// Detaches every segment from `old`, then takes `new`'s (exec).
    pub fn replace(s: *Segs, old: vmm.AddressSpace, new: Segs) void {
        s.lockSpin();
        defer s.lock.unlock();
        s.releaseLocked(old);
        inline for (.{ "text", "data", "stack", "extra", "stack_floor", "ustktop", "seg_max" }) |f| @field(s, f) = @field(new, f);
    }

    /// The segments for an rfork child running in `as`: text and `shared`
    /// segments are shared, the stack is copied, and data and `memory`
    /// segments are shared with RFMEM (`share`) and copied without it.
    /// Each segment keeps its slot.
    pub fn fork(s: *const Segs, as: vmm.AddressSpace, share: bool) Error!Segs {
        var c: Segs = .{ .stack_floor = s.stack_floor, .ustktop = s.ustktop, .seg_max = s.seg_max };
        errdefer c.release(as);
        if (s.text) |t| {
            try t.attach(as);
            c.text = t;
        }
        if (s.data) |d| {
            const n = if (share) d else try d.copy();
            try n.attach(as);
            c.data = n;
        }
        if (s.stack) |st| {
            const n = try st.copy();
            try n.attach(as);
            c.stack = n;
        }
        for (s.extra, &c.extra) |e, *slot| if (e) |seg| {
            const n = if (share or seg.kind == .shared) seg else try seg.copy();
            try n.attach(as);
            slot.* = n;
        };
        return c;
    }

    /// exec: attaches `old`'s segattach segments to `as`, the new image's
    /// address space, in their slots, except those with SG_CEXEC and any
    /// that overlap the new image. On error, those attached so far stay in
    /// `s`, so releasing it detaches them.
    pub fn inherit(s: *Segs, old: *const Segs, as: vmm.AddressSpace) Error!void {
        for (old.extra, &s.extra) |e, *slot| if (e) |seg| {
            if (seg.cexec) continue;
            const span = seg.span();
            var clash = false;
            for (s.imageSpans()) |o| if (o) |sp| {
                clash = clash or span.overlaps(sp);
            };
            if (clash) continue;
            try seg.attach(as);
            slot.* = seg;
        };
    }

    /// Text, data up to its break, and the stack's whole range.
    fn imageSpans(s: *const Segs) [3]?Span {
        var out: [3]?Span = @splat(null);
        if (s.text) |t| out[0] = t.span();
        if (s.data) |d| {
            d.lockSpin();
            defer d.lock.unlock();
            out[1] = .{ .lo = d.base, .hi = d.brk };
        }
        if (s.stack != null) out[2] = .{ .lo = s.stack_floor, .hi = s.ustktop };
        return out;
    }

    /// The segment [va, va+len) would overlap, other than `skip`, with the
    /// data segment counted only up to its break.
    fn overlapping(s: *const Segs, sp: Span, skip: ?*Segment) ?Span {
        for (s.imageSpans()) |o| if (o) |x| if (x.overlaps(sp)) return x;
        for (s.extra) |e| if (e) |seg| if (seg != skip) {
            const x = seg.span();
            if (x.overlaps(sp)) return x;
        };
        return null;
    }

    /// Makes room for a segment at `sp` that overlaps nothing but perhaps
    /// the data segment's headroom above its break: trims the headroom to
    /// the break. Fails with Overlap if the data segment is shared, since
    /// a sibling could write it while a straddling chunk is copied.
    fn trimHeadroom(s: *Segs, sp: Span) SegError!void {
        const d = s.data orelse return;
        d.lockSpin();
        defer d.lock.unlock();
        if (!sp.overlaps(.{ .lo = d.brk, .hi = d.top })) return;
        if (d.attached.items.len > 1) return error.Overlap;
        d.cutLocked(d.brk) catch return error.NoVmem;
    }

    /// The ranges a new segment may not overlap: text, data up to its
    /// break, the stack's whole range, and segattach's segments.
    fn used(s: *const Segs, buf: *[3 + max_extra]Span) []const Span {
        var n: usize = 0;
        for (s.imageSpans()) |o| if (o) |x| {
            buf[n] = x;
            n += 1;
        };
        for (s.extra) |e| if (e) |seg| {
            buf[n] = seg.span();
            n += 1;
        };
        return buf[0..n];
    }

    /// segattach(attr, class, va, len), with 9front's placement rules
    /// (`place`), for the class `kind` (null for one h9 doesn't have).
    /// Errors are checked in 9front's order. Returns the base.
    pub fn segattach(s: *Segs, gpa: std.mem.Allocator, backend: vmm.Backend, as: vmm.AddressSpace, class: ?Kind, attr: u32, va: u64, len: u64) SegError!u64 {
        if (va != 0 and va >= s.ustktop) return error.BadArg;
        const slot = for (&s.extra) |*e| {
            if (e.* == null) break e;
        } else return error.NoVmem;
        var buf: [3 + max_extra]Span = undefined;
        const sp = try place(s.used(&buf), s.stack_floor, s.ustktop, va, len);
        const kind = class orelse return error.BadArg;
        std.debug.assert(kind == .shared or kind == .memory);
        if (sp.hi - sp.lo > s.seg_max) return error.NoVmem;
        try s.trimHeadroom(sp);

        const perms: vmm.Perms = .{ .write = attr & SG_RONLY == 0 };
        const seg = Segment.create(gpa, backend, kind, perms, sp.lo, sp.hi - sp.lo) catch return error.NoVmem;
        seg.cexec = attr & SG_CEXEC != 0;
        seg.attach(as) catch return error.NoVmem;
        s.lockSpin();
        slot.* = seg;
        s.lock.unlock();
        return sp.lo;
    }

    /// The segattach segment containing `addr`, or starting at it if it's
    /// empty, and its slot.
    fn extraAt(s: *Segs, addr: u64) ?*?*Segment {
        for (&s.extra) |*slot| if (slot.*) |seg| {
            const x = seg.span();
            if ((addr >= x.lo and addr < x.hi) or (x.lo == x.hi and addr == x.lo)) return slot;
        };
        return null;
    }

    /// segdetach(addr): detaches the segattach segment containing `addr`
    /// from `as`, which frees it if no other process has it. Text, data
    /// and stack can't be detached.
    pub fn segdetach(s: *Segs, as: vmm.AddressSpace, addr: u64) SegError!void {
        const slot = s.extraAt(addr) orelse return error.BadArg;
        const seg = slot.*.?;
        s.lockSpin();
        slot.* = null;
        s.lock.unlock();
        seg.detach(as);
    }

    /// segbrk(saddr, addr): moves the top of the segattach segment
    /// containing `saddr` to `addr`, rounded up. `addr` 0 returns its base.
    pub fn segbrk(s: *Segs, saddr: u64, addr: u64) SegError!u64 {
        var seg: *Segment = undefined;
        for (s.extra) |e| if (e) |x| {
            const sp = x.span();
            if (saddr >= sp.lo and saddr < sp.hi) {
                seg = x;
                break;
            }
        } else return error.BadArg;
        if (addr == 0) return seg.base;
        if (addr < seg.base) return error.NoVmem;
        // Past the top it would overlap the stack, as on 9front.
        if (addr > s.ustktop) return error.Overlap;
        const top = std.mem.alignForward(u64, addr, page);
        if (top > seg.top) {
            const grow: Span = .{ .lo = seg.top, .hi = top };
            if (s.overlapping(grow, seg) != null) return error.Overlap;
            if (top - seg.base > s.seg_max) return error.NoVmem;
            try s.trimHeadroom(grow);
        }
        seg.lockSpin();
        defer seg.lock.unlock();
        seg.moveBreakLocked(top, top, false) catch |e| return switch (e) {
            error.InUse => error.InUse,
            error.NoVmem, error.Overlap => error.NoVmem,
        };
        return 0;
    }

    /// The segment whose mapped part contains `addr`.
    fn segmentAt(s: *const Segs, addr: u64) ?*Segment {
        inline for (.{ "text", "data", "stack" }) |f| if (@field(s, f)) |seg| {
            const sp = seg.span();
            if (addr >= sp.lo and addr < sp.hi) return seg;
        };
        for (s.extra) |e| if (e) |seg| {
            const sp = seg.span();
            if (addr >= sp.lo and addr < sp.hi) return seg;
        };
        return null;
    }

    /// segfree(va, len): zeroes the whole pages of the span in a segattach
    /// segment; for text, data and stack it does nothing, which the manual
    /// allows. The pages stay allocated, so other processes sharing the
    /// segment see the zeros.
    pub fn segfree(s: *Segs, va: u64, len: u64) SegError!void {
        const to_raw = std.math.add(u64, va, len) catch return error.BadArg;
        const seg = s.segmentAt(va) orelse return error.BadArg;
        const to = std.mem.alignBackward(u64, to_raw, page);
        if (va > std.math.maxInt(u64) - page) return error.BadArg;
        const from = std.mem.alignForward(u64, va, page);
        if (from >= to) return;
        seg.lockSpin();
        defer seg.lock.unlock();
        if (to > seg.top) return error.BadArg;
        if (seg.kind == .shared or seg.kind == .memory) seg.zeroLocked(from, to);
    }

    /// segflush(va, len): checks that the span's pages are all in
    /// segments. Nothing runs from segattach segments, and the backends
    /// keep data coherent across vCPUs, so there's nothing to flush.
    pub fn segflush(s: *Segs, va: u64, len: u64) SegError!void {
        const end = std.math.add(u64, va, len) catch return error.BadArg;
        if (end > std.math.maxInt(u64) - page) return error.BadArg;
        var from = std.mem.alignBackward(u64, va, page);
        const to = std.mem.alignForward(u64, end, page);
        while (from < to) {
            const seg = s.segmentAt(from) orelse return error.BadArg;
            from = @min(seg.span().hi, to);
        }
    }

    /// Whether guest [va, va+len) lies in the data or stack segment or a
    /// writable segattach segment, which the guest may write. Host access
    /// to guest memory ignores page permissions, so the kernel checks this
    /// before writing where the guest says, as 9front's okaddr does for a
    /// note handler's frame.
    pub fn writable(s: *const Segs, va: u64, len: u64) bool {
        if (va +% len < va) return false;
        inline for (.{ "data", "stack" }) |f| if (@field(s, f)) |seg| {
            const sp = seg.span();
            if (va >= sp.lo and va + len <= sp.hi) return true;
        };
        for (s.extra) |e| if (e) |seg| if (seg.perms.write) {
            const sp = seg.span();
            if (va >= sp.lo and va + len <= sp.hi) return true;
        };
        return false;
    }

    /// Bytes mapped for the process, for /proc/n/status.
    pub fn mapped(s: *const Segs) u64 {
        var n: u64 = 0;
        inline for (.{ "text", "data", "stack" }) |f| if (@field(s, f)) |seg| {
            const sp = seg.span();
            n += sp.hi - sp.lo;
        };
        for (s.extra) |e| if (e) |seg| {
            const sp = seg.span();
            n += sp.hi - sp.lo;
        };
        return n;
    }

    /// /proc/n/segment, in 9front's format and slot order: the stack,
    /// text, data up to its break, then the segattach segments. The count
    /// is the address spaces each is attached to. Safe from any thread.
    pub fn segmentText(s: *Segs, buf: []u8) usize {
        s.lockSpin();
        defer s.lock.unlock();
        var w: std.Io.Writer = .fixed(buf);
        if (s.stack) |seg| line(&w, "Stack", false, s.stack_floor, s.ustktop, seg.refs());
        if (s.text) |seg| line(&w, "Text", true, seg.base, seg.top, seg.refs());
        if (s.data) |seg| {
            seg.lockSpin();
            const base = seg.base;
            const brk_ = seg.brk;
            const refs = seg.attached.items.len;
            seg.lock.unlock();
            line(&w, "Data", false, base, brk_, refs);
        }
        for (s.extra) |e| if (e) |seg| {
            const sp = seg.span();
            line(&w, if (seg.kind == .shared) "Shared" else "Bss", !seg.perms.write, sp.lo, sp.hi, seg.refs());
        };
        return w.end;
    }

    fn line(w: *std.Io.Writer, name: []const u8, ronly: bool, base: u64, top: u64, refs: usize) void {
        w.print("{s: <6} {c}  {x: >8} {x: >8} {d: >4}\n", .{ name, @as(u8, if (ronly) 'R' else ' '), base, top, refs }) catch {};
    }

    /// The current break.
    pub fn brkTop(s: *const Segs) u64 {
        const d = s.data orelse return 0;
        d.lockSpin();
        defer d.lock.unlock();
        return d.brk;
    }

    /// Moves the break to `addr` (9front's ibrk), rounded up to a page. The
    /// data segment's mapping grows to cover it, and gives back whole chunks
    /// above it. With RFMEM the break is shared, since the segment is. It
    /// stops at the stack's floor, and below any segattach segment above
    /// the data.
    pub fn brk(s: *Segs, addr: u64) BrkError!void {
        const d = s.data orelse return error.NoVmem;
        if (addr < d.base or addr > s.stack_floor) return error.NoVmem;
        const want = std.mem.alignForward(u64, addr, page);
        if (want > s.stack_floor) return error.NoVmem;
        var limit = s.stack_floor;
        for (s.extra) |e| if (e) |seg| if (seg.base >= d.base) {
            limit = @min(limit, seg.base);
        };
        if (want > limit) return error.Overlap;
        d.lockSpin();
        defer d.lock.unlock();
        return d.moveBreakLocked(want, limit, true);
    }

    /// Grows the stack down so that `addr` and `stack_slack` below it are
    /// mapped. Returns whether `addr` is now mapped stack. Called on faults,
    /// and at each syscall with the SP, so that buffers on the stack that
    /// the guest hasn't touched yet are mapped before the kernel uses them.
    pub fn growStack(s: *Segs, addr: u64) bool {
        const st = s.stack orelse return false;
        st.lockSpin();
        defer st.lock.unlock();
        if (addr >= st.top or addr < s.stack_floor) return false;
        if (addr >= st.base + stack_slack or (addr >= st.base and st.base == s.stack_floor)) return true;
        // At least double, so a deep stack takes few chunks.
        const want = @min(std.mem.alignBackward(u64, addr, page) -| stack_slack, st.base -| (st.top - st.base));
        st.growDownLocked(@max(want, s.stack_floor)) catch return addr >= st.base;
        return true;
    }
};

const testing = std.testing;
const arm64_top: u64 = 0x7FFFF0000;
const arm64_floor: u64 = arm64_top - (16 << 20);

test "place: va 0 goes below the stack, stepping below each segment in the way" {
    const stack: Span = .{ .lo = arm64_floor, .hi = arm64_top };
    const text: Span = .{ .lo = 0x10000, .hi = 0x20000 };
    var used = [_]Span{ stack, text, undefined };
    const a = try place(used[0..2], arm64_floor, arm64_top, 0, 0x1000);
    try testing.expectEqual(Span{ .lo = arm64_floor - 0x1000, .hi = arm64_floor }, a);
    used[2] = a;
    const b = try place(&used, arm64_floor, arm64_top, 0, 100);
    try testing.expectEqual(Span{ .lo = a.lo - 0x1000, .hi = a.lo }, b);
    // Too big for the space below the stack.
    try testing.expectError(error.NoVmem, place(used[0..2], arm64_floor, arm64_top, 0, arm64_floor));
}

test "place: rounding, overlap and the bounds" {
    const used = [_]Span{.{ .lo = 0x100000, .hi = 0x102000 }};
    // va rounds down and len up, so the segment covers [va, va+len).
    try testing.expectEqual(Span{ .lo = 0x200000, .hi = 0x202000 }, try place(&used, arm64_floor, arm64_top, 0x200ff0, 0x20));
    try testing.expectError(error.Overlap, place(&used, arm64_floor, arm64_top, 0x101000, 0x1000));
    try testing.expectError(error.Overlap, place(&used, arm64_floor, arm64_top, 0xff000, 0x2000));
    // Just beside it is fine.
    _ = try place(&used, arm64_floor, arm64_top, 0x102000, 0x1000);
    _ = try place(&used, arm64_floor, arm64_top, 0xff000, 0x1000);
    try testing.expectError(error.BadArg, place(&used, arm64_floor, arm64_top, 0x1000, 0));
    try testing.expectError(error.BadArg, place(&used, arm64_floor, arm64_top, 0x800, 0x100)); // rounds to page 0
    try testing.expectError(error.BadArg, place(&used, arm64_floor, arm64_top, arm64_top, 0x1000));
    try testing.expectError(error.BadArg, place(&used, arm64_floor, arm64_top, arm64_top - 0x1000, 0x2000));
    _ = try place(&used, arm64_floor, arm64_top, arm64_top - 0x1000, 0x1000);
}

test "place: wraparound is a bad arg" {
    const max = std.math.maxInt(u64);
    try testing.expectError(error.BadArg, place(&.{}, arm64_floor, max, 0x1000, max));
    try testing.expectError(error.BadArg, place(&.{}, arm64_floor, max, 0x1fff, max - 0xfff));
    try testing.expectError(error.BadArg, place(&.{}, arm64_floor, max, max - 0xfff, 0x2000));
    try testing.expectError(error.BadArg, place(&.{}, arm64_floor, max, 0, max));
}

test "segfree, segflush and segbrk check their arguments before using them" {
    var s: Segs = .{ .stack_floor = arm64_floor, .ustktop = arm64_top, .seg_max = 8 << 30 };
    const max = std.math.maxInt(u64);
    try testing.expectError(error.BadArg, s.segfree(max - 0xfff, 0x2000));
    try testing.expectError(error.BadArg, s.segfree(0x1000, 0x1000));
    try testing.expectError(error.BadArg, s.segflush(max - 0xfff, 0x2000));
    try testing.expectError(error.BadArg, s.segflush(max - 0xfff, 0x10));
    try testing.expectError(error.BadArg, s.segflush(0x1000, 0x1000));
    try testing.expectError(error.BadArg, s.segbrk(0x1000, 0x2000));
    try testing.expectError(error.BadArg, s.segdetach(.{ .fake = undefined }, 0x1000));
}

test "errorString matches 9front's" {
    try testing.expectEqualStrings("bad arg in system call", errorString(error.BadArg));
    try testing.expectEqualStrings("virtual memory allocation failed", errorString(error.NoVmem));
    try testing.expectEqualStrings("segments overlap", errorString(error.Overlap));
    try testing.expectEqualStrings("device or object already in use", errorString(error.InUse));
}
