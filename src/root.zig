//! h9: run 9front executables on host hypervisors.

pub const aout = @import("aout.zig");
/// Linux ELF binaries (design/epoch-0/linux-personality.md).
pub const linux_elf = @import("linux/elf.zig");
pub const vmm = @import("vmm.zig");
pub const loader = @import("loader.zig");
pub const segment = @import("segment.zig");
pub const kern = @import("kern.zig");
pub const Machine = @import("machine.zig").Machine;
pub const hostpty = @import("hostpty.zig");
pub const Mount = Machine.Mount;
pub const Status = @import("machine.zig").Status;
pub const RootChanges = @import("machine.zig").RootChanges;
pub const Program = @import("machine.zig").Program;
pub const EnvVar = @import("machine.zig").EnvVar;
pub const policy = @import("policy.zig");
pub const Policy = policy.Policy;
pub const guestmem = @import("guestmem.zig");
pub const syscall = @import("syscall.zig");
pub const newns = @import("newns.zig");
pub const consin = @import("consin.zig");
pub const ws = @import("ws.zig");
pub const hstream = @import("hstream.zig");
/// Credential helpers for WebSocket handshakes (design/epoch-0/credential-helpers.md).
pub const cred = @import("cred.zig");
/// `--serve` listeners (design/epoch-0/serve.md).
pub const serve = @import("serve.zig");
pub const gfx = @import("gfx.zig");
pub const rootindex = @import("rootindex.zig");
pub const web = @import("web.zig");
/// The 9P2000.L server over a tree in memory that the dotl tests use,
/// for tests/backends.zig's [fd-mounts] cases; only in tests.
pub const dotl_test_server = if (@import("builtin").is_test) @import("dotl/testserver.zig").Server else void;

/// What this h9 was built from, for `--version`.
pub const build_info = struct {
    const o = @import("build_options");
    /// `git describe`, or -Dversion.
    pub const version: []const u8 = o.version;
    /// The pinned 9front release and source revision, and drawterm's.
    pub const ninefront_release: []const u8 = o.ninefront_release;
    pub const ninefront_rev: []const u8 = o.ninefront_rev;
    pub const drawterm_rev: []const u8 = o.drawterm_rev;
    /// The GUI backend for --gfx (design/epoch-0/gfx.md), or "none".
    pub const gfx: []const u8 = o.gfx;
    /// The built-in root (design/epoch-0/builtin-root.md).
    pub const builtin_root = @import("machine.zig").builtin_root;
};

test {
    _ = aout;
    _ = loader;
    _ = segment;
    _ = vmm;
    _ = kern;
    _ = guestmem;
    _ = syscall;
    _ = policy;
    _ = @import("mount.zig");
    _ = newns;
    _ = consin;
    _ = ws;
    _ = hstream;
    _ = hostpty;
    _ = cred;
    _ = serve;
    _ = gfx;
    _ = @import("cpupool.zig");
    _ = @import("linux/nr.zig");
    _ = @import("linux/mm.zig");
    _ = @import("linux/elf.zig");
    _ = @import("linux/vclock.zig");
    _ = @import("linux/signal.zig");
    _ = @import("linux/sys.zig");
    _ = @import("linux/locks.zig");
    _ = @import("linux/cputime.zig");
    _ = @import("linux/netlink.zig");
    _ = @import("dotl/attr.zig");
    _ = @import("dotl/wire.zig");
    _ = @import("dotl/client.zig");
    _ = @import("dotl/server.zig");
    _ = @import("dotl/kern.zig");
    _ = rootindex;
    _ = @import("rootindex/kern.zig");
    _ = @import("statictree.zig");
}
