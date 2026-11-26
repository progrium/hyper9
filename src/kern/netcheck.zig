//! src/kern/netcheck.c in Zig (design/kernel-port.md): the C side of
//! devip's sandbox hooks (src/kern/netcheck.h). The policy itself, and
//! the machine's resolved-name table, are in src/kern.zig. A close
//! translation: the same functions in the same order, with error unions
//! for the C's error labels. The exported functions keep the C's
//! contracts: h9_net_redirect raises for devip, and the rest return
//! their status.
//!
//! devip's socket calls raise, so they're called through
//! src/kern/devshim.c.

const std = @import("std");
const port = @import("port.zig");
const dev = @import("dev.zig");
const c = port.c;
const Error = port.Error;

const IPaddrlen = 16;

// devip.h's protocols.
const S_TCP = 0;
const S_UDP = 1;

// netcheck.h's operations.
const H9_NETCONNECT = 0;
const H9_NETANNOUNCE = 1;

// src/kern.zig: the policy and the resolver.
extern fn h9_net_check(op: c_int, proto: c_int, addr: *[IPaddrlen]u8, port: c_int) c_int;
extern fn h9_dns_target(proto: c_int, addr: *[IPaddrlen]u8, port: *c_int) c_int;
extern fn h9_dns_register(proto: c_int, lport: c_int, orig: *[IPaddrlen]u8, oport: c_int) void;
extern fn h9_dns_peer(proto: c_int, lport: c_int, addr: *[IPaddrlen]u8, port: *u16) c_int;
extern fn h9_dns_self(proto: c_int, addr: *[IPaddrlen]u8, port: c_int) c_int;

// src/kern/devshim.c: devip's so_getsockname and so_bind, and
// hostsock's h9so_socket, which raise; 0, or -1 with the error string set.
extern fn h9_shim_so_getsockname(fd: c_int, laddr: *[IPaddrlen]u8, lport: *u16) c_int;
extern fn h9_shim_so_bind(fd: c_int, su: c_int, port: u16, addr: *[IPaddrlen]u8) c_int;
extern fn h9_shim_so_socket(proto: c_int, addr: *[IPaddrlen]u8, opts: ?*c_int, r: *c_int) c_int;

fn so_getsockname(sfd: c_int, laddr: *[IPaddrlen]u8, lport: *u16) Error!void {
    try dev.caught(h9_shim_so_getsockname(sfd, laddr, lport));
}

fn so_bind(sfd: c_int, su: c_int, p: u16, addr: *[IPaddrlen]u8) Error!void {
    try dev.caught(h9_shim_so_bind(sfd, su, p, addr));
}

fn h9so_socket(proto: c_int, addr: *[IPaddrlen]u8, opts: ?*c_int) Error!c_int {
    var r: c_int = -1;
    try dev.caught(h9_shim_so_socket(proto, addr, opts, &r));
    return r;
}

fn h9_net_proto(name: [*:0]const u8) callconv(.c) c_int {
    if (dev.streq(name, "tcp"))
        return S_TCP;
    if (dev.streq(name, "udp"))
        return S_UDP;
    return -1;
}

/// The host port of sfd, bound to addr (the resolver's loopback) if it has
/// none. A socket that isn't bound has port 0 on POSIX hosts, but on
/// Windows getsockname fails on it (WSAEINVAL), so a failure is port 0 too.
fn dnslport(sfd: c_int, addr: *[IPaddrlen]u8) Error!c_int {
    var laddr: [IPaddrlen]u8 = undefined;
    var lport: u16 = 0;
    so_getsockname(sfd, &laddr, &lport) catch {
        lport = 0;
    };
    if (lport == 0) {
        try so_bind(sfd, 0, 0, addr);
        try so_getsockname(sfd, &laddr, &lport);
    }
    return lport;
}

// The host sockets of probe-only UDP conversations (design/linux-dns.md,
// Updates). getaddrinfo ranks its answers by connecting a UDP socket to
// each address, which sends nothing, and reading its source address, so
// a connect to an address recorded for an allowed name is made on the
// host whatever its port, and its socket is marked here: devip's write
// and the Linux layer's send refuse to send on it. Host sockets are the
// process's, so one table serves every machine. The mark is set or
// cleared at each connect, and cleared by h9so_close before the socket
// is closed, so a later socket with the same number starts unmarked.

const Nprobe = 1024;

var probes: struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    fd: [Nprobe]c_int = undefined,
    n: usize = 0,
} = .{};

fn probeslot(sfd: c_int) ?usize {
    for (probes.fd[0..probes.n], 0..) |f, i|
        if (f == sfd)
            return i;
    return null;
}

/// Marks or unmarks sfd; -1 if there's no room to mark it.
fn probemark(sfd: c_int, on: bool) c_int {
    var r: c_int = 0;
    c.lock(&probes.lk);
    const i = probeslot(sfd);
    if (on and i == null) {
        if (probes.n < Nprobe) {
            probes.fd[probes.n] = sfd;
            probes.n += 1;
        } else r = -1;
    } else if (!on and i != null) {
        probes.n -= 1;
        probes.fd[i.?] = probes.fd[probes.n];
    }
    c.unlock(&probes.lk);
    return r;
}

fn h9_net_send(sfd: c_int) callconv(.c) c_int {
    if (sfd == -1)
        return 0;
    c.lock(&probes.lk);
    const i = probeslot(sfd);
    c.unlock(&probes.lk);
    return if (i == null) 0 else -1;
}

fn h9_net_closed(sfd: c_int) callconv(.c) void {
    if (sfd != -1)
        _ = probemark(sfd, false);
}

/// A UDP connect that isn't redirected: marks its socket probe-only if
/// h9_net_check allowed it only as a probe, making the socket first so
/// there's one to mark, and unmarks it otherwise, since a conversation
/// may connect again. -1 refuses the connect.
fn probe(proto: c_int, addr: *[IPaddrlen]u8, p: c_int, sfd: *c_int, opts: ?*c_int) Error!c_int {
    if (proto != S_UDP)
        return 0;
    if (h9_net_check(H9_NETCONNECT, proto, addr, p) <= 0) {
        if (sfd.* != -1)
            _ = probemark(sfd.*, false);
        return 0;
    }
    if (sfd.* == -1)
        sfd.* = try h9so_socket(proto, addr, opts);
    return probemark(sfd.*, true);
}

fn redirect(proto: c_int, addr: *[IPaddrlen]u8, p: *c_int, sfd: *c_int, opts: ?*c_int) Error!c_int {
    var orig: [IPaddrlen]u8 = addr.*;
    const oport = p.*;
    const r = h9_dns_target(proto, addr, p);
    if (r == 0)
        return probe(proto, addr, p.*, sfd, opts);
    if (r < 0)
        return r;
    // Made for the resolver's address, so it's an IPv4 socket whatever the guest dialled.
    if (sfd.* == -1)
        sfd.* = try h9so_socket(proto, addr, opts);
    _ = probemark(sfd.*, false);
    h9_dns_register(proto, try dnslport(sfd.*, addr), &orig, oport);
    return 1;
}

/// For devip's connect, which it raises from.
fn h9_net_redirect(proto: c_int, addr: *[IPaddrlen]u8, p: *c_int, sfd: *c_int, opts: ?*c_int) callconv(.c) c_int {
    return redirect(proto, addr, p, sfd, opts) catch |e| port.raise(e);
}

fn h9_net_redirectto(proto: c_int, sfd: c_int, addr: *[IPaddrlen]u8, p: *c_int) callconv(.c) c_int {
    var orig: [IPaddrlen]u8 = addr.*;
    const oport = p.*;
    const r = h9_dns_target(proto, addr, p);
    if (r <= 0)
        return r;
    const lport = dnslport(sfd, addr) catch return -1;
    h9_dns_register(proto, lport, &orig, oport);
    return 1;
}

fn h9_net_unredirect(proto: c_int, sfd: c_int, addr: *[IPaddrlen]u8, p: *u16) callconv(.c) void {
    var laddr: [IPaddrlen]u8 = undefined;
    var lport: u16 = 0;
    if (h9_dns_self(proto, addr, p.*) == 0)
        return;
    so_getsockname(sfd, &laddr, &lport) catch return;
    _ = h9_dns_peer(proto, lport, addr, p);
}

pub fn exportC() void {
    @export(&h9_net_proto, .{ .name = "h9_net_proto" });
    @export(&h9_net_send, .{ .name = "h9_net_send" });
    @export(&h9_net_closed, .{ .name = "h9_net_closed" });
    @export(&h9_net_redirect, .{ .name = "h9_net_redirect" });
    @export(&h9_net_redirectto, .{ .name = "h9_net_redirectto" });
    @export(&h9_net_unredirect, .{ .name = "h9_net_unredirect" });
}

// Cases (zig build kern-test): the probe table, which needs no devip.

const testing = std.testing;

test "a probe-only socket can't send until it's unmarked or closed [kernel-port]" {
    try testing.expectEqual(0, h9_net_send(-1));
    try testing.expectEqual(0, h9_net_send(1001));
    try testing.expectEqual(0, probemark(1001, true));
    try testing.expectEqual(0, probemark(1002, true));
    try testing.expectEqual(-1, h9_net_send(1001));
    try testing.expectEqual(0, probemark(1001, true)); // marked once
    try testing.expectEqual(0, probemark(1001, false));
    try testing.expectEqual(0, h9_net_send(1001));
    try testing.expectEqual(-1, h9_net_send(1002));
    h9_net_closed(1002);
    try testing.expectEqual(0, h9_net_send(1002));
    try testing.expectEqual(0, probes.n);
}

test "the probe table refuses a mark when it's full [kernel-port]" {
    var i: c_int = 0;
    while (i < Nprobe) : (i += 1)
        try testing.expectEqual(0, probemark(5000 + i, true));
    try testing.expectEqual(-1, probemark(9999, true));
    i = 0;
    while (i < Nprobe) : (i += 1)
        h9_net_closed(5000 + i);
    try testing.expectEqual(0, probes.n);
    try testing.expectEqual(0, h9_net_proto("udp") - S_UDP);
    try testing.expectEqual(-1, h9_net_proto("il"));
}
