//! The CLI's tool functions, `--version` and `--check` (DESIGN.md, "CLI").
//! They use the library like any embedder; only the output format is here.

const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");
const hello = @import("hello");
const vmm = h9.vmm;
const build_options = h9.build_info;

/// Exit status of a check that found a problem: h9 itself can't work.
pub const exit_failed = 125;

/// Prints the version, the pinned 9front and drawterm revisions and the
/// backends built in.
pub fn version(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("h9 {s}\n", .{build_options.version});
    try w.print("9front {s} ({s})\n", .{ build_options.ninefront_release, short(build_options.ninefront_rev) });
    try w.print("drawterm {s}\n", .{short(build_options.drawterm_rev)});
    try w.writeAll("backends:");
    var any = false;
    inline for (@typeInfo(vmm.Kind).@"enum".fields) |f| {
        const k: vmm.Kind = @enumFromInt(f.value);
        if (k.built()) {
            try w.print(" {s}", .{f.name});
            if (k == .emu) {
                var buf: [16]u8 = undefined;
                try w.print(" (Unicorn {s})", .{vmm.emuVersion(&buf) orelse "?"});
            }
            any = true;
        }
    }
    if (!any) try w.writeAll(" none");
    try w.writeAll("\n");
}

fn short(rev: []const u8) []const u8 {
    return rev[0..@min(rev.len, 12)];
}

pub const CheckOptions = struct {
    /// Which backend to check; `.auto` checks every one built in and then
    /// the one `auto` picks.
    backend: vmm.BackendKind = .auto,
    memory: ?u64 = null,
    /// The root tree as given (for messages), or null if none was found.
    root_arg: ?[]const u8 = null,
    /// The root resolved (a host directory for #U, or a 9P server), or
    /// null if it couldn't be.
    root: ?h9.Root = null,
    /// Why `root_arg` couldn't be resolved.
    root_err: []const u8 = "not found",
    /// The attach name and uname for a 9P root.
    root_spec: []const u8 = "",
    root_user: ?[]const u8 = null,
    /// A WebSocket root's headers, `--root-ca` and proxies.
    root_headers: []const []const u8 = &.{},
    root_ca: ?[]const u8 = null,
    proxy: h9.Machine.Proxy = .{},
};

/// Probes the backends (creating a VM and running a tiny program on each,
/// which on macOS also checks the hypervisor entitlement), reports HVF's
/// vCPU limit, and checks the root tree by running /bin/echo from it.
/// Prints one line per item and returns 0, or `exit_failed` if h9 can't
/// run 9front programs from the root here.
pub fn check(gpa: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, o: CheckOptions) std.Io.Writer.Error!u8 {
    try w.print("h9 {s} on {t} {t}\n", .{ build_options.version, builtin.os.tag, builtin.cpu.arch });
    const arch = vmm.host_arch orelse {
        try w.writeAll("host: no 9front architecture for this CPU\n");
        return exit_failed;
    };

    var failed = false;
    const kinds: []const vmm.BackendKind = switch (o.backend) {
        .auto => &.{ .hvf, .kvm, .whp, .emu, .auto },
        else => &.{o.backend},
    };
    for (kinds) |k| {
        const r = probe(gpa, io, k, arch, o.memory);
        // Backends that aren't built in are listed only when asked for.
        if (o.backend == .auto and k != .auto and r == .err and r.err == error.BackendNotBuilt) continue;
        try w.print("backend {t}: ", .{k});
        switch (r) {
            .ok => |p| {
                try w.print("ok", .{});
                if (k == .auto) try w.print(" (uses {t})", .{p.kind});
                if (p.max_vcpus) |n| try w.print(", {d} vCPUs", .{n});
                try w.print(", hello in {d}.{d} ms\n", .{ p.us / 1000, p.us % 1000 / 100 });
            },
            .err => |e| {
                try w.print("{s}\n", .{explain(k, e)});
                if (k == o.backend) failed = true;
            },
            .wrong, .failed => |msg| {
                try w.print("ran, but {s}\n", .{msg});
                if (k == o.backend) failed = true;
            },
        }
    }

    const root = o.root orelse {
        if (o.root_arg) |r| try w.print("root {s}: {s}\n", .{ r, o.root_err }) else try w.writeAll("root: none (use --root DIR or $H9ROOT; scripts/mkroot.py builds one)\n");
        return exit_failed;
    };
    try w.print("root {s}: ", .{switch (root) {
        .dir => |d| d,
        // A 9P root as given, which is how its errors name it.
        .tcp, .unix, .ws => o.root_arg orelse "",
    }});
    if (failed) {
        try w.writeAll("not checked, no usable backend\n");
        return exit_failed;
    }
    var why: [256]u8 = undefined;
    const echo = runRoot(gpa, io, o, arch, &why);
    switch (echo) {
        .ok => try w.print("ok, /bin/echo runs ({t})\n", .{arch}),
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
    ok: struct { kind: vmm.Kind, max_vcpus: ?u32, us: u64 },
    err: anyerror,
    /// The program ran with the wrong result.
    wrong: []const u8,
    /// The machine's namespace couldn't be built, and why.
    failed: []const u8,
};

/// Creates a machine on backend `k` and runs the hello fixture on it.
fn probe(gpa: std.mem.Allocator, io: std.Io, k: vmm.BackendKind, arch: vmm.Arch, memory: ?u64) Probe {
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
        .backend = k,
        .arch = arch,
        .policy = .{ .memory = memory },
        .stdio = .{ .out = &out.writer, .err = &err.writer },
    }) catch |e| return .{ .err = e };
    defer m.deinit();
    const st = m.run(.{ .bytes = img }, &.{"hello"}) catch |e| return .{ .err = e };
    const us: u64 = @intCast(@max(0, @divTrunc(start.durationTo(.now(io, .awake)).toNanoseconds(), std.time.ns_per_us)));
    if (st != .exited or st.exited.len != 0) return .{ .wrong = "the test program didn't exit cleanly" };
    if (!std.mem.eql(u8, out.written(), hello.msg)) return .{ .wrong = "the test program's output was wrong" };
    const kind = m.backend.kind();
    return .{
        .ok = .{
            .kind = kind,
            // The emulator has no vCPU limit.
            .max_vcpus = if (kind == .hvf) m.backend.maxVcpus() catch null else null,
            .us = us,
        },
    };
}

/// Runs `/bin/echo ok` from the root tree on the backend `o.backend` picks.
/// A `.failed` message is in `why`.
fn runRoot(gpa: std.mem.Allocator, io: std.Io, o: CheckOptions, arch: vmm.Arch, why: []u8) Probe {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var m = h9.Machine.init(gpa, io, .{
        .backend = o.backend,
        .arch = arch,
        .root = o.root,
        .root_spec = o.root_spec,
        .root_user = o.root_user,
        .root_headers = o.root_headers,
        .root_ca = o.root_ca,
        .proxy = o.proxy,
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
    if (st != .exited or st.exited.len != 0) return .{ .wrong = "it failed" };
    if (!std.mem.eql(u8, out.written(), "ok\n")) return .{ .wrong = "its output was wrong" };
    return .{ .ok = .{ .kind = m.backend.kind(), .max_vcpus = null, .us = 0 } };
}

/// Why backend `want` can't be used, for the CLI's messages.
pub fn explain(want: vmm.BackendKind, err: anyerror) []const u8 {
    return switch (err) {
        error.HypervisorUnavailable => if (builtin.os.tag == .macos)
            "no usable hypervisor (is h9 signed with h9.entitlements?)"
        else
            "no usable hypervisor",
        error.BackendNotBuilt => switch (want) {
            .emu, .auto => "the emulator isn't built into this h9 (use h9-emu from the releases, or build with -Demu=unicorn)",
            else => "not built into this h9",
        },
        error.WrongArch => "can't run this architecture",
        error.NotImplemented => "not implemented yet",
        error.OutOfGuestMemory => "can't reserve guest memory (is --memory too large?)",
        else => @errorName(err),
    };
}
