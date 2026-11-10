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
/// alone.
pub fn checkRegions(gpa: std.mem.Allocator, r: *check.Run, map: *const mem.Map, start: Cpu, budget: i64, max_regions: u32) !Result {
    const backing = check.mapBacking(map);
    var cpu = start;
    var res: Result = .{ .exit = .chain, .pc = start.eip, .regions = 0, .retired = 0 };
    while (res.regions < max_regions) {
        var reg = check.liftAt(gpa, guest, &backing, cpu.eip, .{}) catch |e| switch (e) {
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

pub fn runChecked(gpa: std.mem.Allocator, m: *Machine, start: Cpu, budget: i64) !Result {
    const r = try check.Run.init(gpa, guest, check.mapBacking(&m.map));
    defer r.deinit();
    const res = try checkRegions(gpa, r, &m.map, start, budget, 1000);
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
    try testing.expectEqualSlices(u8, &m0.data, &m.data);
    try testing.expectEqualSlices(u8, &m0.stack, &m.stack);
    return got;
}

test "check/x86: a counted loop with memory, flags, and a backward branch" {
    // movl $100, %ecx; xorl %eax, %eax; movl $0x20000, %ebx
    // l: addl %ecx, %eax; addl %ecx, (%ebx); adcl $0, 4(%ebx); decl %ecx; jnz l
    // int $0x80
    const code = [_]u8{
        0xb9, 100, 0, 0, 0, 0x31, 0xc0, 0xbb, 0x00, 0x00, 0x02, 0x00,
        0x01, 0xc8, 0x01, 0x0b, 0x83, 0x53, 0x04, 0x00, 0x49, 0x75, 0xf5,
        0xcd, 0x80,
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
        0x55, 0x89, 0xe5, 0x6a, 0x05, 0x8b, 0x45, 0xfc, 0xc9, 0xc3,
    };
    const r = try expectRun(&code, null);
    try testing.expectEqual(Exit.svc, r.exit);
}

test "check/x86: DIV and IDIV, and #DE through the guard" {
    // movl $100, %eax; xorl %edx, %edx; movl $7, %ecx; divl %ecx;
    // movl $-100, %eax; cltd; idivl %ecx; movb $3, %cl; divb %cl;
    // xorl %ecx, %ecx; divl %ecx (#DE)
    const code = [_]u8{
        0xb8, 100, 0, 0, 0, 0x31, 0xd2, 0xb9, 7, 0, 0, 0, 0xf7, 0xf1,
        0xb8, 0x9c, 0xff, 0xff, 0xff, 0x99, 0xf7, 0xf9,
        0x66, 0xb8, 0x10, 0x00, 0xb1, 0x03, 0xf6, 0xf1,
        0x31, 0xc9, 0xf7, 0xf1,
    };
    const r = try expectRun(&code, null);
    try testing.expectEqual(Exit.fault, r.exit);
    try testing.expectEqual(@as(u64, Machine.code_va + 32), r.pc);
    // IDIV of INT_MIN by -1 overflows.
    const code2 = [_]u8{ 0xb8, 0, 0, 0, 0x80, 0x99, 0xb9, 0xff, 0xff, 0xff, 0xff, 0xf7, 0xf9, 0xcd, 0x80 };
    const r2 = try expectRun(&code2, null);
    try testing.expectEqual(Exit.fault, r2.exit);
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
        0xbf, 0, 0, 2, 0, 0xb9, 0, 0x20, 0, 0, 0xf3, 0xae, // repe scasb: stops at 0x900
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
