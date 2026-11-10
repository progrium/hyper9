//! The x86 CPU's comptime mode: `.legacy` is h86, a flat 32-bit protected
//! mode 386; `.long` is hx64, 64-bit long mode (design/hcpu.md, hx64). The
//! encoding table, the decoder, T0, the Cpu, and the lifter each take it as
//! a comptime parameter, so one set of semantics serves both and the 386
//! path pays nothing at run time for long mode.

pub const Mode = enum {
    legacy,
    long,

    /// The width of an address, a general register, and the PC, in bytes.
    pub fn wordBytes(comptime m: Mode) u8 {
        return switch (m) {
            .legacy => 4,
            .long => 8,
        };
    }

    /// The unsigned integer that holds a general register, an address, or
    /// the PC.
    pub fn Word(comptime m: Mode) type {
        return switch (m) {
            .legacy => u32,
            .long => u64,
        };
    }
};
