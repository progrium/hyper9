//! The Linux ABI's part of a process's memory: where things go in a Linux
//! address space, brk, and mmap's protection bits. The address space
//! itself, VMAs over chunks of pages with copy-on-write fork and lazily
//! filled file mappings, is the kernel's (src/kern/mm.zig), which 9front
//! processes use too (design/memory-model.md); its names are re-exported
//! here for the Linux ABI's files.

const std = @import("std");
const engine = @import("../../engine.zig");
const kmm = @import("../../kern/mm.zig");

pub const Mm = kmm.Mm;
pub const Vma = kmm.Vma;
pub const Src = kmm.Src;
pub const Pages = kmm.Pages;
pub const Shared = kmm.Shared;
pub const Prot = kmm.Prot;
pub const Kind = kmm.Kind;
pub const Error = kmm.Error;
pub const chunk_size = kmm.chunk_size;
pub const pages_per_chunk = kmm.pages_per_chunk;

const page = engine.page_size;

/// Where things go in a Linux address space, by architecture.
pub const Layout = struct {
    /// The top of the user address space.
    user_top: u64,
    /// Where the stack ends (exclusive), and how much of it is reserved.
    stack_top: u64,
    stack_size: u64 = 8 << 20,
    /// mmap allocates downward from here, below the stack and a gap.
    mmap_base: u64,
    /// Where a PIE executable is loaded (Linux's ELF_ET_DYN_BASE).
    pie_base: u64,

    /// 47 bits on arm64 and amd64, as on amd64 Linux, which arm64's 48-bit
    /// space also holds. i386 gets Linux's 3 GiB, below the emulator's
    /// descriptor table at the top (design/epoch-0/linux-i386.md), with PIEs at 4 MiB as Linux puts them.
    pub fn of(arch: engine.Arch) Layout {
        const top: u64 = if (arch == .i386) 0xC000_0000 else 1 << 47;
        return .{
            .user_top = top,
            .stack_top = top - page,
            .mmap_base = top - page - (8 << 20) - (128 << 20),
            .pie_base = if (arch == .i386) 0x40_0000 else 0x5555_5555_4000 & ~(chunk_size - 1),
        };
    }
};

/// The 64-bit layout, the largest: what a Linux address may be at most.
pub const user_top: u64 = Layout.of(.amd64).user_top;
/// Nothing is mapped below this, so a null pointer always faults.
pub const min_addr: u64 = 0x10000;

/// The layout of `m`'s architecture.
pub fn layout(m: *const Mm) Layout {
    return .of(m.arch);
}

/// From mmap's PROT_* bits.
pub fn protFromLinux(p: u64) Prot {
    return .{ .read = p & 1 != 0, .write = p & 2 != 0, .exec = p & 4 != 0 };
}

/// A free range of `len` bytes, as high as possible below `mmap_base`.
pub fn findFree(m: *const Mm, len: u64) ?u64 {
    return m.findFree(len, min_addr, layout(m).mmap_base);
}

/// Grows or shrinks the heap (brk). Returns the new break, or the old
/// one if it can't move, as Linux does.
pub fn setBrk(m: *Mm, want: u64) u64 {
    if (want < m.brk_start) return m.brk;
    const old_end = std.mem.alignForward(u64, m.brk, page);
    const new_end = std.mem.alignForward(u64, want, page);
    if (new_end > old_end) {
        if (!m.isFree(old_end, new_end) or new_end > layout(m).mmap_base) return m.brk;
        if (!m.extend(old_end, new_end, .heap)) {
            m.insert(.{ .start = old_end, .end = new_end, .prot = .rw, .kind = .heap }) catch return m.brk;
        }
    } else if (new_end < old_end) {
        m.unmap(new_end, old_end) catch return m.brk;
    }
    m.brk = want;
    return m.brk;
}

test "protFromLinux" {
    try std.testing.expectEqual(Prot{ .read = true, .exec = true }, protFromLinux(5));
    try std.testing.expectEqual(Prot.none, protFromLinux(0));
}
