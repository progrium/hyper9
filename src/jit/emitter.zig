//! What an emitter gives the shared JIT layer. Each host (arm64, x86-64,
//! wasm) has one, in src/jit/emit/.

const std = @import("std");
const ir = @import("ir.zig");
const alloc = @import("alloc.zig");

pub const EmitError = error{ OutOfMemory, Unsupported, TooLarge };

/// What `emit` produced. Native code is position-independent apart from
/// absolute addresses of runtime functions it embeds, so the cache can
/// copy it anywhere; `entry` is the offset of its `ctx.EntryFn`. For wasm,
/// `code` is a whole module whose export "run" is the entry.
pub const Code = struct {
    entry: u32 = 0,
    /// Where a linked chain site (or a jump-cache hit) lands, with the
    /// context register and the stack as they are at a site. 0 for wasm.
    chain_entry: u32 = 0,
    /// The region's chain sites, one per `exit.chain`, in order, up to
    /// `max_chains`; more are emitted but not reported, so never linked.
    chains: [max_chains]Chain = undefined,
    nchains: u8 = 0,

    pub fn chainSites(c: *const Code) []const Chain {
        return c.chains[0..c.nchains];
    }
};

pub const max_chains = 16;

/// A chain site: its offset from the start of the code (the patchable
/// jump: arm64's `B`, x86-64's `jmp rel32`), and the guest PC it leaves
/// for. The unlinked site falls through to the exit, which sets exit_pc
/// to `pc` and exit_info to the site's executable address.
pub const Chain = struct { site: u32, pc: u64 };

pub const Emitter = struct {
    name: []const u8,
    /// It lowers pending.flags aux2 = 2 (lazily written eflags records).
    lazy_eflags: bool = false,
    /// Appends the region's code to `out`. The region must verify.
    emit: *const fn (gpa: std.mem.Allocator, r: *const ir.Region, a: *const alloc.Allocation, out: *std.ArrayList(u8)) EmitError!Code,
};
