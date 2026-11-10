//! The emulator backend on h9's own CPUs (-Demu=zig): ha64 for arm64
//! binaries and h86 for 386 binaries, picked by architecture at create.
//! amd64 binaries need Unicorn (-Demu=unicorn).
//!
//! Step 0 of the build-out: the dispatch is here and the two backends are
//! stubs, so later work only fills in src/vmm/ha64.zig and h86.zig and the
//! shared runtime under src/jit/.

const std = @import("std");
const build_options = @import("build_options");
const vmm = @import("../vmm.zig");
const ha64 = @import("ha64.zig");
const h86 = @import("h86.zig");

pub fn version(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "zig ({s})", .{if (build_options.jit) "jit" else "interpreter"}) catch "zig";
}

pub const Backend = struct {
    pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: vmm.Options) vmm.CreateError!*Backend {
        return switch (opts.arch) {
            .arm64 => ha64.create(gpa, io, opts),
            .i386 => h86.create(gpa, io, opts),
            .amd64 => error.WrongArch,
        };
    }
    pub fn destroy(_: *Backend) void {
        unreachable;
    }
    pub fn maxVcpus(_: *Backend) vmm.Error!u32 {
        unreachable;
    }
    pub fn allocPages(_: *Backend, _: usize) vmm.Error![]align(vmm.page_size) u8 {
        unreachable;
    }
    pub fn freePages(_: *Backend, _: []align(vmm.page_size) u8) void {
        unreachable;
    }
    pub fn newAddressSpace(_: *Backend) vmm.CreateError!*AddressSpace {
        unreachable;
    }
    pub fn createVcpu(_: *Backend) vmm.CreateError!Vcpu {
        unreachable;
    }
};

pub const AddressSpace = struct {
    pub fn destroy(_: *AddressSpace) void {
        unreachable;
    }
    pub fn map(_: *AddressSpace, _: u64, _: []align(vmm.page_size) u8, _: vmm.Perms) vmm.CreateError!void {
        unreachable;
    }
    pub fn shootdown(_: *AddressSpace) void {}
    pub fn unmap(_: *AddressSpace, _: u64) void {
        unreachable;
    }
    pub fn translate(_: *AddressSpace, _: u64, _: u64) ?[]u8 {
        unreachable;
    }
    pub fn copy(_: *AddressSpace, _: u64, _: []u8, _: bool) bool {
        unreachable;
    }
    pub fn codeChanged(_: *AddressSpace, _: u64, _: u64) void {
        unreachable;
    }
};

pub const Vcpu = struct {
    pub fn destroy(_: *Vcpu) void {
        unreachable;
    }
    pub fn setAddressSpace(_: *Vcpu, _: *AddressSpace) vmm.Error!void {
        unreachable;
    }
    pub fn run(_: *Vcpu) vmm.Error!vmm.Exit {
        unreachable;
    }
    pub fn getUreg(_: *Vcpu, _: *vmm.Ureg) void {
        unreachable;
    }
    pub fn setUreg(_: *Vcpu, _: *const vmm.Ureg) void {
        unreachable;
    }
    pub fn kick(_: *Vcpu) void {
        unreachable;
    }
    pub fn getExtra(_: *Vcpu, _: *vmm.Extra) vmm.Error!void {
        unreachable;
    }
    pub fn setExtra(_: *Vcpu, _: *const vmm.Extra) vmm.Error!void {
        unreachable;
    }
};
