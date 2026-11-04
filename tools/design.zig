//! The design tool: lists, checks and files the proposals under design/
//! (design/0001-proposals.md). Run as `zig build design -- <command>` from
//! the repository root.

const std = @import("std");
const fm = @import("frontmatter.zig");
const Proposal = fm.Proposal;
const Status = fm.Status;
const Diags = fm.Diags;

const usage =
    \\usage: zig build design -- <command> [args]
    \\
    \\  list [--status S] [--area A]    proposals, their status, and ready or what they need
    \\  ready                           accepted proposals whose dependencies are all implemented
    \\  graph                           the dependency graph, as Mermaid
    \\  readme                          rewrite README.md's proposal table and graph
    \\  new <slug> [--title T] [--author LOGIN]
    \\                                  start a draft from design/TEMPLATE.md
    \\  file <slug> [--yes] [--dry-run] [--issue N]
    \\                                  create its GitHub issue (or use issue N), number it, and commit
    \\  fix                             rewrite slug references to filed proposals as numbers
    \\  check                           validate the proposals and test tags
    \\
;

/// Most proposals that can be in a final comment period at once.
const max_fcp = 3;

/// An integration case and its tags (`test "name [a, b]"`).
const Case = struct {
    file: []const u8,
    line: u32,
    name: []const u8,
    tags: []const []const u8,
    /// The tags as written, between the brackets.
    raw: []const u8,
};

/// The repository as the tool sees it: the proposals and the tagged cases.
const Repo = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    ps: []Proposal,
    cases: []Case,

    fn load(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir, diags: *Diags) !Repo {
        var design = root.openDir(io, "design", .{ .iterate = true }) catch |err| {
            diags.err("design/: {t}", .{err});
            return .{ .arena = arena, .io = io, .root = root, .ps = &.{}, .cases = &.{} };
        };
        defer design.close(io);
        return .{
            .arena = arena,
            .io = io,
            .root = root,
            .ps = try fm.scan(arena, io, design, diags),
            .cases = try scanCases(arena, io, root),
        };
    }

    fn resolve(r: Repo, ref: []const u8) ?usize {
        return fm.resolve(r.ps, ref);
    }
};

/// Integration cases with tags, from tests/*.zig.
fn scanCases(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![]Case {
    var out: std.ArrayList(Case) = .empty;
    var dir = root.openDir(io, "tests", .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zig")) continue;
        const file = try std.fmt.allocPrint(arena, "tests/{s}", .{e.name});
        const text = try dir.readFileAlloc(io, e.name, arena, .limited(1 << 24));
        var lines = std.mem.splitScalar(u8, text, '\n');
        var lineno: u32 = 0;
        while (lines.next()) |line| {
            lineno += 1;
            const name = testName(line) orelse continue;
            const tags = fm.testTags(name) orelse continue;
            var list: std.ArrayList([]const u8) = .empty;
            var ts = std.mem.splitScalar(u8, tags, ',');
            while (ts.next()) |t| try list.append(arena, std.mem.trim(u8, t, " "));
            try out.append(arena, .{ .file = file, .line = lineno, .name = name, .tags = list.items, .raw = tags });
        }
    }
    return out.items;
}

/// The name in a `test "name" {` line.
fn testName(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, t, "test \"")) return null;
    const end = std.mem.lastIndexOf(u8, t, "\" {") orelse return null;
    if (end < 6) return null;
    return t[6..end];
}

/// A proposal with an issue. The baseline (id 0) has none, so it keeps its
/// slug everywhere.
fn filed(p: Proposal) bool {
    return if (p.id) |id| id != 0 else false;
}

fn label(p: Proposal, buf: []u8) []const u8 {
    if (!filed(p)) return p.slug;
    return p.name(buf);
}

// ---- check ----

/// Validates everything `check` covers. Errors and warnings go to `diags`.
fn check(r: Repo, diags: *Diags) !void {
    const ps = r.ps;
    var buf: [64]u8 = undefined;
    var fcp: std.ArrayList([]const u8) = .empty;

    for (ps, 0..) |p, i| {
        if (fm.validSlug(p.slug)) {
            const want = p.expectedFile(&buf);
            if (!std.mem.eql(u8, want, p.file)) diags.err("design/{s}: should be named design/{s}", .{ p.file, want });
        }
        for (ps[0..i]) |q| {
            if (p.slug.len > 0 and std.mem.eql(u8, p.slug, q.slug)) diags.err("design/{s}: slug `{s}` is also used by design/{s}", .{ p.file, p.slug, q.file });
            if (p.id != null and p.id == q.id) diags.err("design/{s}: id {d} is also used by design/{s}", .{ p.file, p.id.?, q.file });
        }
        if (p.status != .draft and p.id == null) diags.err("design/{s}: status `{t}` needs an id; file it first (zig build design -- file {s})", .{ p.file, p.status, p.slug });
        if (p.status == .superseded and p.superseded_by == null) diags.err("design/{s}: superseded, but `superseded-by` isn't set", .{p.file});
        if (p.status != .superseded and p.superseded_by != null) diags.err("design/{s}:{d}: `superseded-by` is set, but the status is `{t}`", .{ p.file, p.superseded_line, p.status });
        if (p.status.inFcp()) try fcp.append(r.arena, p.file);

        for (p.depends) |ref| {
            const j = r.resolve(ref) orelse {
                diags.err("design/{s}:{d}: depends on `{s}`, which isn't a proposal", .{ p.file, p.depends_line, ref });
                continue;
            };
            const q = ps[j];
            if (j == i) diags.err("design/{s}:{d}: depends on itself", .{ p.file, p.depends_line });
            if (!fm.isId(ref) and filed(q)) diags.warn("design/{s}:{d}: `{s}` is #{d} now; zig build design -- fix rewrites it", .{ p.file, p.depends_line, ref, q.id.? });
            if (p.status == .implemented and q.status != .implemented) diags.err("design/{s}: implemented, but its dependency {s} is `{t}`", .{ p.file, label(q, &buf), q.status });
            if (p.status == .accepted and q.status == .declined) diags.err("design/{s}: accepted, but it depends on {s}, which was declined", .{ p.file, label(q, &buf) });
        }
        if (p.superseded_by) |ref| {
            if (r.resolve(ref)) |j| {
                if (!fm.isId(ref) and filed(ps[j])) diags.warn("design/{s}:{d}: `{s}` is #{d} now; zig build design -- fix rewrites it", .{ p.file, p.superseded_line, ref, ps[j].id.? });
            } else diags.err("design/{s}:{d}: superseded by `{s}`, which isn't a proposal", .{ p.file, p.superseded_line, ref });
        }
    }

    if (fcp.items.len > max_fcp) {
        const list = try std.mem.join(r.arena, ", ", fcp.items);
        diags.err("{d} proposals are in a final comment period, more than {d}: {s}", .{ fcp.items.len, max_fcp, list });
    }

    try checkCycles(r, diags);

    for (r.cases) |c| {
        const canonical = try fm.canonicalTags(r.arena, c.raw);
        if (!std.mem.eql(u8, canonical, c.raw)) diags.err("{s}:{d}: write the tags as [{s}], so zig build proposal -Dp finds them; zig build design -- fix rewrites them", .{ c.file, c.line, canonical });
    }
    for (r.cases) |c| for (c.tags) |t| {
        const j = r.resolve(t) orelse {
            diags.err("{s}:{d}: tag `{s}` isn't a proposal", .{ c.file, c.line, t });
            continue;
        };
        if (!fm.isId(t) and filed(ps[j])) diags.warn("{s}:{d}: tag `{s}` is #{d} now; zig build design -- fix rewrites it", .{ c.file, c.line, t, ps[j].id.? });
    };

    checkReadme(r, diags);
}

/// Reports each dependency cycle once, as a path.
fn checkCycles(r: Repo, diags: *Diags) !void {
    const n = r.ps.len;
    const color = try r.arena.alloc(u8, n); // 0 unvisited, 1 on the path, 2 done
    @memset(color, 0);
    const path = try r.arena.alloc(usize, n);
    for (0..n) |i| if (color[i] == 0) try visit(r, diags, color, path, 0, i);
}

fn visit(r: Repo, diags: *Diags, color: []u8, path: []usize, depth: usize, i: usize) !void {
    color[i] = 1;
    path[depth] = i;
    for (r.ps[i].depends) |ref| {
        const j = r.resolve(ref) orelse continue;
        if (j == i) continue; // reported as "depends on itself"
        if (color[j] == 1) {
            var s: std.ArrayList(u8) = .empty;
            var buf: [64]u8 = undefined;
            const start = std.mem.indexOfScalar(usize, path[0 .. depth + 1], j).?;
            for (path[start .. depth + 1]) |k| try s.print(r.arena, "{s} -> ", .{label(r.ps[k], &buf)});
            try s.appendSlice(r.arena, label(r.ps[j], &buf));
            diags.err("dependency cycle: {s}", .{s.items});
        } else if (color[j] == 0) try visit(r, diags, color, path, depth + 1, j);
    }
    color[i] = 2;
}

// ---- list, ready, graph, readme ----

/// What a proposal is waiting for: `ready` for an accepted proposal with
/// everything it depends on implemented, else the unimplemented ones.
fn state(r: Repo, p: Proposal, out: *std.ArrayList(u8)) !void {
    switch (p.status) {
        .implemented, .declined, .superseded => return,
        else => {},
    }
    var first = true;
    for (p.depends) |ref| {
        const j = r.resolve(ref) orelse continue;
        const q = r.ps[j];
        if (q.status == .implemented) continue;
        try out.appendSlice(r.arena, if (first) "needs " else ", ");
        try out.appendSlice(r.arena, q.slug);
        first = false;
    }
    if (first and p.status == .accepted) try out.appendSlice(r.arena, "ready");
}

fn isReady(r: Repo, p: Proposal) bool {
    if (p.status != .accepted) return false;
    for (p.depends) |ref| {
        const j = r.resolve(ref) orelse return false;
        if (r.ps[j].status != .implemented) return false;
    }
    return true;
}

fn hasArea(p: Proposal, area: []const u8) bool {
    for (p.areas) |a| if (std.mem.eql(u8, a, area)) return true;
    return false;
}

fn listCmd(r: Repo, w: *std.Io.Writer, status: ?Status, area: ?[]const u8, ready_only: bool) !void {
    const Row = struct { id: []const u8, slug: []const u8, status: []const u8, state: []const u8, title: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    try rows.append(r.arena, .{ .id = "ID", .slug = "SLUG", .status = "STATUS", .state = "STATE", .title = "TITLE" });
    for (r.ps) |p| {
        if (status) |s| if (p.status != s) continue;
        if (area) |a| if (!hasArea(p, a)) continue;
        if (ready_only and !isReady(r, p)) continue;
        var st: std.ArrayList(u8) = .empty;
        try state(r, p, &st);
        try rows.append(r.arena, .{
            .id = if (p.id) |id| try std.fmt.allocPrint(r.arena, "{d}", .{id}) else "-",
            .slug = p.slug,
            .status = @tagName(p.status),
            .state = if (st.items.len > 0) st.items else "-",
            .title = p.title,
        });
    }
    var widths = [_]usize{0} ** 4;
    for (rows.items) |row| {
        for ([_][]const u8{ row.id, row.slug, row.status, row.state }, 0..) |cell, k| widths[k] = @max(widths[k], cell.len);
    }
    for (rows.items) |row| {
        for ([_][]const u8{ row.id, row.slug, row.status, row.state }, 0..) |cell, k| {
            try w.writeAll(cell);
            try w.splatByteAll(' ', widths[k] - cell.len + 2);
        }
        try w.print("{s}\n", .{row.title});
    }
}

fn nodeId(arena: std.mem.Allocator, slug: []const u8) ![]const u8 {
    const out = try std.fmt.allocPrint(arena, "p_{s}", .{slug});
    std.mem.replaceScalar(u8, out, '-', '_');
    return out;
}

fn graph(r: Repo, w: *std.Io.Writer) !void {
    try w.writeAll("flowchart LR\n");
    try w.writeAll(
        \\  classDef draft stroke-dasharray: 4 3
        \\  classDef accepted stroke-width: 2px
        \\  classDef implemented fill:#dfd,stroke:#393
        \\  classDef closed fill:#eee,stroke:#999,color:#777
        \\
    );
    for (r.ps) |p| {
        if (p.slug.len == 0) continue;
        const class = switch (p.status) {
            .draft, .@"likely-accept", .@"likely-decline", .hold => "draft",
            .accepted => "accepted",
            .implemented => "implemented",
            .declined, .superseded => "closed",
        };
        const id = try nodeId(r.arena, p.slug);
        // #35; is Mermaid's escape for #.
        if (filed(p)) {
            try w.print("  {s}[\"#35;{d} {s}<br/>{t}\"]:::{s}\n", .{ id, p.id.?, p.slug, p.status, class });
        } else try w.print("  {s}[\"{s}<br/>{t}\"]:::{s}\n", .{ id, p.slug, p.status, class });
    }
    for (r.ps) |p| for (p.depends) |ref| {
        const j = r.resolve(ref) orelse continue;
        try w.print("  {s} --> {s}\n", .{ try nodeId(r.arena, r.ps[j].slug), try nodeId(r.arena, p.slug) });
    };
}

const readme_begin = "<!-- design:begin (zig build design -- readme) -->";
const readme_end = "<!-- design:end -->";

/// README.md's generated block: a table of proposals and the graph.
fn readmeBlock(r: Repo) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(r.arena);
    const w = &aw.writer;
    try w.print("{s}\n\n| Proposal | Status | State | Title |\n| --- | --- | --- | --- |\n", .{readme_begin});
    for (r.ps) |p| {
        var st: std.ArrayList(u8) = .empty;
        try state(r, p, &st);
        try w.print("| [{s}](design/{s}) | {t} | {s} | {s} |\n", .{ p.slug, p.file, p.status, st.items, p.title });
    }
    try w.writeAll("\n```mermaid\n");
    try graph(r, w);
    try w.print("```\n\n{s}", .{readme_end});
    return aw.written();
}

/// README.md with the block replaced, or null if it has no block.
fn readmeUpdated(r: Repo, text: []const u8) !?[]const u8 {
    const a = std.mem.indexOf(u8, text, readme_begin) orelse return null;
    const b = std.mem.indexOfPos(u8, text, a, readme_end) orelse return null;
    return try std.mem.concat(r.arena, u8, &.{ text[0..a], try readmeBlock(r), text[b + readme_end.len ..] });
}

fn checkReadme(r: Repo, diags: *Diags) void {
    const text = r.root.readFileAlloc(r.io, "README.md", r.arena, .limited(1 << 22)) catch return;
    const updated = (readmeUpdated(r, text) catch return) orelse return;
    if (!std.mem.eql(u8, updated, text)) diags.warn("README.md: the proposal table is out of date; zig build design -- readme rewrites it", .{});
}

/// Rewrites README.md's block if it has one; true if that changed it.
fn readmeRefresh(r: Repo) !bool {
    const text = try r.root.readFileAlloc(r.io, "README.md", r.arena, .limited(1 << 22));
    const updated = (try readmeUpdated(r, text)) orelse return false;
    if (std.mem.eql(u8, updated, text)) return false;
    try r.root.writeFile(r.io, .{ .sub_path = "README.md", .data = updated });
    return true;
}

fn readmeCmd(r: Repo) !void {
    const text = try r.root.readFileAlloc(r.io, "README.md", r.arena, .limited(1 << 22));
    const updated = (try readmeUpdated(r, text)) orelse fail("README.md has no {s} ... {s} block", .{ readme_begin, readme_end });
    if (std.mem.eql(u8, updated, text)) return;
    try r.root.writeFile(r.io, .{ .sub_path = "README.md", .data = updated });
}

// ---- fix ----

/// Rewrites references to proposals in `which` (by index) that are written
/// as slugs, in frontmatter and test tags, to their numbers. With `which`
/// null, every filed proposal. Returns the files it changed.
fn fix(r: Repo, which: ?usize) ![]const []const u8 {
    var changed: std.ArrayList([]const u8) = .empty;
    const Ctx = struct {
        r: Repo,
        which: ?usize,
        fn map(c: @This(), ref: []const u8) ?[]const u8 {
            if (fm.isId(ref)) return null;
            const j = c.r.resolve(ref) orelse return null;
            if (c.which) |w| if (w != j) return null;
            const p = c.r.ps[j];
            if (!filed(p)) return null;
            return std.fmt.allocPrint(c.r.arena, "{d}", .{p.id.?}) catch null;
        }
    };
    const ctx: Ctx = .{ .r = r, .which = which };

    for (r.ps) |p| {
        const path = try std.fmt.allocPrint(r.arena, "design/{s}", .{p.file});
        const text = try r.root.readFileAlloc(r.io, path, r.arena, .limited(1 << 22));
        if (try rewriteFrontmatter(r.arena, text, ctx)) |out| {
            try r.root.writeFile(r.io, .{ .sub_path = path, .data = out });
            try changed.append(r.arena, path);
        }
    }
    var seen: std.ArrayList([]const u8) = .empty;
    for (r.cases) |c| {
        var dup = false;
        for (seen.items) |s| dup = dup or std.mem.eql(u8, s, c.file);
        if (dup) continue;
        try seen.append(r.arena, c.file);
        const text = try r.root.readFileAlloc(r.io, c.file, r.arena, .limited(1 << 24));
        if (try rewriteTags(r.arena, text, ctx)) |out| {
            try r.root.writeFile(r.io, .{ .sub_path = c.file, .data = out });
            try changed.append(r.arena, c.file);
        }
    }
    return changed.items;
}

/// Rewrites a list or scalar of references; null if nothing changed.
fn mapRefs(arena: std.mem.Allocator, items: []const u8, ctx: anytype) !?[]const u8 {
    if (std.mem.trim(u8, items, " \t").len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    var any = false;
    var it = std.mem.splitScalar(u8, items, ',');
    var first = true;
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (!first) try out.appendSlice(arena, ", ");
        first = false;
        if (ctx.map(t)) |m| {
            try out.appendSlice(arena, m);
            any = true;
        } else try out.appendSlice(arena, t);
    }
    return if (any) out.items else null;
}

fn rewriteFrontmatter(arena: std.mem.Allocator, text: []const u8, ctx: anytype) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var any = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var fences: u8 = 0;
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        const cr = std.mem.endsWith(u8, line, "\r");
        const bare = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.eql(u8, bare, "---")) fences +|= 1;
        // Keys and values are read as frontmatter.parse reads them.
        if (fences == 1) if (std.mem.indexOfScalar(u8, bare, ':')) |colon| {
            const key = bare[0..colon];
            const value = std.mem.trim(u8, bare[colon + 1 ..], " \t");
            const list = std.mem.eql(u8, key, "depends") and value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']';
            const scalar = std.mem.eql(u8, key, "superseded-by") and value.len > 0;
            if (list or scalar) {
                const items = if (list) value[1 .. value.len - 1] else value;
                if (try mapRefs(arena, items, ctx)) |m| {
                    if (list) try out.print(arena, "depends: [{s}]", .{m}) else try out.print(arena, "superseded-by: {s}", .{m});
                    if (cr) try out.append(arena, '\r');
                    any = true;
                    continue;
                }
            }
        };
        try out.appendSlice(arena, line);
    }
    return if (any) out.items else null;
}

fn rewriteTags(arena: std.mem.Allocator, text: []const u8, ctx: anytype) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var any = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        if (testName(line)) |name| if (fm.testTags(name)) |tags| {
            const mapped = try mapRefs(arena, tags, ctx);
            const canonical = try fm.canonicalTags(arena, tags);
            const m: ?[]const u8 = mapped orelse if (std.mem.eql(u8, canonical, tags)) null else canonical;
            if (m) |new_tags| {
                const start = @intFromPtr(tags.ptr) - @intFromPtr(line.ptr);
                try out.print(arena, "{s}{s}{s}", .{ line[0..start], new_tags, line[start + tags.len ..] });
                any = true;
                continue;
            }
        };
        try out.appendSlice(arena, line);
    }
    return if (any) out.items else null;
}

// ---- new ----

/// Today's date in UTC.
fn today(io: std.Io) [10]u8 {
    const secs: u64 = @intCast(@max(0, std.Io.Clock.real.now(io).toSeconds()));
    const day = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    var out: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), @as(u8, md.day_index) + 1 }) catch unreachable;
    return out;
}

/// The template with its frontmatter replaced and its title filled in.
fn fromTemplate(arena: std.mem.Allocator, template: []const u8, slug: []const u8, title: []const u8, author: []const u8, date: []const u8) ![]const u8 {
    var body = template;
    if (std.mem.startsWith(u8, body, "---\n")) {
        if (std.mem.indexOf(u8, body[4..], "\n---\n")) |end| body = body[4 + end + 5 ..];
    }
    const filled = try std.mem.replaceOwned(u8, arena, body, "[Title]", title);
    return std.fmt.allocPrint(arena,
        \\---
        \\slug: {s}
        \\title: {s}
        \\status: draft
        \\created: {s}
        \\authors: [{s}]
        \\depends: []
        \\areas: []
        \\---
        \\{s}
    , .{ slug, title, date, author, filled });
}

fn newCmd(r: Repo, gpa: std.mem.Allocator, args: []const []const u8) !void {
    var slug: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var author: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--title") and i + 1 < args.len) {
            i += 1;
            title = args[i];
        } else if (std.mem.eql(u8, args[i], "--author") and i + 1 < args.len) {
            i += 1;
            author = args[i];
        } else if (slug == null and args[i].len > 0 and args[i][0] != '-') {
            slug = args[i];
        } else fail("new: unexpected `{s}`\n{s}", .{ args[i], usage });
    }
    const s = slug orelse fail("new: which slug?\n{s}", .{usage});
    if (!fm.validSlug(s)) fail("new: bad slug `{s}`: lowercase words of letters and digits joined by dashes, not all digits", .{s});
    if (r.resolve(s) != null) fail("new: `{s}` is already a proposal", .{s});
    const t = title orelse try titleFromSlug(r.arena, s);
    if (fm.plainScalarProblem(t)) |why| fail("new: the title can't be used as is: {s}, which YAML would read differently", .{why});
    const a = author orelse (run(gpa, r.io, r.arena, &.{ "gh", "api", "user", "--jq", ".login" }) catch
        fail("new: couldn't get your GitHub login from gh; pass --author LOGIN", .{}));
    const template = r.root.readFileAlloc(r.io, "design/TEMPLATE.md", r.arena, .limited(1 << 20)) catch |err|
        fail("new: design/TEMPLATE.md: {t}", .{err});
    // The local date where `date` exists, else UTC.
    var utc = today(r.io);
    const local = run(gpa, r.io, r.arena, &.{ "date", "+%Y-%m-%d" }) catch "";
    const date = if (std.mem.trim(u8, local, " \n").len == 10) std.mem.trim(u8, local, " \n") else &utc;
    const text = try fromTemplate(r.arena, template, s, t, std.mem.trim(u8, a, " \n"), date);
    const path = try std.fmt.allocPrint(r.arena, "design/{s}.md", .{s});
    try r.root.writeFile(r.io, .{ .sub_path = path, .data = text, .flags = .{ .exclusive = true } });
    std.debug.print("{s}\n", .{path});
}

fn titleFromSlug(arena: std.mem.Allocator, slug: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, slug);
    std.mem.replaceScalar(u8, out, '-', ' ');
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

// ---- file ----

/// The text of the Abstract section, for the issue body.
fn abstract(body: []const u8) []const u8 {
    const h = std.mem.indexOf(u8, body, "\n## Abstract\n") orelse return "";
    const rest = body[h + "\n## Abstract\n".len ..];
    const end = std.mem.indexOf(u8, rest, "\n## ") orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " \n");
}

/// Inserts `id: N` before the `slug:` line of the frontmatter.
fn withId(arena: std.mem.Allocator, text: []const u8, id: u32) ![]const u8 {
    const at = std.mem.indexOf(u8, text, "\nslug:") orelse return error.NoSlugLine;
    return std.fmt.allocPrint(arena, "{s}\nid: {d}{s}", .{ text[0..at], id, text[at..] });
}

fn fileCmd(r: Repo, gpa: std.mem.Allocator, args: []const []const u8) !void {
    var slug: ?[]const u8 = null;
    var yes = false;
    var dry_run = false;
    var existing: ?u32 = null;
    var k: usize = 0;
    while (k < args.len) : (k += 1) {
        const a = args[k];
        if (std.mem.eql(u8, a, "--yes")) {
            yes = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--issue") and k + 1 < args.len) {
            k += 1;
            existing = std.fmt.parseInt(u32, args[k], 10) catch fail("file: --issue needs an issue number, not `{s}`", .{args[k]});
            if (existing == 0) fail("file: --issue needs an issue number, not 0", .{});
        } else if (slug == null and a.len > 0 and a[0] != '-') {
            slug = a;
        } else fail("file: unexpected `{s}`\n{s}", .{ a, usage });
    }
    const s = slug orelse fail("file: which slug?\n{s}", .{usage});
    const i = r.resolve(s) orelse fail("file: `{s}` isn't a proposal", .{s});
    const p = r.ps[i];
    if (fm.isId(s) or p.id != null) fail("file: {s} is already filed", .{s});
    if (p.status != .draft) fail("file: {s} is `{t}`, not a draft", .{ s, p.status });
    if (!p.ok) fail("file: design/{s} has frontmatter errors; run zig build design -- check", .{p.file});
    const summary = abstract(p.body);
    if (summary.len == 0) fail("file: design/{s} has no Abstract to put in the issue", .{p.file});
    const title = try std.fmt.allocPrint(r.arena, "proposal: {s}", .{p.title});
    if (existing) |id| {
        if (r.resolve(try std.fmt.allocPrint(r.arena, "{d}", .{id}))) |j| fail("file: #{d} is already design/{s}", .{ id, r.ps[j].file });
        std.debug.print("numbering design/{s} for the existing issue #{d}; nothing is created on GitHub\n", .{ p.file, id });
        if (dry_run) return;
        return number(r, gpa, p, id);
    }

    std.debug.print(
        \\This creates a GitHub issue with gh, as the account gh is logged in as:
        \\
        \\  title:  {s}
        \\  label:  Proposal
        \\  body:   the Abstract of design/{s}, and a link to the file
        \\
        \\then renames design/{s} to design/NNNN-{s}.md (NNNN is the issue number),
        \\sets its id, rewrites references to `{s}` as the number, and commits.
        \\
    , .{ title, p.file, p.file, p.slug, p.slug });
    if (dry_run) {
        std.debug.print("\n--dry-run: nothing changed. The issue body would be:\n\n{s}\n", .{summary});
        return;
    }
    if (!yes and !try confirm(r.io, "File it? [y/N] ")) fail("file: not filed", .{});

    const repo_info = run(gpa, r.io, r.arena, &.{ "gh", "api", "repos/{owner}/{repo}", "--jq", ".html_url + \" \" + .default_branch" }) catch
        fail("file: gh couldn't read the repository; is gh logged in?", .{});
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, repo_info, " \n"), ' ');
    const html = parts.next() orelse "";
    const branch = parts.next() orelse "main";

    const body_arg = try std.fmt.allocPrint(r.arena, "body={s}", .{summary});
    const title_arg = try std.fmt.allocPrint(r.arena, "title={s}", .{title});
    const out = run(gpa, r.io, r.arena, &.{ "gh", "api", "repos/{owner}/{repo}/issues", "-f", title_arg, "-f", body_arg, "-f", "labels[]=Proposal", "--jq", ".number" }) catch
        fail("file: gh couldn't create the issue", .{});
    const id = std.fmt.parseInt(u32, std.mem.trim(u8, out, " \n"), 10) catch fail("file: unexpected answer from gh: {s}", .{out});
    std.debug.print("created issue #{d}\n", .{id});

    var link_buf: [256]u8 = undefined;
    const new_file = std.fmt.bufPrint(&link_buf, "{d:0>4}-{s}.md", .{ id, p.slug }) catch unreachable;
    const linked = try std.fmt.allocPrint(r.arena, "body={s}\n\nDesign doc: {s}/blob/{s}/design/{s} (on {s} once merged)", .{ summary, html, branch, new_file, branch });
    const patch_path = try std.fmt.allocPrint(r.arena, "repos/{{owner}}/{{repo}}/issues/{d}", .{id});
    _ = run(gpa, r.io, r.arena, &.{ "gh", "api", "-X", "PATCH", patch_path, "-f", linked }) catch
        std.debug.print("warning: couldn't add the design doc link to #{d}\n", .{id});
    try number(r, gpa, p, id);
}

/// Renames a draft to its numbered file, sets its id, rewrites references
/// to its slug as the number, and commits those files.
fn number(r: Repo, gpa: std.mem.Allocator, p: Proposal, id: u32) !void {
    var name_buf: [256]u8 = undefined;
    const new_file = std.fmt.bufPrint(&name_buf, "{d:0>4}-{s}.md", .{ id, p.slug }) catch unreachable;
    const old_path = try std.fmt.allocPrint(r.arena, "design/{s}", .{p.file});
    const new_path = try std.fmt.allocPrint(r.arena, "design/{s}", .{new_file});
    // A draft that was never committed has nothing to remove from git.
    const tracked = blk: {
        const out = run(gpa, r.io, r.arena, &.{ "git", "ls-files", "--", old_path }) catch break :blk false;
        break :blk std.mem.trim(u8, out, " \n").len > 0;
    };

    const text = try r.root.readFileAlloc(r.io, old_path, r.arena, .limited(1 << 22));
    try r.root.writeFile(r.io, .{ .sub_path = new_path, .data = try withId(r.arena, text, id), .flags = .{ .exclusive = true } });
    try r.root.deleteFile(r.io, old_path);

    var changed: std.ArrayList([]const u8) = .empty;
    try changed.append(r.arena, new_path);
    for (try relinkFiles(r, gpa, p.file, new_file)) |f| try addOnce(r.arena, &changed, f);

    // Reload, so the renamed proposal resolves by its number.
    var diags: Diags = .{ .gpa = r.arena };
    const r2 = try Repo.load(r.arena, r.io, r.root, &diags);
    for (try fix(r2, r2.resolve(p.slug))) |f| try addOnce(r.arena, &changed, f);
    const r3 = try Repo.load(r.arena, r.io, r.root, &diags);
    if (readmeRefresh(r3) catch false) try addOnce(r.arena, &changed, "README.md");

    var add: std.ArrayList([]const u8) = .empty;
    try add.appendSlice(r.arena, &.{ "git", "add", "--" });
    try add.appendSlice(r.arena, changed.items);
    _ = run(gpa, r.io, r.arena, add.items) catch fail("file: git add failed; the files are changed but not committed", .{});
    if (tracked) _ = run(gpa, r.io, r.arena, &.{ "git", "rm", "-q", "--cached", "--", old_path }) catch
        fail("file: git rm of {s} failed; the other changes are staged", .{old_path});
    const msg = try std.fmt.allocPrint(r.arena, "design: file {s} as #{d}", .{ p.slug, id });
    var commit: std.ArrayList([]const u8) = .empty;
    try commit.appendSlice(r.arena, &.{ "git", "commit", "-q", "-m", msg, "--" });
    if (tracked) try commit.append(r.arena, old_path);
    try commit.appendSlice(r.arena, changed.items);
    _ = run(gpa, r.io, r.arena, commit.items) catch fail("file: git commit failed; the changes are staged", .{});
    std.debug.print("{s}\n", .{msg});
}

fn addOnce(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), item: []const u8) !void {
    for (list.items) |x| if (std.mem.eql(u8, x, item)) return;
    try list.append(arena, item);
}

/// Rewrites links to a renamed proposal in the files git tracks:
/// `design/<old>` anywhere, and `](<old>` in design/ itself. Returns the
/// files it changed.
fn relinkFiles(r: Repo, gpa: std.mem.Allocator, old: []const u8, new: []const u8) ![]const []const u8 {
    var changed: std.ArrayList([]const u8) = .empty;
    const files = run(gpa, r.io, r.arena, &.{ "git", "ls-files" }) catch return changed.items;
    const long_old = try std.fmt.allocPrint(r.arena, "design/{s}", .{old});
    const long_new = try std.fmt.allocPrint(r.arena, "design/{s}", .{new});
    const short_old = try std.fmt.allocPrint(r.arena, "]({s}", .{old});
    const short_new = try std.fmt.allocPrint(r.arena, "]({s}", .{new});
    var it = std.mem.tokenizeScalar(u8, files, '\n');
    while (it.next()) |path| {
        if (std.mem.startsWith(u8, path, "third_party/") or std.mem.startsWith(u8, path, "tools/testdata/")) continue;
        const text = r.root.readFileAlloc(r.io, path, r.arena, .limited(1 << 24)) catch continue;
        if (std.mem.indexOfScalar(u8, text, 0) != null) continue; // binary
        var out = try std.mem.replaceOwned(u8, r.arena, text, long_old, long_new);
        if (std.mem.startsWith(u8, path, "design/")) out = try std.mem.replaceOwned(u8, r.arena, out, short_old, short_new);
        if (std.mem.eql(u8, out, text)) continue;
        try r.root.writeFile(r.io, .{ .sub_path = path, .data = out });
        try changed.append(r.arena, path);
    }
    return changed.items;
}

fn confirm(io: std.Io, prompt: []const u8) !bool {
    std.debug.print("{s}", .{prompt});
    var buf: [256]u8 = undefined;
    var rd = std.Io.File.stdin().readerStreaming(io, &buf);
    const line = (rd.interface.takeDelimiter('\n') catch return false) orelse return false;
    const a = std.mem.trim(u8, line, " \r\t");
    return std.ascii.eqlIgnoreCase(a, "y") or std.ascii.eqlIgnoreCase(a, "yes");
}

/// Runs a command and returns its stdout; fails unless it exits 0.
fn run(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const res = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("{s}", .{res.stderr});
            return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
    return arena.dupe(u8, res.stdout);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("design: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    const args = argv[1..];
    if (args.len == 0 or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) {
        std.debug.print("{s}", .{usage});
        return if (args.len == 0) 2 else 0;
    }
    const cmd = args[0];
    const rest = args[1..];

    var diags: Diags = .{ .gpa = arena };
    const r = try Repo.load(arena, io, std.Io.Dir.cwd(), &diags);

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &out.interface;
    defer w.flush() catch {};

    if (std.mem.eql(u8, cmd, "check")) {
        try check(r, &diags);
        for (diags.errors.items) |m| std.debug.print("error: {s}\n", .{m});
        for (diags.warnings.items) |m| std.debug.print("warning: {s}\n", .{m});
        if (diags.errors.items.len > 0) return 1;
        try w.print("ok: {d} proposals, {d} tagged cases\n", .{ r.ps.len, r.cases.len });
        return 0;
    }
    // Other commands work on what parsed, but say what didn't.
    for (diags.errors.items) |m| std.debug.print("error: {s}\n", .{m});
    if (std.mem.eql(u8, cmd, "list")) {
        var status: ?Status = null;
        var area: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "--status") and i + 1 < rest.len) {
                i += 1;
                status = std.meta.stringToEnum(Status, rest[i]) orelse fail("list: unknown status `{s}`", .{rest[i]});
            } else if (std.mem.eql(u8, rest[i], "--area") and i + 1 < rest.len) {
                i += 1;
                area = rest[i];
            } else fail("list: unexpected `{s}`\n{s}", .{ rest[i], usage });
        }
        try listCmd(r, w, status, area, false);
    } else if (std.mem.eql(u8, cmd, "ready")) {
        try listCmd(r, w, null, null, true);
    } else if (std.mem.eql(u8, cmd, "graph")) {
        try graph(r, w);
    } else if (std.mem.eql(u8, cmd, "readme")) {
        try readmeCmd(r);
    } else if (std.mem.eql(u8, cmd, "new")) {
        try newCmd(r, init.gpa, rest);
    } else if (std.mem.eql(u8, cmd, "file")) {
        try fileCmd(r, init.gpa, rest);
    } else if (std.mem.eql(u8, cmd, "fix")) {
        for (try fix(r, null)) |f| try w.print("{s}\n", .{f});
    } else {
        std.debug.print("design: unknown command `{s}`\n{s}", .{ cmd, usage });
        return 2;
    }
    return 0;
}

// ---- tests ----

// Runs check over each fixture in tools/testdata/check. A fixture is a
// txtar-style file: comment lines first, each `error: text` or
// `warning: text` that check must report (as a substring), then files as
// `-- path --` followed by their contents. The fixture must produce
// exactly the listed messages.
test "check fixtures" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "tools/testdata/check", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".txtar")) continue;
        count += 1;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const text = try dir.readFileAlloc(io, e.name, arena, .limited(1 << 20));

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var want_err: std.ArrayList([]const u8) = .empty;
        var want_warn: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var cur: ?[]const u8 = null;
        var content: std.ArrayList(u8) = .empty;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "-- ") and std.mem.endsWith(u8, line, " --")) {
                if (cur) |path| try writeFixture(io, tmp.dir, path, content.items);
                cur = line[3 .. line.len - 3];
                content = .empty;
            } else if (cur != null) {
                try content.appendSlice(arena, line);
                try content.append(arena, '\n');
            } else if (std.mem.startsWith(u8, line, "error: ")) {
                try want_err.append(arena, line["error: ".len..]);
            } else if (std.mem.startsWith(u8, line, "warning: ")) {
                try want_warn.append(arena, line["warning: ".len..]);
            }
        }
        if (cur) |path| try writeFixture(io, tmp.dir, path, content.items);

        var diags: Diags = .{ .gpa = arena };
        const r = try Repo.load(arena, io, tmp.dir, &diags);
        try check(r, &diags);
        expectMessages(e.name, "error", want_err.items, diags.errors.items) catch |err| return err;
        expectMessages(e.name, "warning", want_warn.items, diags.warnings.items) catch |err| return err;
    }
    try std.testing.expect(count > 0);
}

fn writeFixture(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

fn expectMessages(fixture: []const u8, kind: []const u8, want: []const []const u8, got: []const []const u8) !void {
    var ok = want.len == got.len;
    for (want) |w| {
        var found = false;
        for (got) |g| found = found or std.mem.indexOf(u8, g, w) != null;
        ok = ok and found;
    }
    if (ok) return;
    std.debug.print("{s}: {s}s don't match\n  want:\n", .{ fixture, kind });
    for (want) |w| std.debug.print("    {s}\n", .{w});
    std.debug.print("  got:\n", .{});
    for (got) |g| std.debug.print("    {s}\n", .{g});
    return error.TestUnexpectedResult;
}

test "fix rewrites slug references to numbers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Ctx = struct {
        fn map(_: @This(), ref: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, ref, "devsrv")) "12" else null;
        }
    };
    const fmtext = "---\nslug: gfx\ndepends: [devsrv, 7]\n---\ndepends: [devsrv]\n";
    try std.testing.expectEqualStrings("---\nslug: gfx\ndepends: [12, 7]\n---\ndepends: [devsrv]\n", (try rewriteFrontmatter(arena, fmtext, Ctx{})).?);
    const tests = "test \"ramfs posts to /srv [devsrv]\" {\n    const x = 1;\n}\n";
    try std.testing.expectEqualStrings("test \"ramfs posts to /srv [12]\" {\n    const x = 1;\n}\n", (try rewriteTags(arena, tests, Ctx{})).?);
    try std.testing.expect(try rewriteTags(arena, "test \"x [baseline]\" {\n", Ctx{}) == null);
    // Spacing the parser accepts, and CRLF lines.
    try std.testing.expectEqualStrings("---\r\ndepends: [12]\r\n---\r\n", (try rewriteFrontmatter(arena, "---\r\ndepends:  [devsrv] \r\n---\r\n", Ctx{})).?);
    try std.testing.expectEqualStrings("---\nsuperseded-by: 12\n---\n", (try rewriteFrontmatter(arena, "---\nsuperseded-by:devsrv\n---\n", Ctx{})).?);
    try std.testing.expect(try rewriteFrontmatter(arena, "---\ndepends: []\n---\n", Ctx{}) == null);
    // Tags are rewritten to the canonical spacing.
    try std.testing.expectEqualStrings("test \"x [baseline, 12]\" {\n", (try rewriteTags(arena, "test \"x [baseline,devsrv]\" {\n", Ctx{})).?);
}

test "new fills the template" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try fromTemplate(arena_state.allocator(), "---\nslug: x\n---\n\n# Proposal: [Title]\n", "kvm", "KVM backend", "progrium", "2026-11-03");
    try std.testing.expectEqualStrings(
        \\---
        \\slug: kvm
        \\title: KVM backend
        \\status: draft
        \\created: 2026-11-03
        \\authors: [progrium]
        \\depends: []
        \\areas: []
        \\---
        \\
        \\# Proposal: KVM backend
        \\
    , out);
}

test "file helpers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("Short.", abstract("\n# P\n\n## Abstract\n\nShort.\n\n## Background\n\nLong.\n"));
    try std.testing.expectEqualStrings("---\nid: 9\nslug: a\n---\n", try withId(arena_state.allocator(), "---\nslug: a\n---\n", 9));
}
