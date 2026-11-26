/*
 * The process record (design/kernel-port.md, "One process record"):
 * drawterm's Proc, first, and then what 9front keeps in its Proc and
 * drawterm's lacks, in one allocation with one lifetime. drawterm's C
 * sees only the Proc; h9 converts a Proc* to its Hproc* (the same
 * address), so every Proc is made as an Hproc (proc.zig's newproc).
 *
 * An Hproc with mach set is a guest process (or kserve's helper, with
 * pid 0); a kproc has none. The record is counted (ref): the thread
 * holds one reference until pexit, a child holds its parent's, and
 * lookups (h9_pidlookup) take one. Once its thread has exited (exited)
 * the Plan 9 groups are gone, and what's left is what /proc and a parent
 * read: the pid, text, wait records and exit string.
 */

typedef struct Hproc Hproc;
typedef struct Hmach Hmach;
typedef struct Hnote Hnote;
typedef struct Hwait Hwait;

enum
{
	TEXTLEN		= 64,
	ARGSLEN		= 128,	/* args kept for /proc, as 9front */
	NNOTE		= 5,	/* queued notes, as 9front */
};

struct Hproc
{
	/*
	 * drawterm's, at offset 0, so a Proc* is its Hproc*. Its errlab is
	 * a jmp_buf, which MinGW aligns to 16 (SETJMP_FLOAT128) and Zig's
	 * translation only to 8, so the C's Proc can be bigger, by its tail
	 * padding, than the Zig's: what follows it is aligned to 16, which
	 * puts it at the same offset for both. proc.zig checks the offsets
	 * against the C's (the enum below) on every target, and malloc's
	 * blocks are 16-aligned on all of them.
	 */
	Proc	p;

	__int128	align16[0];	/* aligns what follows to 16, as _Alignas would were it translated */
	Ref	ref;
	void	*egrp;		/* devenv.c's HEgrp */

	/*
	 * Where the process runs. The scheduler (design/scheduler.md) puts
	 * its continuation here; nil until then, while each Proc has a host
	 * thread and up is that thread's (p.oproc).
	 */
	void	*cont;

	/* The machine, and its list of processes (under mach->lk). */
	Hmach	*mach;
	Hproc	*mnext;

	/*
	 * The ABI's state (src/machine.zig's Proc): its registers, its
	 * address space (a 9front process's two Mms, shared and stack, in
	 * src/segment.zig's Space, or a Linux process's one) and its Linux
	 * state; nil for a kproc. Set under nlk; h9's hooks below take it.
	 */
	void	*aux;

	/*
	 * The name in wait records and /proc; exec sets it. drawterm's
	 * p.text (KNAMELEN) holds as much of it as fits.
	 */
	char	text[TEXTLEN];
	ulong	start;		/* ticks() at creation, for the real time */
	ulong	ppid;		/* the parent's pid when created, for /proc/n/ppid */
	Lock	alk;		/* guards args, nargs and setargs */
	char	args[ARGSLEN];	/* exec's argv, NUL-separated, as 9front's p->args */
	int	nargs;
	int	setargs;	/* args was written through /proc */
	int	hang;		/* ctl hang: exec stops the process before it runs */
	char	exitstr[ERRMAX];
	ulong	cputime[2];	/* user and sys ms for the wait record, set by the Linux ABI */
	int	released;	/* h9_kern_release has run; only its own thread looks */
	QLock	debug;		/* held to swap or drop the fgrp, pgrp and dot, and to read them from devproc */

	Lock	nlk;		/* guards the note fields below */
	int	exited;		/* its thread is gone (h9_kern_exit); set under debug and nlk */
	int	killed;		/* ctl kill: die with "Killed" at the next delivery */
	ulong	noteid;
	int	notify;		/* has a note handler */
	int	notified;	/* in the handler */
	int	nnote;
	Hnote	*note[NNOTE];
	Hnote	*lastnote;	/* the note being handled, or that killed it */

	/* Debugging (design/epoch-0/self-host.md); under nlk. */
	int	procctl;	/* Pstopme or Ptraceme: stop at the next stop point */
	int	stopped;	/* parked at a stop point until ctl start */
	int	pdbg;		/* a debugger waits in stopr for it to stop */
	int	stopwait;	/* this process waits for another to stop, for status */
	Rendez	startr;		/* the stopped process sleeps here */
	Rendez	stopr;		/* its debugger sleeps here */
	Chan	*textc;		/* the executed image, open, for /proc/n/text; or nil */

	Hproc	*parent;	/* nil with RFNOWAIT or for a machine's first process */
	int	nofollow;	/* the next lookup acts on a link in its last name (h9_fs_nofollow); only its own thread looks */
	Chan	*lroot;		/* the Linux root chroot(2) set (design/epoch-0/linux-chroot.md), or nil for #L; only its own thread looks */
	/*
	 * A Linux thread's group leader (RFLXTHREAD), or nil: its forks are
	 * the leader's children, and its Linux waits read the leader's wait
	 * records, as a Linux process's threads share its children.
	 */
	Hproc	*waiter;
	Hproc	*wnext;		/* on the waiter's wsleep list */
	Rendez	lwaitr;		/* a Linux wait sleeps here */
	Lock	exl;		/* guards the fields below */
	int	dead;		/* exited; children leave no wait records */
	int	nchild;
	int	nwait;
	Hwait	*waitq;
	QLock	qwaitr;		/* one waiter at a time */
	Rendez	waitr;
	Hproc	*wsleep;	/* Linux waits sleeping for this process's children */
	ulong	wgen;		/* bumped when waitq, nchild or dead change, for them */
};

/*
 * The C compiler's layout of the record, as constants, whose values
 * translate-c carries over as the compiler computed them: proc.zig
 * checks the Zig's offset of every Proc field, and the sizes, against
 * them.
 */
enum
{
	Procsize	= sizeof(Proc),
	Hprocsize	= sizeof(Hproc),
	Hprocref	= __builtin_offsetof(Hproc, ref),
	Hprocwgen	= __builtin_offsetof(Hproc, wgen),
	Poffstate	= __builtin_offsetof(Proc, state),
	Poffmach	= __builtin_offsetof(Proc, mach),
	Poffpid		= __builtin_offsetof(Proc, pid),
	Poffpgrp	= __builtin_offsetof(Proc, pgrp),
	Pofffgrp	= __builtin_offsetof(Proc, fgrp),
	Poffrgrp	= __builtin_offsetof(Proc, rgrp),
	Poffrlock	= __builtin_offsetof(Proc, rlock),
	Poffr		= __builtin_offsetof(Proc, r),
	Poffksleep	= __builtin_offsetof(Proc, sleep),	/* lib.h names the field ksleep */
	Poffnotepending	= __builtin_offsetof(Proc, notepending),
	Poffkp		= __builtin_offsetof(Proc, kp),
	Poffrendtag	= __builtin_offsetof(Proc, rendtag),
	Poffrendval	= __builtin_offsetof(Proc, rendval),
	Poffrendhash	= __builtin_offsetof(Proc, rendhash),
	Poffnerrlab	= __builtin_offsetof(Proc, nerrlab),
	Pofferrlab	= __builtin_offsetof(Proc, errlab),
	Poffuser	= __builtin_offsetof(Proc, user),
	Poffsyserrstr	= __builtin_offsetof(Proc, syserrstr),
	Pofferrstr	= __builtin_offsetof(Proc, errstr),
	Pofferrbuf0	= __builtin_offsetof(Proc, errbuf0),
	Pofferrbuf1	= __builtin_offsetof(Proc, errbuf1),
	Poffgenbuf	= __builtin_offsetof(Proc, genbuf),
	Pofftext	= __builtin_offsetof(Proc, text),
	Poffslash	= __builtin_offsetof(Proc, slash),
	Poffdot		= __builtin_offsetof(Proc, dot),
	Poffqnext	= __builtin_offsetof(Proc, qnext),
	Pofffn		= __builtin_offsetof(Proc, fn),
	Poffarg		= __builtin_offsetof(Proc, arg),
	Poffoproc	= __builtin_offsetof(Proc, oproc),
};
