//! A host tree in memory (design/host-handles.md): a `Tree` an embedder
//! builds from a list of files, which `#ū` (src/host/devtree.zig) serves
//! as a directory handle with no host directory beneath it. The files'
//! bytes are the caller's and must outlive it; the directories are the
//! ones the paths name.

const std = @import("std");
const host = @import("host.zig");

pub const File = struct {
    /// Relative, with `/` between names.
    path: []const u8,
    data: []const u8,
    /// Listed with execute permission.
    exec: bool = false,
};

pub const MemTree = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node) = .empty,

    const Node = struct {
        name: [:0]const u8,
        parent: u64,
        /// Null for a directory.
        data: ?[]const u8,
        exec: bool,
        kids: std.ArrayList(u64) = .empty,
    };

    /// The tree of `files`, in `t`, which mustn't move while its `tree` is
    /// in use.
    pub fn init(t: *MemTree, gpa: std.mem.Allocator, files: []const File) error{ OutOfMemory, BadPath }!void {
        t.* = .{ .arena = .init(gpa) };
        errdefer t.arena.deinit();
        const a = t.arena.allocator();
        try t.nodes.append(a, .{ .name = "", .parent = 0, .data = null, .exec = true });
        for (files) |f| {
            var at: u64 = 0;
            var it = std.mem.tokenizeScalar(u8, f.path, '/');
            while (it.next()) |name| {
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.BadPath;
                const last = it.peek() == null;
                if (t.find(at, name)) |k| {
                    if ((t.nodes.items[k].data == null) == last) return error.BadPath;
                    at = k;
                    continue;
                }
                if (t.nodes.items[at].data != null) return error.BadPath;
                const k: u64 = t.nodes.items.len;
                try t.nodes.append(a, .{
                    .name = try a.dupeSentinel(u8, name, 0),
                    .parent = at,
                    .data = if (last) f.data else null,
                    .exec = if (last) f.exec else true,
                });
                try t.nodes.items[at].kids.append(a, k);
                at = k;
            }
        }
    }

    pub fn deinit(t: *MemTree) void {
        t.arena.deinit();
    }

    pub fn tree(t: *MemTree) host.Tree {
        return .{ .ctx = t, .vtable = &vt };
    }

    fn find(t: *const MemTree, at: u64, name: []const u8) ?u64 {
        for (t.nodes.items[at].kids.items) |k| if (std.mem.eql(u8, t.nodes.items[k].name, name)) return k;
        return null;
    }

    fn entryOf(t: *const MemTree, id: u64) host.Tree.Entry {
        const n = t.nodes.items[id];
        return .{ .id = id, .name = n.name, .dir = n.data == null, .len = if (n.data) |d| d.len else 0, .exec = n.exec };
    }

    const vt: host.Tree.VTable = .{ .entry = entry, .parent = parent, .child = child, .read = read };

    fn self(ctx: *anyopaque) *const MemTree {
        return @ptrCast(@alignCast(ctx));
    }

    fn entry(ctx: *anyopaque, id: u64) ?host.Tree.Entry {
        const t = self(ctx);
        if (id >= t.nodes.items.len) return null;
        return t.entryOf(id);
    }

    fn parent(ctx: *anyopaque, id: u64) u64 {
        const t = self(ctx);
        return if (id < t.nodes.items.len) t.nodes.items[id].parent else 0;
    }

    fn child(ctx: *anyopaque, id: u64, i: usize) ?host.Tree.Entry {
        const t = self(ctx);
        if (id >= t.nodes.items.len) return null;
        const kids = t.nodes.items[id].kids.items;
        if (i >= kids.len) return null;
        return t.entryOf(kids[i]);
    }

    fn read(ctx: *anyopaque, id: u64, off: u64, buf: []u8) usize {
        const t = self(ctx);
        if (id >= t.nodes.items.len) return 0;
        const d = t.nodes.items[id].data orelse return 0;
        if (off >= d.len) return 0;
        const n = @min(buf.len, d.len - off);
        @memcpy(buf[0..n], d[@intCast(off)..][0..n]);
        return n;
    }
};

test "a MemTree has the directories its paths name" {
    var t: MemTree = undefined;
    try t.init(std.testing.allocator, &.{
        .{ .path = "a/b/c", .data = "abc" },
        .{ .path = "a/d", .data = "d", .exec = true },
        .{ .path = "e", .data = "" },
    });
    defer t.deinit();
    const tr = t.tree();
    const a = tr.child(0, 0).?;
    try std.testing.expectEqualStrings("a", a.name);
    try std.testing.expect(a.dir);
    const b = tr.lookup(a.id, "b").?;
    const c = tr.lookup(b.id, "c").?;
    try std.testing.expect(!c.dir);
    try std.testing.expectEqual(@as(u64, 3), c.len);
    try std.testing.expectEqual(b.id, tr.parent(c.id));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("bc", buf[0..tr.read(c.id, 1, &buf)]);
    try std.testing.expect(tr.lookup(a.id, "d").?.exec);
    try std.testing.expect(tr.child(0, 2) == null);
    var bad: MemTree = undefined;
    try std.testing.expectError(error.BadPath, bad.init(std.testing.allocator, &.{ .{ .path = "x", .data = "" }, .{ .path = "x/y", .data = "" } }));
}
