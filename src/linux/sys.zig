//! The Linux syscall table (design/0018-linux-personality.md, "Syscalls"),
//! served by drawterm's kern on the calling process's own thread, as
//! src/syscall.zig serves 9front's.
//!
//! Every entry is served (translated onto the kernel), stubbed (a fixed
//! answer that's right for h9) or absent (-ENOSYS, and a line under
//! --trace), so ENOSYS always means "not known to h9". Results are Linux's:
//! a value, or -errno. Arguments the ABI types as `int` are narrowed to 32
//! bits on entry.

const std = @import("std");
const builtin = @import("builtin");
const vmm = @import("../vmm.zig");
const kern = @import("../kern.zig");
const gm = @import("../guestmem.zig");
const mm = @import("mm.zig");
const nr = @import("nr.zig");
const kc = @import("kc.zig");
pub const cputime = @import("cputime.zig");
const locks = @import("locks.zig");
const shmfile = @import("shmfile.zig");
const sysvshm = @import("sysvshm.zig");
const itimer = @import("itimer.zig");
const attr = @import("../dotl/attr.zig");
const sig = @import("signal.zig");
const netlink = @import("netlink.zig");

const E = attr.E;
const Sys = nr.Sys;
const page = vmm.page_size;

/// What the process model does after a call.
pub const Outcome = union(enum) {
    /// Return this to the guest.
    ret: u64,
    /// The process exits with this status (an `exits` string).
    exits: []const u8,
    /// fork, vfork or clone.
    clone: Clone,
    /// execve. The strings belong to the process's allocator.
    exec: Exec,
    /// rt_sigreturn: the process model restores the frame.
    sigreturn,
};

pub const Clone = struct {
    flags: u64,
    /// The child's stack, or 0 to keep the caller's.
    stack: u64 = 0,
    ptid: u64 = 0,
    ctid: u64 = 0,
    tls: u64 = 0,
};

pub const CLONE_VM = 0x100;
pub const CLONE_FS = 0x200;
pub const CLONE_FILES = 0x400;
pub const CLONE_SIGHAND = 0x800;
pub const CLONE_VFORK = 0x4000;
pub const CLONE_PARENT = 0x8000;
pub const CLONE_THREAD = 0x10000;
pub const CLONE_SETTLS = 0x80000;
pub const CLONE_PARENT_SETTID = 0x100000;
pub const CLONE_CHILD_CLEARTID = 0x200000;
pub const CLONE_CHILD_SETTID = 0x1000000;
const CLONE_NEW_ANY: u64 = 0x7e020000; // NEWNS|NEWCGROUP|NEWUTS|NEWIPC|NEWUSER|NEWPID|NEWNET (and NEWTIME is 0x80)

pub const Exec = struct {
    path: [:0]u8,
    argv: [][:0]u8,
    envp: [][:0]u8,

    pub fn deinit(e: Exec, gpa: std.mem.Allocator) void {
        gpa.free(e.path);
        for (e.argv) |a| gpa.free(a);
        gpa.free(e.argv);
        for (e.envp) |a| gpa.free(a);
        gpa.free(e.envp);
    }
};

pub const ThreadKill = struct { tgid: u32 = 0 };

/// What the process model provides to calls that reach other processes.
pub const Host = struct {
    ctx: *anyopaque,
    /// Posts signal `signo` (0 only checks) to pid > 0, to the process
    /// group -pid for pid < -1, to the caller's group for 0, or to every
    /// process for -1. With `thread`, pid is a thread's tid and the signal
    /// is that thread's alone (tgkill), in thread group `thread.tgid` if
    /// it isn't 0. Returns 0 or -errno.
    kill: *const fn (ctx: *anyopaque, from: *Process, pid: i64, signo: u8, thread: ?ThreadKill) i64,
    /// The process group of pid, or null if there's no such process.
    pgidOf: *const fn (ctx: *anyopaque, pid: u32) ?u32,
};

/// A process's user and group ids. h9 has no users: they change what the
/// id calls and `stat` report, and nothing else. A program that drops
/// root (`su`, PostgreSQL's checks) sees itself as that user, and every
/// file as its own, so its ownership checks pass; access is still the
/// namespace's and the sandbox's.
pub const Cred = struct {
    uid: [3]u32 = .{ 0, 0, 0 },
    gid: [3]u32 = .{ 0, 0, 0 },
    groups: [32]u32 = undefined,
    ngroups: u8 = 0,

    /// What an unprivileged process may set an id to: one of its own.
    fn mayBe(ids: [3]u32, want: u32) bool {
        return want == ids[0] or want == ids[1] or want == ids[2];
    }

    fn root(c: *const Cred) bool {
        return c.uid[1] == 0;
    }

    /// setresuid/setresgid: -1 keeps an id.
    fn setRes(c: *Cred, ids: *[3]u32, r: i64, e: i64, s: i64) i64 {
        const want = [3]i64{ r, e, s };
        for (want) |w| if (w != -1 and (w < 0 or w > std.math.maxInt(u32) or (!c.root() and !mayBe(ids.*, @intCast(w))))) return -E.PERM;
        for (want, 0..) |w, i| if (w != -1) {
            ids[i] = @intCast(w);
        };
        return 0;
    }

    /// setuid/setgid: root sets all three, others only the effective id.
    fn setOne(c: *Cred, ids: *[3]u32, v: i64) i64 {
        if (v < 0 or v > std.math.maxInt(u32)) return -E.INVAL;
        const id: u32 = @intCast(v);
        if (c.root()) {
            ids.* = .{ id, id, id };
            return 0;
        }
        if (!mayBe(ids.*, id)) return -E.PERM;
        ids[1] = id;
        return 0;
    }

    /// setreuid/setregid: the saved id follows a changed real id, or an
    /// effective id set to something other than the real one.
    fn setRe(c: *Cred, ids: *[3]u32, r: i64, e: i64) i64 {
        const old = ids.*;
        if (r != -1 and (r < 0 or r > std.math.maxInt(u32) or (!c.root() and r != old[0] and r != old[1]))) return -E.PERM;
        if (e != -1 and (e < 0 or e > std.math.maxInt(u32) or (!c.root() and !mayBe(old, @intCast(e))))) return -E.PERM;
        if (r != -1) ids[0] = @intCast(r);
        if (e != -1) ids[1] = @intCast(e);
        if (r != -1 or (e != -1 and ids[1] != old[0])) ids[2] = ids[1];
        return 0;
    }
};

pub const FdFlags = packed struct(u8) {
    append: bool = false,
    nonblock: bool = false,
    /// Opened with O_PATH.
    path: bool = false,
    _: u5 = 0,
};

/// Directory entries read but not yet returned by getdents64.
const DirBuf = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,
    off: usize = 0,
    eof: bool = false,
    /// Hashes of the names returned so far: a union directory lists a
    /// name once for each of its members, and Linux lists it once.
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
};

fn freeDirBuf(gpa: std.mem.Allocator, b: *DirBuf) void {
    b.seen.deinit(gpa);
    gpa.destroy(b);
}

/// A reaped child: its pid, wait status, and CPU time in ms, which
/// counts its own reaped children.
const WaitRec = struct { pid: u32, status: u32, user_ms: u64 = 0, sys_ms: u64 = 0 };

/// What the threads of one process share (design/0049-linux-threads.md):
/// per-fd state, sockets and epoll interest lists, and its members, for
/// signal actions, exit_group and execve. A process without threads is a
/// group of one. Each member holds a reference.
pub const Group = struct {
    gpa: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    /// Guards everything below. Held only briefly, never across a wait.
    lock: std.atomic.Mutex = .unlocked,
    /// The leader's pid, which getpid returns.
    tgid: u32,
    members: std.ArrayList(*Process) = .empty,
    fdflags: std.AutoHashMapUnmanaged(i32, FdFlags) = .empty,
    dirbufs: std.AutoHashMapUnmanaged(i32, *DirBuf) = .empty,
    /// Sockets by conversation, and epoll interest lists by the #ε
    /// instance's qid (design/0050-linux-net.md).
    /// Each on the heap, so a pointer to one stays good while other
    /// threads add more.
    socks: std.AutoHashMapUnmanaged(u32, *Sock) = .empty,
    epolls: std.AutoHashMapUnmanaged(u64, *Epoll) = .empty,
    /// signalfds by the #ε instance's qid (`signalfd`).
    sigfds: std.AutoHashMapUnmanaged(u64, SigFd) = .empty,
    /// Named AF_UNIX sockets by their pipe end's qid (`unixOf`).
    usocks: std.AutoHashMapUnmanaged(u64, *USock) = .empty,
    /// pread64's read-ahead, by fd (`cachedRead`).
    rcaches: std.AutoHashMapUnmanaged(i32, *ReadCache) = .empty,
    /// How the group ends, once exit_group or a fatal signal has said:
    /// every thread dies, and the leader exits with this status.
    end: ?End = null,
    end_buf: [kern.ERRMAX]u8 = undefined,
    /// Set by a thread's execve while the others are killed: their deaths
    /// don't end the group. The tid of the thread doing it, or 0.
    execing: u32 = 0,
    /// A thread's execve for the leader to run (the process model's).
    exec_req: ?*anyopaque = null,
    /// The CPU time of the members that have ended, and of the children
    /// reaped (getrusage's RUSAGE_SELF and RUSAGE_CHILDREN).
    cpu_ended: cputime.Times = .{},
    cpu_children: cputime.Times = .{},

    pub const End = struct { msg: []const u8, killed: bool };

    pub fn lockSpin(g: *Group) void {
        while (!g.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn destroy(g: *Group) void {
        var it = g.dirbufs.valueIterator();
        while (it.next()) |b| freeDirBuf(g.gpa, b.*);
        g.dirbufs.deinit(g.gpa);
        g.fdflags.deinit(g.gpa);
        var si = g.socks.valueIterator();
        while (si.next()) |so| g.gpa.destroy(so.*);
        g.socks.deinit(g.gpa);
        var ei = g.epolls.valueIterator();
        while (ei.next()) |e| {
            e.*.entries.deinit(g.gpa);
            g.gpa.destroy(e.*);
        }
        g.epolls.deinit(g.gpa);
        g.sigfds.deinit(g.gpa);
        var ui = g.usocks.valueIterator();
        while (ui.next()) |u| g.gpa.destroy(u.*);
        g.usocks.deinit(g.gpa);
        var ri = g.rcaches.valueIterator();
        while (ri.next()) |c| g.gpa.destroy(c.*);
        g.rcaches.deinit(g.gpa);
        g.members.deinit(g.gpa);
        g.gpa.destroy(g);
    }

    /// Removes `p` from the members and drops its reference.
    fn leave(g: *Group, p: *Process) void {
        g.lockSpin();
        for (g.members.items, 0..) |q, i| if (q == p) {
            _ = g.members.orderedRemove(i);
            break;
        };
        g.lock.unlock();
        if (g.refs.fetchSub(1, .acq_rel) == 1) g.destroy();
    }

    /// The members' count.
    pub fn count(g: *Group) usize {
        g.lockSpin();
        defer g.lock.unlock();
        return g.members.items.len;
    }

    /// Starts an execve by thread `tid`, unless another is under way or
    /// the group is ending.
    pub fn beginExec(g: *Group, tid: u32) bool {
        g.lockSpin();
        defer g.lock.unlock();
        if (g.execing != 0 or g.end != null) return false;
        g.execing = tid;
        return true;
    }

    pub fn endExec(g: *Group) void {
        g.lockSpin();
        defer g.lock.unlock();
        g.execing = 0;
    }

    /// Sets how the group ends, unless it's already set or an execve is
    /// killing the other threads. Returns whether this call set it.
    pub fn setEnd(g: *Group, msg: []const u8, killed: bool) bool {
        g.lockSpin();
        defer g.lock.unlock();
        if (g.end != null or g.execing != 0) return false;
        const n = @min(msg.len, g.end_buf.len);
        @memcpy(g.end_buf[0..n], msg[0..n]);
        g.end = .{ .msg = g.end_buf[0..n], .killed = killed };
        return true;
    }

    /// The members' tids other than `self`, into `buf`.
    pub fn others(g: *Group, self: u32, buf: []u32) []u32 {
        g.lockSpin();
        defer g.lock.unlock();
        var n: usize = 0;
        for (g.members.items) |q| {
            if (q.pid == self or n == buf.len) continue;
            buf[n] = q.pid;
            n += 1;
        }
        return buf[0..n];
    }

    /// Sets conversation conv's socket state. Called with the lock held.
    fn putSock(g: *Group, conv: u32, v: Sock) std.mem.Allocator.Error!void {
        const gop = try g.socks.getOrPut(g.gpa, conv);
        if (!gop.found_existing) {
            gop.value_ptr.* = g.gpa.create(Sock) catch |e| {
                _ = g.socks.remove(conv);
                return e;
            };
        }
        gop.value_ptr.*.* = v;
    }

    /// Sets a signal's action in every member (CLONE_SIGHAND).
    fn setAction(g: *Group, signo: u32, a: sig.Action) void {
        g.lockSpin();
        defer g.lock.unlock();
        for (g.members.items) |q| q.sig.actions[signo] = a;
    }

    /// A member other than `self` that doesn't block signo, if any.
    pub fn unblocked(g: *Group, self: u32, signo: u32) ?u32 {
        g.lockSpin();
        defer g.lock.unlock();
        for (g.members.items) |q| {
            if (q.pid != self and load64(&q.sig.mask) & sig.bit(signo) == 0) return q.pid;
        }
        return null;
    }
};

pub const Process = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arch: vmm.Arch,
    pid: u32,
    mm: *mm.Mm,
    host: Host,
    sig: sig.State = .{},
    /// set_tid_address and CLONE_CHILD_CLEARTID: zeroed at exit.
    clear_tid: u64 = 0,
    pgid: u32,
    sid: u32,
    umask: u32 = 0o022,
    /// The ids the process reports and may change (`Cred`).
    cred: Cred = .{},
    /// The thread group: what the process's threads share. Set by
    /// `newGroup`, `forkChild` and `threadChild`.
    g: *Group = undefined,
    /// set_robust_list's head, walked at thread exit.
    robust_list: u64 = 0,
    /// Set by exit (not exit_group): only this thread ends.
    thread_exit: bool = false,
    /// Exits reaped by await that a wait4 for another pid passed over.
    waits: std.ArrayList(WaitRec) = .empty,
    /// The host thread's CPU time when this thread started running on it.
    cpu0: cputime.Times = .{},
    /// The guest-visible CPU features (vmm.Backend.hwcaps).
    hwcap: u64 = 0,
    hwcap2: u64 = 0,
    /// The vDSO's address, or 0.
    vdso: u64 = 0,
    ncpu: u32 = 1,
    mem_limit: u64 = 0,
    /// Whether the console is a terminal (isatty): the host's stdin and
    /// stdout both are.
    console_tty: bool = true,
    /// The exe's guest path, for /proc/self/exe.
    exe: [256]u8 = undefined,
    exe_len: usize = 0,
    trace: ?*std.Io.Writer = null,
    trace_lock: ?*std.atomic.Mutex = null,
    /// Set when the last call returned -EINTR, with what restarts it.
    restart: ?Restart = null,
    name_buf: [4096]u8 = undefined,
    name2_buf: [4096]u8 = undefined,
    msg: [kern.ERRMAX + 32]u8 = undefined,

    pub const Restart = struct { pc: u64, arg0: u64, nr: u64, always_eintr: bool = false };

    pub fn deinit(p: *Process) void {
        p.waits.deinit(p.gpa);
        p.g.leave(p);
    }

    /// Makes the process the only member of a new thread group.
    pub fn newGroup(p: *Process) std.mem.Allocator.Error!void {
        const g = try p.gpa.create(Group);
        g.* = .{ .gpa = p.gpa, .tgid = p.pid };
        g.members.append(p.gpa, p) catch |e| {
            p.gpa.destroy(g);
            return e;
        };
        p.g = g;
    }

    /// The thread group's leader: getpid's answer.
    pub fn tgid(p: *const Process) u32 {
        return p.g.tgid;
    }

    pub fn isLeader(p: *const Process) bool {
        return p.pid == p.g.tgid;
    }

    /// The state a new thread starts with (design/0049-linux-threads.md):
    /// the same memory and thread group, the creator's signal actions and
    /// mask, nothing pending.
    pub fn threadChild(p: *Process, tid: u32) Process {
        var c = p.baseCopy(tid, p.mm.get());
        c.sig = p.sig.forkCopy();
        c.sig.altstack = .{};
        @memcpy(c.exe[0..p.exe_len], p.exe[0..p.exe_len]);
        c.exe_len = p.exe_len;
        _ = p.g.refs.fetchAdd(1, .acq_rel);
        c.g = p.g;
        return c;
    }

    fn baseCopy(p: *Process, pid: u32, m: *mm.Mm) Process {
        return .{
            .gpa = p.gpa,
            .io = p.io,
            .arch = p.arch,
            .pid = pid,
            .mm = m,
            .host = p.host,
            .pgid = p.pgid,
            .sid = p.sid,
            .umask = p.umask,
            .cred = p.cred,
            .hwcap = p.hwcap,
            .hwcap2 = p.hwcap2,
            .vdso = p.vdso,
            .ncpu = p.ncpu,
            .mem_limit = p.mem_limit,
            .console_tty = p.console_tty,
            .trace = p.trace,
            .trace_lock = p.trace_lock,
        };
    }

    /// Adds a process made by `threadChild` or `forkChild`, at its final
    /// address, to its group's members. On failure it's as if `deinit`
    /// had been called.
    pub fn joinGroup(c: *Process) std.mem.Allocator.Error!void {
        const g = c.g;
        g.lockSpin();
        g.members.append(c.gpa, c) catch |e| {
            g.lock.unlock();
            c.waits.deinit(c.gpa);
            if (g.refs.fetchSub(1, .acq_rel) == 1) g.destroy();
            return e;
        };
        g.lock.unlock();
    }

    /// The state a fork child starts with: signal handlers, mask, flags
    /// and groups are inherited; pending signals and waits aren't.
    pub fn forkChild(p: *Process, pid: u32, m: *mm.Mm) std.mem.Allocator.Error!Process {
        var c = p.baseCopy(pid, m);
        c.sig = p.sig.forkCopy();
        @memcpy(c.exe[0..p.exe_len], p.exe[0..p.exe_len]);
        c.exe_len = p.exe_len;
        const g = try c.gpa.create(Group);
        g.* = .{ .gpa = c.gpa, .tgid = pid };
        errdefer g.destroy();
        const pg = p.g;
        pg.lockSpin();
        defer pg.lock.unlock();
        var it = pg.fdflags.iterator();
        while (it.next()) |e| try g.fdflags.put(c.gpa, e.key_ptr.*, e.value_ptr.*);
        var si = pg.socks.iterator();
        while (si.next()) |e| try g.putSock(e.key_ptr.*, e.value_ptr.*.*);
        // The child's interest lists start as copies; Linux shares them.
        var ei = pg.epolls.iterator();
        while (ei.next()) |e| {
            const ep = try c.gpa.create(Epoll);
            ep.* = .{ .entries = e.value_ptr.*.entries.clone(c.gpa) catch |err| {
                c.gpa.destroy(ep);
                return err;
            } };
            g.epolls.put(c.gpa, e.key_ptr.*, ep) catch |err| {
                ep.entries.deinit(c.gpa);
                c.gpa.destroy(ep);
                return err;
            };
        }
        var ufi = pg.usocks.iterator();
        while (ufi.next()) |e| {
            const u = try c.gpa.create(USock);
            u.* = e.value_ptr.*.*;
            g.usocks.put(c.gpa, e.key_ptr.*, u) catch |err| {
                c.gpa.destroy(u);
                return err;
            };
        }
        var sfi = pg.sigfds.iterator();
        while (sfi.next()) |e| try g.sigfds.put(c.gpa, e.key_ptr.*, .{ .fd = e.value_ptr.fd, .mask = e.value_ptr.mask });
        c.g = g;
        return c;
    }

    /// set_robust_list's list: struct robust_list_head is the first
    /// entry's address, the lock word's offset from an entry, and the
    /// entry being taken or released, if any.
    fn walkRobust(p: *Process) Err!void {
        const head = p.robust_list;
        const off: i64 = @bitCast(try p.readU64(head + 8));
        const pending = try p.readU64(head + 16);
        var entry = try p.readU64(head);
        var n: usize = 0;
        while (entry != head and entry != 0 and n < 2048) : (n += 1) {
            // The next one first: waking a waiter may free this one.
            const next = try p.readU64(entry);
            if (entry != pending) p.robustDied(entry +% @as(u64, @bitCast(off)));
            entry = next;
        }
        if (pending != 0) p.robustDied(pending +% @as(u64, @bitCast(off)));
    }

    fn robustDied(p: *Process, va: u64) void {
        const word = futexWord(p, va) catch return;
        var cur = @atomicLoad(u32, word, .seq_cst);
        while (cur & FUTEX_TID_MASK == p.pid) {
            const new = (cur & FUTEX_WAITERS) | FUTEX_OWNER_DIED;
            cur = @cmpxchgWeak(u32, word, cur, new, .seq_cst, .seq_cst) orelse {
                if (cur & FUTEX_WAITERS != 0) _ = kc.futexWake(p.mm, va, 1, 0xffffffff, 0, 0, null);
                return;
            };
        }
    }

    pub fn setExe(p: *Process, path: []const u8) void {
        const n = @min(path.len, p.exe.len);
        @memcpy(p.exe[0..n], path[0..n]);
        p.exe_len = n;
    }

    /// Drops per-fd state at exec, just before the kernel closes the
    /// close-on-exec fds: what closing each of those releases (an flock
    /// whose description this was the last fd of, say, which a parent
    /// that closed its own fd while the child still shared it would
    /// otherwise never see go).
    pub fn execFds(p: *Process) void {
        var fdbuf: [1024]c_int = undefined;
        for (fdbuf[0..@min(fdbuf.len, kc.fds(&fdbuf))]) |fd| {
            const info = kc.fdInfo(fd) catch continue;
            if (!info.cexec) continue;
            releaseLocks(p, fd);
            unixClosed(p, fd);
        }
        const g = p.g;
        g.lockSpin();
        defer g.lock.unlock();
        var it = g.dirbufs.iterator();
        while (it.next()) |e| freeDirBuf(p.gpa, e.value_ptr.*);
        g.dirbufs.clearRetainingCapacity();
        // Flags of fds that survive stay; closed ones are dropped as
        // their numbers are reused (see `fdClosed`).
        var dead: std.ArrayList(i32) = .empty;
        defer dead.deinit(p.gpa);
        var fi = g.fdflags.keyIterator();
        while (fi.next()) |fd| if (kc.fdInfo(fd.*)) |_| {} else |_| dead.append(p.gpa, fd.*) catch {};
        for (dead.items) |fd| _ = g.fdflags.remove(fd);
    }

    fn fdClosed(p: *Process, fd: i32) void {
        releaseLocks(p, fd);
        unixClosed(p, fd);
        const g = p.g;
        g.lockSpin();
        defer g.lock.unlock();
        _ = g.fdflags.remove(fd);
        if (g.dirbufs.fetchRemove(fd)) |e| freeDirBuf(p.gpa, e.value);
    }

    fn lockTrace(p: *Process) void {
        if (p.trace_lock) |l| while (!l.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlockTrace(p: *Process) void {
        if (p.trace_lock) |l| l.unlock();
    }

    pub fn traceLine(p: *Process, comptime fmt: []const u8, args: anytype) void {
        const w = p.trace orelse return;
        p.lockTrace();
        defer p.unlockTrace();
        w.print("{d} linux " ++ fmt ++ "\n", .{p.pid} ++ args) catch {};
        w.flush() catch {};
    }

    // Guest memory, through the VMA layer: each range is checked against
    // the VMAs and its pages allocated before the host touches it.

    pub fn readMem(p: *Process, va: u64, dst: []u8) Err!void {
        p.mm.copy(va, dst, false) catch return error.Fault;
    }

    pub fn writeMem(p: *Process, va: u64, src: []const u8) Err!void {
        // Mm.copy copies both ways from a mutable slice; it only reads it.
        p.mm.copy(va, @constCast(src), true) catch return error.Fault;
    }

    pub fn readU64(p: *Process, va: u64) Err!u64 {
        var b: [8]u8 = undefined;
        try p.readMem(va, &b);
        return std.mem.readInt(u64, &b, .little);
    }

    pub fn writeU64(p: *Process, va: u64, v: u64) Err!void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try p.writeMem(va, &b);
    }

    pub fn writeU32(p: *Process, va: u64, v: u32) Err!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try p.writeMem(va, &b);
    }

    /// A NUL-terminated string at `va`, into `buf`.
    pub fn string(p: *Process, va: u64, buf: []u8) Err![:0]u8 {
        if (va == 0) return error.Fault;
        var i: usize = 0;
        while (i < buf.len) {
            const va_at = va + i;
            const n = @min(page - va_at % page, buf.len - i);
            const s = p.mm.hostSlice(va_at, n, false) catch return error.Fault;
            if (std.mem.indexOfScalar(u8, s, 0)) |z| {
                @memcpy(buf[i..][0..z], s[0..z]);
                buf[i + z] = 0;
                return buf[0 .. i + z :0];
            }
            @memcpy(buf[i..][0..n], s);
            i += n;
        }
        return error.NameTooLong;
    }

    fn stringAlloc(p: *Process, va: u64, max: usize) Err![:0]u8 {
        var tmp: [4096]u8 = undefined;
        if (p.string(va, tmp[0..@min(tmp.len, max)])) |s| {
            return p.gpa.dupeZ(u8, s) catch error.NoMem;
        } else |e| if (e != error.NameTooLong or max <= tmp.len) return if (e == error.NameTooLong) error.TooBig else e;
        // A long one: read it into a buffer of the most it may be.
        const big = p.gpa.alloc(u8, max) catch return error.NoMem;
        defer p.gpa.free(big);
        const s = p.string(va, big) catch |e| return if (e == error.NameTooLong) error.TooBig else e;
        return p.gpa.dupeZ(u8, s) catch error.NoMem;
    }
};

pub const Err = error{ Fault, NameTooLong, TooBig, NoMem };

fn errnoOf(e: Err) i64 {
    return switch (e) {
        error.Fault => -E.FAULT,
        error.NameTooLong => -E.NAMETOOLONG,
        error.TooBig => -E.@"2BIG",
        error.NoMem => -E.NOMEM,
    };
}

/// -errno for the kernel's last error.
/// A relaxed 64-bit atomic load; a plain one on the web host, whose wasm32
/// has no 64-bit atomics and runs everything on one thread.
pub fn load64(ptr: *const u64) u64 {
    return if (@import("builtin").os.tag == .wasi) ptr.* else @atomicLoad(u64, ptr, .monotonic);
}

pub fn kerr() i64 {
    return -@as(i64, attr.errno(kern.errstr()));
}

/// The registers of a call, by the architecture's convention.
const Call = struct {
    nr: u64,
    a: [6]u64,

    fn of(u: *const vmm.Ureg) Call {
        return switch (u.*) {
            .arm64 => |r| .{ .nr = r.r[8], .a = r.r[0..6].* },
            .amd64 => |r| .{ .nr = r.ax, .a = .{ r.di, r.si, r.dx, r.r10, r.r8, r.r9 } },
            .i386 => .{ .nr = std.math.maxInt(u64), .a = @splat(0) },
        };
    }
    fn int(c: Call, i: usize) i32 {
        return @bitCast(@as(u32, @truncate(c.a[i])));
    }
    fn uint(c: Call, i: usize) u32 {
        return @truncate(c.a[i]);
    }
};

pub fn setReturn(u: *vmm.Ureg, v: u64) void {
    switch (u.*) {
        .arm64 => |*r| r.r[0] = v,
        .amd64 => |*r| r.ax = v,
        .i386 => {},
    }
}

pub fn lookup(arch: vmm.Arch, number: u64) ?Sys {
    return switch (arch) {
        .arm64 => nr.lookup(.arm64, number),
        .amd64 => nr.lookup(.amd64, number),
        .i386 => null,
    };
}

pub fn dispatch(p: *Process, u: *const vmm.Ureg) Outcome {
    const c = Call.of(u);
    p.restart = null;
    const s = lookup(p.arch, c.nr) orelse {
        p.traceLine("syscall {d} = -ENOSYS (unknown)", .{c.nr});
        return ret(-E.NOSYS);
    };
    const out = serve(p, s, c, u) catch |e| ret(errnoOf(e));
    switch (out) {
        .ret => |r| {
            const v: i64 = @bitCast(r);
            if (v == -E.INTR) p.restart = .{
                .pc = u.pc(),
                .arg0 = c.a[0],
                .nr = c.nr,
                .always_eintr = switch (s) {
                    // Linux's ERESTARTNOHAND calls: interrupted by a handler,
                    // they return EINTR even with SA_RESTART.
                    .pause, .rt_sigsuspend, .rt_sigtimedwait, .nanosleep, .clock_nanosleep, .poll, .ppoll, .select, .pselect6, .epoll_wait, .epoll_pwait => true,
                    else => false,
                },
            };
            if (p.trace != null) {
                if (v == -E.NOSYS) p.traceLine("{t}(0x{x}, 0x{x}, 0x{x}) = -ENOSYS (absent)", .{ s, c.a[0], c.a[1], c.a[2] }) else if (v < 0 and v > -4096) p.traceLine("{t}(0x{x}, 0x{x}, 0x{x}) = -{d} '{s}'", .{ s, c.a[0], c.a[1], c.a[2], -v, kern.errstr() }) else p.traceLine("{t}(0x{x}, 0x{x}, 0x{x}) = 0x{x}", .{ s, c.a[0], c.a[1], c.a[2], r });
            }
        },
        .exits => |m| p.traceLine("{t} \"{s}\"", .{ s, m }),
        else => p.traceLine("{t}(0x{x}, 0x{x}, 0x{x})", .{ s, c.a[0], c.a[1], c.a[2] }),
    }
    return out;
}

fn memCall(p: *Process, s: Sys, c: Call) Err!Outcome {
    switch (s) {
        .brk => return ret(@intCast(p.mm.setBrk(c.a[0]))),
        .mmap => return ret(try mmap(p, c.a[0], c.a[1], c.uint(2), c.uint(3), c.int(4), c.a[5])),
        .munmap => {
            const a = c.a[0];
            if (a % page != 0 or c.a[1] == 0) return ret(-E.INVAL);
            const len = std.mem.alignForward(u64, c.a[1], page);
            if (a >= mm.user_top or len > mm.user_top - a) return ret(-E.INVAL);
            p.mm.unmap(a, a + len) catch return ret(-E.NOMEM);
            return ret(0);
        },
        .mprotect => {
            const a = c.a[0];
            if (a % page != 0) return ret(-E.INVAL);
            const len = std.mem.alignForward(u64, c.a[1], page);
            if (len == 0) return ret(0);
            p.mm.protect(a, a + len, .fromLinux(c.a[2])) catch |e| return ret(if (e == error.BadAddress) -E.NOMEM else -E.NOMEM);
            return ret(0);
        },
        .madvise => {
            const MADV_DONTNEED = 4;
            const MADV_FREE = 8;
            const a = c.a[0];
            if (a % page != 0) return ret(-E.INVAL);
            // As a kernel before 4.5: callers fall back to MADV_DONTNEED,
            // and Redis skips its arm64 fork check, which reads page counts
            // from /proc/self/smaps that h9 doesn't have.
            if (c.uint(2) == MADV_FREE) return ret(-E.INVAL);
            if (c.uint(2) == MADV_DONTNEED) {
                const len = std.mem.alignForward(u64, c.a[1], page);
                p.mm.discard(a, a + len);
            }
            return ret(0);
        },
        .mremap => return ret(try mremap(p, c.a[0], c.a[1], c.a[2], c.uint(3), c.a[4])),
        .shmat => return ret(shmat(p, @truncate(c.int(0)), c.a[1], c.uint(2))),
        .shmdt => {
            const v = p.mm.find(c.a[0]) orelse return ret(-E.INVAL);
            if (v.kind != .shm or v.start != c.a[0]) return ret(-E.INVAL);
            const id: i32 = @intCast(v.offset);
            const end = v.end;
            p.mm.unmap(c.a[0], end) catch return ret(-E.INVAL);
            sysvshm.lock();
            if (sysvshm.find(p.mm.backend, id)) |sg| {
                sg.lpid = @intCast(p.tgid());
                sg.dtime = @divTrunc(kern.wallNs(), std.time.ns_per_s);
            }
            sysvshm.unlock();
            return ret(0);
        },
        else => unreachable,
    }
}

fn ret(v: i64) Outcome {
    return .{ .ret = @bitCast(v) };
}

fn okOr(r: kern.Error!void) Outcome {
    return if (r) |_| ret(0) else |_| ret(kerr());
}

const AT_FDCWD: i32 = -100;
const AT_SYMLINK_NOFOLLOW = 0x100;
const AT_REMOVEDIR = 0x200;
const AT_EMPTY_PATH = 0x1000;

// Open flags common to both architectures.
const O_ACCMODE = 3;
const O_CREAT = 0o100;
const O_EXCL = 0o200;
const O_NOCTTY = 0o400;
const O_TRUNC = 0o1000;
const O_APPEND = 0o2000;
const O_NONBLOCK = 0o4000;
const O_CLOEXEC = 0o2000000;
const O_PATH = 0o10000000;

fn oDirectory(a: vmm.Arch) u32 {
    return if (a == .arm64) 0o40000 else 0o200000;
}

/// Plan 9 open flags.
const OTRUNC = 16;
const OCEXEC = 32;
const DMDIR: u32 = 0x80000000;

fn serve(p: *Process, s: Sys, c: Call, u: *const vmm.Ureg) Err!Outcome {
    _ = u;
    switch (s) {
        // Files.
        .openat => return ret(try openAt(p, c.int(0), c.a[1], c.uint(2), c.uint(3))),
        .open => return ret(try openAt(p, AT_FDCWD, c.a[0], c.uint(1), c.uint(2))),
        .creat => return ret(try openAt(p, AT_FDCWD, c.a[0], O_CREAT | 1 | O_TRUNC, c.uint(1))),
        .close => {
            const fd = c.int(0);
            p.fdClosed(fd);
            return okOr(if (fd < 0) error.Kern else kern.close(@intCast(fd)));
        },
        .read => return ret(try rw(p, c.int(0), c.a[1], c.a[2], -1, .read)),
        .write => return ret(try rw(p, c.int(0), c.a[1], c.a[2], -1, .write)),
        .pread64 => return ret(try rw(p, c.int(0), c.a[1], c.a[2], @bitCast(c.a[3]), .read)),
        .pwrite64 => return ret(try rw(p, c.int(0), c.a[1], c.a[2], @bitCast(c.a[3]), .write)),
        .readv => return ret(try rwv(p, c.int(0), c.a[1], c.a[2], -1, .read)),
        .writev => return ret(try rwv(p, c.int(0), c.a[1], c.a[2], -1, .write)),
        .preadv => return ret(try rwv(p, c.int(0), c.a[1], c.a[2], @bitCast(c.a[3]), .read)),
        .pwritev => return ret(try rwv(p, c.int(0), c.a[1], c.a[2], @bitCast(c.a[3]), .write)),
        .sendfile => return ret(try sendfile(p, c.int(0), c.int(1), c.a[2], c.a[3])),
        .lseek => {
            const fd = c.int(0);
            if (fd < 0) return ret(-E.BADF);
            const whence = c.int(2);
            if (whence < 0 or whence > 2) return ret(-E.INVAL);
            const r = kern.seek(@intCast(fd), @bitCast(c.a[1]), whence) catch return ret(kerr());
            p.g.lockSpin();
            defer p.g.lock.unlock();
            if (p.g.dirbufs.get(fd)) |b| if (r == 0) {
                b.len = 0;
                b.off = 0;
                b.eof = false;
                b.seen.clearRetainingCapacity();
            };
            return ret(r);
        },
        .dup => {
            const fd = c.int(0);
            if (fd < 0) return ret(-E.BADF);
            const n = kern.dup(@intCast(fd), -1) catch return ret(kerr());
            kc.setCloexec(n, false) catch {};
            copyFlags(p, fd, n);
            return ret(n);
        },
        .dup2, .dup3 => {
            const fd = c.int(0);
            const to = c.int(1);
            if (fd < 0 or to < 0) return ret(-E.BADF);
            if (fd == to) {
                if (s == .dup3) return ret(-E.INVAL);
                _ = kc.fdInfo(fd) catch return ret(-E.BADF);
                return ret(fd);
            }
            p.fdClosed(to);
            const n = kern.dup(@intCast(fd), to) catch return ret(kerr());
            kc.setCloexec(n, s == .dup3 and c.uint(2) & O_CLOEXEC != 0) catch {};
            copyFlags(p, fd, n);
            return ret(n);
        },
        .fcntl => return ret(try fcntl(p, c.int(0), c.int(1), c.a[2])),
        .pipe2, .pipe => {
            const flags: u32 = if (s == .pipe2) c.uint(1) else 0;
            var b: [8]u8 = undefined;
            // Check the array before making the pipe, so a bad one leaks nothing.
            try p.writeMem(c.a[0], &b);
            const fds = kern.pipe() catch return ret(kerr());
            for (fds) |fd| {
                if (flags & O_CLOEXEC != 0) kc.setCloexec(fd, true) catch {};
                if (flags & O_NONBLOCK != 0) setFlags(p, fd, .{ .nonblock = true });
            }
            std.mem.writeInt(i32, b[0..4], fds[0], .little);
            std.mem.writeInt(i32, b[4..8], fds[1], .little);
            try p.writeMem(c.a[0], &b);
            return ret(0);
        },
        .getdents64 => return ret(try getdents(p, c.int(0), c.a[1], c.uint(2))),
        .newfstatat => return ret(try statAt(p, c.int(0), c.a[1], c.a[2], c.uint(3), .native)),
        .fstat => return ret(try statFd(p, c.int(0), c.a[1], .native)),
        .stat => return ret(try statAt(p, AT_FDCWD, c.a[0], c.a[1], 0, .native)),
        .lstat => return ret(try statAt(p, AT_FDCWD, c.a[0], c.a[1], AT_SYMLINK_NOFOLLOW, .native)),
        .statx => return ret(try statAt(p, c.int(0), c.a[1], c.a[4], c.uint(2), .statx)),
        .faccessat, .faccessat2 => return ret(try access(p, c.int(0), c.a[1], c.uint(2))),
        .access => return ret(try access(p, AT_FDCWD, c.a[0], c.uint(1))),
        .mkdirat => return ret(try mkdir(p, c.int(0), c.a[1], c.uint(2))),
        .mkdir => return ret(try mkdir(p, AT_FDCWD, c.a[0], c.uint(1))),
        .unlinkat => return ret(try unlink(p, c.int(0), c.a[1], c.uint(2))),
        .unlink => return ret(try unlink(p, AT_FDCWD, c.a[0], 0)),
        .rmdir => return ret(try unlink(p, AT_FDCWD, c.a[0], AT_REMOVEDIR)),
        .renameat => return ret(try rename(p, c.int(0), c.a[1], c.int(2), c.a[3], 0)),
        .renameat2 => return ret(try rename(p, c.int(0), c.a[1], c.int(2), c.a[3], c.uint(4))),
        .rename => return ret(try rename(p, AT_FDCWD, c.a[0], AT_FDCWD, c.a[1], 0)),
        .fchmod => return ret(try chmodFd(p, c.int(0), c.uint(1))),
        .fchmodat => return ret(try chmodAt(p, c.int(0), c.a[1], c.uint(2))),
        .chmod => return ret(try chmodAt(p, AT_FDCWD, c.a[0], c.uint(1))),
        // Linux ids mean nothing to h9's access checks, so changing the
        // owner is accepted and has no effect.
        .fchownat, .fchown, .chown, .lchown => return ret(0),
        .utimensat => return ret(try utimens(p, c.int(0), c.a[1], c.a[2])),
        .ftruncate => return ret(try truncateFd(p, c.int(0), c.a[1])),
        .fallocate => return ret(try fallocate(p, c.int(0), c.uint(1), c.a[2], c.a[3])),
        .truncate => return ret(try truncatePath(p, c.a[0], c.a[1])),
        .fsync, .fdatasync => return ret(fsync(c.int(0))),
        // A hint to start writing back: fsync does the writing here.
        .sync_file_range => return ret(if (kc.fdInfo(c.int(0))) |_| 0 else |_| -E.BADF),
        .syncfs => return ret(if (c.int(0) < 0) -E.BADF else 0),
        .sync => return ret(0),
        .getcwd => {
            const cwd = kc.getcwd(&p.name_buf) catch return ret(kerr());
            if (cwd.len + 1 > c.a[1]) return ret(-E.RANGE);
            p.name_buf[cwd.len] = 0;
            try p.writeMem(c.a[0], p.name_buf[0 .. cwd.len + 1]);
            return ret(@intCast(cwd.len + 1));
        },
        .chdir => {
            const path = try p.string(c.a[0], &p.name_buf);
            if (path.len == 0) return ret(-E.NOENT);
            return okOr(kern.chdir(path));
        },
        .fchdir => return okOr(kc.fchdir(c.int(0))),
        .readlinkat => return ret(try readlink(p, c.int(0), c.a[1], c.a[2], c.a[3])),
        .readlink => return ret(try readlink(p, AT_FDCWD, c.a[0], c.a[1], c.a[2])),
        .statfs, .fstatfs => {
            if (s == .statfs) _ = try p.string(c.a[0], &p.name_buf);
            var b: [120]u8 = @splat(0);
            std.mem.writeInt(u64, b[0..8], 0x01021994, .little); // TMPFS_MAGIC
            std.mem.writeInt(u64, b[8..16], 4096, .little); // f_bsize
            std.mem.writeInt(u64, b[16..24], 1 << 24, .little); // f_blocks
            std.mem.writeInt(u64, b[24..32], 1 << 23, .little); // f_bfree
            std.mem.writeInt(u64, b[32..40], 1 << 23, .little); // f_bavail
            std.mem.writeInt(u64, b[40..48], 1 << 20, .little); // f_files
            std.mem.writeInt(u64, b[48..56], 1 << 19, .little); // f_ffree
            std.mem.writeInt(u64, b[64..72], 255, .little); // f_namelen
            std.mem.writeInt(u64, b[72..80], 4096, .little); // f_frsize
            try p.writeMem(c.a[1], &b);
            return ret(0);
        },
        .close_range => {
            const lo = c.uint(0);
            const hi = @min(c.uint(1), @as(u32, @intCast(@max(kc.maxFd(), 0))));
            const flags = c.uint(2);
            const CLOSE_RANGE_CLOEXEC = 4;
            if (flags & ~@as(u32, CLOSE_RANGE_CLOEXEC) != 0) return ret(-E.INVAL);
            var fd = lo;
            while (fd <= hi) : (fd += 1) {
                if (flags & CLOSE_RANGE_CLOEXEC != 0) {
                    kc.setCloexec(@intCast(fd), true) catch {};
                } else {
                    p.fdClosed(@intCast(fd));
                    kern.close(@intCast(fd)) catch {};
                }
            }
            return ret(0);
        },
        .ioctl => return ret(try ioctl(p, c.int(0), c.uint(1), c.a[2])),
        .umask => {
            const old = p.umask;
            p.umask = c.uint(0) & 0o777;
            return ret(old);
        },

        // Processes.
        .exit, .exit_group => {
            // exit ends only the calling thread (design/0049-linux-threads.md).
            p.thread_exit = s == .exit;
            return .{ .exits = exitString(p, c.uint(0) & 0xff) };
        },
        .getpid => return ret(p.tgid()),
        .gettid => return ret(p.pid),
        .getppid => return ret(kc.ppid()),
        .set_tid_address => {
            p.clear_tid = c.a[0];
            return ret(p.pid);
        },
        .fork => return .{ .clone = .{ .flags = 17 } },
        .vfork => return .{ .clone = .{ .flags = CLONE_VM | CLONE_VFORK | 17 } },
        .clone => {
            // arm64 and amd64 both take flags, stack, ptid, then ctid and tls
            // in the opposite order (CLONE_BACKWARDS on arm64).
            const flags = c.a[0];
            if (cloneCheck(flags)) |e| return ret(e);
            const tls, const ctid = if (p.arch == .arm64) .{ c.a[3], c.a[4] } else .{ c.a[4], c.a[3] };
            return .{ .clone = .{ .flags = flags, .stack = c.a[1], .ptid = c.a[2], .ctid = ctid, .tls = tls } };
        },
        .clone3 => {
            // struct clone_args: flags, pidfd, child_tid, parent_tid,
            // exit_signal, stack, stack_size, tls, then set_tid and cgroup.
            if (c.a[1] < 64) return ret(-E.INVAL);
            var b: [64]u8 = undefined;
            try p.readMem(c.a[0], &b);
            const w = struct {
                fn at(bs: *const [64]u8, i: usize) u64 {
                    return std.mem.readInt(u64, bs[i * 8 ..][0..8], .little);
                }
            }.at;
            const flags = w(&b, 0) | (w(&b, 4) & 0xff);
            if (cloneCheck(flags)) |e| return ret(e);
            const stack = w(&b, 5);
            const size = w(&b, 6);
            if ((stack == 0) != (size == 0)) return ret(-E.INVAL);
            return .{ .clone = .{ .flags = flags, .stack = if (stack != 0) stack + size else 0, .ptid = w(&b, 3), .ctid = w(&b, 2), .tls = w(&b, 7) } };
        },
        .execve => return execve(p, AT_FDCWD, c.a[0], c.a[1], c.a[2], 0),
        .execveat => return execve(p, c.int(0), c.a[1], c.a[2], c.a[3], c.uint(4)),
        .wait4 => return ret(try wait4(p, c.int(0), c.a[1], c.uint(2), c.a[3])),
        .getrusage => return ret(try getrusage(p, c.int(0), c.a[1])),
        .setitimer => return ret(try setitimer(p, c.int(0), c.a[1], c.a[2])),
        .getitimer => return ret(try getitimer(p, c.int(0), c.a[1])),
        .alarm => {
            const old = itimer.set(@intFromPtr(p.g), .{ .left_ns = @as(i64, c.uint(0)) * std.time.ns_per_s }) catch return ret(-E.NOMEM);
            return ret(if (old.left_ns > 0) @divTrunc(old.left_ns + std.time.ns_per_s / 2, std.time.ns_per_s) else 0);
        },
        .waitid => return ret(try waitid(p, c.uint(0), c.uint(1), c.a[2], c.uint(3), c.a[4])),
        .kill => return ret(p.host.kill(p.host.ctx, p, c.int(0), @truncate(c.uint(1)), null)),
        .tkill => return ret(if (c.int(0) <= 0) -E.INVAL else p.host.kill(p.host.ctx, p, c.int(0), @truncate(c.uint(1)), .{})),
        .tgkill => return ret(if (c.int(0) <= 0 or c.int(1) <= 0) -E.INVAL else p.host.kill(p.host.ctx, p, c.int(1), @truncate(c.uint(2)), .{ .tgid = c.uint(0) })),
        .setsid => {
            if (p.pgid == p.pid) return ret(-E.PERM);
            p.sid = p.pid;
            p.pgid = p.pid;
            return ret(p.pid);
        },
        .getsid => return ret(if (c.int(0) == 0 or c.uint(0) == p.pid) p.sid else (p.host.pgidOf(p.host.ctx, c.uint(0)) orelse return ret(-E.SRCH))),
        .setpgid => {
            const pid = if (c.int(0) == 0) p.pid else c.uint(0);
            const pg = if (c.int(1) == 0) pid else c.uint(1);
            if (c.int(1) < 0) return ret(-E.INVAL);
            if (pid == p.pid) {
                p.pgid = pg;
                return ret(0);
            }
            // A child's group is set by the child itself as well (shells do
            // both), so the parent's call only checks it exists.
            return ret(if (p.host.pgidOf(p.host.ctx, pid) == null) -E.SRCH else 0);
        },
        .getpgid => return ret(if (c.int(0) == 0 or c.uint(0) == p.pid) p.pgid else (p.host.pgidOf(p.host.ctx, c.uint(0)) orelse return ret(-E.SRCH))),
        .getpgrp => return ret(p.pgid),

        // Memory. Other threads' layout changes wait (mm.Mm.op).
        .shmget => return ret(shmget(p, @truncate(c.int(0)), c.a[1], c.uint(2))),
        .shmctl => return ret(try shmctl(p, @truncate(c.int(0)), c.uint(1), c.a[2])),
        .brk, .mmap, .munmap, .mprotect, .madvise, .mremap, .shmat, .shmdt => {
            p.mm.opLock(p.io);
            defer p.mm.opUnlock(p.io);
            return memCall(p, s, c);
        },
        .msync, .mlock, .munlock, .mlockall, .munlockall, .mlock2 => return ret(0),

        // Signals.
        .rt_sigaction => return ret(try sigaction(p, c.a[0], c.a[1], c.a[2], c.a[3])),
        .rt_sigprocmask => return ret(try sigprocmask(p, c.uint(0), c.a[1], c.a[2], c.a[3])),
        .rt_sigreturn => return .sigreturn,
        .rt_sigpending => {
            try p.writeU64(c.a[0], p.sig.pending & p.sig.mask);
            return ret(0);
        },
        .rt_sigsuspend => {
            var b: [8]u8 = undefined;
            try p.readMem(c.a[0], &b);
            p.sig.suspend_mask = p.sig.mask;
            p.sig.mask = std.mem.readInt(u64, &b, .little) & ~sig.unblockable;
            // Wait for a note; the delivery puts the old mask back.
            while (true) {
                kern.sleep(1 << 30) catch return ret(-E.INTR);
            }
        },
        .rt_sigtimedwait => return ret(try sigtimedwait(p, c.a[0], c.a[1], c.a[2])),
        .sigaltstack => return ret(try sigaltstack(p, c.a[0], c.a[1])),
        .pause => {
            while (true) kern.sleep(1 << 30) catch return ret(-E.INTR);
        },

        // Time.
        .clock_gettime => {
            const ns = clockNs(c.uint(0)) orelse return ret(-E.INVAL);
            try writeTimespec(p, c.a[1], ns);
            return ret(0);
        },
        .clock_getres => {
            if (clockNs(c.uint(0)) == null) return ret(-E.INVAL);
            if (c.a[1] != 0) try writeTimespec(p, c.a[1], 1);
            return ret(0);
        },
        .gettimeofday => {
            if (c.a[0] != 0) {
                const ns: u64 = @intCast(kern.wallNs());
                var b: [16]u8 = undefined;
                std.mem.writeInt(u64, b[0..8], ns / std.time.ns_per_s, .little);
                std.mem.writeInt(u64, b[8..16], ns % std.time.ns_per_s / 1000, .little);
                try p.writeMem(c.a[0], &b);
            }
            return ret(0);
        },
        .time => {
            const t: u64 = @intCast(@divTrunc(kern.wallNs(), std.time.ns_per_s));
            if (c.a[0] != 0) try p.writeU64(c.a[0], t);
            return ret(@intCast(t));
        },
        .nanosleep => return ret(try nanosleep(p, c.a[0], c.a[1], false)),
        .clock_nanosleep => {
            const TIMER_ABSTIME = 1;
            if (clockNs(c.uint(0)) == null) return ret(-E.INVAL);
            return ret(try nanosleepClock(p, c.uint(0), c.uint(1) & TIMER_ABSTIME != 0, c.a[2], c.a[3]));
        },
        .times => {
            const ticks: u64 = @intCast(@divTrunc(kern.monoNs(), 10 * std.time.ns_per_ms));
            if (c.a[0] != 0) try p.writeMem(c.a[0], &@as([32]u8, @splat(0)));
            return ret(@intCast(ticks));
        },

        // Fixed answers.
        .uname => {
            var b: [6 * 65]u8 = @splat(0);
            const fields = [_][]const u8{ "Linux", nodename(), "6.1.0-h9", "#1 SMP h9", machineName(p.arch), "(none)" };
            for (fields, 0..) |f, i| @memcpy(b[i * 65 ..][0..f.len], f);
            try p.writeMem(c.a[0], &b);
            return ret(0);
        },
        .getrandom => {
            const n = @min(c.a[1], 1 << 20);
            var tmp: [256]u8 = undefined;
            var off: u64 = 0;
            while (off < n) {
                const k = @min(tmp.len, n - off);
                p.io.random(tmp[0..k]);
                try p.writeMem(c.a[0] + off, tmp[0..k]);
                off += k;
            }
            return ret(@intCast(n));
        },
        .sysinfo => {
            var b: [112]u8 = @splat(0);
            const up_s: u64 = @intCast(@divTrunc(kern.monoNs(), std.time.ns_per_s));
            std.mem.writeInt(u64, b[0..8], up_s, .little);
            std.mem.writeInt(u64, b[32..40], p.mem_limit, .little); // totalram
            std.mem.writeInt(u64, b[40..48], p.mem_limit -| p.mm.bytes(), .little); // freeram
            std.mem.writeInt(u16, b[80..82], 1, .little); // procs
            std.mem.writeInt(u32, b[104..108], 1, .little); // mem_unit
            try p.writeMem(c.a[0], &b);
            return ret(0);
        },
        .getuid => return ret(p.cred.uid[0]),
        .geteuid => return ret(p.cred.uid[1]),
        .getgid => return ret(p.cred.gid[0]),
        .getegid => return ret(p.cred.gid[1]),
        .getresuid, .getresgid => {
            const ids = if (s == .getresuid) p.cred.uid else p.cred.gid;
            for (0..3) |i| try p.writeU32(c.a[i], ids[i]);
            return ret(0);
        },
        .getgroups => {
            const n = p.cred.ngroups;
            if (c.int(0) == 0) return ret(n);
            if (c.int(0) < n) return ret(-E.INVAL);
            for (p.cred.groups[0..n], 0..) |gid, i| try p.writeU32(c.a[1] + 4 * i, gid);
            return ret(n);
        },
        .setuid => return ret(p.cred.setOne(&p.cred.uid, c.int(0))),
        .setgid => return ret(p.cred.setOne(&p.cred.gid, c.int(0))),
        // The fs ids follow the effective ones; these return the old one.
        .setfsuid => return ret(p.cred.uid[1]),
        .setfsgid => return ret(p.cred.gid[1]),
        .setreuid => return ret(p.cred.setRe(&p.cred.uid, c.int(0), c.int(1))),
        .setregid => return ret(p.cred.setRe(&p.cred.gid, c.int(0), c.int(1))),
        .setresuid => return ret(p.cred.setRes(&p.cred.uid, c.int(0), c.int(1), c.int(2))),
        .setresgid => return ret(p.cred.setRes(&p.cred.gid, c.int(0), c.int(1), c.int(2))),
        .setgroups => {
            if (!p.cred.root()) return ret(-E.PERM);
            if (c.a[0] > p.cred.groups.len) return ret(-E.INVAL);
            const n: u8 = @intCast(c.a[0]);
            var raw: [32 * 4]u8 = undefined;
            try p.readMem(c.a[1], raw[0 .. 4 * @as(usize, n)]);
            for (0..n) |i| p.cred.groups[i] = std.mem.readInt(u32, raw[4 * i ..][0..4], .little);
            p.cred.ngroups = n;
            return ret(0);
        },
        .prctl => return ret(try prctl(p, c.int(0), c.a[1])),
        .arch_prctl => return ret(-E.INVAL), // ARCH_SET_FS is served by the process model
        .prlimit64 => return ret(try prlimit(p, c.int(0), c.uint(1), c.a[2], c.a[3])),
        .getrlimit => return ret(try prlimit(p, 0, c.uint(0), 0, c.a[1])),
        .setrlimit => return ret(0),
        .sched_getaffinity => {
            if (c.a[1] < 8) return ret(-E.INVAL);
            const n = @min(p.ncpu, 64);
            const mask: u64 = if (n >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
            try p.writeU64(c.a[2], mask);
            return ret(8);
        },
        .sched_setaffinity, .sched_yield, .setpriority, .sched_setscheduler, .sched_setparam => return ret(0),
        .getpriority => return ret(20),
        .sched_getscheduler => return ret(0),
        .getcpu => {
            if (c.a[0] != 0) try p.writeU32(c.a[0], 0);
            if (c.a[1] != 0) try p.writeU32(c.a[1], 0);
            return ret(0);
        },
        .membarrier => return ret(if (c.int(0) == 0) 0 else -E.INVAL),
        .rseq => return ret(-E.NOSYS),
        .set_robust_list => {
            if (c.a[1] != 24) return ret(-E.INVAL);
            p.robust_list = c.a[0];
            return ret(0);
        },
        .get_robust_list => {
            if (c.int(0) != 0 and c.uint(0) != p.pid) return ret(-E.PERM);
            try p.writeU64(c.a[1], p.robust_list);
            try p.writeU64(c.a[2], 24);
            return ret(0);
        },
        .futex => return ret(try futex(p, c.a[0], c.uint(1), c.uint(2), c.a[3], c.a[4], c.uint(5))),
        .chroot, .mount, .umount2, .pivot_root, .unshare, .setns => return ret(-E.PERM),
        .linkat => return ret(try link(p, c.int(0), c.a[1], c.int(2), c.a[3], c.uint(4))),
        .link => return ret(try link(p, AT_FDCWD, c.a[0], AT_FDCWD, c.a[1], 0)),
        .symlinkat => return ret(try symlink(p, c.a[0], c.int(1), c.a[2])),
        .symlink => return ret(try symlink(p, c.a[0], AT_FDCWD, c.a[1])),
        .flock => return ret(try flockCall(p, c.int(0), c.uint(1))),
        .fadvise64 => return ret(0),
        .getxattr, .lgetxattr, .fgetxattr, .listxattr, .llistxattr, .flistxattr, .setxattr, .lsetxattr, .fsetxattr, .removexattr, .lremovexattr, .fremovexattr => return ret(-E.NOTSUP),
        .personality => return ret(if (c.uint(0) == 0xffffffff or c.uint(0) == 0) 0 else -E.INVAL),
        .ptrace, .bpf, .perf_event_open => return ret(-E.PERM),
        .seccomp => return ret(-E.INVAL),
        .io_uring_setup => return ret(-E.NOSYS),
        // Readiness and sockets (design/0050-linux-net.md).
        .ppoll, .poll => return ret(try pollCall(p, s, c)),
        .pselect6, .select => return ret(try selectCall(p, s, c)),
        .socket => return ret(try socketCall(p, c.uint(0), c.uint(1), c.uint(2))),
        .socketpair => return ret(try socketpair(p, c.uint(0), c.uint(1), c.a[3])),
        .connect => return ret(try connectCall(p, c.int(0), c.a[1], c.a[2])),
        .bind => return ret(try bindCall(p, c.int(0), c.a[1], c.a[2])),
        .listen => return ret(try listenCall(p, c.int(0))),
        .accept => return ret(try acceptCall(p, c.int(0), c.a[1], c.a[2], 0)),
        .accept4 => return ret(try acceptCall(p, c.int(0), c.a[1], c.a[2], c.uint(3))),
        .getsockname => return ret(try sockName(p, c.int(0), c.a[1], c.a[2], false)),
        .getpeername => return ret(try sockName(p, c.int(0), c.a[1], c.a[2], true)),
        .shutdown => return ret(try shutdownCall(p, c.int(0), c.uint(1))),
        .setsockopt => return ret(try setsockopt(p, c.int(0), c.uint(1), c.uint(2), c.a[3], c.a[4])),
        .getsockopt => return ret(try getsockopt(p, c.int(0), c.uint(1), c.uint(2), c.a[3], c.a[4])),
        .sendto => return ret(try sendCall(p, c.int(0), c.a[1], c.a[2], c.uint(3), c.a[4], c.a[5])),
        .recvfrom => return ret(try recvCall(p, c.int(0), c.a[1], c.a[2], c.uint(3), c.a[4], c.a[5])),
        .sendmsg => return ret(try sendmsg(p, c.int(0), c.a[1], c.uint(2))),
        .recvmsg => return ret(try recvmsg(p, c.int(0), c.a[1], c.uint(2))),
        .signalfd => return ret(try signalfd(p, c.int(0), c.a[1], c.a[2], 0)),
        .signalfd4 => return ret(try signalfd(p, c.int(0), c.a[1], c.a[2], c.uint(3))),
        .eventfd => return ret(try eventfd(p, c.uint(0), 0)),
        .eventfd2 => return ret(try eventfd(p, c.uint(0), c.uint(1))),
        .epoll_create => return ret(if (c.int(0) <= 0) -E.INVAL else try epollCreate(p, 0)),
        .epoll_create1 => return ret(try epollCreate(p, c.uint(0))),
        .epoll_ctl => return ret(try epollCtl(p, c.int(0), c.uint(1), c.int(2), c.a[3])),
        .epoll_wait => return ret(try epollWait(p, c.int(0), c.a[1], c.int(2), c.int(3), 0)),
        .epoll_pwait => return ret(try epollWait(p, c.int(0), c.a[1], c.int(2), c.int(3), c.a[4])),
        else => return ret(-E.NOSYS),
    }
}

// Files.

fn pathArg(p: *Process, va: u64, buf: []u8) Err![:0]u8 {
    return p.string(va, buf);
}

/// Runs `f(path)` with relative paths walked from dirfd's directory.
fn at(dirfd: i32, path: [:0]const u8, comptime T: type, f: anytype, args: anytype) kern.Error!T {
    if (dirfd == AT_FDCWD or (path.len > 0 and path[0] == '/')) return @call(.auto, f, args);
    return kc.atDir(dirfd, T, f, args);
}

fn setFlags(p: *Process, fd: i32, f: FdFlags) void {
    p.g.lockSpin();
    defer p.g.lock.unlock();
    p.g.fdflags.put(p.gpa, fd, f) catch {};
}

fn flagsOf(p: *Process, fd: i32) FdFlags {
    p.g.lockSpin();
    defer p.g.lock.unlock();
    return p.g.fdflags.get(fd) orelse .{};
}

fn copyFlags(p: *Process, from: i32, to: i32) void {
    p.g.lockSpin();
    defer p.g.lock.unlock();
    if (p.g.fdflags.get(from)) |f| p.g.fdflags.put(p.gpa, to, f) catch {} else _ = p.g.fdflags.remove(to);
}

fn openAt(p: *Process, dirfd: i32, path_va: u64, flags: u32, mode: u32) Err!i64 {
    const path = try pathArg(p, path_va, &p.name_buf);
    if (path.len == 0) return -E.NOENT;
    var omode: c_int = switch (flags & O_ACCMODE) {
        0 => kern.OREAD,
        1 => kern.OWRITE,
        else => kern.ORDWR,
    };
    if (flags & O_PATH != 0) omode = kern.OREAD;
    if (flags & O_TRUNC != 0 and flags & O_ACCMODE != 0) omode |= OTRUNC;
    if (flags & O_CLOEXEC != 0) omode |= OCEXEC;
    const want_dir = flags & oDirectory(p.arch) != 0;
    const fd: u31 = blk: {
        if (at(dirfd, path, u31, kern.open, .{ path, omode })) |fd| {
            if (flags & O_CREAT != 0 and flags & O_EXCL != 0) {
                kern.close(fd) catch {};
                return -E.EXIST;
            }
            break :blk fd;
        } else |_| {
            const e = kerr();
            if (flags & O_CREAT == 0 or e != -E.NOENT) {
                // A directory opened for writing is EISDIR.
                if (e == -E.ACCES or e == -E.PERM) if (flags & O_ACCMODE != 0) if (isDir(p, dirfd, path)) return -E.ISDIR;
                return e;
            }
            const perm = mode & 0o777 & ~p.umask;
            break :blk at(dirfd, path, u31, kern.create, .{ path, omode & ~@as(c_int, OTRUNC), perm }) catch return kerr();
        }
    };
    if (want_dir or flags & O_ACCMODE != 0) {
        const info = kc.fdInfo(fd) catch {
            kern.close(fd) catch {};
            return -E.BADF;
        };
        if (want_dir and !info.dir) {
            kern.close(fd) catch {};
            return -E.NOTDIR;
        }
    }
    p.fdClosed(fd);
    if (flags & (O_APPEND | O_NONBLOCK | O_PATH) != 0) setFlags(p, fd, .{
        .append = flags & O_APPEND != 0,
        .nonblock = flags & O_NONBLOCK != 0,
        .path = flags & O_PATH != 0,
    });
    return fd;
}

fn isDir(p: *Process, dirfd: i32, path: [:0]const u8) bool {
    var b: [512]u8 = undefined;
    const n = at(dirfd, path, usize, kern.stat, .{ path, &b }) catch return false;
    _ = p;
    const d, _ = attr.Dir.parse(b[0..n]) orelse return false;
    return d.mode & DMDIR != 0;
}

const Dir = enum { read, write };

fn rw(p: *Process, fd: i32, buf: u64, len_in: u64, off: i64, comptime dir: Dir) Err!i64 {
    if (fd < 0) return -E.BADF;
    const len = @min(len_in, 0x7ffff000);
    p.mm.touch(buf, len, dir == .read) catch return -E.FAULT;
    // O_NONBLOCK, and reads and writes on sockets that a signal can
    // interrupt (design/0050-linux-net.md): ask first, for the devices
    // that can block. A file is always ready.
    var is_pipe = false;
    if (off == -1) if (kc.fdInfo(fd) catch null) |info| {
        if (dir == .read and info.dc == ev_dc) {
            if (sigfdOf(p, info.qpath) != null) return sigfdRead(p, fd, info.qpath, buf, len);
        }
        // A Unix socket's fd is a pipe end only once it's connected.
        if (info.dc == '|') if (unixOf(p, fd)) |u| {
            if (u.state != .connected) return -E.NOTCONN;
            // A netlink write is a request (busybox ip writes them).
            if (dir == .write and u.netlink) {
                const tmp = p.gpa.alloc(u8, @min(len, 1 << 16)) catch return -E.NOMEM;
                defer p.gpa.free(tmp);
                try p.readMem(buf, tmp);
                return netlinkSend(p, fd, tmp);
            }
        };
        // A Plan 9 pipe keeps write boundaries, so an empty write would
        // reach the reader as an end of file. On Linux it does nothing.
        if (dir == .write and len == 0 and info.dc == '|') return 0;
    };
    if (off == -1 and len > 0) if (kc.fdInfo(fd) catch null) |info| switch (info.dc) {
        '|', 'I', 'y', ev_dc => {
            const want: u32 = if (dir == .read) kc.POLLIN else kc.POLLOUT;
            is_pipe = info.dc == '|' and !info.dir;
            const vmin0 = if (dir == .read and info.dc == 'y') consoleReadWait(p) else null;
            if (vmin0) |ms| {
                // VMIN 0: no input within VTIME is a read of 0 bytes.
                if (ms == 0) {
                    const r = kc.fdReady(fd, want) orelse return -E.BADF;
                    if (r & (want | kc.POLLHUP | kc.POLLERR) == 0) return 0;
                } else {
                    var pf = [1]kc.PollFd{.{ .fd = fd, .events = @intCast(want), .revents = 0 }};
                    const n = kc.poll(&pf, ms, null) catch return -E.INTR;
                    if (n == 0) return 0;
                }
            } else if (flagsOf(p, fd).nonblock) {
                const r = kc.fdReady(fd, want) orelse return -E.BADF;
                if (r & (want | kc.POLLHUP | kc.POLLERR) == 0) return -E.AGAIN;
            } else if (info.dc == 'I' and !info.dir and info.qpath & 0xf == ip_qdata) {
                const w = waitReady(fd, want);
                if (w < 0) return w;
            }
        },
        else => {},
    };
    if (dir == .write and off == -1 and flagsOf(p, fd).append) _ = kern.seek(@intCast(fd), 0, 2) catch {};
    if (len == 0) {
        // A real address: `&.{}` isn't one, and a host file's write(2)
        // can fail an empty write with EFAULT for it (Go's os.WriteFile
        // of nothing, which `go mod download` makes).
        var none: [1]u8 = undefined;
        const n = switch (dir) {
            .read => kern.pread(@intCast(fd), none[0..0], off),
            .write => kern.pwrite(@intCast(fd), none[0..0], off),
        } catch return kerr();
        return @intCast(n);
    }
    const file = if (is_pipe) null else fileKey(fd);
    if (dir == .read and off >= 0 and len <= read_cache_max) if (file) |k| {
        if (cachedRead(p, fd, k, buf, len, @intCast(off))) |r| return r;
    };
    if (gm.contiguous(p.mm.as, buf, len)) |s| {
        if (dir == .write and is_pipe) return pipeWrite(p, fd, s);
        const n = switch (dir) {
            .read => kern.pread(@intCast(fd), s, off),
            .write => kern.pwrite(@intCast(fd), s, off),
        } catch return kerr();
        if (dir == .read and is_pipe) return @intCast(pipeMore(fd, s, n));
        if (file) |k| fileIo(fd, k, off, s[0..n], dir);
        return @intCast(n);
    }
    // One kernel call, through a bounce buffer, as message boundaries on
    // pipes and directory reads need.
    const tmp = p.gpa.alloc(u8, len) catch return -E.NOMEM;
    defer p.gpa.free(tmp);
    switch (dir) {
        .read => {
            var n = kern.pread(@intCast(fd), tmp, off) catch return kerr();
            if (is_pipe) n = pipeMore(fd, tmp, n);
            if (file) |k| fileIo(fd, k, off, tmp[0..n], .read);
            p.mm.copy(buf, tmp[0..n], true) catch return -E.FAULT;
            return @intCast(n);
        },
        .write => {
            p.mm.copy(buf, tmp, false) catch return -E.FAULT;
            if (is_pipe) return pipeWrite(p, fd, tmp);
            const n = kern.pwrite(@intCast(fd), tmp, off) catch return kerr();
            if (file) |k| fileIo(fd, k, off, tmp[0..n], .write);
            return @intCast(n);
        },
    }
}

/// A write to a pipe, as Linux counts it. A Plan 9 pipe queues a block
/// of up to 64 KB and only then waits for room (qbwrite), so a note
/// that interrupts the wait, such as Go's SIGURG preemption, fails a
/// write whose data is already in the pipe, and a program that retries
/// on EINTR writes it twice. Here each block is written on its own, and
/// one that's interrupted counts as written: Linux returns the bytes
/// written so far, and EINTR only when there were none, and there
/// always are. A message socket's write stays one kernel write, to keep
/// its boundary.
fn pipeWrite(p: *Process, fd: i32, s: []const u8) i64 {
    const atomic = 64 << 10;
    const msg = if (unixOf(p, fd)) |u| u.stype != SOCK_STREAM else false;
    var done: usize = 0;
    while (done < s.len) {
        const chunk = s[done..if (msg) s.len else @min(s.len, done + atomic)];
        const n = kern.pwrite(@intCast(fd), chunk, -1) catch {
            if (std.mem.eql(u8, kern.errstr(), "interrupted")) return @intCast(done + chunk.len);
            return if (done > 0) @intCast(done) else kerr();
        };
        done += n;
        if (msg or n < chunk.len) break;
    }
    return @intCast(done);
}

/// Bumped by every write and truncate through the Linux layer, which
/// invalidates every read cache (`cachedRead`).
var file_writes: @import("../web.zig").Atomic(u64) = .init(0);

/// A regular file's lock and mapping key, or null for anything else.
fn fileKey(fd: i32) ?locks.Key {
    const info = kc.fdInfo(fd) catch return null;
    if (info.dir) return null;
    return switch (info.dc) {
        'U', 'M', 'O' => lockKey(info),
        else => null,
    };
}

/// After a read or write of `data` on a file: shared mappings of it see
/// the write, or are what the read returns (shmfile.zig).
fn fileIo(fd: i32, key: locks.Key, off: i64, data: []u8, dir: Dir) void {
    if (dir == .write) _ = file_writes.fetchAdd(1, .monotonic);
    if (data.len == 0 or !shmfile.mapped(key)) return;
    const pos: u64 = if (off >= 0) @intCast(off) else blk: {
        const cur = kern.seek(@intCast(fd), 0, 1) catch return;
        break :blk @intCast(@max(cur - @as(i64, @intCast(data.len)), 0));
    };
    switch (dir) {
        .read => shmfile.read(key, pos, data),
        .write => shmfile.wrote(key, pos, data),
    }
}

/// pread64s this small read ahead, through a per-fd cache: a database
/// reading page by page (SQLite) makes one kernel read per `read_cache`
/// bytes instead of one per page.
const read_cache_max = 16 << 10;
const read_cache = 128 << 10;
/// How long cached bytes are trusted with nothing in the Linux layer
/// changing (a write, a truncate, a lock taken or dropped): writers it
/// doesn't see, 9front programs or the host, show within this.
const read_cache_ns = std.time.ns_per_s;

pub const ReadCache = struct {
    mu: std.Io.Mutex,
    key: locks.Key = undefined,
    /// file_writes and the lock table's generation when filled.
    writes: u64,
    locks: u64,
    filled_ns: i64,
    off: u64,
    len: usize,
    /// The read stopped short: the file ends at off+len.
    eof: bool,
    buf: [read_cache]u8,
};

/// Serves a pread64 from fd's read cache, filling it if it doesn't hold
/// [off, off+len). Null to read the usual way. A cache stays with its fd
/// number for the group's life: one opened on another file there fails
/// the key check.
fn cachedRead(p: *Process, fd: i32, key: locks.Key, buf: u64, len: u64, off: u64) ?i64 {
    if (shmfile.mapped(key)) return null;
    const g = p.g;
    g.lockSpin();
    const rc = g.rcaches.get(fd) orelse blk: {
        const c = p.gpa.create(ReadCache) catch {
            g.lock.unlock();
            return null;
        };
        c.mu = .init;
        c.len = 0;
        g.rcaches.put(p.gpa, fd, c) catch {
            p.gpa.destroy(c);
            g.lock.unlock();
            return null;
        };
        break :blk c;
    };
    g.lock.unlock();
    rc.mu.lockUncancelable(p.io);
    defer rc.mu.unlock(p.io);
    const writes = file_writes.load(.monotonic);
    const lgen = locks.gen();
    const now = kern.monoNs();
    const fresh = rc.len > 0 and std.meta.eql(rc.key, key) and rc.writes == writes and rc.locks == lgen and now - rc.filled_ns < read_cache_ns;
    if (!(fresh and off >= rc.off and (off + len <= rc.off + rc.len or (rc.eof and off <= rc.off + rc.len)))) {
        // Refill from the page holding off.
        const base = off - off % 4096;
        rc.len = 0;
        const n = kern.pread(@intCast(fd), &rc.buf, @intCast(base)) catch return null;
        rc.key = key;
        rc.writes = writes;
        rc.locks = lgen;
        rc.filled_ns = now;
        rc.off = base;
        rc.len = n;
        rc.eof = n < rc.buf.len;
        if (off >= base + n) return 0;
    }
    const lo: usize = @intCast(off - rc.off);
    const n: usize = @intCast(@min(len, rc.len - lo));
    p.mm.copy(buf, rc.buf[lo..][0..n], true) catch return -E.FAULT;
    return @intCast(n);
}

/// A Linux pipe read takes everything queued, where a 9front one stops
/// at a write's boundary: read on while more is queued and there's room.
fn pipeMore(fd: i32, buf: []u8, n_in: usize) usize {
    var n = n_in;
    while (n > 0 and n < buf.len) {
        const r = kc.fdReady(fd, kc.POLLIN) orelse break;
        if (r & kc.POLLIN == 0 or r & kc.POLLHUP != 0) break;
        const m = kern.pread(@intCast(fd), buf[n..], -1) catch break;
        if (m == 0) break;
        n += m;
    }
    return n;
}

fn rwv(p: *Process, fd: i32, iov: u64, cnt: u64, off_in: i64, comptime dir: Dir) Err!i64 {
    if (cnt > 1024) return -E.INVAL;
    var total: i64 = 0;
    var off = off_in;
    // A read goes on to the next buffer only from a file: from a pipe,
    // the console or a socket it would wait for more after filling one,
    // and Linux's readv returns what's there. Zig's test runner reads its
    // 8-byte request into the first of two buffers, and waited forever.
    var stream: ?bool = null;
    var i: u64 = 0;
    while (i < cnt) : (i += 1) {
        const base = try p.readU64(iov + 16 * i);
        const len = try p.readU64(iov + 16 * i + 8);
        if (len == 0) continue;
        if (dir == .read and total > 0) {
            if (stream == null) stream = if (kc.fdInfo(fd)) |info| switch (info.dc) {
                'U', 'O', 'M' => false,
                else => true,
            } else |_| true;
            if (stream.?) break;
        }
        const n = try rw(p, fd, base, len, off, dir);
        if (n < 0) return if (total > 0) total else n;
        total += n;
        if (off != -1) off += n;
        if (@as(u64, @intCast(n)) < len) break;
    }
    return total;
}

fn sendfile(p: *Process, out: i32, in: i32, offp: u64, count: u64) Err!i64 {
    if (out < 0 or in < 0) return -E.BADF;
    var off: i64 = -1;
    if (offp != 0) off = @bitCast(try p.readU64(offp));
    var buf: [65536]u8 = undefined;
    var total: u64 = 0;
    while (total < count) {
        const want = @min(buf.len, count - total);
        const n = kern.pread(@intCast(in), buf[0..want], off) catch return if (total > 0) @intCast(total) else kerr();
        if (n == 0) break;
        const w = kern.pwrite(@intCast(out), buf[0..n], -1) catch return if (total > 0) @intCast(total) else kerr();
        total += w;
        if (off != -1) off += @intCast(n);
        if (w < n) break;
    }
    if (offp != 0) try p.writeU64(offp, @bitCast(off));
    return @intCast(total);
}

fn fcntl(p: *Process, fd: i32, cmd: i32, arg: u64) Err!i64 {
    if (fd < 0) return -E.BADF;
    const F_DUPFD = 0;
    const F_GETFD = 1;
    const F_SETFD = 2;
    const F_GETFL = 3;
    const F_SETFL = 4;
    const F_GETLK = 5;
    const F_SETLK = 6;
    const F_SETLKW = 7;
    const F_DUPFD_CLOEXEC = 1030;
    const F_OFD_GETLK = 36;
    const F_OFD_SETLK = 37;
    const F_OFD_SETLKW = 38;
    switch (cmd) {
        F_DUPFD, F_DUPFD_CLOEXEC => {
            _ = kc.fdInfo(fd) catch return -E.BADF;
            var n: i32 = @intCast(@min(arg & 0xffffffff, 1 << 20));
            while (kc.fdInfo(n)) |_| n += 1 else |_| {}
            const r = kern.dup(@intCast(fd), n) catch return kerr();
            kc.setCloexec(r, cmd == F_DUPFD_CLOEXEC) catch {};
            copyFlags(p, fd, r);
            return r;
        },
        F_GETFD => {
            const info = kc.fdInfo(fd) catch return -E.BADF;
            return @intFromBool(info.cexec);
        },
        F_SETFD => {
            kc.setCloexec(fd, arg & 1 != 0) catch return -E.BADF;
            return 0;
        },
        F_GETFL => {
            const info = kc.fdInfo(fd) catch return -E.BADF;
            const f = flagsOf(p, fd);
            var r: i64 = switch (info.mode) {
                0, 3 => 0,
                1 => 1,
                2 => 2,
            };
            if (f.append) r |= O_APPEND;
            if (f.nonblock) r |= O_NONBLOCK;
            if (f.path) r |= O_PATH;
            return r;
        },
        F_SETFL => {
            _ = kc.fdInfo(fd) catch return -E.BADF;
            var f = flagsOf(p, fd);
            f.append = arg & O_APPEND != 0;
            f.nonblock = arg & O_NONBLOCK != 0;
            setFlags(p, fd, f);
            return 0;
        },
        F_SETLK, F_SETLKW, F_OFD_SETLK, F_OFD_SETLKW, F_GETLK, F_OFD_GETLK => {
            const ofd = cmd == F_OFD_SETLK or cmd == F_OFD_SETLKW or cmd == F_OFD_GETLK;
            return recordLock(p, fd, arg, ofd, cmd == F_GETLK or cmd == F_OFD_GETLK, cmd == F_SETLKW or cmd == F_OFD_SETLKW);
        },
        else => return -E.INVAL,
    }
}

/// A file's identity in the lock table.
fn lockKey(info: kc.FdInfo) locks.Key {
    return .{ .dc = info.dc, .dev = info.dev, .qpath = info.qpath };
}

/// This process's POSIX lock owner: its tgid within its machine.
fn posixOwner(p: *Process) locks.Owner {
    const m: u64 = @intFromPtr(p.host.ctx);
    return .{ .id = m *% 0x9e3779b97f4a7c15 ^ p.g.tgid, .posix = true, .pid = @intCast(p.g.tgid) };
}

/// fcntl's record locks (locks.zig), from a struct flock: l_type and
/// l_whence (shorts), then l_start, l_len (64-bit) and l_pid.
fn recordLock(p: *Process, fd: i32, arg: u64, ofd: bool, get: bool, wait: bool) Err!i64 {
    const info = kc.fdInfo(fd) catch return -E.BADF;
    var b: [32]u8 = undefined;
    try p.readMem(arg, &b);
    const t = std.enums.fromInt(locks.Type, std.mem.readInt(u16, b[0..2], .little)) orelse return -E.INVAL;
    const whence = std.mem.readInt(u16, b[2..4], .little);
    const l_start = std.mem.readInt(i64, b[8..16], .little);
    const l_len = std.mem.readInt(i64, b[16..24], .little);
    // OFD locks need l_pid 0.
    if (ofd and std.mem.readInt(i32, b[24..28], .little) != 0) return -E.INVAL;
    const base: i64 = switch (whence) {
        0 => 0,
        1 => kern.seek(@intCast(fd), 0, 1) catch return kerr(),
        2 => blk: {
            var st: [512]u8 = undefined;
            _ = kern.fstat(@intCast(fd), &st) catch return kerr();
            break :blk @intCast(std.mem.readInt(u64, st[33..41], .little));
        },
        else => return -E.INVAL,
    };
    // l_len < 0 locks the bytes before l_start; 0 locks to the end.
    var lo = std.math.add(i64, base, l_start) catch return -E.OVERFLOW;
    var hi: i64 = std.math.maxInt(i64);
    if (l_len > 0) {
        hi = std.math.add(i64, lo, l_len) catch std.math.maxInt(i64);
    } else if (l_len < 0) {
        hi = lo;
        lo = std.math.add(i64, lo, l_len) catch return -E.INVAL;
    }
    if (lo < 0) return -E.INVAL;
    const start: u64 = @intCast(lo);
    const end: u64 = if (l_len == 0) std.math.maxInt(u64) else @intCast(hi);
    const owner: locks.Owner = if (ofd) blk: {
        const ch = kc.fdChan(fd) orelse return -E.BADF;
        break :blk .{ .id = ch.id, .posix = false, .pid = -1 };
    } else posixOwner(p);
    const key = lockKey(info);
    if (get) {
        if (t == .unlock) return -E.INVAL;
        const r = locks.conflicting(key, .{ .owner = owner, .type = t, .start = start, .end = end });
        var out: [32]u8 = b;
        if (r) |c| {
            std.mem.writeInt(u16, out[0..2], @intFromEnum(c.type), .little);
            std.mem.writeInt(u16, out[2..4], 0, .little);
            std.mem.writeInt(i64, out[8..16], @intCast(c.start), .little);
            std.mem.writeInt(i64, out[16..24], if (c.end == std.math.maxInt(u64)) 0 else @intCast(c.end - c.start), .little);
            std.mem.writeInt(i32, out[24..28], c.owner.pid, .little);
        } else std.mem.writeInt(u16, out[0..2], @intFromEnum(locks.Type.unlock), .little);
        try p.writeMem(arg, &out);
        return 0;
    }
    if (t == .read and info.mode == kern.OWRITE) return -E.BADF;
    if (t == .write and info.mode != kern.OWRITE and info.mode != kern.ORDWR) return -E.BADF;
    while (true) {
        locks.set(key, owner, t, start, end) catch |e| switch (e) {
            error.OutOfMemory => return -E.NOLCK,
            error.WouldBlock => {
                if (!wait) return -E.AGAIN;
                // No wait queue: poll, and let a signal end the wait.
                if (p.sig.deliverable()) return -E.INTR;
                kern.sleep(2) catch return -E.INTR;
                continue;
            },
        };
        return 0;
    }
}

/// flock(2): LOCK_SH 1, LOCK_EX 2, LOCK_UN 8, with LOCK_NB 4.
fn flockCall(p: *Process, fd: i32, op: u32) Err!i64 {
    const info = kc.fdInfo(fd) catch return -E.BADF;
    const ch = kc.fdChan(fd) orelse return -E.BADF;
    const t: locks.Type = switch (op & ~@as(u32, 4)) {
        1 => .read,
        2 => .write,
        8 => .unlock,
        else => return -E.INVAL,
    };
    while (true) {
        locks.flock(lockKey(info), ch.id, t) catch |e| switch (e) {
            error.OutOfMemory => return -E.NOLCK,
            error.WouldBlock => {
                if (op & 4 != 0) return -E.AGAIN;
                if (p.sig.deliverable()) return -E.INTR;
                kern.sleep(2) catch return -E.INTR;
                continue;
            },
        };
        return 0;
    }
}

/// Before fd closes: its POSIX locks on the file go (any close does
/// that), and its OFD and flock locks if this is the description's last
/// fd.
fn releaseLocks(p: *Process, fd: i32) void {
    if (fd < 0) return;
    const info = kc.fdInfo(fd) catch return;
    if (info.dir) return;
    const key = lockKey(info);
    locks.closedPosix(key, posixOwner(p).id);
    if (kc.fdChan(fd)) |ch| if (ch.refs <= 1) locks.closedOfd(key, ch.id);
}

/// At the group's end, before the kernel closes its fds: what closing
/// each would release.
pub fn releaseAllLocks(p: *Process) void {
    var buf: [1024]c_int = undefined;
    for (buf[0..@min(buf.len, kc.fds(&buf))]) |fd| releaseLocks(p, fd);
    locks.endedPosix(posixOwner(p).id);
    itimer.cancel(@intFromPtr(p.g));
    for (buf[0..@min(buf.len, kc.fds(&buf))]) |fd| unixClosed(p, fd);
}

fn getdents(p: *Process, fd: i32, buf: u64, count: u32) Err!i64 {
    if (fd < 0) return -E.BADF;
    const info = kc.fdInfo(fd) catch return -E.BADF;
    if (!info.dir) return -E.NOTDIR;
    p.g.lockSpin();
    const db = p.g.dirbufs.get(fd) orelse blk: {
        const b = p.gpa.create(DirBuf) catch {
            p.g.lock.unlock();
            return -E.NOMEM;
        };
        b.* = .{};
        p.g.dirbufs.put(p.gpa, fd, b) catch {
            p.g.lock.unlock();
            p.gpa.destroy(b);
            return -E.NOMEM;
        };
        break :blk b;
    };
    p.g.lock.unlock();
    var out: [8192]u8 = undefined;
    const cap = @min(out.len, count);
    var n: usize = 0;
    while (true) {
        if (db.off >= db.len) {
            if (db.eof) break;
            db.off = 0;
            db.len = kern.pread(@intCast(fd), &db.buf, -1) catch {
                if (n > 0) break;
                return kerr();
            };
            if (db.len == 0) {
                db.eof = true;
                break;
            }
        }
        const d, const size = attr.Dir.parse(db.buf[db.off..db.len]) orelse {
            db.off = db.len;
            continue;
        };
        const reclen = std.mem.alignForward(usize, 19 + d.name.len + 1, 8);
        if (n + reclen > cap) {
            if (n == 0) return -E.INVAL;
            break;
        }
        const h = std.hash.Wyhash.hash(0, d.name);
        if (db.seen.contains(h)) {
            db.off += size;
            continue;
        }
        db.seen.put(p.gpa, h, {}) catch {};
        const e = out[n..][0..reclen];
        @memset(e, 0);
        std.mem.writeInt(u64, e[0..8], if (d.qid_path == 0) 1 else d.qid_path, .little);
        std.mem.writeInt(u64, e[8..16], 0, .little); // d_off: positions aren't seekable
        std.mem.writeInt(u16, e[16..18], @intCast(reclen), .little);
        e[18] = attr.dtype(&d, kindOfDir(&d));
        @memcpy(e[19..][0..d.name.len], d.name);
        n += reclen;
        db.off += size;
    }
    if (n > 0) try p.writeMem(buf, out[0..n]);
    return @intCast(n);
}

/// A file's kind from its Dir: devices under /dev are character devices,
/// pipes are FIFOs (Plan 9 has no file types to say so).
fn kindOfDir(d: *const attr.Dir) attr.Kind {
    return switch (d.type) {
        '|' => .fifo,
        'c', 'y' => .chr,
        // A conversation's data file is a socket's (design/0050-linux-net.md).
        'I' => if (d.qid_type & 0x80 == 0 and d.qid_path & 0xf == ip_qdata) .sock else .auto,
        else => if (d.type == devlinux_dc and d.qid_type & 0x80 == 0 and d.qid_path & devlinux_chr_bit != 0) .chr else .auto,
    };
}

/// devlinux's device character and the qid bit it sets on its devices
/// (src/kern/devlinux.c).
pub const devlinux_dc: u16 = 0x3bb; // 'λ'
pub const devlinux_chr_bit: u64 = 1 << 40;

const StatFmt = enum { native, statx };

fn putStat(p: *Process, buf: u64, st_in: *const attr.Stat, fmt: StatFmt) Err!void {
    // Every file is the caller's (`Cred`).
    var st = st_in.*;
    st.uid = p.cred.uid[1];
    st.gid = p.cred.gid[1];
    switch (fmt) {
        .statx => try p.writeMem(buf, &st.statx()),
        .native => switch (p.arch) {
            .amd64 => try p.writeMem(buf, &st.x86()),
            else => try p.writeMem(buf, &st.generic()),
        },
    }
}

fn statFd(p: *Process, fd: i32, buf: u64, fmt: StatFmt) Err!i64 {
    if (fd < 0) return -E.BADF;
    var b: [1024]u8 = undefined;
    const n = kern.fstat(@intCast(fd), &b) catch return kerr();
    const d, _ = attr.Dir.parse(b[0..n]) orelse return -E.IO;
    var st = attr.Stat.fromDir(&d, kindOfDir(&d), 0, 0);
    // A pipe end's Dir is its directory's in some kernels; trust the fd.
    if (kc.fdInfo(fd)) |info| {
        if (info.dc == '|' and !info.dir) st = attr.Stat.fromDir(&d, .fifo, 0, 0);
    } else |_| {}
    try putStat(p, buf, &st, fmt);
    return 0;
}

fn statAt(p: *Process, dirfd: i32, path_va: u64, buf: u64, flags: u32, fmt: StatFmt) Err!i64 {
    const path = try pathArg(p, path_va, &p.name_buf);
    if (path.len == 0) {
        if (flags & AT_EMPTY_PATH != 0) return statFd(p, if (dirfd == AT_FDCWD) -1 else dirfd, buf, fmt);
        return -E.NOENT;
    }
    if (flags & AT_SYMLINK_NOFOLLOW != 0) {
        if (at(dirfd, path, []u8, kern.readlink, .{ path, &p.name2_buf })) |target| {
            var b: [1024]u8 = undefined;
            // The link's own Dir, for its qid and times.
            const parent = at(dirfd, path, usize, kern.stat, .{ path, &b }) catch 0;
            var st: attr.Stat = .{ .dev = 0, .ino = 0, .mode = attr.S_IFLNK | 0o777, .nlink = 1, .uid = 0, .gid = 0, .size = target.len, .atime = 0, .mtime = 0 };
            if (parent > 0) if (attr.Dir.parse(b[0..parent])) |r| {
                st.dev = attr.devNumber(&r[0]);
                st.ino = r[0].qid_path ^ 0x8000000000000000;
                st.mtime = r[0].mtime;
                st.atime = r[0].atime;
            };
            try putStat(p, buf, &st, fmt);
            return 0;
        } else |_| {}
    }
    var b: [1024]u8 = undefined;
    const n = at(dirfd, path, usize, kern.stat, .{ path, &b }) catch return kerr();
    const d, _ = attr.Dir.parse(b[0..n]) orelse return -E.IO;
    const st = attr.Stat.fromDir(&d, kindOfDir(&d), 0, 0);
    try putStat(p, buf, &st, fmt);
    return 0;
}

fn access(p: *Process, dirfd: i32, path_va: u64, mode: u32) Err!i64 {
    const path = try pathArg(p, path_va, &p.name_buf);
    if (path.len == 0) return -E.NOENT;
    var b: [1024]u8 = undefined;
    const n = at(dirfd, path, usize, kern.stat, .{ path, &b }) catch return kerr();
    const d, _ = attr.Dir.parse(b[0..n]) orelse return -E.IO;
    // uid 0 may read and write anything the namespace lets it; execute
    // needs an execute bit, as for root.
    if (mode & 1 != 0 and d.mode & DMDIR == 0 and d.mode & 0o111 == 0) return -E.ACCES;
    return 0;
}

fn mkdir(p: *Process, dirfd: i32, path_va: u64, mode: u32) Err!i64 {
    const path = try pathArg(p, path_va, &p.name_buf);
    if (path.len == 0) return -E.NOENT;
    if (isDir(p, dirfd, path)) return -E.EXIST;
    const perm = DMDIR | (mode & 0o777 & ~p.umask);
    const fd = at(dirfd, path, u31, kern.create, .{ path, kern.OREAD, perm }) catch return kerr();
    kern.close(fd) catch {};
    return 0;
}

fn unlink(p: *Process, dirfd: i32, path_va: u64, flags: u32) Err!i64 {
    const path = try pathArg(p, path_va, &p.name_buf);
    if (path.len == 0) return -E.NOENT;
    // A link is removed itself, whatever it points at.
    const is_link = if (at(dirfd, path, []u8, kern.readlink, .{ path, &p.name2_buf })) |_| true else |_| false;
    const dir = !is_link and isDir(p, dirfd, path);
    if (flags & AT_REMOVEDIR != 0 and !dir) return if (is_link) -E.NOTDIR else (if (statExists(dirfd, path)) -E.NOTDIR else -E.NOENT);
    if (flags & AT_REMOVEDIR == 0 and dir) return -E.ISDIR;
    at(dirfd, path, void, kern.remove, .{path}) catch return kerr();
    return 0;
}

fn statExists(dirfd: i32, path: [:0]const u8) bool {
    var b: [512]u8 = undefined;
    _ = at(dirfd, path, usize, kern.stat, .{ path, &b }) catch return false;
    return true;
}

/// fsync and fdatasync: a wstat that changes nothing, which a host file
/// system serves with the host's fsync (src/kern/devfs-*.c). Devices that
/// don't keep data, and 9P servers that refuse it, have nothing to sync.
fn fsync(fd: i32) i64 {
    if (fd < 0) return -E.BADF;
    const info = kc.fdInfo(fd) catch return -E.BADF;
    if (info.dir) return 0;
    var b: [64]u8 = undefined;
    _ = kern.fwstat(@intCast(fd), (Wstat{}).encode(&b)) catch {
        // devfs raises the host's error; anything else means no sync.
        return if (info.dc == 'U') -E.IO else 0;
    };
    return 0;
}

/// A Plan 9 wstat message that changes nothing (nulldir), with the given
/// fields set.
const Wstat = struct {
    mode: ?u32 = null,
    atime: ?u32 = null,
    mtime: ?u32 = null,
    length: ?u64 = null,
    name: ?[]const u8 = null,

    fn encode(w: Wstat, buf: []u8) []u8 {
        const name = w.name orelse "";
        const size: usize = 41 + 8 + name.len;
        std.mem.writeInt(u16, buf[0..2], @intCast(size - 2), .little);
        @memset(buf[2..41], 0xff);
        std.mem.writeInt(u32, buf[21..25], w.mode orelse 0xffffffff, .little);
        std.mem.writeInt(u32, buf[25..29], w.atime orelse 0xffffffff, .little);
        std.mem.writeInt(u32, buf[29..33], w.mtime orelse 0xffffffff, .little);
        std.mem.writeInt(u64, buf[33..41], w.length orelse 0xffffffffffffffff, .little);
        std.mem.writeInt(u16, buf[41..43], @intCast(name.len), .little);
        @memcpy(buf[43..][0..name.len], name);
        @memset(buf[43 + name.len ..][0..6], 0);
        return buf[0..size];
    }
};

fn rename(p: *Process, olddir: i32, old_va: u64, newdir: i32, new_va: u64, flags: u32) Err!i64 {
    const RENAME_NOREPLACE = 1;
    if (flags & ~@as(u32, RENAME_NOREPLACE) != 0) return -E.INVAL;
    const old = try pathArg(p, old_va, &p.name_buf);
    const new = try pathArg(p, new_va, &p.name2_buf);
    if (old.len == 0 or new.len == 0) return -E.NOENT;
    // Plan 9 renames within a directory only (wstat of the name). A move
    // between directories is the host's rename when both are in host
    // trees, which replaces the target atomically, as Redis's AOF and
    // other databases need, and a move in memory when both are in one
    // overlay, as Zig's cache needs (its entries are made in tmp/ and
    // renamed into place). Anywhere else, and for a directory still in an
    // overlay's lower tree, it's EXDEV, and mv copies instead.
    const od = dirname(old);
    const nd = dirname(new);
    if (!std.mem.eql(u8, od, nd) or olddir != newdir) {
        const old_abs = old[0] == '/';
        var new_abs = new[0] == '/';
        // Both names must resolve from one place: a relative new name in
        // another directory (Zig's cache renames from its tmp/ fd into
        // o/'s) is joined to that directory's path.
        var newbuf: [4096]u8 = undefined;
        var new_full = new;
        if (!new_abs and newdir != olddir) {
            var db: [4096]u8 = undefined;
            const d = if (newdir == AT_FDCWD) kc.getcwd(&db) catch return kerr() else blk: {
                kern.fd2path(@intCast(@max(newdir, 0)), &db) catch return -E.BADF;
                break :blk std.mem.sliceTo(&db, 0);
            };
            new_full = std.fmt.bufPrintZ(&newbuf, "{s}/{s}", .{ d, new }) catch return -E.NAMETOOLONG;
            new_abs = true;
        }
        const base: i32 = if (old_abs and new_abs) AT_FDCWD else if (!old_abs and new_abs) olddir else if (olddir == newdir) olddir else return -E.XDEV;
        if (!statExists(olddir, old)) return -E.NOENT;
        if (flags & RENAME_NOREPLACE != 0 and statExists(newdir, new_full)) return -E.EXIST;
        if (statExists(newdir, new_full)) {
            const new_dir = isDir(p, newdir, new_full);
            const old_dir = isDir(p, olddir, old);
            if (new_dir and !old_dir) return -E.ISDIR;
            if (!new_dir and old_dir) return -E.NOTDIR;
        }
        const moved = at(base, old, bool, kern.renameAcross, .{ old, new_full }) catch return kerr();
        return if (moved) 0 else -E.XDEV;
    }
    if (!statExists(olddir, old)) return -E.NOENT;
    if (std.mem.eql(u8, old, new)) return 0;
    if (statExists(newdir, new)) {
        if (flags & RENAME_NOREPLACE != 0) return -E.EXIST;
        const new_dir = isDir(p, newdir, new);
        const old_dir = isDir(p, olddir, old);
        if (new_dir and !old_dir) return -E.ISDIR;
        if (!new_dir and old_dir) return -E.NOTDIR;
        at(newdir, new, void, kern.remove, .{new}) catch return kerr();
    }
    var b: [600]u8 = undefined;
    const base = basename(new);
    if (base.len > 512) return -E.NAMETOOLONG;
    const msg = (Wstat{ .name = base }).encode(&b);
    _ = at(olddir, old, usize, kern.wstat, .{ old, msg }) catch return kerr();
    return 0;
}

/// 9P has no hard links, so a link to a regular file is a copy, made
/// with an exclusive create: the "create if absent" that programs use
/// `link` for (object_store's put-if-not-exists, lock files) holds, but
/// the two names don't share later writes.
fn link(p: *Process, olddir: i32, old_va: u64, newdir: i32, new_va: u64, flags: u32) Err!i64 {
    const AT_SYMLINK_FOLLOW = 0x400;
    if (flags & ~@as(u32, AT_SYMLINK_FOLLOW) != 0) return -E.INVAL;
    const old = try pathArg(p, old_va, &p.name_buf);
    const new = try pathArg(p, new_va, &p.name2_buf);
    if (old.len == 0 or new.len == 0) return -E.NOENT;
    var sb: [512]u8 = undefined;
    const sn = at(olddir, old, usize, kern.stat, .{ old, &sb }) catch return kerr();
    const d, _ = attr.Dir.parse(sb[0..sn]) orelse return -E.IO;
    if (d.mode & DMDIR != 0) return -E.PERM;
    if (statExists(newdir, new)) return -E.EXIST;
    const in = at(olddir, old, u31, kern.open, .{ old, kern.OREAD }) catch return kerr();
    defer kern.close(in) catch {};
    const OEXCL = 0x1000;
    const out = at(newdir, new, u31, kern.create, .{ new, kern.OWRITE | OEXCL, d.mode & 0o777 }) catch {
        return if (statExists(newdir, new)) -E.EXIST else kerr();
    };
    var buf: [16 << 10]u8 = undefined;
    var off: i64 = 0;
    const ok = while (true) {
        const n = kern.pread(in, &buf, off) catch break false;
        if (n == 0) break true;
        var w: usize = 0;
        while (w < n) w += kern.pwrite(out, buf[w..n], off + @as(i64, @intCast(w))) catch break;
        if (w < n) break false;
        off += @intCast(n);
    };
    kern.close(out) catch {};
    if (!ok) {
        const e = kerr();
        at(newdir, new, void, kern.remove, .{new}) catch {};
        return e;
    }
    return 0;
}

/// A link in an overlay is kept in memory; in a host tree it's a host
/// symlink, the new name checked like a create (design/0018-linux-personality.md).
fn symlink(p: *Process, target_va: u64, newdir: i32, new_va: u64) Err!i64 {
    const target = try pathArg(p, target_va, &p.name2_buf);
    if (target.len == 0) return -E.NOENT;
    var nb: [4096]u8 = undefined;
    const new = try pathArg(p, new_va, &nb);
    if (new.len == 0) return -E.NOENT;
    if (statExists(newdir, new)) return -E.EXIST;
    var lb: [16]u8 = undefined;
    if (at(newdir, new, []u8, kern.readlink, .{ new, &lb })) |_| return -E.EXIST else |_| {}
    at(newdir, new, void, kern.symlink, .{ new, target }) catch return kerr();
    return 0;
}

fn dirname(path: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, path, "/");
    const i = std.mem.lastIndexOfScalar(u8, t, '/') orelse return ".";
    return if (i == 0) "/" else t[0..i];
}

fn basename(path: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, path, "/");
    const i = std.mem.lastIndexOfScalar(u8, t, '/') orelse return t;
    return t[i + 1 ..];
}

fn chmodFd(p: *Process, fd: i32, mode: u32) Err!i64 {
    _ = p;
    if (fd < 0) return -E.BADF;
    var b: [1024]u8 = undefined;
    const n = kern.fstat(@intCast(fd), &b) catch return kerr();
    const d, _ = attr.Dir.parse(b[0..n]) orelse return -E.IO;
    var w: [64]u8 = undefined;
    _ = kern.fwstat(@intCast(fd), (Wstat{ .mode = (d.mode & ~@as(u32, 0o777)) | (mode & 0o777) }).encode(&w)) catch return kerr();
    return 0;
}

fn chmodAt(p: *Process, dirfd: i32, path_va: u64, mode: u32) Err!i64 {
    const path = try pathArg(p, path_va, &p.name_buf);
    if (path.len == 0) return -E.NOENT;
    var b: [1024]u8 = undefined;
    const n = at(dirfd, path, usize, kern.stat, .{ path, &b }) catch return kerr();
    const d, _ = attr.Dir.parse(b[0..n]) orelse return -E.IO;
    var w: [64]u8 = undefined;
    _ = at(dirfd, path, usize, kern.wstat, .{ path, (Wstat{ .mode = (d.mode & ~@as(u32, 0o777)) | (mode & 0o777) }).encode(&w) }) catch return kerr();
    return 0;
}

fn utimens(p: *Process, dirfd: i32, path_va: u64, times: u64) Err!i64 {
    const UTIME_NOW = (1 << 30) - 1;
    const UTIME_OMIT = (1 << 30) - 2;
    const now: u32 = @intCast(@divTrunc(kern.wallNs(), std.time.ns_per_s));
    var ws: Wstat = .{ .atime = now, .mtime = now };
    if (times != 0) {
        var b: [32]u8 = undefined;
        try p.readMem(times, &b);
        const fields = [2]*?u32{ &ws.atime, &ws.mtime };
        for (fields, 0..) |f, i| {
            const sec = std.mem.readInt(i64, b[i * 16 ..][0..8], .little);
            const nsec = std.mem.readInt(i64, b[i * 16 + 8 ..][0..8], .little);
            f.* = if (nsec == UTIME_OMIT) null else if (nsec == UTIME_NOW) now else @intCast(std.math.clamp(sec, 0, std.math.maxInt(u32) - 1));
        }
    }
    var w: [64]u8 = undefined;
    const msg = ws.encode(&w);
    if (path_va == 0) {
        if (dirfd < 0) return -E.BADF;
        _ = kern.fwstat(@intCast(dirfd), msg) catch return kerr();
        return 0;
    }
    const path = try pathArg(p, path_va, &p.name_buf);
    if (path.len == 0) {
        if (dirfd < 0) return -E.NOENT;
        _ = kern.fwstat(@intCast(dirfd), msg) catch return kerr();
        return 0;
    }
    _ = at(dirfd, path, usize, kern.wstat, .{ path, msg }) catch return kerr();
    return 0;
}

fn truncateFd(p: *Process, fd: i32, len: u64) Err!i64 {
    _ = p;
    if (fd < 0) return -E.BADF;
    var w: [64]u8 = undefined;
    _ = kern.fwstat(@intCast(fd), (Wstat{ .length = len }).encode(&w)) catch return kerr();
    _ = file_writes.fetchAdd(1, .monotonic);
    if (fileKey(fd)) |k| shmfile.truncated(k, len);
    return 0;
}

/// fallocate: mode 0 grows the file to cover [off, off+len), as a
/// truncate up does (the host may leave it sparse); KEEP_SIZE has
/// nothing to do. Punching and zeroing holes are EOPNOTSUPP, which
/// PostgreSQL and others take as "write zeros instead".
fn fallocate(p: *Process, fd: i32, mode: u32, off: u64, len: u64) Err!i64 {
    const FALLOC_FL_KEEP_SIZE = 1;
    if (fd < 0) return -E.BADF;
    const info = kc.fdInfo(fd) catch return -E.BADF;
    if (@as(i64, @bitCast(off)) < 0 or @as(i64, @bitCast(len)) <= 0) return -E.INVAL;
    if (mode & ~@as(u32, FALLOC_FL_KEEP_SIZE) != 0) return -E.OPNOTSUPP;
    if (info.dir) return -E.ISDIR;
    if (info.mode == kern.OREAD) return -E.BADF;
    if (mode & FALLOC_FL_KEEP_SIZE != 0) return 0;
    var st: [512]u8 = undefined;
    _ = kern.fstat(@intCast(fd), &st) catch return kerr();
    const size = std.mem.readInt(u64, st[33..41], .little);
    if (off + len <= size) return 0;
    return truncateFd(p, fd, off + len);
}

fn truncatePath(p: *Process, path_va: u64, len: u64) Err!i64 {
    const path = try pathArg(p, path_va, &p.name_buf);
    var w: [64]u8 = undefined;
    _ = kern.wstat(path, (Wstat{ .length = len }).encode(&w)) catch return kerr();
    _ = file_writes.fetchAdd(1, .monotonic);
    return 0;
}

fn readlink(p: *Process, dirfd: i32, path_va: u64, buf: u64, len: u64) Err!i64 {
    const path = try pathArg(p, path_va, &p.name_buf);
    if (path.len == 0) return -E.NOENT;
    if (@as(i64, @bitCast(len)) <= 0) return -E.INVAL;
    // /proc's links are served here: devlinux has no links of its own.
    if (procLink(p, path)) |target| {
        const n = @min(target.len, len);
        try p.writeMem(buf, target[0..n]);
        return @intCast(n);
    }
    const target = at(dirfd, path, []u8, kern.readlink, .{ path, &p.name2_buf }) catch {
        // EINVAL for a file that isn't a link; ENOENT if it's missing.
        return if (statExists(dirfd, path)) -E.INVAL else kerr();
    };
    const n = @min(target.len, len);
    try p.writeMem(buf, target[0..n]);
    return @intCast(n);
}

/// The target of a /proc link: /proc/self/exe, /proc/self/cwd and
/// /proc/self/fd/N for the calling process.
fn procLink(p: *Process, path: []const u8) ?[]const u8 {
    const self_prefixes = [_][]const u8{ "/proc/self/", "/proc/thread-self/" };
    var rest: ?[]const u8 = null;
    for (self_prefixes) |pre| if (std.mem.startsWith(u8, path, pre)) {
        rest = path[pre.len..];
    };
    if (rest == null and std.mem.startsWith(u8, path, "/proc/")) {
        const r = path["/proc/".len..];
        const slash = std.mem.indexOfScalar(u8, r, '/') orelse return null;
        const pid = std.fmt.parseInt(u32, r[0..slash], 10) catch return null;
        if (pid != p.pid) return null;
        rest = r[slash + 1 ..];
    }
    const r = rest orelse return null;
    if (std.mem.eql(u8, r, "exe")) return p.exe[0..p.exe_len];
    if (std.mem.eql(u8, r, "cwd")) return kc.getcwd(&p.name2_buf) catch null;
    if (std.mem.startsWith(u8, r, "fd/")) {
        const fd = std.fmt.parseInt(i32, r[3..], 10) catch return null;
        if (fd < 0) return null;
        const info = kc.fdInfo(fd) catch return null;
        if (info.dc == '|') return std.fmt.bufPrint(&p.name2_buf, "pipe:[{d}]", .{info.qpath}) catch null;
        kern.fd2path(@intCast(fd), &p.name2_buf) catch return null;
        return std.mem.sliceTo(&p.name2_buf, 0);
    }
    return null;
}

// Terminal.

const TCGETS = 0x5401;
const TCSETS = 0x5402;
const TCSETSW = 0x5403;
const TCSETSF = 0x5404;
const TIOCGPGRP = 0x540f;
const TIOCSPGRP = 0x5410;
const TIOCGWINSZ = 0x5413;
const TIOCSWINSZ = 0x5414;
const FIONREAD = 0x541b;
const FIONBIO = 0x5421;
const FIOCLEX = 0x5451;
const FIONCLEX = 0x5450;
const TIOCSCTTY = 0x540e;
const TIOCGSID = 0x5429;

const ICANON = 0o2;
const ECHO = 0o10;
const VTIME = 5;
const VMIN = 6;

/// How long a read on the console waits for input when the termios is
/// non-canonical with VMIN 0, in ms (VTIME's tenths of a second; 0 is a
/// poll, as btop's input loop needs), or null for an ordinary read.
fn consoleReadWait(p: *const Process) ?i32 {
    if (!p.console_tty) return null;
    const t = &console_term.bytes;
    const lflag = std.mem.readInt(u32, t[12..16], .little);
    if (lflag & ICANON != 0 or t[17 + VMIN] != 0) return null;
    return @as(i32, t[17 + VTIME]) * 100;
}

fn isConsole(fd: i32) bool {
    const info = kc.fdInfo(fd) catch return false;
    return info.dc == 'y' or (info.dc == 'c' and !info.dir);
}

fn ioctl(p: *Process, fd: i32, req: u32, arg: u64) Err!i64 {
    if (fd < 0) return -E.BADF;
    switch (req) {
        FIOCLEX, FIONCLEX => {
            kc.setCloexec(fd, req == FIOCLEX) catch return -E.BADF;
            return 0;
        },
        FIONBIO => {
            var b: [4]u8 = undefined;
            try p.readMem(arg, &b);
            var f = flagsOf(p, fd);
            f.nonblock = std.mem.readInt(u32, &b, .little) != 0;
            setFlags(p, fd, f);
            return 0;
        },
        FIONREAD => {
            _ = kc.fdInfo(fd) catch return -E.BADF;
            try p.writeU32(arg, 0);
            return 0;
        },
        else => {},
    }
    _ = kc.fdInfo(fd) catch return -E.BADF;
    if (!isConsole(fd) or !p.console_tty) return -E.NOTTY;
    const con = &console_term;
    switch (req) {
        TCGETS => {
            // The kernel's struct termios is 36 bytes. C libraries keep a
            // larger one, but Go's is 44, so more would clobber its stack.
            try p.writeMem(arg, con.bytes[0..36]);
            return 0;
        },
        TCSETS, TCSETSW, TCSETSF => {
            var b: [60]u8 = undefined;
            try p.readMem(arg, b[0..36]);
            @memcpy(con.bytes[0..36], b[0..36]);
            // The host terminal follows ICANON, ECHO and ICRNL: off,
            // ICANON is raw mode, ECHO alone keeps the line discipline,
            // for password prompts (`read -s`, Go's term.ReadPassword),
            // and ICRNL off in raw mode passes Enter as CR, which fzf
            // and readline-style editors tell from Ctrl-J.
            const iflag = std.mem.readInt(u32, con.bytes[0..4], .little);
            const lflag = std.mem.readInt(u32, con.bytes[12..16], .little);
            const ICRNL = 0o400;
            const info = kc.fdInfo(fd) catch return -E.BADF;
            if (info.dc == 'y') kern.setConsoleMode(info.dev, lflag & ICANON == 0, lflag & ECHO != 0, iflag & ICRNL != 0);
            return 0;
        },
        TIOCGWINSZ => {
            // The host terminal's size, or 80x24 if it can't say.
            const info = kc.fdInfo(fd) catch return -E.BADF;
            const rc: [2]u16 = (if (info.dc == 'y') kern.consoleSize(info.dev) else null) orelse .{ 24, 80 };
            var b: [8]u8 = @splat(0);
            std.mem.writeInt(u16, b[0..2], rc[0], .little);
            std.mem.writeInt(u16, b[2..4], rc[1], .little);
            try p.writeMem(arg, &b);
            return 0;
        },
        TIOCSWINSZ, TIOCSCTTY => return 0,
        TIOCGPGRP => {
            try p.writeU32(arg, if (con.fg != 0) con.fg else p.pgid);
            return 0;
        },
        TIOCSPGRP => {
            var b: [4]u8 = undefined;
            try p.readMem(arg, &b);
            con.fg = std.mem.readInt(u32, &b, .little);
            return 0;
        },
        TIOCGSID => {
            try p.writeU32(arg, p.sid);
            return 0;
        },
        else => return -E.NOTTY,
    }
}

/// The console's termios and foreground group. One machine's console at a
/// time uses it today; the termios is kept here rather than per machine.
pub const Termios = struct {
    bytes: [60]u8,
    fg: u32 = 0,
};

pub var console_term: Termios = .{ .bytes = defaultTermios() };

fn defaultTermios() [60]u8 {
    var b: [60]u8 = @splat(0);
    // c_iflag ICRNL|IXON, c_oflag OPOST|ONLCR, c_cflag CS8|CREAD|B38400,
    // c_lflag ISIG|ICANON|ECHO|ECHOE|ECHOK|IEXTEN|ECHOCTL|ECHOKE.
    std.mem.writeInt(u32, b[0..4], 0o400 | 0o2000, .little);
    std.mem.writeInt(u32, b[4..8], 0o1 | 0o4, .little);
    std.mem.writeInt(u32, b[8..12], 0o60 | 0o200 | 0o17, .little);
    std.mem.writeInt(u32, b[12..16], 0o1 | 0o2 | 0o10 | 0o20 | 0o40 | 0o100000 | 0o1000 | 0o4000, .little);
    // c_cc from offset 17: VINTR ^C, VQUIT ^\, VERASE DEL, VKILL ^U, VEOF ^D,
    // VTIME 0, VMIN 1, VSTART ^Q, VSTOP ^S, VSUSP ^Z.
    const cc = [_]u8{ 3, 0x1c, 0x7f, 0x15, 4, 0, 1, 0, 0x11, 0x13, 0x1a };
    @memcpy(b[17..][0..cc.len], &cc);
    return b;
}

// Processes.

/// The exits string for a Linux exit status: "" for 0, else the number
/// in decimal, as APE's _exit writes it.
/// -errno for clone flags h9 doesn't serve, or null. Threads need
/// CLONE_THREAD, CLONE_SIGHAND and CLONE_VM together, as Linux does; memory
/// is shared only with threads and vfork (design/0049-linux-threads.md).
fn cloneCheck(flags: u64) ?i64 {
    if (flags & CLONE_NEW_ANY != 0) return -E.PERM;
    if (flags & CLONE_THREAD != 0 and flags & CLONE_SIGHAND == 0) return -E.INVAL;
    if (flags & CLONE_SIGHAND != 0 and flags & CLONE_VM == 0) return -E.INVAL;
    if (flags & CLONE_VM != 0 and flags & (CLONE_VFORK | CLONE_THREAD) == 0) return -E.NOSYS;
    return null;
}

fn exitString(p: *Process, code: u32) []const u8 {
    if (code == 0) return "";
    return std.fmt.bufPrint(&p.msg, "{d}", .{code}) catch "1";
}

fn execve(p: *Process, dirfd: i32, path_va: u64, argv_va: u64, envp_va: u64, flags: u32) Err!Outcome {
    _ = flags;
    const raw = try pathArg(p, path_va, &p.name_buf);
    if (raw.len == 0) return ret(-E.NOENT);
    // A relative path with a dirfd: its directory's path, joined.
    var pathbuf: [4096]u8 = undefined;
    const path: []const u8 = if (dirfd != AT_FDCWD and raw[0] != '/') blk: {
        kern.fd2path(@intCast(@max(dirfd, 0)), &pathbuf) catch return ret(-E.BADF);
        const d = std.mem.sliceTo(&pathbuf, 0);
        break :blk std.fmt.bufPrint(&p.name2_buf, "{s}/{s}", .{ d, raw }) catch return ret(-E.NAMETOOLONG);
    } else raw;
    const owned = p.gpa.dupeZ(u8, path) catch return error.NoMem;
    errdefer p.gpa.free(owned);
    const argv = try strings(p, argv_va);
    errdefer freeStrings(p.gpa, argv);
    const envp = try strings(p, envp_va);
    return .{ .exec = .{ .path = owned, .argv = argv, .envp = envp } };
}

fn strings(p: *Process, va: u64) Err![][:0]u8 {
    var list: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (list.items) |s| p.gpa.free(s);
        list.deinit(p.gpa);
    }
    if (va == 0) return list.toOwnedSlice(p.gpa) catch error.NoMem;
    var total: usize = 0;
    var i: u64 = 0;
    while (true) : (i += 1) {
        const ptr = try p.readU64(va + 8 * i);
        if (ptr == 0) break;
        const s = try p.stringAlloc(ptr, 128 << 10);
        total += s.len + 1;
        list.append(p.gpa, s) catch {
            p.gpa.free(s);
            return error.NoMem;
        };
        if (total > 2 << 20 or list.items.len > 1 << 16) return error.TooBig;
    }
    return list.toOwnedSlice(p.gpa) catch error.NoMem;
}

fn freeStrings(gpa: std.mem.Allocator, s: [][:0]u8) void {
    for (s) |x| gpa.free(x);
    gpa.free(s);
}

const WNOHANG = 1;
const WUNTRACED = 2;

/// The Linux wait status for a Plan 9 exit string (design/0018,
/// "Processes"): "" is 0, a decimal number is that exit code, "linux:
/// signal N" is killed by N, a fault is killed by SIGSEGV, and anything
/// else is exit status 1.
pub fn waitStatus(msg: []const u8) u32 {
    if (msg.len == 0) return 0;
    if (std.fmt.parseInt(u32, msg, 10)) |n| return (n & 0xff) << 8 else |_| {}
    // 9front's wait message prefixes the exits string with "name pid: ".
    var m = msg;
    if (std.mem.indexOf(u8, m, ": ")) |i| {
        const head = m[0..i];
        if (std.mem.lastIndexOfScalar(u8, head, ' ')) |sp| {
            if (std.fmt.parseInt(u32, head[sp + 1 ..], 10)) |_| m = m[i + 2 ..] else |_| {}
        }
    }
    if (std.fmt.parseInt(u32, m, 10)) |n| return (n & 0xff) << 8 else |_| {}
    if (std.mem.startsWith(u8, m, "linux: signal ") or std.mem.startsWith(u8, m, "sys: trap: fault"))
        if (sig.noteSignal(m)) |s| return s.signo;
    return 1 << 8;
}

/// Parses an await message: "pid user sys real 'msg'".
fn parseWait(text: []const u8) ?WaitRec {
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    const pid = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const user = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch 0;
    const sys_ = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch 0;
    _ = it.next() orelse return null;
    const q = std.mem.indexOfScalar(u8, text, '\'') orelse return .{ .pid = pid, .status = 0, .user_ms = user, .sys_ms = sys_ };
    var msg = text[q + 1 ..];
    if (msg.len > 0 and msg[msg.len - 1] == '\'') msg = msg[0 .. msg.len - 1];
    // %q doubles quotes inside.
    var buf: [kern.ERRMAX]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < msg.len and n < buf.len) : (i += 1) {
        buf[n] = msg[i];
        n += 1;
        if (msg[i] == '\'' and i + 1 < msg.len and msg[i + 1] == '\'') i += 1;
    }
    return .{ .pid = pid, .status = waitStatus(buf[0..n]), .user_ms = user, .sys_ms = sys_ };
}

fn matches(p: *Process, want: i32, w: WaitRec) bool {
    if (want > 0) return w.pid == want;
    if (want == -1) return true;
    const pg: u32 = if (want == 0) p.pgid else @intCast(-want);
    const g = p.host.pgidOf(p.host.ctx, w.pid) orelse return true;
    return g == pg;
}

/// Finds a matching exit: from those stashed, then from await.
/// A wait record, none yet (only without `block`), or no children at all.
const Reaped = union(enum) { rec: WaitRec, none, nochild };

fn reap(p: *Process, want: i32, block: bool, peek: bool) Err!Reaped {
    for (p.waits.items, 0..) |w, i| if (matches(p, want, w)) {
        return .{ .rec = if (peek) w else p.waits.orderedRemove(i) };
    };
    var buf: [kern.ERRMAX + 128]u8 = undefined;
    while (true) {
        // The kernel picks a pid; a process group is matched here, and
        // other records kept for a later wait.
        const n = kc.await(&buf, block, want, peek and want > 0) catch {
            const e = kerr();
            if (e == -E.INTR) return error.Fault; // see wait4
            return .nochild;
        };
        if (n == 0) return .none;
        const w = parseWait(buf[0..n]) orelse continue;
        if (peek and want > 0) return .{ .rec = w };
        countChild(p, w);
        if (matches(p, want, w)) {
            if (peek) p.waits.append(p.gpa, w) catch return error.NoMem;
            return .{ .rec = w };
        }
        p.waits.append(p.gpa, w) catch return error.NoMem;
    }
}

fn wait4(p: *Process, pid: i32, status_va: u64, options: u32, ru_va: u64) Err!i64 {
    const w = switch (reap(p, pid, options & WNOHANG == 0, false) catch |e| switch (e) {
        error.Fault => return -E.INTR,
        else => return e,
    }) {
        .rec => |w| w,
        .none => return 0,
        .nochild => return -E.CHILD,
    };
    if (status_va != 0) try p.writeU32(status_va, w.status);
    if (ru_va != 0) try writeRusage(p, ru_va, waitTimes(w), 0);
    return w.pid;
}

fn waitTimes(w: WaitRec) cputime.Times {
    return .{ .user_ns = w.user_ms * std.time.ns_per_ms, .sys_ns = w.sys_ms * std.time.ns_per_ms };
}

/// Counts a reaped child's time in the group's RUSAGE_CHILDREN.
fn countChild(p: *Process, w: WaitRec) void {
    p.g.lockSpin();
    defer p.g.lock.unlock();
    p.g.cpu_children = p.g.cpu_children.add(waitTimes(w));
}

/// This thread's CPU time since it started.
pub fn threadCpu(p: *const Process) cputime.Times {
    return cputime.thread().since(p.cpu0);
}

/// The group's CPU time: the members that ended, and the caller. (Other
/// live threads' time isn't counted until they end.)
pub fn groupCpu(p: *Process) cputime.Times {
    p.g.lockSpin();
    defer p.g.lock.unlock();
    return p.g.cpu_ended.add(threadCpu(p));
}

/// Ends this thread's accounting: its time goes to the group's.
pub fn threadCpuEnd(p: *Process) void {
    const t = threadCpu(p);
    p.g.lockSpin();
    defer p.g.lock.unlock();
    p.g.cpu_ended = p.g.cpu_ended.add(t);
}

/// For the leader, last: the time its wait record reports, the group's
/// and its reaped children's, as Linux's wait4 counts it.
pub fn reportCpu(p: *Process) void {
    p.g.lockSpin();
    const t = p.g.cpu_ended.add(p.g.cpu_children);
    p.g.lock.unlock();
    kc.setCputime(t.user_ns / std.time.ns_per_ms, t.sys_ns / std.time.ns_per_ms);
}

fn getrusage(p: *Process, who: i32, ru_va: u64) Err!i64 {
    const RUSAGE_SELF = 0;
    const RUSAGE_CHILDREN = -1;
    const RUSAGE_THREAD = 1;
    const t: cputime.Times = switch (who) {
        RUSAGE_SELF => groupCpu(p),
        RUSAGE_THREAD => threadCpu(p),
        RUSAGE_CHILDREN => blk: {
            p.g.lockSpin();
            defer p.g.lock.unlock();
            break :blk p.g.cpu_children;
        },
        else => return -E.INVAL,
    };
    const rss_kb = if (who == RUSAGE_CHILDREN) 0 else p.mm.bytes() / 1024;
    try writeRusage(p, ru_va, t, rss_kb);
    return 0;
}

/// struct rusage: ru_utime and ru_stime as timevals, then 14 longs, of
/// which only ru_maxrss (KiB) is kept.
fn writeRusage(p: *Process, va: u64, t: cputime.Times, maxrss_kb: u64) Err!void {
    var b: [144]u8 = @splat(0);
    std.mem.writeInt(u64, b[0..8], t.user_ns / std.time.ns_per_s, .little);
    std.mem.writeInt(u64, b[8..16], t.user_ns % std.time.ns_per_s / std.time.ns_per_us, .little);
    std.mem.writeInt(u64, b[16..24], t.sys_ns / std.time.ns_per_s, .little);
    std.mem.writeInt(u64, b[24..32], t.sys_ns % std.time.ns_per_s / std.time.ns_per_us, .little);
    std.mem.writeInt(u64, b[32..40], maxrss_kb, .little);
    try p.writeMem(va, &b);
}

fn waitid(p: *Process, idtype: u32, id: u32, info_va: u64, options: u32, ru_va: u64) Err!i64 {
    const P_ALL = 0;
    const P_PID = 1;
    const P_PGID = 2;
    const WEXITED = 4;
    const WNOHANG_ID = 1;
    const WNOWAIT = 0x01000000;
    if (options & WEXITED == 0) return -E.INVAL;
    const want: i32 = switch (idtype) {
        P_ALL => -1,
        P_PID => @intCast(id),
        P_PGID => if (id == 0) 0 else -@as(i32, @intCast(id)),
        else => return -E.INVAL,
    };
    const w = switch (reap(p, want, options & WNOHANG_ID == 0, options & WNOWAIT != 0) catch |e| switch (e) {
        error.Fault => return -E.INTR,
        else => return e,
    }) {
        .rec => |w| w,
        .nochild => return -E.CHILD,
        .none => {
            if (info_va != 0) try p.writeMem(info_va, &@as([128]u8, @splat(0)));
            return 0;
        },
    };
    if (info_va != 0) {
        var b: [128]u8 = @splat(0);
        const CLD_EXITED = 1;
        const CLD_KILLED = 2;
        std.mem.writeInt(u32, b[0..4], sig.SIGCHLD, .little);
        const killed = w.status & 0x7f != 0;
        std.mem.writeInt(u32, b[8..12], if (killed) CLD_KILLED else CLD_EXITED, .little);
        std.mem.writeInt(u32, b[16..20], w.pid, .little);
        std.mem.writeInt(u32, b[24..28], if (killed) w.status & 0x7f else (w.status >> 8) & 0xff, .little);
        try p.writeMem(info_va, &b);
    }
    if (ru_va != 0) try writeRusage(p, ru_va, waitTimes(w), 0);
    return 0;
}

// Memory.

const MAP_SHARED = 1;
const MAP_PRIVATE = 2;
const MAP_FIXED = 0x10;
const MAP_ANONYMOUS = 0x20;
const MAP_GROWSDOWN = 0x100;
const MAP_FIXED_NOREPLACE = 0x100000;

fn mmap(p: *Process, addr: u64, len_in: u64, prot_bits: u32, flags: u32, fd: i32, off: u64) Err!i64 {
    if (len_in == 0) return -E.INVAL;
    const len = std.mem.alignForward(u64, len_in, page);
    if (len > mm.user_top or len < len_in) return -E.NOMEM;
    if (off % page != 0) return -E.INVAL;
    const shared = flags & 3 == MAP_SHARED or flags & 3 == 3;
    if (flags & 3 == 0) return -E.INVAL;
    const anon = flags & MAP_ANONYMOUS != 0;
    const prot: mm.Prot = .fromLinux(prot_bits);
    var info: ?kc.FdInfo = null;
    if (!anon) {
        if (fd < 0) return -E.BADF;
        info = kc.fdInfo(fd) catch return -E.BADF;
        if (info.?.dir) return -E.NODEV;
        if (info.?.mode == kern.OWRITE) return -E.ACCES;
        if (shared and prot.write and info.?.mode != kern.ORDWR) return -E.ACCES;
    }
    // Shared mappings are kept in chunks of their own, padded, so fork
    // can share them whole and processes mapping one file share its
    // pages (shmfile.zig): a file mapping sits at its offset's place in
    // its first chunk.
    const fixed = flags & (MAP_FIXED | MAP_FIXED_NOREPLACE) != 0;
    const delta: u64 = if (shared and !anon) off % mm.chunk_size else 0;
    const span = if (shared) std.mem.alignForward(u64, delta + len, mm.chunk_size) else len;
    var start: u64 = undefined;
    if (fixed) {
        if (addr % page != 0) return -E.INVAL;
        if (addr < mm.min_addr or addr >= mm.user_top or len > mm.user_top - addr) return -E.NOMEM;
        if (flags & MAP_FIXED_NOREPLACE != 0 and !p.mm.isFree(addr, addr + len)) return -E.EXIST;
        // A shared file mapping can only go where the file's chunks fit.
        if (shared and !anon and addr % mm.chunk_size != delta) return -E.NODEV;
        p.mm.unmap(addr, addr + len) catch return -E.NOMEM;
        start = addr;
    } else {
        const hint = std.mem.alignBackward(u64, addr, page);
        if (hint >= mm.min_addr and hint < mm.user_top and len <= mm.user_top - hint and !shared and p.mm.isFree(hint, hint + len)) {
            start = hint;
        } else {
            const at_ = p.mm.findFree(span + if (shared) mm.chunk_size else 0) orelse return -E.NOMEM;
            start = if (shared) std.mem.alignForward(u64, at_, mm.chunk_size) + delta else at_;
        }
    }
    var v: mm.Vma = .{ .start = start, .end = start + len, .prot = prot, .shared = shared, .kind = if (anon) .anon else .file, .offset = off };
    var path: []const u8 = "";
    if (!anon) {
        if (kern.fd2path(@intCast(fd), &p.name2_buf)) |_| {
            path = std.mem.sliceTo(&p.name2_buf, 0);
            v.name = .init(path);
        } else |_| {}
    }
    if (shared and !anon) {
        if (path.len == 0) return -E.NODEV;
        const Ctx = struct { backend: vmm.Backend, file: locks.Key, fd: u31, path: []const u8, writable: bool, first: u64, failed: bool = false };
        var cx: Ctx = .{ .backend = p.mm.backend, .file = lockKey(info.?), .fd = @intCast(fd), .path = path, .writable = prot.write, .first = off / mm.chunk_size -% start / mm.chunk_size };
        p.mm.insertShared(v, &cx, struct {
            fn f(x: *Ctx, ci: u64) mm.Error!*mm.Pages {
                return shmfile.pagesFor(x.backend, x.file, ci +% x.first, x.fd, x.path, x.writable) catch |e| switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.NoSpace => error.NoSpace,
                    error.Io => {
                        x.failed = true;
                        return error.BadAddress;
                    },
                };
            }
        }.f) catch return if (cx.failed) kerr() else if (fixed) -E.NODEV else -E.NOMEM;
        return @intCast(start);
    }
    if (shared and !fixed) {
        p.mm.insertShared(v, {}, null) catch return -E.NOMEM;
    } else p.mm.insert(v) catch return -E.NOMEM;
    if (!anon) {
        // Private file mappings are copies taken now.
        const Ctx = struct { fd: u31, off: u64, failed: bool = false };
        var cx: Ctx = .{ .fd = @intCast(fd), .off = off };
        p.mm.hostEach(start, len, &cx, struct {
            fn f(x: *Ctx, dst: []u8, o: u64) void {
                var done: usize = 0;
                while (done < dst.len) {
                    const n = kern.pread(x.fd, dst[done..], @intCast(x.off + o + done)) catch {
                        x.failed = true;
                        return;
                    };
                    if (n == 0) return;
                    done += n;
                }
            }
        }.f) catch {
            p.mm.unmap(start, start + len) catch {};
            return -E.NOMEM;
        };
        if (cx.failed) {
            p.mm.unmap(start, start + len) catch {};
            return kerr();
        }
    }
    return @intCast(start);
}

// System V shared memory (sysvshm.zig).

fn shmWho(p: *Process) sysvshm.Who {
    return .{ .uid = p.cred.uid[1], .gid = p.cred.gid[1], .pid = @intCast(p.tgid()), .now = @divTrunc(kern.wallNs(), std.time.ns_per_s) };
}

fn shmget(p: *Process, key: i32, size: u64, flags: u32) i64 {
    return sysvshm.get(p.mm.backend, key, size, flags, shmWho(p)) catch |e| switch (e) {
        error.NotFound => -E.NOENT,
        error.Exists => -E.EXIST,
        error.Invalid => -E.INVAL,
        error.NoSpace, error.OutOfMemory => -E.NOMEM,
    };
}

fn shmat(p: *Process, id: i32, addr: u64, flags: u32) i64 {
    const SHM_RDONLY = 0o10000;
    const SHM_RND = 0o20000;
    sysvshm.lock();
    const sg = sysvshm.find(p.mm.backend, id) orelse {
        sysvshm.unlock();
        return -E.INVAL;
    };
    if (sg.removed and sg.nattch() == 0) {
        sysvshm.unlock();
        return -E.IDRM;
    }
    const pages = sg.pages;
    const len = std.mem.alignForward(u64, sg.size, page);
    sg.lpid = @intCast(p.tgid());
    sg.atime = @divTrunc(kern.wallNs(), std.time.ns_per_s);
    sysvshm.unlock();
    // Its chunks are its own, so it sits at a chunk's start.
    var start: u64 = undefined;
    if (addr != 0) {
        start = if (flags & SHM_RND != 0) std.mem.alignBackward(u64, addr, mm.chunk_size) else addr;
        if (start % mm.chunk_size != 0) return -E.INVAL;
    } else {
        const at_ = p.mm.findFree(len + 2 * mm.chunk_size) orelse return -E.NOMEM;
        start = std.mem.alignForward(u64, at_, mm.chunk_size);
    }
    var v: mm.Vma = .{ .start = start, .end = start + len, .prot = if (flags & SHM_RDONLY != 0) .{ .read = true } else .rw, .shared = true, .kind = .shm, .offset = @intCast(id) };
    var nb: [32]u8 = undefined;
    v.name = .init(std.fmt.bufPrint(&nb, "/SYSV{x:0>8}", .{@as(u32, @bitCast(sg.key))}) catch "");
    const Ctx = struct { pages: []*mm.Pages, first: u64 };
    var cx: Ctx = .{ .pages = pages, .first = start / mm.chunk_size };
    p.mm.insertShared(v, &cx, struct {
        fn f(x: *Ctx, ci: u64) mm.Error!*mm.Pages {
            return x.pages[@intCast(ci - x.first)];
        }
    }.f) catch return if (addr != 0) -E.INVAL else -E.NOMEM;
    return @intCast(start);
}

fn shmctl(p: *Process, id: i32, cmd_in: u32, buf: u64) Err!i64 {
    const IPC_RMID = 0;
    const IPC_SET = 1;
    const IPC_STAT = 2;
    const IPC_INFO = 3;
    const SHM_STAT = 13;
    const SHM_INFO = 14;
    const SHM_STAT_ANY = 15;
    const SHM_LOCK = 11;
    const SHM_UNLOCK = 12;
    const cmd = cmd_in & 0xff; // less IPC_64
    switch (cmd) {
        IPC_INFO, SHM_INFO => {
            var b: [128]u8 = @splat(0);
            // shminfo64: shmmax, shmmin, shmmni, shmseg, shmall.
            std.mem.writeInt(u64, b[0..8], 1 << 40, .little);
            std.mem.writeInt(u64, b[8..16], 1, .little);
            std.mem.writeInt(u64, b[16..24], 4096, .little);
            std.mem.writeInt(u64, b[24..32], 4096, .little);
            std.mem.writeInt(u64, b[32..40], 1 << 28, .little);
            if (buf != 0) try p.writeMem(buf, b[0..if (cmd == IPC_INFO) 80 else 64]);
            return 0;
        },
        else => {},
    }
    sysvshm.lock();
    const sg = sysvshm.find(p.mm.backend, id) orelse {
        sysvshm.unlock();
        return -E.INVAL;
    };
    const owner = p.cred.root() or p.cred.uid[1] == sg.uid or p.cred.uid[1] == sg.cuid;
    switch (cmd) {
        IPC_STAT, SHM_STAT, SHM_STAT_ANY => {
            var b: [112]u8 = undefined;
            sysvshm.stat(sg, &b);
            sysvshm.unlock();
            try p.writeMem(buf, &b);
            return if (cmd == IPC_STAT) 0 else id;
        },
        IPC_SET => {
            if (!owner) {
                sysvshm.unlock();
                return -E.PERM;
            }
            var b: [24]u8 = undefined;
            sysvshm.unlock();
            try p.readMem(buf, &b);
            sysvshm.lock();
            if (sysvshm.find(p.mm.backend, id)) |s2| {
                s2.uid = std.mem.readInt(u32, b[4..8], .little);
                s2.gid = std.mem.readInt(u32, b[8..12], .little);
                s2.mode = std.mem.readInt(u32, b[20..24], .little) & 0o777;
            }
            sysvshm.unlock();
            return 0;
        },
        IPC_RMID => {
            if (!owner) {
                sysvshm.unlock();
                return -E.PERM;
            }
            sysvshm.remove(sg);
            return 0;
        },
        SHM_LOCK, SHM_UNLOCK => {
            sysvshm.unlock();
            return 0;
        },
        else => {
            sysvshm.unlock();
            return -E.INVAL;
        },
    }
}

fn mremap(p: *Process, old: u64, old_len_in: u64, new_len_in: u64, flags: u32, new_addr: u64) Err!i64 {
    const MREMAP_MAYMOVE = 1;
    const MREMAP_FIXED = 2;
    if (old % page != 0) return -E.INVAL;
    const old_len = std.mem.alignForward(u64, old_len_in, page);
    const new_len = std.mem.alignForward(u64, new_len_in, page);
    if (new_len == 0) return -E.INVAL;
    if (flags & MREMAP_FIXED != 0) return -E.INVAL;
    const v = p.mm.find(old) orelse return -E.FAULT;
    if (old + old_len > v.end) return -E.FAULT;
    const vma = v.*;
    // A shared mapping's pages are its chunks', which don't move or grow.
    if (vma.shared and new_len != old_len) return -E.INVAL;
    if (new_len <= old_len) {
        p.mm.unmap(old + new_len, old + old_len) catch return -E.NOMEM;
        return @intCast(old);
    }
    // Grow in place when the space after it is free.
    if (old + old_len == vma.end and p.mm.isFree(old + old_len, old + new_len) and old + new_len <= mm.user_top) {
        var ext = vma;
        ext.start = old + old_len;
        ext.end = old + new_len;
        p.mm.insert(ext) catch return -E.NOMEM;
        return @intCast(old);
    }
    if (flags & MREMAP_MAYMOVE == 0) return -E.NOMEM;
    _ = new_addr;
    const dst = p.mm.findFree(new_len) orelse return -E.NOMEM;
    var nv = vma;
    nv.start = dst;
    nv.end = dst + new_len;
    p.mm.insert(nv) catch return -E.NOMEM;
    // Copy only the pages that were allocated; the rest are zero anyway.
    p.mm.copyRange(old, dst, old_len) catch {
        p.mm.unmap(dst, dst + new_len) catch {};
        return -E.NOMEM;
    };
    p.mm.unmap(old, old + old_len) catch {};
    return @intCast(dst);
}

// Signals.

fn sigaction(p: *Process, signo_raw: u64, act_va: u64, old_va: u64, size: u64) Err!i64 {
    if (size != 8) return -E.INVAL;
    const signo: u32 = @truncate(signo_raw);
    if (signo == 0 or signo > sig.nsig) return -E.INVAL;
    if (old_va != 0) {
        const a = p.sig.actions[signo];
        var b: [32]u8 = undefined;
        std.mem.writeInt(u64, b[0..8], a.handler, .little);
        std.mem.writeInt(u64, b[8..16], a.flags, .little);
        std.mem.writeInt(u64, b[16..24], a.restorer, .little);
        std.mem.writeInt(u64, b[24..32], a.mask, .little);
        try p.writeMem(old_va, &b);
    }
    if (act_va != 0) {
        if (signo == sig.SIGKILL or signo == sig.SIGSTOP) return -E.INVAL;
        var b: [32]u8 = undefined;
        try p.readMem(act_va, &b);
        // Every thread's copy (CLONE_SIGHAND).
        p.g.setAction(signo, .{
            .handler = std.mem.readInt(u64, b[0..8], .little),
            .flags = std.mem.readInt(u64, b[8..16], .little),
            .restorer = std.mem.readInt(u64, b[16..24], .little),
            .mask = std.mem.readInt(u64, b[24..32], .little),
        });
        // Setting SIG_IGN discards a pending signal.
        if (p.sig.actions[signo].handler == sig.SIG_IGN) p.sig.pending &= ~sig.bit(signo);
    }
    return 0;
}

fn sigprocmask(p: *Process, how: u32, set_va: u64, old_va: u64, size: u64) Err!i64 {
    if (size != 8) return -E.INVAL;
    if (old_va != 0) try p.writeU64(old_va, p.sig.mask);
    if (set_va != 0) {
        const set = try p.readU64(set_va);
        switch (how) {
            0 => p.sig.mask |= set,
            1 => p.sig.mask &= ~set,
            2 => p.sig.mask = set,
            else => return -E.INVAL,
        }
        p.sig.mask &= ~sig.unblockable;
    }
    return 0;
}

fn sigaltstack(p: *Process, ss_va: u64, old_va: u64) Err!i64 {
    if (old_va != 0) {
        var b: [24]u8 = @splat(0);
        std.mem.writeInt(u64, b[0..8], p.sig.altstack.sp, .little);
        std.mem.writeInt(u32, b[8..12], if (p.sig.altstack.size == 0) sig.SS_DISABLE else 0, .little);
        std.mem.writeInt(u64, b[16..24], p.sig.altstack.size, .little);
        try p.writeMem(old_va, &b);
    }
    if (ss_va != 0) {
        var b: [24]u8 = undefined;
        try p.readMem(ss_va, &b);
        const flags = std.mem.readInt(u32, b[8..12], .little);
        if (flags & sig.SS_DISABLE != 0) {
            p.sig.altstack = .{};
        } else {
            const size = std.mem.readInt(u64, b[16..24], .little);
            if (size < 2048) return -E.NOMEM;
            p.sig.altstack = .{ .sp = std.mem.readInt(u64, b[0..8], .little), .size = size };
        }
    }
    return 0;
}

fn sigtimedwait(p: *Process, set_va: u64, info_va: u64, ts_va: u64) Err!i64 {
    const set = try p.readU64(set_va);
    var ms: ?i64 = null;
    if (ts_va != 0) ms = @divTrunc(try readTimespec(p, ts_va), std.time.ns_per_ms);
    while (true) {
        if (p.sig.takeFrom(set)) |s| {
            if (info_va != 0) {
                var b: [128]u8 = @splat(0);
                std.mem.writeInt(u32, b[0..4], s, .little);
                try p.writeMem(info_va, &b);
            }
            return s;
        }
        if (ms) |left| {
            if (left <= 0) return -E.AGAIN;
            kern.sleep(left) catch {};
            ms = 0;
        } else kern.sleep(1 << 30) catch {};
        // A note arrived: the process model drains it into pending on the
        // way back, so this returns EINTR and the guest's libc retries.
        if (kern.notePending()) return -E.INTR;
    }
}

// Time.

fn clockNs(id: u32) ?i64 {
    return switch (id) {
        0, 5, 8, 11 => kern.wallNs(), // REALTIME, REALTIME_COARSE, REALTIME_ALARM, TAI
        1, 4, 6, 7, 9 => kern.monoNs(), // MONOTONIC, _RAW, _COARSE, BOOTTIME, BOOTTIME_ALARM
        2, 3 => 0, // PROCESS_CPUTIME_ID, THREAD_CPUTIME_ID: no per-process CPU accounting yet
        else => null,
    };
}

// Interval timers (itimer.zig): ITIMER_REAL. The CPU-time ones are
// accepted and never fire.

fn readTimeval(p: *Process, va: u64) (Err || error{Invalid})!i64 {
    const sec: i64 = @bitCast(try p.readU64(va));
    const usec: i64 = @bitCast(try p.readU64(va + 8));
    if (sec < 0 or usec < 0 or usec >= 1000000) return error.Invalid;
    return sec * std.time.ns_per_s + usec * std.time.ns_per_us;
}

fn writeItimerval(p: *Process, va: u64, v: itimer.Value) Err!void {
    var b: [32]u8 = undefined;
    const tv = [2]i64{ v.interval_ns, v.left_ns };
    for (tv, 0..) |ns, i| {
        const us = @divTrunc(ns + std.time.ns_per_us - 1, std.time.ns_per_us);
        std.mem.writeInt(i64, b[16 * i ..][0..8], @divTrunc(us, 1000000), .little);
        std.mem.writeInt(i64, b[16 * i + 8 ..][0..8], @mod(us, 1000000), .little);
    }
    try p.writeMem(va, &b);
}

fn setitimer(p: *Process, which: i32, new_va: u64, old_va: u64) Err!i64 {
    if (which < 0 or which > 2) return -E.INVAL;
    var v: itimer.Value = .{};
    if (new_va != 0) {
        v.interval_ns = readTimeval(p, new_va) catch |e| return if (e == error.Invalid) -E.INVAL else @as(Err, @errorCast(e));
        v.left_ns = readTimeval(p, new_va + 16) catch |e| return if (e == error.Invalid) -E.INVAL else @as(Err, @errorCast(e));
    }
    if (which != 0) {
        if (old_va != 0) try writeItimerval(p, old_va, .{});
        return 0;
    }
    const old = itimer.set(@intFromPtr(p.g), v) catch return -E.NOMEM;
    if (old_va != 0) try writeItimerval(p, old_va, old);
    return 0;
}

fn getitimer(p: *Process, which: i32, va: u64) Err!i64 {
    if (which < 0 or which > 2) return -E.INVAL;
    try writeItimerval(p, va, if (which == 0) itimer.get(@intFromPtr(p.g)) else .{});
    return 0;
}

fn writeTimespec(p: *Process, va: u64, ns: i64) Err!void {
    var b: [16]u8 = undefined;
    std.mem.writeInt(i64, b[0..8], @divFloor(ns, std.time.ns_per_s), .little);
    std.mem.writeInt(i64, b[8..16], @mod(ns, std.time.ns_per_s), .little);
    try p.writeMem(va, &b);
}

fn readTimespec(p: *Process, va: u64) Err!i64 {
    var b: [16]u8 = undefined;
    try p.readMem(va, &b);
    const s = std.mem.readInt(i64, b[0..8], .little);
    const ns = std.mem.readInt(i64, b[8..16], .little);
    if (s < 0 or ns < 0 or ns >= std.time.ns_per_s) return -1;
    return std.math.add(i64, std.math.mul(i64, s, std.time.ns_per_s) catch std.math.maxInt(i64), ns) catch std.math.maxInt(i64);
}

fn nanosleep(p: *Process, req: u64, rem: u64, abs: bool) Err!i64 {
    _ = abs;
    const ns = try readTimespec(p, req);
    if (ns < 0) return -E.INVAL;
    return sleepNs(p, ns, rem);
}

fn nanosleepClock(p: *Process, clock: u32, abs: bool, req: u64, rem: u64) Err!i64 {
    var ns = try readTimespec(p, req);
    if (ns < 0) return -E.INVAL;
    if (abs) ns -= clockNs(clock) orelse 0;
    if (ns <= 0) return 0;
    return sleepNs(p, ns, if (abs) 0 else rem);
}

fn sleepNs(p: *Process, ns: i64, rem: u64) Err!i64 {
    const start = kern.monoNs();
    // The kernel sleeps in milliseconds; round up so a sleep is never short.
    const ms = @divTrunc(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    if (ms == 0) return 0;
    kern.sleep(ms) catch {
        if (rem != 0) {
            const left = @max(0, ns - (kern.monoNs() - start));
            try writeTimespec(p, rem, left);
        }
        return -E.INTR;
    };
    return 0;
}

const FUTEX_WAIT = 0;
const FUTEX_WAKE = 1;
const FUTEX_REQUEUE = 3;
const FUTEX_CMP_REQUEUE = 4;
const FUTEX_WAIT_BITSET = 9;
const FUTEX_WAKE_BITSET = 10;
const FUTEX_CLOCK_REALTIME = 256;
const FUTEX_WAITERS: u32 = 0x80000000;
const FUTEX_OWNER_DIED: u32 = 0x40000000;
const FUTEX_TID_MASK: u32 = 0x3fffffff;

/// The host's view of the futex word at va, which must be aligned.
fn futexWord(p: *Process, va: u64) Err!*u32 {
    if (va % 4 != 0) return error.Fault;
    const b = p.mm.hostSlice(va, 4, false) catch return error.Fault;
    return @ptrCast(@alignCast(b.ptr));
}

/// futex (design/0049-linux-threads.md): waits keyed on the address
/// space and the guest address, so they're private to the process's
/// threads (and a vfork child's), with or without FUTEX_PRIVATE_FLAG.
/// A futex in a MAP_SHARED mapping (or a System V segment) is keyed on
/// its pages instead, so processes that share them meet there, as
/// process-shared semaphores need (PostgreSQL's).
fn futex(p: *Process, uaddr_in: u64, op: u32, val: u32, timeout: u64, uaddr2_in: u64, val3: u32) Err!i64 {
    const cmd = op & 0x7f;
    var key: *const anyopaque = p.mm;
    var uaddr = uaddr_in;
    var uaddr2 = uaddr2_in;
    const FUTEX_PRIVATE_FLAG = 128;
    if (op & FUTEX_PRIVATE_FLAG == 0 and uaddr % 4 == 0) {
        p.mm.touch(uaddr, 4, false) catch return error.Fault;
        if (p.mm.sharedAt(uaddr)) |s| {
            key = s.pages;
            // A requeue target in the same pages keeps its place in them.
            if (uaddr2 / mm.chunk_size == uaddr / mm.chunk_size) uaddr2 = s.off +% uaddr2 -% uaddr;
            uaddr = s.off;
        }
    }
    switch (cmd) {
        FUTEX_WAIT, FUTEX_WAIT_BITSET => {
            const bitset: u32 = if (cmd == FUTEX_WAIT) 0xffffffff else val3;
            if (bitset == 0) return -E.INVAL;
            if (uaddr % 4 != 0) return -E.INVAL;
            const word = try futexWord(p, uaddr_in);
            var ms: i64 = -1;
            if (timeout != 0) {
                var ns = try readTimespec(p, timeout);
                // WAIT_BITSET's is absolute, on the clock the flag names.
                if (cmd == FUTEX_WAIT_BITSET) ns -= if (op & FUTEX_CLOCK_REALTIME != 0) kern.wallNs() else kern.monoNs();
                if (ns <= 0) return if (@atomicLoad(u32, word, .seq_cst) != val) -E.AGAIN else -E.TIMEDOUT;
                ms = @divTrunc(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
            }
            return switch (kc.futexWait(key, uaddr, word, val, bitset, ms) catch return -E.INTR) {
                .woken => 0,
                .again => -E.AGAIN,
                .timed_out => -E.TIMEDOUT,
            };
        },
        FUTEX_WAKE, FUTEX_WAKE_BITSET => {
            const bitset: u32 = if (cmd == FUTEX_WAKE) 0xffffffff else val3;
            if (bitset == 0) return -E.INVAL;
            return kc.futexWake(key, uaddr, val, bitset, 0, 0, null).?;
        },
        FUTEX_REQUEUE, FUTEX_CMP_REQUEUE => {
            // The fourth argument is a count here, not a timeout.
            const nreq: u32 = @truncate(timeout);
            if (cmd == FUTEX_REQUEUE) return kc.futexWake(key, uaddr, val, 0xffffffff, uaddr2, nreq, null).?;
            const word = try futexWord(p, uaddr_in);
            return kc.futexWake(key, uaddr, val, 0xffffffff, uaddr2, nreq, .{ .word = word, .val = val3 }) orelse -E.AGAIN;
        },
        // PI futexes and FUTEX_WAKE_OP.
        else => return -E.NOSYS,
    }
}

/// Wakes one waiter on the futex at va.
pub fn futexWakeOne(p: *Process, va: u64) void {
    _ = kc.futexWake(p.mm, va, 1, 0xffffffff, 0, 0, null);
}

/// What a thread does on its way out (design/0049): marks the robust
/// futexes it holds as their owner died, waking a waiter on each, then
/// zeroes its clear-tid word and wakes a waiter there (pthread_join).
pub fn threadExiting(p: *Process) void {
    if (p.robust_list != 0) p.walkRobust() catch {};
    p.robust_list = 0;
    if (p.clear_tid != 0) {
        p.writeU32(p.clear_tid, 0) catch {};
        _ = kc.futexWake(p.mm, p.clear_tid, 1, 0xffffffff, 0, 0, null);
    }
    p.clear_tid = 0;
}

// Other.

fn nodename() []const u8 {
    return "h9";
}

fn machineName(a: vmm.Arch) []const u8 {
    return switch (a) {
        .arm64 => "aarch64",
        .amd64 => "x86_64",
        .i386 => "i686",
    };
}

fn prctl(p: *Process, op: i32, arg: u64) Err!i64 {
    const PR_SET_PDEATHSIG = 1;
    const PR_GET_PDEATHSIG = 2;
    const PR_GET_DUMPABLE = 3;
    const PR_SET_DUMPABLE = 4;
    const PR_SET_NAME = 15;
    const PR_GET_NAME = 16;
    const PR_SET_SECCOMP = 22;
    const PR_SET_NO_NEW_PRIVS = 38;
    const PR_GET_NO_NEW_PRIVS = 39;
    switch (op) {
        PR_SET_PDEATHSIG, PR_SET_DUMPABLE => return 0,
        PR_GET_PDEATHSIG => {
            try p.writeU32(arg, 0);
            return 0;
        },
        PR_GET_DUMPABLE => return 1,
        PR_SET_NAME => {
            var b: [16]u8 = undefined;
            const name = p.string(arg, &b) catch |e| switch (e) {
                error.NameTooLong => b[0..15 :0],
                else => return e,
            };
            kern.setText(name);
            return 0;
        },
        PR_GET_NAME => {
            var b: [16]u8 = @splat(0);
            const n = @min(p.exe_len, 15);
            const base = basename(p.exe[0..p.exe_len]);
            @memcpy(b[0..@min(base.len, 15)], base[0..@min(base.len, 15)]);
            _ = n;
            try p.writeMem(arg, &b);
            return 0;
        },
        PR_SET_SECCOMP => return -E.INVAL,
        PR_SET_NO_NEW_PRIVS => return 0,
        PR_GET_NO_NEW_PRIVS => return 1,
        else => return -E.INVAL,
    }
}

fn prlimit(p: *Process, pid: i32, res: u32, new: u64, old: u64) Err!i64 {
    _ = new;
    if (pid != 0 and pid != p.pid) return -E.PERM;
    const inf = std.math.maxInt(u64);
    const RLIMIT_STACK = 3;
    const RLIMIT_NOFILE = 7;
    const RLIMIT_AS = 9;
    const lim: [2]u64 = switch (res) {
        RLIMIT_STACK => .{ mm.stack_size, inf },
        RLIMIT_NOFILE => .{ 1024, 1024 },
        RLIMIT_AS => .{ if (p.mem_limit > 0) p.mem_limit else inf, if (p.mem_limit > 0) p.mem_limit else inf },
        else => if (res < 16) .{ inf, inf } else return -E.INVAL,
    };
    if (old != 0) {
        var b: [16]u8 = undefined;
        std.mem.writeInt(u64, b[0..8], lim[0], .little);
        std.mem.writeInt(u64, b[8..16], lim[1], .little);
        try p.writeMem(old, &b);
    }
    return 0;
}

test "wait statuses" {
    try std.testing.expectEqual(@as(u32, 0), waitStatus(""));
    try std.testing.expectEqual(@as(u32, 3 << 8), waitStatus("3"));
    try std.testing.expectEqual(@as(u32, 11), waitStatus("sys: trap: fault read addr=0x0 pc=0x1234"));
    try std.testing.expectEqual(@as(u32, 9), waitStatus("linux: signal 9"));
    try std.testing.expectEqual(@as(u32, 1 << 8), waitStatus("something else"));
    try std.testing.expectEqual(@as(u32, 2 << 8), waitStatus("sh 7: 2"));
    const w = parseWait("12 0 0 0 'linux: signal 15'").?;
    try std.testing.expectEqual(@as(u32, 12), w.pid);
    try std.testing.expectEqual(@as(u32, 15), w.status);
}

test "the table compiles" {
    _ = &dispatch;
    _ = &frameCheck;
}

fn frameCheck(p: *Process, u: *vmm.Ureg, x: *vmm.Extra, f: sig.Frame) !void {
    try sig.setup(p, &p.sig, u, x, f);
    try sig.restore(p, &p.sig, u, x);
}

// Sockets and readiness (design/0050-linux-net.md). A socket is a /net
// conversation: its fd is the conversation's data file, opened from
// devip directly (#I), so --net and the policy's devip hooks apply as
// they do for 9front programs. What Linux needs beyond the files goes
// through control messages (connect, nbconnect, announce, shutdown,
// sockopt) or straight to the host socket (recvfrom and sendto with
// flags and addresses, SO_ERROR), in src/kern/linuxnet.c.

const AF_UNSPEC = 0;
const AF_UNIX = 1;
const AF_INET = 2;
const AF_INET6 = 10;
const SOCK_STREAM = 1;
const SOCK_DGRAM = 2;
const SOCK_NONBLOCK = 0o4000;
const SOCK_CLOEXEC = 0o2000000;
const MSG_PEEK = 2;
const MSG_TRUNC = 0x20;
const MSG_DONTWAIT = 0x40;
const MSG_WAITALL = 0x100;
const MSG_NOSIGNAL = 0x4000;
const SOL_SOCKET = 1;
const IPPROTO_IP = 0;
const IPPROTO_TCP = 6;
const IPPROTO_IPV6 = 41;
const SO_REUSEADDR = 2;
const SO_TYPE = 3;
const SO_ERROR = 4;
const SO_SNDBUF = 7;
const SO_RCVBUF = 8;
const SO_KEEPALIVE = 9;
const SO_ACCEPTCONN = 30;
const SO_PROTOCOL = 38;
const SO_DOMAIN = 39;
const TCP_NODELAY = 1;
const TCP_KEEPIDLE = 4;
const TCP_KEEPINTVL = 5;
const TCP_KEEPCNT = 6;
const IPV6_V6ONLY = 26;

/// devip's data file type, and its protocols' indexes (kern/devip.c).
const ip_qdata = 7;
const ip_udp = 0;
const ip_tcp = 1;

pub const Sock = struct {
    family: u16,
    stype: u8,
    listening: bool = false,
    connected: bool = false,
    /// A connected datagram socket's peer, set by connect or by the
    /// connect a first sendto makes. A later sendto to it sends on the
    /// conversation, as Linux allows: the host socket is connected, so
    /// passing the address again would fail with EISCONN (musl's resolver
    /// sends its A and AAAA queries to the same server with two sendtos).
    peer: ?kc.NetAddr = null,
    /// bind's address, as an announce string ("addr!port" or "port").
    bound: [64]u8 = undefined,
    bound_len: u8 = 0,
    /// Options set, as getsockopt reports them.
    opts: [16]Opt = undefined,
    nopts: u8 = 0,

    const Opt = struct { key: u32, val: i32 };

    fn opt(s: *const Sock, level: u32, name: u32) ?i32 {
        for (s.opts[0..s.nopts]) |o| if (o.key == level << 16 | name) return o.val;
        return null;
    }
    fn setOpt(s: *Sock, level: u32, name: u32, v: i32) void {
        for (s.opts[0..s.nopts]) |*o| if (o.key == level << 16 | name) {
            o.val = v;
            return;
        };
        if (s.nopts < s.opts.len) {
            s.opts[s.nopts] = .{ .key = level << 16 | name, .val = v };
            s.nopts += 1;
        }
    }
};

/// A socket fd's conversation (protocol << 12 | conversation), or null if
/// fd isn't one.
fn convOf(fd: i32) ?u32 {
    const info = kc.fdInfo(fd) catch return null;
    if (info.dc != 'I' or info.dir or info.qpath & 0xf != ip_qdata) return null;
    return @intCast((info.qpath >> 4) & 0xfffff);
}

/// fd's socket state, made up for a conversation opened another way (by
/// a 9front parent, say).
fn sockOf(p: *Process, fd: i32) ?struct { conv: u32, s: *Sock } {
    const conv = convOf(fd) orelse return null;
    p.g.lockSpin();
    defer p.g.lock.unlock();
    if (p.g.socks.get(conv)) |so| return .{ .conv = conv, .s = so };
    p.g.putSock(conv, .{ .family = AF_INET, .stype = if (conv >> 12 == ip_udp) SOCK_DGRAM else SOCK_STREAM, .connected = true }) catch return null;
    return .{ .conv = conv, .s = p.g.socks.get(conv).? };
}

fn protoName(conv: u32) []const u8 {
    return if (conv >> 12 == ip_udp) "udp" else "tcp";
}

/// Opens one of a conversation's files.
fn convOpen(conv: u32, file: []const u8, mode: c_int) kern.Error!u31 {
    var b: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&b, "#I/{s}/{d}/{s}", .{ protoName(conv), conv & 0xfff, file }) catch unreachable;
    return kern.open(path, mode);
}

/// Reads a conversation's small text file (local, remote, status).
fn convRead(conv: u32, file: []const u8, buf: []u8) ?[]const u8 {
    const fd = convOpen(conv, file, kern.OREAD) catch return null;
    defer kern.close(fd) catch {};
    const n = kern.pread(fd, buf, 0) catch return null;
    return std.mem.trim(u8, buf[0..n], " \n");
}

/// The error for a /net open that failed: --net=disable masks #I, which
/// Linux programs see as a refusal.
fn netErr() i64 {
    const e = kerr();
    return if (e == -E.NOENT or e == -E.IO) -E.ACCES else e;
}

/// Opens a new conversation's data file for socket(2) and accept(2):
/// `clone` is a clone or listen file, opened for its new ctl.
fn openConv(p: *Process, clone: [:0]const u8, proto: u32, cloexec: bool) Err!union(enum) { fd: u31, err: i64 } {
    _ = p;
    const ctl = kern.open(clone, kern.ORDWR) catch return .{ .err = netErr() };
    defer kern.close(ctl) catch {};
    var b: [16]u8 = undefined;
    const n = kern.pread(ctl, &b, 0) catch return .{ .err = kerr() };
    const num = std.fmt.parseInt(u32, std.mem.trim(u8, b[0..n], " \n"), 10) catch return .{ .err = -E.IO };
    const fd = convOpen(proto << 12 | num, "data", kern.ORDWR | if (cloexec) @as(c_int, OCEXEC) else 0) catch return .{ .err = kerr() };
    return .{ .fd = fd };
}

fn socketCall(p: *Process, domain: u32, type_in: u32, protocol: u32) Err!i64 {
    const st = type_in & 0xf;
    if (domain == AF_UNIX) return unixSocket(p, type_in);
    if (domain == netlink.AF_NETLINK) return netlinkSocket(p, type_in, protocol);
    if (domain != AF_INET and domain != AF_INET6) return -E.AFNOSUPPORT;
    // As Linux without IPv6: programs that try both families (Redis's
    // default "bind * -::*") then skip IPv6, where devip would quietly
    // listen on IPv4 for "::" and collide with their IPv4 socket.
    if (domain == AF_INET6 and !kc.hostHasV6()) return -E.AFNOSUPPORT;
    const proto: u32 = switch (st) {
        SOCK_STREAM => ip_tcp,
        SOCK_DGRAM => ip_udp,
        else => return -E.PROTONOSUPPORT,
    };
    const clone: [:0]const u8 = if (proto == ip_tcp) "#I/tcp/clone" else "#I/udp/clone";
    const fd = switch (try openConv(p, clone, proto, type_in & SOCK_CLOEXEC != 0)) {
        .fd => |f| f,
        .err => |e| return e,
    };
    const conv = convOf(fd) orelse return -E.IO;
    {
        p.g.lockSpin();
        defer p.g.lock.unlock();
        p.g.putSock(conv, .{ .family = @intCast(domain), .stype = @intCast(st) }) catch return -E.NOMEM;
    }
    if (type_in & SOCK_NONBLOCK != 0) setFlags(p, fd, .{ .nonblock = true });
    return fd;
}

fn socketpair(p: *Process, domain: u32, type_in: u32, sv: u64) Err!i64 {
    if (domain != AF_UNIX) return -E.AFNOSUPPORT;
    const st = type_in & 0xf;
    if (st != SOCK_STREAM and st != SOCK_DGRAM and st != 5) return -E.PROTONOSUPPORT;
    var b: [8]u8 = undefined;
    try p.writeMem(sv, &b);
    // A 9front pipe is bidirectional and keeps message boundaries.
    const fds = kern.pipe() catch return kerr();
    for (fds) |fd| {
        if (type_in & SOCK_CLOEXEC != 0) kc.setCloexec(fd, true) catch {};
        if (type_in & SOCK_NONBLOCK != 0) setFlags(p, fd, .{ .nonblock = true });
    }
    std.mem.writeInt(i32, b[0..4], fds[0], .little);
    std.mem.writeInt(i32, b[4..8], fds[1], .little);
    try p.writeMem(sv, &b);
    return 0;
}

/// A sockaddr from the guest, as a devip address.
fn readSockaddr(p: *Process, va: u64, len: u64) Err!union(enum) { addr: kc.NetAddr, unspec, err: i64 } {
    if (len < 2) return .{ .err = -E.INVAL };
    var b: [28]u8 = @splat(0);
    try p.readMem(va, b[0..@min(len, b.len)]);
    const fam = std.mem.readInt(u16, b[0..2], .little);
    var a: kc.NetAddr = .{};
    switch (fam) {
        AF_UNSPEC => return .unspec,
        AF_INET => {
            if (len < 16) return .{ .err = -E.INVAL };
            a.port = std.mem.readInt(u16, b[2..4], .big);
            a.ip[10] = 0xff;
            a.ip[11] = 0xff;
            @memcpy(a.ip[12..16], b[4..8]);
        },
        AF_INET6 => {
            if (len < 24) return .{ .err = -E.INVAL };
            a.port = std.mem.readInt(u16, b[2..4], .big);
            @memcpy(&a.ip, b[8..24]);
        },
        else => return .{ .err = -E.AFNOSUPPORT },
    }
    return .{ .addr = a };
}

fn isV4(ip: *const [16]u8) bool {
    return std.mem.allEqual(u8, ip[0..10], 0) and ip[10] == 0xff and ip[11] == 0xff;
}

/// devip's text for an address: "a.b.c.d!port" or the v6 form.
fn addrText(buf: []u8, a: kc.NetAddr) []const u8 {
    if (isV4(&a.ip)) return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}!{d}", .{ a.ip[12], a.ip[13], a.ip[14], a.ip[15], a.port }) catch unreachable;
    var w: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    while (i < 16) : (i += 2) w.print("{s}{x}", .{ if (i > 0) ":" else "", std.mem.readInt(u16, a.ip[i..][0..2], .big) }) catch unreachable;
    w.print("!{d}", .{a.port}) catch unreachable;
    return w.buffered();
}

/// Parses devip's "addr!port" (from local and remote).
fn parseAddrText(t: []const u8) kc.NetAddr {
    var a: kc.NetAddr = .{};
    const bang = std.mem.lastIndexOfScalar(u8, t, '!') orelse return a;
    a.port = std.fmt.parseInt(u16, t[bang + 1 ..], 10) catch 0;
    const ip = std.Io.net.IpAddress.parse(t[0..bang], 0) catch return a;
    switch (ip) {
        .ip4 => |v4| {
            a.ip[10] = 0xff;
            a.ip[11] = 0xff;
            @memcpy(a.ip[12..16], &v4.bytes);
        },
        .ip6 => |v6| a.ip = v6.bytes,
    }
    return a;
}

/// Writes a as a sockaddr for a socket of `family`, truncated to *lenp
/// as Linux does, and sets *lenp to its full length.
fn writeSockaddr(p: *Process, va: u64, lenp: u64, family: u16, a: kc.NetAddr) Err!void {
    if (va == 0 or lenp == 0) return;
    var lb: [4]u8 = undefined;
    try p.readMem(lenp, &lb);
    const have = std.mem.readInt(u32, &lb, .little);
    var b: [28]u8 = @splat(0);
    var n: u32 = 0;
    if (family == AF_INET and isV4(&a.ip)) {
        std.mem.writeInt(u16, b[0..2], AF_INET, .little);
        std.mem.writeInt(u16, b[2..4], a.port, .big);
        @memcpy(b[4..8], a.ip[12..16]);
        n = 16;
    } else {
        std.mem.writeInt(u16, b[0..2], AF_INET6, .little);
        std.mem.writeInt(u16, b[2..4], a.port, .big);
        @memcpy(b[8..24], &a.ip);
        n = 28;
    }
    try p.writeMem(va, b[0..@min(n, have)]);
    std.mem.writeInt(u32, &lb, n, .little);
    try p.writeMem(lenp, &lb);
}

fn ctlMsg(fd: i32, comptime fmt: []const u8, args: anytype) i64 {
    var b: [160]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&b, fmt, args) catch return -E.INVAL;
    kc.sockCtl(fd, msg) catch return kerr();
    return 0;
}

fn connectCall(p: *Process, fd: i32, va: u64, len: u64) Err!i64 {
    if (unixOf(p, fd)) |u| return unixConnect(p, fd, u, va, len);
    const so = sockOf(p, fd) orelse return if (kc.fdInfo(fd)) |_| -E.NOTSOCK else |_| -E.BADF;
    const a = switch (try readSockaddr(p, va, len)) {
        .addr => |a| a,
        .unspec => return 0, // dissolving a UDP association isn't kept
        .err => |e| return e,
    };
    var tb: [96]u8 = undefined;
    const t = addrText(&tb, a);
    if (so.s.stype == SOCK_STREAM and so.s.connected) return -E.ISCONN;
    if (so.s.stype == SOCK_STREAM and flagsOf(p, fd).nonblock) {
        const r = ctlMsg(fd, "nbconnect {s}", .{t});
        if (r < 0) return r;
        so.s.connected = true;
        return -E.INPROGRESS;
    }
    const r = ctlMsg(fd, "connect {s}", .{t});
    if (r < 0) return r;
    so.s.connected = true;
    if (so.s.stype == SOCK_DGRAM) so.s.peer = a;
    return 0;
}

fn bindCall(p: *Process, fd: i32, va: u64, len: u64) Err!i64 {
    if (unixOf(p, fd)) |u| return if (u.netlink) 0 else unixBind(p, u, va, len);
    const so = sockOf(p, fd) orelse return if (kc.fdInfo(fd)) |_| -E.NOTSOCK else |_| -E.BADF;
    const a = switch (try readSockaddr(p, va, len)) {
        .addr => |a| a,
        else => return -E.INVAL,
    };
    var tb: [96]u8 = undefined;
    // devip announces on every address for a zero one, which is IPv6 (and
    // IPv4 too, unless IPV6_V6ONLY) on a host that has IPv6. An IPv4
    // socket's wildcard is named, so it stays IPv4 and doesn't collide
    // with an IPv6 one on the same port.
    const any = std.mem.allEqual(u8, a.ip[0..10], 0) and (std.mem.allEqual(u8, a.ip[10..], 0) or (isV4(&a.ip) and std.mem.allEqual(u8, a.ip[12..], 0)));
    const t = if (any and so.s.family == AF_INET)
        std.fmt.bufPrint(&tb, "0.0.0.0!{d}", .{a.port}) catch unreachable
    else if (any)
        std.fmt.bufPrint(&tb, "{d}", .{a.port}) catch unreachable
    else
        addrText(&tb, a);
    @memcpy(so.s.bound[0..t.len], t);
    so.s.bound_len = @intCast(t.len);
    // A datagram socket receives once bound; a stream one announces at listen.
    if (so.s.stype != SOCK_DGRAM) return 0;
    const r = ctlMsg(fd, "announce {s}", .{t});
    // A client's bind to any address and port 0, as busybox nslookup's
    // before its connect, needs no announce: where the policy refuses
    // one (--net outbound), the socket stays unbound and its connect or
    // first sendto binds it, as Linux's do (design/0050-linux-net.md).
    if (r == -E.ACCES and any and a.port == 0) {
        so.s.bound_len = 0;
        return 0;
    }
    return r;
}

fn listenCall(p: *Process, fd: i32) Err!i64 {
    if (unixOf(p, fd)) |u| return unixListen(p, fd, u);
    const so = sockOf(p, fd) orelse return if (kc.fdInfo(fd)) |_| -E.NOTSOCK else |_| -E.BADF;
    if (so.s.stype != SOCK_STREAM) return -E.OPNOTSUPP;
    if (so.s.listening) return 0;
    const t = if (so.s.bound_len > 0) so.s.bound[0..so.s.bound_len] else if (so.s.family == AF_INET) "0.0.0.0!0" else "0";
    const r = ctlMsg(fd, "announce {s}", .{t});
    if (r < 0) return r;
    so.s.listening = true;
    return 0;
}

/// Waits, interruptibly, until fd has one of `events` (or an error or
/// hangup). Returns 0, or -EINTR.
fn waitReady(fd: i32, events: u32) i64 {
    var pf = [1]kc.PollFd{.{ .fd = fd, .events = @intCast(events), .revents = 0 }};
    _ = kc.poll(&pf, -1, null) catch return -E.INTR;
    return 0;
}

fn acceptCall(p: *Process, fd: i32, addr: u64, lenp: u64, flags: u32) Err!i64 {
    if (unixOf(p, fd)) |u| return unixAccept(p, fd, u, addr, lenp, flags);
    const so = sockOf(p, fd) orelse return if (kc.fdInfo(fd)) |_| -E.NOTSOCK else |_| -E.BADF;
    if (!so.s.listening) return -E.INVAL;
    const family = so.s.family;
    const conv = so.conv;
    // devip's listen open waits in the host's accept, which a note can't
    // interrupt, so it's opened only once a connection is pending.
    if (flagsOf(p, fd).nonblock) {
        const r = kc.fdReady(fd, kc.POLLIN) orelse return -E.BADF;
        if (r & kc.POLLIN == 0) return -E.AGAIN;
    } else {
        const w = waitReady(fd, kc.POLLIN);
        if (w < 0) return w;
    }
    var b: [64]u8 = undefined;
    const listen = std.fmt.bufPrintZ(&b, "#I/{s}/{d}/listen", .{ protoName(conv), conv & 0xfff }) catch unreachable;
    const nfd = switch (try openConv(p, listen, conv >> 12, flags & SOCK_CLOEXEC != 0)) {
        .fd => |f| f,
        .err => |e| return e,
    };
    const nconv = convOf(nfd) orelse return -E.IO;
    {
        p.g.lockSpin();
        defer p.g.lock.unlock();
        p.g.putSock(nconv, .{ .family = family, .stype = SOCK_STREAM, .connected = true }) catch return -E.NOMEM;
    }
    if (flags & SOCK_NONBLOCK != 0) setFlags(p, nfd, .{ .nonblock = true });
    if (addr != 0) {
        var rb: [128]u8 = undefined;
        const t = convRead(nconv, "remote", &rb) orelse "";
        try writeSockaddr(p, addr, lenp, family, parseAddrText(t));
    }
    return nfd;
}

fn sockName(p: *Process, fd: i32, va: u64, lenp: u64, peer: bool) Err!i64 {
    if (unixOf(p, fd)) |u| {
        if (u.netlink) {
            // The kernel's port id is 0; a socket's is its tgid.
            try writeNlAddr(p, va, lenp, if (peer) 0 else p.g.tgid);
            return 0;
        }
        if (peer and u.state != .connected) return -E.NOTCONN;
        try writeUnixAddr(p, va, lenp, if (peer) u.peer[0..u.peer_len] else u.path[0..u.path_len]);
        return 0;
    }
    const so = sockOf(p, fd) orelse return if (kc.fdInfo(fd)) |_| -E.NOTSOCK else |_| -E.BADF;
    if (peer and !so.s.connected) return -E.NOTCONN;
    var rb: [128]u8 = undefined;
    const t = convRead(so.conv, if (peer) "remote" else "local", &rb) orelse return -E.IO;
    try writeSockaddr(p, va, lenp, so.s.family, parseAddrText(t));
    return 0;
}

fn shutdownCall(p: *Process, fd: i32, how: u32) Err!i64 {
    if (unixOf(p, fd)) |u| return if (u.state != .connected) -E.NOTCONN else if (how > 2) -E.INVAL else 0;
    const so = sockOf(p, fd) orelse return if (kc.fdInfo(fd)) |_| -E.NOTSOCK else |_| -E.BADF;
    if (!so.s.connected) return -E.NOTCONN;
    const h = switch (how) {
        0 => "rd",
        1 => "wr",
        2 => "rdwr",
        else => return -E.INVAL,
    };
    return ctlMsg(fd, "shutdown {s}", .{h});
}

fn setsockopt(p: *Process, fd: i32, level: u32, name: u32, va: u64, len: u64) Err!i64 {
    if (unixOf(p, fd) != null) return 0;
    const so = sockOf(p, fd) orelse return if (kc.fdInfo(fd)) |_| -E.NOTSOCK else |_| -E.BADF;
    var v: i32 = 0;
    if (len >= 4) {
        var b: [4]u8 = undefined;
        try p.readMem(va, &b);
        v = std.mem.readInt(i32, &b, .little);
    } else if (len > 0) {
        var b: [1]u8 = undefined;
        try p.readMem(va, &b);
        v = b[0];
    }
    so.s.setOpt(level, name, v);
    const ctl: ?[]const u8 = switch (level) {
        SOL_SOCKET => switch (name) {
            SO_REUSEADDR => "reuseaddr",
            SO_KEEPALIVE => "keepalive",
            SO_RCVBUF => "rcvbuf",
            SO_SNDBUF => "sndbuf",
            else => null,
        },
        IPPROTO_TCP => switch (name) {
            TCP_NODELAY => "nodelay",
            TCP_KEEPIDLE => "keepidle",
            TCP_KEEPINTVL => "keepintvl",
            TCP_KEEPCNT => "keepcnt",
            else => null,
        },
        IPPROTO_IPV6 => if (name == IPV6_V6ONLY) "v6only" else null,
        else => null,
    };
    // Options h9 can't honour are kept, so getsockopt reports them.
    if (ctl) |n| _ = ctlMsg(fd, "sockopt {s} {d}", .{ n, v });
    return 0;
}

fn getsockopt(p: *Process, fd: i32, level: u32, name: u32, va: u64, lenp: u64) Err!i64 {
    if (unixOf(p, fd)) |u| return unixGetsockopt(p, u, level, name, va, lenp);
    const so = sockOf(p, fd) orelse return if (kc.fdInfo(fd)) |_| -E.NOTSOCK else |_| -E.BADF;
    const v: i32 = switch (level) {
        SOL_SOCKET => switch (name) {
            SO_ERROR => @intCast(kc.soError(fd)),
            SO_TYPE => so.s.stype,
            SO_DOMAIN => so.s.family,
            SO_PROTOCOL => if (so.s.stype == SOCK_STREAM) IPPROTO_TCP else 17,
            SO_ACCEPTCONN => @intFromBool(so.s.listening),
            SO_SNDBUF, SO_RCVBUF => so.s.opt(level, name) orelse 212992,
            else => so.s.opt(level, name) orelse 0,
        },
        else => so.s.opt(level, name) orelse 0,
    };
    var lb: [4]u8 = undefined;
    try p.readMem(lenp, &lb);
    const have = std.mem.readInt(u32, &lb, .little);
    var b: [4]u8 = undefined;
    std.mem.writeInt(i32, &b, v, .little);
    try p.writeMem(va, b[0..@min(4, have)]);
    std.mem.writeInt(u32, &lb, 4, .little);
    try p.writeMem(lenp, &lb);
    return 0;
}

/// Gathers or scatters a msghdr's iovecs through one buffer.
const MsgHdr = struct {
    name: u64,
    namelen: u32,
    iov: u64,
    iovlen: u64,
    control: u64,
    controllen: u64,
    flags_va: u64,

    fn read(p: *Process, va: u64) Err!MsgHdr {
        var b: [56]u8 = undefined;
        try p.readMem(va, &b);
        return .{
            .name = std.mem.readInt(u64, b[0..8], .little),
            .namelen = std.mem.readInt(u32, b[8..12], .little),
            .iov = std.mem.readInt(u64, b[16..24], .little),
            .iovlen = std.mem.readInt(u64, b[24..32], .little),
            .control = std.mem.readInt(u64, b[32..40], .little),
            .controllen = std.mem.readInt(u64, b[40..48], .little),
            .flags_va = va + 48,
        };
    }

    fn total(m: MsgHdr, p: *Process) Err!u64 {
        if (m.iovlen > 1024) return error.TooBig;
        var n: u64 = 0;
        var i: u64 = 0;
        while (i < m.iovlen) : (i += 1) n += try p.readU64(m.iov + 16 * i + 8);
        return n;
    }
};

fn sendCall(p: *Process, fd: i32, buf_va: u64, len_in: u64, flags: u32, to_va: u64, to_len: u64) Err!i64 {
    const so = sockOf(p, fd) orelse {
        // send on a pipe from socketpair, or a Unix socket, is a write.
        // A netlink socket's too: rw takes its request.
        if (kc.fdInfo(fd) catch null) |info| if (info.dc == '|') return rw(p, fd, buf_va, len_in, -1, .write);
        return if (kc.fdInfo(fd)) |_| -E.NOTSOCK else |_| -E.BADF;
    };
    const len = @min(len_in, 1 << 20);
    const tmp = p.gpa.alloc(u8, len) catch return -E.NOMEM;
    defer p.gpa.free(tmp);
    try p.readMem(buf_va, tmp);
    return sendBuf(p, fd, so.s, tmp, flags, to_va, to_len);
}

fn sendBuf(p: *Process, fd: i32, s: *Sock, data: []const u8, flags: u32, to_va: u64, to_len: u64) Err!i64 {
    var to: ?kc.NetAddr = null;
    if (to_va != 0 and s.stype == SOCK_DGRAM) {
        to = switch (try readSockaddr(p, to_va, to_len)) {
            .addr => |a| a,
            .unspec => null,
            .err => |e| return e,
        };
        // An unbound, unconnected datagram socket has no host socket yet:
        // connect it to the first destination (allowed wherever a
        // connect is, unlike a bind).
        if (to != null and !s.connected and s.bound_len == 0) {
            var tb: [96]u8 = undefined;
            const r = ctlMsg(fd, "connect {s}", .{addrText(&tb, to.?)});
            if (r < 0) return r;
            s.connected = true;
            s.peer = to;
            to = null;
        } else if (to != null and s.connected) {
            if (s.peer) |pa| if (std.meta.eql(pa, to.?)) {
                to = null;
            };
        }
    } else if (!s.connected and s.stype == SOCK_STREAM) return -E.PIPE;
    const dontwait = flags & MSG_DONTWAIT != 0 or flagsOf(p, fd).nonblock;
    while (true) {
        if (!dontwait) {
            const w = waitReady(fd, kc.POLLOUT);
            if (w < 0) return w;
        }
        const r = kc.sockSend(fd, data, true, if (to) |*t| t else null);
        if (r == -E.AGAIN and !dontwait) continue;
        if (r == -E.PIPE and flags & MSG_NOSIGNAL == 0) _ = p.host.kill(p.host.ctx, p, p.pid, sig.SIGPIPE, .{});
        return r;
    }
}

fn recvCall(p: *Process, fd: i32, buf_va: u64, len_in: u64, flags: u32, from_va: u64, from_len: u64) Err!i64 {
    const so = sockOf(p, fd) orelse {
        if (kc.fdInfo(fd) catch null) |info| if (info.dc == '|') {
            const r = try rw(p, fd, buf_va, len_in, -1, .read);
            if (r >= 0 and from_va != 0) if (unixOf(p, fd)) |u| if (u.netlink) try writeNlAddr(p, from_va, from_len, 0);
            return r;
        };
        return if (kc.fdInfo(fd)) |_| -E.NOTSOCK else |_| -E.BADF;
    };
    const len = @min(len_in, 1 << 20);
    const tmp = p.gpa.alloc(u8, len) catch return -E.NOMEM;
    defer p.gpa.free(tmp);
    var from: kc.NetAddr = .{};
    const r = recvBuf(p, fd, tmp, flags, &from);
    if (r < 0) return r;
    const n: usize = @intCast(@min(r, @as(i64, @intCast(len))));
    try p.writeMem(buf_va, tmp[0..n]);
    if (from_va != 0) try writeSockaddr(p, from_va, from_len, so.s.family, from);
    return if (flags & MSG_TRUNC != 0) r else @intCast(n);
}

fn recvBuf(p: *Process, fd: i32, buf: []u8, flags: u32, from: *kc.NetAddr) i64 {
    const dontwait = flags & MSG_DONTWAIT != 0 or flagsOf(p, fd).nonblock;
    const peek = flags & MSG_PEEK != 0;
    var got: usize = 0;
    while (true) {
        // Wait here, where a signal can interrupt, then take what's there.
        if (!dontwait) {
            const w = waitReady(fd, kc.POLLIN);
            if (w < 0) return if (got > 0) @intCast(got) else w;
        }
        const r = kc.sockRecv(fd, buf[got..], peek, true, from);
        if (r == -E.AGAIN and !dontwait) continue;
        if (r < 0) return if (got > 0) @intCast(got) else r;
        got += @intCast(r);
        if (flags & MSG_WAITALL == 0 or r == 0 or got == buf.len or peek) return @intCast(got);
    }
}

fn sendmsg(p: *Process, fd: i32, msg_va: u64, flags: u32) Err!i64 {
    const so = sockOf(p, fd) orelse {
        if (kc.fdInfo(fd) catch null) |info| if (info.dc == '|') {
            const m = try MsgHdr.read(p, msg_va);
            if (unixOf(p, fd)) |u| if (u.netlink) {
                const total = @min(try m.total(p), 1 << 16);
                const tmp = p.gpa.alloc(u8, total) catch return -E.NOMEM;
                defer p.gpa.free(tmp);
                var off: usize = 0;
                var i: u64 = 0;
                while (i < m.iovlen and off < total) : (i += 1) {
                    const base = try p.readU64(m.iov + 16 * i);
                    const l = @min(try p.readU64(m.iov + 16 * i + 8), total - off);
                    try p.readMem(base, tmp[off .. off + l]);
                    off += l;
                }
                return netlinkSend(p, fd, tmp[0..off]);
            };
            return rwv(p, fd, m.iov, m.iovlen, -1, .write);
        };
        return if (kc.fdInfo(fd)) |_| -E.NOTSOCK else |_| -E.BADF;
    };
    const m = try MsgHdr.read(p, msg_va);
    const total = @min(try m.total(p), 1 << 20);
    const tmp = p.gpa.alloc(u8, total) catch return -E.NOMEM;
    defer p.gpa.free(tmp);
    var off: usize = 0;
    var i: u64 = 0;
    while (i < m.iovlen and off < total) : (i += 1) {
        const base = try p.readU64(m.iov + 16 * i);
        const l = @min(try p.readU64(m.iov + 16 * i + 8), total - off);
        try p.readMem(base, tmp[off .. off + l]);
        off += l;
    }
    return sendBuf(p, fd, so.s, tmp[0..off], flags, m.name, m.namelen);
}

fn recvmsg(p: *Process, fd: i32, msg_va: u64, flags: u32) Err!i64 {
    const so = sockOf(p, fd) orelse {
        if (kc.fdInfo(fd) catch null) |info| if (info.dc == '|') {
            const m = try MsgHdr.read(p, msg_va);
            try p.writeU64(msg_va + 40, 0); // no control data
            const r = try rwv(p, fd, m.iov, m.iovlen, -1, .read);
            if (r >= 0 and m.name != 0) if (unixOf(p, fd)) |u| if (u.netlink) try writeNlAddr(p, m.name, msg_va + 8, 0);
            return r;
        };
        return if (kc.fdInfo(fd)) |_| -E.NOTSOCK else |_| -E.BADF;
    };
    const m = try MsgHdr.read(p, msg_va);
    const total = @min(try m.total(p), 1 << 20);
    const tmp = p.gpa.alloc(u8, total) catch return -E.NOMEM;
    defer p.gpa.free(tmp);
    var from: kc.NetAddr = .{};
    const r = recvBuf(p, fd, tmp, flags, &from);
    if (r < 0) return r;
    const n: usize = @intCast(r);
    var off: usize = 0;
    var i: u64 = 0;
    while (i < m.iovlen and off < n) : (i += 1) {
        const base = try p.readU64(m.iov + 16 * i);
        const l = @min(try p.readU64(m.iov + 16 * i + 8), n - off);
        try p.writeMem(base, tmp[off .. off + l]);
        off += l;
    }
    if (m.name != 0) {
        // msg_namelen is in the msghdr itself.
        try writeSockaddr(p, m.name, msg_va + 8, so.s.family, from);
    }
    try p.writeU64(msg_va + 40, 0); // msg_controllen: no control data
    try p.writeU32(m.flags_va, 0);
    return r;
}

// Named AF_UNIX sockets, on pipes and /srv (devsrv, design/0008). A
// socket is a pipe end in its fd from the start, so poll and epoll see
// it. A listening socket's fd is the read end of a pipe whose write end
// is posted in #s under the bound file's identity (`lx.DEV.QPATH`, or
// `lxa.HEX` for an abstract name). connect makes a pipe for the
// connection, posts one end as `lxc.PID.N`, writes that name down the
// listener's pipe, and keeps the other end as its fd; accept reads a
// name, opens the post and removes it. The bound file is an empty file
// that stands for the socket, so a connect finds it by path. Posts are
// per machine, so sockets connect only within one machine.

pub const USock = struct {
    stype: u8,
    /// An AF_NETLINK socket (netlinkSocket) rather than a Unix one.
    netlink: bool = false,
    state: enum { fresh, bound, listening, connected } = .fresh,
    /// The #s name a connect looks for, once bound.
    key: [48]u8 = undefined,
    key_len: u8 = 0,
    /// sun_path as bound (local) and as the peer's (for getpeername).
    path: [108]u8 = undefined,
    path_len: u8 = 0,
    peer: [108]u8 = undefined,
    peer_len: u8 = 0,
};

var unix_conns: std.atomic.Value(u32) = .init(0);
/// The size of a connect's record on a listener's pipe: a post's name,
/// NUL-padded.
const unix_rec = 32;

fn unixOf(p: *Process, fd: i32) ?*USock {
    const info = kc.fdInfo(fd) catch return null;
    if (info.dc != '|') return null;
    p.g.lockSpin();
    defer p.g.lock.unlock();
    return p.g.usocks.get(info.qpath);
}

/// Registers fd's pipe end as a Unix socket.
fn unixPut(p: *Process, fd: i32, u: USock) i64 {
    const info = kc.fdInfo(fd) catch return -E.BADF;
    const n = p.gpa.create(USock) catch return -E.NOMEM;
    n.* = u;
    p.g.lockSpin();
    defer p.g.lock.unlock();
    p.g.usocks.put(p.gpa, info.qpath, n) catch {
        p.gpa.destroy(n);
        return -E.NOMEM;
    };
    return 0;
}

/// Puts the pipe end `from` in fd's place, keeping fd's socket state and
/// close-on-exec, and closes `from`.
fn unixSwap(p: *Process, fd: i32, from: u31) i64 {
    const old = kc.fdInfo(fd) catch return -E.BADF;
    const cexec = old.cexec;
    _ = kern.dup(from, fd) catch return kerr();
    kern.close(from) catch {};
    kc.setCloexec(@intCast(fd), cexec) catch {};
    const new = kc.fdInfo(fd) catch return -E.BADF;
    p.g.lockSpin();
    defer p.g.lock.unlock();
    const u = p.g.usocks.fetchRemove(old.qpath) orelse return -E.BADF;
    p.g.usocks.put(p.gpa, new.qpath, u.value) catch {
        p.gpa.destroy(u.value);
        return -E.NOMEM;
    };
    return 0;
}

/// AF_NETLINK (netlink.zig): a pipe end, as a Unix socket is, so close,
/// fork, poll and reads work as for any pipe. A send's answers are
/// written to a new pipe whose read end replaces the fd's, one message
/// to a write, so each read takes one datagram, then EOF.
fn netlinkSocket(p: *Process, type_in: u32, protocol: u32) i64 {
    const st = type_in & 0xf;
    const SOCK_RAW = 3;
    if (st != SOCK_RAW and st != SOCK_DGRAM) return -E.PROTONOSUPPORT;
    if (protocol != netlink.NETLINK_ROUTE) return -E.PROTONOSUPPORT;
    const fds = kern.pipe() catch return kerr();
    kern.close(fds[1]) catch {};
    const fd = fds[0];
    if (type_in & SOCK_CLOEXEC != 0) kc.setCloexec(fd, true) catch {};
    if (type_in & SOCK_NONBLOCK != 0) setFlags(p, fd, .{ .nonblock = true });
    const r = unixPut(p, fd, .{ .stype = @intCast(st), .netlink = true, .state = .connected });
    if (r < 0) {
        kern.close(fd) catch {};
        return r;
    }
    return fd;
}

fn netlinkSend(p: *Process, fd: i32, req: []const u8) Err!i64 {
    var hb: [32]kc.IfAddr = undefined;
    var ab: [32]netlink.Addr = undefined;
    var lb: [2]netlink.Addr = undefined;
    // The host's interfaces where the machine has a network (#I isn't
    // masked) and the host lists them; loopback otherwise.
    var addrs: []const netlink.Addr = netlink.loopback(kc.hostHasV6(), &lb);
    if (kern.open("#I", kern.OREAD)) |ip| {
        kern.close(ip) catch {};
        const host = kc.hostIfAddrs(&hb);
        for (host, 0..) |*h, i| ab[i] = .{
            // Linux calls loopback lo, where macOS and the BSDs say lo0
            // and Windows a long description; programs look for lo.
            .name = if (h.loopback != 0) "lo" else std.mem.sliceTo(&h.name, 0),
            .index = @intCast(h.index),
            .up = h.isup != 0,
            .loopback = h.loopback != 0,
            .mtu = @intCast(h.mtu),
            .ip = h.addr,
            .prefix = @intCast(h.prefix),
        };
        if (host.len > 0) addrs = ab[0..host.len];
    } else |_| {}
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |m| p.gpa.free(m);
        out.deinit(p.gpa);
    }
    netlink.answer(p.gpa, req, p.g.tgid, addrs, &out) catch return -E.NOMEM;
    const fds = kern.pipe() catch return kerr();
    for (out.items) |m| _ = kern.pwrite(fds[1], m, -1) catch {
        kern.close(fds[0]) catch {};
        kern.close(fds[1]) catch {};
        return kerr();
    };
    kern.close(fds[1]) catch {};
    const r = unixSwap(p, fd, fds[0]);
    if (r < 0) return r;
    return @intCast(req.len);
}

/// A sockaddr_nl: family, pad, port id, groups.
fn writeNlAddr(p: *Process, va: u64, lenp: u64, pid: u32) Err!void {
    if (va == 0 or lenp == 0) return;
    var lb: [4]u8 = undefined;
    try p.readMem(lenp, &lb);
    const have = std.mem.readInt(u32, &lb, .little);
    var b: [12]u8 = @splat(0);
    std.mem.writeInt(u16, b[0..2], netlink.AF_NETLINK, .little);
    std.mem.writeInt(u32, b[4..8], pid, .little);
    try p.writeMem(va, b[0..@min(12, have)]);
    std.mem.writeInt(u32, &lb, 12, .little);
    try p.writeMem(lenp, &lb);
}

fn unixSocket(p: *Process, type_in: u32) i64 {
    const st = type_in & 0xf;
    // SOCK_SEQPACKET (5) too: a pipe keeps write boundaries.
    if (st != SOCK_STREAM and st != SOCK_DGRAM and st != 5) return -E.PROTONOSUPPORT;
    const fds = kern.pipe() catch return kerr();
    kern.close(fds[1]) catch {};
    const fd = fds[0];
    if (type_in & SOCK_CLOEXEC != 0) kc.setCloexec(fd, true) catch {};
    if (type_in & SOCK_NONBLOCK != 0) setFlags(p, fd, .{ .nonblock = true });
    const r = unixPut(p, fd, .{ .stype = @intCast(st) });
    if (r < 0) {
        kern.close(fd) catch {};
        return r;
    }
    return fd;
}

/// A sockaddr_un's path: a NUL-terminated name, or an abstract one
/// (leading NUL) as is.
fn readUnixPath(p: *Process, va: u64, len: u64, buf: *[108]u8) Err!union(enum) { path: []const u8, err: i64 } {
    if (len < 3 or len > 110) return .{ .err = -E.INVAL };
    var fam: [2]u8 = undefined;
    try p.readMem(va, &fam);
    if (std.mem.readInt(u16, &fam, .little) != AF_UNIX) return .{ .err = -E.AFNOSUPPORT };
    const n: usize = @intCast(len - 2);
    try p.readMem(va + 2, buf[0..n]);
    if (buf[0] == 0) return .{ .path = buf[0..n] };
    return .{ .path = buf[0 .. std.mem.indexOfScalar(u8, buf[0..n], 0) orelse n] };
}

/// The #s name for a socket path: the bound file's identity.
fn unixKey(path: []const u8, out: []u8, create: bool) union(enum) { key: []const u8, err: i64 } {
    if (path[0] == 0) {
        var w: std.Io.Writer = .fixed(out);
        w.writeAll("lxa.") catch {};
        for (path[1..@min(path.len, 20)]) |ch| w.print("{x:0>2}", .{ch}) catch {};
        return .{ .key = w.buffered() };
    }
    var zb: [112]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{path}) catch return .{ .err = -E.NAMETOOLONG };
    const OEXCL = 0x1000;
    const fd = (if (create) kern.create(z, kern.OREAD | OEXCL, 0o777) else kern.open(z, kern.OREAD)) catch {
        const e = kerr();
        return .{ .err = if (create and e == -E.EXIST) -E.ADDRINUSE else e };
    };
    defer kern.close(fd) catch {};
    const info = kc.fdInfo(fd) catch return .{ .err = -E.IO };
    return .{ .key = std.fmt.bufPrint(out, "lx.{d}.{d}.{d}", .{ info.dc, info.dev, info.qpath }) catch unreachable };
}

/// Posts fd in #s as `name`.
fn srvPost(name: []const u8, fd: u31) i64 {
    var b: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&b, "#s/{s}", .{name}) catch return -E.NAMETOOLONG;
    const sfd = kern.create(path, kern.OWRITE, 0o600) catch return kerr();
    defer kern.close(sfd) catch {};
    var nb: [16]u8 = undefined;
    const t = std.fmt.bufPrint(&nb, "{d}", .{fd}) catch unreachable;
    _ = kern.pwrite(sfd, t, -1) catch return kerr();
    return 0;
}

fn srvRemove(name: []const u8) void {
    var b: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&b, "#s/{s}", .{name}) catch return;
    kern.remove(path) catch {};
}

fn unixBind(p: *Process, u: *USock, va: u64, len: u64) Err!i64 {
    if (u.state != .fresh) return -E.INVAL;
    var pb: [108]u8 = undefined;
    const path = switch (try readUnixPath(p, va, len, &pb)) {
        .path => |x| x,
        .err => |e| return e,
    };
    var kb: [48]u8 = undefined;
    const key = switch (unixKey(path, &kb, true)) {
        .key => |k| k,
        .err => |e| return e,
    };
    if (path[0] == 0) {
        // An abstract name is held from the bind by an empty post,
        // which devsrv's create keeps unique; the listen fills it.
        var sb: [64]u8 = undefined;
        const sfd = kern.create(std.fmt.bufPrintZ(&sb, "#s/{s}", .{key}) catch return -E.NAMETOOLONG, kern.OWRITE, 0o600) catch return -E.ADDRINUSE;
        kern.close(sfd) catch {};
    }
    @memcpy(u.key[0..key.len], key);
    u.key_len = @intCast(key.len);
    @memcpy(u.path[0..path.len], path);
    u.path_len = @intCast(path.len);
    u.state = .bound;
    return 0;
}

fn unixListen(p: *Process, fd: i32, u: *USock) i64 {
    if (u.stype == SOCK_DGRAM) return -E.OPNOTSUPP;
    if (u.state == .listening) return 0;
    if (u.state != .bound) return -E.INVAL;
    const l = kern.pipe() catch return kerr();
    const key = u.key[0..u.key_len];
    // A post left by a socket on a file whose identity was reused.
    srvRemove(key);
    var r = srvPost(key, l[1]);
    kern.close(l[1]) catch {};
    if (r < 0) {
        kern.close(l[0]) catch {};
        return r;
    }
    u.state = .listening;
    r = unixSwap(p, fd, l[0]);
    if (r < 0) srvRemove(key);
    return r;
}

fn unixConnect(p: *Process, fd: i32, u: *USock, va: u64, len: u64) Err!i64 {
    if (u.state == .connected) return -E.ISCONN;
    if (u.state == .listening) return -E.INVAL;
    var pb: [108]u8 = undefined;
    const path = switch (try readUnixPath(p, va, len, &pb)) {
        .path => |x| x,
        .err => |e| return e,
    };
    var kb: [48]u8 = undefined;
    const key = switch (unixKey(path, &kb, false)) {
        .key => |k| k,
        .err => |e| return e,
    };
    var sb: [64]u8 = undefined;
    const lf = kern.open(std.fmt.bufPrintZ(&sb, "#s/{s}", .{key}) catch return -E.NAMETOOLONG, kern.OWRITE) catch return -E.CONNREFUSED;
    defer kern.close(lf) catch {};
    const c = kern.pipe() catch return kerr();
    var nb: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&nb, "lxc.{d}.{d}", .{ p.tgid(), unix_conns.fetchAdd(1, .monotonic) }) catch unreachable;
    const r = srvPost(name, c[1]);
    kern.close(c[1]) catch {};
    if (r < 0) {
        kern.close(c[0]) catch {};
        return r;
    }
    // Connects from several threads or processes write to one pipe, and
    // a read may join writes, so each name goes as one fixed-size record.
    var rec: [unix_rec]u8 = @splat(0);
    @memcpy(rec[0..name.len], name);
    _ = kern.pwrite(lf, &rec, -1) catch {
        srvRemove(name);
        kern.close(c[0]) catch {};
        return -E.CONNREFUSED;
    };
    @memcpy(u.peer[0..path.len], path);
    u.peer_len = @intCast(path.len);
    u.state = .connected;
    return unixSwap(p, fd, c[0]);
}

fn unixAccept(p: *Process, fd: i32, u: *USock, addr: u64, lenp: u64, flags: u32) Err!i64 {
    if (u.state != .listening) return -E.INVAL;
    if (flagsOf(p, fd).nonblock) {
        const r = kc.fdReady(fd, kc.POLLIN) orelse return -E.BADF;
        if (r & kc.POLLIN == 0) return -E.AGAIN;
    } else {
        const w = waitReady(fd, kc.POLLIN);
        if (w < 0) return w;
    }
    var nb: [unix_rec]u8 = undefined;
    var n: usize = 0;
    while (n < nb.len) {
        const m = kern.pread(@intCast(fd), nb[n..], -1) catch return kerr();
        if (m == 0) return -E.CONNABORTED;
        n += m;
    }
    const name = nb[0 .. std.mem.indexOfScalar(u8, &nb, 0) orelse nb.len];
    var sb: [80]u8 = undefined;
    const nfd = kern.open(std.fmt.bufPrintZ(&sb, "#s/{s}", .{name}) catch return -E.IO, kern.ORDWR | if (flags & SOCK_CLOEXEC != 0) @as(c_int, OCEXEC) else 0) catch return -E.CONNABORTED;
    srvRemove(name);
    var nu: USock = .{ .stype = u.stype, .state = .connected };
    @memcpy(nu.path[0..u.path_len], u.path[0..u.path_len]);
    nu.path_len = u.path_len;
    const r = unixPut(p, nfd, nu);
    if (r < 0) {
        kern.close(nfd) catch {};
        return r;
    }
    if (flags & SOCK_NONBLOCK != 0) setFlags(p, nfd, .{ .nonblock = true });
    // The connecting socket is unnamed.
    if (addr != 0) try writeUnixAddr(p, addr, lenp, "");
    return nfd;
}

/// Writes a sockaddr_un, truncated to *lenp, and its length to *lenp.
fn writeUnixAddr(p: *Process, va: u64, lenp: u64, path: []const u8) Err!void {
    if (va == 0 or lenp == 0) return;
    var lb: [4]u8 = undefined;
    try p.readMem(lenp, &lb);
    const have = std.mem.readInt(u32, &lb, .little);
    var b: [110]u8 = @splat(0);
    std.mem.writeInt(u16, b[0..2], AF_UNIX, .little);
    @memcpy(b[2..][0..path.len], path);
    // A named path's length counts its NUL; an abstract one's doesn't.
    const n: u32 = @intCast(2 + path.len + @intFromBool(path.len > 0 and path[0] != 0));
    try p.writeMem(va, b[0..@min(n, have)]);
    std.mem.writeInt(u32, &lb, n, .little);
    try p.writeMem(lenp, &lb);
}

fn unixGetsockopt(p: *Process, u: *USock, level: u32, name: u32, va: u64, lenp: u64) Err!i64 {
    const SO_PEERCRED = 17;
    var b: [12]u8 = @splat(0);
    var n: u32 = 4;
    if (level == SOL_SOCKET and name == SO_PEERCRED) {
        // The peer is in this machine; its ids aren't known, so the
        // caller's stand in, as for a peer of the same user.
        std.mem.writeInt(u32, b[4..8], p.cred.uid[1], .little);
        std.mem.writeInt(u32, b[8..12], p.cred.gid[1], .little);
        n = 12;
    } else {
        const v: i32 = if (level != SOL_SOCKET) 0 else switch (name) {
            SO_TYPE => u.stype,
            SO_DOMAIN => AF_UNIX,
            SO_ACCEPTCONN => @intFromBool(u.state == .listening),
            SO_SNDBUF, SO_RCVBUF => 212992,
            else => 0,
        };
        std.mem.writeInt(i32, b[0..4], v, .little);
    }
    var lb: [4]u8 = undefined;
    try p.readMem(lenp, &lb);
    const have = std.mem.readInt(u32, &lb, .little);
    try p.writeMem(va, b[0..@min(n, have)]);
    std.mem.writeInt(u32, &lb, n, .little);
    try p.writeMem(lenp, &lb);
    return 0;
}

/// fd is closing: a listening socket's last fd takes its post away, so a
/// connect is refused rather than writing to a pipe no one reads, and
/// an abstract name is freed.
fn unixClosed(p: *Process, fd: i32) void {
    const info = kc.fdInfo(fd) catch return;
    if (info.dc != '|') return;
    var key: [48]u8 = undefined;
    var key_len: usize = 0;
    {
        p.g.lockSpin();
        defer p.g.lock.unlock();
        const u = p.g.usocks.get(info.qpath) orelse return;
        if (kc.fdChan(fd)) |ch| if (ch.refs > 1) return;
        if (u.state == .listening or (u.state == .bound and u.path_len > 0 and u.path[0] == 0)) {
            @memcpy(key[0..u.key_len], u.key[0..u.key_len]);
            key_len = u.key_len;
        }
        _ = p.g.usocks.remove(info.qpath);
        p.gpa.destroy(u);
    }
    if (key_len > 0) srvRemove(key[0..key_len]);
}

// Readiness.

fn pollCall(p: *Process, s: Sys, c: Call) Err!i64 {
    const fds = c.a[0];
    if (c.a[1] > 4096) return -E.INVAL;
    const n: usize = @intCast(c.a[1]);
    var ms: i64 = -1;
    if (s == .poll) {
        const t = c.int(2);
        if (t >= 0) ms = t;
    } else if (c.a[2] != 0) {
        const ns = try readTimespec(p, c.a[2]);
        if (ns < 0) return -E.INVAL;
        ms = @divTrunc(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    }
    const pf = p.gpa.alloc(kc.PollFd, @max(n, 1)) catch return -E.NOMEM;
    defer p.gpa.free(pf);
    try p.readMem(fds, std.mem.sliceAsBytes(pf[0..n]));
    var old_mask: ?u64 = null;
    if (s == .ppoll and c.a[3] != 0) {
        old_mask = p.sig.mask;
        p.sig.mask = (try p.readU64(c.a[3])) & ~sig.unblockable;
    }
    defer if (old_mask) |m| {
        p.sig.mask = m;
    };
    const r = kc.poll(pf[0..n], ms, null) catch return -E.INTR;
    try p.writeMem(fds, std.mem.sliceAsBytes(pf[0..n]));
    return @intCast(r);
}

fn selectCall(p: *Process, s: Sys, c: Call) Err!i64 {
    const nfds: usize = @intCast(@min(c.uint(0), 1024));
    var ms: i64 = -1;
    if (c.a[4] != 0) {
        if (s == .select) {
            var b: [16]u8 = undefined;
            try p.readMem(c.a[4], &b);
            const sec = std.mem.readInt(i64, b[0..8], .little);
            const usec = std.mem.readInt(i64, b[8..16], .little);
            if (sec < 0 or usec < 0) return -E.INVAL;
            ms = sec * 1000 + @divTrunc(usec + 999, 1000);
        } else {
            const ns = try readTimespec(p, c.a[4]);
            if (ns < 0) return -E.INVAL;
            ms = @divTrunc(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        }
    }
    const words = (nfds + 63) / 64;
    var sets: [3][16]u64 = @splat(@splat(0));
    for (0..3) |k| {
        if (c.a[1 + k] == 0) continue;
        for (0..words) |w| sets[k][w] = try p.readU64(c.a[1 + k] + 8 * w);
    }
    var pf: [1024]kc.PollFd = undefined;
    var n: usize = 0;
    for (0..nfds) |fd| {
        const w = fd / 64;
        const bit = @as(u64, 1) << @intCast(fd % 64);
        var ev: i16 = 0;
        if (sets[0][w] & bit != 0) ev |= kc.POLLIN;
        if (sets[1][w] & bit != 0) ev |= kc.POLLOUT;
        if (sets[2][w] & bit != 0) ev |= kc.POLLPRI;
        if (ev == 0) continue;
        pf[n] = .{ .fd = @intCast(fd), .events = ev, .revents = 0 };
        n += 1;
    }
    var old_mask: ?u64 = null;
    if (s == .pselect6 and c.a[5] != 0) {
        const sigset = try p.readU64(c.a[5]);
        if (sigset != 0) {
            old_mask = p.sig.mask;
            p.sig.mask = (try p.readU64(sigset)) & ~sig.unblockable;
        }
    }
    defer if (old_mask) |m| {
        p.sig.mask = m;
    };
    _ = kc.poll(pf[0..n], ms, null) catch return -E.INTR;
    var out: [3][16]u64 = @splat(@splat(0));
    var ready: i64 = 0;
    for (pf[0..n]) |f| {
        if (f.revents & kc.POLLNVAL != 0) return -E.BADF;
        const fd: usize = @intCast(f.fd);
        const w = fd / 64;
        const bit = @as(u64, 1) << @intCast(fd % 64);
        if (f.events & kc.POLLIN != 0 and f.revents & (kc.POLLIN | kc.POLLHUP | kc.POLLERR) != 0) {
            out[0][w] |= bit;
            ready += 1;
        }
        if (f.events & kc.POLLOUT != 0 and f.revents & (kc.POLLOUT | kc.POLLERR) != 0) {
            out[1][w] |= bit;
            ready += 1;
        }
    }
    for (0..3) |k| {
        if (c.a[1 + k] == 0) continue;
        for (0..words) |w| try p.writeU64(c.a[1 + k] + 8 * w, out[k][w]);
    }
    if (s == .select and c.a[4] != 0) {
        // Linux updates the timeout; a program that loops on it sees time pass.
    }
    return ready;
}

// eventfd and epoll, on #ε instances (src/kern/linuxnet.c).

const EFD_SEMAPHORE = 1;
const ev_dc: u21 = 0x3b5; // 'ε'

fn eventfd(p: *Process, initval: u32, flags: u32) Err!i64 {
    const path: [:0]const u8 = if (flags & EFD_SEMAPHORE != 0) "#\u{3b5}/eventsem" else "#\u{3b5}/eventfd";
    const fd = kern.open(path, kern.ORDWR | if (flags & O_CLOEXEC != 0) @as(c_int, OCEXEC) else 0) catch return kerr();
    if (initval != 0) {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, initval, .little);
        _ = kern.pwrite(fd, &b, -1) catch {};
    }
    if (flags & O_NONBLOCK != 0) setFlags(p, fd, .{ .nonblock = true });
    return fd;
}

// signalfd: an eventfd counter, nonzero while a signal the fd's mask
// names is pending, which the process model posts to (`signalPosted`)
// as a note it can't deliver comes in; reads take the signals.

pub const SigFd = struct {
    fd: i32,
    mask: u64,
    /// The counter is nonzero.
    armed: bool = false,
};

fn sigfdOf(p: *Process, qpath: u64) ?SigFd {
    p.g.lockSpin();
    defer p.g.lock.unlock();
    return p.g.sigfds.get(qpath);
}

fn signalfd(p: *Process, fd: i32, mask_va: u64, size: u64, flags: u32) Err!i64 {
    if (size != 8) return -E.INVAL;
    const mask = (try p.readU64(mask_va)) & ~sig.unblockable;
    if (fd != -1) {
        const info = kc.fdInfo(fd) catch return -E.BADF;
        p.g.lockSpin();
        defer p.g.lock.unlock();
        const e = p.g.sigfds.getPtr(info.qpath) orelse return -E.INVAL;
        if (info.dc != ev_dc) return -E.INVAL;
        e.mask = mask;
        e.fd = fd;
        return fd;
    }
    const nfd = kern.open("#\u{3b5}/eventfd", kern.ORDWR | if (flags & O_CLOEXEC != 0) @as(c_int, OCEXEC) else 0) catch return kerr();
    if (flags & O_NONBLOCK != 0) setFlags(p, nfd, .{ .nonblock = true });
    const info = kc.fdInfo(nfd) catch return -E.BADF;
    {
        p.g.lockSpin();
        defer p.g.lock.unlock();
        p.g.sigfds.put(p.gpa, info.qpath, .{ .fd = nfd, .mask = mask }) catch {
            kern.close(nfd) catch {};
            return -E.NOMEM;
        };
    }
    signalPosted(p);
    return nfd;
}

/// After signals were posted: a signalfd whose mask names a pending one
/// is made readable.
pub fn signalPosted(p: *Process) void {
    if (p.sig.pending == 0) return;
    p.g.lockSpin();
    defer p.g.lock.unlock();
    var it = p.g.sigfds.iterator();
    while (it.next()) |e| {
        const sf = e.value_ptr;
        if (sf.armed or p.sig.pending & sf.mask == 0) continue;
        const info = kc.fdInfo(sf.fd) catch continue;
        if (info.dc != ev_dc or info.qpath != e.key_ptr.*) continue;
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, 1, .little);
        _ = kern.pwrite(@intCast(sf.fd), &b, -1) catch continue;
        sf.armed = true;
    }
}

fn sigfdRead(p: *Process, fd: i32, qpath: u64, buf: u64, len: u64) Err!i64 {
    if (len < 128) return -E.INVAL;
    while (true) {
        const sf = sigfdOf(p, qpath) orelse return -E.BADF;
        var got: u64 = 0;
        while (got + 128 <= len) {
            const signo = p.sig.takeFrom(sf.mask) orelse break;
            const in = p.sig.info[signo];
            var b: [128]u8 = @splat(0);
            std.mem.writeInt(u32, b[0..4], signo, .little);
            std.mem.writeInt(i32, b[8..12], in.code, .little);
            std.mem.writeInt(u32, b[12..16], in.pid, .little);
            std.mem.writeInt(i32, b[48..52], in.status, .little);
            std.mem.writeInt(u64, b[72..80], in.addr, .little);
            try p.writeMem(buf + got, &b);
            got += 128;
        }
        // Empty the counter once nothing the mask names is pending.
        if (p.sig.pending & sf.mask == 0) {
            p.g.lockSpin();
            const e = p.g.sigfds.getPtr(qpath);
            const armed = if (e) |x| x.armed else false;
            if (e) |x| x.armed = false;
            p.g.lock.unlock();
            if (armed) {
                var b: [8]u8 = undefined;
                _ = kern.pread(@intCast(fd), &b, -1) catch {};
            }
        }
        if (got > 0) return @intCast(got);
        if (flagsOf(p, fd).nonblock) return -E.AGAIN;
        // A note ends the wait; the process model posts it and the read
        // runs again.
        const w = waitReady(fd, kc.POLLIN);
        if (w < 0) return w;
    }
}

const EPOLLIN = 1;
const EPOLLOUT = 4;
const EPOLLERR = 8;
const EPOLLHUP = 0x10;
const EPOLLRDHUP = 0x2000;
const EPOLLEXCLUSIVE = 1 << 28;
const EPOLLWAKEUP = 1 << 29;
const EPOLLONESHOT = 1 << 30;
const EPOLLET = 1 << 31;

pub const EpEntry = struct {
    fd: i32,
    events: u32,
    data: u64,
    /// The wake generation of the last report, for EPOLLET.
    last_gen: u64 = std.math.maxInt(u64),
    /// Reported once under EPOLLONESHOT; rearmed by EPOLL_CTL_MOD.
    disarmed: bool = false,
};

pub const Epoll = struct {
    entries: std.ArrayList(EpEntry) = .empty,
};

fn epollOf(p: *Process, epfd: i32) ?*Epoll {
    const info = kc.fdInfo(epfd) catch return null;
    if (info.dc != ev_dc) return null;
    p.g.lockSpin();
    defer p.g.lock.unlock();
    if (p.g.epolls.get(info.qpath)) |ep| return ep;
    const ep = p.gpa.create(Epoll) catch return null;
    ep.* = .{};
    p.g.epolls.put(p.gpa, info.qpath, ep) catch {
        p.gpa.destroy(ep);
        return null;
    };
    return ep;
}

fn epollCreate(p: *Process, flags: u32) Err!i64 {
    const fd = kern.open("#\u{3b5}/epoll", kern.ORDWR | if (flags & O_CLOEXEC != 0) @as(c_int, OCEXEC) else 0) catch return kerr();
    _ = epollOf(p, fd);
    return fd;
}

fn epollCtl(p: *Process, epfd: i32, op: u32, fd: i32, ev_va: u64) Err!i64 {
    const ep = epollOf(p, epfd) orelse return if (kc.fdInfo(epfd)) |_| -E.INVAL else |_| -E.BADF;
    _ = kc.fdInfo(fd) catch return -E.BADF;
    if (fd == epfd) return -E.INVAL;
    var events: u32 = 0;
    var data: u64 = 0;
    if (op != 2) {
        var b: [12]u8 = undefined;
        // struct epoll_event is packed on amd64 (12 bytes) and padded to 16 on arm64.
        try p.readMem(ev_va, b[0..4]);
        events = std.mem.readInt(u32, b[0..4], .little);
        data = try p.readU64(ev_va + if (p.arch == .amd64) @as(u64, 4) else 8);
    }
    p.g.lockSpin();
    defer p.g.lock.unlock();
    // A wait in another thread looks again.
    defer kc.pollWake();
    const idx: ?usize = for (ep.entries.items, 0..) |e, i| {
        if (e.fd == fd) break i;
    } else null;
    switch (op) {
        1 => { // ADD
            if (idx != null) return -E.EXIST;
            ep.entries.append(p.gpa, .{ .fd = fd, .events = events, .data = data }) catch return -E.NOMEM;
        },
        2 => { // DEL
            const i = idx orelse return -E.NOENT;
            _ = ep.entries.swapRemove(i);
        },
        3 => { // MOD
            const i = idx orelse return -E.NOENT;
            ep.entries.items[i] = .{ .fd = fd, .events = events, .data = data };
        },
        else => return -E.INVAL,
    }
    return 0;
}

fn epollWait(p: *Process, epfd: i32, events_va: u64, maxevents: i32, timeout_ms: i32, sigmask_va: u64) Err!i64 {
    const ep = epollOf(p, epfd) orelse return if (kc.fdInfo(epfd)) |_| -E.INVAL else |_| -E.BADF;
    if (maxevents <= 0) return -E.INVAL;
    var old_mask: ?u64 = null;
    if (sigmask_va != 0) {
        old_mask = p.sig.mask;
        p.sig.mask = (try p.readU64(sigmask_va)) & ~sig.unblockable;
    }
    defer if (old_mask) |m| {
        p.sig.mask = m;
    };
    const ev_size: u64 = if (p.arch == .amd64) 12 else 16;
    const deadline: ?i64 = if (timeout_ms >= 0) kern.monoNs() + @as(i64, timeout_ms) * std.time.ns_per_ms else null;
    // The entries are copied out under the group's lock, since other
    // threads change them while this waits (Go's netpoller does).
    var snap: std.ArrayList(EpEntry) = .empty;
    defer snap.deinit(p.gpa);
    var pf: std.ArrayList(kc.PollFd) = .empty;
    defer pf.deinit(p.gpa);
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(p.gpa);
    while (true) {
        {
            p.g.lockSpin();
            defer p.g.lock.unlock();
            // Drop entries whose fd was closed, as Linux does when the
            // last reference to the file goes.
            var i: usize = 0;
            while (i < ep.entries.items.len) {
                if (kc.fdInfo(ep.entries.items[i].fd)) |_| i += 1 else |_| _ = ep.entries.swapRemove(i);
            }
            snap.clearRetainingCapacity();
            snap.appendSlice(p.gpa, ep.entries.items) catch return -E.NOMEM;
        }
        const n = snap.items.len;
        pf.resize(p.gpa, @max(n, 1)) catch return -E.NOMEM;
        for (snap.items, 0..) |e, k| pf.items[k] = .{
            .fd = if (e.disarmed) -1 else e.fd,
            .events = @bitCast(@as(u16, @truncate(e.events & (EPOLLIN | EPOLLOUT | EPOLLRDHUP | 2)))),
            .revents = 0,
        };
        var gen: u64 = 0;
        // Ask without waiting first: an edge-triggered entry whose state
        // hasn't changed since it was reported isn't ready, so the wait
        // below must be for the next wake, not for readiness alone.
        _ = kc.poll(pf.items[0..n], 0, &gen) catch return -E.INTR;
        var out: usize = 0;
        out_buf.clearRetainingCapacity();
        {
            p.g.lockSpin();
            defer p.g.lock.unlock();
            for (snap.items, 0..) |s, k| {
                const rev: u32 = @as(u16, @bitCast(pf.items[k].revents));
                if (rev == 0 or s.disarmed) continue;
                // The live entry, unless another thread removed or changed it.
                const e = for (ep.entries.items) |*e| {
                    if (e.fd == s.fd and e.events == s.events and e.data == s.data) break e;
                } else continue;
                if (e.disarmed) continue;
                if (e.events & EPOLLET != 0) {
                    if (e.last_gen == gen) continue;
                    e.last_gen = gen;
                }
                if (out >= @as(usize, @intCast(maxevents))) break;
                var b: [16]u8 = @splat(0);
                std.mem.writeInt(u32, b[0..4], rev & (e.events | EPOLLERR | EPOLLHUP), .little);
                if (p.arch == .amd64) std.mem.writeInt(u64, b[4..12], e.data, .little) else std.mem.writeInt(u64, b[8..16], e.data, .little);
                out_buf.appendSlice(p.gpa, b[0..@intCast(ev_size)]) catch return -E.NOMEM;
                out += 1;
                if (e.events & EPOLLONESHOT != 0) e.disarmed = true;
            }
        }
        if (out > 0) {
            try p.writeMem(events_va, out_buf.items);
            return @intCast(out);
        }
        var ms: i64 = -1;
        if (deadline) |d| {
            const left = d - kern.monoNs();
            if (left <= 0) return 0;
            ms = @divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        }
        // Sleep until something changes. An fd that's ready now but was
        // reported edge-triggered is left out, so it doesn't end the wait
        // at once; any wake ends it, and the loop asks again.
        // An edge-triggered fd waits only for the events that aren't
        // ready yet (a socket that can be written waits to be readable).
        var waiting: usize = 0;
        for (snap.items, 0..) |e, k| {
            if (e.disarmed) continue;
            var want: u16 = @bitCast(pf.items[k].events);
            if (e.events & EPOLLET != 0 and e.last_gen == gen) want &= ~@as(u16, @bitCast(pf.items[k].revents));
            if (want == 0) continue;
            pf.items[waiting] = .{ .fd = e.fd, .events = @bitCast(want), .revents = 0 };
            waiting += 1;
        }
        if (kc.pollGen() != gen) continue;
        _ = kc.pollOnce(pf.items[0..waiting], ms) catch return -E.INTR;
    }
}
