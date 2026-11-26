//! Stands in for an engine that isn't built into this h9: `create` fails,
//! so the other methods are never reached.

const std = @import("std");
const engine = @import("../engine.zig");

pub const Engine = struct {
    pub fn create(_: std.mem.Allocator, _: std.Io, _: engine.Options) engine.CreateError!*Engine {
        return error.EngineNotBuilt;
    }
    pub fn destroy(_: *Engine) void {
        unreachable;
    }
    pub fn maxVcpus(_: *Engine) engine.Error!u32 {
        unreachable;
    }
    pub fn allocPages(_: *Engine, _: usize) engine.Error![]align(engine.page_size) u8 {
        unreachable;
    }
    pub fn freePages(_: *Engine, _: []align(engine.page_size) u8) void {
        unreachable;
    }
    pub fn newAddressSpace(_: *Engine) engine.CreateError!*AddressSpace {
        unreachable;
    }
    pub fn createVcpu(_: *Engine) engine.CreateError!Vcpu {
        unreachable;
    }
};

pub const AddressSpace = struct {
    pub fn destroy(_: *AddressSpace) void {
        unreachable;
    }
    pub fn map(_: *AddressSpace, _: u64, _: []align(engine.page_size) u8, _: engine.Perms) engine.CreateError!void {
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
    pub fn setAddressSpace(_: *Vcpu, _: *AddressSpace) engine.Error!void {
        unreachable;
    }
    pub fn run(_: *Vcpu) engine.Error!engine.Exit {
        unreachable;
    }
    pub fn getUreg(_: *Vcpu, _: *engine.Ureg) void {
        unreachable;
    }
    pub fn setUreg(_: *Vcpu, _: *const engine.Ureg) void {
        unreachable;
    }
    pub fn kick(_: *Vcpu) void {
        unreachable;
    }
    pub fn getExtra(_: *Vcpu, _: *engine.Extra) engine.Error!void {
        unreachable;
    }
    pub fn setExtra(_: *Vcpu, _: *const engine.Extra) engine.Error!void {
        unreachable;
    }
};
