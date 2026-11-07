/*
 * h9's per-process records (proc.c), shared with devproc.c. See proc.c.
 */

enum
{
	RFNAMEG		= (1<<0),
	RFENVG		= (1<<1),
	RFFDG		= (1<<2),
	RFNOTEG		= (1<<3),
	RFPROC		= (1<<4),
	RFMEM		= (1<<5),
	RFNOWAIT	= (1<<6),
	RFCNAMEG	= (1<<10),
	RFCENVG		= (1<<11),
	RFCFDG		= (1<<12),
	RFREND		= (1<<13),
	RFNOMNT		= (1<<14),

	Maxwait		= 128,	/* wait records a parent keeps, as 9front */
	PROCHASH	= 64,
	TEXTLEN		= 64,
	ARGSLEN		= 128,	/* args kept for /proc, as 9front's exec */
	NNOTE		= 5,	/* queued notes, as 9front */

	/* procctl, as 9front's Proc_stopme and Proc_traceme */
	Pstopme		= 1,	/* stop at the next stop point */
	Ptraceme	= 2,	/* stop at the next stop point with a note queued */
};

/* h9_kern_popnote's results. */
enum
{
	Nnone,		/* no note to act on */
	Nhandle,	/* enter the handler with the note */
	Nkill,		/* die with the note as the exit status */
	Nkilldebug,	/* the same, and print "suicide: note" first */
};

/* devenv.c */
extern void	*h9_egrpnew(void);
extern void	*h9_egrpcopy(void*);
extern void	h9_egrpincref(void*);
extern void	h9_egrpclose(void*);

typedef struct Hwait Hwait;
typedef struct Hproc Hproc;
typedef struct Hmach Hmach;
typedef struct Hnote Hnote;

/* A machine: the processes descended from one h9_kern_spawn. */
struct Hmach
{
	Ref	ref;		/* one per record */
	Lock	lk;
	ulong	nextnoteid;
	int	nlive;		/* processes not yet released (h9_kern_release); under lk */
	void	*srv;		/* devsrv.c's registry, made on first attach; under lk */
	int	cmdsend;	/* its host commands are killed (hostcmd.c); under hostcmd.c's lock */
};

/* 9front's Note. One note posted to a group is shared by its queues. */
struct Hnote
{
	Ref	ref;
	int	flag;		/* NUser, NExit or NDebug */
	char	msg[ERRMAX];
};

struct Hwait
{
	Hwait	*next;
	ulong	pid;
	ulong	time[3];	/* user, sys, real, in ms */
	char	msg[ERRMAX];
};

struct Hproc
{
	Ref	ref;
	Proc	*p;
	Hproc	*hash;		/* table chain */

	ulong	pid;		/* machine-local */
	char	text[TEXTLEN];
	ulong	start;		/* ticks() at creation, for the real time */
	ulong	ppid;		/* the parent's pid when created, for /proc/n/ppid */
	Lock	alk;		/* guards args, nargs and setargs */
	char	args[ARGSLEN];	/* exec's argv, NUL-separated, as 9front's p->args */
	int	nargs;
	int	setargs;	/* args was written through /proc */
	int	hang;		/* ctl hang: exec stops the process before it runs */
	int	killed;		/* ctl kill: die with "Killed" at the next delivery; under nlk */
	char	exitstr[ERRMAX];
	void	*egrp;		/* devenv.c's HEgrp */
	void	*aux;		/* the Zig process */
	Hmach	*mach;
	int	released;	/* h9_kern_release has run; only its own thread looks */
	QLock	debug;		/* held to swap or drop p's fgrp, pgrp and dot, and to read them from devproc */

	Lock	nlk;		/* guards the note fields below */
	ulong	noteid;
	int	notify;		/* has a note handler */
	int	notified;	/* in the handler */
	int	nnote;
	Hnote	*note[NNOTE];
	Hnote	*lastnote;	/* the note being handled, or that killed it */

	/* Debugging (design/0010-self-host.md); under nlk. */
	int	procctl;	/* Pstopme or Ptraceme: stop at the next stop point */
	int	stopped;	/* parked at a stop point until ctl start */
	int	pdbg;		/* a debugger waits in stopr for it to stop */
	int	stopwait;	/* this process waits for another to stop, for status */
	Rendez	startr;		/* the stopped process sleeps here */
	Rendez	stopr;		/* its debugger sleeps here */
	Chan	*textc;		/* the executed image, open, for /proc/n/text; or nil */

	Hproc	*parent;	/* nil with RFNOWAIT or for a machine's first process */
	Lock	exl;		/* guards the fields below */
	int	dead;		/* exited; children leave no wait records */
	int	nchild;
	int	nwait;
	Hwait	*waitq;
	QLock	qwaitr;		/* one waiter at a time */
	Rendez	waitr;
};


/* proc.c, for devproc.c. Lookups take a reference; release it with h9_putproc. */
Hproc*	h9_uphproc(void);
Hproc*	h9_pidlookup(Hmach*, ulong);
void	h9_putproc(Hproc*);
Hnote*	h9_mknote(char*, int);
void	h9_freenote(Hnote*);
int	h9_pushnote(Hproc*, Hnote*);
void	h9_postnotepg(Hmach*, ulong, char*, int);
int	h9_setnoteid(Hproc*, ulong);
void	h9_killproc(Hproc*);
void	h9_fgrpclose(Fgrp*);
int	h9_pids(Hmach*, ulong*, int);

/* devsrv.c */
void	h9_srvmachclose(Hmach*);
void	h9_srvmachfree(Hmach*);

/* src/hstream.zig: closes the machine's host streams */
void	h9_hstream_machend(void*);
void	h9_hostcmd_machend(void*);
Hmach*	h9_fgrpmach(Fgrp*);
void	h9_kern_putmach(void*);

/*
 * Set by the Zig side: the state (a syscall's name, "Running"...) and the
 * mapped memory in KiB of Zig process aux. Called with the record's nlk
 * held, and only while its aux is set.
 */
extern void	(*h9_procstatus)(void*, char*, int, ulong*);

/*
 * Set by the Zig side: /proc/n/segment's text for Zig process aux, in
 * 9front's format; returns its length. Called as h9_procstatus is.
 */
extern int	(*h9_procsegment)(void*, char*, int);

/*
 * Set by the Zig side: makes Zig process aux check for a stop request at
 * its next stop point, kicking it out of guest code. Called as
 * h9_notekick is.
 */
extern void	(*h9_stopkick)(void*);

/* h9_procdebug's files and errors. */
enum
{
	Dmem,
	Dregs,
	Dfpregs,

	Dbadaddr	= -1,	/* nothing mapped there */
	Dnoreg		= -2,	/* no saved registers: not stopped or in a syscall */
	Dnomem		= -3,	/* out of memory copying text for a write */
};

/*
 * Set by the Zig side: reads or writes n bytes of Zig process aux's
 * memory (Dmem, at address off), registers (Dregs, its Ureg) or FP
 * registers (Dfpregs, its FPsave) at off. Returns the bytes moved, or a
 * negative D error. Writes come only while it's stopped. Called as
 * h9_procstatus is.
 */
extern long	(*h9_procdebug)(void*, int, int, uvlong, void*, long);
