//! The h86 lifter's tests, on src/jit/check.zig's region check with
//! h86's Guest (check/x86.zig): hand-written programs for each lifted
//! path, and a random program generator (fuzz-x86 in the unit tests).

const std = @import("std");
const check = @import("../check.zig");
const ctx_mod = @import("../ctx.zig");
const mem = @import("../../interp/mem.zig");
const exec = @import("../../interp/x86/exec.zig");
const cpu_mod = @import("../../interp/x86/cpu.zig");
const dec = @import("../../interp/x86/decode.zig");
const table = @import("../../interp/x86/table.zig");

const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;
pub const Cpu = cpu_mod.Cpu;
const page_size = mem.page_size;
const guest = &check.x86.guest;
const native_mod = @import("../emit/native.zig");
const Native = native_mod.Native;

// ---------------------------------------------------------------- machine

/// A test address space: code, data (two pages), stack, and a read-only
/// page, with an unmapped page after the data.
pub const Machine = struct {
    pub const code_va = 0x10000;
    pub const data_va = 0x20000;
    pub const stack_va = 0x30000;
    pub const ro_va = 0x40000;

    code: [2 * page_size]u8 align(page_size) = @splat(0xcc),
    data: [2 * page_size]u8 align(page_size) = @splat(0),
    stack: [page_size]u8 align(page_size) = @splat(0),
    ro: [page_size]u8 align(page_size) = @splat(0x5a),
    regions: [4]mem.Region = undefined,
    map: mem.Map = undefined,

    pub fn init(m: *Machine) void {
        m.regions = .{
            .{ .va = code_va, .mem = &m.code, .exec = true },
            .{ .va = data_va, .mem = &m.data, .write = true },
            .{ .va = stack_va, .mem = &m.stack, .write = true },
            .{ .va = ro_va, .mem = &m.ro },
        };
        m.map = .{ .regions = &m.regions };
    }

    pub fn load(m: *Machine, code: []const u8) void {
        @memset(&m.code, 0xcc);
        @memcpy(m.code[0..code.len], code);
    }

    pub fn cpu(_: *Machine) Cpu {
        var c: Cpu = .{};
        c.eip = code_va;
        c.r[4] = stack_va + page_size / 2;
        c.r[5] = stack_va + page_size / 2 + 64;
        return c;
    }
};

/// How a checked run ended.
pub const Result = struct {
    exit: Exit,
    pc: u64,
    regions: u32,
    retired: u64,
    cpu: Cpu = .{},
    ok: bool = true,
};

/// Runs from `start` region by region: lifts at the PC, checks the region
/// against T0 with `r` (which holds the report of a divergence), commits
/// T1's memory and Cpu, and goes on until an exit that doesn't continue.
/// An instruction the lifter can't start on (an unreadable PC) runs on T0
/// alone. With `native`, each region that agrees under ir_eval is checked
/// again as this host's generated code.
pub fn checkRegions(gpa: std.mem.Allocator, r: *check.Run, map: *const mem.Map, start: Cpu, budget: i64, max_regions: u32, native: ?*Native) !Result {
    const backing = check.mapBacking(map);
    var cpu = start;
    var res: Result = .{ .exit = .chain, .pc = start.eip, .regions = 0, .retired = 0 };
    while (res.regions < max_regions) {
        // Lazy records when every emitter that runs the region lowers them.
        var reg = check.liftOpt(gpa, guest, &backing, cpu.eip, .{ .lazy_eflags = native == null or native_mod.lazy_eflags }) catch |e| switch (e) {
            error.Unsupported => {
                var sh = check.Shadow.init(gpa, backing);
                defer sh.deinit();
                var c: Ctx = .{ .cpu = @intFromPtr(&cpu), .space = @intFromPtr(&sh) };
                const x: Exit = @enumFromInt(check.x86.step(&c));
                sh.commit();
                res.exit = x;
                res.pc = cpu.eip;
                res.cpu = cpu;
                return res;
            },
            else => return e,
        };
        defer reg.deinit(gpa);
        if (!try r.check(.{ .ir_eval = &reg }, std.mem.asBytes(&cpu), .{ .budget = budget })) {
            res.ok = false;
            return res;
        }
        if (native) |n| if (try n.compile(gpa, &reg)) |f| {
            if (!try r.check(.{ .entry = f }, std.mem.asBytes(&cpu), .{ .budget = budget })) {
                res.ok = false;
                return res;
            }
        };
        res.regions += 1;
        const o = r.out[check.Run.t1];
        res.retired += o.retired;
        r.shadow[check.Run.t1].commit();
        @memcpy(std.mem.asBytes(&cpu), r.cpu[check.Run.t1]);
        res.exit = o.exit;
        res.pc = o.pc;
        res.cpu = cpu;
        switch (o.exit) {
            .chain, .indirect => {},
            else => return res,
        }
    }
    return res;
}

/// Where runChecked also checks each region as this host's generated
/// code: the native fuzz tests set it.
pub var run_native: ?*Native = null;

pub fn runChecked(gpa: std.mem.Allocator, m: *Machine, start: Cpu, budget: i64) !Result {
    const r = try check.Run.init(gpa, guest, check.mapBacking(&m.map));
    defer r.deinit();
    const res = try checkRegions(gpa, r, &m.map, start, budget, 1000, run_native);
    if (!res.ok) {
        std.debug.print("h86 region check failed:\n{s}\n", .{r.report.items});
        return error.Diverged;
    }
    if (res.regions == 1000) return error.TooManyRegions;
    return res;
}

/// Runs T0 alone from `start` to its first exit, for comparing whole runs.
pub fn runT0(m: *Machine, start: Cpu) struct { exit: cpu_mod.Exit, cpu: Cpu } {
    var c = start;
    const M = struct {
        m: *Machine,
        pub fn translate(s: *@This(), va: u32, access: cpu_mod.Access) ?[*]u8 {
            for (s.m.regions) |rg| {
                if (va >= rg.va and va - rg.va < rg.mem.len) {
                    const ok = switch (access) {
                        .read => rg.read,
                        .write => rg.write,
                        .exec => rg.exec,
                    };
                    if (!ok) return null;
                    return rg.mem.ptr + (va - @as(u32, @intCast(rg.va)));
                }
            }
            return null;
        }
    };
    var mm: M = .{ .m = m };
    const e = exec.run(&c, &mm, .{ .budget = 1_000_000 });
    return .{ .exit = e, .cpu = c };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectRun(code: []const u8, setup: ?*const fn (*Cpu) void) !Result {
    const gpa = testing.allocator;
    const m = try gpa.create(Machine);
    defer gpa.destroy(m);
    m.init();
    m.load(code);
    var c = m.cpu();
    if (setup) |f| f(&c);
    // The whole run on T0 alone, from a copy of the memory.
    const m0 = try gpa.create(Machine);
    defer gpa.destroy(m0);
    m0.* = m.*;
    m0.init();
    const want = runT0(m0, c);
    const got = try runChecked(gpa, m, c, std.math.maxInt(i64));
    // The checked run, region by region, ends where T0 does.
    try testing.expectEqualSlices(u32, &want.cpu.r, &got.cpu.r);
    try testing.expectEqual(want.cpu.fl.get(), got.cpu.fl.get());
    try testing.expectEqual(@as(u64, want.cpu.eip), got.pc);
    try testing.expect(std.meta.eql(want.cpu.fpu, got.cpu.fpu));
    try testing.expectEqualSlices(u8, &m0.data, &m.data);
    try testing.expectEqualSlices(u8, &m0.stack, &m.stack);
    return got;
}

test "check/x86: a counted loop with memory, flags, and a backward branch" {
    // movl $100, %ecx; xorl %eax, %eax; movl $0x20000, %ebx
    // l: addl %ecx, %eax; addl %ecx, (%ebx); adcl $0, 4(%ebx); decl %ecx; jnz l
    // int $0x80
    const code = [_]u8{
        0xb9, 100,  0,    0,    0,    0x31, 0xc0, 0xbb, 0x00, 0x00, 0x02, 0x00,
        0x01, 0xc8, 0x01, 0x0b, 0x83, 0x53, 0x04, 0x00, 0x49, 0x75, 0xf5, 0xcd,
        0x80,
    };
    const r = try expectRun(&code, null);
    try testing.expectEqual(Exit.svc, r.exit);
    try testing.expectEqual(@as(u64, 3 + 5 * 100 + 1), r.retired);
}

test "check/x86: push, pop, call, ret, leave, and call-next-pop" {
    //   call f; call n; n: popl %esi; pushl $7; popl %edx; int $0x80
    // f: pushl %ebp; movl %esp, %ebp; pushl $5; movl -4(%ebp), %eax; leave; ret
    const code = [_]u8{
        0xe8, 0x0c, 0, 0, 0, // call f (0x11)
        0xe8, 0, 0, 0, 0, // call n
        0x5e, // n: pop esi
        0x6a, 0x07, 0x5a, // push 7; pop edx
        0xcd, 0x80, 0x90, // int $0x80; nop
        0x55, 0x89, 0xe5,
        0x6a, 0x05, 0x8b,
        0x45, 0xfc, 0xc9,
        0xc3,
    };
    const r = try expectRun(&code, null);
    try testing.expectEqual(Exit.svc, r.exit);
}

test "check/x86: calls to PIC thunks lift as moves" {
    //   call tbx; call tcx; addl %ebx, %ecx; int $0x80
    // tbx: movl (%esp), %ebx; ret    tcx: movl (%esp), %ecx; ret
    const code = [_]u8{
        0xe8, 0x0b, 0, 0, 0, // call tbx (0x10)
        0xe8, 0x0a, 0, 0, 0, // call tcx (0x14)
        0x01, 0xd9, // addl %ebx, %ecx
        0xcd, 0x80, 0x90, 0x90, // int $0x80
        0x8b, 0x1c, 0x24, 0xc3, // tbx
        0x8b, 0x0c, 0x24, 0xc3, // tcx
    };
    const r = try expectRun(&code, null);
    try testing.expectEqual(Exit.svc, r.exit);
    try testing.expectEqual(@as(u32, Machine.code_va + 5), r.cpu.r[3]);
    try testing.expectEqual(@as(u64, 3 + 3 + 2), r.retired);
}

test "check/x86: DIV and IDIV, and #DE through the guard" {
    // movl $100, %eax; xorl %edx, %edx; movl $7, %ecx; divl %ecx;
    // movl $-100, %eax; cltd; idivl %ecx; movb $3, %cl; divb %cl;
    // xorl %ecx, %ecx; divl %ecx (#DE)
    const code = [_]u8{
        0xb8, 100,  0,    0,    0,    0x31, 0xd2, 0xb9, 7,    0,    0,    0,    0xf7, 0xf1,
        0xb8, 0x9c, 0xff, 0xff, 0xff, 0x99, 0xf7, 0xf9, 0x66, 0xb8, 0x10, 0x00, 0xb1, 0x03,
        0xf6, 0xf1, 0x31, 0xc9, 0xf7, 0xf1,
    };
    const r = try expectRun(&code, null);
    try testing.expectEqual(Exit.fault, r.exit);
    try testing.expectEqual(@as(u64, Machine.code_va + 32), r.pc);
    // IDIV of INT_MIN by -1 overflows.
    const code2 = [_]u8{ 0xb8, 0, 0, 0, 0x80, 0x99, 0xb9, 0xff, 0xff, 0xff, 0xff, 0xf7, 0xf9, 0xcd, 0x80 };
    const r2 = try expectRun(&code2, null);
    try testing.expectEqual(Exit.fault, r2.exit);
}

test "check/x86: DIV from memory, its #DE, and SAHF and LAHF" {
    // movl $0x20000, %ebx; movl $7, (%ebx); movl $100, %eax; xorl %edx, %edx;
    // divl (%ebx); movb $9, 4(%ebx); movw $300, %ax; divb 4(%ebx);
    // movb $0xd5, %ah; sahf; lahf; movb %ah, %cl; movb $0x00, %ah; sahf;
    // lahf; movl $0, 8(%ebx); idivl 8(%ebx) (#DE)
    const code = [_]u8{
        0xbb, 0x00, 0x00, 0x02, 0x00, 0xc7, 0x03, 7, 0, 0, 0, 0xb8, 100, 0, 0, 0, 0x31, 0xd2,
        0xf7, 0x33, // divl (%ebx)
        0xc6, 0x43, 0x04, 9,    0x66, 0xb8, 0x2c, 0x01, 0xf6, 0x73, 0x04, // movb; movw; divb 4(%ebx)
        0xb4, 0xd5, 0x9e, 0x9f, 0x88, 0xe1, 0xb4, 0x00, 0x9e, 0x9f, 0xc7,
        0x43, 0x08, 0,    0,    0,    0,    0xf7, 0x7b, 0x08,
    };
    const r = try expectRun(&code, null);
    try testing.expectEqual(Exit.fault, r.exit);
    try testing.expectEqual(@as(u64, Machine.code_va + code.len - 3), r.pc);
    try testing.expectEqual(@as(u32, 0xd7), r.cpu.r[1] & 0xff);
}

fn shortRepSetup(c: *Cpu) void {
    c.r[6] = Machine.data_va + 0x2000 - 8;
    c.r[7] = Machine.data_va + 0x100;
    c.r[1] = 10;
}

test "check/x86: short REP counts as IR loops: MOVS faulting mid-copy, CMPS, SCAS, STOS, and zero" {
    // rep movsl: two dwords, then the source runs off the data page.
    const r = try expectRun(&.{ 0xf3, 0xa5, 0xcd, 0x80 }, shortRepSetup);
    try testing.expectEqual(Exit.fault, r.exit);
    try testing.expectEqual(@as(u64, Machine.code_va), r.pc);
    try testing.expectEqual(@as(u32, 8), r.cpu.r[1]);
    // movl $0x20000, %edi; movl $12, %ecx; movb $0x61, %al; rep stosb;
    // movb $0x62, 0x20005; movl $0x20000, %esi; movl $0x20100, %edi;
    // movl $12, %ecx; rep movsb; movl $0x20000, %esi; movl $0x20100, %edi;
    // movl $12, %ecx; movb $0x63, 0x20107; repe cmpsb (stops at 7);
    // movl $0x20000, %edi; movl $9, %ecx; movb $0x62, %al; repne scasb (finds 5);
    // xorl %ecx, %ecx; rep stosb (nothing); std; movl $0x20008, %edi;
    // movl $3, %ecx; rep stosb (down); cld; int $0x80
    const code = [_]u8{
        0xbf, 0,    0,    2,    0,    0xb9, 12,   0,    0,    0,    0xb0, 0x61, 0xf3, 0xaa,
        0xc6, 0x05, 0x05, 0,    2,    0,    0x62, 0xbe, 0,    0,    2,    0,    0xbf, 0,
        1,    2,    0,    0xb9, 12,   0,    0,    0,    0xf3, 0xa4, 0xbe, 0,    0,    2,
        0,    0xbf, 0,    1,    2,    0,    0xb9, 12,   0,    0,    0,    0xc6, 0x05, 0x07,
        1,    2,    0,    0x63, 0xf3, 0xa6, 0xbf, 0,    0,    2,    0,    0xb9, 9,    0,
        0,    0,    0xb0, 0x62, 0xf2, 0xae, 0x31, 0xc9, 0xf3, 0xaa, 0xfd, 0xbf, 8,    0,
        2,    0,    0xb9, 3,    0,    0,    0,    0xf3, 0xaa, 0xfc, 0xcd, 0x80,
    };
    const r2 = try expectRun(&code, null);
    try testing.expectEqual(Exit.svc, r2.exit);
}

fn repSetup(c: *Cpu) void {
    c.r[6] = Machine.data_va + 0xff0;
    c.r[7] = Machine.data_va + 0x1000 - 0x40;
    c.r[1] = 0x1800;
}

test "check/x86: REP MOVS, STOS, and SCAS a page at a time, and a fault mid-copy" {
    // rep movsb (into the unmapped page past the data: faults with ECX exact)
    const r = try expectRun(&.{ 0xf3, 0xa4, 0xcd, 0x80 }, repSetup);
    try testing.expectEqual(Exit.fault, r.exit);
    try testing.expectEqual(@as(u64, Machine.code_va), r.pc);
    // movl $0x20010, %edi; movl $0x1000, %ecx; movl $0x11223344, %eax;
    // rep stosl (runs into the unmapped page too)
    const r2 = try expectRun(&.{ 0xbf, 0x10, 0, 2, 0, 0xb9, 0, 0x08, 0, 0, 0xb8, 0x44, 0x33, 0x22, 0x11, 0xf3, 0xab, 0xcd, 0x80 }, null);
    try testing.expectEqual(Exit.fault, r2.exit);
    // movl $0x20000, %edi; movl $0x900, %ecx; rep stosb (fits);
    // movl $0x20000, %edi; movl $0x2000, %ecx; movb $1, 0x20800; xorl %eax, %eax... repne scasb finds it? (al = 0)
    const code3 = [_]u8{
        0xbf, 0, 0, 2, 0, 0xb9, 0, 0x09, 0, 0, 0xb0, 0x61, 0xf3, 0xaa, // fills 0x900 bytes of 'a'
        0xbf, 0, 0, 2, 0, 0xb9, 0, 0x20, 0, 0, 0xf2, 0xae, // repne scasb for 'a': stops at once
        0xbf, 0,    0, 2, 0, 0xb9, 0, 0x20, 0, 0, 0xf3, 0xae, // repe scasb: stops at 0x900
        0xcd, 0x80,
    };
    const r3 = try expectRun(&code3, null);
    try testing.expectEqual(Exit.svc, r3.exit);
}

test "check/x86: shifts by CL (including 0), 8- and 16-bit operands, SETcc, and CMOVcc" {
    const code = [_]u8{
        0xb8, 0x81, 0x80, 0x00, 0x80, // movl $0x80008081, %eax
        0xb1, 0x00, 0xd3, 0xe0, // movb $0, %cl; shll %cl, %eax (no change)
        0xb1, 0x09, 0xd2, 0xe0, // movb $9, %cl; shlb %cl, %al
        0x66, 0xd3, 0xf8, // sarw %cl, %ax
        0xd1, 0xe8, // shrl $1, %eax
        0x0f, 0x92, 0xc3, // setb %bl
        0x0f, 0x4c, 0xd0, // cmovl %eax, %edx
        0x86, 0xe0, // xchgb %ah, %al
        0x0f, 0xb6, 0xf4, // movzbl %ah, %esi
        0x0f, 0xbf, 0xf8, // movswl %ax, %edi
        0x80, 0xc4, 0x7f, // addb $0x7f, %ah
        0x10, 0xe7, // adcb %ah, %bh
        0x66, 0x19, 0xc2, // sbbw %ax, %dx
        0xf7, 0xe2, // mull %edx
        0x6b, 0xc0, 0xfd, // imull $-3, %eax, %eax
        0xf6, 0xe9, // imulb %cl
        0x0f, 0xc8, // bswap %eax
        0x0f, 0xa3, 0xc8, // btl %ecx, %eax (interp)
        0x72, 0x01, 0x40, // jc +1; incl %eax
        0xf5, 0x98, 0x99, // cmc; cwtl; cltd
        0xcd, 0x80,
    };
    const r = try expectRun(&code, null);
    try testing.expectEqual(Exit.svc, r.exit);
}

fn bitSetup(c: *Cpu) void {
    c.r[0] = 0x12345678;
    c.r[1] = 0x10;
    c.r[3] = Machine.data_va + 0x300;
    c.r[6] = Machine.data_va + 0x100;
    c.r[7] = Machine.data_va + 0x200;
}

test "check/x86: rotates, SHLD, BT*, BSF/BSR, POP to memory, and single string ops" {
    const code = [_]u8{
        0x0f, 0xbc, 0xd0, // bsfl %eax, %edx
        0x0f, 0xbd, 0xd0, // bsrl %eax, %edx
        0xbd, 0x00, 0x00, 0x00, 0x00, // movl $0, %ebp
        0x0f, 0xbc, 0xd5, // bsfl %ebp, %edx (zero: ZF, %edx kept)
        0x0f, 0xab, 0x0b, // btsl %ecx, (%ebx)
        0x0f, 0xba, 0x73, 0x04, 0x03, // btrl $3, 4(%ebx)
        0x0f, 0xbb, 0xc8, // btcl %ecx, %eax
        0x0f, 0xa3, 0x4b, 0xfc, // btl %ecx, -4(%ebx)
        0xd3, 0xc0, // roll %cl, %eax
        0xc0, 0xc8, 0x03, // rorb $3, %al
        0x66, 0xd1, 0xc0, // rolw $1, %ax
        0xd1, 0xd0, // rcll $1, %eax
        0x0f, 0xa4, 0xc2, 0x04, // shldl $4, %eax, %edx
        0x0f, 0xad, 0xc2, // shrdl %cl, %eax, %edx
        0x50, 0x8f, 0x43, 0x08, // pushl %eax; popl 8(%ebx)
        0x50, 0x8f, 0x04, 0x24, // pushl %eax; popl (%esp) (after the pop)
        0x58, // popl %eax
        0xa5, 0xa4, 0x66, 0xa5, // movsl; movsb; movsw
        0xfd, 0xab, 0xac, 0xa7, 0xae, // std; stosl; lodsb; cmpsl; scasb
        0xfc, 0x66, 0xab, 0xa6, // cld; stosw; cmpsb
        0xcd, 0x80,
    };
    const r = try expectRun(&code, &bitSetup);
    try testing.expectEqual(Exit.svc, r.exit);
}

fn x87Setup(c: *Cpu) void {
    c.r[3] = Machine.data_va + 0x100;
}

test "check/x86: x87 through the helper: loads, arithmetic, stores, FCOMI, FNSTSW, and FCMOV" {
    const code = [_]u8{
        0xc7, 0x03, 0x00, 0x00, 0x00, 0x00, // movl $0, (%ebx)
        0xc7, 0x43, 0x04, 0x00, 0x00, 0x24, 0x40, // movl $0x40240000, 4(%ebx) (10.0)
        0xc7, 0x43, 0x0c, 0x00, 0x00, 0xc0, 0x3f, // movl $0x3fc00000, 12(%ebx) (1.5f)
        0x66, 0xc7, 0x43, 0x14, 0x07, 0x00, // movw $7, 20(%ebx)
        0xd9, 0xe8, // fld1
        0xd9, 0xee, // fldz
        0xde, 0xc1, // faddp
        0xdd, 0x03, // fldl (%ebx)
        0xd8, 0x4b, 0x0c, // fmuls 12(%ebx)
        0xdf, 0x43, 0x14, // filds 20(%ebx)
        0xdb, 0xf1, // fcomi %st(1), %st
        0x0f, 0x92, 0xc1, // setb %cl
        0xda, 0xc1, // fcmovb %st(1), %st
        0xd9, 0xc9, // fxch %st(1)
        0xd9, 0xfa, // fsqrt
        0xd9, 0xe0, // fchs
        0xdd, 0x5b, 0x20, // fstpl 32(%ebx)
        0xdb, 0x5b, 0x28, // fistpl 40(%ebx)
        0xdf, 0xe9, // fucomip %st(1), %st
        0xdf, 0xe0, // fnstsw %ax
        0x9e, // sahf
        0xd9, 0x7b, 0x30, // fnstcw 48(%ebx)
        0xd9, 0x6b, 0x30, // fldcw 48(%ebx)
        0xdb, 0x7b, 0x38, // fstpt 56(%ebx)
        0xdb, 0x6b, 0x38, // fldt 56(%ebx)
        0xdd, 0xd8, // fstp %st(0)
        0x9b, // fwait
        0xcd,
        0x80,
    };
    const r = try expectRun(&code, &x87Setup);
    try testing.expectEqual(Exit.svc, r.exit);
    // FCOMI compares 7 with 10 * 1.5: below, so SETB gives 1.
    try testing.expectEqual(@as(u32, 1), r.cpu.r[1] & 0xff);
}

test "check/x86: x87 traps go to T0: a store fault, a crossing store, and #MF" {
    // fld1; movl $0x40000, %ecx; fstpl (%ecx) (read-only): faults with
    // the stack unpopped.
    const r = try expectRun(&.{ 0xd9, 0xe8, 0xb9, 0, 0, 4, 0, 0xdd, 0x19, 0xcd, 0x80 }, null);
    try testing.expectEqual(Exit.fault, r.exit);
    try testing.expectEqual(@as(u64, Machine.code_va + 7), r.pc);
    try testing.expectEqual(@as(u3, 7), r.cpu.fpu.top);
    // fld1; movl $0x20ffc, %ecx; fstpt (%ecx) (crosses into the second
    // data page); fldt (%ecx)
    const r2 = try expectRun(&.{ 0xd9, 0xe8, 0xb9, 0xfc, 0x0f, 2, 0, 0xdb, 0x39, 0xdb, 0x29, 0xcd, 0x80 }, null);
    try testing.expectEqual(Exit.svc, r2.exit);
    // Unmask ZE, divide 1 by 0, and the next waiting instruction raises
    // #MF: movw $0x037b, 0x100(%ebx); fldcw; fld1; fldz; fdivp; fld1
    const r3 = try expectRun(&.{
        0x66, 0xc7, 0x43, 0x30, 0x7b, 0x03, 0xd9, 0x6b, 0x30, 0xd9, 0xe8, 0xd9, 0xee, 0xde, 0xf9, 0xd9, 0xe8, 0xcd, 0x80,
    }, &x87Setup);
    try testing.expectEqual(Exit.fault, r3.exit);
    try testing.expectEqual(@as(u64, Machine.code_va + 15), r3.pc);
}

fn atomSetup(c: *Cpu) void {
    c.r[3] = Machine.data_va + 0x100;
    c.r[0] = 5;
    c.r[1] = 0x77;
    c.r[2] = 0;
}

test "check/x86: atomics through cas, and split locks through T0" {
    const code = [_]u8{
        0xf0, 0x01, 0x03, // lock addl %eax, (%ebx)
        0xf0, 0x0f, 0xc1, 0x43, 0x04, // lock xaddl %eax, 4(%ebx)
        0x87, 0x4b, 0x08, // xchgl %ecx, 8(%ebx)
        0xf0, 0x0f, 0xb1, 0x0b, // lock cmpxchgl %ecx, (%ebx) (fails: (%ebx) is 5)
        0xf0, 0x0f, 0xb1, 0x0b, // again (succeeds: EAX now holds 5)
        0xf0, 0xfe, 0x43, 0x0c, // lock incb 12(%ebx)
        0xf0, 0xf7, 0x5b, 0x10, // lock negl 16(%ebx)
        0xf0, 0x83, 0x53, 0x14, 0x01, // lock adcl $1, 20(%ebx)
        0xf0, 0x0f, 0xc7, 0x4b, 0x18, // lock cmpxchg8b 24(%ebx)
        0xf0, 0x0f, 0xc7, 0x4b, 0x18, // again
        0xf0, 0x01, 0x43, 0x21, // lock addl %eax, 33(%ebx): a split lock
        0xf0, 0x87, 0x43, 0x29, // lock xchgl %eax, 41(%ebx): another
        0x0f, 0xc1, 0xc1, // xaddl %eax, %ecx
        0x0f, 0xb1, 0xd1, // cmpxchgl %edx, %ecx
        0xf0, 0x01, 0xc0, // lock addl %eax, %eax: #UD
    };
    const r = try expectRun(&code, atomSetup);
    try testing.expectEqual(Exit.undef, r.exit);
    // A cas on an unmapped page faults as a write.
    const r2 = try expectRun(&.{ 0xbb, 0, 0, 5, 0, 0xf0, 0x01, 0x03 }, null);
    try testing.expectEqual(Exit.fault, r2.exit);
}

fn fsSetup(c: *Cpu) void {
    c.setTls(Machine.data_va + 0x100);
    c.loadSeg(.fs, cpu_mod.tls_sel) catch unreachable;
}

test "check/x86: FS through its base, and a null GS through the guard" {
    // movl %fs:0x14, %eax; movl $9, %fs:0x18; movl %gs:0, %ecx (#GP)
    const code = [_]u8{ 0x64, 0xa1, 0x14, 0, 0, 0, 0x64, 0xc7, 0x05, 0x18, 0, 0, 0, 9, 0, 0, 0, 0x65, 0x8b, 0x0d, 0, 0, 0, 0 };
    const r = try expectRun(&code, fsSetup);
    try testing.expectEqual(Exit.fault, r.exit);
    try testing.expectEqual(@as(u64, Machine.code_va + 17), r.pc);
}

test "check/x86: faults are exact: a store to read-only memory, and a pop past the stack" {
    // movl $1, %eax; addl %eax, 0x40000 (read-only)
    const r = try expectRun(&.{ 0xb8, 1, 0, 0, 0, 0x01, 0x05, 0, 0, 4, 0 }, null);
    try testing.expectEqual(Exit.fault, r.exit);
    try testing.expectEqual(@as(u64, Machine.code_va + 5), r.pc);
    // incl 0x50000 (unmapped): the read-modify-write faults as a write.
    const r3 = try expectRun(&.{ 0xff, 0x05, 0, 0, 5, 0 }, null);
    try testing.expectEqual(Exit.fault, r3.exit);
    // movl $0x30ffe, %esp; popl %eax (crosses into the unmapped page)
    const r2 = try expectRun(&.{ 0xbc, 0xfe, 0x0f, 3, 0, 0x58, 0xcd, 0x80 }, null);
    try testing.expectEqual(Exit.fault, r2.exit);
}

test "check/x86: a budget stops a loop at its head, and it resumes" {
    const gpa = testing.allocator;
    const m = try gpa.create(Machine);
    defer gpa.destroy(m);
    m.init();
    // movl $1000, %ecx; l: incl %eax; loop l; int $0x80
    m.load(&.{ 0xb9, 0xe8, 0x03, 0, 0, 0x40, 0xe2, 0xfd, 0xcd, 0x80 });
    const c = m.cpu();
    const r = try runChecked(gpa, m, c, 101);
    try testing.expectEqual(Exit.interrupted, r.exit);
    try testing.expectEqual(@as(u64, Machine.code_va + 5), r.pc);
}

// ---------------------------------------------------------------- fuzz-x86

/// Random straight-line programs of the instructions the lifter handles
/// (and some it hands to T0), with forward branches, ending in INT $0x80.
pub const Gen = struct {
    rng: std.Random,
    out: std.ArrayList(u8) = .empty,

    const one_byte = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d,
        0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d,
        0x40, 0x41, 0x42, 0x43, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4d,
        0x4e, 0x4f, 0x50, 0x51, 0x52, 0x53, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a,
        0x5b, 0x5d, 0x5e, 0x5f, 0x68, 0x69, 0x6a, 0x6b, 0x80, 0x81, 0x83, 0x84,
        0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8d, 0x90, 0x91, 0x92, 0x93,
        0x96, 0x97, 0x98, 0x99, 0x9c, 0x9d, 0x9e, 0x9f, 0xa8, 0xa9, 0xb0, 0xb1,
        0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbb, 0xbd, 0xbe,
        0xbf, 0xc0, 0xc1, 0xd0, 0xd1, 0xd2, 0xd3, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9,
        0xfc, 0xfd, 0xfe,
    };
    const two_byte = [_]u8{
        0x40, 0x42, 0x44, 0x45, 0x47, 0x4c, 0x4e, 0x4f, 0x90, 0x92, 0x94, 0x95,
        0x96, 0x9c, 0x9f, 0xa3, 0xa4, 0xa5, 0xab, 0xac, 0xad, 0xaf, 0xb6, 0xb7,
        0xbc, 0xbd, 0xbe, 0xbf, 0xc8, 0xcb, 0xcf, 0xba,
    };

    fn byte(g: *Gen, gpa: std.mem.Allocator, v: u8) !void {
        try g.out.append(gpa, v);
    }

    /// A ModRM byte: mostly registers, else memory through EBX, ESI, or
    /// EDI with a small displacement.
    fn modrm(g: *Gen, gpa: std.mem.Allocator, reg: ?u3) !void {
        const r: u8 = reg orelse g.rng.int(u3);
        if (g.rng.uintLessThan(u8, 10) < 6) return g.byte(gpa, 0xc0 | (r << 3) | g.rng.int(u3));
        const bases = [_]u8{ 3, 6, 7 };
        const base = bases[g.rng.uintLessThan(usize, 3)];
        if (g.rng.boolean()) {
            try g.byte(gpa, (r << 3) | base);
        } else {
            try g.byte(gpa, 0x40 | (r << 3) | base);
            try g.byte(gpa, g.rng.int(u8) & 0x7c);
        }
    }

    pub fn insn(g: *Gen, gpa: std.mem.Allocator) !void {
        const start = g.out.items.len;
        const k = g.rng.uintLessThan(u8, 100);
        if (k < 3) {
            // A string op, with or without REP.
            if (g.rng.boolean()) try g.byte(gpa, if (g.rng.boolean()) 0xf3 else 0xf2);
            const ops = [_]u8{ 0xa4, 0xa5, 0xa6, 0xa7, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf };
            try g.byte(gpa, ops[g.rng.uintLessThan(usize, ops.len)]);
            return;
        }
        if (k < 9) {
            // A short forward branch: Jcc, JMP, LOOP, or JECXZ.
            const ops = [_]u8{ 0x70, 0x72, 0x74, 0x75, 0x76, 0x7c, 0x7e, 0x7f, 0xeb, 0xe2, 0xe3, 0x78 };
            const op = ops[g.rng.uintLessThan(usize, ops.len)];
            try g.byte(gpa, op + if (op < 0x80) g.rng.int(u4) & 0 else 0);
            try g.byte(gpa, g.rng.uintLessThan(u8, 12));
            return;
        }
        if (k < 11) {
            // call-next-pop.
            try g.out.appendSlice(gpa, &.{ 0xe8, 0, 0, 0, 0 });
            try g.byte(gpa, 0x58 + @as(u8, g.rng.uintLessThan(u8, 4)));
            return;
        }
        if (k < 13) try g.byte(gpa, 0x66);
        if (k >= 13 and k < 14) try g.byte(gpa, 0x64);
        var two = false;
        var op: u8 = undefined;
        if (g.rng.uintLessThan(u8, 5) == 0) {
            two = true;
            op = two_byte[g.rng.uintLessThan(usize, two_byte.len)];
            try g.byte(gpa, 0x0f);
        } else op = one_byte[g.rng.uintLessThan(usize, one_byte.len)];
        try g.byte(gpa, op);
        // Room for the ModRM, displacement, and immediate; decoding
        // trims it to the instruction.
        const has_modrm = table.slot(if (two) 0x0f00 | @as(u16, op) else op).modrm;
        if (has_modrm) {
            // FF /0, /1, /6 only (no indirect transfers).
            const reg: ?u3 = if (op == 0xff and !two) ([_]u3{ 0, 1, 6 })[g.rng.uintLessThan(usize, 3)] else if (op == 0xfe and !two) g.rng.int(u1) else null;
            try g.modrm(gpa, reg);
        }
        var buf: [dec.max_len]u8 = undefined;
        for (&buf) |*b| b.* = g.rng.int(u8);
        const n = g.out.items.len - start;
        @memcpy(buf[0..n], g.out.items[start..]);
        const i = dec.decode(&buf) catch {
            g.out.shrinkRetainingCapacity(start);
            return;
        };
        try g.out.appendSlice(gpa, buf[n..i.len]);
    }

    pub fn program(g: *Gen, gpa: std.mem.Allocator, n: usize) ![]const u8 {
        g.out.clearRetainingCapacity();
        for (0..n) |_| try g.insn(gpa);
        try g.out.appendSlice(gpa, &.{ 0xcd, 0x80 });
        return g.out.items;
    }
};

/// A random start: registers pointing into the data, near page edges at
/// times, with random flags and DF.
pub fn randomCpu(m: *Machine, rng: std.Random) Cpu {
    var c = m.cpu();
    for (&c.r, 0..) |*r, i| {
        r.* = switch (i) {
            4 => Machine.stack_va + 0x400 + (rng.int(u32) & 0x3fc),
            5 => Machine.stack_va + 0x800 + (rng.int(u32) & 0x3fc),
            1 => rng.int(u32) & 0x1ff,
            3, 6, 7 => if (rng.uintLessThan(u8, 8) == 0) Machine.data_va + 0x2000 - (rng.int(u32) & 0x3f) else Machine.data_va + (rng.int(u32) & 0x1ffc),
            else => if (rng.boolean()) rng.int(u32) else rng.int(u32) & 0xff,
        };
    }
    c.fl.set(rng.int(u32) & (0x8d5 | (if (rng.uintLessThan(u8, 4) == 0) @as(u32, 0x400) else 0)));
    if (rng.boolean()) fsSetup(&c);
    return c;
}

pub fn fuzz(gpa: std.mem.Allocator, seed: u64, count: usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const m = try gpa.create(Machine);
    defer gpa.destroy(m);
    var g: Gen = .{ .rng = rng };
    defer g.out.deinit(gpa);
    for (0..count) |iter| {
        m.* = .{};
        m.init();
        for (&m.data) |*b| b.* = rng.int(u8);
        const code = try g.program(gpa, 8 + rng.uintLessThan(usize, 40));
        m.load(code);
        const c = randomCpu(m, rng);
        _ = runChecked(gpa, m, c, std.math.maxInt(i64)) catch |e| {
            std.debug.print("fuzz-x86: seed {d}, program {d}: {s}\ncode:", .{ seed, iter, @errorName(e) });
            for (code) |b| std.debug.print(" {x:0>2}", .{b});
            std.debug.print("\n", .{});
            return e;
        };
    }
}

test "fuzz-x86: random programs agree region by region" {
    try fuzz(testing.allocator, 0x86, 400);
}

/// Random x87 programs: memory forms on [ebx+d8] over random data (so
/// NaNs, denormals, and random control words from FLDCW, with unmasked
/// exceptions and #MF), register forms, and SAHF, SETB, and FWAIT between.
pub fn fuzzX87(gpa: std.mem.Allocator, seed: u64, count: usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const m = try gpa.create(Machine);
    defer gpa.destroy(m);
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    for (0..count) |iter| {
        m.* = .{};
        m.init();
        for (&m.data) |*b| b.* = rng.int(u8);
        code.clearRetainingCapacity();
        for (0..4 + rng.uintLessThan(usize, 20)) |_| {
            switch (rng.uintLessThan(u8, 15)) {
                // FLDCW, FNSTCW, FILD m32, and FIST(P)/FISTTP m16 and m32.
                13 => {
                    const forms = [_][2]u8{ .{ 0xd9, 5 }, .{ 0xd9, 7 }, .{ 0xdb, 0 }, .{ 0xdb, 1 }, .{ 0xdb, 2 }, .{ 0xdb, 3 }, .{ 0xdf, 1 }, .{ 0xdf, 2 }, .{ 0xdf, 3 } };
                    const f = forms[rng.uintLessThan(usize, forms.len)];
                    try code.appendSlice(gpa, &.{ f[0], 0x43 | f[1] << 3, rng.uintLessThan(u8, 0x78) & ~@as(u8, 1) });
                },
                // Arithmetic with a memory operand.
                14 => try code.appendSlice(gpa, &.{ 0xd8 | 2 * rng.uintLessThan(u8, 4), 0x43 | @as(u8, rng.uintLessThan(u8, 8)) << 3, rng.uintLessThan(u8, 0x78) & ~@as(u8, 7) }),
                0...3 => try code.appendSlice(gpa, &.{ 0xd8 | rng.uintLessThan(u8, 8), 0x43 | @as(u8, rng.uintLessThan(u8, 8)) << 3, rng.uintLessThan(u8, 0x78) }),
                // The data movement x87fast takes: FLD, FST, and FSTP
                // m64fp, and FLD, FXCH, FST, and FSTP ST(i).
                10, 11 => try code.appendSlice(gpa, &.{ 0xdd, 0x43 | @as(u8, ([_]u8{ 0, 2, 3 })[rng.uintLessThan(usize, 3)]) << 3, rng.uintLessThan(u8, 0x78) & ~@as(u8, 7) }),
                12 => try code.appendSlice(gpa, if (rng.boolean()) &.{ 0xd9, 0xc0 | rng.uintLessThan(u8, 16) } else &.{ 0xdd, 0xd0 | rng.uintLessThan(u8, 16) }),
                4...7 => try code.appendSlice(gpa, &.{ 0xd8 | rng.uintLessThan(u8, 8), 0xc0 | rng.uintLessThan(u8, 64) }),
                8 => try code.appendSlice(gpa, &.{ 0xd9, 0xe8 + rng.uintLessThan(u8, 7) }), // constants
                else => try code.appendSlice(gpa, switch (rng.uintLessThan(u8, 4)) {
                    0 => &.{0x9e}, // sahf
                    1 => &.{ 0x0f, 0x92, 0xc1 }, // setb %cl
                    2 => &.{0x9b}, // fwait
                    else => &.{ 0xdf, 0xe0 }, // fnstsw %ax
                }),
            }
        }
        try code.appendSlice(gpa, &.{ 0xcd, 0x80 });
        m.load(code.items);
        var c = randomCpu(m, rng);
        c.r[3] = Machine.data_va + 0x100;
        _ = runChecked(gpa, m, c, std.math.maxInt(i64)) catch |e| {
            std.debug.print("fuzz-x87: seed {d}, program {d}: {s}\ncode:", .{ seed, iter, @errorName(e) });
            for (code.items) |b| std.debug.print(" {x:0>2}", .{b});
            std.debug.print("\n", .{});
            return e;
        };
    }
}

test "fuzz-x87: random x87 programs agree region by region" {
    try fuzzX87(testing.allocator, 0x87, 1000);
}

/// Runs `f` with each region also checked as this host's code.
pub fn natively(f: anytype, args: anytype) !void {
    var n = Native.init() catch return error.SkipZigTest;
    defer n.deinit();
    run_native = &n;
    defer run_native = null;
    try @call(.auto, f, args);
}

test "fuzz-x87 natively" {
    try natively(fuzzX87, .{ testing.allocator, 0x870, 300 });
}

/// Random SSE and SSE2 programs over random data: the scalar arithmetic,
/// conversions, compares, and moves, and the 128-bit moves and logic, on
/// registers and [ebx+d8], with LDMXCSR from random data now and then
/// (which T0 then runs the rest under), and SETB after compares.
pub fn fuzzSse(gpa: std.mem.Allocator, seed: u64, count: usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const m = try gpa.create(Machine);
    defer gpa.destroy(m);
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    const ops = [_]u8{ 0x10, 0x11, 0x28, 0x29, 0x51, 0x58, 0x59, 0x5c, 0x5d, 0x5e, 0x5f, 0x5a, 0x2a, 0x2c, 0x2d, 0x2e, 0x2f, 0x54, 0x55, 0x56, 0x57, 0x6e, 0x7e, 0xd6, 0x6f, 0x7f, 0xef, 0xdb, 0xeb, 0xdf, 0x14, 0x15, 0xc6, 0xfc, 0xfd, 0xfe, 0xd4, 0xf8, 0xf9, 0xfa, 0xfb, 0x74, 0x75, 0x76, 0x64, 0x65, 0x66, 0xda, 0xde, 0xea, 0xee, 0xd5, 0x60, 0x61, 0x62, 0x68, 0x69, 0x6a, 0x6c, 0x6d, 0x63, 0x67, 0x6b, 0x70, 0x71, 0x72, 0x73, 0x12, 0x13, 0x16, 0x17, 0x2b, 0xe7, 0xd7, 0x50, 0xc5, 0xc4 };
    const pfx = [_]?u8{ null, 0x66, 0xf3, 0xf2 };
    for (0..count) |iter| {
        m.* = .{};
        m.init();
        for (&m.data) |*b| b.* = rng.int(u8);
        code.clearRetainingCapacity();
        // Fill the registers from memory first.
        for (0..8) |r| try code.appendSlice(gpa, &.{ 0x0f, 0x10, 0x43 | @as(u8, @intCast(r)) << 3, @intCast(r * 16) });
        for (0..4 + rng.uintLessThan(usize, 24)) |_| {
            if (rng.uintLessThan(u8, 30) == 0) {
                // ldmxcsr d8(%ebx)
                try code.appendSlice(gpa, &.{ 0x0f, 0xae, 0x53, rng.uintLessThan(u8, 0x70) & ~@as(u8, 3) });
                continue;
            }
            if (rng.uintLessThan(u8, 6) == 0) {
                try code.appendSlice(gpa, &.{ 0x0f, 0x92, 0xc1 }); // setb %cl
                continue;
            }
            const op = ops[rng.uintLessThan(usize, ops.len)];
            if (pfx[rng.uintLessThan(usize, 4)]) |p| try code.append(gpa, p);
            try code.appendSlice(gpa, &.{ 0x0f, op });
            var reg = rng.uintLessThan(u8, 8);
            var rm = rng.uintLessThan(u8, 8);
            // General registers these write or read: EAX to EDX only, so
            // EBX (the base) and ESP stay put.
            if (op == 0x2c or op == 0x2d or op == 0xd7 or op == 0x50 or op == 0xc5) reg &= 1;
            if (op == 0x7e or op == 0x2a or op == 0x6e or op == 0xc4) rm &= 1;
            const shift = op >= 0x71 and op <= 0x73;
            if (!shift and rng.boolean()) {
                const disp = if (rng.uintLessThan(u8, 4) == 0) rng.uintLessThan(u8, 0x70) else rng.uintLessThan(u8, 0x70) & ~@as(u8, 15);
                try code.appendSlice(gpa, &.{ 0x43 | reg << 3, disp });
            } else try code.append(gpa, 0xc0 | reg << 3 | rm);
            if (op == 0x70 or op == 0xc6 or op == 0xc4 or op == 0xc5 or shift) {
                // Shift counts past the lane width now and then.
                try code.append(gpa, if (shift and rng.uintLessThan(u8, 4) != 0) rng.uintLessThan(u8, 20) else rng.int(u8));
            }
        }
        try code.appendSlice(gpa, &.{ 0xcd, 0x80 });
        m.load(code.items);
        var c = randomCpu(m, rng);
        c.r[3] = Machine.data_va + 0x100;
        c.r[4] = Machine.stack_va + 0x800;
        _ = runChecked(gpa, m, c, std.math.maxInt(i64)) catch |e| {
            std.debug.print("fuzz-sse: seed {d}, program {d}: {s}\ncode:", .{ seed, iter, @errorName(e) });
            for (code.items) |b| std.debug.print(" {x:0>2}", .{b});
            std.debug.print("\n", .{});
            return e;
        };
    }
}

test "fuzz-sse: random SSE and SSE2 programs agree region by region" {
    try fuzzSse(testing.allocator, 0x55e, 1000);
}

test "fuzz-sse natively" {
    try natively(fuzzSse, .{ testing.allocator, 0x55f, 300 });
}

// ---------------------------------------------------------------- hx64

pub const Cpu64 = cpu_mod.Cpu64;
const guest64 = &check.x86.guest64;
const gen = check.gen_x86;

/// hx64's test address space: gen_x86's (code, then data at RBX and the
/// stack after it), with the code two pages.
pub const Machine64 = struct {
    pub const code_va = gen.code_va;
    pub const data_va = gen.data_va;
    pub const stack_va = gen.stack_va;

    code: [2 * page_size]u8 align(page_size) = @splat(0xcc),
    data: [page_size]u8 align(page_size) = @splat(0),
    stack: [page_size]u8 align(page_size) = @splat(0),
    regions: [3]mem.Region = undefined,
    map: mem.Map = undefined,

    pub fn init(m: *Machine64) void {
        m.regions = .{
            .{ .va = code_va, .mem = &m.code, .exec = true },
            .{ .va = data_va, .mem = &m.data, .write = true },
            .{ .va = stack_va, .mem = &m.stack, .write = true },
        };
        m.map = .{ .regions = &m.regions };
    }

    pub fn load(m: *Machine64, code: []const u8) void {
        @memset(&m.code, 0xcc);
        @memcpy(m.code[0..code.len], code);
    }

    pub fn cpu(_: *Machine64) Cpu64 {
        var c: Cpu64 = .{};
        c.rip = code_va;
        c.r[3] = data_va;
        c.r[4] = stack_va + page_size / 2;
        return c;
    }
};

pub const Result64 = struct {
    exit: Exit,
    pc: u64,
    regions: u32,
    retired: u64,
    cpu: Cpu64 = .{},
    ok: bool = true,
};

/// `checkRegions` for hx64, over check.x86.guest64.
pub fn checkRegions64(gpa: std.mem.Allocator, r: *check.Run, map: *const mem.Map, start: Cpu64, budget: i64, max_regions: u32, native: ?*Native) !Result64 {
    const backing = check.mapBacking(map);
    var cpu = start;
    var res: Result64 = .{ .exit = .chain, .pc = start.rip, .regions = 0, .retired = 0 };
    while (res.regions < max_regions) {
        var reg = check.liftOpt(gpa, guest64, &backing, cpu.rip, .{ .lazy_eflags = native == null or native_mod.lazy_eflags }) catch |e| switch (e) {
            error.Unsupported => {
                var sh = check.Shadow.init(gpa, backing);
                defer sh.deinit();
                var c: Ctx = .{ .cpu = @intFromPtr(&cpu), .space = @intFromPtr(&sh) };
                const x: Exit = @enumFromInt(check.x86.step64(&c));
                sh.commit();
                res.exit = x;
                res.pc = cpu.rip;
                res.cpu = cpu;
                return res;
            },
            else => return e,
        };
        defer reg.deinit(gpa);
        if (!try r.check(.{ .ir_eval = &reg }, std.mem.asBytes(&cpu), .{ .budget = budget })) {
            res.ok = false;
            return res;
        }
        if (native) |n| if (try n.compile(gpa, &reg)) |f| {
            if (!try r.check(.{ .entry = f }, std.mem.asBytes(&cpu), .{ .budget = budget })) {
                res.ok = false;
                return res;
            }
        };
        res.regions += 1;
        const o = r.out[check.Run.t1];
        res.retired += o.retired;
        r.shadow[check.Run.t1].commit();
        @memcpy(std.mem.asBytes(&cpu), r.cpu[check.Run.t1]);
        res.exit = o.exit;
        res.pc = o.pc;
        res.cpu = cpu;
        switch (o.exit) {
            .chain, .indirect => {},
            else => return res,
        }
    }
    return res;
}

pub fn runChecked64(gpa: std.mem.Allocator, m: *Machine64, start: Cpu64, budget: i64) !Result64 {
    const r = try check.Run.init(gpa, guest64, check.mapBacking(&m.map));
    defer r.deinit();
    const res = try checkRegions64(gpa, r, &m.map, start, budget, 1000, run_native);
    if (!res.ok) {
        std.debug.print("hx64 region check failed:\n{s}\n", .{r.report.items});
        return error.Diverged;
    }
    if (res.regions == 1000) return error.TooManyRegions;
    return res;
}

/// Runs long-mode T0 alone from `start` to its first exit.
pub fn runT0_64(m: *Machine64, start: Cpu64) struct { exit: cpu_mod.Exit64, cpu: Cpu64 } {
    var c = start;
    const M = struct {
        m: *Machine64,
        pub fn translate(s: *@This(), va: u64, access: cpu_mod.Access) ?[*]u8 {
            for (s.m.regions) |rg| {
                if (va >= rg.va and va - rg.va < rg.mem.len) {
                    const ok = switch (access) {
                        .read => rg.read,
                        .write => rg.write,
                        .exec => rg.exec,
                    };
                    if (!ok) return null;
                    return rg.mem.ptr + (va - rg.va);
                }
            }
            return null;
        }
    };
    var mm: M = .{ .m = m };
    const e = exec.runIn(.long, &c, &mm, .{ .budget = 1_000_000 });
    return .{ .exit = e, .cpu = c };
}

fn expectRun64(code: []const u8, setup: ?*const fn (*Cpu64) void) !Result64 {
    const gpa = testing.allocator;
    const m = try gpa.create(Machine64);
    defer gpa.destroy(m);
    m.* = .{};
    m.init();
    m.load(code);
    var c = m.cpu();
    if (setup) |f| f(&c);
    const m0 = try gpa.create(Machine64);
    defer gpa.destroy(m0);
    m0.* = m.*;
    m0.init();
    const want = runT0_64(m0, c);
    const got = try runChecked64(gpa, m, c, std.math.maxInt(i64));
    try testing.expectEqualSlices(u64, &want.cpu.r, &got.cpu.r);
    try testing.expectEqual(want.cpu.fl.get(), got.cpu.fl.get());
    try testing.expectEqual(want.cpu.rip, got.pc);
    try testing.expectEqualSlices(u8, &m0.data, &m.data);
    try testing.expectEqualSlices(u8, &m0.stack, &m.stack);
    return got;
}

fn regs64Setup(c: *Cpu64) void {
    for (&c.r, 0..) |*x, n| {
        if (n == 3 or n == 4) continue;
        x.* = 0x8000_0000_ffff_0000 +% n *% 0x1111_1111_1111;
    }
}

test "check/x64: a counted loop over 64-bit memory, RIP-relative data, and R8-R15" {
    // mov ecx, 100; xor eax, eax; mov r9, 0x1_0000_0003
    // l: add rax, rcx; add [rbx], rcx; adc qword [rbx+8], 0
    //    add r10, [rip+d] (the qword after the code); add r10, r9;
    //    dec ecx; jnz l
    // syscall
    const code = [_]u8{
        0xb9, 100, 0, 0, 0, // mov ecx, 100
        0x31, 0xc0, // xor eax, eax
        0x49, 0xb9, 3, 0, 0, 0, 1, 0, 0, 0, // mov r9, 0x1_0000_0003
        0x48, 0x01, 0xc8, // l (+0x11): add rax, rcx
        0x48, 0x01, 0x0b, // add [rbx], rcx
        0x48, 0x83, 0x53, 0x08, 0x00, // adc qword [rbx+8], 0
        0x4c, 0x03, 0x15, 0x09, 0, 0, 0, // add r10, [rip+9]: the qword at +0x2c
        0x4d, 0x01, 0xca, // add r10, r9
        0xff, 0xc9, // dec ecx
        0x75, 0xe7, // jnz l
        0x0f, 0x05, // syscall (+0x2a)
        0xef, 0xbe, 0xad, 0xde, 0x01, 0, 0, 0, // the qword
    };
    const r = try expectRun64(&code, regs64Setup);
    try testing.expectEqual(@as(u64, 5050), r.cpu.r[0]);
    try testing.expectEqual(Exit.svc, r.exit);
}

test "check/x64: 32-bit writes zero the upper half, and 8-bit ones with REX name SPL-DIL" {
    // mov eax, ecx; add edx, 1; xchg esi, edi; lea r8d, [rax+rdx]
    // cmovz r9d, r10d (not taken either way, still zero-extends)
    // shl r11d, 0 (also); bsf r12d, r13d with r13 = 0 (leaves r12 whole)
    // mov sil, 7 (REX); mov ah, 9 (no REX); add dil, ah? (not encodable): add dil, al
    // cmpxchg r14d, r15d; setnz bpl; movsxd rcx, edx; movzx r15, byte [rbx+1]
    // cdqe; cqo; bswap rbp; neg r8; not r9w; imul r10, r11, -3; mul r12
    // syscall
    const code = [_]u8{
        0x89, 0xc8, // mov eax, ecx
        0x83, 0xc2, 0x01, // add edx, 1
        0x87, 0xfe, // xchg esi, edi
        0x44, 0x8d, 0x04, 0x10, // lea r8d, [rax+rdx]
        0x45, 0x0f, 0x44, 0xca, // cmovz r9d, r10d
        0x41, 0xc1, 0xe3, 0x00, // shl r11d, 0
        0x45, 0x0f, 0xbc, 0xe5, // bsf r12d, r13d
        0x40, 0xb6, 0x07, // mov sil, 7
        0xb4, 0x09, // mov ah, 9
        0x40, 0x00, 0xc7, // add dil, al
        0x45, 0x0f, 0xb1, 0xfe, // cmpxchg r14d, r15d
        0x40, 0x0f, 0x95, 0xc5, // setnz bpl
        0x48, 0x63, 0xca, // movsxd rcx, edx
        0x4c, 0x0f, 0xb6, 0x7b, 0x01, // movzx r15, byte [rbx+1]
        0x48, 0x98, // cdqe
        0x48, 0x99, // cqo
        0x48, 0x0f, 0xcd, // bswap rbp
        0x49, 0xf7, 0xd8, // neg r8
        0x66, 0x41, 0xf7, 0xd1, // not r9w
        0x4d, 0x6b, 0xd3, 0xfd, // imul r10, r11, -3
        0x49, 0xf7, 0xe4, // mul r12
        0x0f, 0x05,
    };
    const S = struct {
        fn setup(c: *Cpu64) void {
            regs64Setup(c);
            c.r[13] = 0;
            c.fl.set(0x2); // ZF clear
        }
    };
    _ = try expectRun64(&code, S.setup);
}

test "check/x64: push, pop, call, ret, leave, and 16-bit pushes" {
    // push rbp; mov rbp, rsp; push 0x12345678 (sign-extended); push word 7
    // call f; pop ax; pop rcx; leave; syscall
    // f: mov rax, [rsp]; ret 0
    const code = [_]u8{
        0x55, // push rbp
        0x48, 0x89, 0xe5, // mov rbp, rsp
        0x68, 0x78, 0x56, 0x34, 0x92, // push 0xffffffff92345678
        0x66, 0x6a, 0x07, // push word 7
        0xe8, 0x08, 0, 0, 0, // call f (+0x19)
        0x66, 0x58, // pop ax
        0x59, // pop rcx
        0xc9, // leave
        0x0f, 0x05, // syscall
        0xcc, 0xcc,
        0x48, 0x8b, 0x04, 0x24, // f: mov rax, [rsp]
        0xc2, 0x00, 0x00, // ret 0
    };
    _ = try expectRun64(&code, regs64Setup);
}

test "check/x64: DIV and IDIV under 64 bits, #DE through the guard, and DIV at 64 on T0" {
    // div ecx; xor edx, edx; idiv cx; div r8 (T0's); then a #DE: xor
    // ecx, ecx; div ecx
    const code = [_]u8{
        0xf7, 0xf1, // div ecx
        0x31, 0xd2, // xor edx, edx
        0x66, 0xf7, 0xf9, // idiv cx
        0x49, 0xf7, 0xf0, // div r8
        0x31, 0xc9, // xor ecx, ecx
        0xf7, 0xf1, // div ecx
        0x0f, 0x05,
    };
    const S = struct {
        fn setup(c: *Cpu64) void {
            c.r[0] = 0x1234_5678_9abc_def0;
            c.r[1] = 0x30003;
            c.r[2] = 0x7;
            c.r[8] = 0x1_0000_0000;
        }
    };
    const r = try expectRun64(&code, S.setup);
    try testing.expectEqual(Exit.fault, r.exit);
    try testing.expectEqual(@as(u64, Machine64.code_va + 12), r.pc);
}

test "check/x64: a fault is exact: a store past the stack page" {
    // mov rsp, rbx; sub rsp, 8 (below data, unmapped: data is the first
    // mapped page after the code gap); push rax
    const code = [_]u8{
        0x48, 0x89, 0xdc, // mov rsp, rbx
        0x48, 0x83, 0xec, 0x08, // sub rsp, 8
        0x50, // push rax
        0x0f,
        0x05,
    };
    const r = try expectRun64(&code, regs64Setup);
    try testing.expectEqual(Exit.fault, r.exit);
    try testing.expectEqual(@as(u64, Machine64.code_va + 7), r.pc);
}

/// Random long-mode programs (gen_x86.program64) region by region.
pub fn fuzz64(gpa: std.mem.Allocator, seed: u64, count: usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const m = try gpa.create(Machine64);
    defer gpa.destroy(m);
    var buf: [page_size - 16]u8 = undefined;
    for (0..count) |iter| {
        m.* = .{};
        m.init();
        for (&m.data) |*b| b.* = rng.int(u8);
        for (&m.stack) |*b| b.* = rng.int(u8);
        const code = gen.program64(rng, .{ .len = 8 + rng.uintLessThan(u32, 40) }, &buf);
        m.load(code);
        var c = m.cpu();
        const regs = gen.registers64(rng);
        c.r = regs.r;
        c.fl.set(@truncate(regs.rflags));
        _ = runChecked64(gpa, m, c, std.math.maxInt(i64)) catch |e| {
            std.debug.print("fuzz-x64: seed {d}, program {d}: {s}\ncode:", .{ seed, iter, @errorName(e) });
            for (code) |b| std.debug.print(" {x:0>2}", .{b});
            std.debug.print("\n", .{});
            return e;
        };
    }
}

test "fuzz-x64: random long-mode programs agree region by region" {
    try fuzz64(testing.allocator, 0x64, 400);
}

test "fuzz-x64 natively" {
    try natively(fuzz64, .{ testing.allocator, 0x6464, 200 });
}

fn strings64Setup(c: *Cpu64) void {
    regs64Setup(c);
    c.r[6] = Machine64.data_va + 0x100; // rsi
    c.r[7] = Machine64.data_va + 0x200; // rdi
    c.r[1] = 9; // rcx
    c.r[0] = 0x1122_3344_5566_7788;
}

test "check/x64: strings: REP MOVSB, REP STOSQ, REPE CMPSB, REPNE SCASB, and LODSQ, both directions" {
    const code = [_]u8{
        0xf3, 0xa4, // rep movsb
        0xb9, 0x05, 0, 0, 0, // mov ecx, 5
        0xf3, 0x48, 0xab, // rep stosq
        0xb9, 0x30, 0, 0, 0, // mov ecx, 48 (past rep_inline: T0 chunks)
        0x48, 0x83, 0xee, 0x40, // sub rsi, 64
        0xf3, 0xa6, // repe cmpsb
        0xb9, 0x11, 0, 0, 0, // mov ecx, 17
        0xf2, 0xae, // repne scasb
        0x48, 0xad, // lodsq
        0xfd, // std
        0x48, 0xa5, // movsq
        0xf3, 0x66, 0xa5, // rep movsw (rcx = what scas left)
        0xfc, // cld
        0x0f,
        0x05,
    };
    _ = try expectRun64(&code, strings64Setup);
}

test "check/x64: atomics through cas: LOCK ADD, XADD, XCHG, and CMPXCHG at 32 and 64 bits" {
    const code = [_]u8{
        0xf0, 0x48, 0x01, 0x0b, // lock add [rbx], rcx
        0xf0, 0x0f, 0xc1, 0x53, 0x08, // lock xadd [rbx+8], edx
        0x48, 0x87, 0x73, 0x10, // xchg [rbx+16], rsi
        0x8b, 0x43, 0x18, // mov eax, [rbx+24]
        0xf0, 0x0f, 0xb1, 0x7b, 0x18, // lock cmpxchg [rbx+24], edi (equal)
        0xf0, 0x0f, 0xb1, 0x7b, 0x18, // lock cmpxchg [rbx+24], edi (not now)
        0xf0, 0x4c, 0x0f, 0xb1, 0x43, 0x20, // lock cmpxchg [rbx+32], r8
        0xf0, 0x48, 0xff, 0x43, 0x28, // lock inc qword [rbx+40]
        0xf0, 0x48, 0xf7, 0x5b, 0x30, // lock neg qword [rbx+48]
        0x48, 0x0f, 0xc7, 0x4b, 0x40, // cmpxchg16b [rbx+64] (T0's)
        0x0f, 0x05,
    };
    const S = struct {
        fn setup(c: *Cpu64) void {
            regs64Setup(c);
            c.r[0] = 0xdead_beef_0000_0000; // upper half kept by an equal CMPXCHG
        }
    };
    _ = try expectRun64(&code, S.setup);
}

test "check/x64: rotates and SHLD at 64 bits, BT into memory by a register, POP to memory, and FS" {
    const code = [_]u8{
        0x48, 0xc1, 0xc0, 0x25, // rol rax, 37
        0x49, 0xd3, 0xc9, // ror r9, cl
        0x41, 0xc1, 0xc2, 0x00, // rol r10d, 0 (zeroes the upper half)
        0x0f, 0xa4, 0xd6, 0x05, // shld esi, edx, 5
        0x48, 0x0f, 0xa5, 0xd7, // shld rdi, rdx, cl (T0's)
        0x48, 0x0f, 0xab, 0x0b, // bts [rbx], rcx
        0x48, 0x0f, 0xa3, 0x13, // bt [rbx], rdx
        0x0f, 0xba, 0xf8, 0x23, // btc eax, 35
        0xff, 0x33, // push qword [rbx]
        0x8f, 0x43, 0x08, // pop qword [rbx+8]
        0x64, 0x48, 0x8b, 0x04, 0x25, 0x10, 0, 0, 0, // mov rax, fs:[0x10]
        0x64, 0x48, 0x89, 0x0c, 0x25, 0x18, 0, 0, 0, // mov fs:[0x18], rcx
        0x0f, 0x05,
    };
    const S = struct {
        fn setup(c: *Cpu64) void {
            regs64Setup(c);
            c.r[1] = 0x1_0000_0047; // rcx: cl 0x47, a bit offset past the qword
            c.r[2] = 0xffff_ffff_ffff_ffc3; // rdx: a negative bit offset
            c.fs_base = Machine64.data_va + 0x300;
        }
    };
    _ = try expectRun64(&code, S.setup);
}

/// fuzzSse in long mode: XMM8-15 and R8-R9 through REX, and REX.W now and
/// then (MOVQ and the conversions at 64 bits; ignored elsewhere).
pub fn fuzzSse64(gpa: std.mem.Allocator, seed: u64, count: usize) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const m = try gpa.create(Machine64);
    defer gpa.destroy(m);
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    const ops = [_]u8{ 0x10, 0x11, 0x28, 0x29, 0x51, 0x58, 0x59, 0x5c, 0x5d, 0x5e, 0x5f, 0x5a, 0x2a, 0x2c, 0x2d, 0x2e, 0x2f, 0x54, 0x55, 0x56, 0x57, 0x6e, 0x7e, 0xd6, 0x6f, 0x7f, 0xef, 0xdb, 0xeb, 0xdf, 0x14, 0x15, 0xc6, 0xfc, 0xfd, 0xfe, 0xd4, 0xf8, 0xf9, 0xfa, 0xfb, 0x74, 0x75, 0x76, 0x64, 0x65, 0x66, 0xda, 0xde, 0xea, 0xee, 0xd5, 0x60, 0x61, 0x62, 0x68, 0x69, 0x6a, 0x6c, 0x6d, 0x63, 0x67, 0x6b, 0x70, 0x71, 0x72, 0x73, 0x12, 0x13, 0x16, 0x17, 0x2b, 0xe7, 0xd7, 0x50, 0xc5, 0xc4 };
    const pfx = [_]?u8{ null, 0x66, 0xf3, 0xf2 };
    for (0..count) |iter| {
        m.* = .{};
        m.init();
        for (&m.data) |*b| b.* = rng.int(u8);
        code.clearRetainingCapacity();
        // Fill the 16 registers from memory first: movups xmmN, [rbx+d8].
        for (0..16) |r| {
            if (r >= 8) try code.append(gpa, 0x44);
            try code.appendSlice(gpa, &.{ 0x0f, 0x10, 0x43 | @as(u8, @intCast(r & 7)) << 3, @bitCast(@as(i8, @intCast(@as(i32, @intCast(r)) * 16 - 128))) });
        }
        for (0..4 + rng.uintLessThan(usize, 24)) |_| {
            if (rng.uintLessThan(u8, 30) == 0) {
                try code.appendSlice(gpa, &.{ 0x0f, 0xae, 0x53, rng.uintLessThan(u8, 0x70) & ~@as(u8, 3) });
                continue;
            }
            if (rng.uintLessThan(u8, 6) == 0) {
                try code.appendSlice(gpa, &.{ 0x41, 0x0f, 0x92, 0xc1 }); // setb r9b
                continue;
            }
            const op = ops[rng.uintLessThan(usize, ops.len)];
            if (pfx[rng.uintLessThan(usize, 4)]) |p| try code.append(gpa, p);
            var reg = rng.uintLessThan(u8, 8);
            var rm = rng.uintLessThan(u8, 8);
            // General registers these write or read: RAX, RCX, R8, R9.
            if (op == 0x2c or op == 0x2d or op == 0xd7 or op == 0x50 or op == 0xc5) reg &= 1;
            if (op == 0x7e or op == 0x2a or op == 0x6e or op == 0xc4) rm &= 1;
            const shift = op >= 0x71 and op <= 0x73;
            const memop = !shift and rng.boolean();
            const w: u8 = if (rng.uintLessThan(u8, 4) == 0) 8 else 0;
            const r_: u8 = if (rng.boolean()) 4 else 0;
            const b_: u8 = if (!memop and rng.boolean()) 1 else 0;
            const rex = 0x40 | w | r_ | b_;
            if (rex != 0x40 or rng.uintLessThan(u8, 8) == 0) try code.append(gpa, rex);
            try code.appendSlice(gpa, &.{ 0x0f, op });
            if (memop) {
                const disp = if (rng.uintLessThan(u8, 4) == 0) rng.uintLessThan(u8, 0x70) else rng.uintLessThan(u8, 0x70) & ~@as(u8, 15);
                try code.appendSlice(gpa, &.{ 0x43 | reg << 3, disp });
            } else try code.append(gpa, 0xc0 | reg << 3 | rm);
            if (op == 0x70 or op == 0xc6 or op == 0xc4 or op == 0xc5 or shift) {
                try code.append(gpa, if (shift and rng.uintLessThan(u8, 4) != 0) rng.uintLessThan(u8, 20) else rng.int(u8));
            }
        }
        try code.appendSlice(gpa, &.{ 0x0f, 0x05 });
        m.load(code.items);
        var c = m.cpu();
        for (&c.r, 0..) |*x, n| if (n != 3 and n != 4) {
            x.* = if (rng.boolean()) rng.int(u64) else rng.int(u32);
        };
        c.r[3] = Machine64.data_va + 0x100;
        c.fl.set(rng.int(u32) & 0x8d5);
        _ = runChecked64(gpa, m, c, std.math.maxInt(i64)) catch |e| {
            std.debug.print("fuzz-sse64: seed {d}, program {d}: {s}\ncode:", .{ seed, iter, @errorName(e) });
            for (code.items) |b| std.debug.print(" {x:0>2}", .{b});
            std.debug.print("\n", .{});
            return e;
        };
    }
}

test "fuzz-sse64: random SSE and SSE2 programs in long mode agree region by region" {
    try fuzzSse64(testing.allocator, 0x55e64, 1000);
}

test "fuzz-sse64 natively" {
    try natively(fuzzSse64, .{ testing.allocator, 0x55f64, 300 });
}
