/*
 * h9's machines, notes and wait records (proc.c), shared with devproc.c
 * and the other devices that look at processes. The process record is
 * Proc (h9proc.h). See proc.c.
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

/* ns.c */
extern void	pgrpcpy(Pgrp*, Pgrp*, int);

/*
 * A machine: the C half of a Kernel (src/kern.zig), which makes it with
 * h9_kern_newmach, and the processes spawned into it and their
 * descendants.
 */
struct Hmach
{
	Ref	ref;		/* the Kernel's, and one per process */
	void	*kernel;	/* the Kernel, until h9_kern_machdetach; under lk */
	Lock	lk;
	ulong	nextnoteid;
	int	nlive;		/* processes not yet released (h9_kern_release); under lk */
	void	*srv;		/* devsrv.c's registry, made on first attach; under lk */
	Proc	*procs;		/* its processes, on mnext, until they exit; under lk */
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

/*
 * h9_kern_fork's flag for a Linux thread (with RFNOWAIT): the child's
 * waiter is the caller's group leader. Not a 9front flag.
 */
enum { RFLXTHREAD = 1<<30 };


/* proc.c, for devproc.c. Lookups take a reference; release it with h9_putproc. */
Proc*	h9_uphproc(void);
void	wakewaits(Proc*);
Proc*	h9_pidlookup(Hmach*, ulong);
void	h9_putproc(Proc*);
Hnote*	h9_mknote(char*, int);
void	h9_freenote(Hnote*);
int	h9_pushnote(Proc*, Hnote*);
void	h9_postnotepg(Hmach*, ulong, char*, int);
int	h9_setnoteid(Proc*, ulong);
void	h9_killproc(Proc*);
void	h9_fgrpclose(Fgrp*);
int	h9_pids(Hmach*, ulong*, int);

/* devsrv.c */
void	h9_srvmachclose(Hmach*);
void	h9_srvmachfree(Hmach*);

/* src/hstream.zig: closes the machine's host streams */
void	h9_hstream_machend(void*);
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
