//! h9's proc.c (design/kernel-port.md): the process record, `Proc`
//! (h9proc.h), drawterm's Proc with what 9front keeps in its Proc and
//! drawterm's lacks (parent, children, wait queue, Egrp, the
//! machine-local pid, the note queue and a pointer to the ABI's state),
//! in one record. See SPEC.md, "Process model". drawterm's procinit.c
//! is here too, since making and ending a Proc is this file's.
//!
//! Also here, ported from 9front at the pinned release: the group
//! handling of sysrfork (port/sysproc.c), pexit's and pwait's wait
//! records, and the note queue (mknote, pushnote, postnote, postnotepg
//! and popnote, port/proc.c).
//!
//! A close translation of the C: the same functions in the same order,
//! with error unions in place of error labels, each exported under its C
//! name with the C's contract (a function that returned -1 with the
//! error string set still does, and one that raised still raises).
//!
//! Notes are queued on the record by pushnote: drawterm's postnote only
//! set notepending, which sysfile clears after every successful call, so
//! notepending stays the "interrupt this call" flag. The pipe device
//! (src/kern/dev/pipe.zig) posts its notes here. Each guest process
//! belongs to a machine (Hmach) and is on its list: note groups and
//! postnotepg never reach another machine's processes.
//!
//! devproc (#p, src/kern/dev/proc.zig) reads and changes records
//! through the h9_* functions declared in hproc.h; a lookup by pid only
//! finds processes in the caller's machine.
//!
//! Records are reference counted: the thread holds one until pexit, and
//! each child holds one on its parent's, so a child that outlives its
//! parent never touches freed memory. A parent that exits marks its
//! record dead, and children's exits then leave no wait record.
//!
//! One C call that can raise is made through src/kern/procshim.c: the
//! function h9_kern_isolated runs.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const pgrp = @import("pgrp.zig");
const chan = @import("chan.zig");
const dev = @import("dev.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Proc = c.Proc;

// The C and the Zig must agree on the record: see errlab in h9proc.h.
comptime {
    std.debug.assert(@offsetOf(Proc, "errlab") == 0);
    std.debug.assert(@sizeOf(@FieldType(Proc, "errlab")) % 16 == 0);
}
const Hmach = c.Hmach;
const Hnote = c.Hnote;
const Hwait = c.Hwait;
const Chan = c.Chan;
const Fgrp = c.Fgrp;
const Pgrp = c.Pgrp;
const Rgrp = c.Rgrp;

const incref = chan.incref;
const decref = chan.decref;
const lock = c.lock;
const unlock = c.unlock;

// devsrv.c and src/hstream.zig.
extern fn h9_srvmachclose(m: *Hmach) void;
extern fn h9_srvmachfree(m: *Hmach) void;
extern fn h9_hstream_machend(m: ?*anyopaque) void;
// src/kern/procshim.c: a call of fn(arg), returning -1 if it raised,
// with the error string on the process.
extern fn h9_shim_call(f: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) c_int;
extern fn sysclose(fd: c_int) c_int; // sysfile.zig's, for C

// dev/env.zig's environment groups, kept as void* on the record; the
// namespace kernel has no environment, so its processes have none.
const devenv = @import("dev/env.zig");

fn egrpnew() Error!?*anyopaque {
    if (port.options.nskernel) return null;
    return try devenv.egrpnew();
}

fn egrpcopy(from: ?*anyopaque) Error!?*anyopaque {
    if (port.options.nskernel) return null;
    return try devenv.egrpcopy(@ptrCast(@alignCast(from.?)));
}

fn h9_egrpincref(e: ?*anyopaque) void {
    if (!port.options.nskernel) devenv.egrpincref(@ptrCast(@alignCast(e.?)));
}

fn h9_egrpclose(e: ?*anyopaque) void {
    if (!port.options.nskernel) devenv.egrpclose(@ptrCast(@alignCast(e.?)));
}

fn kstrcpy(s: [*]u8, t: [*:0]const u8) void {
    chan.kstrcpy(s, t, port.ERRMAX);
}

fn strecpy(dst: []u8, src: [*c]const u8) void {
    _ = c.strecpy(dst.ptr, dst.ptr + dst.len, @constCast(src));
}

// A guest process is on its machine's list (Hmach.procs) from its
// making until h9_kern_exit; pid lookups, /proc and group notes walk it.
fn enter(p: *Proc) void {
    const m: *Hmach = p.mach;
    lock(&m.lk);
    p.mnext = m.procs;
    m.procs = p;
    unlock(&m.lk);
}

fn leave(p: *Proc) void {
    const m: *Hmach = p.mach;
    lock(&m.lk);
    var l: *[*c]Proc = &m.procs;
    while (l.* != null) : (l = &l.*.*.mnext) {
        if (l.* == p) {
            l.* = p.mnext;
            break;
        }
    }
    unlock(&m.lk);
}

fn freenote(n_: ?*Hnote) void {
    const n = n_ orelse return;
    if (decref(&n.ref) != 0)
        return;
    c.free(n);
}

/// Called with p.nlk held.
fn freenotes(p: *Proc) void {
    while (p.nnote > 0) {
        p.nnote -= 1;
        const i: usize = @intCast(p.nnote);
        freenote(p.note[i]);
        p.note[i] = null;
    }
}

fn putmach(m_: ?*Hmach) void {
    const m = m_ orelse return;
    if (decref(&m.ref) == 0) {
        h9_srvmachfree(m);
        c.free(m);
    }
}

/// Drops a reference to p. The last frees what's left once its thread
/// has gone (pexit closed its groups): wait records, notes and the
/// machine.
fn putproc(p_: ?*Proc) void {
    const p = p_ orelse return;
    if (decref(&p.ref) != 0)
        return;
    while (@as(?*Hwait, p.waitq)) |w| {
        p.waitq = w.next;
        c.free(w);
    }
    freenotes(p);
    freenote(p.lastnote);
    putmach(p.mach);
    c.free(p);
}

/// Wakes the Linux waits sleeping for h's children (h9_linux_await),
/// after a change to its wait records, children or deadness. Called
/// with h.exl.
fn wakewaits(h: *Proc) callconv(.c) void {
    h.wgen +%= 1;
    var s: ?*Proc = h.wsleep;
    while (s) |sp| : (s = sp.wnext)
        _ = sync.wakeup(&sp.lwaitr);
}

/// The calling process, if it's a guest process (it has a machine), or
/// nil.
fn self() ?*Proc {
    const p: ?*Proc = c._getproc();
    if (p == null or p.?.mach == null)
        return null;
    return p;
}

fn uphproc() Error!*Proc {
    return self() orelse port.kerror("not an h9 process");
}

// drawterm's procinit.c, which h9 doesn't build: the boot Proc, and
// making and ending kprocs. A Proc is counted (h9proc.h), and pexit
// drops the thread's reference rather than freeing it.

fn procinit0() Error!void {
    const p = newproc() orelse port.kpanic("procinit0: no memory", .{});
    p.fgrp = try pgrp.dupfgrp(null);
    p.rgrp = try pgrp.newrgrp();
    p.pgrp = try pgrp.newpgrp();
    c._setproc(p);

    const slash = try chan.namec("#/", c.Atodir, 0, 0);
    up().slash = slash;
    chan.pathclose(slash.path);
    slash.path = chan.newpath("/");
    up().dot = try chan.cclone(slash);
}

fn newproc() ?*Proc {
    const p: *Proc = @ptrCast(@alignCast(c.mallocz(@sizeOf(Proc), 1) orelse return null));
    p.ref.ref = 1;
    _ = c.strcpy(&p.user, c.eve);
    p.syserrstr = &p.errbuf0;
    p.errstr = &p.errbuf1;
    _ = c.strcpy(&p.text, "drawterm");
    p.start = c.ticks();
    c.osnewproc(p);
    return p;
}

const Fn = *const fn (?*anyopaque) callconv(.c) void;

fn kproc(name: [*c]const u8, f: Fn, arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const p = newproc() orelse port.kpanic("kproc: no memory", .{});
    p.@"fn" = f;
    p.arg = arg;
    p.slash = chan.cclone(up().slash) catch |e| port.raise(e);
    p.dot = chan.cclone(up().dot) catch |e| port.raise(e);
    p.rgrp = up().rgrp;
    if (@as(?*Rgrp, p.rgrp)) |r|
        _ = incref(&r.ref);
    p.pgrp = up().pgrp;
    if (@as(?*Pgrp, up().pgrp)) |g|
        _ = incref(&g.ref);
    p.fgrp = up().fgrp;
    if (@as(?*Fgrp, p.fgrp)) |f_|
        _ = incref(&f_.ref);
    strecpy(&p.text, name);

    c.osproc(p);
    return p;
}

/// Ends the calling Proc's thread, after closing its groups (drawterm's
/// closefgrp, as procinit.c's).
fn pexit(msg: [*c]u8, freemem: c_int) callconv(.c) void {
    _ = msg;
    _ = freemem;
    const p = up();

    if (@as(?*Pgrp, p.pgrp)) |g| {
        pgrp.closepgrp(g);
        p.pgrp = null;
    }
    if (@as(?*Rgrp, p.rgrp)) |r| {
        pgrp.closergrp(r);
        p.rgrp = null;
    }
    if (@as(?*Fgrp, p.fgrp)) |f| {
        pgrp.closefgrp(f);
        p.fgrp = null;
    }

    chan.cclose(p.dot);
    p.dot = null;
    chan.cclose(p.slash);
    p.slash = null;

    // A process the scheduler runs ends its continuation, not a thread.
    // putproc may free p.
    // And its record, which /proc may hold on to, keeps no pointer to
    // the continuation the scheduler frees.
    const on_cont = sync.contOf(p) != null;
    p.cont = null;
    putproc(p);
    if (on_cont) sync.exitCont();
    c.osexit();
}

fn newnoteid(m: *Hmach) c_uint {
    lock(&m.lk);
    m.nextnoteid +%= 1;
    const id = m.nextnoteid;
    unlock(&m.lk);
    return id;
}

/// Set by the Zig side: makes a process running guest code take an
/// exit, so a note posted to it is delivered. Called with the process's
/// nlk held, and only while its aux is set.
var h9_notekick: ?*const fn (?*anyopaque) callconv(.c) void = null;

fn mknote(msg: [*:0]const u8, flag: c_int) ?*Hnote {
    const n: *Hnote = @ptrCast(@alignCast(c.mallocz(@sizeOf(Hnote), 1) orelse return null));
    kstrcpy(&n.msg, msg);
    n.flag = flag;
    n.ref.ref = 1;
    return n;
}

/// 9front's pushnote: queues n (taking the caller's reference) and
/// interrupts the process. A note posted by the system to a process that
/// can't handle it will kill it, so the notes before it are dropped.
fn pushnote(h: *Proc, n: *Hnote) bool {
    lock(&h.nlk);
    if (h.exited != 0) {
        unlock(&h.nlk);
        freenote(n);
        return false;
    }
    if (n.flag != c.NUser and (h.notify == 0 or h.notified != 0))
        freenotes(h);
    if (h.nnote >= c.NNOTE) {
        unlock(&h.nlk);
        freenote(n);
        return false;
    }
    h.note[@intCast(h.nnote)] = n;
    h.nnote += 1;
    // The kick first: the exit loop interrupts a call it starts with the
    // kick's flag set, and a call started before the flag is set sees
    // this interrupt.
    if (h.aux != null) if (h9_notekick) |k| k(h.aux);
    sync.procinterrupt(h);
    unlock(&h.nlk);
    return true;
}

/// drawterm's postnote, which the pipe device (src/kern/dev/pipe.zig)
/// calls. A Proc that isn't an h9 process (a kproc) is only
/// interrupted, as drawterm's postnote does.
fn h9_postnote(p_: ?*Proc, dolock: c_int, msg: [*:0]const u8, flag: c_int) callconv(.c) c_int {
    _ = dolock;
    const p = p_ orelse return 0;
    if (p.mach == null) {
        sync.procinterrupt(p);
        return 0;
    }
    const n = mknote(msg, flag) orelse return 0;
    return @intFromBool(pushnote(p, n));
}

/// 9front's postnotepg, within machine m.
fn postnotepg(m: *Hmach, noteid: c_uint, msg: [*:0]const u8, flag: c_int) void {
    const n = mknote(msg, flag) orelse return;
    const me: ?*Proc = c._getproc();
    lock(&m.lk);
    var h_: ?*Proc = m.procs;
    while (h_) |h| : (h_ = h.mnext) {
        if (h == me or h.noteid != noteid)
            continue;
        _ = incref(&n.ref);
        _ = pushnote(h, n);
    }
    unlock(&m.lk);
    freenote(n);
}

/// Posts a note to the process with machine-local pid in the caller's
/// machine. Returns 1 if it was queued, 0 if the queue was full, or -1
/// with the error string set if there's no such process.
fn h9_kern_postnote(pid: c_uint, msg: [*:0]const u8, flag: c_int) callconv(.c) c_int {
    const h = (if (self() != null) h9_pidlookup(up().mach, pid) else null) orelse {
        kstrcpy(up().syserrstr, "process exited");
        return -1;
    };
    var r: c_int = 0;
    if (mknote(msg, flag)) |n|
        r = @intFromBool(pushnote(h, n));
    putproc(h);
    return r;
}

/// The calling process's record, with a reference, which h9_kern_unref
/// releases; for a note posted later from anywhere, as an interval
/// timer's (src/abi/linux/itimer.zig). nil if the caller isn't an h9
/// process.
fn h9_kern_selfref() callconv(.c) ?*anyopaque {
    const h = self();
    if (h) |p|
        _ = incref(&p.ref);
    return h;
}

/// Posts a note to the process of a h9_kern_selfref reference: 1 if
/// queued.
fn h9_kern_postnoteref(v: *Proc, msg: [*:0]const u8, flag: c_int) callconv(.c) c_int {
    const n = mknote(msg, flag) orelse return 0;
    return @intFromBool(pushnote(v, n));
}

fn h9_kern_unref(v: ?*Proc) callconv(.c) void {
    putproc(v);
}

/// The calling process's machine, with a reference for the caller,
/// which h9_kern_putmach releases. nil if the caller isn't an h9
/// process.
fn h9_kern_mach() callconv(.c) ?*anyopaque {
    const h = self() orelse return null;
    _ = incref(&h.mach.*.ref);
    return h.mach;
}

fn h9_kern_putmach(m: ?*Hmach) callconv(.c) void {
    putmach(m);
}

/// Posts a note from the host side (Ctrl-C, hangup, a timeout) to
/// machine m: with all set, to every process; otherwise to the note
/// group of its first process (pid 1), which is the foreground group.
/// Callable from any thread, including ones that aren't kernel
/// processes: it takes only locks, never up or an error label, as
/// h9_cons_wake doesn't. Returns how many processes it reached.
fn h9_kern_postmach(m: *Hmach, all: c_int, msg: [*:0]const u8, flag: c_int) callconv(.c) c_int {
    const n = mknote(msg, flag) orelse return 0;
    var count: c_int = 0;
    lock(&m.lk);
    var noteid: c_uint = 0;
    var found = all != 0;
    var h_: ?*Proc = m.procs;
    while (!found) : (h_ = h_.?.mnext) {
        const h = h_ orelse break;
        if (h.pid == 1) {
            noteid = h.noteid;
            found = true;
        }
    }
    if (found) {
        h_ = m.procs;
        while (h_) |h| : (h_ = h.mnext) {
            if (all == 0 and h.noteid != noteid)
                continue;
            _ = incref(&n.ref);
            count += @intFromBool(pushnote(h, n));
        }
    }
    unlock(&m.lk);
    freenote(n);
    return count;
}

// For devproc (hproc.h).

var h9_procstatus: ?*const fn (?*anyopaque, [*c]u8, c_int, [*c]c_uint) callconv(.c) void = null;
var h9_procthreads: ?*const fn (?*anyopaque, [*c]c_uint, [*c]c_uint) callconv(.c) void = null;

/// Set by the Zig side: whether the process with this aux wants a
/// "linux: signal 17" note (SIGCHLD) when a child leaves a wait record.
/// Called with the parent's nlk held, and only while its aux is set.
var h9_wantchld: ?*const fn (?*anyopaque) callconv(.c) c_int = null;
var h9_procsegment: ?*const fn (?*anyopaque, [*c]u8, c_int) callconv(.c) c_int = null;
var h9_stopkick: ?*const fn (?*anyopaque) callconv(.c) void = null;
var h9_procdebug: ?*const fn (?*anyopaque, c_int, c_int, u64, ?*anyopaque, c_int) callconv(.c) c_int = null;

/// The calling process's record, raising if it isn't an h9 process.
fn h9_uphproc() callconv(.c) *Proc {
    return uphproc() catch |e| port.raise(e);
}

/// Whether the calling process's next lookup acts on a link in its last
/// name (design/epoch-0/linux-symlinks.md, fscheck.h); h9_fs_nofollow
/// sets it and returns what it was. A process that isn't h9's always
/// follows.
fn h9_fs_nofollow(on: c_int) callconv(.c) c_int {
    const h = self() orelse return 0;
    const old = h.nofollow;
    h.nofollow = on;
    return old;
}

fn h9_fs_nofollowing() callconv(.c) c_int {
    const h = self() orelse return 0;
    return h.nofollow;
}

/// The process with machine-local pid in machine m, with a reference,
/// or nil.
pub fn h9_pidlookup(m: *Hmach, pid: c_uint) callconv(.c) ?*Proc {
    lock(&m.lk);
    var h_: ?*Proc = m.procs;
    while (h_) |h| : (h_ = h.mnext) {
        if (h.pid == pid)
            break;
    }
    if (h_) |h|
        _ = incref(&h.ref);
    unlock(&m.lk);
    return h_;
}

pub fn h9_putproc(h: ?*Proc) callconv(.c) void {
    putproc(h);
}

/// The pids in machine m, in ascending order: fills up to n of them
/// into pids and returns how many it filled.
pub fn h9_pids(m: *Hmach, pids: [*]c_uint, n: c_int) callconv(.c) c_int {
    var count: c_int = 0;
    lock(&m.lk);
    var h_: ?*Proc = m.procs;
    while (h_) |h| : (h_ = h.mnext) {
        if (h.pid != 0) {
            if (count < n)
                pids[@intCast(count)] = h.pid;
            count += 1;
        }
    }
    unlock(&m.lk);
    if (count > n)
        count = n;
    var i: usize = 1;
    while (i < @as(usize, @intCast(count))) : (i += 1) {
        const v = pids[i];
        var j = i;
        while (j > 0 and pids[j - 1] > v) : (j -= 1)
            pids[j] = pids[j - 1];
        pids[j] = v;
    }
    return count;
}

pub fn h9_mknote(msg: [*:0]const u8, flag: c_int) callconv(.c) ?*Hnote {
    return mknote(msg, flag);
}

pub fn h9_freenote(n: ?*Hnote) callconv(.c) void {
    freenote(n);
}

pub fn h9_pushnote(h: *Proc, n: *Hnote) callconv(.c) c_int {
    return @intFromBool(pushnote(h, n));
}

pub fn h9_postnotepg(m: *Hmach, noteid: c_uint, msg: [*:0]const u8, flag: c_int) callconv(.c) void {
    postnotepg(m, noteid, msg, flag);
}

/// Moves h into note group noteid, which some process in its machine
/// must be in already (9front's changenoteid, where users can't
/// differ). Returns 0, or -1 if there's no such group.
pub fn h9_setnoteid(h: *Proc, noteid: c_uint) callconv(.c) c_int {
    const m: *Hmach = h.mach;
    var found = false;
    lock(&m.lk);
    var q_: ?*Proc = m.procs;
    while (!found) : (q_ = q_.?.mnext) {
        const q = q_ orelse break;
        if (q.noteid == noteid)
            found = true;
    }
    if (found)
        h.noteid = noteid;
    unlock(&m.lk);
    return if (found) 0 else -1;
}

/// 9front's killproc for ctl kill: the process dies with "Killed" at
/// its next note delivery, whether or not it has a handler.
pub fn h9_killproc(h: *Proc) callconv(.c) void {
    lock(&h.nlk);
    if (h.exited == 0) {
        h.killed = 1;
        // The kick first, as in pushnote.
        if (h.aux != null) if (h9_notekick) |k| k(h.aux);
        sync.procinterrupt(h);
    }
    unlock(&h.nlk);
}

/// Records exec's argv for /proc/n/args: n bytes of NUL-terminated
/// strings, which the caller has cut to ARGSLEN at a character
/// boundary.
fn h9_kern_setargs(args: [*]const u8, n: c_int) callconv(.c) void {
    const h = self() orelse return;
    if (n < 0 or n > c.ARGSLEN)
        return;
    lock(&h.alk);
    const len: usize = @intCast(n);
    @memmove(h.args[0..len], args[0..len]);
    h.nargs = n;
    h.setargs = 0;
    unlock(&h.alk);
}

/// Posts a note to every process but the caller in its machine's note
/// group noteid.
fn h9_kern_postnotepg(noteid: c_uint, msg: [*:0]const u8, flag: c_int) callconv(.c) void {
    if (self()) |h|
        postnotepg(h.mach, noteid, msg, flag);
}

/// The calling process's note group.
fn h9_kern_noteid() callconv(.c) c_uint {
    return if (self()) |h| h.noteid else 0;
}

/// Whether the calling process has a note handler (notify with a
/// non-nil function).
fn h9_kern_setnotify(on: c_int) callconv(.c) void {
    const h = self() orelse return;
    lock(&h.nlk);
    h.notify = @intFromBool(on != 0);
    unlock(&h.nlk);
}

/// Whether the calling process has a note queued.
fn h9_kern_notepending() callconv(.c) c_int {
    const h = self() orelse return 0;
    return @intFromBool(h.nnote > 0 or h.killed != 0);
}

/// 9front's popnote, for delivery at a syscall exit or kick. Takes the
/// next note into msg (ERRMAX bytes), with " pc=" and pc appended to a
/// "sys:" note posted to this process alone, and says what to do:
/// Nhandle (the process is now in its handler until h9_kern_noted),
/// Nkill or Nkilldebug (it has no handler, or is in it already), or
/// Nnone (no note, or only user notes while in the handler, which
/// wait).
fn h9_kern_popnote(msg: [*]u8, pc: u64) callconv(.c) c_int {
    const h = self() orelse return c.Nnone;
    up().notepending = 0;
    lock(&h.nlk);
    if (h.killed != 0) {
        unlock(&h.nlk);
        kstrcpy(msg, "Killed");
        return c.Nkill;
    }
    if (h.nnote == 0 or (h.notified != 0 and h.note[0].*.flag == c.NUser)) {
        unlock(&h.nlk);
        return c.Nnone;
    }
    freenote(h.lastnote);
    const n: *Hnote = h.note[0];
    h.lastnote = n;
    h.nnote -= 1;
    const nn: usize = @intCast(h.nnote);
    if (nn > 0)
        std.mem.copyForwards([*c]Hnote, h.note[0..nn], h.note[1 .. nn + 1]);
    h.note[nn] = null;
    if (n.ref.ref == 1 and std.mem.startsWith(u8, &n.msg, "sys:")) {
        const l = std.mem.indexOfScalar(u8, &n.msg, 0).?;
        _ = c.snprint(@as([*]u8, &n.msg) + l, port.ERRMAX - @as(c_int, @intCast(l)), @constCast(" pc=%#llux"), pc);
    }
    var r: c_int = undefined;
    if (h.notify == 0 or h.notified != 0) {
        r = if (n.flag == c.NDebug) c.Nkilldebug else c.Nkill;
    } else {
        h.notified = 1;
        r = c.Nhandle;
    }
    kstrcpy(msg, @ptrCast(&n.msg));
    unlock(&h.nlk);
    return r;
}

/// The bookkeeping of 9front's sysnoted. arg is noted's argument (NCONT
/// 0, NDFLT 1, NSAVE 2, NRSTR 3). Returns -1 for noted outside a handler
/// with anything but NRSTR (an error, Ebadarg); otherwise, for NDFLT or
/// an unknown arg, Nkill or Nkilldebug with the last note in msg, and
/// Nnone when the process carries on, out of the handler (NCONT, NSAVE,
/// NRSTR).
fn h9_kern_noted(arg: c_int, msg: [*]u8) callconv(.c) c_int {
    const h = self() orelse return -1;
    lock(&h.nlk);
    if (h.notified == 0 and arg != 3) {
        unlock(&h.nlk);
        kstrcpy(up().syserrstr, &port.Ebadarg);
        return -1;
    }
    var r: c_int = c.Nnone;
    switch (arg) {
        0, 2, 3 => h.notified = 0,
        else => {
            if (arg != 1) {
                if (@as(?*Hnote, h.lastnote)) |ln|
                    ln.flag = c.NDebug;
            }
            if (@as(?*Hnote, h.lastnote)) |ln| {
                kstrcpy(msg, @ptrCast(&ln.msg));
                r = if (ln.flag == c.NDebug) c.Nkilldebug else c.Nkill;
            } else {
                kstrcpy(msg, "Suicide");
                r = c.Nkill;
            }
        },
    }
    unlock(&h.nlk);
    return r;
}

/// exec's reset of the note state: no handler, nothing queued.
fn h9_kern_execnotes() callconv(.c) void {
    const h = self() orelse return;
    lock(&h.nlk);
    freenotes(h);
    freenote(h.lastnote);
    h.lastnote = null;
    h.notify = 0;
    h.notified = 0;
    unlock(&h.nlk);
}

// Debugging (design/epoch-0/self-host.md): the process side of 9front's
// procctl. A debugger's ctl stop, startstop or an exec with hang set
// makes a stop request; the Zig exit loop checks for one at each stop
// point (entering a syscall, before running guest code again after a
// syscall, a kick, a fault or a breakpoint, and before delivering a
// note). Stopped, the process sleeps on its own kernel thread until ctl
// start, holding no vCPU.

/// Whether the calling process should stop here, as 9front's procctl
/// decides: for Pstopme always, for Ptraceme only with a note queued.
/// Takes the request.
fn h9_kern_wantstop() callconv(.c) c_int {
    const h = self() orelse return 0;
    var r: c_int = 0;
    lock(&h.nlk);
    switch (h.procctl) {
        c.Ptraceme, c.Pstopme => if (h.procctl == c.Pstopme or h.nnote != 0 or h.killed != 0) {
            h.procctl = 0;
            r = 1;
        },
        else => {},
    }
    unlock(&h.nlk);
    return r;
}

fn notstopped(a: ?*anyopaque) callconv(.c) c_int {
    const p: *Proc = @ptrCast(@alignCast(a.?));
    return @intFromBool(@as(*volatile c_int, &p.stopped).* == 0);
}

/// Stops the calling process, waking a debugger waiting for that, and
/// sleeps until ctl start. Returns 0 when started; -1 when interrupted
/// (a note, a kill or the machine's teardown), still stopped, so the
/// caller can decide whether to sleep again or h9_kern_unstop. The
/// caller saves its registers for /proc/n/regs before calling.
fn h9_kern_stopwait() callconv(.c) c_int {
    const h = self() orelse return 0;
    lock(&h.nlk);
    h.stopped = 1;
    unlock(&h.nlk);
    _ = sync.wakeup(&h.stopr);
    sync.sleep(&h.startr, notstopped, h) catch return -1;
    return 0;
}

/// Ends a stop without ctl start, for a process that's going to die.
fn h9_kern_unstop() callconv(.c) void {
    const h = self() orelse return;
    lock(&h.nlk);
    h.stopped = 0;
    unlock(&h.nlk);
}

/// Whether ctl kill has been written for the calling process.
fn h9_kern_killed() callconv(.c) c_int {
    const h = self() orelse return 0;
    return @intFromBool(h.killed != 0);
}

/// exec's part, as 9front's sysexec: with ctl hang set, the process
/// stops before its first instruction. Returns whether it will.
fn h9_kern_exechang() callconv(.c) c_int {
    const h = self() orelse return 0;
    lock(&h.nlk);
    const r = h.hang;
    if (r != 0)
        h.procctl = c.Pstopme;
    unlock(&h.nlk);
    return r;
}

/// Keeps the image the calling process just executed, opened from
/// path, for /proc/n/text (9front serves the image's channel). Best
/// effort: on an error the process has no text.
fn h9_kern_settextpath(path: ?[*:0]const u8) callconv(.c) void {
    const h = self() orelse return;
    var ch: ?*Chan = null;
    if (path) |p|
        ch = chan.namec(p, c.Aopen, c.OREAD, 0) catch null;
    lock(&h.nlk);
    const old: ?*Chan = h.textc;
    h.textc = ch;
    unlock(&h.nlk);
    if (old) |o|
        chan.cclose(o);
}

/// The calling process's Egrp, for devenv; fails if it has none.
pub fn upegrp() Error!*anyopaque {
    const h = self();
    if (h == null or h.?.egrp == null)
        return port.kerror("no environment");
    return h.?.egrp.?;
}

/// drawterm's closefgrp frees the fd table without closing its channels
/// (its kprocs never exit holding fds), so a pipe's write end would
/// outlive the last process holding it and its reader would never see
/// EOF. This is 9front's closefgrp. All Fgrp releases in this file but
/// pexit's go through it.
fn fgrpclose(f_: ?*Fgrp) void {
    const f = f_ orelse return;
    if (decref(&f.ref) != 0)
        return;
    var i: c_int = 0;
    while (i <= f.maxfd) : (i += 1) {
        if (@as(?*Chan, f.fd[@intCast(i)])) |ch| {
            f.fd[@intCast(i)] = null;
            chan.cclose(ch);
        }
    }
    c.free(f.flag);
    c.free(@ptrCast(f.fd));
    c.free(f);
}

pub fn h9_fgrpclose(f: ?*Fgrp) callconv(.c) void {
    fgrpclose(f);
}

/// The boot Proc, whose slash is #/.
var bootproc: *Proc = undefined;

/// A clone of the boot Proc's slash, #/, which can't fail: cloning
/// allocates with drawterm's smalloc.
fn bootslash() *Chan {
    return chan.cclone(bootproc.slash) catch |e| port.raise(e);
}

/// For a kproc that a guest process starts lazily, such as hostpoll
/// (hostsock-*.c): drops the fd table and namespace that kproc() shares
/// with that process. Kept, they outlived it, so the first process to
/// poll a host socket never had its sockets closed at exit and their
/// peers never saw EOF.
///
/// Its dot and slash, clones of that process's, go too, for #/: they
/// can be in the machine's root overlay or named unions, which then
/// outlived the machine and its pages. A later machine in the same host
/// process whose pages had the same address found the dead machine's
/// #Olinux as its own and faulted walking it.
fn h9_kprocdetach() callconv(.c) void {
    const p = up();
    fgrpclose(p.fgrp);
    p.fgrp = null;
    if (@as(?*Pgrp, p.pgrp)) |g| {
        pgrp.closepgrp(g);
        p.pgrp = null;
    }
    var ch: ?*Chan = p.dot;
    p.dot = bootslash();
    if (ch) |o|
        chan.cclose(o);
    ch = p.slash;
    p.slash = bootslash();
    if (ch) |o|
        chan.cclose(o);
}

/// Code using RFNOMNT expects to block all but these devices.
const nomntdevs = "|decp";

fn checkflags(flag: c_int) Error!void {
    if ((flag & (c.RFFDG | c.RFCFDG)) == (c.RFFDG | c.RFCFDG))
        return port.kerror(&port.Ebadarg);
    if ((flag & (c.RFNAMEG | c.RFCNAMEG)) == (c.RFNAMEG | c.RFCNAMEG))
        return port.kerror(&port.Ebadarg);
    if ((flag & (c.RFENVG | c.RFCENVG)) == (c.RFENVG | c.RFCENVG))
        return port.kerror(&port.Ebadarg);
}

/// Swaps the error strings after an error, as sysfile's wrappers do.
fn syserr() c_int {
    const p = up();
    const s = p.syserrstr;
    p.syserrstr = p.errstr;
    p.errstr = s;
    return -1;
}

const Spawn = struct {
    f: Fn,
    arg: ?*anyopaque,
};

fn newspawn(f: Fn, arg: ?*anyopaque) ?*Spawn {
    const s: *Spawn = @ptrCast(@alignCast(port.malloc(@sizeOf(Spawn)) orelse return null));
    s.* = .{ .f = f, .arg = arg };
    return s;
}

fn takespawn(v: ?*anyopaque) Spawn {
    const sp: *Spawn = @ptrCast(@alignCast(v.?));
    const s = sp.*;
    c.free(sp);
    return s;
}

/// Called once the kernel is up, from the boot Proc (glue.zig). Starts
/// the timer kproc that tsleep needs, and sets up the semaphore wait
/// lists.
fn h9_proc_boot() callconv(.c) void {
    bootproc = up();
    @import("sema.zig").semainit();
    @import("tsleep.zig").tsleepinit();
}

/// A new process's groups, as the boot Proc's: just #/, no fds, and its
/// own rendezvous group.
fn freshgroups() Error!void {
    const p = up();
    p.slash = try chan.cclone(bootproc.slash);
    p.dot = try chan.cclone(bootproc.slash);
    p.pgrp = try pgrp.newpgrp();
    p.fgrp = try pgrp.dupfgrp(null);
    p.rgrp = try pgrp.newrgrp();
}

fn spawntramp(v: ?*anyopaque) callconv(.c) void {
    const s = takespawn(v);
    // Now that up is set, kernel calls (and their errors) are allowed.
    (struct {
        fn f() Error!void {
            const h = try uphproc();
            try freshgroups();
            h.egrp = try egrpnew();
        }
    }).f() catch port.kpanic("h9_kern_spawn: %s", .{up().errstr});
    s.f(s.arg);
    h9_kern_exit();
}

/// A machine's C half, for the Zig Kernel (src/kern.zig) that owns it:
/// kernel is that Kernel, which h9_kern_machkernel returns until
/// h9_kern_machdetach. Returns nil if allocation fails.
/// Starts p, made by h9_kern_spawn or fork: on its machine's scheduler
/// (design/scheduler.md), if it has one and p may go there, and otherwise
/// on a host thread of its own.
fn startproc(p: *Proc, hostthread: bool) void {
    if (sync.can_park and !hostthread) {
        if (@as(?*Hmach, p.mach)) |m| if (m.schedstart) |start| {
            if (start(m.sched, p) == 0) return;
        };
    }
    c.osproc(p);
}

fn h9_kern_newmach(kernel: ?*anyopaque) callconv(.c) ?*anyopaque {
    const m: *Hmach = @ptrCast(@alignCast(c.mallocz(@sizeOf(Hmach), 1) orelse return null));
    m.ref.ref = 1;
    m.kernel = kernel;
    return m;
}

/// Has machine m's processes start on a scheduler (design/scheduler.md):
/// start(sched, p) takes each, or returns -1 to give it a host thread.
fn h9_kern_setsched(m: *Hmach, s: ?*anyopaque, start: ?*const fn (?*anyopaque, ?*Proc) callconv(.c) c_int) callconv(.c) void {
    m.sched = s;
    m.schedstart = start;
}

/// The Kernel that owns machine m, or nil once it has let go of it.
fn h9_kern_machkernel(m_: ?*Hmach) callconv(.c) ?*anyopaque {
    const m = m_ orelse return null;
    lock(&m.lk);
    const k = m.kernel;
    unlock(&m.lk);
    return k;
}

/// The Kernel's end: drops its reference to m, which its processes may
/// outlive.
fn h9_kern_machdetach(m: *Hmach) callconv(.c) void {
    lock(&m.lk);
    m.kernel = null;
    unlock(&m.lk);
    putmach(m);
}

/// Runs fn(arg) on a new kernel process in machine mach, with its own
/// thread, a fresh namespace (just #/, as the boot Proc has), no fds,
/// an empty environment and its own rendezvous group; it has no parent.
/// Unlike drawterm's kproc it can be called from a thread that isn't a
/// Proc: it only allocates here, and the new thread sets up its groups
/// once up is set. Returns 0, or -1 if allocation fails.
fn h9_kern_spawn(mach: *Hmach, name: [*c]const u8, f: Fn, arg: ?*anyopaque) callconv(.c) c_int {
    const s = newspawn(f, arg) orelse return -1;
    const p = newproc() orelse {
        c.free(s);
        return -1;
    };
    p.mach = mach;
    _ = incref(&mach.ref);
    lock(&mach.lk);
    mach.nlive += 1;
    unlock(&mach.lk);
    p.noteid = newnoteid(mach);
    p.@"fn" = spawntramp;
    p.arg = s;
    strecpy(&p.text, name);
    enter(p);
    startproc(p, false);
    return 0;
}

fn detachtramp(v: ?*anyopaque) callconv(.c) void {
    const s = takespawn(v);
    h9_kprocdetach();
    s.f(s.arg);
}

/// Starts a kproc that drops what it shares with the caller
/// (h9_kprocdetach) and then runs fn(arg), as the kprocs a guest process
/// starts lazily do. For kern.zig's tests. Returns 0, or -1 if
/// allocation fails.
fn h9_kern_kprocdetached(name: [*c]const u8, f: Fn, arg: ?*anyopaque) callconv(.c) c_int {
    const s = newspawn(f, arg) orelse return -1;
    _ = kproc(name, detachtramp, s);
    return 0;
}

/// Makes the calling thread, which isn't a Proc, a kernel process for
/// good: h9_kern_spawn's cloning from the boot Proc, without a new
/// thread. It has no machine, so notes never reach it. For macOS --gfx,
/// where AppKit runs on the process's main thread and drawterm's Cocoa
/// delegate sleeps and starts kprocs there (design/epoch-0/gfx.md).
/// Returns 0, or -1 if allocation fails.
fn h9_kern_adopt(name: [*c]const u8) callconv(.c) c_int {
    const p = newproc() orelse return -1;
    strecpy(&p.text, name);
    c._setproc(p);
    freshgroups() catch port.kpanic("h9_kern_adopt: %s", .{up().errstr});
    return 0;
}

/// Runs fn(arg) in the calling Proc with a fresh namespace, no fds and
/// its own rendezvous group, as a spawned process starts, and puts the
/// Proc's own back after. The kprocs fn starts share these, not the
/// caller's: a GUI backend's event and resize kprocs outlive the guest
/// process whose attach of #i started them (src/kern/gfx.c). fn is C,
/// which can raise: it's called through the shim, and its error raised
/// again once the Proc's own are back.
fn h9_kern_isolated(f: Fn, arg: ?*anyopaque) callconv(.c) void {
    const p = up();
    const pg = p.pgrp;
    const fg = p.fgrp;
    const rg = p.rgrp;
    const slash = p.slash;
    const dot = p.dot;
    p.pgrp = pgrp.newpgrp() catch |e| port.raise(e);
    p.fgrp = pgrp.dupfgrp(null) catch |e| port.raise(e);
    p.rgrp = pgrp.newrgrp() catch |e| port.raise(e);
    p.slash = bootslash();
    p.dot = bootslash();
    const rc = h9_shim_call(f, arg);
    pgrp.closepgrp(p.pgrp);
    fgrpclose(p.fgrp);
    pgrp.closergrp(p.rgrp);
    chan.cclose(p.slash);
    chan.cclose(p.dot);
    p.pgrp = pg;
    p.fgrp = fg;
    p.rgrp = rg;
    p.slash = slash;
    p.dot = dot;
    dev.caught(rc) catch |e| port.raise(e);
}

fn forktramp(v: ?*anyopaque) callconv(.c) void {
    const s = takespawn(v);
    s.f(s.arg);
    h9_kern_exit();
}

/// A child h9_kern_fork failed to make: what it has so far goes.
fn forkundo(p: *Proc) void {
    if (@as(?*Fgrp, p.fgrp)) |f| fgrpclose(f);
    if (@as(?*Pgrp, p.pgrp)) |g| pgrp.closepgrp(g);
    if (@as(?*Rgrp, p.rgrp)) |r| pgrp.closergrp(r);
    if (@as(?*Chan, p.dot)) |ch| chan.cclose(ch);
    if (@as(?*Chan, p.slash)) |ch| chan.cclose(ch);
    if (@as(?*Chan, p.textc)) |ch| chan.cclose(ch);
    if (p.egrp != null) h9_egrpclose(p.egrp);
    putmach(p.mach);
    c.free(p);
}

/// rfork with RFPROC: runs fn(arg) on a new kernel process that is a
/// child of the caller, with groups shared or copied from the caller's
/// as flag says (9front's sysrfork). pid is the child's machine-local
/// pid. RFMEM is the caller's business. The child inherits the note
/// handler and, without RFNOTEG, the note group, but no queued notes.
/// On error, fn never runs.
pub fn fork(flag: c_int, pid: c_uint, f: Fn, arg: ?*anyopaque) Error!void {
    if ((flag & c.RFPROC) == 0)
        return port.kerror(&port.Ebadarg);
    try checkflags(flag);
    const ph = try uphproc();
    // A Linux thread's children are its group leader's.
    const wp: *Proc = if (@as(?*Proc, ph.waiter)) |w| w else ph;

    const s = newspawn(f, arg) orelse return port.kerror(&port.Enomem);
    errdefer c.free(s);
    const p = newproc() orelse return port.kerror(&port.Enomem);
    errdefer forkundo(p);
    const h = p;
    h.pid = pid;
    h.ppid = wp.pid;
    h.mach = ph.mach;
    _ = incref(&h.mach.*.ref);
    h.notify = ph.notify;
    h.noteid = if ((flag & c.RFNOTEG) != 0) newnoteid(h.mach) else ph.noteid;
    // As 9front's sysrfork: the child inherits hang, and runs the same
    // image.
    h.hang = ph.hang;
    lock(&ph.nlk);
    h.textc = ph.textc;
    if (@as(?*Chan, h.textc)) |t|
        _ = incref(&t.ref);
    unlock(&ph.nlk);
    strecpy(&p.text, &up().text);

    const me = up();
    p.slash = me.slash;
    _ = incref(&p.slash.*.ref);
    p.dot = me.dot;
    _ = incref(&p.dot.*.ref);

    // File descriptors
    if ((flag & (c.RFFDG | c.RFCFDG)) != 0) {
        if ((flag & c.RFFDG) != 0)
            p.fgrp = try pgrp.dupfgrp(me.fgrp)
        else
            p.fgrp = try pgrp.dupfgrp(null);
    } else {
        p.fgrp = me.fgrp;
        _ = incref(&me.fgrp.*.ref);
    }

    // Process groups
    if ((flag & (c.RFNAMEG | c.RFCNAMEG)) != 0) {
        p.pgrp = try pgrp.newpgrp();
        try pgrp.pgrpcpy(p.pgrp, me.pgrp, flag);
    } else {
        p.pgrp = me.pgrp;
        _ = incref(&me.pgrp.*.ref);
    }

    // Rendezvous group
    if ((flag & c.RFREND) != 0)
        p.rgrp = try pgrp.newrgrp()
    else {
        p.rgrp = me.rgrp;
        _ = incref(&me.rgrp.*.ref);
    }

    // Environment group
    if ((flag & (c.RFENVG | c.RFCENVG)) != 0) {
        if ((flag & c.RFENVG) != 0)
            h.egrp = try egrpcopy(ph.egrp)
        else
            h.egrp = try egrpnew();
    } else {
        h.egrp = ph.egrp;
        h9_egrpincref(ph.egrp);
    }

    // The child keeps its parent's chroot (design/epoch-0/linux-chroot.md).
    h.lroot = ph.lroot;
    if (@as(?*Chan, h.lroot)) |r|
        _ = incref(&r.ref);

    if ((flag & c.RFNOMNT) != 0)
        pgrp.devmask(p.pgrp, true, nomntdevs);

    if ((flag & c.RFNOWAIT) == 0) {
        _ = incref(&wp.ref);
        h.parent = wp;
        lock(&wp.exl);
        wp.nchild += 1;
        wp.wgen +%= 1;
        unlock(&wp.exl);
    }
    if ((flag & c.RFLXTHREAD) != 0) {
        _ = incref(&wp.ref);
        h.waiter = wp;
    }

    lock(&h.mach.*.lk);
    h.mach.*.nlive += 1;
    unlock(&h.mach.*.lk);

    p.@"fn" = forktramp;
    p.arg = s;
    enter(h);
    startproc(p, (flag & c.RFHOSTTHREAD) != 0);
}

/// fork for C: 0, or -1 with the error string set.
fn h9_kern_fork(flag: c_int, pid: c_uint, f: Fn, arg: ?*anyopaque) callconv(.c) c_int {
    fork(flag, pid, f, arg) catch return syserr();
    return 0;
}

/// Swap the caller's groups under h.debug, for devproc's readers.
fn swapfgrp(h: *Proc, f: ?*Fgrp) void {
    sync.qlock(&h.debug);
    up().fgrp = f;
    sync.qunlock(&h.debug);
}

fn swappgrp(h: *Proc, pg: ?*Pgrp) void {
    sync.qlock(&h.debug);
    up().pgrp = pg;
    sync.qunlock(&h.debug);
}

/// chdir, as drawterm's syschdir, with dot swapped under the record's
/// debug lock. Returns 0, or -1 with the error string set.
fn h9_kern_chdir(name: [*:0]const u8) callconv(.c) c_int {
    const ch = chan.namec(name, c.Atodir, 0, 0) catch return syserr();
    const h = self();
    if (h) |p|
        sync.qlock(&p.debug);
    const old = up().dot;
    up().dot = ch;
    if (h) |p|
        sync.qunlock(&p.debug);
    chan.cclose(old);
    return 0;
}

/// rfork without RFPROC: changes the caller's own groups (9front's
/// sysrfork).
pub fn rfork(flag: c_int) Error!void {
    try checkflags(flag);
    if ((flag & (c.RFPROC | c.RFMEM | c.RFNOWAIT)) != 0)
        return port.kerror(&port.Ebadarg);
    const h = try uphproc();
    const me = up();

    const ofg: ?*Fgrp = me.fgrp;
    const opg: ?*Pgrp = me.pgrp;
    const org: ?*Rgrp = me.rgrp;
    const oeg = h.egrp;

    {
        errdefer {
            if (me.fgrp != ofg) {
                fgrpclose(me.fgrp);
                swapfgrp(h, ofg);
            }
            if (me.pgrp != opg) {
                pgrp.closepgrp(me.pgrp);
                swappgrp(h, opg);
            }
            if (me.rgrp != org) {
                pgrp.closergrp(me.rgrp);
                me.rgrp = org;
            }
            if (h.egrp != oeg) {
                h9_egrpclose(h.egrp);
                h.egrp = oeg;
            }
        }

        // File descriptors
        if ((flag & (c.RFFDG | c.RFCFDG)) != 0) {
            if ((flag & c.RFFDG) != 0)
                swapfgrp(h, try pgrp.dupfgrp(ofg))
            else
                swapfgrp(h, try pgrp.dupfgrp(null));
        }

        // Process group
        if ((flag & (c.RFNAMEG | c.RFCNAMEG)) != 0) {
            swappgrp(h, try pgrp.newpgrp());
            try pgrp.pgrpcpy(me.pgrp, opg.?, flag);
        }

        // Rendezvous group
        if ((flag & c.RFREND) != 0)
            me.rgrp = try pgrp.newrgrp();

        // Environment group
        if ((flag & (c.RFENVG | c.RFCENVG)) != 0) {
            if ((flag & c.RFENVG) != 0)
                h.egrp = try egrpcopy(oeg)
            else
                h.egrp = try egrpnew();
        }
    }

    if (ofg != me.fgrp)
        fgrpclose(ofg);
    if (opg != me.pgrp)
        pgrp.closepgrp(opg.?);
    if (org != me.rgrp)
        pgrp.closergrp(org.?);
    if (oeg != h.egrp)
        h9_egrpclose(oeg);

    if ((flag & c.RFNOMNT) != 0)
        pgrp.devmask(me.pgrp, true, nomntdevs);
    if ((flag & c.RFNOTEG) != 0) {
        const id = newnoteid(h.mach);
        lock(&h.mach.*.lk); // postnotepg reads noteid under the machine's lock
        h.noteid = id;
        unlock(&h.mach.*.lk);
    }
}

/// rfork for C: 0, or -1 with the error string set.
fn h9_kern_rfork(flag: c_int) callconv(.c) c_int {
    rfork(flag) catch return syserr();
    return 0;
}

/// Lets go of the calling process's fds, namespace, current directory
/// and image (for /proc/n/text) before it ends, so that what they hold
/// (an overlay's pages, say) is freed while the machine that owns it is
/// still there: the process's thread can outlive the machine's wait for
/// it. dot and slash become #/, since pexit closes them. The machine's
/// last process to get here also closes what's posted in its /srv
/// (devsrv.c), which nothing else holds.
fn h9_kern_release() callconv(.c) void {
    const p = up();
    if (@as(?*Fgrp, p.fgrp)) |f| {
        fgrpclose(f);
        p.fgrp = null;
    }
    if (@as(?*Pgrp, p.pgrp)) |g| {
        pgrp.closepgrp(g);
        p.pgrp = null;
    }
    var ch: ?*Chan = p.dot;
    p.dot = bootslash();
    chan.cclose(ch);
    ch = p.slash;
    p.slash = bootslash();
    chan.cclose(ch);

    const h_ = self();
    // The image's channel (/proc/n/text) can hold an overlay too, and so
    // can a chroot's root.
    if (h_) |h| {
        lock(&h.nlk);
        ch = h.textc;
        h.textc = null;
        unlock(&h.nlk);
        if (ch) |t|
            chan.cclose(t);
        ch = h.lroot;
        h.lroot = null;
        if (ch) |r|
            chan.cclose(r);
    }
    const h = h_ orelse return;
    if (h.released != 0)
        return;
    h.released = 1;
    const m: *Hmach = h.mach;
    lock(&m.lk);
    m.nlive -= 1;
    const last = m.nlive == 0;
    unlock(&m.lk);
    if (last) {
        h9_srvmachclose(m);
        h9_hstream_machend(m);
    }
}

/// Ends the calling kernel process; it doesn't return. The parent, if
/// any, gets a wait record built from the exit string set with
/// h9_kern_setexits, as 9front's pexit builds it.
fn h9_kern_exit() callconv(.c) void {
    const h = self() orelse {
        pexit(@constCast(""), 1);
        return;
    };
    // Normally gone already, with h9_kern_release.
    lock(&h.nlk);
    const ch: ?*Chan = h.textc;
    h.textc = null;
    unlock(&h.nlk);
    if (ch) |t|
        chan.cclose(t);
    leave(h);
    // Notes posted from now on are dropped, and devproc no longer looks
    // at its groups, which pexit closes.
    sync.qlock(&h.debug);
    lock(&h.nlk);
    h.exited = 1;
    h.aux = null;
    h.killed = 0;
    h.stopped = 0;
    h.procctl = 0;
    freenotes(h);
    unlock(&h.nlk);
    sync.qunlock(&h.debug);
    // A debugger waiting for it to stop finds it gone (9front's pexit).
    _ = sync.wakeup(&h.stopr);

    // Close the fds before the parent hears of the exit, as 9front's
    // pexit does: a parent's wait that returns while the child's pipe or
    // FIFO ends are still open lets the next reader find a writer that's
    // about to go, read EOF, and leave the next writer waiting for good.
    // (drawterm's pexit would leak the fds' channels anyway.)
    if (@as(?*Fgrp, up().fgrp)) |f| {
        fgrpclose(f);
        up().fgrp = null;
    }

    if (@as(?*Proc, h.parent)) |ph| {
        var w_: ?*Hwait = @ptrCast(@alignCast(c.mallocz(@sizeOf(Hwait), 1)));
        if (w_) |w| {
            w.pid = h.pid;
            w.time[0] = h.cputime[0];
            w.time[1] = h.cputime[1];
            w.time[2] = c.ticks() -% h.start;
            if (h.exitstr[0] != 0)
                _ = c.snprint(&w.msg, w.msg.len, @constCast("%s %lud: %s"), @as([*]u8, &h.text), h.pid, @as([*]u8, &h.exitstr));
        }
        // A Linux parent gets SIGCHLD (design/epoch-0/linux-personality.md),
        // posted under exl with the wait record, so that a wait sees the
        // record only once the signal is pending, as on Linux. Posted
        // after, it could reach a parent that had reaped the child and
        // gone on, and interrupt what it was blocked in then, such as a
        // FIFO's open, with EINTR. (pushnote takes nlk, which is never
        // held while taking exl.)
        var want = false;
        if (h9_wantchld) |wc| {
            lock(&ph.nlk);
            want = ph.aux != null and wc(ph.aux) != 0;
            unlock(&ph.nlk);
        }
        var n_: ?*Hnote = if (want) mknote("linux: signal 17", c.NUser) else null;
        lock(&ph.exl);
        if (ph.dead == 0) {
            ph.nchild -= 1;
            if (w_ != null and ph.nwait < c.Maxwait) {
                const w = w_.?;
                w.next = ph.waitq;
                ph.waitq = w;
                ph.nwait += 1;
                w_ = null;
                _ = sync.wakeup(&ph.waitr);
            }
            if (n_) |n| {
                _ = pushnote(ph, n);
                n_ = null;
            }
            wakewaits(ph);
        }
        unlock(&ph.exl);
        if (n_) |n|
            freenote(n);
        c.free(w_);
        h.parent = null;
        putproc(ph);
    }

    if (@as(?*Proc, h.waiter)) |w| {
        putproc(w);
        h.waiter = null;
    }

    // Prevent my children from leaving waits; wake /proc/n/wait readers.
    lock(&h.exl);
    h.dead = 1;
    _ = sync.wakeup(&h.waitr);
    wakewaits(h);
    h.nchild = 0;
    h.nwait = 0;
    while (@as(?*Hwait, h.waitq)) |w| {
        h.waitq = w.next;
        c.free(w);
    }
    unlock(&h.exl);

    if (h.egrp != null) {
        h9_egrpclose(h.egrp);
        h.egrp = null;
    }
    // pexit drops the thread's reference to the record.
    pexit(@constCast(""), 1);
}

fn haswaitq(x: ?*anyopaque) callconv(.c) c_int {
    const p: *Proc = @ptrCast(@alignCast(x.?));
    return @intFromBool(@as(*volatile [*c]Hwait, &p.waitq).* != null);
}

/// await: waits for a child to exit and formats its wait record into
/// buf as 9front's sysawait does ("pid utime stime real 'msg'").
/// Returns the length; an error is no children ("no living children"),
/// another await in progress, or interrupted.
pub fn await(buf: [*]u8, n: c_int) Error!c_int {
    const h = try uphproc();
    if (!sync.canqlock(&h.qwaitr))
        return port.kerror(&port.Einuse);
    const w = blk: {
        defer sync.qunlock(&h.qwaitr);
        lock(&h.exl);
        while (h.waitq == null) {
            if (h.nchild == 0) {
                unlock(&h.exl);
                return port.kerror(&port.Enochild);
            }
            unlock(&h.exl);
            try sync.sleep(&h.waitr, haswaitq, h);
            lock(&h.exl);
        }
        const w: *Hwait = h.waitq;
        h.waitq = w.next;
        h.nwait -= 1;
        unlock(&h.exl);
        break :blk w;
    };

    const len = c.snprint(buf, n, @constCast("%lud %lud %lud %lud %q"), w.pid, w.time[0], w.time[1], w.time[2], @as([*]u8, &w.msg));
    c.free(w);
    return len;
}

/// await for C: the length, or -1 with the error string set.
fn h9_kern_await(buf: [*]u8, n: c_int) callconv(.c) c_int {
    return await(buf, n) catch return syserr();
}

/// The exit string the parent's wait record will carry; empty for
/// success.
fn h9_kern_setexits(msg: [*c]const u8) callconv(.c) void {
    if (self()) |h|
        strecpy(&h.exitstr, msg);
}

/// The calling process's machine-local pid, and setting it.
fn h9_kern_gpid() callconv(.c) c_uint {
    return if (self()) |h| h.pid else 0;
}

/// The calling process's parent's pid when it was made, as
/// /proc/n/ppid.
fn h9_kern_gppid() callconv(.c) c_uint {
    return if (self()) |h| h.ppid else 0;
}

fn h9_kern_setgpid(pid: c_uint) callconv(.c) void {
    if (self()) |h|
        h.pid = pid;
}

/// The process's name in wait records; exec sets it to the program's.
fn h9_kern_settext(text: [*c]const u8) callconv(.c) void {
    strecpy(&up().text, text);
}

/// The Zig process behind the calling kernel process.
fn h9_kern_aux() callconv(.c) ?*anyopaque {
    return if (self()) |h| h.aux else null;
}

fn h9_kern_setaux(aux: ?*anyopaque) callconv(.c) void {
    const h = self() orelse return;
    // h9_notekick reads aux under nlk.
    lock(&h.nlk);
    h.aux = aux;
    unlock(&h.nlk);
}

/// Closes the calling process's close-on-exec fds, as exec does.
fn h9_kern_closeexec() callconv(.c) void {
    const f: *Fgrp = up().fgrp;
    var i: c_int = 0;
    while (true) : (i += 1) {
        lock(&f.ref.lk);
        if (i > f.maxfd) {
            unlock(&f.ref.lk);
            break;
        }
        const k: usize = @intCast(i);
        const cexec = f.fd[k] != null and (f.flag[k] & c.CCEXEC) != 0;
        unlock(&f.ref.lk);
        if (cexec)
            _ = sysclose(i);
    }
}

// kserve's kernel processes (kserve.c, design/epoch-0/kernel-serve.md)
// act for the process that started serving: each gets a record of its
// own in that process's machine, sharing its environment, so devices
// that look up the caller's machine (#ℓ, #s, #p) see the server's. Its
// pid is 0, so /proc doesn't list it and no pid finds it, and its note
// group is its own, so a note to a group never reaches it.
//
// h9_kprocsrc returns the calling process's record, referenced, for
// h9_kprocshare in the new kproc; h9_kprocput drops that reference.

fn h9_kprocsrc() callconv(.c) ?*anyopaque {
    const h = self() orelse return null;
    _ = incref(&h.ref);
    return h;
}

fn h9_kprocput(v: ?*Proc) callconv(.c) void {
    putproc(v);
}

fn h9_kprocshare(src_: ?*Proc, text: [*c]const u8) callconv(.c) c_int {
    const src = src_ orelse return -1;
    if (self() != null)
        return -1;
    const h = up();
    strecpy(&h.text, text);
    h.mach = src.mach;
    _ = incref(&h.mach.*.ref);
    h.ppid = src.pid;
    if (src.egrp != null) {
        h9_egrpincref(src.egrp);
        h.egrp = src.egrp;
    }
    h.noteid = newnoteid(h.mach);
    h.released = 1; // never counted among the machine's live processes
    enter(h);
    return 0;
}

/// Ends what h9_kprocshare began, before the kproc's pexit.
fn h9_kprocunshare() callconv(.c) void {
    const h = self() orelse return;
    leave(h);
    lock(&h.nlk);
    freenotes(h);
    freenote(h.lastnote);
    h.lastnote = null;
    unlock(&h.nlk);
    const e = h.egrp;
    h.egrp = null;
    if (e != null)
        h9_egrpclose(e);
    // A kproc again: no machine.
    putmach(h.mach);
    h.mach = null;
    h.pid = 0;
    h.ppid = 0;
    h.noteid = 0;
}

// The C kernel's names for procinit.c's, with its semantics.

fn c_procinit0() callconv(.c) void {
    procinit0() catch |e| port.raise(e);
}
fn c_newproc() callconv(.c) ?*Proc {
    return newproc();
}

pub fn exportC() void {
    @export(&wakewaits, .{ .name = "wakewaits" });
    @export(&c_procinit0, .{ .name = "procinit0" });
    @export(&c_newproc, .{ .name = "newproc" });
    @export(&kproc, .{ .name = "kproc" });
    @export(&pexit, .{ .name = "pexit" });
    @export(&h9_notekick, .{ .name = "h9_notekick" });
    @export(&h9_postnote, .{ .name = "h9_postnote" });
    @export(&h9_kern_postnote, .{ .name = "h9_kern_postnote" });
    @export(&h9_kern_selfref, .{ .name = "h9_kern_selfref" });
    @export(&h9_kern_postnoteref, .{ .name = "h9_kern_postnoteref" });
    @export(&h9_kern_unref, .{ .name = "h9_kern_unref" });
    @export(&h9_kern_mach, .{ .name = "h9_kern_mach" });
    @export(&h9_kern_putmach, .{ .name = "h9_kern_putmach" });
    @export(&h9_kern_postmach, .{ .name = "h9_kern_postmach" });
    @export(&h9_procstatus, .{ .name = "h9_procstatus" });
    @export(&h9_procthreads, .{ .name = "h9_procthreads" });
    @export(&h9_wantchld, .{ .name = "h9_wantchld" });
    @export(&h9_procsegment, .{ .name = "h9_procsegment" });
    @export(&h9_stopkick, .{ .name = "h9_stopkick" });
    @export(&h9_procdebug, .{ .name = "h9_procdebug" });
    @export(&h9_uphproc, .{ .name = "h9_uphproc" });
    @export(&h9_fs_nofollow, .{ .name = "h9_fs_nofollow" });
    @export(&h9_fs_nofollowing, .{ .name = "h9_fs_nofollowing" });
    @export(&h9_pidlookup, .{ .name = "h9_pidlookup" });
    @export(&h9_putproc, .{ .name = "h9_putproc" });
    @export(&h9_pids, .{ .name = "h9_pids" });
    @export(&h9_mknote, .{ .name = "h9_mknote" });
    @export(&h9_freenote, .{ .name = "h9_freenote" });
    @export(&h9_pushnote, .{ .name = "h9_pushnote" });
    @export(&h9_postnotepg, .{ .name = "h9_postnotepg" });
    @export(&h9_setnoteid, .{ .name = "h9_setnoteid" });
    @export(&h9_killproc, .{ .name = "h9_killproc" });
    @export(&h9_kern_setargs, .{ .name = "h9_kern_setargs" });
    @export(&h9_kern_postnotepg, .{ .name = "h9_kern_postnotepg" });
    @export(&h9_kern_noteid, .{ .name = "h9_kern_noteid" });
    @export(&h9_kern_setnotify, .{ .name = "h9_kern_setnotify" });
    @export(&h9_kern_notepending, .{ .name = "h9_kern_notepending" });
    @export(&h9_kern_popnote, .{ .name = "h9_kern_popnote" });
    @export(&h9_kern_noted, .{ .name = "h9_kern_noted" });
    @export(&h9_kern_execnotes, .{ .name = "h9_kern_execnotes" });
    @export(&h9_kern_wantstop, .{ .name = "h9_kern_wantstop" });
    @export(&h9_kern_stopwait, .{ .name = "h9_kern_stopwait" });
    @export(&h9_kern_unstop, .{ .name = "h9_kern_unstop" });
    @export(&h9_kern_killed, .{ .name = "h9_kern_killed" });
    @export(&h9_kern_exechang, .{ .name = "h9_kern_exechang" });
    @export(&h9_kern_settextpath, .{ .name = "h9_kern_settextpath" });
    @export(&h9_fgrpclose, .{ .name = "h9_fgrpclose" });
    @export(&h9_kprocdetach, .{ .name = "h9_kprocdetach" });
    @export(&h9_proc_boot, .{ .name = "h9_proc_boot" });
    @export(&h9_kern_newmach, .{ .name = "h9_kern_newmach" });
    @export(&h9_kern_machkernel, .{ .name = "h9_kern_machkernel" });
    @export(&h9_kern_machdetach, .{ .name = "h9_kern_machdetach" });
    @export(&h9_kern_spawn, .{ .name = "h9_kern_spawn" });
    @export(&h9_kern_setsched, .{ .name = "h9_kern_setsched" });
    @export(&h9_kern_kprocdetached, .{ .name = "h9_kern_kprocdetached" });
    @export(&h9_kern_adopt, .{ .name = "h9_kern_adopt" });
    @export(&h9_kern_isolated, .{ .name = "h9_kern_isolated" });
    @export(&h9_kern_fork, .{ .name = "h9_kern_fork" });
    @export(&h9_kern_chdir, .{ .name = "h9_kern_chdir" });
    @export(&h9_kern_rfork, .{ .name = "h9_kern_rfork" });
    @export(&h9_kern_release, .{ .name = "h9_kern_release" });
    @export(&h9_kern_exit, .{ .name = "h9_kern_exit" });
    @export(&h9_kern_await, .{ .name = "h9_kern_await" });
    @export(&h9_kern_setexits, .{ .name = "h9_kern_setexits" });
    @export(&h9_kern_gpid, .{ .name = "h9_kern_gpid" });
    @export(&h9_kern_gppid, .{ .name = "h9_kern_gppid" });
    @export(&h9_kern_setgpid, .{ .name = "h9_kern_setgpid" });
    @export(&h9_kern_settext, .{ .name = "h9_kern_settext" });
    @export(&h9_kern_aux, .{ .name = "h9_kern_aux" });
    @export(&h9_kern_setaux, .{ .name = "h9_kern_setaux" });
    @export(&h9_kern_closeexec, .{ .name = "h9_kern_closeexec" });
    @export(&h9_kprocsrc, .{ .name = "h9_kprocsrc" });
    @export(&h9_kprocput, .{ .name = "h9_kprocput" });
    @export(&h9_kprocshare, .{ .name = "h9_kprocshare" });
    @export(&h9_kprocunshare, .{ .name = "h9_kprocunshare" });
}

const testing = std.testing;
const kt = port.testing;

/// Makes the test's process a guest process with pid 1 in a machine of
/// its own, and undoes it.
const Guest = struct {
    m: *Hmach,

    fn begin(p: *Proc) !Guest {
        const m: *Hmach = @ptrCast(@alignCast(h9_kern_newmach(null) orelse return error.OutOfMemory));
        p.mach = m;
        _ = incref(&m.ref);
        p.pid = 1;
        p.noteid = newnoteid(m);
        enter(p);
        return .{ .m = m };
    }

    fn end(g: Guest, p: *Proc) void {
        leave(p);
        lock(&p.nlk);
        freenotes(p);
        freenote(p.lastnote);
        p.lastnote = null;
        p.notify = 0;
        p.notified = 0;
        unlock(&p.nlk);
        putmach(p.mach);
        p.mach = null;
        p.pid = 0;
        p.notepending = 0;
        h9_kern_machdetach(g.m);
    }
};

test "rfork's flags are checked, and only a guest process may rfork [kernel-port]" {
    _ = try kt.begin();
    try testing.expectError(error.Kernel, rfork(c.RFFDG | c.RFCFDG));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Ebadarg)), kt.errstr());
    try testing.expectError(error.Kernel, rfork(c.RFNAMEG));
    try testing.expectEqualStrings("not an h9 process", kt.errstr());
    try testing.expectEqual(-1, h9_kern_rfork(c.RFPROC));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Ebadarg)), std.mem.sliceTo(up().syserrstr, 0));
    try testing.expectError(error.Kernel, fork(0, 2, undefined, null));
}

test "a note queues, popnote takes it with the pc on a sys: note, and a system note with no handler drops the queue [kernel-port]" {
    const p = try kt.begin();
    const g = try Guest.begin(p);
    defer g.end(p);

    try testing.expectEqual(1, h9_kern_postnote(1, "one", c.NUser));
    try testing.expectEqual(1, p.notepending);
    try testing.expectEqual(1, h9_kern_notepending());
    try testing.expectEqual(-1, h9_kern_postnote(2, "nobody", c.NUser));

    // A handler takes the user note; a second user note waits while in it.
    h9_kern_setnotify(1);
    var msg: [port.ERRMAX]u8 = undefined;
    try testing.expectEqual(c.Nhandle, h9_kern_popnote(&msg, 0x1234));
    try testing.expectEqualStrings("one", std.mem.sliceTo(&msg, 0));
    try testing.expectEqual(1, h9_kern_postnote(1, "two", c.NUser));
    try testing.expectEqual(c.Nnone, h9_kern_popnote(&msg, 0));
    try testing.expectEqual(c.Nnone, h9_kern_noted(0, &msg));

    // A system note to a process in its handler drops what's queued,
    // and kills it with the pc appended.
    h9_kern_setnotify(0);
    try testing.expectEqual(1, h9_kern_postnote(1, "sys: trap", c.NExit));
    try testing.expectEqual(1, p.nnote);
    try testing.expectEqual(c.Nkill, h9_kern_popnote(&msg, 0x1234));
    try testing.expectEqualStrings("sys: trap pc=0x1234", std.mem.sliceTo(&msg, 0));
    try testing.expectEqual(-1, h9_kern_noted(1, &msg));

    // A full queue refuses more.
    for (0..c.NNOTE) |_|
        try testing.expectEqual(1, h9_kern_postnote(1, "x", c.NUser));
    try testing.expectEqual(0, h9_kern_postnote(1, "x", c.NUser));
}

test "pids are listed in order, and a note group must exist to be joined [kernel-port]" {
    const p = try kt.begin();
    const g = try Guest.begin(p);
    defer g.end(p);

    var others: [3]Proc = undefined;
    for (&others, [_]c_uint{ 7, 3, 5 }) |*o, pid| {
        o.* = std.mem.zeroes(Proc);
        o.ref.ref = 1;
        o.pid = pid;
        o.noteid = 99;
        o.mach = g.m;
        enter(o);
    }
    defer for (&others) |*o| leave(o);
    var pids: [8]c_uint = undefined;
    try testing.expectEqual(4, h9_pids(g.m, &pids, pids.len));
    try testing.expectEqualSlices(c_uint, &.{ 1, 3, 5, 7 }, pids[0..4]);
    try testing.expectEqual(2, h9_pids(g.m, &pids, 2));

    const h = h9_pidlookup(g.m, 5) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(&others[2], h);
    _ = decref(&h.ref);
    try testing.expectEqual(null, h9_pidlookup(g.m, 4));

    try testing.expectEqual(-1, h9_setnoteid(p, 1000));
    try testing.expectEqual(0, h9_setnoteid(p, 99));
    try testing.expectEqual(99, h9_kern_noteid());
}
