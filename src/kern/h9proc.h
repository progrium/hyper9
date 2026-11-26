/*
 * The process record (design/kernel-port.md, "One process record"):
 * drawterm's Proc and what was h9's second record, Hproc, in one, so a
 * process is one allocation with one lifetime. third_party's dat.h
 * includes this in place of its struct Proc.
 *
 * A Proc with mach set is a guest process (or kserve's helper, with pid
 * 0); a kproc has none. The record is counted (ref): the thread holds one
 * reference until pexit, a child holds its parent's, and lookups
 * (h9_pidlookup) take one. Once its thread has exited (exited) the
 * Plan 9 groups are gone, and what's left is what /proc and a parent
 * read: the pid, text, wait records and exit string.
 */

typedef struct Hmach Hmach;
typedef struct Hnote Hnote;
typedef struct Hwait Hwait;

enum
{
	TEXTLEN		= 64,
	ARGSLEN		= 128,	/* args kept for /proc, as 9front's exec */
	NNOTE		= 5,	/* queued notes, as 9front */
};

struct Proc
{
	/*
	 * First, so it is at offset 0 for the C and the Zig alike. MinGW's
	 * jmp_buf is 16-aligned (SETJMP_FLOAT128) and Zig's translation of
	 * it only 8-aligned, so anywhere else the two put errlab, and every
	 * field after it, at different offsets on Windows. The array's size
	 * is a multiple of 16 (proc.zig checks), so the fields after it agree.
	 */
	Label	errlab[NERR];
	Ref	ref;
	uint	state;

	ulong	pid;		/* machine-local; 0 for a kproc */

	Pgrp	*pgrp;		/* Process group for namespace */
	Fgrp	*fgrp;		/* File descriptor group */
	Rgrp	*rgrp;
	void	*egrp;		/* devenv.c's HEgrp */

	Lock	rlock;		/* sync sleep/wakeup with postnote */
	Rendez	*r;		/* rendezvous point slept on */
	Rendez	sleep;		/* place for syssleep/debug */
	int	notepending;	/* note issued but not acted on */
	int	kp;		/* true if a kernel process */

	void*	rendtag;	/* Tag for rendezvous */
	void*	rendval;	/* Value for rendezvous */
	Proc	*rendhash;	/* Hash list for tag values */

	int	nerrlab;
	char	user[KNAMELEN];
	char	*syserrstr;	/* last error from a system call, errbuf0 or 1 */
	char	*errstr;	/* reason we're unwinding the error stack, errbuf1 or 0 */
	char	errbuf0[ERRMAX];
	char	errbuf1[ERRMAX];
	char	genbuf[128];	/* buffer used e.g. for last name element from namec */
	char	text[TEXTLEN];	/* the name in wait records and /proc; exec sets it */

	Chan	*slash;
	Chan	*dot;

	Proc	*qnext;

	void	(*fn)(void*);
	void	*arg;

	/*
	 * Where the process runs. The scheduler (design/scheduler.md) puts
	 * its continuation here; nil until then, while each Proc has a host
	 * thread and up is that thread's (oproc).
	 */
	void	*cont;
	char oproc[1024];	/* reserved for os */

	/* The machine, and its list of processes (under mach->lk). */
	Hmach	*mach;
	Proc	*mnext;

	/*
	 * The ABI's state (src/machine.zig's Proc): its registers, its
	 * address space (a 9front process's two Mms, shared and stack, in
	 * src/segment.zig's Space, or a Linux process's one) and its Linux
	 * state; nil for a kproc. Set under nlk; h9's hooks below take it.
	 */
	void	*aux;

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

	Proc	*parent;	/* nil with RFNOWAIT or for a machine's first process */
	int	nofollow;	/* the next lookup acts on a link in its last name (h9_fs_nofollow); only its own thread looks */
	Chan	*lroot;		/* the Linux root chroot(2) set (design/epoch-0/linux-chroot.md), or nil for #L; only its own thread looks */
	/*
	 * A Linux thread's group leader (RFLXTHREAD), or nil: its forks are
	 * the leader's children, and its Linux waits read the leader's wait
	 * records, as a Linux process's threads share its children.
	 */
	Proc	*waiter;
	Proc	*wnext;		/* on the waiter's wsleep list */
	Rendez	lwaitr;		/* a Linux wait sleeps here */
	Lock	exl;		/* guards the fields below */
	int	dead;		/* exited; children leave no wait records */
	int	nchild;
	int	nwait;
	Hwait	*waitq;
	QLock	qwaitr;		/* one waiter at a time */
	Rendez	waitr;
	Proc	*wsleep;	/* Linux waits sleeping for this process's children */
	ulong	wgen;		/* bumped when waitq, nchild or dead change, for them */
};
