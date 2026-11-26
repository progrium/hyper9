//! The namespace kernel's cases (design/namespace-kernel.md), through its
//! native library: each connection is a socketpair, one end served with
//! h9ns_serve, the other a 9P2000 client (tests/ninep.zig), as a host
//! would talk to it.

const std = @import("std");
const ninep = @import("ninep.zig");
const h9ns = @import("h9ns");
const TestServer = h9ns.DotlTestServer;

const t = std.testing;
const gpa = std.heap.page_allocator;
const Client = ninep.Client;

comptime {
    _ = h9ns;
}

extern fn h9ns_boot() c_int;
extern fn h9ns_serve(fd: c_int, aname: ?[*:0]const u8) c_int;
extern fn h9ns_addfd(name: ?[*:0]const u8, fd: c_int) c_int;

fn pair() ![2]c_int {
    var sv: [2]c_int = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv) != 0) return error.SocketPair;
    return sv;
}

/// A connection to namespace `aname`, attached: the client and its root fid.
const Conn = struct {
    c: Client,
    root: u32,

    fn open(aname: [:0]const u8) !Conn {
        if (h9ns_boot() != 0) return error.Boot;
        const sv = try pair();
        if (h9ns_serve(sv[0], aname) != 0) return error.Serve;
        var c = try Client.init(gpa, sv[1]);
        const root = try c.attach("");
        return .{ .c = c, .root = root };
    }

    fn close(k: *Conn) void {
        _ = std.c.close(k.c.fd);
        k.c.deinit();
    }

    fn cat(k: *Conn, path: []const u8) ![]u8 {
        return k.c.cat(k.root, path);
    }

    fn ls(k: *Conn, path: []const u8) ![]u8 {
        return k.c.ls(k.root, path);
    }

    fn exists(k: *Conn, path: []const u8) !bool {
        return k.c.exists(k.root, path);
    }

    fn make(k: *Conn, path: []const u8, dir: bool, data: []const u8) !void {
        return k.c.make(k.root, path, dir, data);
    }
};

/// The control connection, to namespace 0.
var control: ?Conn = null;

fn ctl0() !*Conn {
    if (control == null) control = try Conn.open("");
    return &control.?;
}

/// A namespace made through /ns/clone, whose ctl fid stays open.
const Ns = struct {
    id: [16]u8 = undefined,
    id_len: usize = 0,
    fid: u32,

    fn new(first: ?[]const u8) !Ns {
        const k = try ctl0();
        const f = try k.c.walk(k.root, "ns/clone");
        try k.c.open(f, ninep.ORDWR);
        var n: Ns = .{ .fid = f };
        n.id_len = try k.c.read(f, 0, &n.id);
        if (first) |l| try n.ctl(l);
        return n;
    }

    fn name(n: *const Ns) []const u8 {
        return n.id[0..n.id_len];
    }

    fn nameZ(n: *const Ns, buf: *[17]u8) [:0]const u8 {
        @memcpy(buf[0..n.id_len], n.name());
        buf[n.id_len] = 0;
        return buf[0..n.id_len :0];
    }

    /// Writes ctl line `l`; error.Rerror with the client's errstr if it fails.
    fn ctl(n: *const Ns, l: []const u8) !void {
        const k = try ctl0();
        _ = try k.c.write(n.fid, 0, l);
    }

    fn attach(n: *const Ns) !Conn {
        var b: [17]u8 = undefined;
        return Conn.open(n.nameZ(&b));
    }

    fn close(n: *const Ns) void {
        const k = ctl0() catch return;
        k.c.clunk(n.fid) catch {};
    }
};

/// Writes a line to namespace 0's ctl.
fn ctlZero(l: []const u8) !void {
    const k = try ctl0();
    try k.c.put(k.root, "ns/0/ctl", l);
}

/// Serves namespace `n` on a socketpair and names the other end `name`,
/// so a ctl line can mount it as fd!name.
fn lend(n: *const Ns, name: [:0]const u8) !void {
    const sv = try pair();
    var b: [17]u8 = undefined;
    if (h9ns_serve(sv[0], n.nameZ(&b)) != 0) return error.Serve;
    if (h9ns_addfd(name, sv[1]) != 0) return error.AddFd;
}

/// A namespace holding /hello, served as fd!name.
fn helloServer(name: [:0]const u8) !Ns {
    const x = try Ns.new(null);
    var k = try x.attach();
    defer k.close();
    try k.make("/hello", false, "hi");
    try lend(&x, name);
    return x;
}

test "an empty namespace's / is writable and in memory [namespace-kernel]" {
    const a = try Ns.new(null);
    defer a.close();
    var k = try a.attach();
    defer k.close();
    try k.make("/a", true, "");
    try k.make("/a/b", false, "data");
    const got = try k.cat("/a/b");
    defer gpa.free(got);
    try t.expectEqualStrings("data", got);
    // Another namespace's root is its own.
    const b = try Ns.new(null);
    defer b.close();
    var kb = try b.attach();
    defer kb.close();
    try t.expect(!try kb.exists("/a"));
}

test "a copied namespace keeps its parent's mounts [namespace-kernel]" {
    const x = try helloServer("copied");
    defer x.close();
    const a = try Ns.new(null);
    defer a.close();
    var ka = try a.attach();
    defer ka.close();
    try ka.make("/n", true, "");
    try a.ctl("mount fd!copied /n");
    var line: [32]u8 = undefined;
    const b = try Ns.new(try std.fmt.bufPrint(&line, "copy {s}", .{a.name()}));
    defer b.close();
    var kb = try b.attach();
    defer kb.close();
    const got = try kb.cat("/n/hello");
    defer gpa.free(got);
    try t.expectEqualStrings("hi", got);
}

test "ctl lines bind, mount and unmount in that namespace only [namespace-kernel]" {
    const x = try helloServer("only");
    defer x.close();
    const a = try Ns.new(null);
    defer a.close();
    var ka = try a.attach();
    defer ka.close();
    try ka.make("/x", true, "");
    try ka.make("/y", true, "");
    try ka.make("/m", true, "");
    try ka.make("/x/f", false, "f");
    var line: [32]u8 = undefined;
    // b shares a's root tree, but not its mount table.
    const b = try Ns.new(try std.fmt.bufPrint(&line, "copy {s}", .{a.name()}));
    defer b.close();
    var kb = try b.attach();
    defer kb.close();
    try a.ctl("bind /x /y");
    try a.ctl("mount fd!only /m");
    try t.expect(try ka.exists("/y/f"));
    try t.expect(try ka.exists("/m/hello"));
    try t.expect(!try kb.exists("/y/f"));
    try t.expect(!try kb.exists("/m/hello"));
    try a.ctl("unmount /y");
    try a.ctl("unmount /m");
    try t.expect(!try ka.exists("/y/f"));
    try t.expect(!try ka.exists("/m/hello"));
}

test "ns reads back lines ctl replays into an equal namespace [namespace-kernel]" {
    const a = try Ns.new(null);
    defer a.close();
    var ka = try a.attach();
    defer ka.close();
    try ka.make("/p", true, "");
    try ka.make("/q", true, "");
    try ka.make("/r", true, "");
    try a.ctl("bind -b /p /q\nbind -a /r /q\nbind '#O' /r");
    const k = try ctl0();
    var path: [32]u8 = undefined;
    const text = try k.cat(try std.fmt.bufPrint(&path, "ns/{s}/ns", .{a.name()}));
    defer gpa.free(text);
    var line: [32]u8 = undefined;
    // A copy of a's root, cleared, then the lines.
    const b = try Ns.new(try std.fmt.bufPrint(&line, "copy {s}", .{a.name()}));
    defer b.close();
    try b.ctl("clear");
    try b.ctl(text);
    const again = try k.cat(try std.fmt.bufPrint(&path, "ns/{s}/ns", .{b.name()}));
    defer gpa.free(again);
    try t.expectEqualStrings(text, again);
    try t.expect(std.mem.indexOf(u8, text, "bind -b /p /q\n") != null);
}

/// Serves the translator's test server (src/dotl/testserver.zig) on `fd`.
fn dotlLoop(s: *TestServer, fd: c_int) void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) return;
        s.feed(buf[0..@intCast(n)]) catch return;
        var off: usize = 0;
        while (off < s.out.items.len) {
            const w = std.c.write(fd, s.out.items[off..].ptr, s.out.items.len - off);
            if (w <= 0) return;
            off += @intCast(w);
        }
        s.out.items.len = 0;
    }
}

test "a 9P2000.L server mounts through ctl [namespace-kernel, dotl]" {
    const s = try TestServer.init(gpa);
    _ = try s.add("etc/issue", .file, "dotl\n");
    const sv = try pair();
    const th = try std.Thread.spawn(.{}, dotlLoop, .{ s, sv[0] });
    th.detach();
    try t.expectEqual(@as(c_int, 0), h9ns_addfd("dotl", sv[1]));
    const a = try Ns.new(null);
    defer a.close();
    var ka = try a.attach();
    defer ka.close();
    try ka.make("/l", true, "");
    try a.ctl("mount fd!dotl /l");
    const got = try ka.cat("/l/etc/issue");
    defer gpa.free(got);
    try t.expectEqualStrings("dotl\n", got);
}

fn gone(path: []const u8) !bool {
    const k = try ctl0();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (!try k.exists(path)) return true;
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

test "a namespace is freed when ctl and every attach close [namespace-kernel]" {
    const k = try ctl0();
    var path: [32]u8 = undefined;
    const a = try Ns.new(null);
    const p = try std.fmt.bufPrint(&path, "ns/{s}", .{a.name()});
    var ka = try a.attach();
    a.close();
    // The attach holds it.
    try t.expect(try k.exists(p));
    ka.close();
    try t.expect(try gone(p));

    // hold keeps one with neither, until free.
    const b = try Ns.new("hold");
    var pb: [32]u8 = undefined;
    const q = try std.fmt.bufPrint(&pb, "ns/{s}", .{b.name()});
    b.close();
    try t.expect(try k.exists(q));
    var cp: [32]u8 = undefined;
    try k.c.put(k.root, try std.fmt.bufPrint(&cp, "ns/{s}/ctl", .{b.name()}), "free");
    try t.expect(try gone(q));
}

test "/ns isn't reachable from a task's namespace [namespace-kernel]" {
    const a = try Ns.new("copy 0");
    defer a.close();
    var ka = try a.attach();
    defer ka.close();
    try t.expect(!try ka.exists("/ns/clone"));
    try t.expect(!try ka.exists("/srv/clone"));
    // Its ctl can't attach #N or #s either.
    try t.expectError(error.Rerror, a.ctl("bind '#N' /tmp"));
    const k = try ctl0();
    try t.expect(k.c.errstr().len > 0);
    try t.expectError(error.Rerror, a.ctl("bind '#s' /tmp"));
    // Nor can an attach name another namespace.
    try t.expectError(error.Rerror, ka.c.attach("0"));
}

test "srv!opfs in a ctl mounts the host's board entry into that namespace only [namespace-kernel]" {
    const x = try helloServer("opfs-conn");
    defer x.close();
    try ctlZero("post opfs fd!opfs-conn");
    const k = try ctl0();
    try t.expect(try k.exists("/srv/opfs"));
    const a = try Ns.new(null);
    defer a.close();
    var ka = try a.attach();
    defer ka.close();
    try ka.make("/mnt", true, "");
    try a.ctl("mount srv!opfs /mnt");
    const got = try ka.cat("/mnt/hello");
    defer gpa.free(got);
    try t.expectEqualStrings("hi", got);
    var line: [32]u8 = undefined;
    const b = try Ns.new(try std.fmt.bufPrint(&line, "copy {s}", .{a.name()}));
    defer b.close();
    try b.ctl("unmount /mnt");
    var kb = try b.attach();
    defer kb.close();
    try t.expect(!try kb.exists("/mnt/hello"));
    try t.expect(try ka.exists("/mnt/hello"));
}

test "a task's board line gives it a private /srv [namespace-kernel]" {
    const x = try helloServer("board-conn");
    defer x.close();
    const a = try Ns.new(null);
    defer a.close();
    try a.ctl("board");
    try a.ctl("post mine fd!board-conn");
    var ka = try a.attach();
    defer ka.close();
    const l = try ka.ls("/srv");
    defer gpa.free(l);
    try t.expectEqualStrings("clone mine", l);
    const k = try ctl0();
    try t.expect(!try k.exists("/srv/mine"));
    const b = try Ns.new("board");
    defer b.close();
    var kb = try b.attach();
    defer kb.close();
    try t.expect(!try kb.exists("/srv/mine"));
}

test "the native library serves the same tree [namespace-kernel]" {
    // The tree tests/web/nskernel.mjs builds through h9ns.wasm.
    const a = try Ns.new(null);
    defer a.close();
    try a.ctl("bind '#O' /");
    var ka = try a.attach();
    defer ka.close();
    try ka.make("/a", true, "");
    try ka.make("/a/b", false, "b\n");
    const l = try ka.ls("/a");
    defer gpa.free(l);
    try t.expectEqualStrings("b", l);
    var kb = try a.attach();
    defer kb.close();
    const got = try kb.cat("/a/b");
    defer gpa.free(got);
    try t.expectEqualStrings("b\n", got);
}
