//! The host's devices (design/host-handles.md): the kernel's devices that
//! reach outside the machine, which the kernel's Zig (src/kern/dev.zig)
//! names and which call back into it. `fs` is the host tree device,
//! `#U`, and `ip` the host network device, `#I`, which the namespace
//! kernel doesn't build.

const kern = @import("kern");

pub const fs = @import("devfs.zig");
pub const ip = @import("devip.zig");

pub fn exportC() void {
    fs.exportC();
    if (!kern.options.nskernel) ip.exportC();
}
