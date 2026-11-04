//! Hypervisor abstraction. See DESIGN.md, "Hypervisor layer (vmm)".
//!
//! Each backend module provides Backend, AddressSpace and Vcpu types with the
//! same methods; the unions below pick one at run time. Backends that aren't
//! built into this h9 are replaced by vmm/none.zig.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const aout = @import("aout.zig");
pub const arm64 = @import("arch/arm64.zig");
pub const amd64 = @import("arch/amd64.zig");

const hvf = if (have_hvf) @import("vmm/hvf.zig") else @import("vmm/none.zig");
const emu = if (have_emu) @import("vmm/emu.zig") else @import("vmm/none.zig");

const have_hvf = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
const have_emu = build_options.emu != .none;

pub const Arch = aout.Arch;

/// The architecture of 9front binaries that run natively on this host.
pub const host_arch: ?Arch = switch (builtin.cpu.arch) {
    .aarch64 => .arm64,
    .x86_64 => .amd64,
    else => null,
};

/// What `--backend` asks for.
pub const BackendKind = enum { auto, hvf, kvm, whp, emu };

/// A concrete backend. kvm and whp are proposed (design/kvm.md, design/whp.md).
pub const Kind = enum {
    hvf,
    emu,

    pub fn built(k: Kind) bool {
        return switch (k) {
            .hvf => have_hvf,
            .emu => have_emu,
        };
    }
};

pub const Error = error{
    /// The host has no usable hypervisor, or h9 lacks the access it needs.
    HypervisorUnavailable,
    HypervisorFailed,
    OutOfGuestMemory,
    BadAddress,
    /// The backend isn't compiled into this h9.
    BackendNotBuilt,
    /// The backend can't run binaries for this architecture.
    WrongArch,
    NotImplemented,
};

pub const CreateError = Error || std.mem.Allocator.Error;

pub const Options = struct {
    arch: Arch,
    /// Cap on the guest memory the backend hands out, page tables included;
    /// null means the backend's default region size.
    memory: ?u64 = null,
};

/// The guest memory region when no cap is given.
pub const default_memory: u64 = 1 << 30;
/// The largest cap: HVF's default 36-bit IPA space, less the low 2 GiB.
pub const max_memory: u64 = 32 << 30;

pub const page_size = 4096;

pub const Perms = packed struct { read: bool = true, write: bool = false, exec: bool = false };

pub const Fault = struct {
    addr: u64,
    access: enum { read, write, exec },
    syndrome: u64,
};

pub const Exit = union(enum) {
    syscall,
    fault: Fault,
    interrupted,
    halted,
    other: u64,
};

/// A Plan 9 Ureg in the layout of the process's architecture.
pub const Ureg = union(Arch) {
    arm64: arm64.Ureg,
    amd64: amd64.Ureg,

    pub fn initExec(arch: Arch, entry: u64, sp: u64, tos: u64) Ureg {
        return switch (arch) {
            .arm64 => .{ .arm64 = .initExec(entry, sp, tos) },
            .amd64 => .{ .amd64 = .initExec(entry, sp, tos) },
        };
    }
    pub fn pc(u: *const Ureg) u64 {
        return switch (u.*) {
            inline else => |r| r.pc,
        };
    }
    pub fn syscallNumber(u: *const Ureg) u64 {
        return switch (u.*) {
            inline else => |*r| r.syscallNumber(),
        };
    }
    pub fn syscallArgs(u: *const Ureg) u64 {
        return switch (u.*) {
            inline else => |*r| r.syscallArgs(),
        };
    }
    pub fn setReturn(u: *Ureg, v: u64) void {
        switch (u.*) {
            inline else => |*r| r.setReturn(v),
        }
    }
    pub fn stackPointer(u: *const Ureg) u64 {
        return switch (u.*) {
            inline else => |r| r.sp,
        };
    }
    /// The Ureg's size in the guest's layout, as notify copies it.
    pub fn size(u: *const Ureg) usize {
        return switch (u.*) {
            inline else => |r| @sizeOf(@TypeOf(r)),
        };
    }
    /// The Ureg's bytes in the guest's layout.
    pub fn bytes(u: *const Ureg) []const u8 {
        return switch (u.*) {
            inline else => |*r| std.mem.asBytes(r),
        };
    }

    /// A note handler's frame (9front's notify): see arm64.notifyFrame.
    pub const NotifyFrame = struct { nureg: u64, msg: u64, sp: u64, regs: Ureg };

    pub fn notifyFrame(u: *const Ureg, handler: u64, errmax: u64) ?NotifyFrame {
        return switch (u.*) {
            inline else => |*r, a| blk: {
                const f = (if (a == .arm64) arm64 else amd64).notifyFrame(r, handler, errmax) orelse break :blk null;
                break :blk .{ .nureg = f.nureg, .msg = f.msg, .sp = f.sp, .regs = @unionInit(Ureg, @tagName(a), f.regs) };
            },
        };
    }

    /// The Ureg noted restores from `saved` (the guest's copy, in this
    /// Ureg's layout), with the privileged state taken from `u`.
    pub fn restored(u: *const Ureg, saved: []const u8) Ureg {
        return switch (u.*) {
            inline else => |*r, a| blk: {
                const T = @TypeOf(r.*);
                var g: T = undefined;
                @memcpy(std.mem.asBytes(&g), saved[0..@sizeOf(T)]);
                break :blk @unionInit(Ureg, @tagName(a), (if (a == .arm64) arm64 else amd64).sanitize(g, r));
            },
        };
    }

    /// noted(NSAVE): the handler resumes with its Ureg argument again, in
    /// R0 on arm64 and BP on amd64, and the stack at `new_sp`.
    pub fn setNoteSave(u: *Ureg, new_sp: u64, nureg: u64) void {
        switch (u.*) {
            .arm64 => |*r| {
                r.sp = new_sp;
                r.r[0] = nureg;
            },
            .amd64 => |*r| {
                r.sp = new_sp;
                r.bp = nureg;
            },
        }
    }

    /// Whether noted may resume at this PC and SP (9front checks
    /// alignment on arm64).
    pub fn aligned(u: *const Ureg) bool {
        return switch (u.*) {
            .arm64 => |r| r.pc & 3 == 0 and r.sp & 7 == 0,
            .amd64 => true,
        };
    }
};

/// User state beyond the Ureg that a process keeps across vCPUs: the
/// FP/SIMD registers and the thread pointer. A process that moves between
/// pooled vCPUs, or forks, carries it with it.
pub const Extra = struct {
    /// Q0-Q31 on arm64, XMM0-XMM15 on amd64 (the rest unused).
    v: [32]u128 = @splat(0),
    /// FPCR and FPSR on arm64; MXCSR in `fpcr` on amd64.
    fpcr: u64 = 0,
    fpsr: u64 = 0,
    /// TPIDR_EL0 on arm64; FS base on amd64.
    tls: u64 = 0,

    /// The state at exec, with the MXCSR default on amd64.
    pub fn initExec(arch: Arch) Extra {
        return .{ .fpcr = if (arch == .amd64) 0x1f80 else 0 };
    }
};

/// The emulator's version (Unicorn's, e.g. "2.1"), or null if it isn't built in.
pub fn emuVersion(buf: []u8) ?[]const u8 {
    return if (have_emu) emu.version(buf) else null;
}

/// The native hypervisor backend for this host, if there is one.
fn native() ?Kind {
    return if (have_hvf) .hvf else null;
}

/// Creates a backend. `.auto` uses the host hypervisor when it can run
/// `opts.arch` binaries, and otherwise the emulator; check `kind()` to see
/// which one was picked.
pub fn create(gpa: std.mem.Allocator, io: std.Io, want: BackendKind, opts: Options) CreateError!Backend {
    return switch (want) {
        .hvf => createKind(gpa, io, .hvf, opts),
        .emu => createKind(gpa, io, .emu, opts),
        .kvm, .whp => error.BackendNotBuilt,
        .auto => {
            if (native()) |k| {
                if (createKind(gpa, io, k, opts)) |b| return b else |err| switch (err) {
                    error.HypervisorUnavailable, error.WrongArch => if (!have_emu) return err,
                    else => return err,
                }
            }
            return createKind(gpa, io, .emu, opts);
        },
    };
}

fn createKind(gpa: std.mem.Allocator, io: std.Io, k: Kind, opts: Options) CreateError!Backend {
    return switch (k) {
        .hvf => .{ .hvf = try hvf.Backend.create(gpa, io, opts) },
        .emu => .{ .emu = try emu.Backend.create(gpa, io, opts) },
    };
}

pub const Backend = union(Kind) {
    hvf: *hvf.Backend,
    emu: *emu.Backend,

    pub fn kind(b: Backend) Kind {
        return b;
    }
    pub fn destroy(b: Backend) void {
        switch (b) {
            inline else => |p| p.destroy(),
        }
    }
    pub fn maxVcpus(b: Backend) Error!u32 {
        return switch (b) {
            inline else => |p| p.maxVcpus(),
        };
    }
    /// Returns zeroed, page-aligned memory that address spaces can map.
    pub fn allocPages(b: Backend, n: usize) Error![]align(page_size) u8 {
        return switch (b) {
            inline else => |p| p.allocPages(n),
        };
    }
    /// Returns a whole allocation from `allocPages`, no longer mapped.
    pub fn freePages(b: Backend, mem: []align(page_size) u8) void {
        switch (b) {
            inline else => |p| p.freePages(mem),
        }
    }
    pub fn newAddressSpace(b: Backend) CreateError!AddressSpace {
        return switch (b) {
            inline else => |p, k| @unionInit(AddressSpace, @tagName(k), try p.newAddressSpace()),
        };
    }
    /// Must be called on the thread that will run the vCPU.
    pub fn createVcpu(b: Backend) CreateError!Vcpu {
        return switch (b) {
            inline else => |p, k| @unionInit(Vcpu, @tagName(k), try p.createVcpu()),
        };
    }
};

/// One address space per Plan 9 process.
pub const AddressSpace = union(enum) {
    hvf: *hvf.AddressSpace,
    emu: *emu.AddressSpace,
    /// A translate-only stand-in for unit tests of guest-memory code.
    fake: Fake,

    pub const Fake = struct {
        ctx: *anyopaque,
        translate: *const fn (*anyopaque, u64, u64) ?[]u8,
    };

    pub fn initFake(ctx: anytype, comptime f: fn (@TypeOf(ctx), u64, u64) ?[]u8) AddressSpace {
        const T = @TypeOf(ctx);
        return .{ .fake = .{ .ctx = ctx, .translate = struct {
            fn t(p: *anyopaque, va: u64, len: u64) ?[]u8 {
                return f(@as(T, @ptrCast(@alignCast(p))), va, len);
            }
        }.t } };
    }

    /// Frees the space's own state; mapped pages belong to the caller.
    pub fn destroy(as: AddressSpace) void {
        switch (as) {
            .fake => {},
            inline else => |p| p.destroy(),
        }
    }
    /// Maps memory from `Backend.allocPages` at a page-aligned user address.
    pub fn map(as: AddressSpace, va: u64, mem: []align(page_size) u8, perms: Perms) CreateError!void {
        return switch (as) {
            .fake => error.NotImplemented,
            inline else => |p| p.map(va, mem, perms),
        };
    }
    /// Removes the mapping `map` made at `va`; its pages stay allocated.
    /// vCPUs running the space see the change from their next run.
    pub fn unmap(as: AddressSpace, va: u64) void {
        switch (as) {
            .fake => {},
            inline else => |p| p.unmap(va),
        }
    }
    /// Host view of [va, va+len) if it lies within one mapping.
    pub fn translate(as: AddressSpace, va: u64, len: u64) ?[]u8 {
        return switch (as) {
            .fake => |f| f.translate(f.ctx, va, len),
            inline else => |p| p.translate(va, len),
        };
    }
};

pub const Vcpu = union(Kind) {
    hvf: hvf.Vcpu,
    emu: emu.Vcpu,

    pub fn destroy(v: *Vcpu) void {
        switch (v.*) {
            inline else => |*p| p.destroy(),
        }
    }
    pub fn setAddressSpace(v: *Vcpu, as: AddressSpace) Error!void {
        return switch (v.*) {
            inline else => |*p, k| p.setAddressSpace(@field(as, @tagName(k))),
        };
    }
    /// Blocks until the next exit.
    pub fn run(v: *Vcpu) Error!Exit {
        return switch (v.*) {
            inline else => |*p| p.run(),
        };
    }
    pub fn getUreg(v: *Vcpu, u: *Ureg) void {
        switch (v.*) {
            inline else => |*p| p.getUreg(u),
        }
    }
    pub fn setUreg(v: *Vcpu, u: *const Ureg) void {
        switch (v.*) {
            inline else => |*p| p.setUreg(u),
        }
    }
    /// Reads the FP/SIMD registers and thread pointer.
    pub fn getExtra(v: *Vcpu, x: *Extra) Error!void {
        return switch (v.*) {
            inline else => |*p| p.getExtra(x),
        };
    }
    pub fn setExtra(v: *Vcpu, x: *const Extra) Error!void {
        return switch (v.*) {
            inline else => |*p| p.setExtra(x),
        };
    }
    /// Makes `run` return `.interrupted` soon. Safe to call from any thread.
    pub fn kick(v: *Vcpu) void {
        switch (v.*) {
            inline else => |*p| p.kick(),
        }
    }
};
