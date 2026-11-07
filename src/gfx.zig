//! Graphics: one host window per process, drawn by drawterm's GUI backends
//! (design/0015-gfx.md). A machine with `Options.gfx` claims the screen,
//! and its namespace gets `#i`, `#m` and `#b` on /dev; every other machine
//! has them masked. The backend is chosen at build time (`-Dgfx`).
//!
//! The kernel side is src/kern/gfx.c, with the backend's own source, or
//! src/kern/nogfx.c without one.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const kern = @import("kern.zig");

pub const Backend = enum { none, headless, x11, win32, cocoa };

/// The GUI backend built into this h9.
pub const backend: Backend = std.meta.stringToEnum(Backend, build_options.gfx).?;

/// Whether `Options.gfx` can be honoured at all.
pub const built = backend != .none and kern.available;

/// A machine's window (`Machine.Options.gfx`).
pub const Options = struct {
    /// Whether /dev/snarf is the host clipboard. False is `--gfx=noclip`:
    /// a buffer in the h9 process, shared by the guest's programs only.
    clipboard: bool = true,
    /// The screen scale, drawterm's `-x`: 0 draws in the display's
    /// backing pixels, 1 in points, N in backing pixels divided by N.
    /// Cocoa only; the other backends draw in device pixels.
    scale: u8 = 1,
};

pub const Error = error{
    /// This h9 has no GUI backend (`-Dgfx=none`).
    GfxNotBuilt,
    /// Another machine in this process has the screen.
    GfxInUse,
    /// There's no display; `unavailable` says why.
    GfxUnavailable,
};

/// What closing the window does to the machine that has the screen: its
/// `Signals.hangup`, as for a closed terminal.
pub const Claim = struct {
    ctx: *anyopaque,
    close: *const fn (ctx: *anyopaque) void,
};

const c = if (built) struct {
    extern var h9_gfx_noclip: c_int;
    extern var scalef: c_int;
    extern var h9_gfx_onclose: ?*const fn () callconv(.c) void;
    extern fn h9_gfx_ready() c_int;
} else struct {
    var h9_gfx_noclip: c_int = 0;
    var scalef: c_int = 0;
    var h9_gfx_onclose: ?*const fn () callconv(.c) void = null;
    fn h9_gfx_ready() c_int {
        return 0;
    }
};

const cocoa = struct {
    extern fn h9_kern_adopt(name: [*:0]const u8) c_int;
    extern fn guimain() void;
    extern fn h9_gfx_cocoa_observe() void;
    extern var h9_gfx_onterminate: ?*const fn () callconv(.c) void;
    extern fn usleep(us: c_uint) c_int;
};

const x11 = struct {
    const Display = opaque {};
    extern fn XOpenDisplay(name: ?[*:0]const u8) ?*Display;
    extern fn XCloseDisplay(d: *Display) c_int;
};

var owner: std.atomic.Value(?*const Claim) = .init(null);
/// Set by `main` on macOS once AppKit has the main thread.
var main_handed: std.atomic.Value(bool) = .init(false);

/// Why there's no display to open a window on, or null if there is one
/// (or might be: X11's `$DISPLAY` is only opened with the window).
pub fn unavailable() ?[]const u8 {
    switch (backend) {
        .x11 => {
            const d = std.c.getenv("DISPLAY") orelse return "$DISPLAY isn't set";
            if (std.mem.span(d).len == 0) return "$DISPLAY isn't set";
        },
        .cocoa => if (!main_handed.load(.acquire)) return "the program didn't give its main thread to h9.gfx.main",
        else => {},
    }
    return null;
}

/// For `--check`: on X11, whether `$DISPLAY` opens, without opening a
/// window. Null means there's nothing to check beyond `unavailable`.
pub fn probeDisplay() ?bool {
    if (backend == .x11) {
        if (unavailable() != null) return false;
        const d = x11.XOpenDisplay(null) orelse return false;
        _ = x11.XCloseDisplay(d);
        return true;
    } else return null;
}

/// Claims the screen for a machine, and sets the clipboard and scale for
/// its window. On macOS it waits for AppKit to open the window, so the
/// machine's first attach of `#i` finds it. Fails if this h9 has no
/// backend, another machine has the screen or there's no display.
pub fn acquire(io: std.Io, claim: *const Claim, opts: Options) Error!void {
    if (built) try claimScreen(io, claim, opts) else return error.GfxNotBuilt;
}

fn claimScreen(io: std.Io, claim: *const Claim, opts: Options) Error!void {
    if (unavailable() != null) return error.GfxUnavailable;
    if (owner.cmpxchgStrong(null, claim, .acq_rel, .acquire) != null) return error.GfxInUse;
    c.h9_gfx_noclip = @intFromBool(!opts.clipboard);
    c.scalef = opts.scale;
    c.h9_gfx_onclose = onClose;
    if (backend == .cocoa) {
        // AppKit opens the window at start; give it 10 s.
        var waited: u32 = 0;
        while (c.h9_gfx_ready() == 0) : (waited += 10) {
            if (waited >= 10_000) {
                release(claim);
                return error.GfxUnavailable;
            }
            io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }
}

/// Gives the screen up, if `claim` has it. The window stays open with
/// what was drawn, until h9 exits or another machine draws.
pub fn release(claim: *const Claim) void {
    _ = owner.cmpxchgStrong(claim, null, .acq_rel, .acquire);
}

/// The backend's close path (src/kern/gfx.c), on its event thread.
fn onClose() callconv(.c) void {
    if (owner.load(.acquire)) |o| o.close(o.ctx);
}

/// Runs `work` with the GUI set up. On macOS this must be called on the
/// process's main thread: it gives that thread to AppKit and runs `work`
/// on a new thread, and returns only through `work`'s exit code. Elsewhere
/// it calls `work` directly.
pub fn main(work: *const fn (?*anyopaque) u8, ctx: ?*anyopaque) noreturn {
    if (backend == .cocoa) cocoaMain(work, ctx) else std.process.exit(work(ctx));
}

fn cocoaMain(work: *const fn (?*anyopaque) u8, ctx: ?*anyopaque) noreturn {
    // The main thread becomes a kernel Proc, since drawterm's Cocoa
    // delegate sleeps and starts kprocs on it.
    kern.boot() catch fatal("can't boot the kernel");
    if (cocoa.h9_kern_adopt("gfx") < 0) fatal("can't adopt the main thread");
    Work.fn_ = work;
    Work.ctx = ctx;
    main_handed.store(true, .release);
    const t = std.Thread.spawn(.{}, Work.run, .{}) catch fatal("can't start a thread");
    t.detach();
    cocoa.h9_gfx_onterminate = Work.terminate;
    cocoa.h9_gfx_cocoa_observe();
    cocoa.guimain();
    // AppKit returns only by exiting.
    std.process.exit(0);
}

const Work = struct {
    var fn_: *const fn (?*anyopaque) u8 = undefined;
    var ctx: ?*anyopaque = null;
    var code: std.atomic.Value(u32) = .init(running);
    const running = 0x100;

    fn run() void {
        const rc = fn_(ctx);
        code.store(rc, .release);
        std.process.exit(rc);
    }

    /// AppKit is ending (the window's close button, or Quit): the machine
    /// with the screen gets hangup, and h9 exits with the run's status once
    /// it ends, or after the grace period and a little more.
    fn terminate() callconv(.c) void {
        onClose();
        var waited: u32 = 0;
        while (waited < 2500) : (waited += 10) {
            const rc = code.load(.acquire);
            if (rc != running) std.c._exit(@intCast(rc));
            _ = cocoa.usleep(10_000);
        }
        std.c._exit(1);
    }
};

fn fatal(msg: []const u8) noreturn {
    std.debug.print("h9: --gfx: {s}\n", .{msg});
    std.process.exit(125);
}

/// The headless backend's test hooks (src/kern/gfx-headless.c), for
/// `-Dgfx=headless` builds: what a window system would do to the window.
/// They may be called from any thread.
pub const headless = struct {
    const h = struct {
        extern fn h9_gfx_headless_key(r: u32, down: c_int) void;
        extern fn h9_gfx_headless_mouse(x: c_int, y: c_int, b: c_int) void;
        extern fn h9_gfx_headless_clipread() ?[*:0]u8;
        extern fn h9_gfx_headless_clipwrite(s: [*:0]const u8) void;
        extern fn h9_gfx_headless_size(dx: *c_int, dy: *c_int) c_int;
        extern fn h9_gfx_headless_pixels(buf: [*]u8, n: c_long) c_int;
        extern fn h9_gfx_headless_close() void;
        extern fn free(p: ?*anyopaque) void;
    };

    comptime {
        if (backend != .headless) @compileError("h9.gfx.headless needs -Dgfx=headless");
    }

    /// A key typed in the window: pressed, then released.
    pub fn key(r: u21) void {
        h.h9_gfx_headless_key(r, 1);
        h.h9_gfx_headless_key(r, 0);
    }

    /// A key pressed (`down`) or released.
    pub fn keyEvent(r: u21, down: bool) void {
        h.h9_gfx_headless_key(r, @intFromBool(down));
    }

    /// The mouse at x, y, with `buttons` held (1 left, 2 middle, 4 right).
    pub fn mouse(x: i32, y: i32, buttons: u8) void {
        h.h9_gfx_headless_mouse(x, y, buttons);
    }

    /// The host clipboard's text, copied into `buf`.
    pub fn clipboard(buf: []u8) []const u8 {
        const s = h.h9_gfx_headless_clipread() orelse return buf[0..0];
        defer h.free(s);
        const t = std.mem.span(s);
        const n = @min(t.len, buf.len);
        @memcpy(buf[0..n], t[0..n]);
        return buf[0..n];
    }

    pub fn setClipboard(text: [:0]const u8) void {
        h.h9_gfx_headless_clipwrite(text.ptr);
    }

    pub const Size = struct { dx: u32, dy: u32 };

    /// The screen's size, or null before it opens.
    pub fn size() ?Size {
        var dx: c_int = 0;
        var dy: c_int = 0;
        if (h.h9_gfx_headless_size(&dx, &dy) < 0) return null;
        return .{ .dx = @intCast(dx), .dy = @intCast(dy) };
    }

    /// The screen's pixels, XRGB32 (one little-endian u32 per pixel, row
    /// by row), into `buf`, which holds at least 4*dx*dy bytes. False
    /// before the screen opens. Read it while nothing's drawing.
    pub fn pixels(buf: []u8) bool {
        return h.h9_gfx_headless_pixels(buf.ptr, @intCast(buf.len)) == 0;
    }

    /// Closes the window, as its close button would.
    pub fn close() void {
        h.h9_gfx_headless_close();
    }
};

test "without a backend, acquire fails with GfxNotBuilt" {
    if (built) return error.SkipZigTest;
    const Nop = struct {
        fn close(_: *anyopaque) void {}
    };
    var x: u8 = 0;
    const claim: Claim = .{ .ctx = &x, .close = Nop.close };
    try std.testing.expectError(error.GfxNotBuilt, acquire(std.testing.io, &claim, .{}));
}
