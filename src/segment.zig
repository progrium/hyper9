//! A 9front process's segments, as named mappings in the kernel's Mm
//! (src/kern/mm.zig, design/memory-model.md): text, data (data and bss
//! together), and stack, plus up to five that segattach adds (`shared`
//! and `memory`). What's here is Plan 9's own: the segments' names and
//! classes (`Label`, on each mapping), segattach's placement, brk_ and
//! the seg* calls, and /proc/n/segment. Pages, faults, copy-on-write,
//! and the engine's mappings are the Mm's. See spec/kernel.md, "Process
//! model", and design/epoch-0/segattach.md.
//!
//! A process's address space is two Mms (`Space`). One holds text, data,
//! bss, and segattach's segments, and is shared by the RFMEM siblings an
//! rfork(RFMEM) makes, each mapping it into its own engine address space
//! (`Mm.attach`), so a brk or a segattach in one is seen by all of them,
//! as Linux threads share theirs. The other is the stack, which is always
//! the process's own and at the same address in each, so it can't be in
//! the shared one. rfork without RFMEM forks both, copy-on-write, as
//! cow-fork's fork does a Linux process's: so the data an RFMEM sibling
//! shares is still the child's own copy, as on 9front, which a mapping
//! shared between per-process Mms couldn't give.
//!
//! Text and the initialized part of data are private mappings of the
//! a.out (`loader.zig`), filled as they're touched; bss, the heap above
//! it, and the stack are anonymous, with pages on first touch. The stack
//! is its whole 16 MiB from exec, so it needs no growing.

const std = @import("std");
const engine = @import("engine.zig");
const kmm = @import("kern/mm.zig");
const gm = @import("guestmem.zig");
const aout = @import("abi/plan9/aout.zig");

const page = engine.page_size;
const Mm = kmm.Mm;
const Vma = kmm.Vma;

pub const Kind = enum(u3) {
    text = 1,
    data,
    stack,
    /// segattach's `shared` class: the same pages in rfork children.
    shared,
    /// segattach's `memory` class: copied by rfork like the bss, or shared
    /// with RFMEM.
    memory,
};

/// A mapping's segment, in its `Vma.label`: the kind, and for segattach's
/// segments, the slot (the order /proc/n/segment lists them in) and
/// SG_CEXEC.
pub const Label = packed struct(u8) {
    kind: u3,
    slot: u3 = 0,
    cexec: bool = false,
    _: u1 = 0,

    pub fn of(k: Kind) u8 {
        return @bitCast(Label{ .kind = @intFromEnum(k) });
    }

    pub fn get(v: Vma) ?Label {
        if (v.label == 0) return null;
        return @bitCast(v.label);
    }

    pub fn kindOf(l: Label) Kind {
        return @enumFromInt(l.kind);
    }

    fn extra(l: Label) bool {
        return l.kind == @intFromEnum(Kind.shared) or l.kind == @intFromEnum(Kind.memory);
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

/// A segment as its mappings make it: the span of the VMAs with one label.
pub const Seg = struct {
    label: Label,
    lo: u64,
    hi: u64,
    prot: kmm.Prot,
    shared: bool,

    fn span(s: Seg) Span {
        return .{ .lo = s.lo, .hi = s.hi };
    }
};

/// Room for a process's labelled VMAs: text, data, bss, and the heap,
/// which merge, and segattach's segments, which may be in pieces.
const max_vmas = 64;

/// One process's address space: its two Mms, mapped into the engine
/// address space it runs in, which is the caller's.
pub const Space = struct {
    /// Text, data and bss, and segattach's segments, shared with RFMEM
    /// siblings.
    mm: *Mm,
    /// The stack, [floor, top), the process's own.
    stack: *Mm,
    lay: aout.Layout,

    /// The lowest address the stack may use; brk stops below it.
    pub fn floor(s: *const Space) u64 {
        return s.lay.ustktop - s.lay.stack_size;
    }

    /// The Mm holding `va`.
    pub fn mmFor(s: *const Space, va: u64) *Mm {
        return if (va >= s.floor() and va < s.lay.ustktop) s.stack else s.mm;
    }

    /// Unmaps the space's pages from `as`, and drops its references.
    pub fn release(s: *Space, as: engine.AddressSpace) void {
        s.mm.detach(as);
        s.mm.put();
        s.stack.detach(as);
        s.stack.put();
        s.* = undefined;
    }

    /// The space of an rfork child running in `as`: the stack is its own,
    /// copy-on-write, and the rest is shared with RFMEM (`share`) or
    /// forked copy-on-write without, so text and the data and bss are
    /// each side's own once written, and segattach's `shared` segments
    /// are the same pages in both.
    pub fn fork(s: *const Space, as: engine.AddressSpace, share: bool) kmm.Error!Space {
        const mm = if (share) blk: {
            try s.mm.attach(as);
            break :blk s.mm.get();
        } else try s.mm.forkInto(as);
        errdefer {
            mm.detach(as);
            mm.put();
        }
        const st = try s.stack.forkInto(as);
        return .{ .mm = mm, .stack = st, .lay = s.lay };
    }

    // Guest memory, as the kernel reaches it for a syscall: through the
    // Mms, which fill pages on first touch and make a page copy-on-write
    // shares the process's own before the host writes it. Access is as
    // the mapping allows, as 9front's validaddr checks: a write into text
    // is a bad address.

    /// Copies between `buf` and guest [va, va+buf.len).
    pub fn copy(s: *const Space, va: u64, buf: []u8, to_guest: bool) gm.Error!void {
        const end = std.math.add(u64, va, buf.len) catch return error.BadAddress;
        var at = va;
        while (at < end) {
            const m = s.mmFor(at);
            const hi = if (m == s.stack) @min(end, s.lay.ustktop) else if (at < s.floor()) @min(end, s.floor()) else end;
            m.copy(at, buf[@intCast(at - va)..@intCast(hi - va)], to_guest) catch return error.BadAddress;
            at = hi;
        }
    }

    pub fn read(s: *const Space, va: u64, dst: []u8) gm.Error!void {
        return s.copy(va, dst, false);
    }

    pub fn write(s: *const Space, va: u64, data: []const u8) gm.Error!void {
        return s.copy(va, @constCast(data), true);
    }

    /// Makes [va, va+len) ready for the host, as `copy` checks it.
    pub fn touch(s: *const Space, va: u64, len: u64, write_: bool) gm.Error!void {
        const end = std.math.add(u64, va, len) catch return error.BadAddress;
        var at = va;
        while (at < end) {
            const m = s.mmFor(at);
            const hi = if (m == s.stack) @min(end, s.lay.ustktop) else if (at < s.floor()) @min(end, s.floor()) else end;
            m.touch(at, hi - at, write_) catch return error.BadAddress;
            at = hi;
        }
    }

    /// A little-endian word of `size` bytes (4 or 8), zero-extended.
    pub fn readWord(s: *const Space, va: u64, size: u64) gm.Error!u64 {
        var b: [8]u8 = @splat(0);
        try s.read(va, b[0..@intCast(size)]);
        return std.mem.readInt(u64, &b, .little);
    }

    /// Copies a NUL-terminated guest string into `buf`: BadAddress if
    /// it's unmapped before the NUL, or doesn't fit.
    pub fn string(s: *const Space, va: u64, buf: []u8) gm.Error![:0]u8 {
        var i: usize = 0;
        while (i < buf.len) {
            const at = va +% i;
            const n = @min(buf.len - i, page - at % page);
            try s.read(at, buf[i..][0..n]);
            if (std.mem.indexOfScalar(u8, buf[i..][0..n], 0)) |z| return buf[0 .. i + z :0];
            i += n;
        }
        return error.BadAddress;
    }

    /// Copies a NUL-terminated guest string of up to `max` bytes into new
    /// memory.
    pub fn stringAlloc(s: *const Space, va: u64, gpa: std.mem.Allocator, max: usize) (gm.Error || std.mem.Allocator.Error)![:0]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var pg: [page]u8 = undefined;
        while (true) {
            const at = va +% out.items.len;
            const n: usize = @intCast(page - at % page);
            try s.read(at, pg[0..n]);
            if (std.mem.indexOfScalar(u8, pg[0..n], 0)) |z| {
                if (out.items.len + z > max) return error.BadAddress;
                try out.appendSlice(gpa, pg[0..z]);
                return out.toOwnedSliceSentinel(gpa, 0);
            }
            if (out.items.len + n > max) return error.BadAddress;
            try out.appendSlice(gpa, pg[0..n]);
        }
    }

    /// Whether a mapping holds `va`.
    pub fn mapped(s: *const Space, va: u64) bool {
        return s.mmFor(va).mapped(va);
    }

    /// A hold on the pages behind a guest buffer (`Mm.pin`).
    pub const Pin = struct { mm: *Mm, p: Mm.Pinned };

    /// The contiguous host slice behind [va, va+len), held until `unpin`,
    /// or null if it isn't one (the caller copies through a buffer). With
    /// `write`, the pages are the process's own first.
    pub fn pin(s: *const Space, va: u64, len: u64, write_: bool) ?Pin {
        const m = s.mmFor(va);
        if (s.mmFor(va +% (len -| 1)) != m) return null;
        m.touch(va, len, write_) catch return null;
        return .{ .mm = m, .p = m.pin(va, len, write_) orelse return null };
    }

    pub fn unpin(_: *const Space, pn: *Pin) void {
        pn.mm.unpin(&pn.p);
    }

    /// Whether guest [va, va+len) lies in mappings the guest may write,
    /// as 9front's okaddr checks before the kernel writes a note
    /// handler's frame where the guest says.
    pub fn writable(s: *const Space, va: u64, len: u64) bool {
        if (va +% len < va) return false;
        const m = s.mmFor(va);
        if (len > 0 and s.mmFor(va + len - 1) != m) return false;
        return m.permits(va, len, true);
    }

    /// Bytes of guest memory the process has, for /proc/n/status.
    pub fn bytes(s: *const Space) u64 {
        return s.mm.bytes() + s.stack.bytes();
    }

    // The segments.

    /// The segments in the main Mm, by label, from its VMAs: each one's
    /// span is from its lowest VMA to its highest.
    fn segs(s: *const Space, out: *[3 + max_extra]?Seg) void {
        out.* = @splat(null);
        var buf: [max_vmas]Vma = undefined;
        for (s.mm.labelled(&buf)) |v| {
            const l = Label.get(v).?;
            const i: usize = switch (l.kindOf()) {
                .text => 0,
                .data => 1,
                .stack => 2,
                .shared, .memory => 3 + @as(usize, l.slot),
            };
            if (out[i]) |*g| {
                g.lo = @min(g.lo, v.start);
                g.hi = @max(g.hi, v.end);
            } else out[i] = .{ .label = l, .lo = v.start, .hi = v.end, .prot = v.prot, .shared = v.shared };
        }
    }

    /// The ranges a new segment may not overlap: text, data up to its
    /// break, the stack's whole range, and segattach's segments, but for
    /// the segment in slot `skip`.
    fn used(s: *const Space, buf: *[3 + max_extra]Span, skip: ?u3) []const Span {
        var all: [3 + max_extra]?Seg = undefined;
        s.segs(&all);
        var n: usize = 0;
        if (all[0]) |t| {
            buf[n] = t.span();
            n += 1;
        }
        buf[n] = .{ .lo = s.mm.brk_start, .hi = s.mm.brk };
        n += 1;
        buf[n] = .{ .lo = s.floor(), .hi = s.lay.ustktop };
        n += 1;
        for (all[3..], 0..) |o, i| if (o) |x| if (skip == null or skip.? != i) {
            buf[n] = x.span();
            n += 1;
        };
        return buf[0..n];
    }

    /// The segattach segment in slot `i`, if there is one.
    fn extraAt(s: *const Space, i: usize) ?Seg {
        var all: [3 + max_extra]?Seg = undefined;
        s.segs(&all);
        return all[3 + i];
    }

    /// The segattach segment containing `addr`, if any.
    fn extraHolding(s: *const Space, addr: u64) ?Seg {
        var all: [3 + max_extra]?Seg = undefined;
        s.segs(&all);
        for (all[3..]) |o| if (o) |x| if (addr >= x.lo and addr < x.hi) return x;
        return null;
    }

    /// Whether other processes have the segment's pages, so 9front won't
    /// shrink it: RFMEM siblings, or for a `shared` one, rfork children.
    fn sharedElsewhere(s: *const Space, g: Seg) bool {
        if (s.mm.nspaces() > 1) return true;
        if (!g.shared) return false;
        var at = g.lo - g.lo % kmm.chunk_size;
        while (at < g.hi) : (at += kmm.chunk_size) if (s.mm.pageRefs(@max(at, g.lo)) > 1) return true;
        return false;
    }

    /// Maps segattach's segment `v`, or more of one. A `memory` one's
    /// pages come on first touch, as any. A `shared` one's are its own,
    /// made now and beside whatever else is in their chunks
    /// (`Mm.insertOverlaid`), so an rfork child has the same pages however
    /// it gets the rest: segattach places segments at any page.
    fn add(s: *Space, v: Vma) kmm.Error!void {
        if (v.shared) return s.mm.insertOverlaid(v);
        return s.mm.insert(v);
    }

    /// segattach(attr, class, va, len), with 9front's placement rules
    /// (`place`), for the class `kind` (null for one h9 doesn't have).
    /// Errors are checked in 9front's order. Returns the base.
    pub fn segattach(s: *Space, io: std.Io, class: ?Kind, attr: u32, va: u64, len: u64) SegError!u64 {
        s.mm.opLock(io);
        defer s.mm.opUnlock(io);
        if (va != 0 and va >= s.lay.ustktop) return error.BadArg;
        const slot: u3 = for (0..max_extra) |i| {
            if (s.extraAt(i) == null) break @intCast(i);
        } else return error.NoVmem;
        var buf: [3 + max_extra]Span = undefined;
        const sp = try place(s.used(&buf, null), s.floor(), s.lay.ustktop, va, len);
        const kind = class orelse return error.BadArg;
        std.debug.assert(kind == .shared or kind == .memory);
        if (sp.hi - sp.lo > s.lay.seg_max) return error.NoVmem;
        const l: Label = .{ .kind = @intFromEnum(kind), .slot = slot, .cexec = attr & SG_CEXEC != 0 };
        s.add(.{
            .start = sp.lo,
            .end = sp.hi,
            .prot = .{ .read = true, .write = attr & SG_RONLY == 0 },
            .shared = kind == .shared,
            .label = @bitCast(l),
        }) catch return error.NoVmem;
        return sp.lo;
    }

    /// segdetach(addr): unmaps the segattach segment containing `addr`.
    /// Other processes keep their pages. Text, data and stack can't be
    /// detached.
    pub fn segdetach(s: *Space, io: std.Io, addr: u64) SegError!void {
        s.mm.opLock(io);
        defer s.mm.opUnlock(io);
        const g = s.extraHolding(addr) orelse return error.BadArg;
        s.mm.unmap(g.lo, g.hi) catch return error.NoVmem;
    }

    /// segbrk(saddr, addr): moves the top of the segattach segment
    /// containing `saddr` to `addr`, rounded up. `addr` 0 returns its
    /// base. A segment moved down to its base is detached, since a
    /// mapping can't be empty.
    pub fn segbrk(s: *Space, io: std.Io, saddr: u64, addr: u64) SegError!u64 {
        s.mm.opLock(io);
        defer s.mm.opUnlock(io);
        const g = s.extraHolding(saddr) orelse return error.BadArg;
        if (addr == 0) return g.lo;
        if (addr < g.lo) return error.NoVmem;
        // Past the top it would overlap the stack, as on 9front.
        if (addr > s.lay.ustktop) return error.Overlap;
        const top = std.mem.alignForward(u64, addr, page);
        if (top > g.hi) {
            const grow: Span = .{ .lo = g.hi, .hi = top };
            var buf: [3 + max_extra]Span = undefined;
            if (overlap(s.used(&buf, g.label.slot), grow) != null) return error.Overlap;
            if (top - g.lo > s.lay.seg_max) return error.NoVmem;
            s.add(.{ .start = g.hi, .end = top, .prot = g.prot, .shared = g.shared, .label = @bitCast(g.label) }) catch return error.NoVmem;
        } else if (top < g.hi) {
            // A shared segment's pages may already be in another
            // process's syscall, so 9front refuses to shrink it.
            if (s.sharedElsewhere(g)) return error.InUse;
            s.mm.unmap(top, g.hi) catch return error.NoVmem;
        }
        return 0;
    }

    /// The segment whose span contains `addr`: one in the main Mm, or the
    /// stack.
    fn segmentAt(s: *const Space, addr: u64) ?Seg {
        if (addr >= s.floor() and addr < s.lay.ustktop) return .{ .label = @bitCast(Label.of(.stack)), .lo = s.floor(), .hi = s.lay.ustktop, .prot = .rw, .shared = false };
        var all: [3 + max_extra]?Seg = undefined;
        s.segs(&all);
        for (all) |o| if (o) |x| if (addr >= x.lo and addr < x.hi) return x;
        return null;
    }

    /// segfree(va, len): the whole pages of the span in a segattach
    /// segment read as zero again; for text, data and stack it does
    /// nothing, which the manual allows. A `memory` segment's go back to
    /// the engine (`Mm.discard`); a `shared` one's are zeroed in place, so
    /// other processes sharing it see the zeros.
    pub fn segfree(s: *Space, va: u64, len: u64) SegError!void {
        const to_raw = std.math.add(u64, va, len) catch return error.BadArg;
        const g = s.segmentAt(va) orelse return error.BadArg;
        const to = std.mem.alignBackward(u64, to_raw, page);
        if (va > std.math.maxInt(u64) - page) return error.BadArg;
        const from = std.mem.alignForward(u64, va, page);
        if (from >= to) return;
        if (to > g.hi) return error.BadArg;
        if (!g.label.extra()) return;
        if (g.shared) {
            s.mm.hostEach(from, to - from, {}, struct {
                fn f(_: void, dst: []u8, _: u64) void {
                    @memset(dst, 0);
                }
            }.f) catch return error.NoVmem;
        } else s.mm.discard(from, to) catch return error.NoVmem;
    }

    /// segflush(va, len): checks that the span's pages are all in
    /// segments. The caller tells the engine the span's code may have
    /// changed.
    pub fn segflush(s: *Space, va: u64, len: u64) SegError!void {
        const end = std.math.add(u64, va, len) catch return error.BadArg;
        if (end > std.math.maxInt(u64) - page) return error.BadArg;
        var from = std.mem.alignBackward(u64, va, page);
        const to = std.mem.alignForward(u64, end, page);
        while (from < to) {
            const g = s.segmentAt(from) orelse {
                // Data's span is to its break, and the break is a page.
                if (from >= s.mm.brk_start and from < s.mm.brk) {
                    from = @min(s.mm.brk, to);
                    continue;
                }
                return error.BadArg;
            };
            from = @min(g.hi, to);
        }
    }

    /// /proc/n/segment, in 9front's format and slot order: the stack,
    /// text, data up to its break, then the segattach segments. The count
    /// is how many processes have each: the stack is the process's own,
    /// text the a.out's mapping's, and the rest the RFMEM siblings', or
    /// for a `shared` segment, rfork children's too. Safe from any
    /// thread.
    pub fn segmentText(s: *const Space, buf: []u8) usize {
        var w: std.Io.Writer = .fixed(buf);
        var all: [3 + max_extra]?Seg = undefined;
        s.segs(&all);
        const spaces = s.mm.nspaces();
        line(&w, "Stack", false, s.floor(), s.lay.ustktop, 1);
        if (all[0]) |t| line(&w, "Text", true, t.lo, t.hi, s.textRefs(t.lo));
        line(&w, "Data", false, s.mm.brk_start, s.mm.brk, spaces);
        for (all[3..]) |o| if (o) |g| {
            const refs = if (g.shared) @max(spaces, s.mm.pageRefs(g.lo)) else spaces;
            line(&w, if (g.label.kindOf() == .shared) "Shared" else "Bss", !g.prot.write, g.lo, g.hi, refs);
        };
        return w.end;
    }

    /// How many processes run the text at `va`: the references to its
    /// a.out's mapping (loader.zig's Image), one for each Mm, which RFMEM
    /// siblings share.
    fn textRefs(s: *const Space, va: u64) usize {
        var buf: [max_vmas]Vma = undefined;
        for (s.mm.labelled(&buf)) |v| if (v.start <= va and va < v.end) {
            const src = v.src orelse break;
            return @max(1, src.refs.load(.acquire)) + s.mm.nspaces() - 1;
        };
        return s.mm.nspaces();
    }

    fn line(w: *std.Io.Writer, name: []const u8, ronly: bool, base: u64, top: u64, refs: usize) void {
        w.print("{s: <6} {c}  {x: >8} {x: >8} {d: >4}\n", .{ name, @as(u8, if (ronly) 'R' else ' '), base, top, refs }) catch {};
    }

    /// The current break.
    pub fn brkTop(s: *const Space) u64 {
        return s.mm.brk;
    }

    /// Moves the break to `addr` (9front's ibrk), rounded up to a page.
    /// Memory above the break reads as zero when it grows back. With
    /// RFMEM the break is shared, since the Mm is. It stops at the
    /// stack's floor, and below any segattach segment above the data.
    pub fn brk(s: *Space, io: std.Io, addr: u64) BrkError!void {
        s.mm.opLock(io);
        defer s.mm.opUnlock(io);
        const m = s.mm;
        if (addr < m.brk_start or addr > s.floor()) return error.NoVmem;
        const want = std.mem.alignForward(u64, addr, page);
        if (want > s.floor()) return error.NoVmem;
        var limit = s.floor();
        var all: [3 + max_extra]?Seg = undefined;
        s.segs(&all);
        for (all[3..]) |o| if (o) |g| if (g.lo >= m.brk_start) {
            limit = @min(limit, g.lo);
        };
        if (want > limit) return error.Overlap;
        if (want > m.brk) {
            m.insert(.{ .start = m.brk, .end = want, .prot = .rw, .label = Label.of(.data) }) catch return error.NoVmem;
        } else if (want < m.brk) {
            // Another process's syscall may be using the pages.
            if (m.nspaces() > 1) return error.InUse;
            m.unmap(want, m.brk) catch return error.NoVmem;
        }
        m.brk = want;
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

test "a label keeps the kind, the slot and SG_CEXEC" {
    const l: Label = .{ .kind = @intFromEnum(Kind.memory), .slot = 4, .cexec = true };
    const v: Vma = .{ .start = 0, .end = page, .prot = .rw, .label = @bitCast(l) };
    try testing.expectEqual(Kind.memory, Label.get(v).?.kindOf());
    try testing.expectEqual(@as(u3, 4), Label.get(v).?.slot);
    try testing.expect(Label.get(v).?.cexec);
    try testing.expectEqual(@as(?Label, null), Label.get(.{ .start = 0, .end = page, .prot = .rw }));
}

test "errorString matches 9front's" {
    try testing.expectEqualStrings("bad arg in system call", errorString(error.BadArg));
    try testing.expectEqualStrings("virtual memory allocation failed", errorString(error.NoVmem));
    try testing.expectEqualStrings("segments overlap", errorString(error.Overlap));
    try testing.expectEqualStrings("device or object already in use", errorString(error.InUse));
}
