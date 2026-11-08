//! Stands in for a backend that isn't built into this h9: `create` fails,
//! so the other methods are never reached.

const std = @import("std");
const vmm = @import("../vmm.zig");

pub const Backend = struct {
    pub fn create(_: std.mem.Allocator, _: std.Io, _: vmm.Options) vmm.CreateError!*Backend {
        return error.BackendNotBuilt;
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
