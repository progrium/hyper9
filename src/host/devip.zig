//! The host network device, `#I` (design/host-handles.md): drawterm's
//! devip.c, ported to Zig as a native device, with h9's changes to it. A
//! close translation: the same functions in the same order, with error
//! unions in place of C's error labels.
//!
//! A conversation is a host socket, made and used through the host's
//! socket layer (src/host/ipsock-posix.c, ipsock-win32.c, and
//! ipsock-wasm.c, drawterm's so_ calls, and src/host/hostsock-*.c, h9's),
//! which raise as drawterm's C does, so the Zig calls them through
//! dev.zig's `raising`. Every dial, announce, and name lookup asks the
//! machine's policy first (src/kern/netcheck.zig and src/kern.zig).

const std = @import("std");
const kern = @import("kern");

const port = kern;
const c = kern.c;
const dev = kern.dev;
const chan = kern.chan;
const sysfile = kern.sysfile;
const linuxnet = kern.linuxnet;
const Error = port.Error;
const Chan = c.Chan;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Qid = c.Qid;
const Walkqid = c.Walkqid;

const IPaddrlen = 16;
const KNAMELEN = c.KNAMELEN;

// devip.h's protocols.
const S_TCP: c_int = 0;
const S_UDP: c_int = 1;

// src/host/hostsock.h's H9nopt: a conversation's socket options.
const Nopt = 9;

// netcheck.h's operations.
const H9_NETCONNECT: c_int = 0;
const H9_NETANNOUNCE: c_int = 1;

// The host's socket layer, which raises (src/host/ipsock-*.c).
extern fn parseip(to: [*c]u8, from: [*c]u8) c_longlong; // libip
extern fn osipinit() void;
extern fn so_connect(fd: c_int, raddr: [*c]u8, rport: c_ushort) void;
extern fn so_getsockname(fd: c_int, laddr: [*c]u8, lport: [*c]c_ushort) void;
extern fn so_bind(fd: c_int, su: c_int, port: c_ushort, addr: [*c]u8) void;
extern fn so_listen(fd: c_int) void;
extern fn so_send(fd: c_int, a: ?*anyopaque, n: c_int, flags: c_int) c_int;
extern fn so_recv(fd: c_int, a: ?*anyopaque, n: c_int, flags: c_int) c_int;
extern fn so_accept(fd: c_int, raddr: [*c]u8, rport: [*c]c_ushort) c_int;
extern fn so_getservbyname(name: [*c]u8, proto: [*c]u8, buf: [*c]u8) c_int;
extern fn so_gethostbyname(name: [*c]u8, ips: [*c][*c]u8, n: c_int) c_int;
// src/host/hostsock-*.c, which raise too.
extern fn h9so_socket(stype: c_int, addr: [*c]u8, opts: [*c]c_int) c_int;
extern fn h9so_connect_nb(fd: c_int, raddr: [*c]u8, rport: c_ushort) c_int;
extern fn h9so_shutdown(fd: c_int, how: [*c]u8) void;
extern fn h9so_close(fd: c_int) void;
extern fn h9so_setopt(fd: c_int, opts: [*c]c_int, name: [*c]u8, val: c_int) void;
// The policy (src/kern/netcheck.zig and src/kern.zig), which doesn't raise.
extern fn h9_net_check(op: c_int, proto: c_int, addr: [*c]u8, port: c_int) c_int;
extern fn h9_net_lookup(proto: c_int, name: [*c]u8, port: c_int) c_int;
extern fn h9_net_resolved(proto: c_int, name: [*c]u8, port: c_int, addrs: [*c][IPaddrlen]u8, n: c_int) void;
extern fn h9_net_proto(name: [*c]u8) c_int;
extern fn h9_net_redirect(proto: c_int, addr: [*c]u8, port: *c_int, sfd: *c_int, opts: [*c]c_int) c_int;
extern fn h9_net_send(sfd: c_int) c_int;

const Qtopdir = 1; // top level directory
const Qtopbase = 2;
const Qcs = Qtopbase;
const Qprotodir = 3; // directory for a protocol
const Qprotobase = 4;
const Qclone = Qprotobase;
const Qconvdir = 5; // directory for a conversation
const Qconvbase = 6;
const Qctl = Qconvbase;
const Qdata = 7;
const Qstatus = 8;
const Qremote = 9;
const Qlocal = 10;
const Qlisten = 11;
const MAXPROTO = 4;

fn TYPE(q: Qid) c_int {
    return @intCast(q.path & 0xf);
}
fn CONV(q: Qid) usize {
    return @intCast((q.path >> 4) & 0xfff);
}
fn PROTO(q: Qid) usize {
    return @intCast((q.path >> 16) & 0xff);
}
fn QID(p: usize, cv: usize, y: c_int) i64 {
    return @intCast((p << 16) | (cv << 4) | @as(usize, @intCast(y)));
}

const DEVDOT = -2;

const Conv = struct {
    x: c_int,
    r: c.Ref,
    sfd: c_int,
    perm: c_int,
    owner: [KNAMELEN]u8,
    state: [*:0]const u8,
    laddr: [IPaddrlen]u8,
    lport: c_ushort,
    raddr: [IPaddrlen]u8,
    rport: c_ushort,
    restricted: c_int,
    ctime: c_uint,
    cerr: [KNAMELEN]u8,
    p: *Proto,
    /// Socket options, applied when sfd is made (src/host/hostsock.h).
    opts: [Nopt]c_int,
};

const Proto = struct {
    l: c.Lock,
    x: usize,
    stype: c_int,
    name: [KNAMELEN]u8,
    nc: usize,
    maxconv: usize,
    conv: [*]?*Conv = undefined,
    qid: Qid,
};

var np: usize = 0;
var proto: [MAXPROTO]Proto = undefined;

const network = "network";

fn cstr(s: []const u8) [*c]u8 {
    return @constCast(s.ptr);
}

fn bprint(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]u8 {
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    w.print(fmt, args) catch {};
    buf[w.end] = 0;
    return buf[0..w.end :0];
}

fn convof(q: Qid) *Conv {
    return proto[PROTO(q)].conv[CONV(q)].?;
}

fn ip3gen(ch: *Chan, i: c_int, dp: *Dir) c_int {
    const cv = convof(ch.qid);
    var q: Qid = undefined;
    dev.mkqid(&q, QID(PROTO(ch.qid), CONV(ch.qid), i), 0, c.QTFILE);
    const own: [*c]u8 = &cv.owner;
    switch (i) {
        Qctl => dev.devdir(ch, q, cstr("ctl"), 0, own, cv.perm, dp),
        Qdata => dev.devdir(ch, q, cstr("data"), 0, own, cv.perm, dp),
        Qlisten => dev.devdir(ch, q, cstr("listen"), 0, own, cv.perm, dp),
        Qlocal => dev.devdir(ch, q, cstr("local"), 0, own, 0o444, dp),
        Qremote => dev.devdir(ch, q, cstr("remote"), 0, own, 0o444, dp),
        Qstatus => dev.devdir(ch, q, cstr("status"), 0, own, 0o444, dp),
        else => return -1,
    }
    dp.mtime = cv.ctime;
    return 1;
}

fn ip2gen(ch: *Chan, i: c_int, dp: *Dir) c_int {
    if (i == Qclone) {
        var q: Qid = undefined;
        dev.mkqid(&q, QID(PROTO(ch.qid), 0, Qclone), 0, c.QTFILE);
        dev.devdir(ch, q, cstr("clone"), 0, cstr(network), 0o666, dp);
        return 1;
    }
    return -1;
}

fn ip1gen(ch: *Chan, i: c_int, dp: *Dir) c_int {
    if (i != Qcs) return -1;
    var q: Qid = undefined;
    dev.mkqid(&q, QID(0, 0, i), 0, c.QTFILE);
    dev.devdir(ch, q, cstr("cs"), 0, cstr(network), 0o664, dp);
    return 1;
}

fn topdir(ch: *Chan, dp: *Dir) void {
    var q: Qid = undefined;
    dev.mkqid(&q, QID(0, 0, Qtopdir), 0, c.QTDIR);
    const name = bprint(&port.up().genbuf, "#I{d}", .{ch.dev});
    dev.devdir(ch, q, name.ptr, 0, cstr(network), 0o555, dp);
}

fn protodir(ch: *Chan, s: usize, dp: *Dir) void {
    var q: Qid = undefined;
    dev.mkqid(&q, QID(s, 0, Qprotodir), 0, c.QTDIR);
    dev.devdir(ch, q, &proto[s].name, 0, cstr(network), 0o555, dp);
}

fn convdir(ch: *Chan, s: usize, dp: *Dir) void {
    const cv = proto[PROTO(ch.qid)].conv[s].?;
    const name = bprint(&port.up().genbuf, "{d}", .{s});
    var q: Qid = undefined;
    dev.mkqid(&q, QID(PROTO(ch.qid), s, Qconvdir), 0, c.QTDIR);
    dev.devdir(ch, q, name.ptr, 0, &cv.owner, 0o555, dp);
    dp.mtime = cv.ctime;
}

fn ipgen(ch_: [*c]Chan, name: [*c]u8, tab: [*c]Dirtab, ntab: c_int, s_: c_int, dp_: [*c]Dir) callconv(.c) c_int {
    _ = .{ name, tab, ntab };
    const ch: *Chan = ch_;
    const dp: *Dir = dp_;
    const s = s_;
    switch (TYPE(ch.qid)) {
        Qtopdir => {
            if (s == c.DEVDOTDOT or s == DEVDOT) {
                topdir(ch, dp);
                return 1;
            }
            if (s >= 0 and s < np) {
                protodir(ch, @intCast(s), dp);
                return 1;
            }
            return ip1gen(ch, s - @as(c_int, @intCast(np)) + Qtopbase, dp);
        },
        Qcs => return ip1gen(ch, TYPE(ch.qid), dp),
        Qprotodir => {
            if (s == c.DEVDOTDOT) {
                topdir(ch, dp);
                return 1;
            }
            if (s == DEVDOT) {
                protodir(ch, PROTO(ch.qid), dp);
                return 1;
            }
            const nc = proto[PROTO(ch.qid)].nc;
            if (s >= 0 and s < nc) {
                convdir(ch, @intCast(s), dp);
                return 1;
            }
            return ip2gen(ch, s - @as(c_int, @intCast(nc)) + Qprotobase, dp);
        },
        Qclone => return ip2gen(ch, TYPE(ch.qid), dp),
        Qconvdir => {
            if (s == c.DEVDOTDOT) {
                protodir(ch, PROTO(ch.qid), dp);
                return 1;
            }
            if (s == DEVDOT) {
                convdir(ch, CONV(ch.qid), dp);
                return 1;
            }
            return ip3gen(ch, s + Qconvbase, dp);
        },
        Qctl, Qdata, Qlisten, Qlocal, Qremote, Qstatus => return ip3gen(ch, TYPE(ch.qid), dp),
        else => return -1,
    }
}

fn newproto(name: []const u8, stype: c_int, maxconv: usize) void {
    if (np >= MAXPROTO) {
        port.print("no %s: increase MAXPROTO", .{cstr(name)});
        return;
    }
    const p = &proto[np];
    p.* = .{ .l = std.mem.zeroes(c.Lock), .x = 0, .stype = 0, .name = @splat(0), .nc = 0, .maxconv = 0, .qid = std.mem.zeroes(Qid) };
    @memcpy(p.name[0..name.len], name);
    p.name[name.len] = 0;
    p.stype = stype;
    p.qid.path = @intCast(QID(np, 0, Qprotodir));
    p.qid.type = c.QTDIR;
    p.x = np;
    np += 1;
    p.maxconv = maxconv;
    p.conv = @ptrCast(@alignCast(port.malloc(@sizeOf(?*Conv) * (maxconv + 1)) orelse port.kpanic("no memory", .{})));
}

extern fn eipfmt(f: ?*c.Fmt) c_int;

fn ipinit() void {
    osipinit();
    // 10 and 30 were too few for a Linux program's connection pool.
    newproto("udp", S_UDP, 1024);
    newproto("tcp", S_TCP, 4096);
    _ = c.fmtinstall('I', @ptrCast(&eipfmt));
    _ = c.fmtinstall('E', @ptrCast(&eipfmt));
}

fn ipattach(spec: [*:0]const u8) Error!*Chan {
    const ch = dev.devattach('I', spec);
    ch.qid.path = @intCast(QID(0, 0, Qtopdir));
    ch.qid.type = c.QTDIR;
    ch.qid.vers = 0;
    return ch;
}

fn ipwalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, null, 0, &ipgen);
}

fn ipstat(ch: *Chan, dp: [*]u8, n: c_int) Error!c_int {
    if (ch.qid.type == c.QTDIR) {
        var d: Dir = undefined;
        _ = ipgen(ch, null, null, 0, DEVDOT, &d);
        const k: c_int = @intCast(c.convD2M(&d, dp, @intCast(n)));
        if (k == 0) return port.kerror(&port.Ebadarg);
        return k;
    }
    return dev.devstat(ch, dp, n, null, 0, &ipgen);
}

fn upuser() [*:0]const u8 {
    return @ptrCast(&port.up().user);
}

fn ipopen(ch: *Chan, omode_: c_int) Error!*Chan {
    const omode = omode_ & 3;
    const perm: c_int = switch (omode) {
        c.OREAD => 4,
        c.OWRITE => 2,
        c.ORDWR => 6,
        else => 0,
    };
    switch (TYPE(ch.qid)) {
        Qtopdir, Qprotodir, Qconvdir, Qstatus, Qremote, Qlocal => {
            if (omode != c.OREAD) return port.kerror(&port.Eperm);
        },
        Qclone => {
            const p = &proto[PROTO(ch.qid)];
            const cv = (try protoclone(p, upuser(), -1)) orelse return port.kerror(&port.Enodev);
            ch.qid.path = @intCast(QID(p.x, @intCast(cv.x), Qctl));
            ch.qid.vers = 0;
        },
        Qdata, Qctl => {
            const p = &proto[PROTO(ch.qid)];
            c.lock(&p.l);
            const cv = p.conv[CONV(ch.qid)].?;
            c.lock(&cv.r.lk);
            if ((perm & (cv.perm >> 6)) != perm) {
                if (!dev.streq(upuser(), @ptrCast(&cv.owner)) or (perm & cv.perm) != perm) {
                    c.unlock(&cv.r.lk);
                    c.unlock(&p.l);
                    return port.kerror(&port.Eperm);
                }
            }
            cv.r.ref += 1;
            if (cv.r.ref == 1) {
                @memcpy(&cv.owner, port.up().user[0..KNAMELEN]);
                cv.perm = 0o660;
            }
            c.unlock(&cv.r.lk);
            c.unlock(&p.l);
        },
        Qlisten => {
            const p = &proto[PROTO(ch.qid)];
            const lcv = p.conv[CONV(ch.qid)].?;
            var raddr: [IPaddrlen]u8 = undefined;
            var rport: c_ushort = 0;
            const nfd = try dev.raising(&so_accept, .{ lcv.sfd, &raddr, &rport });
            const cv = (protoclone(p, upuser(), nfd) catch |e| {
                h9so_close(nfd);
                return e;
            }) orelse {
                h9so_close(nfd); // closesocket on Windows
                return port.kerror(&port.Enodev);
            };
            cv.raddr = raddr;
            cv.rport = rport;
            try setladdr(cv);
            cv.state = "Established";
            ch.qid.path = @intCast(QID(p.x, @intCast(cv.x), Qctl));
        },
        else => {},
    }
    ch.mode = @intCast(try sysfile.openmode(@bitCast(omode)));
    ch.flag |= c.COPEN;
    ch.offset = 0;
    return ch;
}

fn ipclose(ch: *Chan) Error!void {
    switch (TYPE(ch.qid)) {
        Qcs => csclose(ch),
        Qdata, Qctl => {
            if (ch.flag & c.COPEN == 0) return;
            const cc = convof(ch.qid);
            if (chan.decref(&cc.r) != 0) return;
            @memcpy(cc.owner[0 .. network.len + 1], network ++ "\x00");
            cc.perm = 0o666;
            cc.state = "Closed";
            cc.laddr = @splat(0);
            cc.raddr = @splat(0);
            cc.lport = 0;
            cc.rport = 0;
            h9so_close(cc.sfd); // closesocket on Windows
            cc.sfd = -1; // not closed twice, nor watched once closed
            cc.opts = @splat(0);
        },
        else => {},
    }
}

fn readstr(off: i64, va: ?*anyopaque, n: c_int, s: [*:0]const u8) c_int {
    return c.readstr(@truncate(@as(u64, @bitCast(off))), @ptrCast(va), @bitCast(n), @constCast(s));
}

/// "%I!%d\n" of addr and port.
fn addrport(buf: *[128]u8, addr: *const [IPaddrlen]u8, p: c_ushort) [*:0]const u8 {
    var ip = addr.*;
    _ = c.snprint(buf, buf.len, @constCast("%I!%d\n"), &ip, @as(c_int, p));
    return @ptrCast(buf);
}

fn ipread(ch: *Chan, a: ?*anyopaque, n: c_int, offset: i64) Error!c_int {
    var buf: [128]u8 = undefined;
    switch (TYPE(ch.qid)) {
        Qcs => return csread(ch, a, n, offset),
        Qprotodir, Qtopdir, Qconvdir => return dev.devdirread(ch, @ptrCast(a.?), n, null, 0, &ipgen),
        Qctl => return readstr(offset, a, n, bprint(&buf, "{d}", .{CONV(ch.qid)})),
        Qremote => {
            const cv = convof(ch.qid);
            return readstr(offset, a, n, addrport(&buf, &cv.raddr, cv.rport));
        },
        Qlocal => {
            const cv = convof(ch.qid);
            return readstr(offset, a, n, addrport(&buf, &cv.laddr, cv.lport));
        },
        Qstatus => {
            const cv = convof(ch.qid);
            const s = bprint(&buf, "{s}/{d} {d} {s} \n", .{ std.mem.sliceTo(&cv.p.name, 0), cv.x, cv.r.ref, cv.state });
            return readstr(offset, a, n, s);
        },
        Qdata => {
            const cv = convof(ch.qid);
            const r = try dev.raising(&so_recv, .{ cv.sfd, a, n, @as(c_int, 0) });
            if (r < 0) {
                c.oserrstr();
                return error.Kernel;
            }
            return r;
        },
        else => return port.kerror(&port.Eperm),
    }
}

fn setladdr(cv: *Conv) Error!void {
    try dev.raising(&so_getsockname, .{ cv.sfd, &cv.laddr, &cv.lport });
}

fn mksocket(cv: *Conv, addr: *[IPaddrlen]u8) Error!void {
    if (cv.sfd == -1) cv.sfd = try dev.raising(&h9so_socket, .{ cv.p.stype, addr, &cv.opts }); // with its options
}

fn setlport(cv: *Conv) Error!void {
    if (cv.restricted == 0 and cv.lport == 0) return;
    try mksocket(cv, &cv.laddr);
    try dev.raising(&so_bind, .{ cv.sfd, cv.restricted, cv.lport, &cv.laddr });
}

fn setladdrport(cv: *Conv, str: [*:0]u8) Error!void {
    var addr: [IPaddrlen]u8 = @splat(0);
    var p: [*:0]u8 = str;
    if (std.mem.indexOfScalar(u8, std.mem.span(str), '!')) |i| {
        str[i] = 0;
        _ = parseip(&addr, str);
        p = str + i + 1;
    }
    const pt: c_int = if (p[0] == '*') 0 else c.atoi(p);
    // Checked before anything is bound.
    if (h9_net_check(H9_NETANNOUNCE, cv.p.stype, &addr, pt) < 0) return port.kerror(&port.Eperm);
    cv.laddr = addr;
    cv.lport = @truncate(@as(c_uint, @bitCast(pt)));
    try setlport(cv);
}

fn setraddrport(cv: *Conv, str: [*:0]u8) Error!void {
    var addr: [IPaddrlen]u8 = undefined;
    const i = std.mem.indexOfScalar(u8, std.mem.span(str), '!') orelse return port.kerror("malformed address");
    str[i] = 0;
    const p = str + i + 1;
    _ = parseip(&addr, str);
    var pt: c_int = c.atoi(p);
    // Checked before a port is bound or the host is dialed.
    if (h9_net_check(H9_NETCONNECT, cv.p.stype, &addr, pt) < 0) return port.kerror(&port.Eperm);
    // Port 53 may go to the machine's resolver instead.
    if (h9_net_redirect(cv.p.stype, &addr, &pt, &cv.sfd, &cv.opts) < 0) return port.kerror(&port.Eperm);
    cv.raddr = addr;
    cv.rport = @truncate(@as(c_uint, @bitCast(pt)));
    if (std.mem.indexOfScalar(u8, std.mem.span(p), '!')) |j| {
        if (dev.streq(p + j, "!r")) cv.restricted = 1;
    }
}

fn ipwrite(ch: *Chan, a: ?*const anyopaque, n_: c_int, offset: i64) Error!c_int {
    var n = n_;
    switch (TYPE(ch.qid)) {
        Qcs => return cswrite(ch, a, n, offset),
        Qctl => {
            const cv = convof(ch.qid);
            var buf: [128]u8 = undefined;
            if (n > buf.len - 1) n = buf.len - 1;
            const k: usize = @intCast(n);
            @memcpy(buf[0..k], @as([*]const u8, @ptrCast(a.?))[0..k]);
            buf[k] = 0;
            var fields: [3][*c]u8 = .{ null, null, null };
            const nf = c.tokenize(&buf, &fields, 3);
            const f0: [*:0]const u8 = if (nf > 0) @ptrCast(fields[0]) else "";
            if (dev.streq(f0, "connect")) {
                switch (nf) {
                    2 => try setraddrport(cv, @ptrCast(fields[1])),
                    3 => {
                        try setraddrport(cv, @ptrCast(fields[1]));
                        cv.lport = @truncate(@as(c_uint, @bitCast(c.atoi(fields[2]))));
                        try setlport(cv);
                    },
                    else => return port.kerror("bad args to connect"),
                }
                try mksocket(cv, &cv.raddr);
                try dev.raising(&so_connect, .{ cv.sfd, &cv.raddr, cv.rport });
                try setladdr(cv);
                cv.state = "Established";
                return n;
            }
            // A connect that doesn't wait (Linux's O_NONBLOCK connect):
            // the conversation reports writable when it completes, and
            // SO_ERROR says how (src/kern/linuxnet.zig).
            if (dev.streq(f0, "nbconnect")) {
                if (nf != 2) return port.kerror("bad args to nbconnect");
                try setraddrport(cv, @ptrCast(fields[1]));
                try mksocket(cv, &cv.raddr);
                if (try dev.raising(&h9so_connect_nb, .{ cv.sfd, &cv.raddr, cv.rport }) == 0)
                    cv.state = "Established"
                else
                    cv.state = "Connecting";
                try setladdr(cv);
                return n;
            }
            // Half-close, served by the host's shutdown.
            if (dev.streq(f0, "shutdown")) {
                if (nf != 2) return port.kerror("bad args to shutdown");
                if (cv.sfd == -1) return port.kerror("not connected");
                try dev.raising(&h9so_shutdown, .{ cv.sfd, fields[1] });
                return n;
            }
            // Socket options, kept for a socket made later.
            if (dev.streq(f0, "sockopt")) {
                if (nf != 3) return port.kerror("bad args to sockopt");
                try dev.raising(&h9so_setopt, .{ cv.sfd, &cv.opts, fields[1], c.atoi(fields[2]) });
                return n;
            }
            if (dev.streq(f0, "announce")) {
                if (nf != 2) return port.kerror("bad args to announce");
                try setladdrport(cv, @ptrCast(fields[1]));
                // Port 0 (any) needs a socket too, and UDP doesn't listen.
                if (cv.sfd == -1) {
                    try mksocket(cv, &cv.laddr);
                    try dev.raising(&so_bind, .{ cv.sfd, @as(c_int, 0), @as(c_ushort, 0), &cv.laddr });
                }
                if (cv.p.stype == S_UDP) {
                    try setladdr(cv);
                    cv.state = "Announced";
                    return n;
                }
                try dev.raising(&so_listen, .{cv.sfd});
                try setladdr(cv); // getsockname after an ephemeral port
                cv.state = "Announced";
                return n;
            }
            if (dev.streq(f0, "bind")) {
                if (nf != 2) return port.kerror("bad args to bind");
                cv.lport = @truncate(@as(c_uint, @bitCast(c.atoi(fields[1]))));
                try setlport(cv);
                return n;
            }
            return port.kerror("bad control message");
        },
        Qdata => {
            const cv = convof(ch.qid);
            // A probe-only connect sends nothing.
            if (h9_net_send(cv.sfd) < 0) return port.kerror(&port.Eperm);
            const r = try dev.raising(&so_send, .{ cv.sfd, @constCast(a), n, @as(c_int, 0) });
            if (r < 0) {
                c.oserrstr();
                return error.Kernel;
            }
            return r;
        },
        else => return port.kerror(&port.Eperm),
    }
}

fn protoclone(p: *Proto, user: [*:0]const u8, nfd: c_int) Error!?*Conv {
    c.lock(&p.l);
    defer c.unlock(&p.l);
    var cv: *Conv = undefined;
    var i: usize = 0;
    while (i < p.maxconv) : (i += 1) {
        if (p.conv[i]) |x| {
            c.lock(&x.r.lk);
            if (x.r.ref == 0) {
                x.r.ref += 1;
                cv = x;
                break;
            }
            c.unlock(&x.r.lk);
        } else {
            const x: *Conv = @ptrCast(@alignCast(port.malloc(@sizeOf(Conv)) orelse return port.kerror(&port.Enomem)));
            c.lock(&x.r.lk);
            x.r.ref = 1;
            x.p = p;
            x.x = @intCast(i);
            p.nc += 1;
            p.conv[i] = x;
            cv = x;
            break;
        }
    }
    if (i >= p.maxconv) return null;

    const u = std.mem.span(user);
    const k = @min(u.len, KNAMELEN - 1);
    @memcpy(cv.owner[0..k], u[0..k]);
    cv.owner[k] = 0;
    cv.perm = 0o660;
    cv.state = "Closed";
    cv.restricted = 0;
    cv.laddr = @splat(0);
    cv.raddr = @splat(0);
    cv.lport = 0;
    cv.rport = 0;
    cv.sfd = nfd;
    cv.ctime = @bitCast(c.seconds());
    c.unlock(&cv.r.lk);
    return cv;
}

fn csclose(ch: *Chan) void {
    c.free(dev.aux(ch).*);
    dev.aux(ch).* = null;
}

fn csread(ch: *Chan, a: ?*anyopaque, n: c_int, offset: i64) Error!c_int {
    const s0: [*:0]const u8 = @ptrCast(dev.aux(ch).* orelse return 0);
    const all = std.mem.span(s0);
    if (offset < 0 or offset >= all.len) return 0;
    const s = all[@intCast(offset)..];
    const e = if (std.mem.indexOfScalar(u8, s, '\n')) |j| j + 1 else s.len;
    const k: usize = @min(e, @as(usize, @intCast(n)));
    @memcpy(@as([*]u8, @ptrCast(a.?))[0..k], s[0..k]);
    return @intCast(k);
}

const Serv = struct { []const u8, c_int };
const services = [_]Serv{
    .{ "cs", 1 },             .{ "echo", 7 },          .{ "discard", 9 },       .{ "systat", 11 },
    .{ "daytime", 13 },       .{ "netstat", 15 },      .{ "chargen", 19 },      .{ "ftp-data", 20 },
    .{ "ftp", 21 },           .{ "ssh", 22 },          .{ "telnet", 23 },       .{ "smtp", 25 },
    .{ "time", 37 },          .{ "whois", 43 },        .{ "dns", 53 },          .{ "domain", 53 },
    .{ "uucp", 64 },          .{ "gopher", 70 },       .{ "rje", 77 },          .{ "finger", 79 },
    .{ "http", 80 },          .{ "link", 87 },         .{ "supdup", 95 },       .{ "hostnames", 101 },
    .{ "iso-tsap", 102 },     .{ "x400", 103 },        .{ "x400-snd", 104 },    .{ "csnet-ns", 105 },
    .{ "pop-2", 109 },        .{ "pop3", 110 },        .{ "portmap", 111 },     .{ "uucp-path", 117 },
    .{ "nntp", 119 },         .{ "netbios", 139 },     .{ "imap4", 143 },       .{ "NeWS", 144 },
    .{ "print-srv", 170 },    .{ "z39.50", 210 },      .{ "fsb", 400 },         .{ "sysmon", 401 },
    .{ "proxy", 402 },        .{ "proxyd", 404 },      .{ "https", 443 },       .{ "cifs", 445 },
    .{ "ssmtp", 465 },        .{ "rexec", 512 },       .{ "login", 513 },       .{ "shell", 514 },
    .{ "printer", 515 },      .{ "courier", 530 },     .{ "cscan", 531 },       .{ "uucp", 540 },
    .{ "snntp", 563 },        .{ "9fs", 564 },         .{ "whoami", 565 },      .{ "guard", 566 },
    .{ "ticket", 567 },       .{ "dlsftp", 666 },      .{ "fmclient", 729 },    .{ "imaps", 993 },
    .{ "pop3s", 995 },        .{ "ingreslock", 1524 }, .{ "pptp", 1723 },       .{ "nfs", 2049 },
    .{ "webster", 2627 },     .{ "weather", 3000 },    .{ "secstore", 5356 },   .{ "Xdisplay", 6000 },
    .{ "styx", 6666 },        .{ "mpeg", 6667 },       .{ "rstyx", 6668 },      .{ "infdb", 6669 },
    .{ "infsigner", 6671 },   .{ "infcsigner", 6672 }, .{ "inflogin", 6673 },   .{ "bandt", 7330 },
    .{ "face", 32000 },       .{ "dhashgate", 11978 }, .{ "exportfs", 17007 },  .{ "rexexec", 17009 },
    .{ "ncpu", 17010 },       .{ "cpu", 17013 },       .{ "rcpu", 17019 },      .{ "t9fs", 17020 },
    .{ "glenglenda2", 17021 }, .{ "glenglenda3", 17022 }, .{ "glenglenda4", 17023 }, .{ "glenglenda5", 17024 },
    .{ "glenglenda6", 17025 }, .{ "glenglenda7", 17026 }, .{ "glenglenda8", 17027 }, .{ "glenglenda9", 17028 },
    .{ "glenglenda10", 17029 }, .{ "flyboy", 17032 },  .{ "dlsftp", 17033 },    .{ "venti", 17034 },
    .{ "wiki", 17035 },       .{ "vica", 17036 },
};

fn lookupport(s: [*:0]u8) Error!c_int {
    var end: [*c]u8 = undefined;
    const i = c.strtol(s, &end, 0);
    if (s[0] != 0 and end[0] == 0) return @truncate(i);
    var buf: [10]u8 = undefined;
    if (try dev.raising(&so_getservbyname, .{ s, cstr("tcp"), &buf }) != -1) return c.atoi(&buf);
    for (services) |t| {
        if (std.mem.eql(u8, std.mem.span(s), t[0])) return t[1];
    }
    return 0;
}

fn cswrite(ch: *Chan, a: ?*const anyopaque, n: c_int, offset: i64) Error!c_int {
    _ = offset;
    const k: usize = @intCast(n);
    const s: [*]u8 = @ptrCast(port.malloc(k + 1) orelse return port.kerror(&port.Enomem));
    defer c.free(s);
    @memcpy(s[0..k], @as([*]const u8, @ptrCast(a.?))[0..k]);
    s[k] = 0;
    var f: [4][*c]u8 = undefined;
    const nf = c.getfields(s, &f, f.len, 0, @constCast("!"));
    if (nf != 3) return port.kerror("can't translate");

    const pt = try lookupport(@ptrCast(f[2]));
    if (pt <= 0) return port.kerror("no translation for port found");
    if (dev.streq(@ptrCast(f[0]), "net")) f[0] = cstr("tcp");
    var ns: [*c]u8 = undefined;
    if (dev.streq(@ptrCast(f[1]), "*")) {
        ns = c.smprint(@constCast("/net/%s/clone %d"), f[0], pt);
    } else {
        var ips: [8][*c]u8 = undefined;
        var nips: usize = 0;
        var ip: [IPaddrlen]u8 = undefined;
        if (parseip(&ip, f[1]) != -1) {
            ips[0] = c.smprint(@constCast("%I"), &ip);
            nips = 1;
        } else {
            // Names outside the policy never reach the host's resolver.
            const pr = h9_net_proto(f[0]);
            if (h9_net_lookup(pr, f[1], pt) < 0) return port.kerror("no translation for host found");
            const r = try dev.raising(&so_gethostbyname, .{ f[1], &ips, @as(c_int, ips.len) });
            if (r <= 0) return port.kerror("no translation for host found");
            nips = @intCast(r);
            var addrs: [8][IPaddrlen]u8 = undefined;
            for (0..nips) |i| {
                if (parseip(&addrs[i], ips[i]) == -1) addrs[i] = @splat(0);
            }
            h9_net_resolved(pr, f[1], pt, &addrs, @intCast(nips));
        }
        ns = c.smprint(@constCast("/net/%s/clone %s!%d"), f[0], ips[0], pt);
        c.free(ips[0]);
        for (1..nips) |i| {
            const t = c.smprint(@constCast("%s\n/net/%s/clone %s!%d"), ns, f[0], ips[i], pt);
            c.free(ips[i]);
            c.free(ns);
            ns = t;
        }
    }
    c.free(dev.aux(ch).*);
    dev.aux(ch).* = ns;
    return n;
}

/// A conversation's host socket, for readiness and the Linux calls that
/// pass flags (src/kern/linuxnet.zig). -1 if ch isn't a conversation's
/// file or it has no socket yet. udp says whether it's a datagram one.
pub fn sfd(ch: *Chan, udp: ?*c_int) c_int {
    switch (TYPE(ch.qid)) {
        Qctl, Qdata, Qlisten => {},
        else => return -1,
    }
    if (PROTO(ch.qid) >= np) return -1;
    const cv = proto[PROTO(ch.qid)].conv[CONV(ch.qid)] orelse return -1;
    if (udp) |u| u.* = @intFromBool(cv.p.stype == S_UDP);
    return cv.sfd;
}

/// Writes a control message to the conversation behind any of ch's
/// files, as a write to its ctl would, for the Linux socket calls.
pub fn ctl(ch: *Chan, msg: [*:0]const u8) Error!c_int {
    var t = ch.*;
    t.qid.path = @intCast(QID(PROTO(ch.qid), CONV(ch.qid), Qctl));
    return ipwrite(&t, msg, @intCast(std.mem.len(msg)), 0);
}

fn ready(ch: *Chan, ev: c_int) c_int {
    return linuxnet.ipready(ch, ev);
}

fn watch(ch: *Chan, ev: c_int, w: *dev.rd.Watch, wk: *dev.rd.Waker) void {
    linuxnet.ipwatch(ch, ev, w, wk);
}

pub const Device = dev.Native('I', "ip", .{
    .init = ipinit,
    .attach = ipattach,
    .walk = ipwalk,
    .stat = ipstat,
    .open = ipopen,
    .create = dev.devcreate,
    .close = ipclose,
    .read = ipread,
    .write = ipwrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
    .gens = &.{&ipgen},
    .ready = ready,
    .watch = watch,
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "ipdevtab" });
}
