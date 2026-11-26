//! The 9front syscall table, served by drawterm's kern. Runs on the
//! process's own kernel thread (kern.spawn), so `up` is the calling Proc.
//!
//! Numbers and argument layouts are from 9front's libc/9syscall/sys.h and
//! port/sys*.c at the pinned release. Arguments are 8-byte slots on the user
//! stack from SP+8; narrower values sit in the low bytes of their slot.
//! Calls not here post "sys: bad sys call", as 9front does for unknown ones.

const std = @import("std");
const engine = @import("../../engine.zig");
const kern = @import("../../kern.zig");
const gm = @import("../../guestmem.zig");
const segment = @import("../../segment.zig");

pub const Nr = enum(u64) {
    errstr = 41,
    exec = 7,
    rfork = 19,
    pipe = 21,
    await = 47,
    bind = 2,
    chdir = 3,
    fauth = 10,
    unmount = 35,
    mount = 46,
    close = 4,
    dup = 5,
    exits = 8,
    sleep = 17,
    open = 14,
    create = 22,
    fd2path = 23,
    brk_ = 24,
    remove = 25,
    wstat = 44,
    fwstat = 45,
    notify = 28,
    noted = 29,
    seek = 39,
    stat = 42,
    fstat = 43,
    pread = 50,
    pwrite = 51,
    segbrk = 12,
    segattach = 30,
    segdetach = 31,
    segfree = 32,
    segflush = 33,
    rendezvous = 34,
    semacquire = 37,
    semrelease = 38,
    tsemacquire = 52,
    /// The only underscore call h9 serves (design/epoch-0/go-compat.md).
    _nsec = 53,
    _,
};

/// What the process should do after a syscall.
pub const Outcome = union(enum) {
    /// Return `ret` to the guest.
    ret: u64,
    /// The process exits with this status (copied into Process.msg).
    exits: []const u8,
    /// rfork with these flags; the process model does it, and traces it.
    rfork: u32,
    /// exec; the process model does it, and traces it. The strings are
    /// allocated with the process's allocator, and the receiver frees them.
    exec: Exec,
    /// noted with this argument; the process model restores the registers.
    noted: i32,
};

pub const Exec = struct {
    path: [:0]u8,
    argv: [][:0]u8,

    pub fn deinit(e: Exec, gpa: std.mem.Allocator) void {
        gpa.free(e.path);
        for (e.argv) |a| gpa.free(a);
        gpa.free(e.argv);
    }
};

/// The most argument bytes exec accepts; the stack limits them further.
const max_exec_args: usize = 8 << 20;

/// Per-process state the syscalls need beyond the kernel's.
pub const Process = struct {
    /// Machine-local pid, as in the trace and Tos.
    pid: u32 = 1,
    gpa: std.mem.Allocator,
    engine: engine.Engine,
    as: engine.AddressSpace,
    /// Text, data, stack and segattach's segments, as mappings in its Mms;
    /// brk_ moves the end of data. Guest memory is reached through it.
    space: *segment.Space,
    /// For the Mm's lock on layout changes, which RFMEM siblings share.
    io: std.Io,
    /// The note handler from notify, or 0.
    notify: u64 = 0,
    trace: ?*std.Io.Writer = null,
    /// Serializes trace lines from the processes sharing `trace`.
    trace_lock: ?*std.atomic.Mutex = null,
    /// Holds the exits string or note.
    msg: [kern.ERRMAX + 64]u8 = undefined,
    name_buf: [1024]u8 = undefined,
    name2_buf: [1024]u8 = undefined,
    /// mount's and fauth's attach name (aname).
    spec_buf: [1024]u8 = undefined,
    /// The current call's arguments, formatted for the trace.
    targs: [256]u8 = undefined,
    targs_len: usize = 0,

    /// Traces a call the process model finished (rfork and exec).
    pub fn traceRet(p: *Process, nm: []const u8, v: i64) void {
        const w = p.trace orelse return;
        p.lockTrace();
        defer p.unlockTrace();
        const args = p.targs[0..p.targs_len];
        if (v == -1) {
            w.print("{d} {s}{s} = -1 '{s}'\n", .{ p.pid, nm, args, kern.errstr() }) catch {};
        } else {
            w.print("{d} {s}{s} = {d}\n", .{ p.pid, nm, args, v }) catch {};
        }
        w.flush() catch {};
    }

    fn lockTrace(p: *Process) void {
        if (p.trace_lock) |l| while (!l.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlockTrace(p: *Process) void {
        if (p.trace_lock) |l| l.unlock();
    }

    fn note(p: *Process, comptime fmt: []const u8, args: anytype) void {
        if (p.trace == null) return;
        p.targs_len = if (std.fmt.bufPrint(&p.targs, " " ++ fmt, args)) |t| t.len else |_| p.targs.len;
    }
};

const fail: Outcome = .{ .ret = @bitCast(@as(i64, -1)) };

/// A call the kernel refuses with a note, as 9front's do: the note is
/// posted to the caller (delivered when the call returns, so a handler can
/// catch it), and the call fails with "bad arg in system call".
fn sysNote(p: *Process, msg: [*:0]const u8) Outcome {
    _ = kern.postNote(p.pid, msg, .debug) catch {};
    kern.setErrstr("bad arg in system call");
    return fail;
}

fn ok(v: anytype) Outcome {
    return .{ .ret = @bitCast(@as(i64, @intCast(v))) };
}

/// A call's arguments on the user stack, in slots of the architecture's
/// word: 8 bytes on arm64 and amd64, where every argument takes one slot;
/// 4 on 386, in 8c's layout, where a vlong takes two (`vlongSlots`). They
/// were just written there, so the pages are in and read through the
/// address space, or through the process's Mms (`space`) if not.
const Args = struct {
    as: engine.AddressSpace,
    space: ?*const segment.Space = null,
    base: u64,
    word: u64 = 8,

    fn u(a: Args, i: u64) gm.Error!u64 {
        return gm.readWord(a.as, a.base + a.word * i, a.word) catch
            (a.space orelse return error.BadAddress).readWord(a.base + a.word * i, a.word);
    }
    /// The slots a vlong argument takes, for the index of the next one.
    fn vlongSlots(a: Args) u64 {
        return 8 / a.word;
    }
    fn int(a: Args, i: u64) gm.Error!i32 {
        return @bitCast(@as(u32, @truncate(try a.u(i))));
    }
    fn uint(a: Args, i: u64) gm.Error!u32 {
        return @truncate(try a.u(i));
    }
    fn vlong(a: Args, i: u64) gm.Error!i64 {
        return @bitCast(gm.readU64(a.as, a.base + a.word * i) catch
            try (a.space orelse return error.BadAddress).readWord(a.base + a.word * i, 8));
    }
};

pub fn dispatch(p: *Process, u: *const engine.Ureg) Outcome {
    const a: Args = .{ .as = p.as, .space = p.space, .base = u.syscallArgs(), .word = u.wordSize() };
    p.targs_len = 0;
    const nr: Nr = @enumFromInt(u.syscallNumber());
    const out = serve(p, nr, a) catch |e| switch (e) {
        error.BadAddress => sysNote(p, "sys: bad address in syscall"),
        error.OutOfMemory => blk: {
            kern.setErrstr("no memory");
            break :blk fail;
        },
    };
    if (p.trace) |w| traceCall(w, p, nr, u.syscallNumber(), out);
    return out;
}

fn traceCall(w: *std.Io.Writer, p: *Process, nr: Nr, raw: u64, out: Outcome) void {
    var nb: [24]u8 = undefined;
    const nm = std.enums.tagName(Nr, nr) orelse (std.fmt.bufPrint(&nb, "sys{d}", .{raw}) catch "sys?");
    const args = p.targs[0..p.targs_len];
    if (out == .rfork or out == .exec or out == .noted) return;
    p.lockTrace();
    defer p.unlockTrace();
    switch (out) {
        .ret => |r| {
            const v: i64 = @bitCast(r);
            if (v == -1) {
                w.print("{d} {s}{s} = -1 '{s}'\n", .{ p.pid, nm, args, kern.errstr() }) catch {};
            } else {
                w.print("{d} {s}{s} = {d}\n", .{ p.pid, nm, args, v }) catch {};
            }
        },
        .exits => |m| w.print("{d} exits \"{s}\"\n", .{ p.pid, m }) catch {},
        .rfork, .exec, .noted => return,
    }
    w.flush() catch {};
}

fn serve(p: *Process, nr: Nr, a: Args) (gm.Error || std.mem.Allocator.Error)!Outcome {
    switch (nr) {
        .rfork => {
            p.note("0x{x}", .{try a.uint(0)});
            return .{ .rfork = try a.uint(0) };
        },
        .exec => return execArgs(p, try a.u(0), try a.u(1), a.word),
        .await => {
            // await(char *s, int n): the message, truncated and NUL-terminated
            // as snprint leaves it.
            const buf = try a.u(0);
            const n = try a.uint(1);
            var tmp: [kern.ERRMAX + 128]u8 = undefined;
            const len = kern.await(&tmp) catch return fail;
            if (n == 0) return ok(0);
            const m = @min(len, n - 1, tmp.len - 1);
            try p.space.write(buf, tmp[0..m]);
            try p.space.write(buf + m, "\x00");
            return ok(m);
        },
        .pipe => {
            const fds = try a.u(0);
            // Check the array before making the pipe, so a bad one leaks nothing.
            try p.space.touch(fds, 8, true);
            const fd = kern.pipe() catch return fail;
            var b: [8]u8 = undefined;
            std.mem.writeInt(i32, b[0..4], fd[0], .little);
            std.mem.writeInt(i32, b[4..8], fd[1], .little);
            try p.space.write(fds, &b);
            return ok(0);
        },
        .exits => {
            const ptr = try a.u(0);
            const s = if (ptr == 0) "" else p.space.string(ptr, p.msg[0..kern.ERRMAX]) catch
                // 9front truncates over-long exit strings rather than failing.
                truncated(p, ptr);
            return .{ .exits = s };
        },
        .errstr => {
            const buf = try a.u(0);
            const len = @min(try a.uint(1), kern.ERRMAX);
            if (len == 0) return fail;
            var tmp: [kern.ERRMAX]u8 = @splat(0);
            const s = p.space.string(buf, tmp[0..len]) catch "";
            tmp[s.len] = 0;
            kern.swapErrstr(&tmp);
            const n = std.mem.indexOfScalar(u8, &tmp, 0) orelse len - 1;
            const m = @min(n, len - 1);
            try p.space.write(buf, tmp[0..m]);
            try p.space.write(buf + m, "\x00");
            return ok(0);
        },
        .open => {
            const path = try p.space.string(try a.u(0), &p.name_buf);
            p.note("\"{s}\" {d}", .{ path, try a.int(1) });
            return result(kern.open(path, try a.int(1)));
        },
        .create => {
            const path = try p.space.string(try a.u(0), &p.name_buf);
            p.note("\"{s}\" {d} {o}", .{ path, try a.int(1), try a.uint(2) });
            return result(kern.create(path, try a.int(1), try a.uint(2)));
        },
        .close => {
            p.note("{d}", .{try a.int(0)});
            return result0(kern.close(fdArg(try a.int(0)) orelse return badFd()));
        },
        .dup => {
            const fd0 = fdArg(try a.int(0)) orelse return badFd();
            return result(kern.dup(fd0, try a.int(1)));
        },
        .pread => {
            p.note("{d} {d}", .{ try a.int(0), @as(u32, @truncate(try a.u(2))) });
            const fd = fdArg(try a.int(0)) orelse return badFd();
            return io(p, fd, try a.u(1), @as(u32, @truncate(try a.u(2))), try a.vlong(3), .read);
        },
        .pwrite => {
            p.note("{d} {d}", .{ try a.int(0), @as(u32, @truncate(try a.u(2))) });
            const fd = fdArg(try a.int(0)) orelse return badFd();
            return io(p, fd, try a.u(1), @as(u32, @truncate(try a.u(2))), try a.vlong(3), .write);
        },
        .seek => {
            // seek(vlong *ret, int fd, vlong off, int whence)
            const retp = try a.u(0);
            const fd = fdArg(try a.int(1)) orelse return badFd();
            const r = kern.seek(fd, try a.vlong(2), try a.int(2 + a.vlongSlots())) catch return fail;
            var b: [8]u8 = undefined;
            std.mem.writeInt(i64, &b, r, .little);
            try p.space.write(retp, &b);
            return ok(0);
        },
        .fd2path => {
            const fd = fdArg(try a.int(0)) orelse return badFd();
            const buf = try a.u(1);
            const len = @min(try a.uint(2), p.name_buf.len);
            kern.fd2path(fd, p.name_buf[0..len]) catch return fail;
            const s = std.mem.sliceTo(p.name_buf[0..len], 0);
            try p.space.write(buf, s);
            if (s.len < len) try p.space.write(buf + s.len, "\x00");
            return ok(0);
        },
        .stat, .fstat => {
            const buf = try a.u(1);
            const len = try a.uint(2);
            var tmp: [65536]u8 = undefined;
            const want = @min(len, tmp.len);
            const n = if (nr == .stat)
                kern.stat(try p.space.string(try a.u(0), &p.name_buf), tmp[0..want]) catch return fail
            else
                kern.fstat(fdArg(try a.int(0)) orelse return badFd(), tmp[0..want]) catch return fail;
            try p.space.write(buf, tmp[0..@min(n, want)]);
            return ok(n);
        },
        .chdir => return result0(kern.chdir(try p.space.string(try a.u(0), &p.name_buf))),
        .bind => {
            const old = try p.space.string(try a.u(0), &p.name_buf);
            const new = try p.space.string(try a.u(1), &p.name2_buf);
            return result0(kern.bind(old, new, try a.int(2)));
        },
        .mount => {
            // mount(int fd, int afd, char *old, int flag, char *aname)
            // (design/epoch-0/devsrv.md): drawterm's sysmount, which closes fd.
            const old = try p.space.string(try a.u(2), &p.name_buf);
            const spec_va = try a.u(4);
            const spec: [:0]const u8 = if (spec_va == 0) "" else try p.space.string(spec_va, &p.spec_buf);
            const flag = try a.int(3);
            p.note("{d} {d} \"{s}\" {d} \"{s}\"", .{ try a.int(0), try a.int(1), old, flag, spec });
            const fd = fdArg(try a.int(0)) orelse return badFd();
            return result(kern.mount(fd, try a.int(1), old, flag, spec));
        },
        .unmount => {
            // unmount(char *name, char *old): name may be nil.
            const name_va = try a.u(0);
            const name: ?[:0]const u8 = if (name_va == 0) null else try p.space.string(name_va, &p.name2_buf);
            const old = try p.space.string(try a.u(1), &p.name_buf);
            p.note("\"{s}\" \"{s}\"", .{ name orelse "nil", old });
            return result0(kern.unmount(if (name) |n| n.ptr else null, old));
        },
        .fauth => {
            // fauth(int fd, char *aname)
            const spec_va = try a.u(1);
            const spec: [:0]const u8 = if (spec_va == 0) "" else try p.space.string(spec_va, &p.spec_buf);
            p.note("{d} \"{s}\"", .{ try a.int(0), spec });
            const fd = fdArg(try a.int(0)) orelse return badFd();
            return result(kern.fauth(fd, spec));
        },
        .remove => return result0(kern.remove(try p.space.string(try a.u(0), &p.name_buf))),
        .wstat, .fwstat => {
            const len = try a.uint(2);
            var tmp: [65536]u8 = undefined;
            if (len > tmp.len) return fail;
            try p.space.read(try a.u(1), tmp[0..len]);
            const n = if (nr == .wstat)
                kern.wstat(try p.space.string(try a.u(0), &p.name_buf), tmp[0..len]) catch return fail
            else
                kern.fwstat(fdArg(try a.int(0)) orelse return badFd(), tmp[0..len]) catch return fail;
            return ok(n);
        },
        .sleep => {
            p.note("{d}", .{try a.int(0)});
            return result0(kern.sleep(try a.int(0)));
        },
        .notify => {
            p.notify = try a.u(0);
            kern.setNotify(p.notify != 0);
            return ok(0);
        },
        .noted => {
            p.note("{d}", .{try a.int(0)});
            return .{ .noted = try a.int(0) };
        },
        .brk_ => {
            p.note("0x{x}", .{try a.u(0)});
            return brk(p, try a.u(0));
        },
        .segattach => {
            // segattach(int attr, char *class, void *va, ulong len)
            var cls_buf: [32]u8 = undefined;
            const cls_va = try a.u(1);
            // A name too long for any class is just an unknown one.
            const cls: []const u8 = p.space.string(cls_va, &cls_buf) catch |e|
                if (p.space.mapped(cls_va)) "" else return e;
            const va = try a.u(2);
            const len = try a.uint(3);
            p.note("0x{x} \"{s}\" 0x{x} {d}", .{ try a.uint(0), cls, va, len });
            const kind: ?segment.Kind = if (std.mem.eql(u8, cls, "shared"))
                .shared
            else if (std.mem.eql(u8, cls, "memory"))
                .memory
            else
                null;
            const base = p.space.segattach(p.io, kind, try a.uint(0), va, len) catch |e| return segFail(e);
            return .{ .ret = base };
        },
        .segdetach => {
            p.note("0x{x}", .{try a.u(0)});
            p.space.segdetach(p.io, try a.u(0)) catch |e| return segFail(e);
            return ok(0);
        },
        .segbrk => {
            p.note("0x{x} 0x{x}", .{ try a.u(0), try a.u(1) });
            const r = p.space.segbrk(p.io, try a.u(0), try a.u(1)) catch |e| return segFail(e);
            return .{ .ret = r };
        },
        .segfree => {
            p.note("0x{x} {d}", .{ try a.u(0), try a.uint(1) });
            p.space.segfree(try a.u(0), try a.uint(1)) catch |e| return segFail(e);
            return ok(0);
        },
        .segflush => {
            p.note("0x{x} {d}", .{ try a.u(0), try a.uint(1) });
            p.space.segflush(try a.u(0), try a.uint(1)) catch |e| return segFail(e);
            p.as.codeChanged(try a.u(0), try a.uint(1));
            return ok(0);
        },
        .rendezvous => {
            // rendezvous(void *tag, void *val): both whole words.
            p.note("0x{x} 0x{x}", .{ try a.u(0), try a.u(1) });
            return .{ .ret = kern.rendezvous(try a.u(0), try a.u(1)) };
        },
        .semacquire => {
            // semacquire(long *addr, int block)
            p.note("0x{x} {d}", .{ try a.u(0), try a.int(1) });
            var sw = try semWord(p, try a.u(0)) orelse return fail;
            defer p.space.unpin(&sw);
            return ok(@intFromBool(kern.semacquire(semPtr(sw), try a.int(1) != 0) catch return fail));
        },
        .tsemacquire => {
            // tsemacquire(long *addr, ulong ms)
            p.note("0x{x} {d}", .{ try a.u(0), try a.uint(1) });
            var sw = try semWord(p, try a.u(0)) orelse return fail;
            defer p.space.unpin(&sw);
            return ok(@intFromBool(kern.tsemacquire(semPtr(sw), try a.uint(1)) catch return fail));
        },
        .semrelease => {
            // semrelease(long *addr, long count)
            p.note("0x{x} {d}", .{ try a.u(0), try a.int(1) });
            var sw = try semWord(p, try a.u(0)) orelse return fail;
            defer p.space.unpin(&sw);
            return ok(kern.semrelease(semPtr(sw), try a.int(1)) catch return fail);
        },
        ._nsec => {
            // _nsec(vlong*): wall nanoseconds in the return register on
            // 64-bit machines, as 9front's sys_nsec. On 386 it returns 0
            // and stores the time through the pointer, as 9front does there.
            const now = kern.wallNs();
            if (a.word == 8) return .{ .ret = @bitCast(now) };
            const ptr = try a.u(0);
            if (ptr & 3 != 0) return sysNote(p, "sys: odd address");
            var b: [8]u8 = undefined;
            std.mem.writeInt(i64, &b, now, .little);
            try p.space.write(ptr, &b);
            return ok(0);
        },
        _ => return sysNote(p, "sys: bad sys call"),
    }
}

/// The host word behind a semaphore's guest address, checked as 9front's
/// evenaddr and seg checks are (design/epoch-0/semaphores.md): an odd address
/// posts "sys: odd address", an unmapped one is a bad address, and one
/// outside a writable segment fails; those two fail with "bad arg in system
/// call" and return null. A Plan 9 long is 32 bits, and an aligned one
/// never crosses a page.
///
/// The wait lists are keyed by the word's host address (src/kern/sema.c),
/// so its page mustn't move while the call blocks: the word's pages are
/// the process's own, not shared copy-on-write with a fork, and held
/// (`Mm.pin`) until the call returns, so an rfork meanwhile by an RFMEM
/// sibling copies them for its child rather than sharing them, and no
/// write moves them. The caller unpins.
fn semWord(p: *Process, addr: u64) gm.Error!?segment.Space.Pin {
    if (addr & 3 != 0) {
        _ = sysNote(p, "sys: odd address");
        return null;
    }
    if (!p.space.mapped(addr)) return error.BadAddress;
    if (!p.space.writable(addr, 4)) {
        kern.setErrstr("bad arg in system call");
        return null;
    }
    return p.space.pin(addr, 4, true) orelse error.BadAddress;
}

fn semPtr(pn: segment.Space.Pin) *i32 {
    return @ptrCast(@alignCast(pn.p.s.ptr));
}

/// Copies exec's file name and argv out of guest memory.
fn execArgs(p: *Process, file: u64, argp: u64, word: u64) (gm.Error || std.mem.Allocator.Error)!Outcome {
    const path = try p.space.stringAlloc(file, p.gpa, 1024);
    errdefer p.gpa.free(path);
    p.note("\"{s}\"", .{path});
    var argv: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (argv.items) |s| p.gpa.free(s);
        argv.deinit(p.gpa);
    }
    var total: usize = 0;
    while (true) {
        const ptr = try p.space.readWord(argp + word * argv.items.len, word);
        if (ptr == 0) break;
        const s = try p.space.stringAlloc(ptr, p.gpa, max_exec_args - total);
        total += s.len + 1;
        argv.append(p.gpa, s) catch |e| {
            p.gpa.free(s);
            return e;
        };
    }
    if (argv.items.len == 0) {
        p.gpa.free(path);
        argv.deinit(p.gpa);
        kern.setErrstr("bad arg in system call");
        return fail;
    }
    return .{ .exec = .{ .path = path, .argv = try argv.toOwnedSlice(p.gpa) } };
}

fn truncated(p: *Process, ptr: u64) []const u8 {
    var i: usize = 0;
    while (i < kern.ERRMAX - 1) : (i += 1) {
        var b: [1]u8 = undefined;
        p.space.read(ptr + i, &b) catch break;
        if (b[0] == 0) break;
        p.msg[i] = b[0];
    }
    return p.msg[0..i];
}

fn fdArg(fd: i32) ?u31 {
    return if (fd < 0) null else @intCast(fd);
}

fn badFd() Outcome {
    kern.setErrstr("fd out of range or not open");
    return fail;
}

fn result(r: kern.Error!u31) Outcome {
    return if (r) |v| ok(v) else |_| fail;
}

fn result0(r: kern.Error!void) Outcome {
    return if (r) |_| ok(0) else |_| fail;
}

const Dir = enum { read, write };

/// One kernel call per pread or pwrite, as on 9front: splitting a call
/// would end directory reads early and break message boundaries on pipes
/// and ctl files. A buffer that isn't contiguous on the host goes through
/// a bounce buffer; only calls over `gm.max_chunk` are split. Zero-length
/// calls reach the kernel too: a zero-length write to a pipe is a message.
fn io(p: *Process, fd: u31, buf: u64, len: u32, off: i64, comptime dir: Dir) gm.Error!Outcome {
    if (len > gm.max_chunk) return ioSplit(p, fd, buf, len, off, dir);
    if (len == 0) return ok((switch (dir) {
        .read => kern.pread(fd, &.{}, off),
        .write => kern.pwrite(fd, &.{}, off),
    }) catch return fail);
    // The buffer's pages, held for the call, so another process's unmap
    // can't free them under it, and for a read, the process's own first,
    // so it can't land in pages a fork shares copy-on-write.
    if (p.space.pin(buf, len, dir == .read)) |pn_| {
        var pn = pn_;
        defer p.space.unpin(&pn);
        const s = pn.p.s;
        const n = switch (dir) {
            .read => kern.pread(fd, s, off),
            .write => kern.pwrite(fd, s, off),
        } catch return fail;
        // What was compiled or decoded from the pages read into goes.
        if (dir == .read) p.as.hostWrote(s[0..n]);
        return ok(n);
    }
    const tmp = std.heap.page_allocator.alloc(u8, len) catch {
        kern.setErrstr("no memory");
        return fail;
    };
    defer std.heap.page_allocator.free(tmp);
    switch (dir) {
        .read => {
            // Check the range before the read, so a bad buffer has no side effects.
            try p.space.touch(buf, len, true);
            const n = kern.pread(fd, tmp, off) catch return fail;
            try p.space.write(buf, tmp[0..n]);
            return ok(n);
        },
        .write => {
            try p.space.read(buf, tmp);
            return ok(kern.pwrite(fd, tmp, off) catch return fail);
        },
    }
}

fn ioSplit(p: *Process, fd: u31, buf: u64, len: u32, off: i64, comptime dir: Dir) gm.Error!Outcome {
    try p.space.touch(buf, len, dir == .read);
    var done: u64 = 0;
    var o = off;
    while (done < len) {
        const n: u32 = @intCast(@min(len - done, gm.max_chunk));
        const r = try io(p, fd, buf + done, n, o, dir);
        const got: i64 = @bitCast(r.ret);
        if (got < 0) return if (done == 0) fail else ok(done);
        done += @intCast(got);
        if (o != -1) o += got;
        if (got < n) break;
    }
    return ok(done);
}

fn brk(p: *Process, addr: u64) gm.Error!Outcome {
    if (addr == 0) return ok(p.space.brkTop());
    p.space.brk(p.io, addr) catch |e| return segFail(e);
    return ok(0);
}

fn segFail(e: segment.SegError) Outcome {
    kern.setErrstr(segment.errorString(e));
    return fail;
}

test "386 arguments: 4-byte slots, and a vlong takes two" {
    // seek(vlong *ret, int fd, vlong off, int whence) as 8c lays it out.
    var stack: [24]u8 = undefined;
    for ([_]u32{ 0x1000, 3, 0x89abcdef, 0x01234567, 2 }, 0..) |v, i| std.mem.writeInt(u32, stack[i * 4 ..][0..4], v, .little);
    const Ctx = struct {
        fn t(b: *[24]u8, va: u64, len: u64) ?[]u8 {
            if (va < 0x100 or va - 0x100 + len > b.len) return null;
            return b[va - 0x100 ..][0..len];
        }
    };
    const as: engine.AddressSpace = .initFake(&stack, Ctx.t);
    const a: Args = .{ .as = as, .base = 0x100, .word = 4 };
    try std.testing.expectEqual(@as(u64, 0x1000), try a.u(0));
    try std.testing.expectEqual(@as(i32, 3), try a.int(1));
    try std.testing.expectEqual(@as(i64, 0x0123456789abcdef), try a.vlong(2));
    try std.testing.expectEqual(@as(i32, 2), try a.int(2 + a.vlongSlots()));
}
