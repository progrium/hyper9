//! Host streams (design/0021-websocket-9p.md): WebSocket connections h9
//! makes on the host and hands to the kernel through devhstream
//! (src/kern/devhstream.c), which devmnt can mount. A stream is made by h9
//! for a `ws://` root or a namespace-file mount (host-made), or by the
//! guest through `/net/ws/clone` (a conversation).
//!
//! This is devhcons's pattern (src/consin.zig) applied to a connection:
//! each stream has a thread that connects, does TLS for `wss`, runs
//! src/ws.zig's handshake and then reads frames, queuing payload bytes;
//! a guest read never blocks in a host call, but sleeps in the kernel
//! until `h9_hstream_wake`, so notes and teardown interrupt it. Writes
//! frame and send on the caller's thread, under a lock per stream.
//!
//! Every stream belongs to a machine (the kernel's Hmach, as an opaque
//! key). When the machine ends its streams are closed with 1001 and their
//! queues freed (`h9_hstream_machend`). Queued bytes are kept in pages from
//! the machine's page allocator (kern.Pages), so they count against
//! `--memory`; data and text together are capped at `ws.max_message`.
//!
//! On the web host (design/0021-websocket-9p.md, "On the browser host")
//! the JS host's WebSocket connects, does TLS and frames, through the
//! `h9_ws_*` imports below; each stream's reader is a coroutine parked
//! in `ws_recv`. ws.zig, TLS, proxies and the keepalive aren't used there.
//!
//! Accepted streams (design/0035-serve.md) are the other direction: a
//! connection a `--serve` listener accepted, handed to the kernel the same
//! way. A WebSocket one (`server`) does the server's side of the
//! handshake and reads masked frames; a unix or TCP one (`raw`) carries
//! the bytes as they come. Either way the stream's thread waits for the
//! client's first 9P message, checks it in the dialect slot, and only then
//! tells the listener's `Served` that the stream is ready for exportfs.
//!
//! The leaves called from devhstream.c never raise kernel errors: they
//! return -1 with the error in the caller's ERRMAX buffer, and the C side
//! raises it.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("ws.zig");
const kern = @import("kern.zig");
const policy = @import("policy.zig");

const Io = std.Io;
const net = std.Io.net;
const tls = std.crypto.tls;

const web = @import("web.zig");

const gpa = web.gpa;

/// Streams in the host process, across machines.
pub const max_streams = 256;
/// Conversations one machine may have open, like devip's 30 TCP ones.
pub const max_convs = 32;
/// What `read` returns when the caller has to sleep until `ready`.
pub const would_block = -2;

/// The idle time before a ping, and again before the connection fails
/// (ws.Keepalive). Tests shorten it.
pub var keepalive_idle_ns: u64 = 30 * std.time.ns_per_s;

var io_global: ?Io = null;

/// The Io streams connect and read with. Set by the machine before its
/// first stream; the process's Io must outlive every stream thread.
pub fn setIo(io: Io) void {
    io_global = io;
}

fn theIo() Io {
    return io_global orelse Io.Threaded.global_single_threaded.io();
}

pub const Kind = enum(c_int) { data = 0, text = 1 };

/// The JS host's WebSockets (src/web/h9-web.js), on the web host only.
/// `ws_opened` and `ws_recv` are Suspending, so they're called through
/// `web.coro.blocking`.
const js = struct {
    /// Starts a WebSocket to `url` offering the comma-separated
    /// `protocols`; its id, or -1 if the URL is refused.
    extern "h9" fn ws_open(url: [*]const u8, url_n: u32, protocols: [*]const u8, protocols_n: u32) i32;
    /// Waits for the open: the selected subprotocol's length (in `sel`),
    /// or -1 if it failed or closed first.
    extern "h9" fn ws_opened(id: i32, sel: [*]u8, n: u32) i32;
    /// Waits for received bytes: up to `n` of the current message, with
    /// `info` bit 0 set for text and bit 1 on its last piece; -1 once the
    /// socket has closed and nothing is left.
    extern "h9" fn ws_recv(id: i32, buf: [*]u8, n: u32, info: *u32) i32;
    /// Sends a binary (kind 0) or text (1) message; -1 if not open.
    extern "h9" fn ws_send(id: i32, kind: u32, buf: [*]const u8, n: u32) i32;
    extern "h9" fn ws_close(id: i32, code: u32, reason: [*]const u8, n: u32) void;
    /// A closed socket's code (1006 for a failure) and its reason or
    /// error in `buf` (length in `len`).
    extern "h9" fn ws_status(id: i32, buf: [*]u8, n: u32, len: *u32) u32;
    extern "h9" fn ws_free(id: i32) void;
};

pub const State = enum(u8) { idle, connecting, established, closed };

// The table. A stream's id is its slot plus a generation, so a stale id
// never finds a newer stream.

var table_lock: std.atomic.Mutex = .unlocked;
var table: [max_streams]?*Stream = @splat(null);
var gens: [max_streams]u32 = @splat(0);

fn lockTable() void {
    while (!table_lock.tryLock()) std.atomic.spinLoopHint();
}

fn slotOf(id: u32) usize {
    return id % max_streams;
}

/// The stream with `id`, with a reference the caller drops with `unref`.
fn get(id: c_ulong) ?*Stream {
    const i: u32 = @truncate(id);
    lockTable();
    defer table_lock.unlock();
    const s = table[slotOf(i)] orelse return null;
    if (s.id != i) return null;
    s.refs += 1;
    return s;
}

fn unref(s: *Stream) void {
    lockTable();
    s.refs -= 1;
    const last = s.refs == 0;
    if (last) table[slotOf(s.id)] = null;
    table_lock.unlock();
    if (last) s.destroy();
}

/// A received byte stream: a FIFO of pages from the machine.
const Queue = struct {
    head: ?*Chunk = null,
    tail: ?*Chunk = null,
    len: usize = 0,

    const page = kern.Pages.page_size;

    const Chunk = struct {
        next: ?*Chunk = null,
        mem: [*]u8,
        start: usize = 0,
        end: usize = 0,
    };

    fn allocPage(pages: ?*const kern.Pages) ?[*]u8 {
        if (pages) |p| return p.alloc(p.ctx, page);
        const m = std.heap.page_allocator.alloc(u8, page) catch return null;
        return m.ptr;
    }

    fn freePage(pages: ?*const kern.Pages, m: [*]u8) void {
        if (pages) |p| return p.free(p.ctx, m, page);
        const sl: []u8 = m[0..page];
        std.heap.page_allocator.free(sl);
    }

    fn push(q: *Queue, pages: ?*const kern.Pages, bytes: []const u8) error{OutOfMemory}!void {
        var rest = bytes;
        while (rest.len > 0) {
            const t = if (q.tail) |t| if (t.end < page) t else null else null;
            const c = t orelse blk: {
                const mem = allocPage(pages) orelse return error.OutOfMemory;
                const c = gpa.create(Chunk) catch {
                    freePage(pages, mem);
                    return error.OutOfMemory;
                };
                c.* = .{ .mem = mem };
                if (q.tail) |old| old.next = c else q.head = c;
                q.tail = c;
                break :blk c;
            };
            const n = @min(rest.len, page - c.end);
            @memcpy(c.mem[c.end..][0..n], rest[0..n]);
            c.end += n;
            q.len += n;
            rest = rest[n..];
        }
    }

    /// Removes up to `dest.len` bytes into `dest`, or skips them when
    /// `dest` is null.
    fn take(q: *Queue, pages: ?*const kern.Pages, dest: ?[]u8, want: usize) usize {
        var got: usize = 0;
        while (got < want) {
            const c = q.head orelse break;
            const n = @min(want - got, c.end - c.start);
            if (dest) |d| @memcpy(d[got..][0..n], c.mem[c.start..][0..n]);
            c.start += n;
            got += n;
            q.len -= n;
            if (c.start == c.end) {
                q.head = c.next;
                if (q.head == null) q.tail = null;
                freePage(pages, c.mem);
                gpa.destroy(c);
            }
        }
        return got;
    }

    /// The byte `off` bytes in; the caller checks `len`.
    fn peekByte(q: *const Queue, off: usize) u8 {
        var skip = off;
        var c = q.head;
        while (c) |ch| : (c = ch.next) {
            const n = ch.end - ch.start;
            if (skip < n) return ch.mem[ch.start + skip];
            skip -= n;
        }
        unreachable;
    }

    /// The first four bytes, as a text message's length.
    fn peekLen(q: *const Queue) u32 {
        var b: [4]u8 = undefined;
        var got: usize = 0;
        var c = q.head;
        while (got < 4) {
            const ch = c.?;
            const n = @min(4 - got, ch.end - ch.start);
            @memcpy(b[got..][0..n], ch.mem[ch.start..][0..n]);
            got += n;
            c = ch.next;
        }
        return std.mem.readInt(u32, &b, .little);
    }

    fn clear(q: *Queue, pages: ?*const kern.Pages) void {
        _ = q.take(pages, null, q.len);
    }
};

/// The connection under a stream: TCP, through a proxy's tunnel or not,
/// and TLS for `wss`.
const Conn = struct {
    stream: net.Stream,
    sr: net.Stream.Reader,
    sw: net.Stream.Writer,
    tls: ?tls.Client = null,
    sock_in: [tls.Client.min_buffer_len]u8 = undefined,
    sock_out: [tls.Client.min_buffer_len]u8 = undefined,
    tls_in: [tls.Client.min_buffer_len + 8192]u8 = undefined,
    tls_out: [8192]u8 = undefined,

    fn create(stream: net.Stream) error{OutOfMemory}!*Conn {
        const c = try gpa.create(Conn);
        c.* = .{ .stream = stream, .sr = undefined, .sw = undefined };
        c.sr = stream.reader(theIo(), &c.sock_in);
        c.sw = stream.writer(theIo(), &c.sock_out);
        return c;
    }

    fn reader(c: *Conn) *Io.Reader {
        return if (c.tls) |*t| &t.reader else &c.sr.interface;
    }

    fn writer(c: *Conn) *Io.Writer {
        return if (c.tls) |*t| &t.writer else &c.sw.interface;
    }

    fn flush(c: *Conn) Io.Writer.Error!void {
        if (c.tls) |*t| try t.writer.flush();
        try c.sw.interface.flush();
    }

    /// Unblocks a read or connect on another thread.
    fn shutdown(c: *Conn) void {
        c.stream.shutdown(theIo(), .both) catch {};
    }

    fn destroy(c: *Conn) void {
        c.stream.close(theIo());
        gpa.destroy(c);
    }
};

/// Options for a stream h9 makes for a root or a namespace-file mount.
pub const HostOptions = struct {
    /// `Name: value` handshake headers, already checked.
    headers: []const []const u8 = &.{},
    /// A PEM file a `wss` server's certificate must chain to, instead of
    /// the host's bundle.
    ca_file: ?[]const u8 = null,
    proxy: ws.ProxyConfig = .{},
};

/// What's under a stream.
pub const Mode = enum {
    /// A WebSocket h9 connected as the client.
    client,
    /// A WebSocket a `--serve ws://` listener accepted: h9 is the server.
    server,
    /// A unix or TCP connection a listener accepted: bytes, unframed.
    raw,
};

/// An accepted stream's listener (design/0035-serve.md): its WebSocket
/// checks, and what to tell it. Must outlive the stream's thread.
pub const Served = struct {
    /// A WebSocket listener's checks; null for unix and TCP.
    ws: ?ws.ServerPolicy = null,
    ctx: *anyopaque,
    /// The stream's first 9P message has arrived and passed the dialect
    /// slot. The callee takes the maker's reference, which it drops with
    /// `release` once it has a channel on the stream.
    ready: *const fn (ctx: *anyopaque, id: u32) void,
    /// The stream's thread is ending. `handed` says whether `ready` was
    /// called; if not, the maker's reference is dropped here.
    done: *const fn (ctx: *anyopaque, handed: bool) void,
};

/// The dialect slot (design/0035-serve.md, "Each connection"): what
/// serves a connection whose first message has type `typ`. Every
/// connection goes to an exportfs through a `#ℓ` conversation's server
/// side (design/0022-dotl.md), which translates a 9P2000.L client and
/// passes any other version to exportfs to answer.
pub const Dialect = enum { exportfs };

pub fn dialect(typ: u8) ?Dialect {
    const tversion = 100;
    return if (typ == tversion) .exportfs else null;
}

pub const Stream = struct {
    id: u32,
    owner: usize,
    mode: Mode = .client,
    /// An accepted stream's listener.
    served: ?*const Served = null,
    /// An accepted stream's first message passed the dialect slot, and
    /// `served.ready` has it.
    announced: bool = false,
    /// The guest's conversation number, or null for a host-made stream.
    conv: ?u8,
    /// Under the table lock: references (leaf calls in progress, the
    /// thread, the maker) and C opens. A conversation is listed while it
    /// has opens.
    refs: u32 = 1,
    opens: u32 = 0,
    listed: bool = true,
    pages: ?*const kern.Pages,

    lock: std.atomic.Mutex = .unlocked,
    /// Under `lock`, but read without it by `ready`.
    state: std.atomic.Value(State) = .init(.idle),
    /// The stream has ended (a close, an error, or a hangup); reads return
    /// what's queued, then 0 or the error.
    ended: bool = false,
    /// It ended with an error (`err`), not a clean close.
    failed: bool = false,
    /// The machine ended: nothing may be queued again.
    dead: bool = false,
    cancel: bool = false,
    /// The handshake completed, whatever happened since.
    opened: bool = false,
    err_buf: [96]u8 = undefined,
    err_len: usize = 0,
    close_code: u16 = 0,
    close_reason: [123]u8 = undefined,
    close_reason_len: usize = 0,
    selected: [32]u8 = undefined,
    selected_len: ?usize = null,
    data: Queue = .{},
    text: Queue = .{},

    url: []u8 = &.{},
    headers: std.ArrayList([]u8) = .empty,
    protocols: std.ArrayList([]u8) = .empty,
    /// A host-made stream's `--root-ca` file and proxy URL, if any.
    ca_file: ?[]u8 = null,
    proxy: ?[]u8 = null,
    /// Allowed addresses, for a guest connect, checked before the thread
    /// starts.
    addrs: []net.IpAddress = &.{},

    /// Held while sending; the reader thread and the keepalive send pongs,
    /// pings and closes under it too.
    wlock: Io.Mutex = .init,
    /// Set under `wlock` (and `lock`) once connected; cleared under both
    /// when the thread ends.
    conn: ?*Conn = null,
    /// The JS host's socket, on the web host, under the same rules as
    /// `conn`.
    sock: i32 = -1,
    close_sent: bool = false,
    keepalive: ws.Keepalive = .{ .last_rx = 0 },
    thread: ?web.Thread = null,

    /// Unblocks the reader: shuts the connection, or closes the socket.
    fn shutdownConn(s: *Stream) void {
        if (s.conn) |c| c.shutdown();
        if (web.enabled and s.sock >= 0) js.ws_close(s.sock, ws.Close.normal, "", 0);
    }

    fn lockS(s: *Stream) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn destroy(s: *Stream) void {
        s.data.clear(if (s.dead) null else s.pages);
        s.text.clear(if (s.dead) null else s.pages);
        gpa.free(s.url);
        for (s.headers.items) |h| gpa.free(h);
        s.headers.deinit(gpa);
        for (s.protocols.items) |p| gpa.free(p);
        s.protocols.deinit(gpa);
        gpa.free(s.addrs);
        if (s.ca_file) |f| gpa.free(f);
        if (s.proxy) |p| gpa.free(p);
        gpa.destroy(s);
    }

    fn setErr(s: *Stream, comptime fmt: []const u8, args: anytype) void {
        const m = std.fmt.bufPrint(&s.err_buf, fmt, args) catch blk: {
            const n = @min(s.err_buf.len, fmt.len);
            @memcpy(s.err_buf[0..n], fmt[0..n]);
            break :blk s.err_buf[0..n];
        };
        s.err_len = m.len;
    }

    fn errText(s: *const Stream) []const u8 {
        return s.err_buf[0..s.err_len];
    }

    /// Ends the stream with an error, unless it has ended already. Called
    /// with `lock` held.
    fn failLocked(s: *Stream, comptime fmt: []const u8, args: anytype) void {
        if (!s.ended) {
            s.setErr(fmt, args);
            s.failed = true;
            s.ended = true;
        }
        s.state.store(.closed, .release);
        s.shutdownConn();
    }

    fn fail(s: *Stream, comptime fmt: []const u8, args: anytype) void {
        s.lockS();
        s.failLocked(fmt, args);
        s.lock.unlock();
        wake(s.id);
    }

    /// Sends one frame under `wlock`. A send that fails ends the stream.
    fn send(s: *Stream, op: ws.Opcode, payload: []const u8) bool {
        const io = theIo();
        s.wlock.lockUncancelable(io);
        defer s.wlock.unlock(io);
        if (web.enabled) return s.webSend(op, payload);
        const c = s.conn orelse return false;
        if (s.mode == .raw) {
            // No frames: only data goes out, as it is.
            if (op != .binary) return true;
            c.writer().writeAll(payload) catch {
                s.fail("i/o on hungup channel", .{});
                return false;
            };
            c.flush() catch {
                s.fail("i/o on hungup channel", .{});
                return false;
            };
            return true;
        }
        if (s.close_sent) return false;
        if (op == .close) s.close_sent = true;
        // A client masks its frames; a server doesn't.
        var mask: ?[4]u8 = null;
        if (s.mode == .client) {
            var m: [4]u8 = undefined;
            io.random(&m);
            mask = m;
        }
        ws.writeFrame(c.writer(), op, payload, mask) catch {
            s.fail("i/o on hungup channel", .{});
            return false;
        };
        c.flush() catch {
            s.fail("i/o on hungup channel", .{});
            return false;
        };
        return true;
    }

    /// `send` on the web host: the JS host frames, and answers pings
    /// itself. Called under `wlock`.
    fn webSend(s: *Stream, op: ws.Opcode, payload: []const u8) bool {
        if (s.sock < 0 or s.close_sent) return false;
        switch (op) {
            .binary, .text => if (js.ws_send(s.sock, @intFromBool(op == .text), payload.ptr, @intCast(payload.len)) < 0) {
                s.fail("i/o on hungup channel", .{});
                return false;
            },
            .close => {
                s.close_sent = true;
                const code: u32 = if (payload.len >= 2) std.mem.readInt(u16, payload[0..2], .big) else ws.Close.normal;
                const reason = if (payload.len > 2) payload[2..] else "";
                js.ws_close(s.sock, code, reason.ptr, @intCast(reason.len));
            },
            else => {},
        }
        return true;
    }

    /// Sends a close (if connected and none was sent), ends the stream
    /// and unblocks its thread.
    fn hangup(s: *Stream, code: u16, reason: []const u8) void {
        s.lockS();
        const was = s.state.load(.acquire);
        s.cancel = true;
        s.lock.unlock();
        if (was == .established) {
            var buf: [125]u8 = undefined;
            _ = s.send(.close, ws.closePayload(&buf, code, reason));
        }
        s.lockS();
        if (!s.ended) {
            s.ended = true;
            s.close_code = code;
            const n = @min(reason.len, s.close_reason.len);
            @memcpy(s.close_reason[0..n], reason[0..n]);
            s.close_reason_len = n;
        }
        s.state.store(.closed, .release);
        s.shutdownConn();
        s.lock.unlock();
        wake(s.id);
    }

    /// For an accepted stream, checks the first 9P message in the dialect
    /// slot once its type has arrived. Returns whether the listener is to
    /// be told it's ready, or fails the stream if the slot refuses it.
    /// Called with `lock` held.
    fn firstLocked(s: *Stream) bool {
        if (s.served == null or s.announced or s.ended or s.data.len < 5) return false;
        if (dialect(s.data.peekByte(4)) == null) {
            s.failLocked("the first message isn't a Tversion", .{});
            return false;
        }
        s.announced = true;
        return true;
    }

    /// Tells the listener the stream is ready, after `firstLocked`.
    fn announce(s: *Stream) void {
        const sv = s.served.?;
        sv.ready(sv.ctx, s.id);
    }

    /// Queues received bytes, failing the stream past the limit or when
    /// the machine's memory is used up. Called with `lock` held.
    fn queueLocked(s: *Stream, q: *Queue, bytes: []const u8) bool {
        if (s.dead or s.ended) return false;
        if (s.data.len + s.text.len + bytes.len > ws.max_message) {
            s.failLocked("more than 16 MiB unread", .{});
            return false;
        }
        q.push(s.pages, bytes) catch {
            s.failLocked("out of memory for received data", .{});
            return false;
        };
        return true;
    }
};

/// Makes a stream in the table with one reference, for the caller.
fn newStream(owner: usize, conv: ?u8) ?*Stream {
    return newStreamPages(owner, conv, kern.currentPages());
}

/// `newStream`, with the machine's pages given, for a thread that isn't
/// one of its processes.
fn newStreamPages(owner: usize, conv: ?u8, pages: ?*const kern.Pages) ?*Stream {
    const s = gpa.create(Stream) catch return null;
    s.* = .{ .id = 0, .owner = owner, .conv = conv, .pages = pages };
    lockTable();
    defer table_lock.unlock();
    for (&table, 0..) |*slot, i| {
        if (slot.* != null) continue;
        gens[i] +%= 1;
        // Kept below 2^31, since C sees an id as a long, which is 32 bits on Windows.
        s.id = (gens[i] *% max_streams + @as(u32, @intCast(i))) & 0x7fff_ffff;
        slot.* = s;
        return s;
    }
    gpa.destroy(s);
    return null;
}

// The C side (src/kern/devhstream.c).

fn wake(id: u32) void {
    kern.hstreamWake(id);
}

// Host-made streams.

pub const OpenError = error{ BadUrl, TooManyStreams, OutOfMemory, SystemResources };

/// Starts connecting a host-made stream to `url` for the machine `owner`,
/// and returns its id, with a reference the caller drops with `release`.
/// The caller waits for the connect in the kernel (kern.hstreamWait),
/// then checks `result`.
pub fn openHost(owner: usize, url: []const u8, o: HostOptions) OpenError!u32 {
    const u = ws.Url.parse(url) catch return error.BadUrl;
    const s = newStream(owner, null) orelse return error.TooManyStreams;
    errdefer unref(s);
    s.url = try gpa.dupe(u8, url);
    try s.protocols.append(gpa, try gpa.dupe(u8, ws.subprotocol));
    for (o.headers) |h| {
        const d = try gpa.dupe(u8, h);
        s.headers.append(gpa, d) catch |e| {
            gpa.free(d);
            return e;
        };
    }
    if (o.ca_file) |f| s.ca_file = try gpa.dupe(u8, f);
    if (o.proxy.pick(u)) |p| s.proxy = try gpa.dupe(u8, p);
    try start(s);
    return s.id;
}

/// Why a stream failed to connect, or null if its handshake completed
/// (it may have ended since). The message is in `buf`.
pub fn result(id: u32, buf: []u8) ?[]const u8 {
    const s = get(id) orelse return "stream gone";
    defer unref(s);
    s.lockS();
    defer s.lock.unlock();
    if (s.opened) return null;
    const e = if (s.failed) s.errText() else "connection closed";
    const n = @min(e.len, buf.len);
    @memcpy(buf[0..n], e[0..n]);
    return buf[0..n];
}

/// Drops the maker's reference, hanging up first if no channel holds the
/// stream.
pub fn release(id: u32) void {
    const s = get(id) orelse return;
    lockTable();
    const opens = s.opens;
    table_lock.unlock();
    if (opens == 0) s.hangup(ws.Close.going_away, "");
    unref(s); // get's
    unref(s); // the maker's
}

/// Takes a connection a listener accepted, for the machine `owner`
/// (design/0035-serve.md), and starts its thread, which does a WebSocket
/// listener's handshake, waits for the first 9P message, and calls
/// `served.ready` with the stream's id if the dialect slot takes it.
/// `peer` is what `remote` says. The stream holds the connection from
/// here, even on error.
pub fn openAccepted(owner: usize, pages: ?*const kern.Pages, stream: net.Stream, peer: []const u8, served: *const Served) OpenError!void {
    const s = newStreamPages(owner, null, pages) orelse {
        stream.close(theIo());
        return error.TooManyStreams;
    };
    s.mode = if (served.ws != null) .server else .raw;
    s.served = served;
    s.url = gpa.dupe(u8, peer) catch {
        stream.close(theIo());
        unref(s);
        return error.OutOfMemory;
    };
    s.conn = Conn.create(stream) catch {
        stream.close(theIo());
        unref(s);
        return error.OutOfMemory;
    };
    // A handshake that never comes ends at the keepalive's second period.
    s.keepalive = .{ .idle_ns = keepalive_idle_ns, .last_rx = now() };
    s.state.store(.connecting, .release);
    lockTable();
    s.refs += 1;
    table_lock.unlock();
    s.thread = web.Thread.spawn(.{}, runAccepted, .{s}) catch {
        finish(s);
        unref(s); // the thread's
        unref(s); // the maker's
        return error.SystemResources;
    };
    s.thread.?.detach();
    if (s.mode == .server) startKeepalive();
}

/// An accepted stream's thread. The maker's reference is the thread's
/// until the stream is announced, and `served.ready`'s after.
fn runAccepted(s: *Stream) void {
    const sv = s.served.?;
    defer {
        s.lockS();
        const handed = s.announced;
        s.lock.unlock();
        sv.done(sv.ctx, handed);
        if (!handed) unref(s); // the maker's
        unref(s); // the thread's
    }
    if (s.mode == .server) acceptUpgrade(s, sv.ws.?) catch {
        finish(s);
        return;
    };
    s.lockS();
    if (s.cancel or s.ended) {
        s.lock.unlock();
        finish(s);
        return;
    }
    s.opened = true;
    s.keepalive = .{ .idle_ns = keepalive_idle_ns, .last_rx = now() };
    s.state.store(.established, .release);
    s.lock.unlock();
    wake(s.id);
    if (s.mode == .raw) rawLoop(s) else readLoop(s);
    finish(s);
}

/// A WebSocket listener's side of the handshake: reads the request,
/// checks it (ws.checkUpgrade), and answers 101 or the refusal.
fn acceptUpgrade(s: *Stream, pol: ws.ServerPolicy) error{Refused}!void {
    const c = s.conn.?;
    var q: ws.Request = .{};
    ws.readRequest(c.reader(), &q) catch {
        ws.writeStatus(c.writer(), 400, ws.reasonPhrase(400)) catch {};
        c.flush() catch {};
        s.fail("bad upgrade request", .{});
        return error.Refused;
    };
    switch (ws.checkUpgrade(&q, pol)) {
        .refuse => |st| {
            ws.writeStatus(c.writer(), st, ws.reasonPhrase(st)) catch {};
            c.flush() catch {};
            s.fail("refused with {d}", .{st});
            return error.Refused;
        },
        .accept => |p| {
            ws.writeAccept(c.writer(), q.key, p) catch {
                s.fail("i/o on hungup channel", .{});
                return error.Refused;
            };
            c.flush() catch {
                s.fail("i/o on hungup channel", .{});
                return error.Refused;
            };
            s.lockS();
            defer s.lock.unlock();
            if (p) |name| {
                @memcpy(s.selected[0..name.len], name);
                s.selected_len = name.len;
            }
        },
    }
}

/// Reads an accepted unix or TCP connection's bytes until it ends.
fn rawLoop(s: *Stream) void {
    const c = s.conn orelse return;
    const r = c.reader();
    while (true) {
        if (r.bufferedLen() == 0) r.fillMore() catch |e| {
            if (e == error.EndOfStream) {
                s.lockS();
                if (!s.ended) s.ended = true;
                s.state.store(.closed, .release);
                s.lock.unlock();
                wake(s.id);
                return;
            }
            return readFailed(s, e);
        };
        const b = r.buffered();
        s.lockS();
        const ok = s.queueLocked(&s.data, b);
        const first = ok and s.firstLocked();
        s.lock.unlock();
        r.toss(b.len);
        wake(s.id);
        if (!ok) return;
        if (first) s.announce();
    }
}

/// Starts the stream's thread, which connects and then reads.
fn start(s: *Stream) OpenError!void {
    s.lockS();
    s.state.store(.connecting, .release);
    s.lock.unlock();
    lockTable();
    s.refs += 1;
    table_lock.unlock();
    s.thread = web.Thread.spawn(.{}, run, .{s}) catch {
        s.fail("can't start a thread", .{});
        unref(s);
        return error.SystemResources;
    };
    s.thread.?.detach();
}

fn errName(e: anyerror) []const u8 {
    return switch (e) {
        error.ConnectionRefused => "connection refused",
        error.ConnectionResetByPeer => "connection reset",
        error.NetworkUnreachable => "network unreachable",
        error.HostUnreachable => "host unreachable",
        error.Timeout, error.ConnectionTimedOut => "connection timed out",
        error.UnknownHostName, error.NoAddressReturned => "unknown host",
        error.EndOfStream => "connection closed during the handshake",
        error.CertificateIssuerNotFound, error.TlsCertificateNotVerified => "certificate: unknown authority",
        error.CertificateHostMismatch => "certificate: wrong host",
        error.CertificateExpired => "certificate: expired",
        error.CertificateNotYetValid => "certificate: not yet valid",
        error.TlsAlert => "TLS alert from the server",
        error.BadResponse => "not a WebSocket server",
        error.BadAccept => "bad WebSocket handshake answer",
        error.BadExtension => "server selected an extension",
        else => @errorName(e),
    };
}

/// The thread: connects, handshakes, then reads until the stream ends.
fn run(s: *Stream) void {
    defer unref(s);
    connect(s) catch |e| {
        s.lockS();
        if (!s.cancel) switch (e) {
            error.HandshakeStatus => s.failLocked("server answered {d} {s}", .{ s.close_code, s.close_reason[0..s.close_reason_len] }),
            error.ProxyStatus => s.failLocked("proxy answered {d} {s}", .{ s.close_code, s.close_reason[0..s.close_reason_len] }),
            error.BadProtocol => if (s.conv == null)
                s.failLocked("server didn't select the 9p subprotocol", .{})
            else
                s.failLocked("server selected a subprotocol that wasn't offered", .{}),
            error.BadProxy => s.failLocked("bad proxy URL", .{}),
            error.BadCa => s.failLocked("--root-ca: can't read the certificates", .{}),
            error.Bundle => s.failLocked("can't load the host's certificate bundle", .{}),
            else => s.failLocked("{s}", .{errName(e)}),
        } else s.failLocked("hangup", .{});
        // Not an error once it's shown: the handshake fields were scratch.
        s.close_code = 0;
        s.close_reason_len = 0;
        s.lock.unlock();
        wake(s.id);
        finish(s);
        return;
    };
    if (web.enabled) webReadLoop(s) else readLoop(s);
    finish(s);
}

/// Ends the stream and frees its connection.
fn finish(s: *Stream) void {
    const io = theIo();
    s.lockS();
    if (!s.ended) {
        s.ended = true;
        s.failed = true;
        s.setErr("i/o on hungup channel", .{});
    }
    s.state.store(.closed, .release);
    s.lock.unlock();
    s.wlock.lockUncancelable(io);
    s.lockS();
    const c = s.conn;
    s.conn = null;
    const sock = s.sock;
    s.sock = -1;
    s.lock.unlock();
    s.wlock.unlock(io);
    if (c) |cn| cn.destroy();
    if (web.enabled and sock >= 0) js.ws_free(sock);
    wake(s.id);
}

const ConnectError = error{
    HandshakeStatus,
    ProxyStatus,
    BadProtocol,
    BadProxy,
    BadCa,
    Bundle,
    Canceled,
} || anyerror;

/// Publishes the connection so a hangup can shut it down. Fails if the
/// stream was hung up meanwhile.
fn adopt(s: *Stream, c: *Conn) error{Canceled}!void {
    const io = theIo();
    s.wlock.lockUncancelable(io);
    defer s.wlock.unlock(io);
    s.lockS();
    defer s.lock.unlock();
    if (s.cancel) return error.Canceled;
    s.conn = c;
}

fn connect(s: *Stream) ConnectError!void {
    if (web.enabled) return webConnect(s);
    const io = theIo();
    const url = ws.Url.parse(s.url) catch unreachable;
    const proxy: ?ws.Proxy = if (s.proxy) |p| ws.Proxy.parse(p) catch return error.BadProxy else null;
    // TCP: a guest's checked addresses, or the host's resolver.
    const stream: net.Stream = if (s.addrs.len > 0) blk: {
        var last: anyerror = error.UnknownHostName;
        for (s.addrs) |*a| {
            if (refusedOnWindows(a.connect(io, .{ .mode = .stream }))) |st| break :blk st else |e| last = e;
        }
        return last;
    } else try dial(io, if (proxy) |p| p.host else url.host, if (proxy) |p| p.port else url.port);
    noDelay(stream);
    const c = Conn.create(stream) catch |e| {
        stream.close(io);
        return e;
    };
    adopt(s, c) catch |e| {
        c.destroy();
        return e;
    };
    // From here `finish` frees `c`.
    if (proxy) |p| {
        try ws.writeConnect(&c.sw.interface, p, url);
        var resp: ws.Response = .{};
        ws.readConnect(&c.sr.interface, &resp) catch |e| {
            if (e == error.Status) {
                scratchStatus(s, resp);
                return error.ProxyStatus;
            }
            return e;
        };
    }
    if (url.tls) try startTls(s, c, url);
    var raw: [16]u8 = undefined;
    io.random(&raw);
    const key = ws.makeKey(&raw);
    try ws.writeRequest(c.writer(), url, &key, protoSlices(s), headerSlices(s));
    try c.flush();
    var resp: ws.Response = .{};
    ws.readResponse(c.reader(), &key, protoSlices(s), &resp) catch |e| {
        if (e == error.Status) {
            scratchStatus(s, resp);
            return error.HandshakeStatus;
        }
        return e;
    };
    s.lockS();
    defer s.lock.unlock();
    if (s.cancel) return error.Canceled;
    if (resp.protocol) |p| {
        const n = @min(p.len, s.selected.len);
        @memcpy(s.selected[0..n], p[0..n]);
        s.selected_len = n;
    }
    s.keepalive = .{ .idle_ns = keepalive_idle_ns, .last_rx = now() };
    s.opened = true;
    s.state.store(.established, .release);
    wake(s.id);
    startKeepalive();
}

/// `connect` on the web host: the JS host's WebSocket connects, does TLS
/// and the handshake. Failing, it sets the error itself, since the
/// browser says no more than that it failed.
fn webConnect(s: *Stream) ConnectError!void {
    var protos: std.ArrayList(u8) = .empty;
    defer protos.deinit(gpa);
    for (s.protocols.items, 0..) |p, i| {
        if (i > 0) try protos.append(gpa, ',');
        try protos.appendSlice(gpa, p);
    }
    const id = js.ws_open(s.url.ptr, @intCast(s.url.len), protos.items.ptr, @intCast(protos.items.len));
    if (id < 0) {
        s.lockS();
        s.failLocked("this host refuses the url", .{});
        s.lock.unlock();
        return error.Canceled;
    }
    {
        const io = theIo();
        s.wlock.lockUncancelable(io);
        defer s.wlock.unlock(io);
        s.lockS();
        defer s.lock.unlock();
        if (s.cancel) {
            js.ws_free(id);
            return error.Canceled;
        }
        s.sock = id;
    }
    // From here `finish` frees the socket.
    var sel: [32]u8 = undefined;
    const n = web.coro.blocking(js.ws_opened, .{ id, &sel, @as(u32, sel.len) });
    s.lockS();
    defer s.lock.unlock();
    if (s.cancel) return error.Canceled;
    if (n < 0) {
        var why: [96]u8 = undefined;
        var len: u32 = 0;
        _ = js.ws_status(id, &why, why.len, &len);
        s.failLocked("{s}", .{if (len > 0) why[0..len] else "connection failed"});
        return error.Canceled;
    }
    const got = sel[0..@intCast(n)];
    if (s.conv == null and !std.mem.eql(u8, got, ws.subprotocol)) {
        s.failLocked("server didn't select the 9p subprotocol", .{});
        return error.Canceled;
    }
    if (got.len > 0) {
        @memcpy(s.selected[0..got.len], got);
        s.selected_len = got.len;
    }
    s.opened = true;
    s.state.store(.established, .release);
    wake(s.id);
}

/// `readLoop` on the web host: takes what the JS host's socket received
/// until it closes.
fn webReadLoop(s: *Stream) void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        var info: u32 = 0;
        const n = web.coro.blocking(js.ws_recv, .{ s.sock, &buf, @as(u32, buf.len), &info });
        if (n < 0) {
            var reason: [123]u8 = undefined;
            var len: u32 = 0;
            const code = js.ws_status(s.sock, &reason, reason.len, &len);
            s.lockS();
            if (!s.ended) {
                if (code == 1006 or code == 0) {
                    s.failLocked("i/o on hungup channel", .{});
                } else {
                    s.ended = true;
                    s.close_code = @intCast(code);
                    @memcpy(s.close_reason[0..len], reason[0..len]);
                    s.close_reason_len = len;
                }
            }
            s.state.store(.closed, .release);
            s.lock.unlock();
            wake(s.id);
            return;
        }
        const chunk = buf[0..@intCast(n)];
        if (info & 1 == 0) {
            s.lockS();
            const ok = s.queueLocked(&s.data, chunk);
            s.lock.unlock();
            wake(s.id);
            if (!ok) return;
            continue;
        }
        if (s.conv == null) return protocolError(s, ws.Close.invalid_data, "text message on a 9P stream");
        text.appendSlice(gpa, chunk) catch return s.fail("out of memory for received data", .{});
        if (text.items.len > ws.max_message) return protocolError(s, ws.Close.too_big, "message over 16 MiB");
        if (info & 2 == 0) continue;
        var lenb: [4]u8 = undefined;
        std.mem.writeInt(u32, &lenb, @intCast(text.items.len), .little);
        s.lockS();
        const ok = s.queueLocked(&s.text, &lenb) and s.queueLocked(&s.text, text.items);
        s.lock.unlock();
        text.clearRetainingCapacity();
        wake(s.id);
        if (!ok) return;
    }
}

/// Keeps an HTTP status for the error message, in the close fields.
fn scratchStatus(s: *Stream, resp: ws.Response) void {
    s.lockS();
    defer s.lock.unlock();
    s.close_code = resp.status;
    const n = @min(resp.reason.len, s.close_reason.len);
    @memcpy(s.close_reason[0..n], resp.reason[0..n]);
    s.close_reason_len = n;
}

fn protoSlices(s: *Stream) []const []const u8 {
    return @ptrCast(s.protocols.items);
}

fn headerSlices(s: *Stream) []const []const u8 {
    return @ptrCast(s.headers.items);
}

/// Turns off Nagle's algorithm on `st`. A 9P request is a small write,
/// and so is the pong h9 sends for a server's ping. With Nagle on, a
/// request written while a pong is unacknowledged waits for the server's
/// delayed ACK (40 ms on Linux, up to 200 ms on macOS) before it's sent,
/// on every round trip that follows a ping. Browsers turn it off for
/// WebSockets too.
fn noDelay(st: net.Stream) void {
    const one: c_int = 1;
    if (builtin.os.tag == .windows) {
        _ = setsockopt(st.socket.handle, 6, 1, std.mem.asBytes(&one), @sizeOf(c_int));
    } else std.posix.setsockopt(st.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&one)) catch {};
}

/// Winsock's, which std.posix doesn't wrap: IPPROTO_TCP is 6 and
/// TCP_NODELAY 1 there too.
extern "ws2_32" fn setsockopt(s: net.Socket.Handle, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(.winapi) i32;

/// Connects to `host`, a name or a literal address.
fn dial(io: Io, host: []const u8, port: u16) !net.Stream {
    return refusedOnWindows(dialHost(io, host, port));
}

/// Zig 0.16's Windows connect reports a refused connection, the usual
/// reason one fails, as an unexpected NTSTATUS; name it so the machine's
/// error says what happened.
fn refusedOnWindows(r: anytype) @TypeOf(r) {
    if (builtin.os.tag != .windows) return r;
    return r catch |e| switch (e) {
        error.Unexpected => error.ConnectionRefused,
        else => e,
    };
}

fn dialHost(io: Io, host: []const u8, port: u16) !net.Stream {
    if (net.IpAddress.parse(host, port)) |a| return a.connect(io, .{ .mode = .stream }) else |_| {}
    const hn = try net.HostName.init(host);
    return hn.connect(io, port, .{ .mode = .stream });
}

// The host's certificate bundle, loaded once per process.
var bundle_lock: Io.RwLock = .init;
var bundle: std.crypto.Certificate.Bundle = .empty;
var bundle_loaded = false;

fn startTls(s: *Stream, c: *Conn, url: ws.Url) ConnectError!void {
    const io = theIo();
    const now_ts = Io.Clock.real.now(io);
    var own: std.crypto.Certificate.Bundle = .empty;
    defer own.deinit(gpa);
    var own_lock: Io.RwLock = .init;
    const ca_file = s.ca_file;
    if (ca_file) |path| {
        own.addCertsFromFilePath(gpa, io, now_ts, Io.Dir.cwd(), path) catch return error.BadCa;
        if (own.map.count() == 0) return error.BadCa;
    } else {
        bundle_lock.lockUncancelable(io);
        defer bundle_lock.unlock(io);
        if (!bundle_loaded) {
            bundle.rescan(gpa, io, now_ts) catch return error.Bundle;
            bundle_loaded = true;
        }
    }
    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    c.tls = tls.Client.init(&c.sr.interface, &c.sw.interface, .{
        .host = .{ .explicit = url.host },
        .ca = .{ .bundle = .{
            .gpa = gpa,
            .io = io,
            .lock = if (ca_file != null) &own_lock else &bundle_lock,
            .bundle = if (ca_file != null) &own else &bundle,
        } },
        .read_buffer = &c.tls_in,
        .write_buffer = &c.tls_out,
        .entropy = &entropy,
        .realtime_now = now_ts,
    }) catch |e| return switch (e) {
        error.WriteFailed => c.sw.err orelse error.WriteFailed,
        error.ReadFailed => c.sr.err orelse error.ReadFailed,
        else => e,
    };
}

fn now() i64 {
    return @intCast(Io.Timestamp.now(theIo(), .awake).nanoseconds);
}

/// Reads frames until the stream ends.
fn readLoop(s: *Stream) void {
    const c = s.conn orelse return;
    const r = c.reader();
    var rc: ws.Receiver = .{ .side = if (s.mode == .server) .server else .client };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const f = rc.next(r) catch |e| return readFailed(s, e);
        s.lockS();
        s.keepalive.received(now());
        s.lock.unlock();
        switch (f.opcode) {
            .ping, .pong, .close => {
                const p = buf[0..@intCast(f.len)];
                ws.readPayload(r, f, 0, p) catch |e| return readFailed(s, e);
                switch (f.opcode) {
                    .ping => _ = s.send(.pong, p),
                    .pong => {},
                    .close => {
                        const cl = ws.parseClose(p) catch return protocolError(s, ws.Close.protocol_error, "bad close frame");
                        var out: [125]u8 = undefined;
                        _ = s.send(.close, ws.closePayload(&out, cl.code, ""));
                        s.lockS();
                        if (!s.ended) {
                            s.ended = true;
                            s.close_code = cl.code;
                            const n = @min(cl.reason.len, s.close_reason.len);
                            @memcpy(s.close_reason[0..n], cl.reason[0..n]);
                            s.close_reason_len = n;
                        }
                        s.state.store(.closed, .release);
                        s.lock.unlock();
                        wake(s.id);
                        return;
                    },
                    else => unreachable,
                }
            },
            .binary => {
                var off: u64 = 0;
                while (off < f.len) {
                    const n: usize = @intCast(@min(buf.len, f.len - off));
                    ws.readPayload(r, f, off, buf[0..n]) catch |e| return readFailed(s, e);
                    off += n;
                    s.lockS();
                    const ok = s.queueLocked(&s.data, buf[0..n]);
                    const first = ok and s.firstLocked();
                    s.lock.unlock();
                    if (!ok) return wake(s.id);
                    wake(s.id);
                    if (first) s.announce();
                }
            },
            .text => {
                if (s.mode == .server) return protocolError(s, ws.Close.unsupported_data, "text message on a 9P stream");
                if (s.conv == null) return protocolError(s, ws.Close.invalid_data, "text message on a 9P stream");
                if (f.first) text.clearRetainingCapacity();
                const at = text.items.len;
                text.resize(gpa, at + @as(usize, @intCast(f.len))) catch return s.fail("out of memory for received data", .{});
                ws.readPayload(r, f, 0, text.items[at..]) catch |e| return readFailed(s, e);
                if (!f.fin) continue;
                if (!ws.validUtf8(text.items)) return protocolError(s, ws.Close.invalid_data, "invalid utf-8 from the server");
                var len: [4]u8 = undefined;
                std.mem.writeInt(u32, &len, @intCast(text.items.len), .little);
                s.lockS();
                const ok = s.queueLocked(&s.text, &len) and s.queueLocked(&s.text, text.items);
                s.lock.unlock();
                wake(s.id);
                if (!ok) return;
            },
            else => unreachable,
        }
    }
}

fn readFailed(s: *Stream, e: anyerror) void {
    switch (e) {
        error.ProtocolError => protocolError(s, ws.Close.protocol_error, "WebSocket protocol error"),
        error.TooBig => protocolError(s, ws.Close.too_big, "message over 16 MiB"),
        else => {
            s.lockS();
            // A hangup or the keepalive already said why.
            if (!s.ended) s.failLocked("i/o on hungup channel", .{});
            s.lock.unlock();
            wake(s.id);
        },
    }
}

/// Fails the stream, telling the server why with a close frame.
fn protocolError(s: *Stream, code: u16, why: []const u8) void {
    var out: [125]u8 = undefined;
    _ = s.send(.close, ws.closePayload(&out, code, why));
    s.lockS();
    s.failLocked("{s}", .{why});
    s.close_code = code;
    s.lock.unlock();
    wake(s.id);
}

// The keepalive: one thread for every stream in the process.

var keepalive_started: std.atomic.Value(bool) = .init(false);

fn startKeepalive() void {
    if (keepalive_started.swap(true, .acq_rel)) return;
    const t = web.Thread.spawn(.{}, keepaliveLoop, .{}) catch {
        keepalive_started.store(false, .release);
        return;
    };
    t.detach();
}

fn keepaliveLoop() void {
    const io = theIo();
    while (true) {
        const step = @max(@min(keepalive_idle_ns / 4, std.time.ns_per_s), std.time.ns_per_ms * 10);
        io.sleep(.fromNanoseconds(@intCast(step)), .awake) catch {};
        for (0..max_streams) |i| {
            const s = blk: {
                lockTable();
                defer table_lock.unlock();
                const s = table[i] orelse continue;
                s.refs += 1;
                break :blk s;
            };
            defer unref(s);
            s.lockS();
            const st = s.state.load(.acquire);
            var act: ws.Keepalive.Action = if (st == .established and !s.ended and s.mode != .raw) s.keepalive.tick(now()) else .none;
            // A listener's client that hasn't finished its handshake
            // within two periods is dropped.
            if (s.mode == .server and st == .connecting and !s.ended and now() - s.keepalive.last_rx >= 2 * @as(i64, @intCast(s.keepalive.idle_ns))) {
                s.failLocked("the handshake timed out", .{});
                act = .fail;
            } else if (act == .fail) s.failLocked("i/o on hungup channel: {s} stopped answering pings", .{if (s.mode == .server) "the client" else "the server"});
            s.lock.unlock();
            switch (act) {
                .none => {},
                .ping => _ = s.send(.ping, "h9"),
                .fail => wake(s.id),
            }
        }
    }
}

// Leaves called from devhstream.c.

fn putErr(err: [*]u8, msg: []const u8) void {
    const n = @min(msg.len, kern.ERRMAX - 1);
    @memcpy(err[0..n], msg[0..n]);
    err[n] = 0;
}

fn h9_hstream_clone(mach: ?*anyopaque, err: [*]u8) callconv(.c) c_long {
    const owner = @intFromPtr(mach);
    var used: [max_convs]bool = @splat(false);
    var n: u8 = 0;
    {
        lockTable();
        defer table_lock.unlock();
        for (table) |slot| if (slot) |s| if (s.owner == owner and s.listed) if (s.conv) |cv| {
            used[cv] = true;
        };
        while (n < max_convs and used[n]) n += 1;
    }
    if (n == max_convs) {
        putErr(err, "no free devices");
        return -1;
    }
    const s = newStream(owner, n) orelse {
        putErr(err, "no free devices");
        return -1;
    };
    lockTable();
    s.opens = 1;
    table_lock.unlock();
    return @intCast(s.id);
}

fn h9_hstream_convno(id: c_ulong) callconv(.c) c_int {
    const s = get(id) orelse return -1;
    defer unref(s);
    return if (s.conv) |cv| cv else -1;
}

fn h9_hstream_conv(mach: ?*anyopaque, n: c_int) callconv(.c) c_long {
    const owner = @intFromPtr(mach);
    lockTable();
    defer table_lock.unlock();
    for (table) |slot| if (slot) |s| if (s.owner == owner and s.listed and s.conv != null and s.conv.? == n) return @intCast(s.id);
    return -1;
}

/// Writes the conversation numbers `mach` has, in order; returns how many.
fn h9_hstream_convs(mach: ?*anyopaque, out: [*]c_int, max: c_int) callconv(.c) c_int {
    const owner = @intFromPtr(mach);
    var have: [max_convs]bool = @splat(false);
    {
        lockTable();
        defer table_lock.unlock();
        for (table) |slot| if (slot) |s| if (s.owner == owner and s.listed) if (s.conv) |cv| {
            have[cv] = true;
        };
    }
    var k: c_int = 0;
    for (have, 0..) |h, i| if (h and k < max) {
        out[@intCast(k)] = @intCast(i);
        k += 1;
    };
    return k;
}

fn h9_hstream_incref(id: c_ulong) callconv(.c) void {
    const s = get(id) orelse return;
    lockTable();
    s.opens += 1;
    s.refs += 1;
    table_lock.unlock();
    unref(s);
}

/// The last close of a conversation's files, or of a host-made stream's
/// channel, hangs it up.
fn h9_hstream_decref(id: c_ulong) callconv(.c) void {
    const s = get(id) orelse return;
    lockTable();
    s.opens -= 1;
    const last = s.opens == 0;
    if (last) s.listed = false;
    table_lock.unlock();
    if (last) s.hangup(ws.Close.normal, "");
    unref(s); // get's
    unref(s); // the open's
}

/// A `ctl` message: `header Name: value`, `connect url [subprotocol...]`
/// or `hangup`. Returns 0, 1 when a connect has started (the caller waits
/// for it), or -1 with the error.
fn h9_hstream_ctl(id: c_ulong, buf: [*]const u8, n: c_long, err: [*]u8) callconv(.c) c_long {
    const s = get(id) orelse {
        putErr(err, "i/o on hungup channel");
        return -1;
    };
    defer unref(s);
    const msg = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
    const sp = std.mem.indexOfAny(u8, msg, " \t") orelse msg.len;
    const verb = msg[0..sp];
    const arg = std.mem.trim(u8, msg[sp..], " \t");
    if (std.mem.eql(u8, verb, "hangup")) {
        s.hangup(ws.Close.normal, "");
        return 0;
    }
    if (s.state.load(.acquire) != .idle) {
        putErr(err, "already connected");
        return -1;
    }
    if (std.mem.eql(u8, verb, "header")) {
        if (web.enabled) {
            putErr(err, "headers can't be set on the web host");
            return -1;
        }
        const h = ws.checkHeader(arg) catch |e| {
            putErr(err, if (e == error.ReservedHeader) "header changes the handshake" else "bad header");
            return -1;
        };
        const d = gpa.dupe(u8, h) catch {
            putErr(err, "no memory");
            return -1;
        };
        s.headers.append(gpa, d) catch {
            gpa.free(d);
            putErr(err, "no memory");
            return -1;
        };
        return 0;
    }
    if (std.mem.eql(u8, verb, "connect")) {
        var words = std.mem.tokenizeAny(u8, arg, " \t");
        const u = words.next() orelse {
            putErr(err, "bad url");
            return -1;
        };
        const url = ws.Url.parse(u) catch {
            putErr(err, "bad url");
            return -1;
        };
        while (words.next()) |p| {
            const d = gpa.dupe(u8, p) catch {
                putErr(err, "no memory");
                return -1;
            };
            s.protocols.append(gpa, d) catch {
                gpa.free(d);
                putErr(err, "no memory");
                return -1;
            };
        }
        s.url = gpa.dupe(u8, u) catch {
            putErr(err, "no memory");
            return -1;
        };
        s.addrs = guestAddrs(url, err) orelse return -1;
        start(s) catch {
            putErr(err, "can't start a thread");
            return -1;
        };
        return 1;
    }
    putErr(err, "bad process or channel control request");
    return -1;
}

/// The addresses a guest connect may use, checked against the calling
/// thread's network policy as devip's connect and cs check them: a name
/// must be allowed before it's resolved, and each address before it's
/// used. Null with the error in `err` when none may be.
fn guestAddrs(url: ws.Url, err: [*]u8) ?[]net.IpAddress {
    const plan = kern.currentPlan();
    if (web.enabled) return webCheck(plan, url, err);
    var list: std.ArrayList(net.IpAddress) = .empty;
    defer list.deinit(gpa);
    if (net.IpAddress.parse(url.host, url.port)) |a| {
        list.append(gpa, a) catch return noMem(err);
    } else |_| {
        if (plan) |p| if (!p.netLookup(.tcp, url.host, url.port)) {
            putErr(err, "permission denied");
            return null;
        };
        const hn = net.HostName.init(url.host) catch {
            putErr(err, "unknown host");
            return null;
        };
        var qbuf: [32]net.HostName.LookupResult = undefined;
        var q: Io.Queue(net.HostName.LookupResult) = .init(&qbuf);
        hn.lookup(theIo(), &q, .{ .port = url.port }) catch {
            putErr(err, "unknown host");
            return null;
        };
        while (q.getOneUncancelable(theIo())) |res| switch (res) {
            .address => |a| list.append(gpa, a) catch return noMem(err),
            .canonical_name => {},
        } else |_| {}
        if (plan) |p| {
            var forms: [32][16]u8 = undefined;
            const k = @min(list.items.len, forms.len);
            for (list.items[0..k], forms[0..k]) |a, *f| f.* = addr16(a);
            p.netResolved(.tcp, url.host, url.port, forms[0..k]);
        }
    }
    var allowed: std.ArrayList(net.IpAddress) = .empty;
    for (list.items) |a| {
        const f = addr16(a);
        if (plan) |p| if (!p.netCheck(.connect, .tcp, &f, url.port)) continue;
        allowed.append(gpa, a) catch {
            allowed.deinit(gpa);
            return noMem(err);
        };
    }
    if (allowed.items.len == 0) {
        allowed.deinit(gpa);
        putErr(err, if (list.items.len == 0) "unknown host" else "permission denied");
        return null;
    }
    return allowed.toOwnedSlice(gpa) catch noMem(err);
}

/// `guestAddrs` on the web host, where the JS host's WebSocket resolves
/// names and says nothing of what to: a name is checked before it's
/// used, a literal address as devip would check it, and the stream
/// connects by URL. Returns no addresses, or null with the error.
fn webCheck(plan: ?*const policy.Plan, url: ws.Url, err: [*]u8) ?[]net.IpAddress {
    const none = gpa.alloc(net.IpAddress, 0) catch return noMem(err);
    const p = plan orelse return none;
    const ok = if (net.IpAddress.parse(url.host, url.port)) |a| blk: {
        const f = addr16(a);
        break :blk p.netCheck(.connect, .tcp, &f, url.port);
    } else |_| p.netLookup(.tcp, url.host, url.port);
    if (!ok) {
        putErr(err, "permission denied");
        return null;
    }
    return none;
}

fn noMem(err: [*]u8) ?[]net.IpAddress {
    putErr(err, "no memory");
    return null;
}

/// devip's 16-byte form: IPv4 as IPv4-mapped IPv6.
fn addr16(a: net.IpAddress) [16]u8 {
    return switch (a) {
        .ip4 => |v| .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff } ++ v.bytes,
        .ip6 => |v| v.bytes,
    };
}

fn h9_hstream_connecting(id: c_ulong) callconv(.c) c_int {
    const s = get(id) orelse return 0;
    defer unref(s);
    return @intFromBool(s.state.load(.acquire) == .connecting);
}

/// After a connect: 0 if established, else -1 with why.
fn h9_hstream_result(id: c_ulong, err: [*]u8) callconv(.c) c_int {
    var buf: [kern.ERRMAX]u8 = undefined;
    const e = result(@truncate(id), &buf) orelse return 0;
    putErr(err, e);
    return -1;
}

fn h9_hstream_hangup(id: c_ulong) callconv(.c) void {
    const s = get(id) orelse return;
    defer unref(s);
    s.hangup(ws.Close.normal, "");
}

/// Reads queued bytes (`data`) or one message (`text`). Returns the
/// length, 0 at the end, `would_block`, or -1 with the error.
fn h9_hstream_read(id: c_ulong, kind: c_int, buf: [*]u8, n: c_long, err: [*]u8) callconv(.c) c_long {
    const s = get(id) orelse return 0;
    defer unref(s);
    s.lockS();
    defer s.lock.unlock();
    const st = s.state.load(.acquire);
    if (st == .idle or st == .connecting) {
        if (st == .connecting) return would_block;
        putErr(err, "not connected");
        return -1;
    }
    const dest = buf[0..@intCast(n)];
    if (kind == @intFromEnum(Kind.text)) {
        if (s.text.len > 0) {
            const len = s.text.peekLen();
            if (len > dest.len) {
                putErr(err, "message too long");
                return -1;
            }
            _ = s.text.take(s.pages, null, 4);
            return @intCast(s.text.take(s.pages, dest, len));
        }
    } else if (s.data.len > 0) {
        return @intCast(s.data.take(s.pages, dest, dest.len));
    }
    if (!s.ended) return would_block;
    if (s.failed) {
        putErr(err, s.errText());
        return -1;
    }
    return 0;
}

fn h9_hstream_ready(id: c_ulong, kind: c_int) callconv(.c) c_int {
    const s = get(id) orelse return 1;
    defer unref(s);
    s.lockS();
    defer s.lock.unlock();
    if (s.ended) return 1;
    const st = s.state.load(.acquire);
    if (st == .idle) return 1;
    if (st == .connecting) return 0;
    return @intFromBool(if (kind == @intFromEnum(Kind.text)) s.text.len > 0 else s.data.len > 0);
}

/// Sends one binary (`data`) or text message. Returns `n` or -1.
fn h9_hstream_write(id: c_ulong, kind: c_int, buf: [*]const u8, n: c_long, err: [*]u8) callconv(.c) c_long {
    const s = get(id) orelse {
        putErr(err, "i/o on hungup channel");
        return -1;
    };
    defer unref(s);
    const bytes = buf[0..@intCast(n)];
    const text = kind == @intFromEnum(Kind.text);
    if (text and !ws.validUtf8(bytes)) {
        putErr(err, "invalid utf-8");
        return -1;
    }
    if (bytes.len > ws.max_message) {
        putErr(err, "message too long");
        return -1;
    }
    s.lockS();
    const st = s.state.load(.acquire);
    const ended = s.ended;
    s.lock.unlock();
    if (st != .established or ended) {
        putErr(err, if (st == .idle) "not connected" else "i/o on hungup channel");
        return -1;
    }
    if (!s.send(if (text) .text else .binary, bytes)) {
        putErr(err, "i/o on hungup channel");
        return -1;
    }
    return n;
}

/// `remote` (what = 0) or `status` (what = 1), as text with a newline.
fn h9_hstream_info(id: c_ulong, what: c_int, buf: [*]u8, n: c_int) callconv(.c) c_int {
    const s = get(id) orelse return 0;
    defer unref(s);
    var w: Io.Writer = .fixed(buf[0..@intCast(n)]);
    s.lockS();
    defer s.lock.unlock();
    if (what == 0) {
        w.print("{s}\n", .{s.url}) catch {};
    } else switch (s.state.load(.acquire)) {
        .idle => w.writeAll("Idle\n") catch {},
        .connecting => w.writeAll("Connecting\n") catch {},
        .established => if (s.selected_len) |l|
            w.print("Established {s}\n", .{s.selected[0..l]}) catch {}
        else
            w.writeAll("Established\n") catch {},
        .closed => if (s.failed)
            w.print("Closed {d} {s}\n", .{ if (s.close_code != 0) s.close_code else 1006, s.errText() }) catch {}
        else
            w.print("Closed {d} {s}\n", .{ s.close_code, s.close_reason[0..s.close_reason_len] }) catch {},
    }
    return @intCast(w.end);
}

/// The machine ended: close its streams with 1001 and free their queues,
/// whose pages go with the machine.
fn h9_hstream_machend(mach: ?*anyopaque) callconv(.c) void {
    const owner = @intFromPtr(mach);
    for (0..max_streams) |i| {
        const s = blk: {
            lockTable();
            defer table_lock.unlock();
            const s = table[i] orelse continue;
            if (s.owner != owner) continue;
            s.refs += 1;
            s.listed = false;
            break :blk s;
        };
        s.hangup(ws.Close.going_away, "");
        s.lockS();
        s.dead = true;
        s.data.clear(s.pages);
        s.text.clear(s.pages);
        s.lock.unlock();
        unref(s);
    }
}

comptime {
    if (kern.available) {
        @export(&h9_hstream_clone, .{ .name = "h9_hstream_clone" });
        @export(&h9_hstream_convno, .{ .name = "h9_hstream_convno" });
        @export(&h9_hstream_conv, .{ .name = "h9_hstream_conv" });
        @export(&h9_hstream_convs, .{ .name = "h9_hstream_convs" });
        @export(&h9_hstream_incref, .{ .name = "h9_hstream_incref" });
        @export(&h9_hstream_decref, .{ .name = "h9_hstream_decref" });
        @export(&h9_hstream_ctl, .{ .name = "h9_hstream_ctl" });
        @export(&h9_hstream_connecting, .{ .name = "h9_hstream_connecting" });
        @export(&h9_hstream_result, .{ .name = "h9_hstream_result" });
        @export(&h9_hstream_hangup, .{ .name = "h9_hstream_hangup" });
        @export(&h9_hstream_read, .{ .name = "h9_hstream_read" });
        @export(&h9_hstream_ready, .{ .name = "h9_hstream_ready" });
        @export(&h9_hstream_write, .{ .name = "h9_hstream_write" });
        @export(&h9_hstream_info, .{ .name = "h9_hstream_info" });
        @export(&h9_hstream_machend, .{ .name = "h9_hstream_machend" });
    }
}

// Tests: the device end to end, through the kernel, against a WebSocket
// echo server on loopback.

const testing = std.testing;

/// Echoes each message back as the same type, answers pings, and closes
/// when asked. Selects `9p` when offered.
const Echo = struct {
    server: net.Server,
    port: u16,
    thread: web.Thread = undefined,
    /// Close each connection right after the handshake.
    close_after: bool = false,
    pings: std.atomic.Value(u32) = .init(0),

    fn start(e: *Echo) !void {
        const io = testing.io;
        const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
        e.server = try addr.listen(io, .{ .reuse_address = true });
        e.port = e.server.socket.address.getPort();
        e.thread = try web.Thread.spawn(.{}, serve, .{e});
        e.thread.detach();
    }

    fn serve(e: *Echo) void {
        while (true) {
            const st = e.server.accept(testing.io) catch return;
            const t = web.Thread.spawn(.{}, conn, .{ e, st }) catch {
                st.close(testing.io);
                continue;
            };
            t.detach();
        }
    }

    fn conn(e: *Echo, st: net.Stream) void {
        const io = testing.io;
        defer st.close(io);
        var ib: [8192]u8 = undefined;
        var ob: [8192]u8 = undefined;
        var sr = st.reader(io, &ib);
        var sw = st.writer(io, &ob);
        const r = &sr.interface;
        const w = &sw.interface;
        var q: ws.Request = .{};
        ws.readRequest(r, &q) catch return;
        ws.writeAccept(w, q.key, if (q.offers("9p")) "9p" else null) catch return;
        if (e.close_after) {
            var b: [125]u8 = undefined;
            ws.writeFrame(w, .close, ws.closePayload(&b, 1000, "bye"), null) catch {};
            return;
        }
        var rc: ws.Receiver = .{ .side = .server };
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(gpa);
        var op: ws.Opcode = .binary;
        while (true) {
            const f = rc.next(r) catch return;
            if (f.first and !f.opcode.isControl()) {
                msg.clearRetainingCapacity();
                op = f.opcode;
            }
            const at = msg.items.len;
            msg.resize(gpa, at + @as(usize, @intCast(f.len))) catch return;
            ws.readPayload(r, f, 0, msg.items[at..]) catch return;
            switch (f.opcode) {
                .ping => {
                    _ = e.pings.fetchAdd(1, .acq_rel);
                    ws.writeFrame(w, .pong, msg.items[at..], null) catch return;
                    msg.shrinkRetainingCapacity(at);
                },
                .close => {
                    ws.writeFrame(w, .close, msg.items[at..], null) catch {};
                    return;
                },
                .pong => msg.shrinkRetainingCapacity(at),
                else => if (f.fin) ws.writeFrame(w, op, msg.items, null) catch return,
            }
        }
    }
};

fn readAll(fd: u31, buf: []u8, want: usize) !usize {
    var got: usize = 0;
    while (got < want) {
        const n = try kern.pread(fd, buf[got..want], 0);
        if (n == 0) break;
        got += n;
    }
    return got;
}

test "the guest's /net/ws: connect, data, text, status, and the last close hangs up" {
    if (!kern.available) return error.SkipZigTest;
    setIo(testing.io);
    var echo: Echo = .{ .server = undefined, .port = 0 };
    try echo.start();

    const T = struct {
        port: u16,
        err: ?anyerror = null,
        what: []const u8 = "",
        why: [kern.ERRMAX]u8 = undefined,
        why_len: usize = 0,
        done: std.atomic.Value(bool) = .init(false),

        fn run(t: *@This()) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                t.err = e;
                const m = kern.errstr();
                @memcpy(t.why[0..m.len], m);
                t.why_len = m.len;
            };
        }

        fn body(t: *@This()) !void {
            var buf: [256]u8 = undefined;
            var path: [64]u8 = undefined;
            const ctl = try kern.open("#ℏ/ws/clone", kern.ORDWR);
            var conv_buf: [8]u8 = undefined;
            const n = try kern.pread(ctl, &conv_buf, 0);
            const conv = conv_buf[0..n];
            t.what = "connect";
            var cmd: [96]u8 = undefined;
            const c = try std.fmt.bufPrint(&cmd, "connect ws://127.0.0.1:{d}/x?k=v 9p", .{t.port});
            _ = try kern.pwrite(ctl, c, 0);
            t.what = "status";
            const sfd = try kern.open(try std.fmt.bufPrintZ(&path, "#ℏ/ws/{s}/status", .{conv}), kern.OREAD);
            const sn = try kern.pread(sfd, &buf, 0);
            try kern.close(sfd);
            try testing.expectEqualStrings("Established 9p\n", buf[0..sn]);
            const rfd = try kern.open(try std.fmt.bufPrintZ(&path, "#ℏ/ws/{s}/remote", .{conv}), kern.OREAD);
            const rn = try kern.pread(rfd, &buf, 0);
            try kern.close(rfd);
            try testing.expect(std.mem.startsWith(u8, buf[0..rn], "ws://127.0.0.1:"));

            t.what = "data";
            const data = try kern.open(try std.fmt.bufPrintZ(&path, "#ℏ/ws/{s}/data", .{conv}), kern.ORDWR);
            _ = try kern.pwrite(data, "hello, ", 0);
            _ = try kern.pwrite(data, "world", 0);
            try testing.expectEqual(@as(usize, 12), try readAll(data, &buf, 12));
            try testing.expectEqualStrings("hello, world", buf[0..12]);

            t.what = "text";
            const text = try kern.open(try std.fmt.bufPrintZ(&path, "#ℏ/ws/{s}/text", .{conv}), kern.ORDWR);
            _ = try kern.pwrite(text, "{\"ħ\":1}", 0);
            _ = try kern.pwrite(text, "", 0);
            var small: [3]u8 = undefined;
            try testing.expectError(error.Kern, kern.pread(text, &small, 0));
            try testing.expectEqualStrings("message too long", kern.errstr());
            try testing.expectEqual(@as(usize, 8), try kern.pread(text, &buf, 0));
            try testing.expectEqualStrings("{\"ħ\":1}", buf[0..8]);
            try testing.expectEqual(@as(usize, 0), try kern.pread(text, &buf, 0));
            try testing.expectError(error.Kern, kern.pwrite(text, &.{ 0xff, 0xfe }, 0));
            try testing.expectEqualStrings("invalid utf-8", kern.errstr());
            // Text doesn't show up on data, nor data on text.
            _ = try kern.pwrite(text, "t", 0);
            _ = try kern.pwrite(data, "d", 0);
            try testing.expectEqual(@as(usize, 1), try kern.pread(data, &buf, 0));
            try testing.expectEqualStrings("d", buf[0..1]);
            try testing.expectEqual(@as(usize, 1), try kern.pread(text, &buf, 0));
            try testing.expectEqualStrings("t", buf[0..1]);

            t.what = "listing";
            const dir = try kern.open("#ℏ/ws", kern.OREAD);
            const dn = try kern.pread(dir, &buf, 0);
            try kern.close(dir);
            // clone and the conversation.
            try testing.expect(dn > 0 and std.mem.indexOf(u8, buf[0..dn], "clone") != null);

            t.what = "close";
            try kern.close(text);
            try kern.close(data);
            try kern.close(ctl);
            const dir2 = try kern.open("#ℏ/ws", kern.OREAD);
            var dbuf: [512]u8 = undefined;
            const dn2 = try kern.pread(dir2, &dbuf, 0);
            try kern.close(dir2);
            // Only clone is left.
            try testing.expect(std.mem.indexOf(u8, dbuf[0..dn2], "clone") != null);
            if (kern.open(try std.fmt.bufPrintZ(&path, "#ℏ/ws/{s}/data", .{conv}), kern.ORDWR)) |_| return error.StillThere else |_| {}

            t.what = "attach spec";
            if (kern.open("#ℏ1", kern.OREAD)) |_| return error.SpecAccepted else |_| {}

            t.what = "refused";
            const ctl2 = try kern.open("#ℏ/ws/clone", kern.ORDWR);
            defer kern.close(ctl2) catch {};
            try testing.expectError(error.Kern, kern.pwrite(ctl2, "connect ws://127.0.0.1:1/ 9p", 0));
            try testing.expectEqualStrings("connection refused", kern.errstr());
            try testing.expectError(error.Kern, kern.pwrite(ctl2, "header Host: x", 0));
        }
    };
    var t: T = .{ .port = echo.port };
    try kern.spawn("test", T, T.run, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| {
        std.debug.print("at {s}: {s}\n", .{ t.what, t.why[0..t.why_len] });
        return e;
    }
}

test "a host-made stream: connect, wait, an fd, and a server close ends it" {
    if (!kern.available) return error.SkipZigTest;
    setIo(testing.io);
    var echo: Echo = .{ .server = undefined, .port = 0 };
    try echo.start();
    var bye: Echo = .{ .server = undefined, .port = 0, .close_after = true };
    try bye.start();

    const T = struct {
        port: u16,
        bye_port: u16,
        err: ?anyerror = null,
        msg: [128]u8 = undefined,
        msg_len: usize = 0,
        done: std.atomic.Value(bool) = .init(false),

        fn run(t: *@This()) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                t.err = e;
                const m = kern.errstr();
                @memcpy(t.msg[0..m.len], m);
                t.msg_len = m.len;
            };
        }

        fn body(t: *@This()) !void {
            var url: [64]u8 = undefined;
            const owner = @intFromPtr(kern.mach());
            const id = try openHost(owner, try std.fmt.bufPrint(&url, "ws://127.0.0.1:{d}/9p", .{t.port}), .{ .headers = &.{"X-Test: 1"} });
            try kern.hstreamWait(id);
            var why: [128]u8 = undefined;
            try testing.expectEqual(@as(?[]const u8, null), result(id, &why));
            const fd = try kern.hstreamFd(id);
            release(id);
            _ = try kern.pwrite(fd, "9p bytes", 0);
            var buf: [16]u8 = undefined;
            try testing.expectEqual(@as(usize, 8), try readAll(fd, &buf, 8));
            try testing.expectEqualStrings("9p bytes", buf[0..8]);
            try kern.close(fd);

            // A server that closes: reads end.
            const id2 = try openHost(owner, try std.fmt.bufPrint(&url, "ws://127.0.0.1:{d}/9p", .{t.bye_port}), .{});
            try kern.hstreamWait(id2);
            const fd2 = try kern.hstreamFd(id2);
            release(id2);
            try testing.expectEqual(@as(usize, 0), try kern.pread(fd2, &buf, 0));
            try kern.close(fd2);

            // An unreachable server fails the wait's result.
            const id3 = try openHost(owner, "ws://127.0.0.1:1/9p", .{});
            defer release(id3);
            if (kern.hstreamWait(id3)) |_| return error.Connected else |_| {}
            const e = kern.errstr();
            @memcpy(t.msg[0..e.len], e);
            t.msg_len = e.len;
        }
    };
    var t: T = .{ .port = echo.port, .bye_port = bye.port };
    try kern.spawn("test", T, T.run, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| {
        std.debug.print("{s}\n", .{t.msg[0..t.msg_len]});
        return e;
    }
    try testing.expectEqualStrings("connection refused", t.msg[0..t.msg_len]);
    try testing.expectEqualStrings("connection refused", t.msg[0..t.msg_len]);
}

test "the keepalive pings an idle stream" {
    if (!kern.available) return error.SkipZigTest;
    setIo(testing.io);
    const saved = keepalive_idle_ns;
    keepalive_idle_ns = 200 * std.time.ns_per_ms;
    defer keepalive_idle_ns = saved;
    var echo: Echo = .{ .server = undefined, .port = 0 };
    try echo.start();
    const T = struct {
        port: u16,
        err: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        fn run(t: *@This()) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                t.err = e;
            };
        }
        fn body(t: *@This()) !void {
            var url: [64]u8 = undefined;
            const id = try openHost(@intFromPtr(kern.mach()), try std.fmt.bufPrint(&url, "ws://127.0.0.1:{d}/", .{t.port}), .{});
            try kern.hstreamWait(id);
            try testing.io.sleep(.fromMilliseconds(2500), .awake);
            release(id);
        }
    };
    var t: T = .{ .port = echo.port };
    try kern.spawn("test", T, T.run, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| return e;
    try testing.expect(echo.pings.load(.acquire) >= 2);
}
