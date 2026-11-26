//! drawterm's allocb.c and qio.c (design/kernel-port.md): blocks, and the
//! I/O queues pipes, devmnt's conversations, and h9's streams are made
//! of. A close translation: the same functions in the same order, with
//! error unions in place of waserror, and h9's two patches kept: the
//! readiness hook (`h9_qwake`, which wakes Linux pollers whenever a
//! queue's state changes), and reader and writer locks that a note
//! interrupts (`qlockintr`).
//!
//! A process waits in a queue in three places, each one small function:
//! `qlockintr` (behind another reader or writer), `qwait` (for data), and
//! `qflow` (for room). Each waits in sync.zig's sleep or tsleep.
//!
//! A queue's kick and bypass functions are called with no lock held and
//! nothing to undo, as in C, but they mustn't raise: an error() there
//! would longjmp through these frames. No caller in h9 sets either.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;
const assert = port.assert;

const Block = c.Block;

const QDEBUG = false;

// allocb.c

const Hdrspc = 64; // leave room for high-level headers
const Tlrspc = 16; // extra room at the end for pad/crc/mac
const Bdead: usize = 0x51494F42; // "QIOB"

const BLOCKALIGN = c.BLOCKALIGN;

/// BLEN: the bytes in a block.
inline fn BLEN(b: *const Block) c_int {
    return @intCast(@as(isize, @bitCast(@intFromPtr(b.wp) -% @intFromPtr(b.rp))));
}

/// BALLOC: the bytes a block was allocated with.
inline fn BALLOC(b: *const Block) c_uint {
    return @truncate(@intFromPtr(b.lim) -% @intFromPtr(b.base));
}

/// The bytes from p up to q.
inline fn span(p: [*c]u8, q: [*c]u8) isize {
    return @bitCast(@intFromPtr(q) -% @intFromPtr(p));
}

fn _allocb(size_: c_int) ?*Block {
    const size: usize = @as(usize, @intCast(size_)) + Tlrspc;
    const raw = c.mallocz(@intCast(@sizeOf(Block) + size + Hdrspc), 0) orelse return null;
    const b: *Block = @ptrCast(@alignCast(raw));

    b.next = null;
    b.list = null;
    b.free = null;
    b.flag = 0;

    // Align the start of the data portion by rounding up.
    var addr: usize = @intFromPtr(b);
    addr = std.mem.alignForward(usize, addr + @sizeOf(Block), BLOCKALIGN);
    b.base = @ptrFromInt(addr);

    // Align the end of the data portion by rounding down.
    addr = @intFromPtr(b) + @sizeOf(Block) + size + Hdrspc;
    addr &= ~@as(usize, BLOCKALIGN - 1);
    b.lim = @ptrFromInt(addr);

    // Leave sluff at the beginning for added headers.
    b.rp = b.lim - std.mem.alignForward(usize, size, BLOCKALIGN);
    if (@intFromPtr(b.rp) < @intFromPtr(b.base))
        port.kpanic("_allocb", .{});
    b.wp = b.rp;

    return b;
}

pub fn allocb(size: c_int) *Block {
    return allocbAt(size, @returnAddress());
}

/// allocb, with the caller's pc for the malloc tag: the exported allocb
/// passes its C caller's.
fn allocbAt(size: c_int, pc: usize) *Block {
    // Check in a process and wait until successful.
    if (c._getproc() == null)
        port.kpanic("allocb without up: %#p", .{pc});
    const b = _allocb(size) orelse port.kpanic("allocb: no memory for %d bytes", .{size});
    c.setmalloctag(b, pc);

    return b;
}

pub fn iallocb(size: c_int) ?*Block {
    return iallocbAt(size, @returnAddress());
}

fn iallocbAt(size: c_int, pc: usize) ?*Block {
    const b = _allocb(size) orelse port.kpanic("iallocb: no memory for %d bytes", .{size});
    c.setmalloctag(b, pc);
    b.flag = c.BINTR;

    return b;
}

/// Stores Bdead in a pointer field: it isn't aligned for most pointer
/// types, so it goes in as the integer it is.
inline fn poison(field: anytype) void {
    @as(*usize, @ptrCast(field)).* = Bdead;
}

inline fn isdead(p: anytype) bool {
    return @intFromPtr(p) == Bdead;
}

pub fn freeb(b_: ?*Block) void {
    const b = b_ orelse return;

    // Drivers which perform non cache coherent DMA manage their own
    // buffer pool of uncached buffers and provide their own free routine.
    if (b.free) |f| {
        f(b);
        return;
    }

    // Poison the block in case someone is still holding onto it.
    poison(&b.next);
    poison(&b.rp);
    poison(&b.wp);
    poison(&b.lim);
    poison(&b.base);

    c.free(b);
}

pub fn checkb(b: *Block, msg: [*:0]const u8) void {
    if (isdead(b))
        port.kpanic("checkb b %s %#p", .{ msg, b });
    if (isdead(b.base) or isdead(b.lim) or isdead(b.next) or isdead(b.rp) or isdead(b.wp)) {
        port.print("checkb: base %#p lim %#p next %#p\n", .{ b.base, b.lim, b.next });
        port.print("checkb: rp %#p wp %#p\n", .{ b.rp, b.wp });
        port.kpanic("checkb dead: %s", .{msg});
    }

    if (@intFromPtr(b.base) > @intFromPtr(b.lim))
        port.kpanic("checkb 0 %s %#p %#p", .{ msg, b.base, b.lim });
    if (@intFromPtr(b.rp) < @intFromPtr(b.base))
        port.kpanic("checkb 1 %s %#p %#p", .{ msg, b.base, b.rp });
    if (@intFromPtr(b.wp) < @intFromPtr(b.base))
        port.kpanic("checkb 2 %s %#p %#p", .{ msg, b.base, b.wp });
    if (@intFromPtr(b.rp) > @intFromPtr(b.lim))
        port.kpanic("checkb 3 %s %#p %#p", .{ msg, b.rp, b.lim });
    if (@intFromPtr(b.wp) > @intFromPtr(b.lim))
        port.kpanic("checkb 4 %s %#p %#p", .{ msg, b.wp, b.lim });
}

// qio.c

/// h9: wakes Linux pollers (src/kern/linuxnet.c).
extern fn h9_qwake(q: *Queue) void;

/// h9: qlock for a queue's reader or writer lock, which a note
/// interrupts. A reader waiting behind another reader (one pipe that
/// several processes read, as a jobserver's is) otherwise sleeps in
/// qlock, which no note reaches, so a signal can't break its read:
/// cargo's and rustc's jobserver helpers each read the jobserver pipe and
/// are stopped with SIGUSR1, and wait forever. Waiting in tsleep instead,
/// a note raises Eintr as it does for the reader that holds the lock.
fn qlockintr(l: *c.QLock) Error!void {
    while (!sync.canqlock(l))
        try sync.tsleep(&up().ksleep, return0, null, 10); // lib.h names the field ksleep
}

fn return0(_: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

/// IO queues. C sees only `Queue*`.
pub const Queue = extern struct {
    lk: c.Lock,

    state: c_int,
    dlen: c_int, // data length in bytes
    rp: c_uint, // read position (counting BALLOC() bytes)
    wp: c_uint, // write position (counting BALLOC() bytes)
    limit: c_int, // max BALLOC() bytes in queue
    inilim: c_int, // initial limit
    noblock: u8, // true if writes return immediately when q full
    eof: u8, // number of eofs read by user

    bfirst: ?*Block, // buffer
    blast: ?*Block,

    arg: ?*anyopaque, // argument to kick and bypass
    kick: ?*const fn (?*anyopaque) callconv(.c) void, // restart output
    bypass: ?*const fn (?*anyopaque, ?*Block) callconv(.c) void, // bypass queue altogether

    rlock: c.QLock, // mutex for reading processes
    rr: c.Rendez, // process waiting to read

    wlock: c.QLock, // mutex for writing processes
    wr: c.Rendez, // process waiting to write

    err: [port.ERRMAX]u8,
};

const Maxatomic = 64 * 1024;

const Qstarve = c.Qstarve;
const Qmsg = c.Qmsg;
const Qclosed = c.Qclosed;
const Qflow = c.Qflow;
const Qcoalesce = c.Qcoalesce;
const Qkick = c.Qkick;

/// Free a list of blocks.
pub fn freeblist(b_: ?*Block) void {
    var b = b_;
    while (b) |bp| {
        const next: ?*Block = bp.next;
        bp.next = null;
        freeb(bp);
        b = next;
    }
}

/// Return the count of bytes in a string of blocks.
pub fn blocklen(bp_: ?*Block) c_int {
    var len: c_int = 0;
    var bp = bp_;
    while (bp) |b| {
        len += BLEN(b);
        bp = b.next;
    }
    return len;
}

/// Copy the contents of a string of blocks into memory from an offset.
/// The block list is kept unchanged. Return the number of bytes copied.
/// (o is drawterm's ulong, which is 32 bits.)
pub fn readblist(b_: ?*Block, p_: [*]u8, n_: c_int, o_: c_uint) c_int {
    var b = b_;
    var p = p_;
    var n = n_;
    var o: usize = o_;
    var r: usize = 0;
    while (n > 0) {
        const bp = b orelse break;
        var m: usize = @intCast(BLEN(bp));
        if (o >= m)
            o -= m
        else {
            m -= o;
            if (n < m)
                m = @intCast(n);
            @memmove(p[0..m], (bp.rp + o)[0..m]);
            p += m;
            r += m;
            n -= @intCast(m);
            o = 0;
        }
        b = bp.next;
    }
    return @intCast(r);
}

/// Copy the string of blocks into a single block and free the string.
pub fn concatblock(bp: *Block) ?*Block {
    if (bp.next == null)
        return bp;
    const len = blocklen(bp);
    return pullupblock(bp, len);
}

/// Make sure the first block has at least n bytes.
pub fn pullupblock(bp_: *Block, n_: c_int) ?*Block {
    var bp = bp_;
    var n = n_;
    assert(n >= 0);

    // This should almost always be true; it's just to avoid every caller
    // checking.
    if (BLEN(bp) >= n)
        return bp;

    // If there's not enough room in the first block, add another to the
    // front of the list.
    if (span(bp.rp, bp.lim) < n) {
        const nbp = allocb(n);
        nbp.next = bp;
        bp = nbp;
    }

    // Copy bytes from the trailing blocks into the first.
    n -= BLEN(bp);
    while (@as(?*Block, bp.next)) |nbp| {
        var i = BLEN(nbp);
        if (i > n) {
            const k: usize = @intCast(n);
            @memmove(bp.wp[0..k], nbp.rp[0..k]);
            bp.wp += k;
            nbp.rp += k;
            if (QDEBUG) checkb(bp, "pullupblock 1");
            return bp;
        } else {
            // Shouldn't happen, but why crash if it does.
            if (i < 0) {
                port.print("pullup negative length packet, called from %#p\n", .{@returnAddress()});
                i = 0;
            }
            const k: usize = @intCast(i);
            @memmove(bp.wp[0..k], nbp.rp[0..k]);
            bp.wp += k;
            bp.next = nbp.next;
            nbp.next = null;
            freeb(nbp);
            n -= i;
            if (n == 0) {
                if (QDEBUG) checkb(bp, "pullupblock 2");
                return bp;
            }
        }
    }
    freeb(bp);
    return null;
}

/// Make sure the first block has at least n bytes.
pub fn pullupqueue(q: *Queue, n: c_int) ?*Block {
    assert(n >= 0);

    if (BLEN(q.bfirst.?) >= n)
        return q.bfirst;
    q.bfirst = pullupblock(q.bfirst.?, n);
    var b = q.bfirst;
    while (b != null and b.?.next != null) : (b = b.?.next) {}
    q.blast = b;
    return q.bfirst;
}

/// Trim to len bytes starting at offset.
pub fn trimblock(bp_: *Block, offset_: c_int, len_: c_int) ?*Block {
    var bp = bp_;
    var offset = offset_;
    var len = len_;
    if (offset < 0 or len < 0) {
        freeblist(bp);
        return null;
    }
    if (QDEBUG) checkb(bp, "trimblock 1");
    var l: c_int = blocklen(bp);
    if (offset == 0 and len == l)
        return bp;
    if (l < offset + len) {
        freeblist(bp);
        return null;
    }

    while (true) {
        l = BLEN(bp);
        if (l >= offset) break;
        offset -= l;
        const nb = bp.next.?;
        bp.next = null;
        freeb(bp);
        bp = nb;
    }

    const startb = bp;
    bp.rp += @as(usize, @intCast(offset));

    while (true) {
        l = BLEN(bp);
        if (l >= len) break;
        len -= l;
        bp = bp.next.?;
    }

    bp.wp -= @as(usize, @intCast(BLEN(bp) - len));

    if (@as(?*Block, bp.next)) |next| {
        freeblist(next);
        bp.next = null;
    }

    return startb;
}

/// Pad a block to the front (or the back if size is negative).
pub fn padblock(bp: *Block, size_: c_int) *Block {
    var size = size_;
    var nbp: *Block = undefined;

    if (QDEBUG) checkb(bp, "padblock 0");
    if (size >= 0) {
        if (span(bp.base, bp.rp) >= size) {
            bp.rp -= @as(usize, @intCast(size));
            return bp;
        }
        const n: usize = @intCast(BLEN(bp));
        nbp = allocb(size + @as(c_int, @intCast(n)));
        nbp.rp += @as(usize, @intCast(size));
        nbp.wp = nbp.rp;
        @memmove(nbp.wp[0..n], bp.rp[0..n]);
        nbp.wp += n;
        nbp.rp -= @as(usize, @intCast(size));
    } else {
        size = -size;
        if (span(bp.wp, bp.lim) >= size)
            return bp;
        const n: usize = @intCast(BLEN(bp));
        nbp = allocb(@as(c_int, @intCast(n)) + size);
        @memmove(nbp.wp[0..n], bp.rp[0..n]);
        nbp.wp += n;
    }
    nbp.next = bp.next;
    freeb(bp);
    if (QDEBUG) checkb(nbp, "padblock 1");
    return nbp;
}

/// Copy `count` bytes into a new block.
pub fn copyblock(bp_: ?*Block, count_: c_int) *Block {
    var count = count_;
    assert(count >= 0);

    if (QDEBUG) if (bp_) |b| checkb(b, "copyblock 0");
    const nbp = allocb(count);
    var bp = bp_;
    while (count > 0) {
        const b = bp orelse break;
        var l = BLEN(b);
        if (l > count)
            l = count;
        const k: usize = @intCast(l);
        @memmove(nbp.wp[0..k], b.rp[0..k]);
        nbp.wp += k;
        count -= l;
        bp = b.next;
    }
    if (count > 0) {
        const k: usize = @intCast(count);
        @memset(nbp.wp[0..k], 0);
        nbp.wp += k;
    }
    if (QDEBUG) checkb(nbp, "copyblock 1");

    return nbp;
}

pub fn adjustblock(bp: *Block, len: c_int) ?*Block {
    if (len < 0) {
        freeb(bp);
        return null;
    }

    if (@intFromPtr(bp.rp) + @as(usize, @intCast(len)) > @intFromPtr(bp.lim)) {
        const nbp = copyblock(bp, len);
        freeblist(bp);
        if (QDEBUG) checkb(nbp, "adjustblock 1");

        return nbp;
    }

    const n = BLEN(bp);
    if (len > n)
        @memset(bp.wp[0..@intCast(len - n)], 0);
    bp.wp = bp.rp + @as(usize, @intCast(len));
    if (QDEBUG) checkb(bp, "adjustblock 2");

    return bp;
}

/// If the allocated space is way out of line with the used space,
/// reallocate to a smaller block.
pub fn packblock(bp_: ?*Block) ?*Block {
    var bp = bp_;
    var l: *?*Block = &bp;
    while (l.*) |nbp| : (l = &l.*.?.next) {
        const n = BLEN(nbp);
        if ((n << 2) < BALLOC(nbp)) {
            const k: usize = @intCast(n);
            const nb = allocb(n);
            l.* = nb;
            @memmove(nb.wp[0..k], nbp.rp[0..k]);
            nb.wp += k;
            nb.next = nbp.next;
            freeb(nbp);
        }
    }

    return bp;
}

/// Throw away up to count bytes from a list of blocks. Return the count
/// of bytes thrown away.
pub fn pullblock(bph_: ?*?*Block, count_: c_int) c_int {
    var count = count_;
    var bytes: c_int = 0;
    const bph = bph_ orelse return 0;

    while (count > 0) {
        const bp = bph.* orelse break;
        if (QDEBUG) checkb(bp, "pullblock ");
        var n = BLEN(bp);
        if (count < n)
            n = count;
        bytes += n;
        count -= n;
        bp.rp += @as(usize, @intCast(n));
        if (BLEN(bp) == 0) {
            bph.* = bp.next;
            bp.next = null;
            freeb(bp);
        }
    }
    return bytes;
}

/// Remove a block from the front of the queue.
pub fn qremove(q: *Queue) ?*Block {
    const b = q.bfirst orelse return null;
    if (QDEBUG) checkb(b, "qremove");
    q.bfirst = b.next;
    b.next = null;
    q.dlen -= BLEN(b);
    q.rp +%= BALLOC(b);
    return b;
}

/// Put a block back on the front of the queue.
pub fn qputback(q: *Queue, b: *Block) void {
    if (QDEBUG) checkb(b, "qputback");
    b.next = q.bfirst;
    if (q.bfirst == null)
        q.blast = b;
    q.bfirst = b;
    q.dlen += BLEN(b);
    q.rp -%= BALLOC(b);
}

/// After removing data from the queue, unlock the queue and wake up a
/// blocked writer. Called at interrupt level.
fn iunlock_consumer(q: *Queue) c_int {
    const s = q.state;

    // Stop flow control when back at or below the limit.
    if (@as(c_int, @bitCast(q.wp -% q.rp)) <= q.limit)
        q.state = s & ~@as(c_int, Qflow);

    c.iunlock(&q.lk);
    h9_qwake(q); // h9

    if (s & Qflow != 0) {
        // Wake up flow-controlled writers. Note that this is done even
        // when q.state still has Qflow set, as the unblocking condition
        // depends on the writers' local queuing position, not on the
        // global queue length.
        _ = sync.wakeup(&q.wr);
    }
    return s;
}

/// After removing data from the queue, unlock the queue and wake up a
/// blocked writer. Get output going again when it was blocked. Called
/// at process level.
fn iunlock_reader(q: *Queue) c_int {
    const s = iunlock_consumer(q);

    if (q.kick != null and s & Qflow != 0)
        q.kick.?(q.arg);

    return s;
}

/// After inserting into the queue, unlock the queue and wake up a
/// starved reader. Called at interrupt level.
fn iunlock_producer(q: *Queue) c_int {
    var s = q.state;

    // Start flow control when above the limit.
    if (@as(c_int, @bitCast(q.wp -% q.rp)) > q.limit)
        s |= Qflow;

    q.state = s & ~@as(c_int, Qstarve);
    c.iunlock(&q.lk);
    h9_qwake(q); // h9

    if (s & Qstarve != 0)
        _ = sync.wakeup(&q.rr);
    return s;
}

/// Unlock the queue and wake up a starved reader. Get output going again
/// when it was starved. Called at process level.
fn iunlock_writer(q: *Queue) c_int {
    const s = iunlock_producer(q);

    if (q.kick != null and s & (Qstarve | Qkick) != 0)
        q.kick.?(q.arg);

    return s;
}

/// Get the next block from a queue; null if there's nothing there.
/// Called at interrupt level.
pub fn qget(q: *Queue) ?*Block {
    c.ilock(&q.lk);
    const b = qremove(q) orelse {
        q.state |= Qstarve;
        c.iunlock(&q.lk);
        return null;
    };
    _ = iunlock_consumer(q);

    return b;
}

/// Interrupt-level copy out of a queue. Return the number of bytes
/// copied.
pub fn qconsume(q: *Queue, vp: [*]u8, len_: c_int) c_int {
    var len = len_;
    var tofree: ?*Block = null;
    var n: c_int = undefined;

    assert(len >= 0);

    c.ilock(&q.lk);
    const b: *Block = while (true) {
        const b = q.bfirst orelse {
            q.state |= Qstarve;
            len = -1;
            _ = iunlock_consumer(q);
            freeblist(tofree);
            return len;
        };
        if (QDEBUG) checkb(b, "qconsume 1");

        n = BLEN(b);
        if (n > 0)
            break b;

        // Get rid of zero-length blocks.
        q.bfirst = b.next;
        q.rp +%= BALLOC(b);

        // Remember to free this.
        b.next = tofree;
        tofree = b;
    };

    if (n < len)
        len = n;
    const k: usize = @intCast(len);
    @memmove(vp[0..k], b.rp[0..k]);
    b.rp += k;
    q.dlen -= len;

    // Discard the block if we're done with it.
    if ((q.state & Qmsg) != 0 or len == n) {
        q.bfirst = b.next;
        q.rp +%= BALLOC(b);
        q.dlen -= BLEN(b);

        // Remember to free this.
        b.next = tofree;
        tofree = b;
    }
    _ = iunlock_consumer(q);

    freeblist(tofree);

    return len;
}

/// Add a block list to a queue. Return the bytes added.
pub fn qaddlist(q: *Queue, b_: *Block) c_int {
    var b = b_;
    if (QDEBUG) checkb(b, "qaddlist 1");

    // Queue the block.
    if (q.bfirst != null)
        q.blast.?.next = b
    else
        q.bfirst = b;

    var len = BLEN(b);
    q.wp +%= BALLOC(b);
    while (@as(?*Block, b.next)) |next| {
        b = next;
        if (QDEBUG) checkb(b, "qaddlist 2");
        len += BLEN(b);
        q.wp +%= BALLOC(b);
    }
    q.dlen += len;
    q.blast = b;
    return len;
}

pub fn qpass(q: *Queue, b: *Block) c_int {
    c.ilock(&q.lk);
    if (q.state & Qclosed != 0) {
        c.iunlock(&q.lk);
        freeblist(b);
        return 0;
    }
    if (q.state & Qflow != 0) {
        c.iunlock(&q.lk);
        freeblist(b);
        return -1;
    }
    const len = qaddlist(q, b);
    _ = iunlock_producer(q);

    return len;
}

pub fn qpassnolim(q: *Queue, b: *Block) c_int {
    c.ilock(&q.lk);
    if (q.state & Qclosed != 0) {
        c.iunlock(&q.lk);
        freeblist(b);
        return 0;
    }
    const len = qaddlist(q, b);
    _ = iunlock_producer(q);

    return len;
}

pub fn qproduce(q: *Queue, vp: [*]const u8, len: c_int) c_int {
    assert(len >= 0);

    const b = iallocb(len) orelse return 0;

    // Save in the buffer.
    const k: usize = @intCast(len);
    @memmove(b.wp[0..k], vp[0..k]);
    b.wp += k;

    return qpass(q, b);
}

/// Copy from an offset in the queue.
pub fn qcopy(q: *Queue, len: c_int, offset: c_uint) *Block {
    assert(len >= 0);

    const b = allocb(len);
    c.ilock(&q.lk);
    b.wp += @as(usize, @intCast(readblist(q.bfirst, b.wp, len, offset)));
    c.iunlock(&q.lk);
    return b;
}

fn newqueue() ?*Queue {
    // malloc, as C's: drawterm's (kern/alloc.c) clears, so the locks and
    // the rest start zeroed.
    return @ptrCast(@alignCast(c.mallocz(@sizeOf(Queue), 1)));
}

/// Called by non-interrupt code.
pub fn qopen(limit: c_int, msg: c_int, kick: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) ?*Queue {
    assert(limit >= 0);

    const q = newqueue() orelse return null;

    q.dlen = 0;
    q.wp = 0;
    q.rp = 0;
    q.limit = limit;
    q.inilim = limit;
    q.kick = kick;
    q.arg = arg;
    q.state = msg | Qstarve;
    q.eof = 0;
    q.noblock = 0;

    return q;
}

/// Open a queue to be bypassed.
pub fn qbypass(bypass: ?*const fn (?*anyopaque, ?*Block) callconv(.c) void, arg: ?*anyopaque) ?*Queue {
    const q = newqueue() orelse return null;

    q.dlen = 0;
    q.wp = 0;
    q.rp = 0;
    q.limit = 0;
    q.arg = arg;
    q.bypass = bypass;
    q.state = 0;
    q.eof = 0;
    q.noblock = 0;

    return q;
}

fn notempty(a: ?*anyopaque) callconv(.c) c_int {
    const q: *Queue = @ptrCast(@alignCast(a));

    return @intFromBool(q.bfirst != null or (q.state & Qclosed) != 0);
}

/// Wait for the queue to be non-empty or closed. Called with q ilocked;
/// returns with it ilocked, unless sleep raised.
fn qwait(q: *Queue) Error!c_int {
    // Wait for data.
    while (true) {
        if (q.bfirst != null)
            break;

        if (q.state & Qclosed != 0) {
            if (q.eof >= 3 or (q.err[0] != 0 and c.strcmp(&q.err, &port.Ehungup) != 0))
                return -1;
            q.eof += 1;
            return 0;
        }

        q.state |= Qstarve; // flag requesting producer to wake me
        c.iunlock(&q.lk);
        try sync.sleep(&q.rr, notempty, q);
        c.ilock(&q.lk);
    }
    return 1;
}

/// Cut off n bytes from the end of h.*. Return a new block with the tail,
/// and change h.* to refer to the head.
fn splitblock(h: **Block, n: c_int) *Block {
    const a = h.*;
    const m = BLEN(a) - n;
    if (m < n) {
        const k: usize = @intCast(m);
        const b = allocb(m);
        @memmove(b.wp[0..k], a.rp[0..k]);
        b.wp += k;
        a.rp += k;
        h.* = b;
        return a;
    } else {
        const k: usize = @intCast(n);
        const b = allocb(n);
        a.wp -= k;
        @memmove(b.wp[0..k], a.wp[0..k]);
        b.wp += k;
        return b;
    }
}

/// Get the next block from a queue (up to a limit).
pub fn qbread(q: *Queue, len: c_int) Error!?*Block {
    assert(len >= 0);

    try qlockintr(&q.rlock);
    errdefer sync.qunlock(&q.rlock);

    c.ilock(&q.lk);
    switch (try qwait(q)) {
        0 => {
            // The queue is closed.
            c.iunlock(&q.lk);
            sync.qunlock(&q.rlock);
            return null;
        },
        -1 => {
            // Multiple reads on a closed queue.
            c.iunlock(&q.lk);
            return port.kerror(@ptrCast(&q.err));
        },
        else => {},
    }

    // If we get here, there's at least one block in the queue.
    var b = qremove(q).?;
    var n = BLEN(b);

    // Split the block if it's too big and this is not a message queue.
    if (n > len) {
        n -= len;
        if ((q.state & Qmsg) == 0)
            qputback(q, splitblock(&b, n))
        else
            b.wp -= @as(usize, @intCast(n));
    }
    _ = iunlock_reader(q);

    sync.qunlock(&q.rlock);

    return b;
}

/// Read a queue. If no data is queued, wait for some.
pub fn qread(q: *Queue, vp: [*]u8, len: c_int) Error!c_int {
    assert(len >= 0);

    try qlockintr(&q.rlock);
    errdefer sync.qunlock(&q.rlock);

    c.ilock(&q.lk);
    var first: *Block = undefined;
    var n: c_int = undefined;
    // `last` is where the last block taken is linked from: &first, or
    // the next of the block before it.
    var last: **Block = &first;
    again: while (true) {
        switch (try qwait(q)) {
            0 => {
                // The queue is closed.
                c.iunlock(&q.lk);
                sync.qunlock(&q.rlock);
                return 0;
            },
            -1 => {
                // Multiple reads on a closed queue.
                c.iunlock(&q.lk);
                return port.kerror(@ptrCast(&q.err));
            },
            else => {},
        }

        // If we get here, there's at least one block in the queue.
        last = &first;
        if (q.state & Qcoalesce != 0) {
            // When coalescing, 0 length blocks just go away.
            var b = q.bfirst.?;
            var m = BLEN(b);
            if (m <= 0) {
                freeb(qremove(q));
                continue :again;
            }
            // Grab the first block plus as many following blocks as will
            // partially fit in the read.
            n = 0;
            while (true) {
                last.* = qremove(q).?;
                n += m;
                if (n >= len or q.bfirst == null)
                    break;
                last = @ptrCast(&b.next);
                b = q.bfirst.?;
                m = BLEN(b);
            }
        } else {
            first = qremove(q).?;
            n = BLEN(first);
        }
        break;
    }

    // Split the last block if it's too big and this is not a message queue.
    if (n > len and (q.state & Qmsg) == 0)
        qputback(q, splitblock(last, n - len));

    _ = iunlock_reader(q);

    sync.qunlock(&q.rlock);

    // C guards this copy with waserror, for a fault on a user buffer;
    // h9 copies to and from guest memory outside the kernel, so it can't
    // fail here.
    const r = readblist(first, vp, len, 0);
    freeblist(first);

    return r;
}

/// A Flow represents a flow-controlled writer on queue q with position p.
const Flow = extern struct {
    q: *Queue,
    p: c_uint,
};

fn unblocked(a: ?*anyopaque) callconv(.c) c_int {
    const f: *Flow = @ptrCast(@alignCast(a));
    const q = f.q;

    return @intFromBool(q.noblock != 0 or @as(c_int, @bitCast(f.p -% q.rp)) <= q.limit or (q.state & Qclosed) != 0);
}

/// Flow control: wait for the queue to drain back to the limit.
fn qflow(f: *Flow) Error!void {
    const q = f.q;

    while (unblocked(f) == 0) {
        try qlockintr(&q.wlock);
        sync.sleep(&q.wr, unblocked, f) catch |e| {
            sync.qunlock(&q.wlock);
            return e;
        };
        sync.qunlock(&q.wlock);
    }
}

/// Add a block to a queue, obeying flow control.
pub fn qbwrite(q: *Queue, b: *Block) Error!c_int {
    if (q.bypass) |bypass| {
        const len = blocklen(b);
        bypass(q.arg, b);
        return len;
    }

    c.ilock(&q.lk);

    // Give up if the queue is closed.
    if (q.state & Qclosed != 0) {
        c.iunlock(&q.lk);
        freeblist(b);
        return port.kerror(@ptrCast(&q.err));
    }
    // If the queue is full, silently discard when non-blocking.
    if (q.state & Qflow != 0 and q.noblock != 0) {
        c.iunlock(&q.lk);
        const len = blocklen(b);
        freeblist(b);
        return len;
    }
    const len = qaddlist(q, b);

    // Save our current position in the queue for flow control below.
    var flow: Flow = .{ .q = q, .p = q.wp };
    if (iunlock_writer(q) & Qflow != 0) {
        // Flow control, before allowing the process to continue and
        // queue more. We do this here so that postnote can only interrupt
        // us after the data has been queued. This means that things like
        // 9P flushes and ssl messages will not be disrupted by software
        // interrupts.
        try qflow(&flow);
    }

    return len;
}

/// Write to a queue. Only Maxatomic bytes at a time is atomic.
pub fn qwrite(q: *Queue, vp: [*]const u8, len: c_int) Error!c_int {
    const p = vp;

    assert(len >= 0);

    var sofar: c_int = 0;
    while (true) {
        var n = len - sofar;
        if (n > Maxatomic)
            n = Maxatomic;

        const b = allocb(n);
        const k: usize = @intCast(n);
        // C guards this copy with waserror, as qread's.
        @memmove(b.wp[0..k], (p + @as(usize, @intCast(sofar)))[0..k]);
        b.wp += k;

        sofar += @intCast(try qbwrite(q, b));
        if (!(sofar < len and (q.state & Qmsg) == 0)) break;
    }

    return len;
}

/// Used by print() to write to a queue. Since we may be splhi or not in
/// a process, don't qlock.
pub fn qiwrite(q: *Queue, vp: [*]const u8, len: c_int) c_int {
    const p = vp;

    assert(len >= 0);

    var sofar: c_int = 0;
    while (true) {
        var n = len - sofar;
        if (n > Maxatomic)
            n = Maxatomic;

        const b = iallocb(n) orelse break;
        const k: usize = @intCast(n);
        @memmove(b.wp[0..k], (p + @as(usize, @intCast(sofar)))[0..k]);
        b.wp += k;

        if (q.bypass) |bypass| {
            sofar += n;
            bypass(q.arg, b);
        } else {
            c.ilock(&q.lk);
            if (q.state & (Qflow | Qclosed) != 0) {
                c.iunlock(&q.lk);
                freeb(b);
                break;
            }
            sofar += qaddlist(q, b);
            _ = iunlock_writer(q);
        }
        if (!(sofar < len and (q.state & Qmsg) == 0)) break;
    }

    return sofar;
}

/// Throw away the next `len` bytes in the queue.
pub fn qdiscard(q: *Queue, len: c_int) c_int {
    var tofree: ?*Block = null;

    assert(len >= 0);

    c.ilock(&q.lk);
    var sofar: c_int = 0;
    var n: c_int = 0;
    while (sofar < len) : (sofar += n) {
        const b = q.bfirst orelse break;
        if (QDEBUG) checkb(b, "qdiscard");
        n = BLEN(b);
        if (n <= len - sofar) {
            q.bfirst = b.next;
            q.rp +%= BALLOC(b);

            // Remember to free this.
            b.next = tofree;
            tofree = b;
        } else {
            n = len - sofar;
            b.rp += @as(usize, @intCast(n));
        }
        q.dlen -= n;
    }
    _ = iunlock_consumer(q);

    freeblist(tofree);

    return sofar;
}

/// Flush the output queue.
pub fn qflush(q: *Queue) void {
    c.ilock(&q.lk);
    const tofree = q.bfirst;
    q.bfirst = null;
    q.rp = q.wp;
    q.dlen = 0;
    _ = iunlock_consumer(q);

    freeblist(tofree);
}

/// Mark a queue as closed. No further IO is permitted. All blocks are
/// released.
pub fn qclose(q_: ?*Queue) void {
    const q = q_ orelse return;

    c.ilock(&q.lk);
    q.state |= Qclosed;
    q.state &= ~@as(c_int, Qflow | Qstarve);
    c.kstrcpy(&q.err, @constCast(&port.Ehungup), port.ERRMAX);
    const tofree = q.bfirst;
    q.bfirst = null;
    q.rp = q.wp;
    q.dlen = 0;
    q.noblock = 0;
    c.iunlock(&q.lk);

    // Wake up readers and writers.
    _ = sync.wakeup(&q.rr);
    _ = sync.wakeup(&q.wr);
    h9_qwake(q); // h9

    // Free queued blocks.
    freeblist(tofree);
}

/// Be extremely careful when calling this, as there is no reference
/// accounting.
pub fn qfree(q: *Queue) void {
    qclose(q);
    c.free(q);
}

/// Mark a queue as closed. Wake up any readers. Don't remove queued
/// blocks.
pub fn qhangup(q: *Queue, msg_: ?[*:0]const u8) void {
    var msg = msg_;
    c.ilock(&q.lk);
    q.state |= Qclosed;
    if (msg == null or msg.?[0] == 0)
        msg = &port.Ehungup;
    c.kstrcpy(&q.err, @constCast(msg.?), port.ERRMAX);
    c.iunlock(&q.lk);

    // Wake up readers and writers.
    _ = sync.wakeup(&q.rr);
    _ = sync.wakeup(&q.wr);
    h9_qwake(q); // h9
}

/// Return non-zero if the queue is hung up.
pub fn qisclosed(q: *Queue) c_int {
    return q.state & Qclosed;
}

/// Mark a queue as no longer hung up.
pub fn qreopen(q: *Queue) void {
    c.ilock(&q.lk);
    q.state &= ~@as(c_int, Qclosed);
    q.state |= Qstarve;
    q.eof = 0;
    q.limit = q.inilim;
    c.iunlock(&q.lk);
}

/// Return the bytes queued.
pub fn qlen(q: *Queue) c_int {
    return q.dlen;
}

/// Return true if we can read without blocking.
pub fn qcanread(q: *Queue) bool {
    return q.bfirst != null;
}

/// Return non-zero when the queue is full.
pub fn qfull(q: *Queue) c_int {
    return q.state & Qflow;
}

/// Change the queue's limit.
pub fn qsetlimit(q: *Queue, limit: c_int) void {
    assert(limit >= 0);

    c.ilock(&q.lk);
    q.limit = limit;
    _ = iunlock_consumer(q);
}

/// Set blocking or nonblocking.
pub fn qnoblock(q: *Queue, onoff: c_int) void {
    c.ilock(&q.lk);
    q.noblock = @truncate(@as(c_uint, @bitCast(onoff)));
    _ = iunlock_consumer(q);
}

// The C kernel's names, with its semantics: a function that fails raises
// its error.

const Kick = ?*const fn (?*anyopaque) callconv(.c) void;
const Bypass = ?*const fn (?*anyopaque, ?*Block) callconv(.c) void;

fn c_allocb(size: c_int) callconv(.c) *Block {
    return allocbAt(size, @returnAddress());
}
fn c_iallocb(size: c_int) callconv(.c) ?*Block {
    return iallocbAt(size, @returnAddress());
}
fn c_freeb(b: ?*Block) callconv(.c) void {
    freeb(b);
}
fn c_checkb(b: *Block, msg: [*:0]const u8) callconv(.c) void {
    checkb(b, msg);
}
fn c_freeblist(b: ?*Block) callconv(.c) void {
    freeblist(b);
}
fn c_blocklen(b: ?*Block) callconv(.c) c_int {
    return blocklen(b);
}
fn c_readblist(b: ?*Block, p: [*]u8, n: c_int, o: c_uint) callconv(.c) c_int {
    return readblist(b, p, n, o);
}
fn c_concatblock(b: *Block) callconv(.c) ?*Block {
    return concatblock(b);
}
fn c_pullupblock(b: *Block, n: c_int) callconv(.c) ?*Block {
    return pullupblock(b, n);
}
fn c_pullupqueue(q: *Queue, n: c_int) callconv(.c) ?*Block {
    return pullupqueue(q, n);
}
fn c_trimblock(b: *Block, offset: c_int, len: c_int) callconv(.c) ?*Block {
    return trimblock(b, offset, len);
}
fn c_padblock(b: *Block, size: c_int) callconv(.c) *Block {
    return padblock(b, size);
}
fn c_copyblock(b: ?*Block, count: c_int) callconv(.c) *Block {
    return copyblock(b, count);
}
fn c_adjustblock(b: *Block, len: c_int) callconv(.c) ?*Block {
    return adjustblock(b, len);
}
fn c_packblock(b: ?*Block) callconv(.c) ?*Block {
    return packblock(b);
}
fn c_pullblock(bph: ?*?*Block, count: c_int) callconv(.c) c_int {
    return pullblock(bph, count);
}
fn c_qremove(q: *Queue) callconv(.c) ?*Block {
    return qremove(q);
}
fn c_qputback(q: *Queue, b: *Block) callconv(.c) void {
    qputback(q, b);
}
fn c_qget(q: *Queue) callconv(.c) ?*Block {
    return qget(q);
}
fn c_qconsume(q: *Queue, vp: [*]u8, len: c_int) callconv(.c) c_int {
    return qconsume(q, vp, len);
}
fn c_qaddlist(q: *Queue, b: *Block) callconv(.c) c_int {
    return qaddlist(q, b);
}
fn c_qpass(q: *Queue, b: *Block) callconv(.c) c_int {
    return qpass(q, b);
}
fn c_qpassnolim(q: *Queue, b: *Block) callconv(.c) c_int {
    return qpassnolim(q, b);
}
fn c_qproduce(q: *Queue, vp: [*]const u8, len: c_int) callconv(.c) c_int {
    return qproduce(q, vp, len);
}
fn c_qcopy(q: *Queue, len: c_int, offset: c_uint) callconv(.c) *Block {
    return qcopy(q, len, offset);
}
fn c_qopen(limit: c_int, msg: c_int, kick: Kick, arg: ?*anyopaque) callconv(.c) ?*Queue {
    return qopen(limit, msg, kick, arg);
}
fn c_qbypass(bypass: Bypass, arg: ?*anyopaque) callconv(.c) ?*Queue {
    return qbypass(bypass, arg);
}
fn c_qbread(q: *Queue, len: c_int) callconv(.c) ?*Block {
    return qbread(q, len) catch |e| port.raise(e);
}
fn c_qread(q: *Queue, vp: [*]u8, len: c_int) callconv(.c) c_int {
    return qread(q, vp, len) catch |e| port.raise(e);
}
fn c_qbwrite(q: *Queue, b: *Block) callconv(.c) c_int {
    return qbwrite(q, b) catch |e| port.raise(e);
}
fn c_qwrite(q: *Queue, vp: [*]const u8, len: c_int) callconv(.c) c_int {
    return qwrite(q, vp, len) catch |e| port.raise(e);
}
fn c_qiwrite(q: *Queue, vp: [*]const u8, len: c_int) callconv(.c) c_int {
    return qiwrite(q, vp, len);
}
fn c_qdiscard(q: *Queue, len: c_int) callconv(.c) c_int {
    return qdiscard(q, len);
}
fn c_qflush(q: *Queue) callconv(.c) void {
    qflush(q);
}
fn c_qclose(q: ?*Queue) callconv(.c) void {
    qclose(q);
}
fn c_qfree(q: *Queue) callconv(.c) void {
    qfree(q);
}
fn c_qhangup(q: *Queue, msg: ?[*:0]const u8) callconv(.c) void {
    qhangup(q, msg);
}
fn c_qisclosed(q: *Queue) callconv(.c) c_int {
    return qisclosed(q);
}
fn c_qreopen(q: *Queue) callconv(.c) void {
    qreopen(q);
}
fn c_qlen(q: *Queue) callconv(.c) c_int {
    return qlen(q);
}
fn c_qcanread(q: *Queue) callconv(.c) c_int {
    return @intFromBool(qcanread(q));
}
fn c_qfull(q: *Queue) callconv(.c) c_int {
    return qfull(q);
}
fn c_qsetlimit(q: *Queue, limit: c_int) callconv(.c) void {
    qsetlimit(q, limit);
}
fn c_qnoblock(q: *Queue, onoff: c_int) callconv(.c) void {
    qnoblock(q, onoff);
}

/// qio.c's global: the bytes a qwrite writes at a time. (Nothing reads
/// it; qwrite uses Maxatomic, as in C.)
pub var qiomaxatomic: c_uint = Maxatomic;

pub fn exportC() void {
    @export(&c_allocb, .{ .name = "allocb" });
    @export(&c_iallocb, .{ .name = "iallocb" });
    @export(&c_freeb, .{ .name = "freeb" });
    @export(&c_checkb, .{ .name = "checkb" });
    @export(&c_freeblist, .{ .name = "freeblist" });
    @export(&c_blocklen, .{ .name = "blocklen" });
    @export(&c_readblist, .{ .name = "readblist" });
    @export(&c_concatblock, .{ .name = "concatblock" });
    @export(&c_pullupblock, .{ .name = "pullupblock" });
    @export(&c_pullupqueue, .{ .name = "pullupqueue" });
    @export(&c_trimblock, .{ .name = "trimblock" });
    @export(&c_padblock, .{ .name = "padblock" });
    @export(&c_copyblock, .{ .name = "copyblock" });
    @export(&c_adjustblock, .{ .name = "adjustblock" });
    @export(&c_packblock, .{ .name = "packblock" });
    @export(&c_pullblock, .{ .name = "pullblock" });
    @export(&c_qremove, .{ .name = "qremove" });
    @export(&c_qputback, .{ .name = "qputback" });
    @export(&c_qget, .{ .name = "qget" });
    @export(&c_qconsume, .{ .name = "qconsume" });
    @export(&c_qaddlist, .{ .name = "qaddlist" });
    @export(&c_qpass, .{ .name = "qpass" });
    @export(&c_qpassnolim, .{ .name = "qpassnolim" });
    @export(&c_qproduce, .{ .name = "qproduce" });
    @export(&c_qcopy, .{ .name = "qcopy" });
    @export(&c_qopen, .{ .name = "qopen" });
    @export(&c_qbypass, .{ .name = "qbypass" });
    @export(&c_qbread, .{ .name = "qbread" });
    @export(&c_qread, .{ .name = "qread" });
    @export(&c_qbwrite, .{ .name = "qbwrite" });
    @export(&c_qwrite, .{ .name = "qwrite" });
    @export(&c_qiwrite, .{ .name = "qiwrite" });
    @export(&c_qdiscard, .{ .name = "qdiscard" });
    @export(&c_qflush, .{ .name = "qflush" });
    @export(&c_qclose, .{ .name = "qclose" });
    @export(&c_qfree, .{ .name = "qfree" });
    @export(&c_qhangup, .{ .name = "qhangup" });
    @export(&c_qisclosed, .{ .name = "qisclosed" });
    @export(&c_qreopen, .{ .name = "qreopen" });
    @export(&c_qlen, .{ .name = "qlen" });
    @export(&c_qcanread, .{ .name = "qcanread" });
    @export(&c_qfull, .{ .name = "qfull" });
    @export(&c_qsetlimit, .{ .name = "qsetlimit" });
    @export(&c_qnoblock, .{ .name = "qnoblock" });
    @export(&qiomaxatomic, .{ .name = "qiomaxatomic" });
}

// Cases (zig build kern-test).

const testing = std.testing;
const kt = port.testing;

fn contents(b: *Block) []u8 {
    return b.rp[0..@intCast(BLEN(b))];
}

fn fill(b: *Block, s: []const u8) void {
    @memcpy(b.wp[0..s.len], s);
    b.wp += s.len;
}

fn blockOf(s: []const u8) *Block {
    const b = allocb(@intCast(s.len));
    fill(b, s);
    return b;
}

test "a block keeps headroom, and pads, trims, pulls up, and copies as C's did [kernel-port]" {
    _ = try kt.begin();
    const b = allocb(100);
    try testing.expectEqual(0, BLEN(b));
    try testing.expect(@intFromPtr(b.rp) % BLOCKALIGN == 0);
    // Hdrspc of headroom, less what aligning both ends cost.
    try testing.expect(span(b.base, b.rp) >= Hdrspc - 2 * BLOCKALIGN);
    try testing.expect(span(b.rp, b.lim) >= 100);
    checkb(b, "allocb");
    fill(b, "hello");

    // Padding at the front uses the headroom, and past it makes a new block.
    const p = padblock(b, 3);
    try testing.expectEqual(b, p);
    try testing.expectEqual(8, BLEN(p));
    try testing.expectEqualStrings("hello", contents(p)[3..]);
    const p2 = padblock(p, 1000);
    try testing.expectEqual(1008, BLEN(p2));
    try testing.expectEqualStrings("hello", contents(p2)[1003..]);
    // At the back, a negative size only makes room.
    const p3 = padblock(p2, -16);
    try testing.expect(span(p3.wp, p3.lim) >= 16);
    try testing.expectEqual(1008, BLEN(p3));

    // Trim to the middle of a list of three.
    const l = blockOf("abc");
    l.next = blockOf("defg");
    l.next.*.next = blockOf("hi");
    try testing.expectEqual(9, blocklen(l));
    var buf: [16]u8 = undefined;
    try testing.expectEqual(4, readblist(l, &buf, 4, 2));
    try testing.expectEqualStrings("cdef", buf[0..4]);
    const t = trimblock(l, 2, 5).?;
    try testing.expectEqual(5, blocklen(t));
    try testing.expectEqual(5, readblist(t, &buf, 16, 0));
    try testing.expectEqualStrings("cdefg", buf[0..5]);
    try testing.expectEqual(null, trimblock(blockOf("x"), 0, 2));

    // Pull up and concatenate.
    const u = pullupblock(t, 3).?;
    try testing.expect(BLEN(u) >= 3);
    try testing.expectEqual(5, blocklen(u));
    const cat = concatblock(u).?;
    try testing.expectEqual(null, @as(?*Block, cat.next));
    try testing.expectEqualStrings("cdefg", contents(cat));
    try testing.expectEqual(null, pullupblock(blockOf("ab"), 3));

    // Copy pads with zeros; adjust grows with zeros and shrinks.
    const cp = copyblock(cat, 7);
    try testing.expectEqualSlices(u8, "cdefg\x00\x00", contents(cp));
    const adj = adjustblock(cp, 3).?;
    try testing.expectEqualStrings("cde", contents(adj));
    const big = adjustblock(adj, 4096).?;
    try testing.expectEqual(4096, BLEN(big));
    try testing.expectEqual(0, big.rp[4095]);
    try testing.expectEqual(null, adjustblock(blockOf("z"), -1));

    // Pull bytes off the front, freeing what empties.
    var head: ?*Block = blockOf("12");
    head.?.next = blockOf("345");
    try testing.expectEqual(3, pullblock(&head, 3));
    try testing.expectEqualStrings("45", contents(head.?));
    try testing.expectEqual(0, pullblock(null, 3));

    // Pack reallocates a block that uses a quarter of its room or less.
    const loose = allocb(4096);
    fill(loose, "tiny");
    const packed_ = packblock(loose).?;
    try testing.expect(packed_ != loose);
    try testing.expectEqualStrings("tiny", contents(packed_));

    freeblist(head);
    freeb(packed_);
    freeb(big);
    freeb(cat);
    freeb(p3);
    freeb(null);
    const ib = iallocb(10).?;
    try testing.expectEqual(c.BINTR, ib.flag);
    freeb(ib);
}

fn readAll(q: *Queue, buf: []u8) !usize {
    return @intCast(try qread(q, buf.ptr, @intCast(buf.len)));
}

test "a queue reads what was written, splits blocks, and keeps a message queue's writes whole [kernel-port]" {
    _ = try kt.begin();
    const q = qopen(64 * 1024, 0, null, null).?;
    defer qfree(q);
    try testing.expectEqual(5, try qwrite(q, "hello", 5));
    try testing.expectEqual(6, try qwrite(q, " world", 6));
    try testing.expectEqual(11, qlen(q));
    try testing.expect(qcanread(q));
    var buf: [64]u8 = undefined;
    // A stream queue splits a block that's longer than the read.
    try testing.expectEqual(3, try readAll(q, buf[0..3]));
    try testing.expectEqualStrings("hel", buf[0..3]);
    try testing.expectEqual(2, try readAll(q, &buf));
    try testing.expectEqualStrings("lo", buf[0..2]);
    const b = (try qbread(q, 4)).?;
    try testing.expectEqualStrings(" wor", contents(b));
    freeb(b);
    try testing.expectEqual(2, try readAll(q, &buf));
    try testing.expect(!qcanread(q));

    // A message queue drops what's past the read.
    const m = qopen(64 * 1024, Qmsg, null, null).?;
    defer qfree(m);
    _ = try qwrite(m, "first", 5);
    _ = try qwrite(m, "second", 6);
    try testing.expectEqual(3, try readAll(m, buf[0..3]));
    try testing.expectEqualStrings("fir", buf[0..3]);
    try testing.expectEqual(6, try readAll(m, &buf));
    try testing.expectEqualStrings("second", buf[0..6]);

    // A coalescing queue reads across blocks, and drops empty ones.
    const k = qopen(64 * 1024, Qcoalesce, null, null).?;
    defer qfree(k);
    _ = qpass(k, allocb(0));
    _ = qpass(k, blockOf("ab"));
    _ = qpass(k, blockOf("cd"));
    try testing.expectEqual(3, try readAll(k, buf[0..3]));
    try testing.expectEqualStrings("abc", buf[0..3]);
    try testing.expectEqual(1, try readAll(k, &buf));
    try testing.expectEqualStrings("d", buf[0..1]);
}

test "qconsume, qproduce, qiwrite, qdiscard, qcopy, and qflush don't wait [kernel-port]" {
    _ = try kt.begin();
    const q = qopen(64 * 1024, 0, null, null).?;
    defer qfree(q);
    var buf: [16]u8 = undefined;
    try testing.expectEqual(-1, qconsume(q, &buf, 4));
    try testing.expectEqual(null, qget(q));
    try testing.expectEqual(6, qproduce(q, "abcdef", 6));
    try testing.expectEqual(3, qiwrite(q, "ghi", 3));
    const cp = qcopy(q, 4, 4);
    try testing.expectEqualStrings("efgh", contents(cp));
    freeb(cp);
    try testing.expectEqual(2, qconsume(q, &buf, 2));
    try testing.expectEqualStrings("ab", buf[0..2]);
    try testing.expectEqual(5, qdiscard(q, 5));
    try testing.expectEqual(2, qlen(q));
    const g = qget(q).?;
    try testing.expectEqualStrings("hi", contents(g));
    qputback(q, g);
    try testing.expectEqual(2, qlen(q));
    qflush(q);
    try testing.expectEqual(0, qlen(q));
    try testing.expect(!qcanread(q));
}

test "a closed queue reads 0 three times, then its error; a hangup's message is the read's error [kernel-port]" {
    _ = try kt.begin();
    const q = qopen(1024, 0, null, null).?;
    defer qfree(q);
    _ = try qwrite(q, "lost", 4);
    qclose(q);
    try testing.expect(qisclosed(q) != 0);
    try testing.expectEqual(0, qlen(q));
    var buf: [8]u8 = undefined;
    for (0..3) |_| try testing.expectEqual(0, try readAll(q, &buf));
    try testing.expectError(error.Kernel, readAll(q, &buf));
    try testing.expectEqualStrings("i/o on hungup channel", kt.errstr());
    try testing.expectError(error.Kernel, qwrite(q, "x", 1));
    try testing.expectEqualStrings("i/o on hungup channel", kt.errstr());
    try testing.expectEqual(0, qpass(q, blockOf("x")));

    // Reopened, it works again; hung up with a message, what's queued
    // still reads, and then the message is the error.
    qreopen(q);
    _ = try qwrite(q, "kept", 4);
    qhangup(q, "gone away");
    try testing.expectEqual(4, try readAll(q, &buf));
    try testing.expectError(error.Kernel, readAll(q, &buf));
    try testing.expectEqualStrings("gone away", kt.errstr());
    try testing.expectError(error.Kernel, qbread(q, 1));
}

const Reader = struct {
    q: *Queue,
    n: c_int = 0,
    result: ?Error = null,
    errstr: [port.ERRMAX]u8 = undefined,
    buf: [32]u8 = undefined,

    fn run(r: *Reader) void {
        r.n = qread(r.q, &r.buf, r.buf.len) catch |e| {
            r.result = e;
            @memcpy(&r.errstr, up().errstr[0..port.ERRMAX]);
            return;
        };
    }
};

test "a read waits for a writer, and a note interrupts it [kernel-port]" {
    _ = try kt.begin();
    const q = qopen(1024, 0, null, null).?;
    defer qfree(q);
    var r: Reader = .{ .q = q };
    var k: kt.Kproc = undefined;
    try k.start(Reader.run, .{&r});
    try kt.waitAsleep(k.proc());
    try testing.expect(q.rr.p == k.proc());
    _ = try qwrite(q, "wake", 4);
    k.join();
    try testing.expectEqual(null, r.result);
    try testing.expectEqualStrings("wake", r.buf[0..@intCast(r.n)]);

    var r2: Reader = .{ .q = q };
    try k.start(Reader.run, .{&r2});
    try kt.waitAsleep(k.proc());
    sync.procinterrupt(k.proc());
    k.join();
    try testing.expectEqual(error.Interrupted, r2.result.?);
    try testing.expectEqualStrings("interrupted", std.mem.sliceTo(&r2.errstr, 0));
    // The reader lock was let go.
    try testing.expect(sync.canqlock(&q.rlock));
    sync.qunlock(&q.rlock);
}

test "a reader queued behind another reader is interrupted by a note too [kernel-port]" {
    _ = try kt.begin();
    const q = qopen(1024, 0, null, null).?;
    defer qfree(q);
    var first: Reader = .{ .q = q };
    var a: kt.Kproc = undefined;
    try a.start(Reader.run, .{&first});
    try kt.waitAsleep(a.proc());
    try testing.expect(q.rr.p == a.proc());
    // The second waits for the reader lock, in tsleep (qlockintr).
    var second: Reader = .{ .q = q };
    var b: kt.Kproc = undefined;
    try b.start(Reader.run, .{&second});
    try kt.waitAsleep(b.proc());
    sync.procinterrupt(b.proc());
    b.join();
    try testing.expectEqual(error.Interrupted, second.result.?);
    // The first still has the queue, and reads.
    _ = try qwrite(q, "first", 5);
    a.join();
    try testing.expectEqual(null, first.result);
    try testing.expectEqualStrings("first", first.buf[0..@intCast(first.n)]);
}

const Writer = struct {
    q: *Queue,
    done: std.atomic.Value(bool) = .init(false),
    result: ?Error = null,

    fn run(w: *Writer) void {
        var data: [256]u8 = @splat('w');
        _ = qwrite(w.q, &data, data.len) catch |e| {
            w.result = e;
        };
        w.done.store(true, .release);
    }
};

test "a writer past the limit waits for a reader to drain the queue, and a note interrupts it [kernel-port]" {
    _ = try kt.begin();
    const q = qopen(64, 0, null, null).?;
    defer qfree(q);
    var w: Writer = .{ .q = q };
    var k: kt.Kproc = undefined;
    try k.start(Writer.run, .{&w});
    try kt.waitAsleep(k.proc());
    try testing.expect(qfull(q) != 0);
    try testing.expect(!w.done.load(.acquire));
    // The data was queued before the writer waited.
    try testing.expectEqual(256, qlen(q));
    var buf: [256]u8 = undefined;
    try testing.expectEqual(256, try readAll(q, &buf));
    k.join();
    try testing.expect(w.done.load(.acquire));
    try testing.expectEqual(null, w.result);
    try testing.expectEqual(0, qfull(q));

    var w2: Writer = .{ .q = q };
    try k.start(Writer.run, .{&w2});
    try kt.waitAsleep(k.proc());
    sync.procinterrupt(k.proc());
    k.join();
    try testing.expectEqual(error.Interrupted, w2.result.?);
    try testing.expectEqual(256, qlen(q));

    // Non-blocking, a full queue drops writes and says they went.
    qnoblock(q, 1);
    try testing.expectEqual(4, try qwrite(q, "drop", 4));
    try testing.expectEqual(256, qlen(q));
    qsetlimit(q, 1024);
    try testing.expectEqual(0, qfull(q));
}
