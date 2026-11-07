//! amd64 page tables for the hypervisor backends (KVM, and WHP's later):
//! 4-level, 4K pages, U/S for user pages and NX for non-executable ones.
//!
//! x86 has one root (CR3) for both halves, so the kernel half sits under
//! PML4 entry 511, at the same addresses as on arm64, and every address
//! space's PML4 shares that entry with the kernel's root. The shim, the
//! IDT and the per-vCPU shared pages are mapped supervisor-only there.

const std = @import("std");
const vmm = @import("../vmm.zig");
const gphys = @import("gphys.zig");
const x86 = @import("x86.zig");

pub const kva_shim: u64 = 0xFFFF_FFFF_F000_0000;
pub const kva_idt: u64 = kva_shim + 0x1000;
pub const kva_shared: u64 = kva_shim + 0x10000;

const kernel_slot = 511;

const PTE_P: u64 = 1 << 0;
const PTE_RW: u64 = 1 << 1;
const PTE_US: u64 = 1 << 2;
const PTE_A: u64 = 1 << 5;
const PTE_D: u64 = 1 << 6;
const PTE_NX: u64 = 1 << 63;
const PTE_ADDR: u64 = 0x000F_FFFF_FFFF_F000;

/// User addresses are the lower canonical half.
pub const user_top: u64 = 1 << 47;

/// Leaf attributes. Accessed and dirty are preset, so the CPU never
/// writes them back into the tables.
pub fn pteAttrs(user: bool, perms: vmm.Perms) u64 {
    var d = PTE_P | PTE_A | PTE_D;
    if (perms.write) d |= PTE_RW;
    if (user) d |= PTE_US;
    if (!perms.exec) d |= PTE_NX;
    return d;
}

pub fn userAttrs(perms: vmm.Perms) u64 {
    return pteAttrs(true, perms);
}

/// A user root shares the kernel half's PML4 entry.
pub fn newRoot(ram: *gphys.Ram, kernel_root: u64) vmm.Error!u64 {
    if (ram.takeRoot()) |root| return root;
    const root = try ram.allocTable();
    ram.table(root)[kernel_slot] = ram.table(kernel_root)[kernel_slot];
    return root;
}

/// Frees a user root's tables, leaving the kernel half's, and keeps the
/// root itself as a root. A vCPU's CR3 can still hold a dead space's root
/// when it next runs: it enters the shim, which runs from the kernel half,
/// and only then loads the next space's root. So a root page must never
/// become anything but a root with the kernel half in it.
pub fn freeRoot(ram: *gphys.Ram, root: u64) void {
    const t = ram.table(root);
    for (t[0..kernel_slot]) |*e| {
        const v = e.*;
        if (v & PTE_P == 0) continue;
        @atomicStore(u64, e, 0, .release);
        freeTables(ram, v & PTE_ADDR, 1);
    }
    ram.keepRoot(root);
}

/// The caller serializes changes to the tables under `root`.
pub fn mapPage(ram: *gphys.Ram, root: u64, va: u64, pa: u64, attrs: u64) vmm.Error!void {
    // Table entries allow everything; the leaf decides. Kernel-half
    // tables leave out U/S, so nothing under them is reachable from user
    // mode whatever a leaf says.
    const table_attrs = PTE_P | PTE_RW | PTE_A | (if (va < user_top) PTE_US else 0);
    var t = root;
    var shift: u6 = 39;
    while (shift > 12) : (shift -= 9) {
        const e = &ram.table(t)[(va >> shift) & 511];
        if (e.* & PTE_P == 0) @atomicStore(u64, e, (try ram.allocTable()) | table_attrs, .release);
        t = e.* & PTE_ADDR;
    }
    @atomicStore(u64, &ram.table(t)[(va >> 12) & 511], (pa & PTE_ADDR) | attrs, .release);
}

pub fn unmapPage(ram: *gphys.Ram, root: u64, va: u64) void {
    var t = root;
    var shift: u6 = 39;
    while (shift > 12) : (shift -= 9) {
        const e = ram.table(t)[(va >> shift) & 511];
        if (e & PTE_P == 0) return;
        t = e & PTE_ADDR;
    }
    @atomicStore(u64, &ram.table(t)[(va >> 12) & 511], 0, .release);
}

/// Frees the table at `pa` and the tables below it, not the pages they map.
fn freeTables(ram: *gphys.Ram, pa: u64, level: u2) void {
    if (level < 3) for (ram.table(pa)) |e| {
        if (e & PTE_P != 0) freeTables(ram, e & PTE_ADDR, level + 1);
    };
    ram.freeTable(pa);
}

/// The kernel half: the shim and the IDT, under a root that has only
/// PML4 entry 511. vCPUs' shared pages are added by `mapShared`.
pub fn kernelRoot(ram: *gphys.Ram) vmm.Error!u64 {
    const root = try ram.allocTable();
    const shim = try ram.allocPages(1);
    @memcpy(shim[0..x86.shim_code.len], x86.shim_code);
    try mapPage(ram, root, kva_shim, ram.gpaOf(shim), pteAttrs(false, .{ .exec = true }));
    const idt = try ram.allocPages(1);
    const gates: *[x86.nvectors][2]u64 = @ptrCast(idt.ptr);
    for (gates, 0..) |*g, i| g.* = x86.idtGate(kva_shim + x86.shim_vectors + i * 16);
    try mapPage(ram, root, kva_idt, ram.gpaOf(idt), pteAttrs(false, .{}));
    return root;
}

pub fn sharedKva(slot: u64) u64 {
    return kva_shared + slot * vmm.page_size;
}

/// Maps a vCPU's shared page and fills in its GDT, TSS and `self`.
/// The caller serializes calls.
pub fn mapShared(ram: *gphys.Ram, kernel_root: u64, slot: u64, page: []align(vmm.page_size) u8) vmm.Error!void {
    const kva = sharedKva(slot);
    try mapPage(ram, kernel_root, kva, ram.gpaOf(page), pteAttrs(false, .{ .write = true }));
    const s: *x86.Shared = @ptrCast(page.ptr);
    s.self = kva;
    const g: *[x86.ngdt]u64 = @ptrCast(@alignCast(page[x86.gdt_off..][0 .. x86.ngdt * 8]));
    g.* = x86.gdt(kva + x86.tss_off);
    const t: *x86.Tss = @ptrCast(@alignCast(page[x86.tss_off..][0..@sizeOf(x86.Tss)]));
    t.* = .init(kva + x86.stack_top);
}
