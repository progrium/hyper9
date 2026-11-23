//! A project that depends on h9 as a fetched package, as
//! docs/embedding.md describes. CI copies ../embed.zig here, adds h9 to
//! build.zig.zon with `zig fetch --save=h9`, and runs `zig build`, so a
//! file the package leaves out of build.zig.zon's paths fails the job.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const h9 = b.dependency("h9", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "embed", .root_module = b.createModule(.{
        .root_source_file = b.path("embed.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "h9", .module = h9.module("h9") }},
    }) });
    if (target.result.os.tag == .macos) exe.root_module.linkFramework("Hypervisor", .{});
    b.installArtifact(exe);
}
