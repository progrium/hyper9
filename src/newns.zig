//! Namespace files in 9front's newns syntax (libauth/newns.c), for `--ns`:
//! the namespace `--print` shows can be saved and replayed. Parsing is pure;
//! the machine runs the operations through the kernel.
//!
//! Supported: `bind`, `mount`, `unmount`, `cd` and `clear`, with the flags
//! `-a`, `-b`, `-c` and `-C`, `#` comments, and `'` quoting (`''` is a
//! literal quote). As in newns, a failed operation doesn't stop the replay.
//! `--print`'s trailing ro/rw/eph/9p column and `<id>` console placeholder
//! are accepted, so its output replays as-is. A `bind` from a bare `#O` makes
//! a fresh copy-on-write overlay over whatever its target is at that point
//! in the replay (design/0006-ephemeral-writes.md); the machine does that. `.` (include) and `chdev`, and
//! `$var` expansion, aren't supported.

const std = @import("std");

pub const Op = union(enum) {
    bind: struct { from: []const u8, to: []const u8, flag: Flag },
    mount: struct { file: []const u8, to: []const u8, spec: []const u8, flag: Flag },
    unmount: struct { from: ?[]const u8, to: []const u8 },
    cd: []const u8,
    clear,
};

pub const Flag = struct {
    order: enum { repl, before, after } = .repl,
    create: bool = false,
    cache: bool = false,
};

pub const Error = error{ OutOfMemory, Syntax };

/// Parses a namespace file. Strings are allocated in `arena`. On a syntax
/// error, `line_no` is the line at fault (from 1).
pub fn parse(arena: std.mem.Allocator, text: []const u8, line_no: *usize) Error![]Op {
    var ops: std.ArrayList(Op) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    line_no.* = 0;
    while (lines.next()) |raw| {
        line_no.* += 1;
        var args: std.ArrayList([]const u8) = .empty;
        try split(arena, raw, &args);
        if (args.items.len == 0) continue;
        const op = try parseLine(args.items);
        try ops.append(arena, op);
    }
    return ops.items;
}

fn parseLine(argv: []const []const u8) Error!Op {
    const cmd = argv[0];
    var flag: Flag = .{};
    var i: usize = 1;
    while (i < argv.len and argv[i].len > 1 and argv[i][0] == '-') : (i += 1) {
        for (argv[i][1..]) |ch| switch (ch) {
            'a' => flag.order = .after,
            'b' => flag.order = .before,
            'c' => flag.create = true,
            'C' => flag.cache = true,
            else => return error.Syntax,
        };
    }
    var rest = argv[i..];
    // --print's access column. --print always writes a mount's spec, ''
    // when empty, so a mount's column is its fourth word.
    if (rest.len == 3 and std.mem.eql(u8, cmd, "bind") and isAccess(rest[2])) {
        rest = rest[0 .. rest.len - 1];
    }
    if (rest.len == 4 and std.mem.eql(u8, cmd, "mount") and isAccess(rest[3])) {
        rest = rest[0 .. rest.len - 1];
    }
    if (std.mem.eql(u8, cmd, "bind") and rest.len == 2) return .{ .bind = .{ .from = rest[0], .to = rest[1], .flag = flag } };
    if (std.mem.eql(u8, cmd, "mount") and (rest.len == 2 or rest.len == 3))
        return .{ .mount = .{ .file = rest[0], .to = rest[1], .spec = if (rest.len == 3) rest[2] else "", .flag = flag } };
    if (std.mem.eql(u8, cmd, "unmount") and rest.len == 1) return .{ .unmount = .{ .from = null, .to = rest[0] } };
    if (std.mem.eql(u8, cmd, "unmount") and rest.len == 2) return .{ .unmount = .{ .from = rest[0], .to = rest[1] } };
    if (std.mem.eql(u8, cmd, "cd") and rest.len == 1) return .{ .cd = rest[0] };
    if (std.mem.eql(u8, cmd, "clear") and rest.len == 0) return .clear;
    return error.Syntax;
}

fn isAccess(s: []const u8) bool {
    for ([_][]const u8{ "ro", "rw", "eph", "9p" }) |a| if (std.mem.eql(u8, s, a)) return true;
    return false;
}

/// Splits a line into arguments on blanks, honouring `'` quoting, and
/// stops at an unquoted `#` that starts a word.
fn split(arena: std.mem.Allocator, line: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    var i: usize = 0;
    while (true) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\r')) i += 1;
        if (i >= line.len or line[i] == '#') return;
        var word: std.ArrayList(u8) = .empty;
        var quoted = false;
        while (i < line.len) : (i += 1) {
            const ch = line[i];
            if (ch == '\'') {
                if (quoted and i + 1 < line.len and line[i + 1] == '\'') {
                    try word.append(arena, '\'');
                    i += 1;
                } else quoted = !quoted;
                continue;
            }
            if (!quoted and (ch == ' ' or ch == '\t' or ch == '\r')) break;
            try word.append(arena, ch);
        }
        if (quoted) return error.Syntax;
        try out.append(arena, word.items);
    }
}

const t = std.testing;

test "parse binds, mounts and the rest" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var line: usize = 0;
    const ops = try parse(arena.allocator(),
        \\# comment
        \\bind /sys/lib /lib
        \\bind -ac '#e' /env
        \\  bind -b '#y<id>' /dev
        \\bind '#U/a b' /mnt/term/cwd                ro
        \\mount -C /srv/fs /n/fs spec
        \\unmount /n/fs
        \\unmount /a /b
        \\cd /tmp
        \\clear
        \\bind 'it''s' /x # trailing
        \\  bind -c '#O' /mnt/term/cwd                eph  # /Users/me/src/proj
    , &line);
    try t.expectEqual(@as(usize, 11), ops.len);
    try t.expectEqualStrings("/sys/lib", ops[0].bind.from);
    try t.expectEqual(.repl, ops[0].bind.flag.order);
    try t.expectEqual(.after, ops[1].bind.flag.order);
    try t.expect(ops[1].bind.flag.create);
    try t.expectEqualStrings("#e", ops[1].bind.from);
    try t.expectEqualStrings("#y<id>", ops[2].bind.from);
    try t.expectEqual(.before, ops[2].bind.flag.order);
    try t.expectEqualStrings("#U/a b", ops[3].bind.from);
    try t.expectEqualStrings("/mnt/term/cwd", ops[3].bind.to);
    try t.expect(ops[4].mount.flag.cache);
    try t.expectEqualStrings("spec", ops[4].mount.spec);
    try t.expectEqual(@as(?[]const u8, null), ops[5].unmount.from);
    try t.expectEqualStrings("/a", ops[6].unmount.from.?);
    try t.expectEqualStrings("/tmp", ops[7].cd);
    try t.expect(ops[8] == .clear);
    try t.expectEqualStrings("it's", ops[9].bind.from);
    try t.expectEqualStrings("#O", ops[10].bind.from);
    try t.expectEqualStrings("/mnt/term/cwd", ops[10].bind.to);
    try t.expect(ops[10].bind.flag.create);
}

test "a 9P root's mount line from --print" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var line: usize = 0;
    const ops = try parse(arena.allocator(),
        \\  mount '#s/root' / ''                                  9p  # tcp!fs!564
        \\  mount '#s/root' /n/other other                        9p
        \\mount /srv/x /n/x 9p
    , &line);
    try t.expectEqual(@as(usize, 3), ops.len);
    try t.expectEqualStrings("#s/root", ops[0].mount.file);
    try t.expectEqualStrings("/", ops[0].mount.to);
    try t.expectEqualStrings("", ops[0].mount.spec);
    try t.expectEqualStrings("other", ops[1].mount.spec);
    // Three words: the third is the spec, as in newns.
    try t.expectEqualStrings("9p", ops[2].mount.spec);
}

test "syntax errors name the line" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var line: usize = 0;
    try t.expectError(error.Syntax, parse(arena.allocator(), "bind /a /b\nbind /a\n", &line));
    try t.expectEqual(@as(usize, 2), line);
    try t.expectError(error.Syntax, parse(arena.allocator(), "bind -x /a /b\n", &line));
    try t.expectError(error.Syntax, parse(arena.allocator(), "bind 'open /b\n", &line));
    try t.expectError(error.Syntax, parse(arena.allocator(), "frob /a\n", &line));
}
