/*
 * h9's hooks for drawterm's devcons (design/go-compat.md): #c/pid,
 * #c/ppid, nanosecond /dev/bintime and /dev/time, and a /dev/sysstat line
 * per CPU. The C side is src/kern/consx.c; the clock and the CPU count
 * are Zig leaves (src/kern.zig). None of them fail or raise kernel errors.
 */

/* Read handlers, called as devcons's own are: off is the file offset. */
long	h9_cons_pid(ulong off, char *buf, long n);
long	h9_cons_ppid(ulong off, char *buf, long n);
long	h9_cons_bintime(char *buf, long n);
long	h9_cons_time(ulong off, char *buf, long n);
long	h9_cons_sysstat(ulong off, char *buf, long n);

/* Zig leaves. Nanoseconds: wall time, and monotonic time that starts at
 * the wall time when the kernel boots. */
vlong	h9_clock_wall(void);
vlong	h9_clock_mono(void);
/* The CPUs the calling process's machine may use, at least 1. */
int	h9_cons_ncpu(void);
