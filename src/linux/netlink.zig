//! NETLINK_ROUTE for the Linux personality (design/0050-linux-net.md):
//! the dumps that list interfaces and their addresses, which Go's
//! net.Interfaces and net.InterfaceAddrs and musl's getifaddrs make.
//! Everything else is answered with EOPNOTSUPP. The interfaces are the
//! host's (src/kern/hostsock.h's h9so_ifaddrs), or loopback alone where
//! the host can't list them or the machine has no network.

const std = @import("std");

pub const AF_NETLINK = 16;
pub const NETLINK_ROUTE = 0;

const NLMSG_ERROR = 2;
const NLMSG_DONE = 3;
const RTM_NEWLINK = 16;
const RTM_GETLINK = 18;
const RTM_NEWADDR = 20;
const RTM_GETADDR = 22;
const NLM_F_MULTI = 2;
const NLM_F_DUMP = 0x300;

const AF_UNSPEC = 0;
const AF_INET = 2;
const AF_INET6 = 10;

const IFF_UP = 0x1;
const IFF_LOOPBACK = 0x8;
const IFF_RUNNING = 0x40;
const IFF_MULTICAST = 0x1000;
const ARPHRD_ETHER = 1;
const ARPHRD_LOOPBACK = 772;

const IFLA_ADDRESS = 1;
const IFLA_BROADCAST = 2;
const IFLA_IFNAME = 3;
const IFLA_MTU = 4;
const IFA_ADDRESS = 1;
const IFA_LOCAL = 2;
const IFA_LABEL = 3;
const IFA_F_PERMANENT = 0x80;
const RT_SCOPE_UNIVERSE = 0;
const RT_SCOPE_LINK = 253;
const RT_SCOPE_HOST = 254;

const EOPNOTSUPP = 95;

/// An interface address, as the host reported it (kc.IfAddr's fields).
pub const Addr = struct {
    name: []const u8,
    index: u32,
    up: bool,
    loopback: bool,
    mtu: u32,
    /// 16 bytes, IPv4 mapped.
    ip: [16]u8,
    prefix: u8,
};

/// Loopback, for a host that can't list its interfaces.
pub fn loopback(v6: bool, buf: *[2]Addr) []const Addr {
    var v4: [16]u8 = @splat(0);
    v4[10] = 0xff;
    v4[11] = 0xff;
    v4[12] = 127;
    v4[15] = 1;
    var one: [16]u8 = @splat(0);
    one[15] = 1;
    buf[0] = .{ .name = "lo", .index = 1, .up = true, .loopback = true, .mtu = 65536, .ip = v4, .prefix = 8 };
    buf[1] = .{ .name = "lo", .index = 1, .up = true, .loopback = true, .mtu = 65536, .ip = one, .prefix = 128 };
    return buf[0 .. @as(usize, 1) + @intFromBool(v6)];
}

pub fn isV4(ip: *const [16]u8) bool {
    return std.mem.allEqual(u8, ip[0..10], 0) and ip[10] == 0xff and ip[11] == 0xff;
}

/// Answers the requests in `req`, a send's bytes, into `out` as whole
/// messages, each to be read as one datagram. `pid` is the socket's
/// port id, which replies carry.
pub fn answer(gpa: std.mem.Allocator, req: []const u8, pid: u32, addrs: []const Addr, out: *std.ArrayList([]u8)) !void {
    var off: usize = 0;
    while (off + 16 <= req.len) {
        const len = std.mem.readInt(u32, req[off..][0..4], .little);
        if (len < 16 or off + len > req.len) break;
        const ty = std.mem.readInt(u16, req[off + 4 ..][0..2], .little);
        const flags = std.mem.readInt(u16, req[off + 6 ..][0..2], .little);
        const seq = std.mem.readInt(u32, req[off + 8 ..][0..4], .little);
        const body = req[off + 16 .. off + len];
        // rtgenmsg, ifinfomsg and ifaddrmsg all start with the family.
        const family: u8 = if (body.len > 0) body[0] else AF_UNSPEC;
        const dump = flags & NLM_F_DUMP == NLM_F_DUMP;
        if (ty == RTM_GETLINK and dump) {
            try links(gpa, seq, pid, addrs, out);
            try done(gpa, seq, pid, out);
        } else if (ty == RTM_GETADDR and dump) {
            try addresses(gpa, seq, pid, family, addrs, out);
            try done(gpa, seq, pid, out);
        } else {
            // NLMSG_ERROR: the errno, then the request's header.
            var m = Msg.init(NLMSG_ERROR, 0, seq, pid);
            m.put(i32, -EOPNOTSUPP);
            m.bytes(req[off..][0..16]);
            try out.append(gpa, try m.done(gpa));
        }
        off += std.mem.alignForward(usize, len, 4);
    }
}

fn links(gpa: std.mem.Allocator, seq: u32, pid: u32, addrs: []const Addr, out: *std.ArrayList([]u8)) !void {
    for (addrs, 0..) |a, i| {
        // One link per index: the first address seen names it.
        const seen = for (addrs[0..i]) |b| (if (b.index == a.index) break true) else false;
        if (seen) continue;
        var m = Msg.init(RTM_NEWLINK, NLM_F_MULTI, seq, pid);
        // ifinfomsg: family, pad, type, index, flags, change.
        m.put(u8, AF_UNSPEC);
        m.put(u8, 0);
        m.put(u16, if (a.loopback) ARPHRD_LOOPBACK else ARPHRD_ETHER);
        m.put(i32, @intCast(a.index));
        var fl: u32 = if (a.loopback) IFF_LOOPBACK else IFF_MULTICAST;
        if (a.up) fl |= IFF_UP | IFF_RUNNING;
        m.put(u32, fl);
        m.put(u32, 0);
        const zero: [6]u8 = @splat(0);
        m.attr(IFLA_ADDRESS, &zero);
        if (!a.loopback) m.attr(IFLA_BROADCAST, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
        var nb: [17]u8 = @splat(0);
        @memcpy(nb[0..a.name.len], a.name);
        m.attr(IFLA_IFNAME, nb[0 .. a.name.len + 1]);
        var mtu: [4]u8 = undefined;
        std.mem.writeInt(u32, &mtu, a.mtu, .little);
        m.attr(IFLA_MTU, &mtu);
        try out.append(gpa, try m.done(gpa));
    }
}

fn addresses(gpa: std.mem.Allocator, seq: u32, pid: u32, family: u8, addrs: []const Addr, out: *std.ArrayList([]u8)) !void {
    for (addrs) |a| {
        const v4 = isV4(&a.ip);
        const fam: u8 = if (v4) AF_INET else AF_INET6;
        if (family != AF_UNSPEC and family != fam) continue;
        var m = Msg.init(RTM_NEWADDR, NLM_F_MULTI, seq, pid);
        // ifaddrmsg: family, prefixlen, flags, scope, index.
        m.put(u8, fam);
        m.put(u8, a.prefix);
        m.put(u8, IFA_F_PERMANENT);
        const link_local = !v4 and a.ip[0] == 0xfe and a.ip[1] & 0xc0 == 0x80;
        m.put(u8, if (a.loopback) RT_SCOPE_HOST else if (link_local) RT_SCOPE_LINK else RT_SCOPE_UNIVERSE);
        m.put(u32, a.index);
        const ip = if (v4) a.ip[12..16] else a.ip[0..16];
        m.attr(IFA_ADDRESS, ip);
        if (v4) m.attr(IFA_LOCAL, ip);
        var nb: [17]u8 = @splat(0);
        @memcpy(nb[0..a.name.len], a.name);
        m.attr(IFA_LABEL, nb[0 .. a.name.len + 1]);
        try out.append(gpa, try m.done(gpa));
    }
}

fn done(gpa: std.mem.Allocator, seq: u32, pid: u32, out: *std.ArrayList([]u8)) !void {
    var m = Msg.init(NLMSG_DONE, NLM_F_MULTI, seq, pid);
    m.put(i32, 0);
    try out.append(gpa, try m.done(gpa));
}

/// A message being built: the header, then the payload, 4-aligned.
const Msg = struct {
    buf: [256]u8 = @splat(0),
    n: usize = 16,

    fn init(ty: u16, flags: u16, seq: u32, pid: u32) Msg {
        var m: Msg = .{};
        std.mem.writeInt(u16, m.buf[4..6], ty, .little);
        std.mem.writeInt(u16, m.buf[6..8], flags, .little);
        std.mem.writeInt(u32, m.buf[8..12], seq, .little);
        std.mem.writeInt(u32, m.buf[12..16], pid, .little);
        return m;
    }

    fn put(m: *Msg, comptime T: type, v: T) void {
        std.mem.writeInt(T, m.buf[m.n..][0..@sizeOf(T)], v, .little);
        m.n += @sizeOf(T);
    }

    fn bytes(m: *Msg, b: []const u8) void {
        @memcpy(m.buf[m.n..][0..b.len], b);
        m.n += b.len;
    }

    /// An rtattr: length, type, value, padded to 4.
    fn attr(m: *Msg, ty: u16, v: []const u8) void {
        m.put(u16, @intCast(4 + v.len));
        m.put(u16, ty);
        m.bytes(v);
        m.n = std.mem.alignForward(usize, m.n, 4);
    }

    fn done(m: *Msg, gpa: std.mem.Allocator) ![]u8 {
        std.mem.writeInt(u32, m.buf[0..4], @intCast(m.n), .little);
        return gpa.dupe(u8, m.buf[0..m.n]);
    }
};

test "a link and address dump of loopback ends with DONE, carrying seq and pid" {
    const gpa = std.testing.allocator;
    var lb: [2]Addr = undefined;
    const addrs = loopback(true, &lb);
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |m| gpa.free(m);
        out.deinit(gpa);
    }
    // Go's NetlinkRIB request: nlmsghdr then a one-byte rtgenmsg.
    var req: [20]u8 = @splat(0);
    std.mem.writeInt(u32, req[0..4], 17, .little);
    std.mem.writeInt(u16, req[4..6], RTM_GETADDR, .little);
    std.mem.writeInt(u16, req[6..8], 0x301, .little);
    std.mem.writeInt(u32, req[8..12], 1, .little);
    try answer(gpa, &req, 42, addrs, &out);
    try std.testing.expectEqual(3, out.items.len);
    for (out.items) |m| {
        try std.testing.expectEqual(m.len, std.mem.readInt(u32, m[0..4], .little));
        try std.testing.expectEqual(1, std.mem.readInt(u32, m[8..12], .little));
        try std.testing.expectEqual(42, std.mem.readInt(u32, m[12..16], .little));
    }
    try std.testing.expectEqual(RTM_NEWADDR, std.mem.readInt(u16, out.items[0][4..6], .little));
    try std.testing.expectEqual(AF_INET, out.items[0][16]);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, out.items[0][28..32]);
    try std.testing.expectEqual(NLMSG_DONE, std.mem.readInt(u16, out.items[2][4..6], .little));

    // AF_INET only, and a link dump: one link for lo.
    for (out.items) |m| gpa.free(m);
    out.clearRetainingCapacity();
    req[16] = AF_INET;
    try answer(gpa, &req, 42, addrs, &out);
    try std.testing.expectEqual(2, out.items.len);
    for (out.items) |m| gpa.free(m);
    out.clearRetainingCapacity();
    std.mem.writeInt(u16, req[4..6], RTM_GETLINK, .little);
    try answer(gpa, &req, 42, addrs, &out);
    try std.testing.expectEqual(2, out.items.len);
    try std.testing.expectEqual(RTM_NEWLINK, std.mem.readInt(u16, out.items[0][4..6], .little));
    try std.testing.expect(std.mem.indexOf(u8, out.items[0], "lo\x00") != null);

    // Anything else is EOPNOTSUPP.
    for (out.items) |m| gpa.free(m);
    out.clearRetainingCapacity();
    std.mem.writeInt(u16, req[4..6], 24, .little); // RTM_NEWROUTE
    std.mem.writeInt(u16, req[6..8], 5, .little);
    try answer(gpa, &req, 42, addrs, &out);
    try std.testing.expectEqual(1, out.items.len);
    try std.testing.expectEqual(NLMSG_ERROR, std.mem.readInt(u16, out.items[0][4..6], .little));
    try std.testing.expectEqual(-EOPNOTSUPP, std.mem.readInt(i32, out.items[0][16..20], .little));
}
