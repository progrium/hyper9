//! The design tool: lists, checks, proposes, and signs the proposals under
//! design/ (design/proposals.md, design/proposal-flow.md). Run as
//! `zig build design -- <command>` from the repository root.

const std = @import("std");
const fm = @import("frontmatter.zig");
const Proposal = fm.Proposal;
const Status = fm.Status;
const Diags = fm.Diags;

const usage =
    \\usage: zig build design -- <command> [args]
    \\
    \\  list [--status S] [--area A]    proposals, their status, and ready, in progress, stalled, or what they need
    \\  ready                           accepted proposals with no branch whose dependencies are all implemented
    \\  graph                           the dependency graph, as Mermaid
    \\  status                          rewrite design/STATUS.md, the proposal table and graph
    \\  new <slug> [--title T] [--author LOGIN]
    \\                                  start a draft from design/TEMPLATE.md
    \\  propose <slug> [--yes] [--dry-run] [--issue N]
    \\                                  open its GitHub issue (or use issue N), set its id, make it proposed, and commit
    \\  log <slug>                      its status and branch changes, from git
    \\  sign <slug or spec>             sign a doc you've reviewed (interactive; see design/README.md, Signature)
    \\  check                           validate the proposals, test tags, signatures, and links to design/
    \\
;

/// Days without a commit before a branch's work counts as stalled.
const stalled_days = 7;

/// An integration or web case and its tags (`test "name [a, b]"`).
const Case = struct {
    file: []const u8,
    line: u32,
    name: []const u8,
    tags: []const []const u8,
    /// The tags as written, between the brackets.
    raw: []const u8,
};

/// A person who can sign, from design/SIGNERS.
const Signer = struct { login: []const u8, name: []const u8 };

/// The repository as the tool sees it.
const Repo = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    ps: []Proposal,
    cases: []Case,
    /// Text files to check links in, relative to the root.
    files: []const []const u8,
    /// Seconds since each branch's last commit, by name, or null when
    /// branches weren't read (no git).
    branches: ?std.StringHashMapUnmanaged(i64),
    /// From design/SIGNERS, or null if there's no such file.
    signers: ?[]const Signer,

    const Source = enum {
        /// The files git tracks, and its branches.
        git,
        /// Every file under the root, and branch ages from a `.branches`
        /// file (`name days` per line), for the check fixtures.
        walk,
    };

    fn load(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir, diags: *Diags, source: Source) !Repo {
        var r: Repo = .{ .arena = arena, .io = io, .root = root, .ps = &.{}, .cases = &.{}, .files = &.{}, .branches = null, .signers = null };
        r.cases = try scanCases(arena, io, root);
        r.signers = try loadSigners(arena, io, root);
        switch (source) {
            .git => {
                r.files = gitFiles(gpa, io, arena) catch &.{};
                r.branches = gitBranches(gpa, io, arena) catch null;
            },
            .walk => {
                r.files = try walkFiles(arena, gpa, io, root);
                r.branches = try fixtureBranches(arena, io, root);
            },
        }
        var design = root.openDir(io, "design", .{ .iterate = true }) catch |err| {
            diags.err("design/: {t}", .{err});
            return r;
        };
        defer design.close(io);
        r.ps = try fm.scan(arena, io, design, diags);
        return r;
    }

    fn resolve(r: Repo, ref: []const u8) ?usize {
        return fm.resolve(r.ps, ref);
    }
};

/// Cases with tags, from tests/*.zig and tests/web/*.mjs.
fn scanCases(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![]Case {
    var out: std.ArrayList(Case) = .empty;
    for ([_]struct { dir: []const u8, ext: []const u8 }{ .{ .dir = "tests", .ext = ".zig" }, .{ .dir = "tests/web", .ext = ".mjs" } }) |src| {
        var dir = root.openDir(io, src.dir, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, src.ext)) continue;
            const file = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src.dir, e.name });
            const text = try dir.readFileAlloc(io, e.name, arena, .limited(1 << 24));
            var lines = std.mem.splitScalar(u8, text, '\n');
            var lineno: u32 = 0;
            while (lines.next()) |line| {
                lineno += 1;
                const name = fm.caseName(line) orelse continue;
                const tags = fm.testTags(name) orelse continue;
                var list: std.ArrayList([]const u8) = .empty;
                var ts = std.mem.splitScalar(u8, tags, ',');
                while (ts.next()) |t| try list.append(arena, std.mem.trim(u8, t, " "));
                try out.append(arena, .{ .file = file, .line = lineno, .name = name, .tags = list.items, .raw = tags });
            }
        }
    }
    return out.items;
}

fn loadSigners(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !?[]const Signer {
    const text = root.readFileAlloc(io, "design/SIGNERS", arena, .limited(1 << 16)) catch return null;
    var out: std.ArrayList(Signer) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        try out.append(arena, .{ .login = line[0..sp], .name = std.mem.trim(u8, line[sp + 1 ..], " \t") });
    }
    return out.items;
}

fn gitFiles(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator) ![]const []const u8 {
    const out = try run(gpa, io, arena, &.{ "git", "ls-files" });
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, out, '\n');
    while (it.next()) |f| try list.append(arena, f);
    return list.items;
}

/// Local branches and origin's, by name, with the age of their last commit.
fn gitBranches(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator) !std.StringHashMapUnmanaged(i64) {
    const out = try run(gpa, io, arena, &.{ "git", "for-each-ref", "--format=%(refname) %(committerdate:unix)", "refs/heads", "refs/remotes/origin" });
    const now = std.Io.Clock.real.now(io).toSeconds();
    var map: std.StringHashMapUnmanaged(i64) = .empty;
    var it = std.mem.tokenizeScalar(u8, out, '\n');
    while (it.next()) |line| {
        const sp = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        const ref = line[0..sp];
        const name = if (std.mem.startsWith(u8, ref, "refs/heads/")) ref["refs/heads/".len..] else if (std.mem.startsWith(u8, ref, "refs/remotes/origin/")) ref["refs/remotes/origin/".len..] else continue;
        if (std.mem.eql(u8, name, "HEAD")) continue;
        const when = std.fmt.parseInt(i64, line[sp + 1 ..], 10) catch continue;
        const age = now - when;
        const e = try map.getOrPut(arena, name);
        if (!e.found_existing or age < e.value_ptr.*) e.value_ptr.* = age;
    }
    return map;
}

fn fixtureBranches(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !?std.StringHashMapUnmanaged(i64) {
    const text = root.readFileAlloc(io, ".branches", arena, .limited(1 << 16)) catch return null;
    var map: std.StringHashMapUnmanaged(i64) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const name = parts.next() orelse continue;
        const days = std.fmt.parseInt(i64, parts.next() orelse continue, 10) catch continue;
        try map.put(arena, name, days * std.time.s_per_day);
    }
    return map;
}

fn walkFiles(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var top = try root.openDir(io, ".", .{ .iterate = true });
    defer top.close(io);
    var w = try top.walk(gpa);
    defer w.deinit();
    while (try w.next(io)) |e| {
        if (e.kind != .file) continue;
        try list.append(arena, try arena.dupe(u8, e.path));
    }
    return list.items;
}

// ---- check ----

/// Validates everything `check` covers. Errors and warnings go to `diags`.
fn check(r: Repo, diags: *Diags) !void {
    const ps = r.ps;
    var buf: [256]u8 = undefined;

    for (ps, 0..) |p, i| {
        if (fm.validSlug(p.slug)) {
            const want = p.expectedFile(&buf);
            if (!std.mem.eql(u8, want, p.file)) diags.err("design/{s}: should be named design/{s}", .{ p.file, want });
        }
        for (ps[0..i]) |q| {
            if (p.slug.len > 0 and std.mem.eql(u8, p.slug, q.slug)) diags.err("design/{s}: slug `{s}` is also used by design/{s}", .{ p.file, p.slug, q.file });
            if (p.id != null and p.id == q.id) diags.err("design/{s}: id {d} is also used by design/{s}", .{ p.file, p.id.?, q.file });
        }
        if (p.status == .proposed and p.id == null) diags.err("design/{s}: proposed, but it has no id; zig build design -- propose {s} opens its issue", .{ p.file, p.slug });
        if (p.status == .superseded and p.superseded_by == null) diags.err("design/{s}: superseded, but `superseded-by` isn't set", .{p.file});
        if (p.status != .superseded and p.superseded_by != null) diags.err("design/{s}:{d}: `superseded-by` is set, but the status is `{t}`", .{ p.file, p.superseded_line, p.status });
        if (p.status == .declined and !hasSection(p.body, "Declined")) diags.err("design/{s}: declined, but it has no `## Declined` section giving the reason", .{p.file});

        // Branches.
        if (p.status == .implemented and !(p.branch.len == 1 and p.onMain()))
            diags.err("design/{s}: implemented, so `branch` must be [main]", .{p.file});
        if (p.status != .implemented and p.onMain())
            diags.err("design/{s}:{d}: `branch` has main, but the status is `{t}`; main is only for implemented proposals", .{ p.file, p.branch_line, p.status });
        if (r.branches) |bs| for (p.branch) |b| {
            if (std.mem.eql(u8, b, "main")) continue;
            if (!bs.contains(b)) diags.warn("design/{s}:{d}: branch `{s}` wasn't found; fetch it, or take it out of `branch` if it's gone", .{ p.file, p.branch_line, b });
        };

        // Done criteria.
        if (hasSection(p.body, "Done when")) diags.err("design/{s}: `## Done when` is now `## Done criteria`, a checklist", .{p.file});
        if (try fm.doneCriteria(r.arena, p.body)) |items| {
            const body_line = bodyStart(p);
            var settled: usize = 0;
            for (items) |item| switch (item.mark) {
                .none => diags.err("design/{s}:{d}: a Done criteria item must be a checkbox: `- [ ]`, `- [x]`, or `- [~] Waived: why`", .{ p.file, body_line + item.line }),
                .open => if (p.status == .implemented) diags.err("design/{s}:{d}: implemented, but this Done criteria item isn't checked; check it, or waive it with `- [~] Waived: why`", .{ p.file, body_line + item.line }),
                .done, .waived => settled += 1,
            };
            if ((p.status == .proposed or p.status == .accepted) and items.len > 0 and settled == items.len)
                diags.warn("design/{s}: every Done criteria item is checked or waived, but it's `{t}`; is it implemented?", .{ p.file, p.status });
        }

        // References.
        for (p.depends) |ref| {
            if (fm.isId(ref)) {
                diags.err("design/{s}:{d}: depends on `{s}`; refer to proposals by slug{s}", .{ p.file, p.depends_line, ref, try bySlug(r, ref) });
                continue;
            }
            const j = r.resolve(ref) orelse {
                diags.err("design/{s}:{d}: depends on `{s}`, which isn't a proposal", .{ p.file, p.depends_line, ref });
                continue;
            };
            const q = ps[j];
            if (j == i) diags.err("design/{s}:{d}: depends on itself", .{ p.file, p.depends_line });
            if (p.status == .implemented and q.status != .implemented) diags.err("design/{s}: implemented, but its dependency {s} is `{t}`", .{ p.file, q.slug, q.status });
            if (p.status == .accepted and q.status == .declined) diags.err("design/{s}: accepted, but it depends on {s}, which was declined", .{ p.file, q.slug });
        }
        if (p.superseded_by) |ref| {
            if (fm.isId(ref)) {
                diags.err("design/{s}:{d}: superseded by `{s}`; refer to proposals by slug{s}", .{ p.file, p.superseded_line, ref, try bySlug(r, ref) });
            } else if (r.resolve(ref) == null) diags.err("design/{s}:{d}: superseded by `{s}`, which isn't a proposal", .{ p.file, p.superseded_line, ref });
        }

        // Signatures.
        const path = try std.fmt.allocPrint(r.arena, "design/{s}", .{p.file});
        checkSignatures(r, diags, path, p.body, bodyStart(p));
    }
    if (r.root.readFileAlloc(r.io, "SPEC.md", r.arena, .limited(1 << 24))) |spec| {
        checkSignatures(r, diags, "SPEC.md", spec, 0);
    } else |_| {}

    try checkCycles(r, diags);

    for (r.cases) |c| {
        const canonical = try fm.canonicalTags(r.arena, c.raw);
        if (!std.mem.eql(u8, canonical, c.raw)) diags.err("{s}:{d}: write the tags as [{s}], so zig build proposal -Dp finds them", .{ c.file, c.line, canonical });
    }
    for (r.cases) |c| for (c.tags) |t| {
        if (fm.isId(t)) {
            diags.err("{s}:{d}: tag `{s}`; tag cases with a proposal's slug{s}", .{ c.file, c.line, t, try bySlug(r, t) });
        } else if (r.resolve(t) == null) diags.err("{s}:{d}: tag `{s}` isn't a proposal", .{ c.file, c.line, t });
    };

    try checkLinks(r, diags);
}

/// `, `slug`` for a number that's some proposal's id, for messages.
fn bySlug(r: Repo, ref: []const u8) ![]const u8 {
    const j = r.resolve(ref) orelse return "";
    return std.fmt.allocPrint(r.arena, " (#{s} is `{s}`)", .{ ref, r.ps[j].slug });
}

fn bodyStart(p: Proposal) u32 {
    return p.body_offset;
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
            const start = std.mem.indexOfScalar(usize, path[0 .. depth + 1], j).?;
            for (path[start .. depth + 1]) |k| try s.print(r.arena, "{s} -> ", .{r.ps[k].slug});
            try s.appendSlice(r.arena, r.ps[j].slug);
            diags.err("dependency cycle: {s}", .{s.items});
        } else if (color[j] == 0) try visit(r, diags, color, path, depth + 1, j);
    }
    color[i] = 2;
}

// ---- signatures ----

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

const Signature = struct {
    /// `Nov 11, 2026`.
    date: []const u8,
    name: []const u8,
};

/// Parses a signature line in either form: `Mon D, YYYY · Name, h.d.a.`
/// with h.d.a. as an `<abbr>` or as a link to README's Signature section.
fn parseSignature(line: []const u8) ?Signature {
    const sep = " · ";
    const at = std.mem.indexOf(u8, line, sep) orelse return null;
    const date = line[0..at];
    if (!validSigDate(date)) return null;
    const rest = line[at + sep.len ..];
    // The abbr's title has commas of its own, so find the mark, not a comma.
    const comma = std.mem.indexOf(u8, rest, ", <abbr ") orelse std.mem.lastIndexOf(u8, rest, ", ") orelse return null;
    const name = rest[0..comma];
    const mark = rest[comma + 2 ..];
    if (name.len == 0) return null;
    const link = std.mem.eql(u8, mark, "[h.d.a.](README.md#signature)") or std.mem.eql(u8, mark, "[h.d.a.](design/README.md#signature)");
    const abbr = std.mem.startsWith(u8, mark, "<abbr title=\"") and std.mem.endsWith(u8, mark, "\">h.d.a.</abbr>");
    if (!link and !abbr) return null;
    return .{ .date = date, .name = name };
}

fn validSigDate(d: []const u8) bool {
    if (d.len < 11) return false;
    var month_ok = false;
    for (months) |m| month_ok = month_ok or std.mem.eql(u8, d[0..3], m);
    if (!month_ok or d[3] != ' ') return false;
    const comma = std.mem.indexOfScalar(u8, d, ',') orelse return false;
    const day = std.fmt.parseInt(u8, d[4..comma], 10) catch return false;
    if (day < 1 or day > 31 or d[4] == '0') return false;
    if (comma + 2 > d.len or d[comma + 1] != ' ') return false;
    const year = d[comma + 2 ..];
    if (year.len != 4) return false;
    _ = std.fmt.parseInt(u16, year, 10) catch return false;
    return true;
}

/// `Nov 11, 2026` from `2026-11-11`.
fn sigDate(arena: std.mem.Allocator, iso: []const u8) ![]const u8 {
    const month = try std.fmt.parseInt(u8, iso[5..7], 10);
    const day = try std.fmt.parseInt(u8, iso[8..10], 10);
    return std.fmt.allocPrint(arena, "{s} {d}, {s}", .{ months[month - 1], day, iso[0..4] });
}

/// The signature lines of a doc: lines between its `# ` title and its
/// first `## ` heading that mention h.d.a. Each is a candidate, valid or not.
fn preambleLines(text: []const u8, out: anytype) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var lineno: u32 = 0;
    var titled = false;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (std.mem.startsWith(u8, line, "## ")) return;
        if (std.mem.startsWith(u8, line, "# ")) {
            titled = true;
            continue;
        }
        if (titled and std.mem.indexOf(u8, line, "h.d.a.") != null) out.found(lineno, line);
    }
}

fn checkSignatures(r: Repo, diags: *Diags, path: []const u8, text: []const u8, offset: u32) void {
    const V = struct {
        r: Repo,
        diags: *Diags,
        path: []const u8,
        offset: u32,
        fn found(v: @This(), lineno: u32, line: []const u8) void {
            const sig = parseSignature(line) orelse {
                v.diags.err("{s}:{d}: not a signature line: write `Mon D, YYYY · Full Name, [h.d.a.](README.md#signature)`, or use zig build design -- sign", .{ v.path, v.offset + lineno });
                return;
            };
            const signers = v.r.signers orelse return;
            for (signers) |s| if (std.mem.eql(u8, s.name, sig.name)) return;
            v.diags.err("{s}:{d}: signed by `{s}`, who isn't in design/SIGNERS", .{ v.path, v.offset + lineno, sig.name });
        }
    };
    preambleLines(text, V{ .r = r, .diags = diags, .path = path, .offset = offset });
}

// ---- links ----

/// Fails on a link to a file under design/ that doesn't exist: `design/<name>.md`
/// anywhere, and `](<name>.md` within design/. Generated and vendored files
/// are left out, as are names with capitals that aren't README, TEMPLATE,
/// or STATUS, which can't be slugs (`design/NNNN-shortname.md`).
fn checkLinks(r: Repo, diags: *Diags) !void {
    for (r.files) |path| {
        if (std.mem.startsWith(u8, path, "third_party/") or std.mem.startsWith(u8, path, "tools/testdata/") or
            std.mem.startsWith(u8, path, ".git/") or std.mem.eql(u8, path, status_path)) continue;
        const text = r.root.readFileAlloc(r.io, path, r.arena, .limited(1 << 22)) catch continue;
        if (std.mem.indexOfScalar(u8, text, 0) != null) continue; // binary
        const in_design = std.mem.startsWith(u8, path, "design/");
        var lines = std.mem.splitScalar(u8, text, '\n');
        var lineno: u32 = 0;
        while (lines.next()) |line| {
            lineno += 1;
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, line, pos, "design/")) |at| {
                pos = at + "design/".len;
                if (at > 0 and (std.ascii.isAlphanumeric(line[at - 1]) or line[at - 1] == '-' or line[at - 1] == '_')) continue;
                if (docName(line[pos..])) |name| try expectDoc(r, diags, path, lineno, name);
            }
            if (!in_design) continue;
            pos = 0;
            while (std.mem.indexOfPos(u8, line, pos, "](")) |at| {
                pos = at + 2;
                if (docName(line[pos..])) |name| try expectDoc(r, diags, path, lineno, name);
            }
        }
    }
}

/// `x` from `x.md...` when x is a plain name (letters, digits, dashes).
fn docName(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
    if (i == 0 or !std.mem.startsWith(u8, s[i..], ".md")) return null;
    const after = i + 3;
    if (after < s.len and (std.ascii.isAlphanumeric(s[after]) or s[after] == '-' or s[after] == '_')) return null;
    return s[0..i];
}

fn expectDoc(r: Repo, diags: *Diags, path: []const u8, lineno: u32, name: []const u8) !void {
    for ([_][]const u8{ "README", "TEMPLATE", "STATUS" }) |n| if (std.mem.eql(u8, name, n)) return;
    for (name) |c| if (std.ascii.isUpper(c)) return;
    for (r.ps) |p| if (std.mem.eql(u8, p.file[0 .. p.file.len - 3], name)) return;
    const msg_path = try std.fmt.allocPrint(r.arena, "design/{s}.md", .{name});
    diags.err("{s}:{d}: links to {s}, which doesn't exist", .{ path, lineno, msg_path });
}

// ---- list, ready, graph, status ----

/// What a proposal is doing or waiting for: in progress or stalled on its
/// branch, ready for an accepted proposal with no branch and everything it
/// depends on implemented, or the unimplemented dependencies.
fn state(r: Repo, p: Proposal, out: *std.ArrayList(u8)) !void {
    if (p.status.closed()) return;
    for (p.branch) |b| {
        if (out.items.len > 0) try out.appendSlice(r.arena, "; ");
        const age = if (r.branches) |bs| bs.get(b) else null;
        if (age) |a| {
            const days = @divFloor(a, std.time.s_per_day);
            if (days > stalled_days) {
                try out.print(r.arena, "stalled on {s} ({d} days)", .{ b, days });
            } else try out.print(r.arena, "in progress on {s}", .{b});
        } else if (r.branches != null) {
            try out.print(r.arena, "stalled: {s} not found", .{b});
        } else try out.print(r.arena, "on {s}", .{b});
    }
    var first = true;
    for (p.depends) |ref| {
        const j = r.resolve(ref) orelse continue;
        const q = r.ps[j];
        if (q.status == .implemented) continue;
        if (first and out.items.len > 0) try out.appendSlice(r.arena, "; ");
        try out.appendSlice(r.arena, if (first) "needs " else ", ");
        try out.appendSlice(r.arena, q.slug);
        first = false;
    }
    if (first and p.status == .accepted and p.branch.len == 0) try out.appendSlice(r.arena, "ready");
}

fn isReady(r: Repo, p: Proposal) bool {
    if (p.status != .accepted or p.branch.len > 0) return false;
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
    const Row = struct { slug: []const u8, id: []const u8, status: []const u8, state: []const u8, title: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    try rows.append(r.arena, .{ .slug = "SLUG", .id = "ISSUE", .status = "STATUS", .state = "STATE", .title = "TITLE" });
    for (r.ps) |p| {
        if (status) |s| if (p.status != s) continue;
        if (area) |a| if (!hasArea(p, a)) continue;
        if (ready_only and !isReady(r, p)) continue;
        var st: std.ArrayList(u8) = .empty;
        try state(r, p, &st);
        try rows.append(r.arena, .{
            .slug = p.slug,
            .id = if (p.id) |id| try std.fmt.allocPrint(r.arena, "#{d}", .{id}) else "-",
            .status = @tagName(p.status),
            .state = if (st.items.len > 0) st.items else "-",
            .title = p.title,
        });
    }
    var widths = [_]usize{0} ** 4;
    for (rows.items) |row| {
        for ([_][]const u8{ row.slug, row.id, row.status, row.state }, 0..) |cell, k| widths[k] = @max(widths[k], cell.len);
    }
    for (rows.items) |row| {
        for ([_][]const u8{ row.slug, row.id, row.status, row.state }, 0..) |cell, k| {
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
            .draft, .proposed, .hold => "draft",
            .accepted => "accepted",
            .implemented => "implemented",
            .declined, .superseded => "closed",
        };
        try w.print("  {s}[\"{s}<br/>{t}\"]:::{s}\n", .{ try nodeId(r.arena, p.slug), p.slug, p.status, class });
    }
    for (r.ps) |p| for (p.depends) |ref| {
        const j = r.resolve(ref) orelse continue;
        try w.print("  {s} --> {s}\n", .{ try nodeId(r.arena, r.ps[j].slug), try nodeId(r.arena, p.slug) });
    };
}

const status_path = "design/STATUS.md";

/// design/STATUS.md: a table of proposals and the graph. Only the
/// post-merge workflow on main (.github/workflows/design-status.yml)
/// commits it, so PRs never touch it and can't conflict over it.
fn statusFile(r: Repo) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(r.arena);
    const w = &aw.writer;
    try w.writeAll(
        \\<!-- Generated by `zig build design -- status` on main after each merge. Don't edit it, or commit it in a PR. -->
        \\
        \\# Proposal status
        \\
        \\Every proposal under [design/](README.md), in the order they were written, with its issue, its status, and whether it's ready, in progress, stalled, or what it needs. `zig build design -- list` prints the same from any checkout.
        \\
        \\| Proposal | Issue | Status | State | Title |
        \\| --- | --- | --- | --- | --- |
        \\
    );
    for (r.ps) |p| {
        var st: std.ArrayList(u8) = .empty;
        try state(r, p, &st);
        var issue: []const u8 = "";
        if (p.id) |id| issue = try std.fmt.allocPrint(r.arena, "[#{d}](../../../issues/{d})", .{ id, id });
        try w.print("| [{s}]({s}) | {s} | {t} | {s} | {s} |\n", .{ p.slug, p.file, issue, p.status, st.items, p.title });
    }
    try w.writeAll("\n```mermaid\n");
    try graph(r, w);
    try w.writeAll("```\n");
    return aw.written();
}

fn statusCmd(r: Repo) !void {
    try r.root.writeFile(r.io, .{ .sub_path = status_path, .data = try statusFile(r) });
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

/// The local date where `date` exists, else UTC.
fn localToday(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    const local = run(gpa, io, arena, &.{ "date", "+%Y-%m-%d" }) catch "";
    const t = std.mem.trim(u8, local, " \n");
    if (t.len == 10) return t;
    return arena.dupe(u8, &today(io));
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
        \\branch: []
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
    const text = try fromTemplate(r.arena, template, s, t, std.mem.trim(u8, a, " \n"), try localToday(gpa, r.io, r.arena));
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

// ---- propose ----

/// Whether the body has a `## <name>` heading.
fn hasSection(body: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trimEnd(u8, line, " \r");
        if (std.mem.startsWith(u8, l, "## ") and std.mem.eql(u8, l[3..], name)) return true;
    }
    return false;
}

/// The text of the Abstract section, for the issue body.
fn abstract(body: []const u8) []const u8 {
    const h = std.mem.indexOf(u8, body, "\n## Abstract\n") orelse return "";
    const rest = body[h + "\n## Abstract\n".len ..];
    const end = std.mem.indexOf(u8, rest, "\n## ") orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " \n");
}

/// Sets `id: N` (before the `slug:` line) and `status: proposed` in the
/// frontmatter.
fn proposedText(arena: std.mem.Allocator, text: []const u8, id: u32) ![]const u8 {
    const at = std.mem.indexOf(u8, text, "\nslug:") orelse return error.NoSlugLine;
    const with_id = try std.fmt.allocPrint(arena, "{s}\nid: {d}{s}", .{ text[0..at], id, text[at..] });
    const st = std.mem.indexOf(u8, with_id, "\nstatus: draft\n") orelse return error.NotDraft;
    return std.fmt.allocPrint(arena, "{s}\nstatus: proposed\n{s}", .{ with_id[0..st], with_id[st + "\nstatus: draft\n".len ..] });
}

fn proposeCmd(r: Repo, gpa: std.mem.Allocator, args: []const []const u8) !void {
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
            existing = std.fmt.parseInt(u32, args[k], 10) catch fail("propose: --issue needs an issue number, not `{s}`", .{args[k]});
            if (existing == 0) fail("propose: --issue needs an issue number, not 0", .{});
        } else if (slug == null and a.len > 0 and a[0] != '-') {
            slug = a;
        } else fail("propose: unexpected `{s}`\n{s}", .{ a, usage });
    }
    const s = slug orelse fail("propose: which slug?\n{s}", .{usage});
    const i = r.resolve(s) orelse fail("propose: `{s}` isn't a proposal", .{s});
    const p = r.ps[i];
    if (p.id) |id| fail("propose: {s} already has an issue, #{d}", .{ p.slug, id });
    if (p.status != .draft) fail("propose: {s} is `{t}`, not a draft", .{ p.slug, p.status });
    if (!p.ok) fail("propose: design/{s} has frontmatter errors; run zig build design -- check", .{p.file});
    const summary = abstract(p.body);
    if (summary.len == 0) fail("propose: design/{s} has no Abstract to put in the issue", .{p.file});
    const title = try std.fmt.allocPrint(r.arena, "proposal: {s}", .{p.title});
    if (existing) |id| {
        if (r.resolve(try std.fmt.allocPrint(r.arena, "{d}", .{id}))) |j| fail("propose: #{d} is already design/{s}", .{ id, r.ps[j].file });
        std.debug.print("setting design/{s}'s id to the existing issue #{d}, and its status to proposed; nothing is created on GitHub\n", .{ p.file, id });
        if (dry_run) return;
        return markProposed(r, gpa, p, id);
    }

    std.debug.print(
        \\This opens a GitHub issue with gh, as the account gh is logged in as:
        \\
        \\  title:  {s}
        \\  label:  Proposal
        \\  body:   the Abstract of design/{s}, and a link to the file
        \\
        \\then sets its id to the issue number and its status to proposed, and commits.
        \\
    , .{ title, p.file });
    // A retried run, or an issue opened by hand, shouldn't get a twin. The
    // REST API, since GraphQL isn't reachable everywhere gh is.
    var quoted: std.ArrayList(u8) = .empty;
    for (title) |c| {
        if (c == '"' or c == '\\') try quoted.append(r.arena, '\\');
        try quoted.append(r.arena, c);
    }
    const jq = try std.fmt.allocPrint(r.arena, ".[] | select(.title == \"{s}\") | .number", .{quoted.items});
    if (run(gpa, r.io, r.arena, &.{ "gh", "api", "--paginate", "repos/{owner}/{repo}/issues?state=open&labels=Proposal&per_page=100", "--jq", jq })) |found| {
        var nums = std.mem.tokenizeAny(u8, found, " \n");
        if (nums.next()) |n| fail("propose: issue #{s} is open with the same title; use --issue {s}", .{ n, n });
    } else |_| fail("propose: gh couldn't list the open proposal issues; is gh logged in?", .{});
    if (dry_run) {
        std.debug.print("\n--dry-run: nothing changed. The issue body would be:\n\n{s}\n", .{summary});
        return;
    }
    if (!yes and !try confirm(r.io, "Propose it? [y/N] ")) fail("propose: not proposed", .{});

    const repo_info = run(gpa, r.io, r.arena, &.{ "gh", "api", "repos/{owner}/{repo}", "--jq", ".html_url + \" \" + .default_branch" }) catch
        fail("propose: gh couldn't read the repository; is gh logged in?", .{});
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, repo_info, " \n"), ' ');
    const html = parts.next() orelse "";
    const branch = parts.next() orelse "main";

    const body_arg = try std.fmt.allocPrint(r.arena, "body={s}\n\nDesign doc: {s}/blob/{s}/design/{s} (on {s} once merged)", .{ summary, html, branch, p.file, branch });
    const title_arg = try std.fmt.allocPrint(r.arena, "title={s}", .{title});
    const out = run(gpa, r.io, r.arena, &.{ "gh", "api", "repos/{owner}/{repo}/issues", "-f", title_arg, "-f", body_arg, "-f", "labels[]=Proposal", "--jq", ".number" }) catch
        fail("propose: gh couldn't create the issue", .{});
    const id = std.fmt.parseInt(u32, std.mem.trim(u8, out, " \n"), 10) catch fail("propose: unexpected answer from gh: {s}", .{out});
    std.debug.print("opened issue #{d}\n", .{id});
    try markProposed(r, gpa, p, id);
}

fn markProposed(r: Repo, gpa: std.mem.Allocator, p: Proposal, id: u32) !void {
    const path = try std.fmt.allocPrint(r.arena, "design/{s}", .{p.file});
    const text = try r.root.readFileAlloc(r.io, path, r.arena, .limited(1 << 22));
    const out = proposedText(r.arena, text, id) catch fail("propose: design/{s} has no `status: draft` line to change", .{p.file});
    try r.root.writeFile(r.io, .{ .sub_path = path, .data = out });
    const msg = try std.fmt.allocPrint(r.arena, "design: propose {s} as #{d}", .{ p.slug, id });
    _ = run(gpa, r.io, r.arena, &.{ "git", "add", "--", path }) catch fail("propose: git add failed; the file is changed but not committed", .{});
    _ = run(gpa, r.io, r.arena, &.{ "git", "commit", "-q", "-m", msg, "--", path }) catch fail("propose: git commit failed; the change is staged", .{});
    std.debug.print("{s}\n", .{msg});
}

// ---- log ----

/// Prints each commit that changed the proposal's status, branch, or id,
/// following renames, oldest first.
fn logCmd(r: Repo, gpa: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len != 1) fail("log: which slug?\n{s}", .{usage});
    const i = r.resolve(args[0]) orelse fail("log: `{s}` isn't a proposal", .{args[0]});
    const path = try std.fmt.allocPrint(r.arena, "design/{s}", .{r.ps[i].file});
    // git can't combine --follow with --reverse, so the commits come
    // newest first and are printed the other way round.
    const out = run(gpa, r.io, r.arena, &.{ "git", "log", "--follow", "--date=short", "--format=@@commit %h %ad %s", "-p", "--", path }) catch
        fail("log: git log failed", .{});
    const text = try formatLog(r.arena, out);
    var rows: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |row| try rows.append(r.arena, row);
    std.mem.reverse([]const u8, rows.items);
    for (rows.items) |row| try w.print("{s}\n", .{row});
}

fn formatLog(arena: std.mem.Allocator, gitlog: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var head: []const u8 = "";
    var changes: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, gitlog, '\n');
    while (true) {
        const next = lines.next();
        if (next == null or std.mem.startsWith(u8, next.?, "@@commit ")) {
            if (head.len > 0 and changes.items.len > 0) {
                // `%h %ad %s` as `date hash: changes (subject)`.
                var parts = std.mem.splitScalar(u8, head, ' ');
                const hash = parts.next() orelse "";
                const date = parts.next() orelse "";
                try out.print(arena, "{s} {s}  {s}  ({s})\n", .{ date, hash, changes.items, parts.rest() });
            }
            const line = next orelse break;
            head = line["@@commit ".len..];
            changes = .empty;
            continue;
        }
        const line = next.?;
        for ([_][]const u8{ "+status: ", "+branch: ", "+id: " }) |key| {
            if (!std.mem.startsWith(u8, line, key)) continue;
            if (changes.items.len > 0) try changes.appendSlice(arena, ", ");
            try changes.appendSlice(arena, line[1..]);
        }
    }
    return out.items;
}

// ---- sign ----

fn signerByLogin(r: Repo, login: []const u8) ?Signer {
    for (r.signers orelse return null) |s| if (std.ascii.eqlIgnoreCase(s.login, login)) return s;
    return null;
}

fn signerByName(r: Repo, name: []const u8) ?Signer {
    for (r.signers orelse return null) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// The doc with `name`'s signature dated `date` (`Nov 11, 2026`): an older
/// signature of theirs is replaced, otherwise the new one goes after the
/// title and any other signatures. Fails if they already signed that day.
fn signedText(arena: std.mem.Allocator, text: []const u8, name: []const u8, date: []const u8, link: []const u8) ![]const u8 {
    const sig = try std.fmt.allocPrint(arena, "{s} · {s}, [h.d.a.]({s})", .{ date, name, link });
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var titled = false;
    var done = false;
    var last_sig: ?usize = null; // offset in out just after the last signature line
    var title_end: ?usize = null;
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        const bare = std.mem.trimEnd(u8, line, " \r");
        if (!done and std.mem.startsWith(u8, bare, "## ")) done = true;
        if (!done and std.mem.startsWith(u8, bare, "# ") and !titled) {
            titled = true;
            try out.appendSlice(arena, line);
            title_end = out.items.len;
            continue;
        }
        if (!done and titled) if (parseSignature(bare)) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                if (std.mem.eql(u8, s.date, date)) return error.AlreadySigned;
                try out.appendSlice(arena, sig);
                done = true;
                last_sig = null;
                title_end = null;
                // Mark as replaced.
                while (lines.next()) |rest| {
                    try out.append(arena, '\n');
                    try out.appendSlice(arena, rest);
                }
                return out.items;
            }
            try out.appendSlice(arena, line);
            last_sig = out.items.len;
            continue;
        };
        try out.appendSlice(arena, line);
    }
    const at = last_sig orelse title_end orelse return error.NoTitle;
    const insert = if (last_sig != null) try std.fmt.allocPrint(arena, "\n{s}", .{sig}) else try std.fmt.allocPrint(arena, "\n\n{s}", .{sig});
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ out.items[0..at], insert, out.items[at..] });
}

fn signCmd(r: Repo, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    var target: ?[]const u8 = null;
    var login: ?[]const u8 = null;
    var date_iso: ?[]const u8 = null;
    var k: usize = 0;
    while (k < args.len) : (k += 1) {
        if (std.mem.eql(u8, args[k], "--login") and k + 1 < args.len) {
            k += 1;
            login = args[k];
        } else if (std.mem.eql(u8, args[k], "--date") and k + 1 < args.len) {
            k += 1;
            date_iso = args[k];
        } else if (target == null and args[k].len > 0 and args[k][0] != '-') {
            target = args[k];
        } else fail("sign: unexpected `{s}`\n{s}", .{ args[k], usage });
    }
    const t = target orelse fail("sign: which doc? A proposal's slug, or spec", .{});
    if (r.signers == null) fail("sign: there's no design/SIGNERS", .{});

    // --login and --date are for the /sign workflow, which has already
    // checked who commented; anywhere else, signing is interactive.
    const from_comment = login != null or date_iso != null;
    if (from_comment) {
        const ev = env.get("GITHUB_EVENT_NAME") orelse "";
        if (!std.mem.eql(u8, ev, "issue_comment")) fail("sign: --login and --date are only for the /sign workflow", .{});
        if (login == null or date_iso == null) fail("sign: the workflow passes both --login and --date", .{});
    } else if (!(std.Io.File.stdin().isTty(r.io) catch false)) {
        fail("sign: run it yourself at a terminal; a signature is your own sign-off (design/README.md, Signature)", .{});
    }

    var path: []const u8 = "SPEC.md";
    var link: []const u8 = "design/README.md#signature";
    var title: []const u8 = "SPEC.md";
    if (!std.mem.eql(u8, t, "spec")) {
        const i = r.resolve(t) orelse fail("sign: `{s}` isn't a proposal", .{t});
        path = try std.fmt.allocPrint(r.arena, "design/{s}", .{r.ps[i].file});
        link = "README.md#signature";
        title = r.ps[i].title;
    }

    const signer: Signer = if (login) |l| signerByLogin(r, l) orelse fail("sign: `{s}` isn't in design/SIGNERS", .{l}) else blk: {
        if (run(gpa, r.io, r.arena, &.{ "gh", "api", "user", "--jq", ".login" })) |out| {
            if (signerByLogin(r, std.mem.trim(u8, out, " \n"))) |s| break :blk s;
        } else |_| {}
        if (run(gpa, r.io, r.arena, &.{ "git", "config", "user.name" })) |out| {
            if (signerByName(r, std.mem.trim(u8, out, " \n"))) |s| break :blk s;
        } else |_| {}
        fail("sign: neither your gh login nor git's user.name is in design/SIGNERS", .{});
    };
    const iso = date_iso orelse try localToday(gpa, r.io, r.arena);
    if (!(iso.len == 10 and iso[4] == '-' and iso[7] == '-')) fail("sign: --date must be YYYY-MM-DD", .{});
    const date = try sigDate(r.arena, iso);

    if (!from_comment) {
        std.debug.print("Signing {s} (\"{s}\") as {s}, dated {s}.\nThis says you directed it, reviewed the whole doc, and take responsibility for it.\nType `{s}` to confirm: ", .{ path, title, signer.name, date, t });
        var buf: [256]u8 = undefined;
        var rd = std.Io.File.stdin().readerStreaming(r.io, &buf);
        const line = (rd.interface.takeDelimiter('\n') catch null) orelse "";
        if (!std.mem.eql(u8, std.mem.trim(u8, line, " \r\t"), t)) fail("sign: not signed", .{});
    }

    const text = try r.root.readFileAlloc(r.io, path, r.arena, .limited(1 << 24));
    const out = signedText(r.arena, text, signer.name, date, link) catch |err| switch (err) {
        error.AlreadySigned => fail("sign: {s} already has {s}'s signature dated {s}", .{ path, signer.name, date }),
        error.NoTitle => fail("sign: {s} has no `# ` title to sign under", .{path}),
        else => return err,
    };
    try r.root.writeFile(r.io, .{ .sub_path = path, .data = out });
    std.debug.print("signed {s}\n", .{path});
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
    const r = try Repo.load(arena, init.gpa, io, std.Io.Dir.cwd(), &diags, .git);

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
    } else if (std.mem.eql(u8, cmd, "status")) {
        try statusCmd(r);
    } else if (std.mem.eql(u8, cmd, "new")) {
        try newCmd(r, init.gpa, rest);
    } else if (std.mem.eql(u8, cmd, "propose")) {
        try proposeCmd(r, init.gpa, rest);
    } else if (std.mem.eql(u8, cmd, "log")) {
        try logCmd(r, init.gpa, w, rest);
    } else if (std.mem.eql(u8, cmd, "sign")) {
        try signCmd(r, init.gpa, init.environ_map, rest);
    } else if (std.mem.eql(u8, cmd, "file") or std.mem.eql(u8, cmd, "fix")) {
        std.debug.print("design: `{s}` is gone; see design/proposal-flow.md (`file` is now `propose`, and nothing needs `fix`)\n", .{cmd});
        return 2;
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
// exactly the listed messages. A `.branches` file gives branch ages in
// days (`name days` per line); without one, branches aren't checked.
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
        const r = try Repo.load(arena, gpa, io, tmp.dir, &diags, .walk);
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

test "state: ready, in progress, and stalled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bs: std.StringHashMapUnmanaged(i64) = .empty;
    try bs.put(arena, "fresh", 2 * std.time.s_per_day);
    try bs.put(arena, "old", 12 * std.time.s_per_day);
    var ps = [_]Proposal{
        .{ .file = "a.md", .slug = "a", .status = .accepted },
        .{ .file = "b.md", .slug = "b", .status = .accepted, .branch = &.{"fresh"} },
        .{ .file = "c.md", .slug = "c", .status = .draft, .branch = &.{"old"} },
        .{ .file = "d.md", .slug = "d", .status = .accepted, .branch = &.{"gone"} },
        .{ .file = "e.md", .slug = "e", .status = .accepted, .depends = &.{"c"} },
    };
    const r: Repo = .{ .arena = arena, .io = std.testing.io, .root = std.Io.Dir.cwd(), .ps = &ps, .cases = &.{}, .files = &.{}, .branches = bs, .signers = null };
    const want = [_][]const u8{ "ready", "in progress on fresh", "stalled on old (12 days)", "stalled: gone not found", "needs c" };
    for (ps, want) |p, w| {
        var st: std.ArrayList(u8) = .empty;
        try state(r, p, &st);
        try std.testing.expectEqualStrings(w, st.items);
    }
    try std.testing.expect(isReady(r, ps[0]) and !isReady(r, ps[1]));
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
        \\branch: []
        \\---
        \\
        \\# Proposal: KVM backend
        \\
    , out);
}

test "propose helpers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expect(hasSection("\n# P\n\n## Declined\n\nNo.\n", "Declined"));
    try std.testing.expect(!hasSection("\n# P\n\n### Declined\n\n## Declined later\n", "Declined"));
    try std.testing.expectEqualStrings("Short.", abstract("\n# P\n\n## Abstract\n\nShort.\n\n## Background\n\nLong.\n"));
    try std.testing.expectEqualStrings("---\nid: 9\nslug: a\nstatus: proposed\n---\n", try proposedText(arena_state.allocator(), "---\nslug: a\nstatus: draft\n---\n", 9));
}

test "signatures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const abbr = "Nov 3, 2026 · Jeff Lindsay, <abbr title=\"AI-assisted work, directed by the named person.\">h.d.a.</abbr>";
    try std.testing.expectEqualStrings("Jeff Lindsay", parseSignature(abbr).?.name);
    try std.testing.expectEqualStrings("Nov 11, 2026", parseSignature("Nov 11, 2026 · Jeff Lindsay, [h.d.a.](README.md#signature)").?.date);
    try std.testing.expect(parseSignature("Nov 11 2026 · Jeff Lindsay, h.d.a.") == null);
    try std.testing.expect(parseSignature("Sometime · Jeff Lindsay, [h.d.a.](README.md#signature)") == null);
    try std.testing.expectEqualStrings("Nov 11, 2026", try sigDate(arena, "2026-11-11"));
    try std.testing.expectEqualStrings("Mar 2, 2027", try sigDate(arena, "2027-03-02"));

    const link = "README.md#signature";
    // A new signature goes under the title.
    try std.testing.expectEqualStrings(
        "---\nslug: a\n---\n\n# Proposal: A\n\nNov 11, 2026 · Jeff Lindsay, [h.d.a.](README.md#signature)\n\n## Abstract\n",
        try signedText(arena, "---\nslug: a\n---\n\n# Proposal: A\n\n## Abstract\n", "Jeff Lindsay", "Nov 11, 2026", link),
    );
    // An older one by the same person is replaced.
    const old = "# Proposal: A\n\n" ++ abbr ++ "\n\n## Abstract\n";
    try std.testing.expectEqualStrings(
        "# Proposal: A\n\nNov 11, 2026 · Jeff Lindsay, [h.d.a.](README.md#signature)\n\n## Abstract\n",
        try signedText(arena, old, "Jeff Lindsay", "Nov 11, 2026", link),
    );
    // Someone else's stays, and the new one follows it.
    try std.testing.expectEqualStrings(
        "# Proposal: A\n\n" ++ abbr ++ "\nNov 11, 2026 · Ada Lovelace, [h.d.a.](README.md#signature)\n\n## Abstract\n",
        try signedText(arena, old, "Ada Lovelace", "Nov 11, 2026", link),
    );
    try std.testing.expectError(error.AlreadySigned, signedText(arena, old, "Jeff Lindsay", "Nov 3, 2026", link));
}

test "log" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gitlog =
        \\@@commit 4be5ab3 2026-11-07 design: draft browser-gfx
        \\
        \\diff --git a/design/browser-gfx.md b/design/browser-gfx.md
        \\+status: draft
        \\+Some body text.
        \\@@commit 0b1c2d3 2026-11-08 design: tidy browser-gfx
        \\-old
        \\+new
        \\@@commit 196b924 2026-11-11 design: 120 implemented
        \\-status: accepted
        \\+status: implemented
        \\+branch: [main]
        \\
    ;
    try std.testing.expectEqualStrings(
        "2026-11-07 4be5ab3  status: draft  (design: draft browser-gfx)\n2026-11-11 196b924  status: implemented, branch: [main]  (design: 120 implemented)\n",
        try formatLog(arena_state.allocator(), gitlog),
    );
}
