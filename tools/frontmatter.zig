//! Proposals under design/: their frontmatter, parsed (design/0001-proposals.md).
//! Shared by tools/design.zig and build.zig, so it does no I/O beyond
//! reading the design directory, and never fails on a bad proposal: it
//! reports it and carries on, and `zig build design -- check` decides.
//!
//! The frontmatter is a strict subset of YAML: one `key: value` per line,
//! values are scalars or flow lists (`[a, b]`), with no nesting, quoting or
//! multi-line values.

const std = @import("std");

pub const Status = enum {
    draft,
    @"likely-accept",
    @"likely-decline",
    accepted,
    declined,
    hold,
    implemented,
    superseded,

    /// The final comment period.
    pub fn inFcp(s: Status) bool {
        return s == .@"likely-accept" or s == .@"likely-decline";
    }
};

pub const Proposal = struct {
    /// File name within the design directory.
    file: []const u8,
    /// The GitHub issue number, once filed; 0 for the baseline, which has none.
    id: ?u32 = null,
    slug: []const u8 = "",
    title: []const u8 = "",
    status: Status = .draft,
    created: []const u8 = "",
    authors: []const []const u8 = &.{},
    /// Ids or slugs, as written.
    depends: []const []const u8 = &.{},
    areas: []const []const u8 = &.{},
    superseded_by: ?[]const u8 = null,
    /// Lines of `depends` and `superseded-by`, for messages.
    depends_line: u32 = 0,
    superseded_line: u32 = 0,
    /// Everything after the frontmatter.
    body: []const u8 = "",
    /// False when the frontmatter had errors; the fields may be partial.
    ok: bool = true,

    /// `#42`, `#0` for the baseline, or the slug for a draft.
    pub fn name(p: Proposal, buf: []u8) []const u8 {
        if (p.id) |id| return std.fmt.bufPrint(buf, "#{d}", .{id}) catch p.slug;
        return p.slug;
    }

    /// The file name the proposal should have: `NNNN-slug.md` once filed,
    /// `slug.md` before.
    pub fn expectedFile(p: Proposal, buf: []u8) []const u8 {
        if (p.id) |id| return std.fmt.bufPrint(buf, "{d:0>4}-{s}.md", .{ id, p.slug }) catch "";
        return std.fmt.bufPrint(buf, "{s}.md", .{p.slug}) catch "";
    }
};

/// Messages from parsing and checking, as `file:line: text`.
pub const Diags = struct {
    gpa: std.mem.Allocator,
    errors: std.ArrayList([]const u8) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,

    pub fn err(d: *Diags, comptime fmt: []const u8, args: anytype) void {
        d.errors.append(d.gpa, std.fmt.allocPrint(d.gpa, fmt, args) catch return) catch {};
    }

    pub fn warn(d: *Diags, comptime fmt: []const u8, args: anytype) void {
        d.warnings.append(d.gpa, std.fmt.allocPrint(d.gpa, fmt, args) catch return) catch {};
    }
};

const keys = [_][]const u8{ "id", "slug", "title", "status", "created", "authors", "depends", "areas", "superseded-by" };
const required = [_][]const u8{ "slug", "title", "status", "created", "authors", "depends" };
const lists = [_][]const u8{ "authors", "depends", "areas" };

fn member(set: []const []const u8, s: []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// A slug: lowercase words of letters and digits joined by dashes. It
/// can't be all digits, which would read as an id.
pub fn validSlug(s: []const u8) bool {
    if (s.len == 0 or s[0] == '-' or isId(s)) return false;
    var prev_dash = false;
    for (s) |c| {
        if (c == '-') {
            if (prev_dash) return false;
            prev_dash = true;
        } else if (std.ascii.isLower(c) or std.ascii.isDigit(c)) {
            prev_dash = false;
        } else return false;
    }
    return !prev_dash;
}

/// All digits: an id rather than a slug.
pub fn isId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn validDate(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    for (s, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return false;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return false;
    return month >= 1 and month <= 12 and day >= 1 and day <= 31;
}

/// Parses one proposal. `file` is its name in the design directory, for
/// messages and the filename check. Problems go to `diags`, and the result
/// has `ok` false.
pub fn parse(arena: std.mem.Allocator, file: []const u8, text: []const u8, diags: *Diags) Proposal {
    var p: Proposal = .{ .file = file };
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.first(), "\r"), "---")) {
        diags.err("design/{s}:1: no frontmatter (the file must start with ---)", .{file});
        p.ok = false;
        return p;
    }
    var seen: std.ArrayList([]const u8) = .empty;
    // Keys with a bad value, so they aren't also reported as missing or empty.
    var bad: std.ArrayList([]const u8) = .empty;
    var lineno: u32 = 1;
    var closed = false;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "---")) {
            closed = true;
            break;
        }
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            diags.err("design/{s}:{d}: not a `key: value` line", .{ file, lineno });
            p.ok = false;
            continue;
        };
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (key.len == 0 or key[0] == ' ' or key[0] == '\t') {
            diags.err("design/{s}:{d}: nested or indented keys aren't supported", .{ file, lineno });
            p.ok = false;
            continue;
        }
        if (!member(&keys, key)) {
            diags.err("design/{s}:{d}: unknown key `{s}`", .{ file, lineno, key });
            p.ok = false;
            continue;
        }
        if (member(seen.items, key)) {
            diags.err("design/{s}:{d}: duplicate key `{s}`", .{ file, lineno, key });
            p.ok = false;
            continue;
        }
        seen.append(arena, key) catch {};
        if (value.len > 0 and (value[0] == '"' or value[0] == '\'' or value[0] == '|' or value[0] == '>' or value[0] == '{')) {
            diags.err("design/{s}:{d}: `{s}`: quoting, nesting and multi-line values aren't supported", .{ file, lineno, key });
            p.ok = false;
            bad.append(arena, key) catch {};
            continue;
        }
        if (!member(&lists, key)) if (plainScalarProblem(value)) |why| {
            diags.err("design/{s}:{d}: `{s}`: {s}, which YAML would read differently", .{ file, lineno, key, why });
            p.ok = false;
            bad.append(arena, key) catch {};
            continue;
        };
        if (member(&lists, key)) {
            const items = parseList(arena, value) orelse {
                diags.err("design/{s}:{d}: `{s}` must be a list, such as [a, b]", .{ file, lineno, key });
                p.ok = false;
                bad.append(arena, key) catch {};
                continue;
            };
            if (std.mem.eql(u8, key, "authors")) p.authors = items;
            if (std.mem.eql(u8, key, "depends")) {
                p.depends = items;
                p.depends_line = lineno;
            }
            if (std.mem.eql(u8, key, "areas")) p.areas = items;
            continue;
        }
        if (value.len > 0 and value[0] == '[') {
            diags.err("design/{s}:{d}: `{s}` must be a single value, not a list", .{ file, lineno, key });
            p.ok = false;
            bad.append(arena, key) catch {};
            continue;
        }
        if (std.mem.eql(u8, key, "id")) {
            p.id = std.fmt.parseInt(u32, value, 10) catch blk: {
                diags.err("design/{s}:{d}: `id` must be an issue number, not `{s}`", .{ file, lineno, value });
                p.ok = false;
                break :blk null;
            };
            if (value.len > 0 and value[0] == '+') {
                diags.err("design/{s}:{d}: `id` must be an issue number, not `{s}`", .{ file, lineno, value });
                p.ok = false;
            }
        } else if (std.mem.eql(u8, key, "slug")) {
            p.slug = value;
            if (!validSlug(value)) {
                diags.err("design/{s}:{d}: bad slug `{s}`: lowercase words of letters and digits joined by dashes, not all digits", .{ file, lineno, value });
                p.ok = false;
            }
        } else if (std.mem.eql(u8, key, "title")) {
            p.title = value;
        } else if (std.mem.eql(u8, key, "status")) {
            p.status = std.meta.stringToEnum(Status, value) orelse blk: {
                diags.err("design/{s}:{d}: unknown status `{s}`", .{ file, lineno, value });
                p.ok = false;
                break :blk .draft;
            };
        } else if (std.mem.eql(u8, key, "created")) {
            p.created = value;
            if (!validDate(value)) {
                diags.err("design/{s}:{d}: `created` must be YYYY-MM-DD, not `{s}`", .{ file, lineno, value });
                p.ok = false;
            }
        } else if (std.mem.eql(u8, key, "superseded-by")) {
            if (value.len > 0) p.superseded_by = value;
            p.superseded_line = lineno;
        }
    }
    if (!closed) {
        diags.err("design/{s}: the frontmatter has no closing ---", .{file});
        p.ok = false;
        return p;
    }
    for (required) |k| if (!member(seen.items, k)) {
        diags.err("design/{s}: missing `{s}`", .{ file, k });
        p.ok = false;
    };
    if (member(seen.items, "title") and !member(bad.items, "title") and p.title.len == 0) {
        diags.err("design/{s}: `title` is empty", .{file});
        p.ok = false;
    }
    if (member(seen.items, "authors") and !member(bad.items, "authors") and p.authors.len == 0) {
        diags.err("design/{s}: `authors` is empty", .{file});
        p.ok = false;
    }
    p.body = lines.rest();
    return p;
}

/// Why a scalar wouldn't read as the same plain string in YAML, or null.
/// Values are never quoted, so these are refused instead.
pub fn plainScalarProblem(v: []const u8) ?[]const u8 {
    if (v.len == 0) return null;
    if (std.mem.indexOfScalar(u8, "-?:,[]{}#&*!|>'\"%@`", v[0]) != null and !(v[0] == '-' and v.len > 1 and v[1] != ' '))
        return "it starts with a YAML indicator";
    if (std.mem.indexOf(u8, v, ": ") != null or v[v.len - 1] == ':') return "it has a colon followed by a space";
    if (std.mem.indexOf(u8, v, " #") != null) return "it has ` #`, which starts a comment";
    return null;
}

/// `[a, b]` to its items, or null if it isn't a flow list.
fn parseList(arena: std.mem.Allocator, value: []const u8) ?[]const []const u8 {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return null;
    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (inner.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t");
        if (t.len == 0) return null;
        for (t) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return null;
        out.append(arena, t) catch return null;
    }
    return out.items;
}

/// Files in the design directory that aren't proposals.
pub fn isProposalFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") and
        !std.mem.eql(u8, name, "README.md") and !std.mem.eql(u8, name, "TEMPLATE.md");
}

/// Reads and parses every proposal in `dir`, sorted by file name.
pub fn scan(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, diags: *Diags) ![]Proposal {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !isProposalFile(e.name)) continue;
        try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    const out = try arena.alloc(Proposal, names.items.len);
    for (names.items, out) |n, *p| {
        const text = try dir.readFileAlloc(io, n, arena, .limited(1 << 22));
        p.* = parse(arena, n, text, diags);
    }
    return out;
}

/// Looks a reference up by id (digits) or slug.
pub fn resolve(ps: []const Proposal, ref: []const u8) ?usize {
    if (isId(ref)) {
        const id = std.fmt.parseInt(u32, ref, 10) catch return null;
        for (ps, 0..) |p, i| if (p.id == id) return i;
        return null;
    }
    for (ps, 0..) |p, i| if (std.mem.eql(u8, p.slug, ref)) return i;
    return null;
}

/// The tags of proposals that aren't implemented: each one's slug, and its
/// id once filed. The integration tests skip cases tagged with these.
pub fn pendingTags(arena: std.mem.Allocator, ps: []const Proposal) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (ps) |p| {
        if (p.status == .implemented or p.slug.len == 0) continue;
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, p.slug);
        if (p.id) |id| try out.print(arena, " {d}", .{id});
    }
    return out.items;
}

/// The tags as they should be written: trimmed, joined by ", ".
pub fn canonicalTags(arena: std.mem.Allocator, tags: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, tags, ',');
    var first = true;
    while (it.next()) |t| {
        if (!first) try out.appendSlice(arena, ", ");
        first = false;
        try out.appendSlice(arena, std.mem.trim(u8, t, " \t"));
    }
    return out.items;
}

/// The tags at the end of a test name: `name [a, b]` gives a and b.
pub fn testTags(name: []const u8) ?[]const u8 {
    if (name.len == 0 or name[name.len - 1] != ']') return null;
    const open = std.mem.lastIndexOfScalar(u8, name, '[') orelse return null;
    if (open == 0 or name[open - 1] != ' ') return null;
    return name[open + 1 .. name.len - 1];
}

test "parse a proposal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d: Diags = .{ .gpa = arena };
    const p = parse(arena, "0042-linux-personality.md",
        \\---
        \\id: 42
        \\slug: linux-personality
        \\title: Linux personality
        \\status: accepted
        \\created: 2026-11-03
        \\authors: [progrium]
        \\depends: [43, symlinks-in-root]
        \\areas: []
        \\superseded-by:
        \\---
        \\
        \\# Proposal: Linux personality
        \\
    , &d);
    try std.testing.expectEqual(@as(usize, 0), d.errors.items.len);
    try std.testing.expect(p.ok);
    try std.testing.expectEqual(@as(?u32, 42), p.id);
    try std.testing.expectEqual(Status.accepted, p.status);
    try std.testing.expectEqual(@as(usize, 2), p.depends.len);
    try std.testing.expectEqualStrings("symlinks-in-root", p.depends[1]);
    try std.testing.expectEqual(@as(?[]const u8, null), p.superseded_by);
    try std.testing.expect(std.mem.startsWith(u8, p.body, "\n# Proposal"));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0042-linux-personality.md", p.expectedFile(&buf));
}

test "plain scalars" {
    try std.testing.expect(plainScalarProblem("devsrv and /srv") == null);
    try std.testing.expect(plainScalarProblem("Graphics (--gfx)") == null);
    try std.testing.expect(plainScalarProblem("Outbound-only network by default, and --net-allow") == null);
    try std.testing.expect(plainScalarProblem("-x is fine") == null);
    try std.testing.expect(plainScalarProblem("Baseline: h9") != null);
    try std.testing.expect(plainScalarProblem("#1 thing") != null);
    try std.testing.expect(plainScalarProblem("a #b") != null);
    try std.testing.expect(plainScalarProblem("- item") != null);
    try std.testing.expect(plainScalarProblem("ends:") != null);
}

test "slugs and tags" {
    try std.testing.expect(validSlug("linux-personality"));
    try std.testing.expect(validSlug("9p-roots"));
    try std.testing.expect(validSlug("42") == false);
    try std.testing.expect(validSlug("a--b") == false);
    try std.testing.expect(validSlug("a-") == false);
    try std.testing.expect(validSlug("Big") == false);
    try std.testing.expectEqualStrings("baseline", testTags("ls /bin | wc -l (demo) [baseline]").?);
    try std.testing.expectEqualStrings("a, b", testTags("x [a, b]").?);
    try std.testing.expect(testTags("x[a]") == null);
    try std.testing.expect(testTags("no tag") == null);
}
