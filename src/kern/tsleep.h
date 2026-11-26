/*
 * tsleep (tsleep.c) and the host side of its timer kproc: a lock, a
 * condition variable and the monotonic clock (glue.c on POSIX hosts,
 * glue-win32.c on Windows).
 */

void	tsleep(Rendez*, int (*)(void*), void*, ulong);
int	h9_tsleepintr(Rendez*, int (*)(void*), void*, ulong);	/* -1 if interrupted, in place of raising */
int	h9_sleepintr(Rendez*, int (*)(void*), void*);		/* sleep's, from src/kern/sync.zig */
void	h9_tsleepinit(void);

void	h9_tinit(void);
uvlong	h9_tnow(void);		/* host monotonic ns */
void	h9_tlock(void);
void	h9_tunlock(void);
void	h9_tsignal(void);	/* with the lock held */
void	h9_twait(uvlong);	/* with the lock held: until the deadline (0: none) or a signal */
