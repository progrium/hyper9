//! Graphics: one screen per process, a host window drawn by drawterm's GUI
//! backends (design/epoch-0/gfx.md) or a screen in memory, the headless
//! screen (design/headless-screen.md). A machine with `Options.gfx` claims
//! the screen, and its namespace gets `#i`, `#m` and `#b` on /dev; every
//! other machine has them masked. The window backend is chosen at build
//! time (`-Dgfx`); every native build with graphics has the headless
//! screen too, and `Options.gfx.screen` picks one per machine.
//!
//! The kernel side is src/kern/gfx.c, with the backend's own source and
//! src/kern/gfx-headless.c, or src/kern/nogfx.c without graphics. On the
//! browser host the backend is a page's canvas (src/kern/gfx-web.c,
//! design/epoch-0/browser-gfx.md), with no headless screen.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const kern = @import("kern.zig");

pub const Backend = enum { none, headless, x11, win32, cocoa, web };

/// The GUI backend built into this h9.
pub const backend: Backend = std.meta.stringToEnum(Backend, build_options.gfx).?;

/// Whether `Options.gfx` can be honoured at all.
pub const built = backend != .none and kern.available;

/// Whether this build has a window (or the browser host's canvas):
/// `Options.screen = .window`.
pub const has_window = built and backend != .headless;

/// Whether this build has the headless screen: `Options.screen = .headless`.
pub const has_headless = built and backend != .web;

/// Which screen a machine gets (design/headless-screen.md).
pub const Screen = enum {
    /// A host window, or the page's canvas on the browser host.
    window,
    /// A screen in memory: no window, display, or window system, and the
    /// clipboard is a buffer in the h9 process.
    headless,
};

/// The headless screen's size, 1024x768 unless `Options.size` says.
pub const HeadlessSize = struct { dx: u16, dy: u16 };
pub const default_size: HeadlessSize = .{ .dx = 1024, .dy = 768 };

/// A machine's window (`Machine.Options.gfx`).
pub const Options = struct {
    /// A window, or the headless screen.
    screen: Screen = .window,
    /// The headless screen's size (`--gfx-size`); null is `default_size`.
    /// The window backends pick their own.
    size: ?HeadlessSize = null,
    /// Whether /dev/snarf is the host clipboard. False is `--gfx=noclip`:
    /// a buffer in the h9 process, shared by the guest's programs only.
    /// The headless screen's "host clipboard" is itself a buffer in the h9
    /// process, the one `headless.clipboard` reads.
    clipboard: bool = true,
    /// The screen scale, drawterm's `-x`: 0 draws in the display's
    /// backing pixels, 1 in points, N in backing pixels divided by N.
    /// Cocoa and the browser host's canvas (where 1 is CSS pixels, and
    /// the page computes the size); the other backends draw in device
    /// pixels.
    scale: u8 = 1,
};

pub const Error = error{
    /// This h9 has no GUI backend (`-Dgfx=none`), or not the screen asked
    /// for: no window in a `-Dgfx=headless` build, no headless screen on
    /// the browser host.
    GfxNotBuilt,
    /// Another machine in this process has the screen, or the process's
    /// screen already opened as the other kind (or the headless screen at
    /// another size): it opens once per process.
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
    extern fn h9_gfx_web_present() c_int;
    extern var h9_gfx_noclip: c_int;
    extern var scalef: c_int;
    extern var h9_gfx_onclose: ?*const fn () callconv(.c) void;
    extern fn h9_gfx_ready() c_int;
    extern var h9_gfx_headless: c_int;
    extern var h9_gfx_opened: c_int;
    extern var h9_gfx_headless_dx: c_int;
    extern var h9_gfx_headless_dy: c_int;
} else struct {
    fn h9_gfx_web_present() c_int {
        return 0;
    }
    var h9_gfx_noclip: c_int = 0;
    var scalef: c_int = 0;
    var h9_gfx_onclose: ?*const fn () callconv(.c) void = null;
    fn h9_gfx_ready() c_int {
        return 0;
    }
    var h9_gfx_headless: c_int = 0;
    var h9_gfx_opened: c_int = 0;
    var h9_gfx_headless_dx: c_int = 0;
    var h9_gfx_headless_dy: c_int = 0;
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
    switch (opts.screen) {
        .window => if (!has_window) return error.GfxNotBuilt,
        .headless => if (!has_headless) return error.GfxNotBuilt,
    }
    if (built) try claimScreen(io, claim, opts) else return error.GfxNotBuilt;
}

fn claimScreen(io: std.Io, claim: *const Claim, opts: Options) Error!void {
    const headless_screen = opts.screen == .headless;
    // The browser host's h9.wasm has the canvas backend, but only a page
    // that passed a canvas has a screen; h9-node never does, and says so
    // as a build without graphics would (design/epoch-0/browser-gfx.md).
    if (backend == .web and c.h9_gfx_web_present() == 0) return error.GfxNotBuilt;
    if (!headless_screen and unavailable() != null) return error.GfxUnavailable;
    const size = opts.size orelse default_size;
    if (owner.cmpxchgStrong(null, claim, .acq_rel, .acquire) != null) return error.GfxInUse;
    // The screen opens once per process, at the first draw, and stays: a
    // later machine gets the same one, so it must ask for the same kind
    // (and the headless screen at the same size).
    const opened = c.h9_gfx_opened;
    if (opened != 0) {
        const same = if (headless_screen)
            opened == 2 and c.h9_gfx_headless_dx == size.dx and c.h9_gfx_headless_dy == size.dy
        else
            opened == 1;
        if (!same) {
            release(claim);
            return error.GfxInUse;
        }
    }
    c.h9_gfx_headless = @intFromBool(headless_screen);
    c.h9_gfx_headless_dx = size.dx;
    c.h9_gfx_headless_dy = size.dy;
    c.h9_gfx_noclip = @intFromBool(!opts.clipboard);
    c.scalef = opts.scale;
    c.h9_gfx_onclose = onClose;
    if (backend == .cocoa and !headless_screen) {
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
/// it calls `work` directly. The headless screen needs none of this.
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

/// The headless screen's hooks (src/kern/gfx-headless.c), in any build
/// with it (design/headless-screen.md): what a window system would do to
/// a window, acting on the machine whose screen is headless. They may be
/// called from any thread.
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
        if (backend == .none or backend == .web) @compileError("h9.gfx.headless needs a build with the headless screen");
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

    /// The headless screen's "host clipboard" text, copied into `buf`.
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

    /// The headless screen's size, or null before it opens (or when the
    /// process's screen is a window).
    pub fn size() ?Size {
        var dx: c_int = 0;
        var dy: c_int = 0;
        if (h.h9_gfx_headless_size(&dx, &dy) < 0) return null;
        return .{ .dx = @intCast(dx), .dy = @intCast(dy) };
    }

    /// The screen's pixels, XRGB32 (one little-endian u32 per pixel, row
    /// by row), into `buf`, which holds at least 4*dx*dy bytes. False
    /// before the headless screen opens. Read it while nothing's drawing,
    /// or read /dev/screen in the machine, which takes the draw lock.
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
