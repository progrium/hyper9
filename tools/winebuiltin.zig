//! Marks a PE DLL as a Wine builtin, as winebuild does: Wine gives a DLL
//! a Unix library (its __wine_unix_call functions) only if its DOS stub
//! starts with "Wine builtin DLL" (design/wine-draw.md, winedraw.drv).
//!
//!   winebuiltin IN OUT

const std = @import("std");

const marker = "Wine builtin DLL\x00";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: winebuiltin IN OUT\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const pe = try cwd.readFileAlloc(io, args[1], init.arena.allocator(), .limited(64 << 20));
    try mark(pe);
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = pe });
}

/// Writes the marker after the 64-byte DOS header, where the DOS stub
/// program is; the PE header must start past it.
fn mark(pe: []u8) !void {
    if (pe.len < 0x40 or !std.mem.eql(u8, pe[0..2], "MZ")) return error.NotPE;
    const lfanew = std.mem.readInt(u32, pe[0x3c..0x40], .little);
    if (lfanew < 0x40 + marker.len or lfanew > pe.len) return error.NoRoom;
    @memcpy(pe[0x40..][0..marker.len], marker);
}

test "mark writes the marker into the DOS stub" {
    var pe: [0x80]u8 = @splat(0);
    pe[0] = 'M';
    pe[1] = 'Z';
    std.mem.writeInt(u32, pe[0x3c..0x40], 0x78, .little);
    try mark(&pe);
    try std.testing.expectEqualStrings(marker, pe[0x40..][0..marker.len]);
    std.mem.writeInt(u32, pe[0x3c..0x40], 0x48, .little);
    try std.testing.expectError(error.NoRoom, mark(&pe));
}
