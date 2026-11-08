//! The calling host thread's CPU time, user and system, for getrusage,
//! wait4's rusage and the wait record's times (design/0018-linux-
//! personality.md, "Processes"). A guest thread runs on one host thread
//! for its life, so a difference of two readings on it is the guest
//! thread's time, the guest's own instructions counted as the host
//! counts them (as user time under HVF and KVM).

const std = @import("std");
const builtin = @import("builtin");

pub const Times = struct {
    user_ns: u64 = 0,
    sys_ns: u64 = 0,

    pub fn add(a: Times, b: Times) Times {
        return .{ .user_ns = a.user_ns +| b.user_ns, .sys_ns = a.sys_ns +| b.sys_ns };
    }

    /// a - b, or zero where b is ahead (another thread's baseline).
    pub fn since(a: Times, b: Times) Times {
        return .{ .user_ns = a.user_ns -| b.user_ns, .sys_ns = a.sys_ns -| b.sys_ns };
    }
};

/// The calling thread's CPU time so far; zero where the host can't say.
pub fn thread() Times {
    switch (builtin.os.tag) {
        .linux => {
            // RUSAGE_THREAD splits it, as clock_gettime can't.
            var ru: std.c.rusage = undefined;
            if (std.c.getrusage(1, &ru) != 0) return .{};
            return .{ .user_ns = tvNs(ru.utime), .sys_ns = tvNs(ru.stime) };
        },
        .macos => {
            const port = mach.mach_thread_self();
            defer _ = mach.mach_port_deallocate(std.c.mach_task_self(), port);
            var info: mach.ThreadBasicInfo = undefined;
            var count: u32 = @sizeOf(mach.ThreadBasicInfo) / 4;
            if (mach.thread_info(port, mach.THREAD_BASIC_INFO, @ptrCast(&info), &count) != 0) return .{};
            return .{ .user_ns = mach.ns(info.user_time), .sys_ns = mach.ns(info.system_time) };
        },
        .windows => {
            var create: u64 = 0;
            var exit: u64 = 0;
            var kernel: u64 = 0;
            var user: u64 = 0;
            if (win.GetThreadTimes(win.GetCurrentThread(), &create, &exit, &kernel, &user) == 0) return .{};
            // 100 ns units.
            return .{ .user_ns = user * 100, .sys_ns = kernel * 100 };
        },
        else => return .{},
    }
}

fn tvNs(tv: std.c.timeval) u64 {
    const s: u64 = @intCast(@max(tv.sec, 0));
    const us: u64 = @intCast(@max(tv.usec, 0));
    return s * std.time.ns_per_s + us * std.time.ns_per_us;
}

const mach = struct {
    const THREAD_BASIC_INFO: c_int = 3;
    const TimeValue = extern struct { seconds: i32, microseconds: i32 };
    const ThreadBasicInfo = extern struct {
        user_time: TimeValue,
        system_time: TimeValue,
        cpu_usage: i32,
        policy: i32,
        run_state: i32,
        flags: i32,
        suspend_count: i32,
        sleep_time: i32,
    };
    extern "c" fn mach_thread_self() std.c.mach_port_t;
    extern "c" fn mach_port_deallocate(task: std.c.mach_port_t, name: std.c.mach_port_t) c_int;
    extern "c" fn thread_info(thread: std.c.mach_port_t, flavor: c_int, info: [*]i32, count: *u32) c_int;

    fn ns(t: TimeValue) u64 {
        return @as(u64, @intCast(@max(t.seconds, 0))) * std.time.ns_per_s + @as(u64, @intCast(@max(t.microseconds, 0))) * std.time.ns_per_us;
    }
};

const win = struct {
    extern "kernel32" fn GetCurrentThread() callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetThreadTimes(thread: ?*anyopaque, create: *u64, exit: *u64, kernel: *u64, user: *u64) callconv(.winapi) c_int;
};

test "a thread's CPU time grows as it spins" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .windows) return error.SkipZigTest;
    const a = thread();
    var x: u64 = 0;
    var i: u64 = 0;
    while (i < 50_000_000) : (i += 1) x +%= i *% 2654435761;
    std.mem.doNotOptimizeAway(x);
    const d = thread().since(a);
    try std.testing.expect(d.user_ns + d.sys_ns > 0);
}
