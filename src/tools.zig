//! The CLI's tool functions, `--version` and `--check` (SPEC.md, "CLI").
//! They use the library like any embedder; only the output format is here.

const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");
const hello = @import("hello");
const engine = h9.engine;
const build_options = h9.build_info;

/// Exit status of a check that found a problem: h9 itself can't work.
pub const exit_failed = 125;

/// Prints the version, the pinned 9front and drawterm revisions and the
/// engines built in.
pub fn version(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("h9 {s}\n", .{build_options.version});
    try w.print("9front {s} ({s})\n", .{ build_options.ninefront_release, short(build_options.ninefront_rev) });
    try w.print("drawterm {s}\n", .{short(build_options.drawterm_rev)});
    try w.writeAll("engines:");
    var any = false;
    inline for (comptime std.enums.values(engine.Kind)) |k| {
        if (k.built()) {
            try w.print(" {t}", .{k});
            if (k == .hcpu) {
                var buf: [32]u8 = undefined;
                try w.print(" ({s})", .{engine.hcpuVersion(&buf) orelse "?"});
            }
            any = true;
        }
    }
    if (!any) try w.writeAll(" none");
    try w.writeAll("\n");
    // Every native build with graphics has the headless screen beside its
    // window backend (design/headless-screen.md).
    const g = build_options.gfx;
    if (std.mem.eql(u8, g, "none") or std.mem.eql(u8, g, "web") or std.mem.eql(u8, g, "headless"))
        try w.print("gfx: {s}\n", .{g})
    else
        try w.print("gfx: {s}, headless\n", .{g});
    const br = build_options.builtin_root;
    if (br.arches.len == 0) {
        try w.writeAll("built-in root: skeleton only\n");
    } else {
        try w.print("built-in root: 9front {s} {s},", .{ br.release, br.set });
        for (br.arches) |a| try w.print(" {s}", .{a});
        try w.print(" ({d} commands)\n", .{br.commands});
    }
}

/// The --check line for the GUI backend (design/epoch-0/gfx.md). On X11 it
/// opens and closes `$DISPLAY`, without a window. A missing display isn't
/// a failure: only --gfx needs one.
fn checkGfx(w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (h9.gfx.backend) {
        .none => try w.writeAll("gfx: not built in\n"),
        .headless => {},
        .x11 => if (h9.gfx.unavailable()) |why|
            try w.print("gfx x11: {s}\n", .{why})
        else if (h9.gfx.probeDisplay().?)
            try w.writeAll("gfx x11: ok, $DISPLAY opens\n")
        else
            try w.writeAll("gfx x11: can't open $DISPLAY\n"),
        .win32, .cocoa => try w.print("gfx {t}: built in\n", .{h9.gfx.backend}),
        .web => try w.writeAll("gfx web: built in (a page's canvas, given to createMachine)\n"),
    }
    if (h9.gfx.has_headless) try w.writeAll("gfx headless: ok (a screen in memory, --gfx=headless)\n");
}

fn short(rev: []const u8) []const u8 {
    return rev[0..@min(rev.len, 12)];
}

pub const CheckOptions = struct {
    /// Which engine to check; `.auto` checks every one built in and then
    /// the one `auto` picks.
    engine: engine.Choice = .auto,
    /// The guest architecture (--arch), or null for the host's.
    arch: ?engine.Arch = null,
    memory: ?u64 = null,
    /// The mounts the CLI resolved (design/epoch-0/mounts.md), the root's among
    /// them: with only the built-in root on `/`, it's checked.
    mounts: []const h9.policy.mount.Mount = &.{},
    /// The root as given, for messages: a path or URL, or null for the
    /// built-in root.
    root_arg: ?[]const u8 = null,
    /// Why the root couldn't be resolved, if it couldn't.
    root_err: ?[]const u8 = null,
    proxy: h9.Machine.Proxy = .{},
    /// --cred and $H9CRED (design/epoch-0/credential-helpers.md).
    cred_helpers: []const h9.Machine.CredHelper = &.{},
    /// --index, `index=`, and the index cache (design/epoch-0/mount-index.md).
    index: h9.Machine.IndexMode = .auto,
    root_index: ?h9.Machine.RootIndex = null,
    index_cache: ?[]const u8 = null,
};

/// Probes the engines (creating a VM and running a tiny program on each,
/// which on macOS also checks the hypervisor entitlement), reports the
/// hypervisor's vCPU limit, and checks the root tree by running /bin/echo from it.
/// Prints one line per item and returns 0, or `exit_failed` if h9 can't
/// run 9front programs from the root here.
pub fn check(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, o: CheckOptions) std.Io.Writer.Error!u8 {
    try w.print("h9 {s} on {t} {t}\n", .{ build_options.version, builtin.os.tag, builtin.cpu.arch });
    const arch = o.arch orelse engine.host_arch orelse {
        try w.writeAll("host: no 9front architecture for this CPU\n");
        return exit_failed;
    };

    var failed = false;
    const kinds: []const engine.Choice = switch (o.engine) {
        .auto => &.{ .hvf, .kvm, .whp, .sud, .hcpu, .auto },
        else => &.{o.engine},
    };
    for (kinds) |k| {
        const r = probe(gpa, io, k, arch, o.memory);
        // Engines that aren't built in are listed only when asked for.
        if (o.engine == .auto and k != .auto and r == .err and r.err == error.EngineNotBuilt) continue;
        try w.print("engine {t}: ", .{k});
        switch (r) {
            .ok => |p| {
                try w.print("ok", .{});
                if (k == .auto) try w.print(" (uses {t})", .{p.kind});
                if (k == .hcpu) {
                    var buf: [32]u8 = undefined;
                    if (engine.hcpuVersion(&buf)) |v| try w.print(" ({s})", .{v});
                }
                if (p.max_vcpus) |n| try w.print(", {d} vCPUs", .{n});
                try w.print(", hello in {d}.{d} ms\n", .{ p.us / 1000, p.us % 1000 / 100 });
            },
            .err => |e| {
                try w.print("{s}\n", .{explain(k, e)});
                if (k == o.engine) failed = true;
            },
            .wrong, .failed => |msg| {
                try w.print("ran, but {s}\n", .{msg});
                if (k == o.engine) failed = true;
            },
        }
    }

    try checkGfx(w);

    if (o.root_err) |e| {
        try w.print("root {s}: {s}\n", .{ o.root_arg orelse "", e });
        return exit_failed;
    }
    if (o.root_arg == null) {
        const br = build_options.builtin_root;
        if (!br.has(arch)) {
            try w.print("root: built-in, skeleton only, with no commands for {s} (use --dir DIR or $H9ROOT; zig build slim adds them)\n", .{arch.name()});
            return exit_failed;
        }
        try w.print("root: built-in (9front {s} {s}, {s}): ", .{ br.release, br.set, arch.name() });
    } else try w.print("root {s}: ", .{o.root_arg.?});
    if (failed) {
        try w.writeAll("not checked, no usable engine\n");
        return exit_failed;
    }
    var why: [256]u8 = undefined;
    var notes_buf: [2048]u8 = undefined;
    var notes: std.Io.Writer = .fixed(&notes_buf);
    const echo = runRoot(gpa, io, o, arch, &why, &notes);
    switch (echo) {
        .ok => {
            try w.print("ok, /bin/echo runs ({t})\n", .{arch});
            // The index the root was mounted with, validated.
            try w.writeAll(notes.buffered());
        },
        .err => |e| {
            try w.print("{s}\n", .{switch (e) {
                error.NotFound => "no /bin/echo (is it a 9front root tree?)",
                error.NotExecutable => "/bin/echo isn't a runnable a.out for this architecture",
                else => @errorName(e),
            }});
            failed = true;
        },
        .wrong => |msg| {
            try w.print("/bin/echo ran, but {s}\n", .{msg});
            failed = true;
        },
        // The namespace couldn't be built: a 9P root's connection or
        // attach failed, say.
        .failed => |msg| {
            // A 9P root's errors already start "root <dial string>: ".
            const colon = if (std.mem.startsWith(u8, msg, "root ")) std.mem.indexOf(u8, msg, ": ") else null;
            try w.print("{s}\n", .{if (colon) |c| msg[c + 2 ..] else msg});
            failed = true;
        },
    }
    return if (failed) exit_failed else 0;
}

const Probe = union(enum) {
    ok: struct { kind: engine.Kind, max_vcpus: ?u32, us: u64 },
    err: anyerror,
    /// The program ran with the wrong result.
    wrong: []const u8,
    /// The machine's namespace couldn't be built, and why.
    failed: []const u8,
};

/// Creates a machine on engine `k` and runs the hello fixture on it.
fn probe(gpa: std.mem.Allocator, io: std.Io, k: engine.Choice, arch: engine.Arch, memory: ?u64) Probe {
    var buf: [h9.aout.header_size]u8 = undefined;
    const hdr = buf[0..arch.headerSize()];
    const text: []const u8 = switch (arch) {
        .arm64 => &hello.arm64_text,
        .amd64 => &hello.amd64_text,
        .i386 => &hello.i386_text,
    };
    h9.aout.writeTextHeader(hdr, arch, text.len);
    const img = std.mem.concat(gpa, u8, &.{ hdr, text }) catch |e| return .{ .err = e };
    defer gpa.free(img);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    const start: std.Io.Timestamp = .now(io, .awake);
    var m = h9.Machine.init(gpa, io, .{
        .engine = k,
        .arch = arch,
        .policy = .{ .memory = memory },
        .stdio = .{ .out = &out.writer, .err = &err.writer },
    }) catch |e| return .{ .err = e };
    defer m.deinit();
    const st = m.run(.{ .bytes = img }, &.{"hello"}) catch |e| return .{ .err = e };
    const us: u64 = @intCast(@max(0, @divTrunc(start.durationTo(.now(io, .awake)).toNanoseconds(), std.time.ns_per_us)));
    if (st != .exited or st.exited.len != 0) return .{ .wrong = "the test program didn't exit cleanly" };
    if (!std.mem.eql(u8, out.written(), hello.msg)) return .{ .wrong = "the test program's output was wrong" };
    const kind = m.engine.kind();
    return .{
        .ok = .{
            .kind = kind,
            // The emulator and the sud engine have no vCPU limit.
            .max_vcpus = if (kind != .hcpu and kind != .sud) m.engine.maxVcpus() catch null else null,
            .us = us,
        },
    };
}

/// Runs `/bin/echo ok` from the root tree on the engine `o.engine` picks.
/// A `.failed` message is in `why`.
/// The root's index notes, without their "h9: ", go to `notes`.
fn runRoot(gpa: std.mem.Allocator, io: std.Io, o: CheckOptions, arch: engine.Arch, why: []u8, notes: *std.Io.Writer) Probe {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var m = h9.Machine.init(gpa, io, .{
        .engine = o.engine,
        .arch = arch,
        .mounts = o.mounts,
        .proxy = o.proxy,
        .cred_helpers = o.cred_helpers,
        .index = o.index,
        .root_index = o.root_index,
        .index_cache = o.index_cache,
        .verbose = true,
        .policy = .{ .memory = o.memory, .timeout_ns = 10 * std.time.ns_per_s },
        .stdio = .{ .out = &out.writer, .err = &err.writer },
    }) catch |e| return .{ .err = e };
    defer m.deinit();
    const st = m.run(.{ .guest = "/bin/echo" }, &.{ "echo", "ok" }) catch |e| {
        if (e != error.NamespaceFailed) return .{ .err = e };
        const n = @min(m.err_msg.len, why.len);
        @memcpy(why[0..n], m.err_msg[0..n]);
        return .{ .failed = why[0..n] };
    };
    // A stuck machine still uses `out`; don't free it under the process.
    if (m.stuck) std.process.exit(exit_failed);
    var lines = std.mem.splitScalar(u8, err.written(), '\n');
    while (lines.next()) |l| if (std.mem.startsWith(u8, l, "h9: index: ")) {
        notes.print("{s}\n", .{l["h9: ".len..]}) catch {};
    };
    if (st != .exited or st.exited.len != 0) return .{ .wrong = "it failed" };
    if (!std.mem.eql(u8, out.written(), "ok\n")) return .{ .wrong = "its output was wrong" };
    return .{ .ok = .{ .kind = m.engine.kind(), .max_vcpus = null, .us = 0 } };
}

/// Why engine `want` can't be used, for the CLI's messages.
pub fn explain(want: engine.Choice, err: anyerror) []const u8 {
    return switch (err) {
        error.HypervisorUnavailable => if (engine.whyUnavailable(want)) |why| why else switch (builtin.os.tag) {
            .macos => "no usable hypervisor (is h9 signed with h9.entitlements?)",
            .windows => "no usable hypervisor (enable the Windows Hypervisor Platform feature: Settings > Optional features, or `DISM /Online /Enable-Feature /FeatureName:HypervisorPlatform`, then restart)",
            else => "no usable hypervisor",
        },
        error.EngineNotBuilt => switch (want) {
            .hcpu, .auto => "the emulator isn't built into this h9 (it's built for arm64 and x86-64 targets)",
            else => "not built into this h9",
        },
        error.WrongArch => "can't run this architecture",
        error.NotImplemented => "not implemented yet",
        error.OutOfGuestMemory => "can't reserve guest memory (is --memory too large?)",
        else => @errorName(err),
    };
}
