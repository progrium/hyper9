//! Lockstep: a T0 against Unicorn, an instruction at a time, for arm64
//! (ha64) and i386 (h86). design/0019-zig-interpreter.md's lockstep,
//! generalized to both guests and kept free of either T0's types.
//!
//! Unicorn runs on a mirror: its own copies of the T0's pages, mapped with
//! `uc_mem_map_ptr` at the same guest addresses and permissions. Each step,
//! the caller runs one T0 instruction and `Engine.step` runs one in
//! Unicorn; then the caller compares the two in a canonical form (`A64`,
//! `X86`) with `diff`, and the memory with `diffMemory`. At a syscall the
//! caller serves it once, on T0's memory, then calls `sync` to copy T0's
//! pages and state into the mirror.
//!
//! It needs Unicorn (GPLv2), so it's built only for the test tools, with
//! -Demu=unicorn: `zig build fuzz-a64` and `fuzz-x86` use it, and so will
//! a lockstep vmm backend once ha64 and h86 are vmm backends.

const std = @import("std");
const uc = @import("unicorn");

pub const page_size = 4096;

pub const Arch = enum { arm64, i386 };

/// arm64 user state, canonical.
pub const A64 = struct {
    x: [31]u64 = @splat(0),
    sp: u64 = 0,
    pc: u64 = 0,
    /// N Z C V in bits 31..28.
    nzcv: u32 = 0,
    v: [32]u128 = @splat(0),
    fpcr: u32 = 0,
    fpsr: u32 = 0,
    tpidr: u64 = 0,
};

/// i386 user state, canonical. FP and SSE come with h86's B3.
pub const X86 = struct {
    /// EAX ECX EDX EBX ESP EBP ESI EDI, in encoding order.
    r: [8]u32 = @splat(0),
    eip: u32 = 0,
    eflags: u32 = 0x202,
};

pub fn State(comptime arch: Arch) type {
    return switch (arch) {
        .arm64 => A64,
        .i386 => X86,
    };
}

/// x86 flags that instructions define (CF PF AF ZF SF OF, DF).
pub const x86_status_flags: u32 = 0x8d5 | 0x400;

/// A mapping of the T0's memory.
pub const Region = struct {
    va: u64,
    mem: []u8,
    read: bool = true,
    write: bool = false,
    exec: bool = false,
};

/// How one Unicorn step ended.
pub const Stop = union(enum) {
    /// It retired; the PC is the next instruction.
    next,
    /// A system call (SVC; INT $64 or INT $0x80), PC past it.
    syscall,
    /// BRK with the PC at it; INT3 with EIP past it.
    breakpoint,
    /// A memory access fault at this address; PC at the instruction.
    fault: struct { addr: u64, write: bool, exec: bool },
    /// An undefined instruction.
    undef,
    /// Another exception (x86 #DE, #GP, ...), by vector.
    exception: u32,
};

// QEMU's exception numbers, as UC_HOOK_INTR passes them.
const arm64_excp_udef = 1;
const arm64_excp_swi = 2;
const arm64_excp_bkpt = 7;
const x86_vector_bp = 3;
const x86_vector_ud = 6;
const x86_vector_plan9 = 64;
const x86_vector_linux = 0x80;
/// Where the i386 engine's GDT lives (as in vmm/emu.zig): flat 32-bit code
/// and data, so segment loads keep the 32-bit stack.
const gdt_va: u64 = 0xFFFF_F000;

pub const Error = error{ Unicorn, OutOfMemory };

fn ok(e: uc.uc_err) Error!void {
    if (e != uc.UC_ERR_OK) {
        std.debug.print("lockstep: unicorn: {s}\n", .{uc.uc_strerror(e)});
        return error.Unicorn;
    }
}

pub fn Engine(comptime arch: Arch) type {
    return struct {
        const Self = @This();
        pub const St = State(arch);

        gpa: std.mem.Allocator,
        engine: *uc.uc_engine,
        mirrors: []Mirror,
        gdt: ?[]align(page_size) u8 = null,
        stop: ?Stop = null,
        fault: ?Stop = null,

        const Mirror = struct { va: u64, t0: []u8, copy: []align(page_size) u8 };

        pub fn init(gpa: std.mem.Allocator, regions: []const Region) Error!*Self {
            const s = try gpa.create(Self);
            errdefer gpa.destroy(s);
            const a: uc.uc_arch, const mode: uc.uc_mode = switch (arch) {
                .arm64 => .{ uc.UC_ARCH_ARM64, uc.UC_MODE_ARM },
                .i386 => .{ uc.UC_ARCH_X86, uc.UC_MODE_32 },
            };
            var engine: ?*uc.uc_engine = null;
            try ok(uc.uc_open(a, mode, &engine));
            errdefer _ = uc.uc_close(engine);
            s.* = .{ .gpa = gpa, .engine = engine.?, .mirrors = try gpa.alloc(Mirror, regions.len) };
            var made: usize = 0;
            errdefer {
                for (s.mirrors[0..made]) |m| gpa.free(m.copy);
                gpa.free(s.mirrors);
            }
            for (regions, 0..) |r, i| {
                std.debug.assert(r.va % page_size == 0 and r.mem.len % page_size == 0);
                const copy = try gpa.alignedAlloc(u8, .fromByteUnits(page_size), r.mem.len);
                @memcpy(copy, r.mem);
                s.mirrors[i] = .{ .va = r.va, .t0 = r.mem, .copy = copy };
                made += 1;
                var p: u32 = 0;
                if (r.read) p |= uc.UC_PROT_READ;
                if (r.write) p |= uc.UC_PROT_WRITE;
                if (r.exec) p |= uc.UC_PROT_EXEC;
                try ok(uc.uc_mem_map_ptr(s.engine, r.va, r.mem.len, p, copy.ptr));
            }
            var h: uc.uc_hook = 0;
            try ok(uc.uc_hook_add(s.engine, &h, uc.UC_HOOK_INTR, @ptrCast(@constCast(&onIntr)), s, 1, 0));
            try ok(uc.uc_hook_add(s.engine, &h, uc.UC_HOOK_MEM_INVALID, @ptrCast(@constCast(&onMemInvalid)), s, 1, 0));
            if (arch == .i386) try s.flatSegments();
            if (arch == .arm64) {
                // CNTKCTL_EL1: EL0 may read the counter, as on Linux and HVF.
                var cp: uc.uc_arm64_cp_reg = .{ .crn = 14, .crm = 1, .op0 = 3, .op1 = 0, .op2 = 0, .val = 3 };
                try ok(uc.uc_reg_write(s.engine, uc.UC_ARM64_REG_CP_REG, &cp));
            }
            return s;
        }

        fn flatSegments(s: *Self) Error!void {
            const g = try s.gpa.alignedAlloc(u8, .fromByteUnits(page_size), page_size);
            @memset(g, 0);
            s.gdt = g;
            std.mem.writeInt(u64, g[8..16], 0x00cf9b00_0000ffff, .little);
            std.mem.writeInt(u64, g[16..24], 0x00cf9300_0000ffff, .little);
            try ok(uc.uc_mem_map_ptr(s.engine, gdt_va, page_size, uc.UC_PROT_READ, g.ptr));
            var gdtr: uc.uc_x86_mmr = .{ .selector = 0, .base = gdt_va, .limit = 3 * 8 - 1, .flags = 0 };
            try ok(uc.uc_reg_write(s.engine, uc.UC_X86_REG_GDTR, &gdtr));
            inline for (.{ .{ uc.UC_X86_REG_CS, 0x08 }, .{ uc.UC_X86_REG_SS, 0x10 }, .{ uc.UC_X86_REG_DS, 0x10 }, .{ uc.UC_X86_REG_ES, 0x10 } }) |r| {
                var v: u16 = r[1];
                try ok(uc.uc_reg_write(s.engine, r[0], &v));
            }
        }

        pub fn deinit(s: *Self) void {
            _ = uc.uc_close(s.engine);
            for (s.mirrors) |m| s.gpa.free(m.copy);
            s.gpa.free(s.mirrors);
            if (s.gdt) |g| s.gpa.free(g);
            s.gpa.destroy(s);
        }

        fn onIntr(_: ?*uc.uc_engine, intno: u32, data: ?*anyopaque) callconv(.c) void {
            const s: *Self = @ptrCast(@alignCast(data));
            s.stop = switch (arch) {
                .arm64 => switch (intno) {
                    arm64_excp_swi => .syscall,
                    arm64_excp_bkpt => .breakpoint,
                    arm64_excp_udef => .undef,
                    else => .{ .exception = intno },
                },
                .i386 => switch (intno) {
                    x86_vector_plan9, x86_vector_linux => .syscall,
                    x86_vector_bp => .breakpoint,
                    x86_vector_ud => .undef,
                    else => .{ .exception = intno },
                },
            };
            _ = uc.uc_emu_stop(s.engine);
        }

        fn onMemInvalid(_: ?*uc.uc_engine, kind: uc.uc_mem_type, addr: u64, _: c_int, _: i64, data: ?*anyopaque) callconv(.c) bool {
            const s: *Self = @ptrCast(@alignCast(data));
            const write = kind == uc.UC_MEM_WRITE_UNMAPPED or kind == uc.UC_MEM_WRITE_PROT;
            const exec = kind == uc.UC_MEM_FETCH_UNMAPPED or kind == uc.UC_MEM_FETCH_PROT;
            if (s.fault == null) s.fault = .{ .fault = .{ .addr = addr, .write = write, .exec = exec } };
            return false;
        }

        /// Runs one instruction in Unicorn.
        pub fn step(s: *Self) Error!Stop {
            s.stop = null;
            s.fault = null;
            const at = s.pc();
            const e = uc.uc_emu_start(s.engine, at, std.math.maxInt(u64), 0, 1);
            if (s.fault) |f| {
                // Unicorn leaves the PC wherever QEMU was; T0s put it at
                // the faulting instruction.
                s.setPc(at);
                return f;
            }
            if (s.stop) |st| return st;
            return switch (e) {
                uc.UC_ERR_OK => .next,
                uc.UC_ERR_INSN_INVALID => .undef,
                uc.UC_ERR_EXCEPTION => .{ .exception = 0 },
                else => blk: {
                    try ok(e);
                    break :blk .next;
                },
            };
        }

        pub fn pc(s: *Self) u64 {
            var v: u64 = 0;
            _ = uc.uc_reg_read(s.engine, if (arch == .arm64) uc.UC_ARM64_REG_PC else uc.UC_X86_REG_EIP, &v);
            return if (arch == .i386) v & 0xffffffff else v;
        }

        fn setPc(s: *Self, v: u64) void {
            var x = v;
            _ = uc.uc_reg_write(s.engine, if (arch == .arm64) uc.UC_ARM64_REG_PC else uc.UC_X86_REG_EIP, &x);
        }

        fn rd(s: *Self, comptime T: type, reg: c_int) T {
            var v: T = 0;
            _ = uc.uc_reg_read(s.engine, reg, &v);
            return v;
        }

        fn wr(s: *Self, comptime T: type, reg: c_int, v: T) Error!void {
            var x = v;
            try ok(uc.uc_reg_write(s.engine, reg, &x));
        }

        fn xreg(i: usize) c_int {
            return switch (i) {
                29 => uc.UC_ARM64_REG_X29,
                30 => uc.UC_ARM64_REG_X30,
                else => uc.UC_ARM64_REG_X0 + @as(c_int, @intCast(i)),
            };
        }

        const x86_regs = [8]c_int{ uc.UC_X86_REG_EAX, uc.UC_X86_REG_ECX, uc.UC_X86_REG_EDX, uc.UC_X86_REG_EBX, uc.UC_X86_REG_ESP, uc.UC_X86_REG_EBP, uc.UC_X86_REG_ESI, uc.UC_X86_REG_EDI };

        pub fn getState(s: *Self) St {
            var st: St = .{};
            switch (arch) {
                .arm64 => {
                    for (0..31) |i| st.x[i] = s.rd(u64, xreg(i));
                    st.sp = s.rd(u64, uc.UC_ARM64_REG_SP);
                    st.pc = s.rd(u64, uc.UC_ARM64_REG_PC);
                    st.nzcv = @truncate(s.rd(u64, uc.UC_ARM64_REG_NZCV));
                    for (0..32) |i| st.v[i] = s.rd(u128, uc.UC_ARM64_REG_Q0 + @as(c_int, @intCast(i)));
                    st.fpcr = @truncate(s.rd(u64, uc.UC_ARM64_REG_FPCR));
                    st.fpsr = @truncate(s.rd(u64, uc.UC_ARM64_REG_FPSR));
                    st.tpidr = s.rd(u64, uc.UC_ARM64_REG_TPIDR_EL0);
                },
                .i386 => {
                    for (x86_regs, 0..) |r, i| st.r[i] = s.rd(u32, r);
                    st.eip = s.rd(u32, uc.UC_X86_REG_EIP);
                    st.eflags = s.rd(u32, uc.UC_X86_REG_EFLAGS);
                },
            }
            return st;
        }

        pub fn setState(s: *Self, st: St) Error!void {
            switch (arch) {
                .arm64 => {
                    for (0..31) |i| try s.wr(u64, xreg(i), st.x[i]);
                    try s.wr(u64, uc.UC_ARM64_REG_SP, st.sp);
                    try s.wr(u64, uc.UC_ARM64_REG_PC, st.pc);
                    try s.wr(u64, uc.UC_ARM64_REG_NZCV, st.nzcv);
                    for (0..32) |i| try s.wr(u128, uc.UC_ARM64_REG_Q0 + @as(c_int, @intCast(i)), st.v[i]);
                    try s.wr(u64, uc.UC_ARM64_REG_FPCR, st.fpcr);
                    try s.wr(u64, uc.UC_ARM64_REG_FPSR, st.fpsr);
                    try s.wr(u64, uc.UC_ARM64_REG_TPIDR_EL0, st.tpidr);
                },
                .i386 => {
                    for (x86_regs, 0..) |r, i| try s.wr(u32, r, st.r[i]);
                    try s.wr(u32, uc.UC_X86_REG_EIP, st.eip);
                    try s.wr(u32, uc.UC_X86_REG_EFLAGS, st.eflags);
                },
            }
        }

        /// Copies T0's memory and state into the mirror (after a syscall
        /// served on T0's side, or to resynchronize after a reported
        /// divergence).
        pub fn sync(s: *Self, st: St) Error!void {
            for (s.mirrors) |m| @memcpy(m.copy, m.t0);
            // Stores to code: drop Unicorn's translations of the mirror.
            for (s.mirrors) |m| _ = uc.uc_ctl(s.engine, uc_ctl_tb_remove, m.va, m.va + m.copy.len);
            try s.setState(st);
        }

        // uc_ctl_remove_cache: UC_CTL_WRITE(UC_CTL_TB_REMOVE_CACHE, 2).
        const uc_ctl_tb_remove: c_uint = uc.UC_CTL_TB_REMOVE_CACHE | (2 << 26) | (1 << 30);

        /// Writes each byte where T0's memory and the mirror differ (up to
        /// a few); returns whether any do.
        pub fn diffMemory(s: *Self, w: *std.Io.Writer) bool {
            var n: usize = 0;
            for (s.mirrors) |m| {
                if (std.mem.eql(u8, m.t0, m.copy)) continue;
                for (m.t0, m.copy, 0..) |a, b, i| if (a != b) {
                    if (n < 16) w.print("mem {x}: T0 {x:0>2}, unicorn {x:0>2}\n", .{ m.va + i, a, b }) catch {};
                    n += 1;
                };
            }
            if (n > 16) w.print("... and {d} more bytes\n", .{n - 16}) catch {};
            return n != 0;
        }
    };
}

/// Divergences where T0 is architectural and Unicorn isn't. The caller
/// stops comparing the program there (T0 has faulted; Unicorn ran on),
/// and counts them by name.
pub const Known = enum {
    /// A misaligned STXR or STXP with no monitor: an alignment fault,
    /// where QEMU returns status 1 without checking alignment.
    misaligned_stxr_without_monitor,
    /// A misaligned LDAR or STLR: an alignment fault, where Unicorn allows
    /// it within 16 bytes.
    misaligned_ldar_stlr,
};

/// Whether arm64 instruction `word`, on which T0 took an alignment fault
/// and Unicorn stopped with `u`, is a known divergence.
pub fn knownA64(word: u32, t0_alignment_fault: bool, u: Stop) ?Known {
    if (!t0_alignment_fault or u != .next) return null;
    if (word & 0x3FE07C00 == 0x08007C00 or word & 0xBFE00000 == 0x88200000) return .misaligned_stxr_without_monitor;
    const ldar_stlr = word & 0x3FFFFC00;
    if (ldar_stlr == 0x08DFFC00 or ldar_stlr == 0x089FFC00) return .misaligned_ldar_stlr;
    return null;
}

/// Writes each difference between T0's state `a` and Unicorn's `b`;
/// returns whether there were any. `flag_mask` limits the x86 flags
/// compared to those the instruction defines.
pub fn diff(comptime arch: Arch, a: State(arch), b: State(arch), flag_mask: u32, w: *std.Io.Writer) bool {
    var bad = false;
    switch (arch) {
        .arm64 => {
            for (a.x, b.x, 0..) |x, y, i| if (x != y) {
                w.print("x{d}: T0 {x}, unicorn {x}\n", .{ i, x, y }) catch {};
                bad = true;
            };
            inline for (.{ "sp", "pc", "nzcv", "fpcr", "fpsr", "tpidr" }) |f| if (@field(a, f) != @field(b, f)) {
                w.print(f ++ ": T0 {x}, unicorn {x}\n", .{ @field(a, f), @field(b, f) }) catch {};
                bad = true;
            };
            for (a.v, b.v, 0..) |x, y, i| if (x != y) {
                w.print("q{d}: T0 {x:0>32}, unicorn {x:0>32}\n", .{ i, x, y }) catch {};
                bad = true;
            };
        },
        .i386 => {
            const names = [8][]const u8{ "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi" };
            for (a.r, b.r, names) |x, y, n| if (x != y) {
                w.print("{s}: T0 {x}, unicorn {x}\n", .{ n, x, y }) catch {};
                bad = true;
            };
            if (a.eip != b.eip) {
                w.print("eip: T0 {x}, unicorn {x}\n", .{ a.eip, b.eip }) catch {};
                bad = true;
            }
            if ((a.eflags ^ b.eflags) & flag_mask != 0) {
                w.print("eflags: T0 {x}, unicorn {x} (compared {x})\n", .{ a.eflags, b.eflags, flag_mask }) catch {};
                bad = true;
            }
        },
    }
    return bad;
}

// ---------------------------------------------------------------- tests

test "lockstep: unicorn steps arm64 one instruction at a time" {
    const gpa = std.testing.allocator;
    var code: [page_size]u8 align(page_size) = @splat(0);
    var data: [page_size]u8 align(page_size) = @splat(0);
    const prog = [_]u32{
        0xD2800540, // mov x0, #42
        0xF9000020, // str x0, [x1]
        0xF9400022, // ldr x2, [x1]
        0xF9400060, // ldr x0, [x3]      (unmapped)
        0xD4000001, // svc #0
    };
    for (prog, 0..) |w, i| std.mem.writeInt(u32, code[i * 4 ..][0..4], w, .little);
    const e = try Engine(.arm64).init(gpa, &.{ .{ .va = 0x1000, .mem = &code, .exec = true }, .{ .va = 0x20000, .mem = &data, .write = true } });
    defer e.deinit();
    try e.setState(.{ .pc = 0x1000, .x = blk: {
        var x: [31]u64 = @splat(0);
        x[1] = 0x20000;
        x[3] = 0x90000;
        break :blk x;
    } });
    try std.testing.expectEqual(Stop.next, try e.step());
    try std.testing.expectEqual(@as(u64, 42), e.getState().x[0]);
    try std.testing.expectEqual(Stop.next, try e.step());
    try std.testing.expectEqual(Stop.next, try e.step());
    try std.testing.expectEqual(@as(u64, 42), e.getState().x[2]);
    // The mirror took the store; T0's page didn't.
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expect(e.diffMemory(&w));
    const f = try e.step();
    try std.testing.expectEqual(@as(u64, 0x90000), f.fault.addr);
    try std.testing.expectEqual(@as(u64, 0x100c), e.pc());
    var st = e.getState();
    st.pc += 4;
    try e.setState(st);
    try std.testing.expectEqual(Stop.syscall, try e.step());
    try std.testing.expectEqual(@as(u64, 0x1014), e.pc());
}

test "lockstep: unicorn steps i386 one instruction at a time" {
    const gpa = std.testing.allocator;
    var code: [page_size]u8 align(page_size) = @splat(0);
    var data: [page_size]u8 align(page_size) = @splat(0);
    const prog = [_]u8{
        0xb8, 0x2a, 0x00, 0x00, 0x00, // mov eax, 42
        0x89, 0x01, // mov [ecx], eax
        0x03, 0x01, // add eax, [ecx]
        0xf7, 0xf3, // div ebx   (ebx = 0: #DE)
        0xcd, 0x40, // int $64
    };
    @memcpy(code[0..prog.len], &prog);
    const e = try Engine(.i386).init(gpa, &.{ .{ .va = 0x1000, .mem = &code, .exec = true }, .{ .va = 0x20000, .mem = &data, .write = true } });
    defer e.deinit();
    try e.setState(.{ .eip = 0x1000, .r = .{ 0, 0x20000, 0, 0, 0x20800, 0, 0, 0 } });
    try std.testing.expectEqual(Stop.next, try e.step());
    try std.testing.expectEqual(Stop.next, try e.step());
    try std.testing.expectEqual(Stop.next, try e.step());
    try std.testing.expectEqual(@as(u32, 84), e.getState().r[0]);
    const de = try e.step();
    try std.testing.expect(de == .exception);
    var st = e.getState();
    st.eip = 0x100b;
    try e.setState(st);
    try std.testing.expectEqual(Stop.syscall, try e.step());
    try std.testing.expectEqual(@as(u32, 0x100d), e.getState().eip);
}
