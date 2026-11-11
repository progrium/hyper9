/*
 * Coroutines on JavaScript Promise Integration, for the web host
 * (design/browser-host.md). Each kernel process, and each of h9's own
 * tasks that would be a thread natively, is a coroutine with its own
 * shadow stack. Blocking parks the coroutine and hands the event loop back
 * to the JS host (src/web/h9-web.js), which is the scheduler.
 */

typedef struct H9coro H9coro;
struct H9coro
{
	int	id;		/* the JS host's token */
	char	name[32];
	unsigned char	*lo;	/* stack, low end (canary) */
	unsigned char	*hi;
	unsigned long	size;
	void	(*fn)(void*);
	void	*arg;
	void	*proc;		/* drawterm's up */
	int	err;		/* errno while parked */
	void	*zls[4];	/* h9's per-thread Zig state while parked */
	void	*exitjb;	/* coroutine exit (jmp_buf*) */
	int	done;
	unsigned long	maxdepth;	/* deepest stack use seen at a park */
	H9coro	*next;		/* free list */
};

H9coro*	h9_coro_self(void);
H9coro*	h9_coro_spawn(char *name, void (*fn)(void*), void *arg, unsigned long stk);
int	h9_coro_park(long ms);	/* 1 if woken, 0 if the time ran out; ms < 0 waits */
void	h9_coro_unpark(H9coro*);
void	h9_coro_yield(void);
void	h9_coro_sleep(long ms);
void	h9_coro_exit(void);
void	h9_coro_panic(char*);
unsigned long	h9_coro_maxdepth(void);
void	h9_coro_save(H9coro*);
void	h9_coro_restore(H9coro*);
