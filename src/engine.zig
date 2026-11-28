//! The engines: what runs a process's code and turns its system calls and
//! faults into exits. See spec/engines.md.
//!
//! Each engine module provides Engine, AddressSpace and Vcpu types with the
//! same methods; the unions below pick one at run time. Engines that aren't
//! built into this h9 are replaced by engine/none.zig.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const aout = @import("abi/plan9/aout.zig");
pub const arm64 = @import("arch/arm64.zig");
pub const amd64 = @import("arch/amd64.zig");
pub const ia32 = @import("arch/i386.zig"); // `i386` is a primitive type name

const hvf = if (have_hvf) @import("engine/hvf.zig") else @import("engine/none.zig");
const kvm = if (have_kvm) @import("engine/kvm.zig") else @import("engine/none.zig");
const whp = if (have_whp) @import("engine/whp.zig") else @import("engine/none.zig");
/// hcpu: h9's own CPUs, which pick ha64, h86, or hx64 by the binary's
/// architecture (engine/hcpu/engine.zig), on every target with a JIT.
const hcpu_engine = if (have_hcpu) @import("engine/hcpu/engine.zig") else @import("engine/none.zig");
const sud = if (have_sud) @import("engine/sud.zig") else @import("engine/none.zig");

const have_hvf = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;
const have_kvm = builtin.os.tag == .linux and (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64);
const have_whp = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64;
/// hcpu is built in on arm64 and x86-64 targets and the web host.
const have_hcpu = build_options.emu == .hcpu;
/// The sud engine (design/epoch-0/native-backend.md): Linux x86_64 for now.
const have_sud = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64;
/// The web host (design/epoch-0/browser-host.md), whose engine is hcpu.
const web = builtin.os.tag == .wasi;

pub const Arch = aout.Arch;

/// The architecture of 9front binaries that run natively on this host.
pub const host_arch: ?Arch = switch (builtin.cpu.arch) {
    .aarch64 => .arm64,
    .x86_64 => .amd64,
    // The web host runs 386 binaries on h86 (design/epoch-0/browser-host.md).
    .wasm32 => .i386,
    else => null,
};

/// What `--engine` asks for: a concrete engine, or `auto`.
pub const Choice = enum { auto, hvf, kvm, whp, hcpu, sud };

/// A concrete engine.
pub const Kind = enum {
    hvf,
    kvm,
    whp,
    /// h9's own CPUs.
    hcpu,
    /// Guest code on the host CPU in a stub process, with no hypervisor,
    /// on Syscall User Dispatch (design/epoch-0/native-backend.md).
    sud,

    pub fn built(k: Kind) bool {
        return switch (k) {
            .hvf => have_hvf,
            .kvm => have_kvm,
            .whp => have_whp,
            .hcpu => have_hcpu,
            .sud => have_sud,
        };
    }
};

pub const Error = error{
    /// The host has no usable hypervisor, or h9 lacks the access it needs.
    HypervisorUnavailable,
    HypervisorFailed,
    OutOfGuestMemory,
    BadAddress,
    /// The engine isn't compiled into this h9.
    EngineNotBuilt,
    /// The engine can't run binaries for this architecture.
    WrongArch,
    NotImplemented,
};

pub const CreateError = Error || std.mem.Allocator.Error;

pub const Options = struct {
    arch: Arch,
    /// Cap on the guest memory the engine hands out, page tables included;
    /// null means the engine's default region size.
    memory: ?u64 = null,
};

/// The guest memory region when no cap is given.
/// The engines' own allocations (decode caches, the JIT's state): on the
/// web host, h9's allocator (web/heap.zig), whose wasm memory comes in big
/// steps, since V8 does a full GC on each grow.
pub const host_gpa: std.mem.Allocator = if (builtin.cpu.arch == .wasm32) @import("web/heap.zig").allocator else std.heap.smp_allocator;

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
    /// A breakpoint instruction: BRK on arm64 (ESR class 0x3C, or the
    /// breakpoint classes 0x30 and 0x31), INT3 on amd64 and 386. The PC
    /// is left at the BRK, and after the INT3, as 9front leaves it
    /// (design/epoch-0/self-host.md).
    breakpoint,
    interrupted,
    halted,
    other: u64,
};

/// A Plan 9 Ureg in the layout of the process's architecture.
pub const Ureg = union(Arch) {
    arm64: arm64.Ureg,
    amd64: amd64.Ureg,
    i386: ia32.Ureg,

    /// The ABI module for each architecture.
    fn abi(comptime a: Arch) type {
        return switch (a) {
            .arm64 => arm64,
            .amd64 => amd64,
            .i386 => ia32,
        };
    }

    pub fn initExec(which: Arch, entry: u64, sp: u64, tos: u64) Ureg {
        return switch (which) {
            inline else => |a| @unionInit(Ureg, @tagName(a), .initExec(entry, sp, tos)),
        };
    }
    pub fn arch(u: *const Ureg) Arch {
        return std.meta.activeTag(u.*);
    }
    /// Bytes in a user pointer and a stack word.
    pub fn wordSize(u: *const Ureg) u64 {
        return u.arch().wordSize();
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
    /// Returns `v` from a 9front syscall, with the registers 9front's
    /// syscall return doesn't preserve cleared as it clears them (the
    /// architecture's `sysReturn`). Not for the Linux ABI.
    pub fn sysReturn(u: *Ureg, v: u64) void {
        switch (u.*) {
            inline else => |*r| r.sysReturn(v),
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
                const f = abi(a).notifyFrame(r, handler, errmax) orelse break :blk null;
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
                break :blk @unionInit(Ureg, @tagName(a), abi(a).sanitize(g, r));
            },
        };
    }

    /// noted(NSAVE): the handler resumes with its Ureg argument again, in
    /// R0 on arm64 and BP on amd64 (on 386 only on the stack), and the
    /// stack at `new_sp`.
    pub fn setNoteSave(u: *Ureg, new_sp: u64, nureg: u64) void {
        switch (u.*) {
            .i386 => |*r| r.sp = @intCast(new_sp),
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
            .amd64, .i386 => true,
        };
    }
};

/// User state beyond the Ureg that a process keeps across vCPUs: the
/// FP/SIMD registers and the thread pointer. A process that moves between
/// pooled vCPUs, or forks, carries it with it.
pub const Extra = union(Arch) {
    arm64: Arm64Extra,
    amd64: X86Extra,
    i386: X86Extra,

    /// The state at exec: zero, with the x87 control word and MXCSR at
    /// their reset values on x86 (FNINIT's 0x037F, all SSE exceptions
    /// masked).
    pub fn initExec(a: Arch) Extra {
        return switch (a) {
            .arm64 => .{ .arm64 = .{} },
            .amd64 => .{ .amd64 = .init },
            .i386 => .{ .i386 = .init },
        };
    }

    pub fn arch(x: *const Extra) Arch {
        return std.meta.activeTag(x.*);
    }
};

pub const Arm64Extra = struct {
    /// Q0-Q31.
    v: [32]u128 = @splat(0),
    fpcr: u64 = 0,
    fpsr: u64 = 0,
    /// TPIDR_EL0.
    tls: u64 = 0,
};

/// The x87, MMX and SSE state as FXSAVE stores it, and the thread pointer.
pub const X86Extra = struct {
    fx: Fxsave = .{},
    /// FS base on amd64; on 386, the base of Linux's first TLS segment,
    /// GDT entry 6, which set_thread_area sets and selector 0x33 loads.
    tls: u64 = 0,
    /// GS base on amd64 (ARCH_SET_GS), which 64-bit Wine keeps its TEB in.
    gs: u64 = 0,
    /// 386: the bases of TLS entries 7 and 8 (selectors 0x3b and 0x43),
    /// which 32-bit Wine takes one of for %fs, and which of the three
    /// entries set_thread_area has given out (bit 0 is entry 6).
    tls_more: [2]u64 = @splat(0),
    tls_used: u8 = 0,

    pub const init: X86Extra = .{ .fx = .{ .fcw = 0x037f, .mxcsr = 0x1f80 } };
};

/// The 512-byte FXSAVE area (Intel SDM vol. 1, 10.5.1), 16-byte aligned,
/// in the 64-bit layout: on 386, FXSAVE's FPU IP and DP fields are 32-bit
/// offsets with selectors, which `fip` and `fdp` hold as they come, and
/// XMM8-XMM15 are unused.
pub const Fxsave = extern struct {
    fcw: u16 = 0,
    fsw: u16 = 0,
    /// Abridged tag word: bit i set when physical register i isn't empty.
    ftw: u8 = 0,
    _r1: u8 = 0,
    fop: u16 = 0,
    fip: u64 = 0,
    fdp: u64 = 0,
    mxcsr: u32 = 0,
    mxcsr_mask: u32 = 0,
    /// ST0-ST7 (stack order, from TOP), 80 bits each in 16-byte slots.
    st: [8][16]u8 = @splat(@splat(0)),
    xmm: [16]u128 = @splat(0),
    _r2: [96]u8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(Fxsave) == 512);
        std.debug.assert(@alignOf(Fxsave) == 16);
        std.debug.assert(@offsetOf(Fxsave, "mxcsr") == 24);
        std.debug.assert(@offsetOf(Fxsave, "st") == 32);
        std.debug.assert(@offsetOf(Fxsave, "xmm") == 160);
    }
};

/// h9's own emulator (engine/hcpu/engine.zig) when it's the one built in, for
/// benchmarks: its `retired_total`. Null otherwise.
pub const hcpu: ?type = if (have_hcpu) hcpu_engine else null;

/// Guest instructions the emulator has retired so far, where it counts
/// them; null otherwise.
pub fn hcpuRetired() ?u64 {
    return if (comptime hcpu) |z| z.retired_total.load(.monotonic) else null;
}

/// T1's dispatch counts so far (compiled, entries, linked, t0), where
/// the emulator is built in; null otherwise.
pub fn hcpuT1Stats() ?[4]u64 {
    return if (comptime hcpu) |z| z.t1Stats() else null;
}

/// Host addresses of the emulator's last vCPU run (Cpu, guest arena,
/// code region, stack), where it's built in; null otherwise.
pub fn hcpuLayout() ?[4]usize {
    if (comptime hcpu) |z| {
        const l = z.layout;
        return .{ l.cpu, l.arena, l.code, l.stack };
    }
    return null;
}

/// The emulator's name and version ("hcpu (jit)" or "hcpu (interpreter)"), or null if it isn't built in.
pub fn hcpuVersion(buf: []u8) ?[]const u8 {
    return if (have_hcpu) hcpu_engine.version(buf) else null;
}

/// The hypervisor engine for this host, if there is one.
fn hypervisor() ?Kind {
    return if (have_hvf) .hvf else if (have_kvm) .kvm else if (have_whp) .whp else null;
}

/// The sud engine's spin budget count (`Sched.busy` in
/// engine/sud_abi.zig), once a sud engine has been created; null
/// otherwise. For tests.
pub fn sudSpinBusy() ?i32 {
    return if (comptime have_sud) sud.spinBusy() else null;
}

/// Why an engine can't be used here, when the engine can
/// tell more than "unavailable": KVM says whether /dev/kvm is missing or
/// not accessible.
pub fn whyUnavailable(want: Choice) ?[]const u8 {
    return switch (want) {
        .kvm, .auto => if (have_kvm) kvm.whyUnavailable() else null,
        .sud => if (have_sud) sud.whyUnavailable() else null,
        else => null,
    };
}

/// Creates an engine. `.auto` uses the host hypervisor when it can run
/// `opts.arch` binaries, and otherwise hcpu (never the sud engine; see
/// below); check `kind()` to see which one was picked.
pub fn create(gpa: std.mem.Allocator, io: std.Io, want: Choice, opts: Options) CreateError!Engine {
    return switch (want) {
        .hvf => createKind(gpa, io, .hvf, opts),
        .kvm => createKind(gpa, io, .kvm, opts),
        .hcpu => createKind(gpa, io, .hcpu, opts),
        .whp => createKind(gpa, io, .whp, opts),
        .sud => createKind(gpa, io, .sud, opts),
        .auto => {
            if (web) return createKind(gpa, io, .hcpu, opts);
            if (hypervisor()) |k| {
                if (createKind(gpa, io, k, opts)) |b| return b else |err| switch (err) {
                    error.HypervisorUnavailable, error.WrongArch => if (!have_hcpu) return err,
                    else => return err,
                }
            }
            // The sud engine runs guest code in the host process's own
            // address space, sharing it with the stub's control pages and
            // text, so it is not a security boundary (design/epoch-0/native-backend.md,
            // Security; security audit 2026-11-09). `auto` must
            // not select it silently: a host without a hypervisor falls
            // back to hcpu, and sud is reached only by an
            // explicit `--engine sud`, an informed choice for a
            // trusted guest. When the emulator isn't built either, `auto`
            // fails with the hypervisor's reason rather than quietly using
            // sud; the CLI points at `--engine sud` then.
            return createKind(gpa, io, .hcpu, opts);
        },
    };
}

fn createKind(gpa: std.mem.Allocator, io: std.Io, k: Kind, opts: Options) CreateError!Engine {
    return switch (k) {
        .hvf => .{ .impl = .{ .hvf = try hvf.Engine.create(gpa, io, opts) } },
        .kvm => .{ .impl = .{ .kvm = try kvm.Engine.create(gpa, io, opts) } },
        .whp => .{ .impl = .{ .whp = try whp.Engine.create(gpa, io, opts) } },
        .hcpu => .{ .impl = .{ .hcpu = try hcpu_engine.Engine.create(gpa, io, opts) } },
        .sud => .{ .impl = .{ .sud = try sud.Engine.create(gpa, io, opts) } },
    };
}

/// arm64 AT_HWCAP bits (Linux's arch/arm64/include/uapi/asm/hwcap.h).
pub const hwcap_arm64_aes: u64 = 1 << 3;
pub const hwcap_arm64_pmull: u64 = 1 << 4;
pub const hwcap_arm64_sha1: u64 = 1 << 5;
pub const hwcap_arm64_sha2: u64 = 1 << 6;
pub const hwcap_arm64_crc32: u64 = 1 << 7;
pub const hwcap_arm64_atomics: u64 = 1 << 8;

/// A machine's share of an engine's guest memory
/// (design/child-machines.md): the bytes of pages it may hold from
/// `allocPages` at once. Machines that share an engine each have one: a
/// root machine's is its `--memory`, and a child's is reserved from its
/// parent's when it starts, and given back when it ends.
pub const Quota = struct {
    limit: u64,
    // Under a lock, since wasm32 has no 64-bit atomics.
    used: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,

    fn lock(q: *Quota) void {
        while (!q.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    /// Takes `n` bytes, or nothing if fewer are left.
    pub fn take(q: *Quota, n: u64) bool {
        q.lock();
        defer q.mutex.unlock();
        if (n > q.limit - q.used) return false;
        q.used += n;
        return true;
    }

    pub fn give(q: *Quota, n: u64) void {
        q.lock();
        defer q.mutex.unlock();
        q.used -|= n;
    }

    /// The bytes not taken.
    pub fn left(q: *Quota) u64 {
        q.lock();
        defer q.mutex.unlock();
        return q.limit -| q.used;
    }
};

/// An engine, as one machine uses it: the engine itself, which several
/// machines in a process may share (design/child-machines.md), and the
/// machine's quota on its memory, if it has one.
pub const Engine = struct {
    impl: Impl,
    quota: ?*Quota = null,

    pub const Impl = union(Kind) {
        hvf: *hvf.Engine,
        kvm: *kvm.Engine,
        whp: *whp.Engine,
        hcpu: *hcpu_engine.Engine,
        sud: *sud.Engine,
    };

    pub fn kind(b: Engine) Kind {
        return b.impl;
    }
    /// What tables kept per engine are keyed by: the machine's quota when
    /// it has one, so machines sharing an engine don't share them, and
    /// otherwise the engine.
    pub fn id(b: Engine) usize {
        if (b.quota) |q| return @intFromPtr(q);
        return switch (b.impl) {
            inline else => |p| @intFromPtr(p),
        };
    }
    /// The same engine, with another quota.
    pub fn withQuota(b: Engine, q: ?*Quota) Engine {
        return .{ .impl = b.impl, .quota = q };
    }
    pub fn destroy(b: Engine) void {
        switch (b.impl) {
            inline else => |p| p.destroy(),
        }
    }
    /// The optional CPU features beyond `arch`'s baseline that this
    /// engine runs, as Linux's AT_HWCAP bits for that arch: on arm64, the
    /// emulator's Armv8.1 atomics, CRC32, AES with PMULL, SHA1, and
    /// SHA256. Hardware engines say none, and a program
    /// finds what the CPU has by trying.
    pub fn hwcaps(b: Engine, arch: Arch) u64 {
        return switch (b.impl) {
            .hcpu => if (!have_hcpu) 0 else switch (arch) {
                .arm64 => hwcap_arm64_aes | hwcap_arm64_pmull | hwcap_arm64_sha1 | hwcap_arm64_sha2 | hwcap_arm64_crc32 | hwcap_arm64_atomics,
                else => 0,
            },
            else => 0,
        };
    }
    /// Whether a guest's `rdtsc` reads the host's own time stamp count,
    /// so h9 reads the same count the guest does (linux/vclock.zig): the
    /// sud engine's, which runs guest code on the host CPU, and KVM's
    /// on x86, which zeroes each vCPU's TSC offset. The emulators' count
    /// instructions.
    pub fn hostTsc(b: Engine) bool {
        return switch (b.impl) {
            .sud => have_sud,
            .kvm => |p| if (comptime have_kvm and builtin.cpu.arch == .x86_64) p.host_tsc else false,
            else => false,
        };
    }
    pub fn maxVcpus(b: Engine) Error!u32 {
        return switch (b.impl) {
            inline else => |p| p.maxVcpus(),
        };
    }
    /// Returns zeroed, page-aligned memory that address spaces can map,
    /// counted against the quota.
    pub fn allocPages(b: Engine, n: usize) Error![]align(page_size) u8 {
        const bytes = @as(u64, n) * page_size;
        if (b.quota) |q| if (!q.take(bytes)) return error.OutOfGuestMemory;
        errdefer if (b.quota) |q| q.give(bytes);
        return switch (b.impl) {
            inline else => |p| p.allocPages(n),
        };
    }
    /// Returns a whole allocation from `allocPages`, no longer mapped.
    pub fn freePages(b: Engine, mem: []align(page_size) u8) void {
        switch (b.impl) {
            inline else => |p| p.freePages(mem),
        }
        if (b.quota) |q| q.give(mem.len);
    }
    pub fn newAddressSpace(b: Engine) CreateError!AddressSpace {
        return switch (b.impl) {
            inline else => |p, k| @unionInit(AddressSpace, @tagName(k), try p.newAddressSpace()),
        };
    }
    /// Must be called on the thread that will run the vCPU.
    pub fn createVcpu(b: Engine) CreateError!Vcpu {
        return switch (b.impl) {
            inline else => |p, k| @unionInit(Vcpu, @tagName(k), try p.createVcpu()),
        };
    }
};

/// Told when an address space's host backing is lost from outside h9: a
/// sud stub process killed by the OOM killer or a `kill -9`. Every
/// process using the space should die then, as killed by SIGKILL, even
/// one blocked in a system call, which no exit from the space will wake.
/// `call` runs on an engine thread, while the space is still alive, and
/// may post notes but not wait for the processes.
pub const LostHook = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, as: AddressSpace) void,
};

/// One address space per Plan 9 process.
pub const AddressSpace = union(enum) {
    hvf: *hvf.AddressSpace,
    kvm: *kvm.AddressSpace,
    whp: *whp.AddressSpace,
    hcpu: *hcpu_engine.AddressSpace,
    sud: *sud.AddressSpace,
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
    /// Maps memory from `Engine.allocPages` at a page-aligned user address.
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
    /// Returns once no vCPU other than the caller's can still reach what
    /// `unmap` removed (design/epoch-0/linux-threads.md, "TLB shootdown"):
    /// each one running the space has stopped and will see the change
    /// before its next guest instruction. Only then may the host reuse
    /// the pages.
    pub fn shootdown(as: AddressSpace) void {
        switch (as) {
            .fake => {},
            inline else => |p| p.shootdown(),
        }
    }

    /// Copies between `buf` and [va, va+buf.len), which must lie within
    /// one mapping, holding the space's lock across the copy, so an
    /// `unmap` on another thread (after which the caller may free the
    /// pages) waits for it. For reading another process's memory
    /// (/proc/n/mem); page permissions don't apply. Returns false if
    /// the range isn't mapped.
    pub fn copy(as: AddressSpace, va: u64, buf: []u8, dir: enum { read, write }) bool {
        return switch (as) {
            .fake => |f| {
                const mem = f.translate(f.ctx, va, buf.len) orelse return false;
                switch (dir) {
                    .read => @memcpy(buf, mem),
                    .write => @memcpy(mem, buf),
                }
                return true;
            },
            inline else => |p| p.copy(va, buf, dir == .write),
        };
    }

    /// Says the host wrote code at [va, va+len) (a breakpoint through
    /// /proc/n/mem): vCPUs running the space drop what they cached of
    /// the old code before their next run. Safe from any thread.
    pub fn codeChanged(as: AddressSpace, va: u64, len: u64) void {
        switch (as) {
            .fake => {},
            inline else => |p| p.codeChanged(va, len),
        }
    }

    /// Sets the hook told if the space's backing is lost (`LostHook`).
    /// The first hook set stays: every process using a space is in one
    /// run. Cheap once set. Engines whose spaces can't be lost so ignore it.
    pub fn setLostHook(as: AddressSpace, h: LostHook) void {
        switch (as) {
            .fake => {},
            inline else => |p| if (@hasDecl(@TypeOf(p.*), "setLostHook")) p.setLostHook(h),
        }
    }

    /// Whether the space's backing has been lost (`LostHook`): a run that
    /// failed then failed for that, and the process was killed.
    pub fn lost(as: AddressSpace) bool {
        return switch (as) {
            .fake => false,
            inline else => |p| if (@hasDecl(@TypeOf(p.*), "lost")) p.lost() else false,
        };
    }

    /// Says the host wrote `mem`, guest memory it got from this space's
    /// pages (a read into a buffer, a file page filled, pages zeroed for
    /// reuse): an engine that tracks which pages hold code drops what it
    /// decoded or compiled from them. Cheap for pages that hold none.
    pub fn hostWrote(as: AddressSpace, mem: []const u8) void {
        switch (as) {
            .fake => {},
            inline else => |p| if (@hasDecl(@TypeOf(p.*), "hostWrote")) p.hostWrote(mem),
        }
    }
};

test {
    _ = ia32;
    _ = hcpu_engine;
    _ = @import("engine/gphys.zig");
}

pub const Vcpu = union(Kind) {
    hvf: hvf.Vcpu,
    kvm: kvm.Vcpu,
    whp: whp.Vcpu,
    hcpu: hcpu_engine.Vcpu,
    sud: sud.Vcpu,

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
