//! WebSocket (RFC 6455) for 9P over WebSocket (design/websocket-9p.md):
//! URLs, the opening handshake, frame encoding and decoding, and masking,
//! as pure functions over `std.Io.Reader` and `std.Io.Writer`, with no
//! sockets. Both sides are here: the client that src/hstream.zig runs, and
//! the server side tests/wsrelay.zig needs. Also the proxy rules that pick
//! how a host-made connection goes out (HTTP_PROXY, NO_PROXY), and the
//! keepalive's timing.
//!
//! h9 offers no extensions, so frames never have RSV bits set, and it
//! sends each message as one frame.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

/// The largest message h9 accepts, and the most a stream buffers unread.
pub const max_message = 16 << 20;

/// The subprotocol h9 offers for 9P.
pub const subprotocol = "9p";

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,

    pub fn isControl(o: Opcode) bool {
        return @intFromEnum(o) & 8 != 0;
    }
};

/// Close codes h9 sends or reads.
pub const Close = struct {
    pub const normal = 1000;
    pub const going_away = 1001;
    pub const protocol_error = 1002;
    /// A data type the endpoint can't accept: a text message on a
    /// served 9P stream (design/serve.md).
    pub const unsupported_data = 1003;
    pub const invalid_data = 1007;
    pub const too_big = 1009;
    /// Received when a close frame has no code; never sent.
    pub const no_status = 1005;
};

// URLs

/// A `ws://` or `wss://` URL.
pub const Url = struct {
    tls: bool,
    /// The host as given, without IPv6 brackets.
    host: []const u8,
    port: u16,
    /// The request target: path and query, `/` when the URL has neither.
    target: []const u8,
    /// The authority as written (`host[:port]`, IPv6 in brackets), for
    /// the Host header.
    authority: []const u8,

    pub const Error = error{BadUrl};

    /// Whether `s` is a WebSocket URL: it starts with `ws://` or `wss://`.
    pub fn is(s: []const u8) bool {
        return std.mem.startsWith(u8, s, "ws://") or std.mem.startsWith(u8, s, "wss://");
    }

    /// Parses `s`; the result's slices point into it. Userinfo isn't
    /// accepted: a header carries credentials.
    pub fn parse(s: []const u8) Error!Url {
        const tls = std.mem.startsWith(u8, s, "wss://");
        if (!tls and !std.mem.startsWith(u8, s, "ws://")) return error.BadUrl;
        const rest = s[if (tls) "wss://".len else "ws://".len..];
        const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        const authority = rest[0..end];
        var target = rest[end..];
        if (std.mem.indexOfScalar(u8, target, '#')) |h| target = target[0..h];
        if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.BadUrl;
        var host = authority;
        var port: u16 = if (tls) 443 else 80;
        if (authority[0] == '[') {
            const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.BadUrl;
            host = authority[1..close];
            const after = authority[close + 1 ..];
            if (after.len > 0) {
                if (after[0] != ':') return error.BadUrl;
                port = parsePort(after[1..]) orelse return error.BadUrl;
            }
        } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            port = parsePort(authority[colon + 1 ..]) orelse return error.BadUrl;
        }
        if (host.len == 0) return error.BadUrl;
        for (host) |ch| if (ch <= ' ' or ch == 0x7f) return error.BadUrl;
        for (target) |ch| if (ch <= ' ' or ch == 0x7f) return error.BadUrl;
        return .{
            .tls = tls,
            .host = host,
            .port = port,
            .target = if (target.len == 0) "/" else if (target[0] == '?') target else target,
            .authority = authority,
        };
    }

    /// `s` with its query replaced by `…`, for the plan and traces.
    pub fn elide(s: []const u8) Elided {
        return .{ .s = s };
    }

    pub const Elided = struct {
        s: []const u8,
        pub fn format(e: Elided, w: *Writer) Writer.Error!void {
            const q = std.mem.indexOfScalar(u8, e.s, '?') orelse return w.writeAll(e.s);
            try w.writeAll(e.s[0 .. q + 1]);
            try w.writeAll("…");
        }
    };
};

fn parsePort(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    const p = std.fmt.parseInt(u16, s, 10) catch return null;
    return if (p == 0) null else p;
}

// Headers

/// Whether `line` (`Name: value`) is a header h9 sends itself, or that
/// changes the handshake, so a user can't set it.
pub fn reservedHeader(name: []const u8) bool {
    const n = std.mem.trim(u8, name, " \t");
    for ([_][]const u8{ "host", "upgrade", "connection", "content-length", "transfer-encoding" }) |r| {
        if (std.ascii.eqlIgnoreCase(n, r)) return true;
    }
    return std.ascii.startsWithIgnoreCase(n, "sec-websocket-");
}

pub const HeaderError = error{ BadHeader, ReservedHeader };

/// Checks a `Name: value` header line a user gave, and returns it
/// trimmed.
pub fn checkHeader(line: []const u8) HeaderError![]const u8 {
    const l = std.mem.trim(u8, line, " \t\r\n");
    const colon = std.mem.indexOfScalar(u8, l, ':') orelse return error.BadHeader;
    const name = l[0..colon];
    if (name.len == 0) return error.BadHeader;
    for (name) |ch| if (!isTokenChar(ch)) return error.BadHeader;
    for (l) |ch| if (ch == '\r' or ch == '\n' or ch == 0) return error.BadHeader;
    if (reservedHeader(name)) return error.ReservedHeader;
    return l;
}

fn isTokenChar(ch: u8) bool {
    return switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// The header's name, for the plan, which shows headers by name only.
pub fn headerName(line: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return line;
    return std.mem.trim(u8, line[0..colon], " \t");
}

// The handshake

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const key_len = 24;

/// A Sec-WebSocket-Key from 16 random bytes.
pub fn makeKey(random: *const [16]u8) [key_len]u8 {
    var out: [key_len]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, random);
    return out;
}

/// The Sec-WebSocket-Accept for `key`.
pub fn acceptFor(key: []const u8) [28]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update(guid);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

/// Writes the client's opening handshake and flushes it.
pub fn writeRequest(w: *Writer, url: Url, key: []const u8, protocols: []const []const u8, headers: []const []const u8) Writer.Error!void {
    try w.print("GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {s}\r\n", .{ url.target, url.authority, key });
    if (protocols.len > 0) {
        try w.writeAll("Sec-WebSocket-Protocol: ");
        for (protocols, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(p);
        }
        try w.writeAll("\r\n");
    }
    for (headers) |h| try w.print("{s}\r\n", .{h});
    try w.writeAll("\r\n");
    try w.flush();
}

pub const HandshakeError = error{
    /// The server answered with a status other than 101; `Response`
    /// has it.
    Status,
    /// The 101 was missing Upgrade, Connection or the right Accept.
    BadAccept,
    /// The server selected a subprotocol h9 didn't offer.
    BadProtocol,
    /// The server selected an extension.
    BadExtension,
    /// Not HTTP, or a header too long for the reader's buffer.
    BadResponse,
    ReadFailed,
    EndOfStream,
};

/// An HTTP status line and the headers h9 looks at.
pub const Response = struct {
    status: u16 = 0,
    /// The reason phrase, in `buf`.
    reason: []const u8 = "",
    /// The selected subprotocol, in `buf`, or null for none.
    protocol: ?[]const u8 = null,
    buf: [128]u8 = undefined,
    /// If set, gets the status line and every header line as received,
    /// for a credential helper's retry (design/credential-helpers.md).
    head: ?*Head = null,

    /// A response's head, as text: the status line and the headers, each
    /// ending in CRLF. What doesn't fit is left out.
    pub const Head = struct {
        buf: [4096]u8 = undefined,
        len: usize = 0,

        pub fn text(h: *const Head) []const u8 {
            return h.buf[0..h.len];
        }

        fn add(h: *Head, line: []const u8) void {
            if (h.len + line.len + 2 > h.buf.len) return;
            @memcpy(h.buf[h.len..][0..line.len], line);
            @memcpy(h.buf[h.len + line.len ..][0..2], "\r\n");
            h.len += line.len + 2;
        }
    };

    fn keep(r: *Response, used: *usize, s: []const u8) []const u8 {
        const n = @min(s.len, r.buf.len - used.*);
        @memcpy(r.buf[used.*..][0..n], s[0..n]);
        defer used.* += n;
        return r.buf[used.*..][0..n];
    }
};

/// Reads an HTTP response's status line and headers up to the blank line,
/// keeping the status and reason in `resp`. Each line must fit in `r`'s
/// buffer. Calls `header` for each header.
fn readHead(r: *Reader, resp: *Response, used: *usize, ctx: anytype, comptime header: fn (@TypeOf(ctx), []const u8, []const u8) void) HandshakeError!void {
    const status_line = try readLine(r);
    // HTTP/1.1 101 Switching Protocols
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.BadResponse;
    if (resp.head) |h| {
        h.len = 0;
        h.add(status_line);
    }
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    _ = parts.next();
    resp.status = std.fmt.parseInt(u16, parts.next() orelse return error.BadResponse, 10) catch return error.BadResponse;
    resp.reason = resp.keep(used, parts.rest());
    while (true) {
        const l = try readLine(r);
        if (l.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse return error.BadResponse;
        if (resp.head) |h| h.add(l);
        header(ctx, std.mem.trim(u8, l[0..colon], " \t"), std.mem.trim(u8, l[colon + 1 ..], " \t"));
    }
}

fn readLine(r: *Reader) HandshakeError![]const u8 {
    const l = r.takeDelimiterInclusive('\n') catch |e| return switch (e) {
        error.ReadFailed => error.ReadFailed,
        error.EndOfStream => error.EndOfStream,
        error.StreamTooLong => error.BadResponse,
    };
    return std.mem.trimEnd(u8, l, "\r\n");
}

/// Reads the server's answer to `writeRequest` and checks it. `offered`
/// is what was offered; a server may select one of them or none.
pub fn readResponse(r: *Reader, key: []const u8, offered: []const []const u8, resp: *Response) HandshakeError!void {
    const Ctx = struct {
        resp: *Response,
        used: usize = 0,
        upgrade: bool = false,
        connection: bool = false,
        accept: bool = false,
        extension: bool = false,
        want: [28]u8,
        fn header(c: *@This(), name: []const u8, value: []const u8) void {
            if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
                c.upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                var it = std.mem.tokenizeAny(u8, value, ", \t");
                while (it.next()) |tok| if (std.ascii.eqlIgnoreCase(tok, "upgrade")) {
                    c.connection = true;
                };
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
                c.accept = std.mem.eql(u8, value, &c.want);
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) {
                c.resp.protocol = c.resp.keep(&c.used, value);
            } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-extensions")) {
                c.extension = value.len > 0;
            }
        }
    };
    var ctx: Ctx = .{ .resp = resp, .want = acceptFor(key) };
    resp.protocol = null;
    try readHead(r, resp, &ctx.used, &ctx, Ctx.header);
    if (resp.status != 101) return error.Status;
    if (!ctx.upgrade or !ctx.connection or !ctx.accept) return error.BadAccept;
    if (ctx.extension) return error.BadExtension;
    if (resp.protocol) |p| {
        for (offered) |o| {
            if (std.mem.eql(u8, o, p)) return;
        }
        return error.BadProtocol;
    }
}

/// A client's opening handshake, as the server side reads it.
pub const Request = struct {
    /// The method, in `buf`: `GET` for an upgrade.
    method: []const u8 = "",
    /// The request target, in `buf`.
    target: []const u8 = "",
    key: []const u8 = "",
    /// The offered subprotocols, comma-separated, in `buf`.
    protocols: []const u8 = "",
    /// Every header line, `Name: value\n`, in `buf`, for checks.
    headers: []const u8 = "",
    upgrade: bool = false,
    version13: bool = false,
    buf: [4096]u8 = undefined,
    used: usize = 0,

    fn keep(q: *Request, s: []const u8) []const u8 {
        const n = @min(s.len, q.buf.len - q.used);
        @memcpy(q.buf[q.used..][0..n], s[0..n]);
        defer q.used += n;
        return q.buf[q.used..][0..n];
    }

    /// The value of header `name`, or null.
    pub fn header(q: *const Request, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, q.headers, '\n');
        while (it.next()) |l| {
            const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(l[0..colon], name)) return std.mem.trim(u8, l[colon + 1 ..], " \t");
        }
        return null;
    }

    /// Whether `p` was offered.
    pub fn offers(q: *const Request, p: []const u8) bool {
        var it = std.mem.tokenizeAny(u8, q.protocols, ", \t");
        while (it.next()) |tok| if (std.mem.eql(u8, tok, p)) return true;
        return false;
    }
};

/// Reads a client's opening handshake (the server side). Any method is
/// read, so the caller can answer one that isn't `GET` with 405.
pub fn readRequest(r: *Reader, q: *Request) HandshakeError!void {
    const first = try readLine(r);
    // GET /path HTTP/1.1
    var parts = std.mem.splitScalar(u8, first, ' ');
    const method = parts.next() orelse "";
    if (method.len == 0) return error.BadResponse;
    q.method = q.keep(method);
    q.target = q.keep(parts.next() orelse return error.BadResponse);
    if (!std.mem.startsWith(u8, parts.next() orelse "", "HTTP/1.")) return error.BadResponse;
    const start = q.used;
    var key_at: ?struct { usize, usize } = null;
    var proto_at: ?struct { usize, usize } = null;
    while (true) {
        const l = try readLine(r);
        if (l.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse return error.BadResponse;
        const name = std.mem.trim(u8, l[0..colon], " \t");
        const value = std.mem.trim(u8, l[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "upgrade")) q.upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-version")) q.version13 = std.mem.eql(u8, value, "13");
        _ = q.keep(name);
        _ = q.keep(": ");
        const vat = q.used;
        _ = q.keep(value);
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) key_at = .{ vat, q.used };
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) proto_at = .{ vat, q.used };
        _ = q.keep("\n");
    }
    q.headers = q.buf[start..q.used];
    if (key_at) |k| q.key = q.buf[k[0]..k[1]];
    if (proto_at) |p| q.protocols = q.buf[p[0]..p[1]];
}

/// The server's 101, selecting `protocol` if not null.
pub fn writeAccept(w: *Writer, key: []const u8, protocol: ?[]const u8) Writer.Error!void {
    try w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n", .{&acceptFor(key)});
    if (protocol) |p| try w.print("Sec-WebSocket-Protocol: {s}\r\n", .{p});
    try w.writeAll("\r\n");
    try w.flush();
}

/// A refusal: any other status, with no body.
pub fn writeStatus(w: *Writer, status: u16, reason: []const u8) Writer.Error!void {
    try w.print("HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ status, reason });
    try w.flush();
}

/// A status's reason phrase, for `writeStatus`.
pub fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        426 => "Upgrade Required",
        503 => "Service Unavailable",
        else => "Error",
    };
}

/// What a WebSocket listener accepts (design/serve.md, "WebSocket
/// listeners").
pub const ServerPolicy = struct {
    /// The one path upgrades are answered on.
    path: []const u8 = "/",
    /// The token a request must carry, as `Authorization: Bearer TOKEN`
    /// or `?token=TOKEN`; null for none.
    token: ?[]const u8 = null,
    /// `Origin`s accepted; "*" accepts any. A request without `Origin`
    /// is accepted whatever this says.
    origins: []const []const u8 = &.{},
};

/// The answer to a request: an upgrade selecting `protocol` (or none),
/// or a refusal with an HTTP status.
pub const Verdict = union(enum) {
    accept: ?[]const u8,
    refuse: u16,
};

/// Checks a client's opening handshake against a listener's policy:
/// 404 for another path, 405 for another method, 426 for a request
/// that isn't an upgrade, 403 for an `Origin` not allowed, 401 without
/// the token, and 400 when subprotocols are offered but not `9p`.
pub fn checkUpgrade(q: *const Request, p: ServerPolicy) Verdict {
    const qmark = std.mem.indexOfScalar(u8, q.target, '?');
    const path = q.target[0 .. qmark orelse q.target.len];
    if (!std.mem.eql(u8, path, p.path)) return .{ .refuse = 404 };
    if (!std.mem.eql(u8, q.method, "GET")) return .{ .refuse = 405 };
    if (!q.upgrade or !q.version13 or q.key.len == 0) return .{ .refuse = 426 };
    if (q.header("origin")) |o| if (!originAllowed(p.origins, o)) return .{ .refuse = 403 };
    if (p.token) |want| {
        const query = if (qmark) |i| q.target[i + 1 ..] else "";
        if (!tokenGiven(q.header("authorization"), query, want)) return .{ .refuse = 401 };
    }
    if (q.protocols.len > 0 and !q.offers(subprotocol)) return .{ .refuse = 400 };
    return .{ .accept = if (q.offers(subprotocol)) subprotocol else null };
}

fn originAllowed(allowed: []const []const u8, origin: []const u8) bool {
    for (allowed) |a| {
        if (std.mem.eql(u8, a, "*") or std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, a, "/"), origin)) return true;
    }
    return false;
}

/// Whether the token is in an `Authorization: Bearer` header or the
/// query's `token` parameter, compared in constant time.
fn tokenGiven(auth: ?[]const u8, query: []const u8, want: []const u8) bool {
    var ok = false;
    if (auth) |a| {
        if (a.len > 7 and std.ascii.eqlIgnoreCase(a[0..7], "bearer ")) ok = sameToken(std.mem.trim(u8, a[7..], " \t"), want) or ok;
    }
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |kv| {
        if (!std.mem.startsWith(u8, kv, "token=")) continue;
        var buf: [512]u8 = undefined;
        const v = queryDecode(&buf, kv["token=".len..]) orelse continue;
        ok = sameToken(v, want) or ok;
    }
    return ok;
}

/// Compares through SHA-256, so the time taken depends on neither
/// token's contents.
fn sameToken(got: []const u8, want: []const u8) bool {
    const Sha = std.crypto.hash.sha2.Sha256;
    var a: [Sha.digest_length]u8 = undefined;
    var b: [Sha.digest_length]u8 = undefined;
    Sha.hash(got, &a, .{});
    Sha.hash(want, &b, .{});
    return std.crypto.timing_safe.eql([Sha.digest_length]u8, a, b);
}

/// `%XX` and `+` decoded into `buf`, or null if it doesn't fit or is
/// malformed.
fn queryDecode(buf: []u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (n >= buf.len) return null;
        switch (s[i]) {
            '%' => {
                if (i + 3 > s.len) return null;
                buf[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
                i += 3;
            },
            '+' => {
                buf[n] = ' ';
                i += 1;
            },
            else => |c| {
                buf[n] = c;
                i += 1;
            },
        }
    }
    return buf[0..n];
}

// Frames

pub const Header = struct {
    fin: bool = true,
    opcode: Opcode,
    mask: ?[4]u8 = null,
    len: u64,
};

pub const FrameError = error{
    /// RSV bits, an unknown opcode, a bad control frame, a continuation
    /// without a message, a new message inside a fragmented one, or a
    /// mask on the wrong side.
    ProtocolError,
    /// A frame or message longer than the limit.
    TooBig,
    ReadFailed,
    EndOfStream,
};

/// Writes one frame's header. A client passes a mask, and the payload
/// must then be masked with it (`writeFrame` does both).
pub fn writeHeader(w: *Writer, h: Header) Writer.Error!void {
    var b: [14]u8 = undefined;
    b[0] = @as(u8, if (h.fin) 0x80 else 0) | @intFromEnum(h.opcode);
    const m: u8 = if (h.mask != null) 0x80 else 0;
    var n: usize = 2;
    if (h.len < 126) {
        b[1] = m | @as(u8, @intCast(h.len));
    } else if (h.len <= 0xffff) {
        b[1] = m | 126;
        std.mem.writeInt(u16, b[2..4], @intCast(h.len), .big);
        n = 4;
    } else {
        b[1] = m | 127;
        std.mem.writeInt(u64, b[2..10], h.len, .big);
        n = 10;
    }
    if (h.mask) |k| {
        @memcpy(b[n..][0..4], &k);
        n += 4;
    }
    try w.writeAll(b[0..n]);
}

/// XORs `bytes` with `mask`, as if they started `offset` bytes into the
/// payload.
pub fn applyMask(mask: [4]u8, offset: u64, bytes: []u8) void {
    for (bytes, 0..) |*b, i| b.* ^= mask[@intCast((offset + i) & 3)];
}

/// Writes a whole frame, masking a copy of the payload when `mask` is
/// given, and flushes.
pub fn writeFrame(w: *Writer, opcode: Opcode, payload: []const u8, mask: ?[4]u8) Writer.Error!void {
    try writeHeader(w, .{ .opcode = opcode, .mask = mask, .len = payload.len });
    if (mask) |k| {
        var chunk: [512]u8 = undefined;
        var off: usize = 0;
        while (off < payload.len) {
            const n = @min(chunk.len, payload.len - off);
            @memcpy(chunk[0..n], payload[off..][0..n]);
            applyMask(k, off, chunk[0..n]);
            try w.writeAll(chunk[0..n]);
            off += n;
        }
    } else try w.writeAll(payload);
    try w.flush();
}

/// A close frame's payload: the code and a reason cut to fit.
pub fn closePayload(buf: *[125]u8, code: u16, reason: []const u8) []const u8 {
    std.mem.writeInt(u16, buf[0..2], code, .big);
    const n = @min(reason.len, buf.len - 2);
    @memcpy(buf[2..][0..n], reason[0..n]);
    return buf[0 .. 2 + n];
}

/// Reads a frame's header, without checking it against the message state.
pub fn readHeader(r: *Reader) FrameError!Header {
    const b = try r.takeArray(2);
    const b0 = b[0];
    const b1 = b[1];
    if (b0 & 0x70 != 0) return error.ProtocolError;
    var h: Header = .{ .fin = b0 & 0x80 != 0, .opcode = @enumFromInt(@as(u4, @truncate(b0))), .len = b1 & 0x7f };
    if (h.len == 126) {
        h.len = try r.takeInt(u16, .big);
        if (h.len < 126) return error.ProtocolError;
    } else if (h.len == 127) {
        h.len = try r.takeInt(u64, .big);
        if (h.len <= 0xffff or h.len >> 63 != 0) return error.ProtocolError;
    }
    if (b1 & 0x80 != 0) h.mask = (try r.takeArray(4)).*;
    return h;
}

/// A received frame, checked against the message it continues.
pub const Frame = struct {
    /// For a continuation, the message's opcode.
    opcode: Opcode,
    /// The message ends with this frame.
    fin: bool,
    len: u64,
    mask: ?[4]u8,
    /// This frame starts a message (it isn't a continuation).
    first: bool,
};

/// Tracks fragmented messages across frames, and enforces the limits.
pub const Receiver = struct {
    /// Which side receives: a server's frames from a client are masked,
    /// a client's from a server aren't.
    side: enum { client, server },
    limit: u64 = max_message,
    /// The fragmented message in progress, if any.
    msg: ?Opcode = null,
    msg_len: u64 = 0,

    /// Reads the next frame's header and checks it. The caller reads the
    /// payload (`readPayload`) before the next call. Control frames can
    /// come between a message's fragments.
    pub fn next(rc: *Receiver, r: *Reader) FrameError!Frame {
        const h = try readHeader(r);
        if ((h.mask != null) != (rc.side == .server)) return error.ProtocolError;
        switch (h.opcode) {
            .close, .ping, .pong => {
                if (!h.fin or h.len > 125) return error.ProtocolError;
                return .{ .opcode = h.opcode, .fin = true, .len = h.len, .mask = h.mask, .first = true };
            },
            .text, .binary => {
                if (rc.msg != null) return error.ProtocolError;
                if (h.len > rc.limit) return error.TooBig;
                if (!h.fin) {
                    rc.msg = h.opcode;
                    rc.msg_len = h.len;
                }
                return .{ .opcode = h.opcode, .fin = h.fin, .len = h.len, .mask = h.mask, .first = true };
            },
            .continuation => {
                const op = rc.msg orelse return error.ProtocolError;
                rc.msg_len += h.len;
                if (rc.msg_len > rc.limit) return error.TooBig;
                if (h.fin) rc.msg = null;
                return .{ .opcode = op, .fin = h.fin, .len = h.len, .mask = h.mask, .first = false };
            },
            _ => return error.ProtocolError,
        }
    }
};

/// Reads `dest.len` payload bytes, `offset` bytes into a frame, unmasking
/// them.
pub fn readPayload(r: *Reader, f: Frame, offset: u64, dest: []u8) FrameError!void {
    try r.readSliceAll(dest);
    if (f.mask) |k| applyMask(k, offset, dest);
}

/// Parses a close frame's payload. An empty one is 1005, no status.
pub fn parseClose(payload: []const u8) FrameError!struct { code: u16, reason: []const u8 } {
    if (payload.len == 0) return .{ .code = Close.no_status, .reason = "" };
    if (payload.len == 1) return error.ProtocolError;
    return .{ .code = std.mem.readInt(u16, payload[0..2], .big), .reason = payload[2..] };
}

/// Whether `s` is valid UTF-8, as text messages must be.
pub fn validUtf8(s: []const u8) bool {
    return std.unicode.utf8ValidateSlice(s);
}

// Proxies

/// An `http://` proxy URL: where to connect, and the credentials to send.
pub const Proxy = struct {
    host: []const u8,
    port: u16,
    /// `user:password`, still percent-encoded, or null.
    userinfo: ?[]const u8,
    /// The URL with userinfo elided, for the plan.
    shown_host: []const u8,

    pub const Error = error{BadProxy};

    pub fn parse(s: []const u8) Error!Proxy {
        if (!std.ascii.startsWithIgnoreCase(s, "http://")) return error.BadProxy;
        var rest = s["http://".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[0..slash];
        var userinfo: ?[]const u8 = null;
        if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
            userinfo = rest[0..at];
            rest = rest[at + 1 ..];
        }
        var host = rest;
        var port: u16 = 80;
        if (rest.len > 0 and rest[0] == '[') {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse return error.BadProxy;
            host = rest[1..close];
            if (rest.len > close + 1) {
                if (rest[close + 1] != ':') return error.BadProxy;
                port = parsePort(rest[close + 2 ..]) orelse return error.BadProxy;
            }
        } else if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
            host = rest[0..colon];
            port = parsePort(rest[colon + 1 ..]) orelse return error.BadProxy;
        }
        if (host.len == 0) return error.BadProxy;
        return .{ .host = host, .port = port, .userinfo = userinfo, .shown_host = rest };
    }

    /// Writes the Proxy-Authorization header for `userinfo`, decoded.
    fn writeAuth(p: Proxy, w: *Writer) Writer.Error!void {
        const ui = p.userinfo orelse return;
        var dec: [256]u8 = undefined;
        const plain = percentDecode(&dec, ui);
        var enc: [std.base64.standard.Encoder.calcSize(256)]u8 = undefined;
        try w.print("Proxy-Authorization: Basic {s}\r\n", .{std.base64.standard.Encoder.encode(&enc, plain)});
    }
};

fn percentDecode(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) : (n += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                buf[n] = b;
                i += 3;
                continue;
            } else |_| {}
        }
        buf[n] = s[i];
        i += 1;
    }
    return buf[0..n];
}

/// Writes a CONNECT request for `host:port` through `proxy`, and flushes.
pub fn writeConnect(w: *Writer, proxy: Proxy, url: Url) Writer.Error!void {
    const v6 = std.mem.indexOfScalar(u8, url.host, ':') != null;
    const lb = if (v6) "[" else "";
    const rb = if (v6) "]" else "";
    try w.print("CONNECT {s}{s}{s}:{d} HTTP/1.1\r\nHost: {s}{s}{s}:{d}\r\n", .{ lb, url.host, rb, url.port, lb, url.host, rb, url.port });
    try proxy.writeAuth(w);
    try w.writeAll("\r\n");
    try w.flush();
}

/// Reads the proxy's answer to `writeConnect`. A status other than 2xx
/// is `error.Status`, with `resp` holding it.
pub fn readConnect(r: *Reader, resp: *Response) HandshakeError!void {
    const Ctx = struct {
        fn header(_: void, _: []const u8, _: []const u8) void {}
    };
    var used: usize = 0;
    try readHead(r, resp, &used, {}, Ctx.header);
    if (resp.status / 100 != 2) return error.Status;
}

/// Whether NO_PROXY's `list` says `host` goes direct: comma-separated
/// names, where a leading `.` or `*.` matches subdomains (and, as curl
/// does, the name itself), and `*` matches every host. Ports in entries
/// are ignored; matching ignores case.
pub fn noProxy(list: []const u8, host: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, ", \t");
    while (it.next()) |raw| {
        var e = raw;
        if (std.mem.eql(u8, e, "*")) return true;
        if (std.mem.startsWith(u8, e, "*.")) e = e[1..];
        // host:port, but not a bare IPv6 address.
        if (std.mem.indexOfScalar(u8, e, ':')) |colon| {
            if (std.mem.indexOfScalar(u8, e[colon + 1 ..], ':') == null) e = e[0..colon];
        }
        if (e.len > 1 and e[0] == '[' and e[e.len - 1] == ']') e = e[1 .. e.len - 1];
        if (e.len == 0) continue;
        if (e[0] == '.') {
            if (std.ascii.endsWithIgnoreCase(host, e)) return true;
            if (std.ascii.eqlIgnoreCase(host, e[1..])) return true;
        } else {
            if (std.ascii.eqlIgnoreCase(host, e)) return true;
            if (host.len > e.len and std.ascii.endsWithIgnoreCase(host, e) and host[host.len - e.len - 1] == '.') return true;
        }
    }
    return false;
}

/// Proxies for host-made connections, from the environment or an
/// embedder.
pub const ProxyConfig = struct {
    /// For `ws://`: HTTP_PROXY. Empty or null means direct.
    http: ?[]const u8 = null,
    /// For `wss://`: HTTPS_PROXY.
    https: ?[]const u8 = null,
    /// NO_PROXY.
    no_proxy: []const u8 = "",

    /// The proxy URL `url` goes through, or null for direct.
    pub fn pick(c: ProxyConfig, url: Url) ?[]const u8 {
        const p = (if (url.tls) c.https else c.http) orelse return null;
        if (p.len == 0) return null;
        if (noProxy(c.no_proxy, url.host)) return null;
        return p;
    }
};

// Keepalive

/// The keepalive's timing: after `idle_ns` without a frame from the
/// server, ping; if nothing arrives within another `idle_ns`, fail.
pub const Keepalive = struct {
    idle_ns: u64 = 30 * std.time.ns_per_s,
    /// When a frame last arrived (or the stream opened).
    last_rx: i64,
    /// When the unanswered ping went, if one did.
    ping_at: ?i64 = null,

    pub const Action = enum { none, ping, fail };

    /// Any frame from the server: the connection is alive.
    pub fn received(k: *Keepalive, now: i64) void {
        k.last_rx = now;
        k.ping_at = null;
    }

    /// What to do at `now`. `ping` is returned once per idle period.
    pub fn tick(k: *Keepalive, now: i64) Action {
        const idle: i64 = @intCast(k.idle_ns);
        if (k.ping_at) |at| return if (now - at >= idle) .fail else .none;
        if (now - k.last_rx >= idle) {
            k.ping_at = now;
            return .ping;
        }
        return .none;
    }
};

const t = std.testing;

test "URLs" {
    const u = try Url.parse("wss://fs.example/9p?token=abc");
    try t.expect(u.tls);
    try t.expectEqualStrings("fs.example", u.host);
    try t.expectEqual(@as(u16, 443), u.port);
    try t.expectEqualStrings("/9p?token=abc", u.target);
    try t.expectEqualStrings("fs.example", u.authority);
    const v = try Url.parse("ws://127.0.0.1:8080");
    try t.expect(!v.tls);
    try t.expectEqual(@as(u16, 8080), v.port);
    try t.expectEqualStrings("/", v.target);
    try t.expectEqualStrings("127.0.0.1:8080", v.authority);
    const w6 = try Url.parse("ws://[::1]:9/x#frag");
    try t.expectEqualStrings("::1", w6.host);
    try t.expectEqual(@as(u16, 9), w6.port);
    try t.expectEqualStrings("/x", w6.target);
    try t.expectEqualStrings("[::1]:9", w6.authority);
    try t.expectEqualStrings("?q", (try Url.parse("ws://h?q")).target);
    for ([_][]const u8{ "http://x/", "ws://", "ws:///p", "ws://h:0/", "ws://h:x/", "ws://u@h/", "ws://h /", "ws://[::1/" }) |bad| {
        try t.expectError(error.BadUrl, Url.parse(bad));
    }
    try t.expect(Url.is("ws://x") and Url.is("wss://x") and !Url.is("tcp!x!1") and !Url.is("/ws"));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("wss://fs/9p?…", try std.fmt.bufPrint(&buf, "{f}", .{Url.elide("wss://fs/9p?token=abc")}));
    try t.expectEqualStrings("ws://fs/9p", try std.fmt.bufPrint(&buf, "{f}", .{Url.elide("ws://fs/9p")}));
}

test "user headers" {
    try t.expectEqualStrings("Authorization: Bearer x", try checkHeader("  Authorization: Bearer x\r\n"));
    try t.expectError(error.ReservedHeader, checkHeader("host: x"));
    try t.expectError(error.ReservedHeader, checkHeader("Sec-WebSocket-Protocol: 9p"));
    try t.expectError(error.ReservedHeader, checkHeader("Connection: close"));
    try t.expectError(error.ReservedHeader, checkHeader("Upgrade: h2c"));
    try t.expectError(error.BadHeader, checkHeader("no colon"));
    try t.expectError(error.BadHeader, checkHeader(": empty name"));
    try t.expectError(error.BadHeader, checkHeader("bad name: x"));
    try t.expectEqualStrings("Authorization", headerName("Authorization: Bearer x"));
}

test "the handshake's key and accept (RFC 6455's example)" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    try t.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptFor(key));
    const raw: [16]u8 = "the sample nonce".*;
    try t.expectEqualStrings(key, &makeKey(&raw));
}

test "a recorded handshake: request, then the server's 101" {
    var out: [512]u8 = undefined;
    var w: Writer = .fixed(&out);
    const url = try Url.parse("ws://server.example.com/chat");
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    try writeRequest(&w, url, key, &.{subprotocol}, &.{"Authorization: Bearer t"});
    try t.expectEqualStrings("GET /chat HTTP/1.1\r\nHost: server.example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: 9p\r\nAuthorization: Bearer t\r\n\r\n", w.buffered());

    // The server side reads it back.
    var rr: Reader = .fixed(w.buffered());
    var q: Request = .{};
    try readRequest(&rr, &q);
    try t.expectEqualStrings("/chat", q.target);
    try t.expectEqualStrings(key, q.key);
    try t.expect(q.upgrade and q.version13 and q.offers("9p") and !q.offers("x"));
    try t.expectEqualStrings("Bearer t", q.header("authorization").?);

    var ok: Response = .{};
    var r1: Reader = .fixed("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSec-WebSocket-Protocol: 9p\r\n\r\nrest");
    try readResponse(&r1, key, &.{subprotocol}, &ok);
    try t.expectEqualStrings("9p", ok.protocol.?);
    try t.expectEqualStrings("rest", r1.buffered());

    // No subprotocol selected is fine; another one isn't.
    var none: Response = .{};
    var r2: Reader = .fixed("HTTP/1.1 101 OK\r\nupgrade: WebSocket\r\nconnection: keep-alive, Upgrade\r\nsec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n");
    try readResponse(&r2, key, &.{subprotocol}, &none);
    try t.expectEqual(@as(?[]const u8, null), none.protocol);
    var other: Response = .{};
    var r3: Reader = .fixed("HTTP/1.1 101 OK\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSec-WebSocket-Protocol: chat\r\n\r\n");
    try t.expectError(error.BadProtocol, readResponse(&r3, key, &.{subprotocol}, &other));

    // A head, for a credential helper's retry (design/credential-helpers.md).
    var head: Response.Head = .{};
    var denied: Response = .{ .head = &head };
    var r4: Reader = .fixed("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer error=\"invalid_token\"\nContent-Length: 0\r\n\r\n");
    try t.expectError(error.Status, readResponse(&r4, key, &.{subprotocol}, &denied));
    try t.expectEqual(@as(u16, 401), denied.status);
    try t.expectEqualStrings("Unauthorized", denied.reason);
    try t.expectEqualStrings("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer error=\"invalid_token\"\r\nContent-Length: 0\r\n", head.text());

    var bad: Response = .{};
    var r5: Reader = .fixed("HTTP/1.1 101 OK\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: wrong\r\n\r\n");
    try t.expectError(error.BadAccept, readResponse(&r5, key, &.{}, &bad));
    var ext: Response = .{};
    var r6: Reader = .fixed("HTTP/1.1 101 OK\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n");
    try t.expectError(error.BadExtension, readResponse(&r6, key, &.{}, &ext));
    var junk: Response = .{};
    var r7: Reader = .fixed("SSH-2.0-OpenSSH\r\n\r\n");
    try t.expectError(error.BadResponse, readResponse(&r7, key, &.{}, &junk));

    var acc: [256]u8 = undefined;
    var aw: Writer = .fixed(&acc);
    try writeAccept(&aw, key, "9p");
    var r8: Reader = .fixed(aw.buffered());
    var back: Response = .{};
    try readResponse(&r8, key, &.{subprotocol}, &back);
}

test "masking" {
    const k: [4]u8 = .{ 0x37, 0xfa, 0x21, 0x3d };
    var b = "Hello".*;
    applyMask(k, 0, &b);
    try t.expectEqualSlices(u8, &.{ 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, &b);
    // Unmasking in two pieces at an offset gives the same bytes.
    applyMask(k, 0, b[0..3]);
    applyMask(k, 3, b[3..]);
    try t.expectEqualStrings("Hello", &b);
}

test "every payload length encoding" {
    const big = try t.allocator.alloc(u8, 70000);
    defer t.allocator.free(big);
    for (big, 0..) |*x, i| x.* = @truncate(i);
    for ([_]usize{ 0, 1, 125, 126, 127, 0xffff, 0x10000, 70000 }) |n| {
        for ([_]?[4]u8{ null, .{ 1, 2, 3, 4 } }) |mask| {
            var out: std.Io.Writer.Allocating = .init(t.allocator);
            defer out.deinit();
            try writeFrame(&out.writer, .binary, big[0..n], mask);
            const len_bytes: usize = if (n < 126) 2 else if (n <= 0xffff) 4 else 10;
            const hdr_len: usize = len_bytes + @as(usize, if (mask != null) 4 else 0);
            try t.expectEqual(hdr_len + n, out.written().len);
            var r: Reader = .fixed(out.written());
            var rc: Receiver = .{ .side = if (mask != null) .server else .client };
            const f = try rc.next(&r);
            try t.expectEqual(@as(u64, n), f.len);
            try t.expect(f.fin and f.first and f.opcode == .binary);
            const got = try t.allocator.alloc(u8, n);
            defer t.allocator.free(got);
            try readPayload(&r, f, 0, got);
            try t.expectEqualSlices(u8, big[0..n], got);
        }
    }
    // Non-minimal lengths are refused.
    var r1: Reader = .fixed(&.{ 0x82, 126, 0, 5 });
    var rc1: Receiver = .{ .side = .client };
    try t.expectError(error.ProtocolError, rc1.next(&r1));
    var r2: Reader = .fixed(&.{ 0x82, 127, 0, 0, 0, 0, 0, 0, 0xff, 0xff });
    var rc2: Receiver = .{ .side = .client };
    try t.expectError(error.ProtocolError, rc2.next(&r2));
}

fn frameBytes(out: *std.Io.Writer.Allocating, fin: bool, op: Opcode, payload: []const u8) !void {
    try writeHeader(&out.writer, .{ .fin = fin, .opcode = op, .len = payload.len });
    try out.writer.writeAll(payload);
}

test "fragmented binary and text messages, with control frames between fragments" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try frameBytes(&out, false, .text, "hel");
    try frameBytes(&out, true, .ping, "p");
    try frameBytes(&out, false, .continuation, "lo ");
    try frameBytes(&out, true, .continuation, "wörld");
    try frameBytes(&out, false, .binary, &.{ 1, 2 });
    try frameBytes(&out, true, .continuation, &.{3});
    try frameBytes(&out, true, .close, &.{ 0x03, 0xe8, 'b', 'y', 'e' });
    var r: Reader = .fixed(out.written());
    var rc: Receiver = .{ .side = .client };
    var text: [32]u8 = undefined;
    var tn: usize = 0;
    var f = try rc.next(&r);
    try t.expect(f.opcode == .text and !f.fin and f.first);
    try readPayload(&r, f, 0, text[tn..][0..f.len]);
    tn += f.len;
    f = try rc.next(&r);
    try t.expect(f.opcode == .ping and f.len == 1);
    try r.discardAll(1);
    for (0..2) |_| {
        f = try rc.next(&r);
        try t.expect(f.opcode == .text and !f.first);
        try readPayload(&r, f, 0, text[tn..][0..f.len]);
        tn += f.len;
    }
    try t.expect(f.fin);
    try t.expectEqualStrings("hello wörld", text[0..tn]);
    try t.expect(validUtf8(text[0..tn]));
    f = try rc.next(&r);
    try t.expect(f.opcode == .binary and !f.fin);
    try r.discardAll(f.len);
    f = try rc.next(&r);
    try t.expect(f.opcode == .binary and f.fin and !f.first);
    try r.discardAll(f.len);
    f = try rc.next(&r);
    try t.expect(f.opcode == .close);
    const cl = try parseClose(try r.take(f.len));
    try t.expectEqual(@as(u16, 1000), cl.code);
    try t.expectEqualStrings("bye", cl.reason);
}

test "protocol errors" {
    const cases = [_][]const u8{
        &.{ 0x80, 0 }, // a continuation with no message
        &.{ 0x09, 0 }, // a fragmented ping
        &.{ 0x89, 126, 0, 126 }, // a ping over 125 bytes
        &.{ 0xc2, 0 }, // RSV1
        &.{ 0x83, 0 }, // opcode 3
        &.{ 0x82, 0x80, 0, 0, 0, 0 }, // a masked frame from the server
    };
    for (cases) |c| {
        var r: Reader = .fixed(c);
        var rc: Receiver = .{ .side = .client };
        try t.expectError(error.ProtocolError, rc.next(&r));
    }
    // A new message inside a fragmented one.
    var r: Reader = .fixed(&.{ 0x02, 0, 0x81, 0 });
    var rc: Receiver = .{ .side = .client };
    _ = try rc.next(&r);
    try t.expectError(error.ProtocolError, rc.next(&r));
    // An unmasked frame from a client.
    var r2: Reader = .fixed(&.{ 0x82, 0 });
    var rc2: Receiver = .{ .side = .server };
    try t.expectError(error.ProtocolError, rc2.next(&r2));
    try t.expectError(error.ProtocolError, parseClose(&.{3}));
    try t.expectEqual(@as(u16, Close.no_status), (try parseClose("")).code);
}

test "UTF-8 validation of text" {
    try t.expect(validUtf8("plain"));
    try t.expect(validUtf8("ℏ and ☃"));
    try t.expect(!validUtf8(&.{ 0xff, 0xfe }));
    try t.expect(!validUtf8(&.{ 0xe2, 0x84 })); // cut short
    try t.expect(!validUtf8(&.{ 0xed, 0xa0, 0x80 })); // a surrogate
}

test "size limits" {
    var r: Reader = .fixed(&.{ 0x82, 127, 0, 0, 0, 0, 0x01, 0, 0, 1 });
    var rc: Receiver = .{ .side = .client };
    try t.expectError(error.TooBig, rc.next(&r));
    // Fragments add up.
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try writeHeader(&out.writer, .{ .fin = false, .opcode = .binary, .len = 6 });
    try out.writer.writeAll("abcdef");
    try writeHeader(&out.writer, .{ .fin = true, .opcode = .continuation, .len = 6 });
    var r2: Reader = .fixed(out.written());
    var rc2: Receiver = .{ .side = .client, .limit = 10 };
    const f = try rc2.next(&r2);
    try r2.discardAll(f.len);
    try t.expectError(error.TooBig, rc2.next(&r2));
}

test "the keepalive's timing" {
    const s = std.time.ns_per_s;
    var k: Keepalive = .{ .last_rx = 0 };
    try t.expectEqual(Keepalive.Action.none, k.tick(29 * s));
    try t.expectEqual(Keepalive.Action.ping, k.tick(30 * s));
    try t.expectEqual(Keepalive.Action.none, k.tick(31 * s));
    try t.expectEqual(Keepalive.Action.none, k.tick(59 * s));
    try t.expectEqual(Keepalive.Action.fail, k.tick(60 * s));
    // Any frame resets it, so a busy connection never pings.
    var b: Keepalive = .{ .last_rx = 0 };
    for (1..100) |i| {
        b.received(@intCast(i * 10 * s));
        try t.expectEqual(Keepalive.Action.none, b.tick(@intCast(i * 10 * s + 5 * s)));
    }
    var c: Keepalive = .{ .last_rx = 0 };
    try t.expectEqual(Keepalive.Action.ping, c.tick(30 * s));
    c.received(40 * s);
    try t.expectEqual(Keepalive.Action.none, c.tick(65 * s));
    try t.expectEqual(Keepalive.Action.ping, c.tick(70 * s));
}

test "NO_PROXY matching" {
    try t.expect(noProxy("*", "anything"));
    try t.expect(noProxy("localhost,127.0.0.1", "127.0.0.1"));
    try t.expect(noProxy(" example.com ", "EXAMPLE.com"));
    try t.expect(noProxy("example.com", "fs.example.com"));
    try t.expect(!noProxy("example.com", "badexample.com"));
    try t.expect(noProxy(".example.com", "fs.example.com"));
    try t.expect(noProxy(".example.com", "example.com"));
    try t.expect(noProxy("*.example.com", "a.b.example.com"));
    try t.expect(!noProxy("*.example.com", "example.org"));
    try t.expect(noProxy("fs.example:8080", "fs.example"));
    try t.expect(noProxy("::1", "::1"));
    try t.expect(noProxy("[::1]", "::1"));
    try t.expect(!noProxy("", "x"));

    const c: ProxyConfig = .{ .http = "http://p:3128", .https = "", .no_proxy = "direct.example" };
    try t.expectEqualStrings("http://p:3128", c.pick(try Url.parse("ws://fs/9p")).?);
    try t.expectEqual(@as(?[]const u8, null), c.pick(try Url.parse("wss://fs/9p")));
    try t.expectEqual(@as(?[]const u8, null), c.pick(try Url.parse("ws://direct.example/9p")));
}

test "proxy URLs and CONNECT" {
    const p = try Proxy.parse("http://us%40r:p%3Ass@proxy.corp:3128/");
    try t.expectEqualStrings("proxy.corp", p.host);
    try t.expectEqual(@as(u16, 3128), p.port);
    try t.expectEqualStrings("proxy.corp:3128", p.shown_host);
    try t.expectEqual(@as(u16, 80), (try Proxy.parse("http://proxy")).port);
    try t.expectError(error.BadProxy, Proxy.parse("socks5://proxy:1080"));
    var out: [256]u8 = undefined;
    var w: Writer = .fixed(&out);
    try writeConnect(&w, p, try Url.parse("wss://fs.example/9p"));
    // us@r:p:ss
    try t.expectEqualStrings("CONNECT fs.example:443 HTTP/1.1\r\nHost: fs.example:443\r\nProxy-Authorization: Basic dXNAcjpwOnNz\r\n\r\n", w.buffered());
    var r: Reader = .fixed("HTTP/1.1 200 Connection established\r\n\r\n");
    var resp: Response = .{};
    try readConnect(&r, &resp);
    var r2: Reader = .fixed("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic\r\n\r\n");
    try t.expectError(error.Status, readConnect(&r2, &resp));
    try t.expectEqual(@as(u16, 407), resp.status);
    try t.expectEqualStrings("Proxy Authentication Required", resp.reason);
}

test "a listener's checks: path, method, upgrade, Origin, token, and subprotocol" {
    const req = struct {
        fn of(text: []const u8, q: *Request) !void {
            var r: Reader = .fixed(text);
            try readRequest(&r, q);
        }
    };
    const up = "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n";
    const pol: ServerPolicy = .{ .path = "/9p", .token = "s3cret t", .origins = &.{"https://app.example"} };
    var q: Request = .{};
    try req.of("GET /9p HTTP/1.1\r\n" ++ up ++ "Authorization: Bearer s3cret t\r\nSec-WebSocket-Protocol: 9p\r\n\r\n", &q);
    try t.expectEqualStrings("9p", checkUpgrade(&q, pol).accept.?);
    q = .{};
    try req.of("GET /9p?a=1&token=s3cret%20t HTTP/1.1\r\n" ++ up ++ "Origin: https://app.example\r\n\r\n", &q);
    try t.expect(checkUpgrade(&q, pol).accept == null);
    q = .{};
    try req.of("GET /9p?token=wrong HTTP/1.1\r\n" ++ up ++ "\r\n", &q);
    try t.expectEqual(@as(u16, 401), checkUpgrade(&q, pol).refuse);
    q = .{};
    try req.of("GET /9p HTTP/1.1\r\n" ++ up ++ "Origin: https://evil.example\r\nAuthorization: Bearer s3cret t\r\n\r\n", &q);
    try t.expectEqual(@as(u16, 403), checkUpgrade(&q, pol).refuse);
    q = .{};
    try req.of("GET /other HTTP/1.1\r\n" ++ up ++ "\r\n", &q);
    try t.expectEqual(@as(u16, 404), checkUpgrade(&q, pol).refuse);
    q = .{};
    try req.of("POST /9p HTTP/1.1\r\n" ++ up ++ "\r\n", &q);
    try t.expectEqual(@as(u16, 405), checkUpgrade(&q, pol).refuse);
    q = .{};
    try req.of("GET /9p HTTP/1.1\r\nHost: x\r\n\r\n", &q);
    try t.expectEqual(@as(u16, 426), checkUpgrade(&q, pol).refuse);
    q = .{};
    try req.of("GET /9p HTTP/1.1\r\n" ++ up ++ "Authorization: Bearer s3cret t\r\nSec-WebSocket-Protocol: chat\r\n\r\n", &q);
    try t.expectEqual(@as(u16, 400), checkUpgrade(&q, pol).refuse);
    // Any origin, and no token required.
    q = .{};
    try req.of("GET / HTTP/1.1\r\n" ++ up ++ "Origin: https://any.example\r\n\r\n", &q);
    try t.expect(checkUpgrade(&q, .{ .origins = &.{"*"} }) == .accept);
    // No Origin is a client that isn't a browser.
    q = .{};
    try req.of("GET / HTTP/1.1\r\n" ++ up ++ "\r\n", &q);
    try t.expect(checkUpgrade(&q, .{}) == .accept);
    q = .{};
    try req.of("GET / HTTP/1.1\r\n" ++ up ++ "Origin: http://localhost:8000\r\n\r\n", &q);
    try t.expectEqual(@as(u16, 403), checkUpgrade(&q, .{}).refuse);
}
