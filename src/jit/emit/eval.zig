//! A test emitter for x86-64 hosts: each region's "code" is a small native
//! stub that runs the region in ir_eval, with real chain sites, so the
//! dispatcher, the code cache's chaining, invalidation, and flushes run on
//! hosts that have no native emitter yet.
//!
//! The stub follows cache.zig's x86-64 contract: `push rbx; mov rbx, rdi`,
//! then the chain entry, which calls `evalEntry(ctx, region)`. A `.chain`
//! exit comes back with the index of the `exit.chain` it took in
//! exit_info; the stub turns that into its chain site (`jmp rel32`,
//! unlinked as `jmp .+5`), whose fall-through sets exit_info to the site's
//! own address and leaves. A linked site jumps to the target's chain entry
//! with rbx and the stack as they are, as native code would.
//!
//! The regions are copied and kept until `reset`.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../ir.zig");
const ir_eval = @import("../ir_eval.zig");
const ctx_mod = @import("../ctx.zig");
const alloc_mod = @import("../alloc.zig");
const emitter = @import("../emitter.zig");
const Ctx = ctx_mod.Ctx;

pub const supported = builtin.cpu.arch == .x86_64;

pub const emitter_def: emitter.Emitter = .{ .name = "ir_eval", .emit = emit };

const gpa = std.heap.smp_allocator;
var regions: std.ArrayList(*ir.Region) = .empty;
var lock: std.atomic.Mutex = .unlocked;

/// Frees every region emitted so far. Only with no stub running.
pub fn reset() void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    for (regions.items) |r| {
        r.deinit(gpa);
        gpa.destroy(r);
    }
    regions.clearAndFree(gpa);
}

fn clone(r: *const ir.Region) !*ir.Region {
    const c = try gpa.create(ir.Region);
    errdefer gpa.destroy(c);
    c.* = .{ .entry_pc = r.entry_pc };
    try c.insts.appendSlice(gpa, r.insts.items);
    try c.blocks.appendSlice(gpa, r.blocks.items);
    try c.handles.appendSlice(gpa, r.handles.items);
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    try regions.append(gpa, c);
    return c;
}

fn evalEntry(cx: *Ctx, r: *const ir.Region) callconv(.c) u32 {
    const e = ir_eval.run(gpa, r, cx) catch {
        cx.exit_pc = r.entry_pc;
        return @intFromEnum(ctx_mod.Exit.undef);
    };
    if (e == .chain) {
        // Which exit.chain: the first to this PC (any with the same target
        // is as good).
        var idx: u64 = 0;
        for (r.insts.items) |i| {
            if (i.op != .@"exit.chain") continue;
            if (i.aux == cx.exit_pc) break;
            idx += 1;
        }
        cx.exit_info = idx;
    }
    return @intFromEnum(e);
}

const off_exit_info: u8 = @offsetOf(Ctx, "exit_info");

pub fn emit(out_gpa: std.mem.Allocator, r: *const ir.Region, _: *const alloc_mod.Allocation, out: *std.ArrayList(u8)) emitter.EmitError!emitter.Code {
    if (!supported) return error.Unsupported;
    const copy = clone(r) catch return error.OutOfMemory;
    var code: emitter.Code = .{};
    const B = struct {
        fn put(o: *std.ArrayList(u8), bytes: []const u8) !void {
            try o.appendSlice(gpa, bytes);
        }
        fn imm(o: *std.ArrayList(u8), v: anytype) !void {
            try o.appendSlice(gpa, std.mem.asBytes(&v));
        }
    };
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try B.put(&b, &.{ 0x53, 0x48, 0x89, 0xfb }); // push rbx; mov rbx, rdi
    code.chain_entry = @intCast(b.items.len);
    try B.put(&b, &.{ 0x48, 0x89, 0xdf }); // mov rdi, rbx
    try B.put(&b, &.{ 0x48, 0xbe }); // mov rsi, imm64
    try B.imm(&b, @as(u64, @intFromPtr(copy)));
    try B.put(&b, &.{ 0x48, 0xb8 }); // mov rax, imm64
    try B.imm(&b, @as(u64, @intFromPtr(&evalEntry)));
    try B.put(&b, &.{ 0xff, 0xd0 }); // call rax
    try B.put(&b, &.{ 0x83, 0xf8, 0x01 }); // cmp eax, 1 (.chain)
    try B.put(&b, &.{ 0x0f, 0x85 }); // jne done
    const jne_done = b.items.len;
    try B.imm(&b, @as(u32, 0));
    try B.put(&b, &.{ 0x48, 0x8b, 0x4b, off_exit_info }); // mov rcx, [rbx+exit_info]
    var nsites: u32 = 0;
    for (r.insts.items) |i| if (i.op == .@"exit.chain") {
        if (nsites == emitter.max_chains) break;
        try B.put(&b, &.{ 0x83, 0xf9, @intCast(nsites) }); // cmp ecx, i
        try B.put(&b, &.{ 0x75, 0 }); // jne next
        const jne_next = b.items.len;
        while ((b.items.len + 1) % 4 != 0) try b.append(gpa, 0x90);
        const site = b.items.len;
        try B.put(&b, &.{ 0xe9, 0, 0, 0, 0 }); // the site: jmp .+5
        // lea rax, [rip - (here + 7 - site)]; mov [rbx+exit_info], rax
        const disp: i32 = -@as(i32, @intCast(b.items.len + 7 - site));
        try B.put(&b, &.{ 0x48, 0x8d, 0x05 });
        try B.imm(&b, disp);
        try B.put(&b, &.{ 0x48, 0x89, 0x43, off_exit_info });
        try B.put(&b, &.{ 0xb8, 1, 0, 0, 0, 0x5b, 0xc3 }); // mov eax, chain; pop rbx; ret
        b.items[jne_next - 1] = @intCast(b.items.len - jne_next);
        code.chains[nsites] = .{ .site = @intCast(site), .pc = i.aux };
        nsites += 1;
    };
    code.nchains = @intCast(nsites);
    // done: rax holds the exit.
    std.mem.writeInt(u32, b.items[jne_done..][0..4], @intCast(b.items.len - (jne_done + 4)), .little);
    try B.put(&b, &.{ 0x5b, 0xc3 }); // pop rbx; ret
    // A chain index past the sites falls through here too, as `.chain`
    // with an exit_info that's no site, so it's never linked.
    try out.appendSlice(out_gpa, b.items);
    return code;
}
