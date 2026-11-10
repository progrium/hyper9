//! zig build vcpu (and litmus-a64): ha64's memory-model litmus tests
//! (src/jit/check/litmus_a64.zig), on real host threads, on each tier: T0,
//! the IR evaluator, and this host's emitter (through emit/native.zig).
//!
//! arm64 is weakly ordered, and a program relies on its barriers. What
//! these check:
//!
//! - SB (store buffering) with a DMB ISH between each thread's store and
//!   load: never both loads 0. Plain SB only tallies.
//! - MP (message passing) with DMBs, or with STLR on the flag and LDAR on
//!   the reader: a reader that sees the flag sees the data. Plain MP only
//!   tallies.
//! - LDXR/STXR (and LDAXR/STLXR) and LDADD counters on four threads lose
//!   no increments.
//!
//! The tallies show only with a forbidden outcome, since the build runner
//! fails a test that writes to stderr; zig build litmus prints them all.

const std = @import("std");
const vcpu = @import("vcpu");
const litmus = vcpu.check.litmus;
const suite = vcpu.check.litmus_a64;

const runs = 5000;

test "litmus-a64: ha64's barriers, acquire/release, and atomics on every tier" {
    const gpa = std.testing.allocator;
    var ok = true;
    for ([_]litmus.Tier{ .t0, .ir_eval, .native }) |tier| {
        if (tier == .native and !vcpu.emit.native.available()) continue;
        for (suite.all) |t| {
            var tally = try litmus.run(gpa, &suite.arch, t, .{ .iterations = runs, .tier = tier });
            defer tally.deinit(gpa);
            try std.testing.expectEqual(@as(u64, runs), tally.iterations);
            if (tally.forbidden == 0) continue;
            ok = false;
            var buf: [4096]u8 = undefined;
            var fw = std.Io.Writer.fixed(&buf);
            tally.print(t, tier, &fw) catch {};
            std.debug.print("{s}", .{fw.buffered()});
        }
    }
    try std.testing.expect(ok);
}
