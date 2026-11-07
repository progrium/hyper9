/*
 * h9's per-process records: what 9front keeps in its Proc and drawterm's
 * lacks (parent, children, wait queue, Egrp, the machine-local pid and a
 * pointer to the Zig process). drawterm's Proc stays as it is, so a record is
 * found from its Proc through a table here. See DESIGN.md, "Process model".
 *
 * Also here, ported from 9front at the pinned release: the group handling
 * of sysrfork (port/sysproc.c), pgrpcpy (port/pgrp.c), pexit's and
 * pwait's wait records, and the note queue (mknote, pushnote, postnote,
 * postnotepg and popnote, port/proc.c).
 *
 * Notes are queued on the record, not in drawterm's Proc: drawterm's
 * postnote only sets notepending, which its sysfile.c clears after every
 * successful call, so notepending stays the "interrupt this call" flag.
 * devpipe.c is built with -Dpostnote=h9_postnote, so its notes come here.
 * Each record belongs to a machine (Hmach): note groups and postnotepg
 * never reach another machine's processes.
 *
 * devproc.c (#p) reads and changes records through the h9_* functions
 * declared in hproc.h; a lookup by pid only finds processes in the
 * caller's machine.
 *
 * Records are reference counted: the table holds one for the process's
 * life, and each child holds one on its parent's record, so a child that
 * outlives its parent never touches freed memory. A parent that exits
 * marks its record dead, and children's exits then leave no wait record.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"

static Lock tablk;
static Hproc *table[PROCHASH];

static uint
prochash(Proc *p)
{
	return ((uintptr)p >> 4) % PROCHASH;
}

static Hproc*
lookup(Proc *p)
{
	Hproc *h;

	lock(&tablk);
	for(h = table[prochash(p)]; h != nil; h = h->hash)
		if(h->p == p)
			break;
	unlock(&tablk);
	return h;
}

static void
enter(Hproc *h)
{
	uint i;

	i = prochash(h->p);
	lock(&tablk);
	h->hash = table[i];
	table[i] = h;
	unlock(&tablk);
}

static void
leave(Hproc *h)
{
	Hproc **l;

	lock(&tablk);
	for(l = &table[prochash(h->p)]; *l != nil; l = &(*l)->hash)
		if(*l == h){
			*l = h->hash;
			break;
		}
	unlock(&tablk);
}

static void
freenote(Hnote *n)
{
	if(n == nil || decref(&n->ref))
		return;
	free(n);
}

/* Called with h->nlk held. */
static void
freenotes(Hproc *h)
{
	while(h->nnote > 0){
		freenote(h->note[--h->nnote]);
		h->note[h->nnote] = nil;
	}
}

static void
putmach(Hmach *m)
{
	if(m != nil && decref(&m->ref) == 0){
		h9_srvmachfree(m);
		free(m);
	}
}

static void
putproc(Hproc *h)
{
	Hwait *w;

	if(h == nil || decref(&h->ref))
		return;
	while((w = h->waitq) != nil){
		h->waitq = w->next;
		free(w);
	}
	freenotes(h);
	freenote(h->lastnote);
	putmach(h->mach);
	free(h);
}

static Hproc*
newhproc(Proc *p, char *text)
{
	Hproc *h;

	h = mallocz(sizeof *h, 1);
	if(h == nil)
		return nil;
	h->ref.ref = 1;
	h->p = p;
	h->start = ticks();
	strecpy(h->text, h->text+sizeof h->text, text);
	return h;
}

static Hproc*
uphproc(void)
{
	Hproc *h;

	h = lookup(up);
	if(h == nil)
		error("not an h9 process");
	return h;
}

static ulong
newnoteid(Hmach *m)
{
	ulong id;

	lock(&m->lk);
	id = ++m->nextnoteid;
	unlock(&m->lk);
	return id;
}

/*
 * Set by the Zig side: makes a process running guest code take an exit,
 * so a note posted to it is delivered. Called with the process's nlk held,
 * and only while its aux is set.
 */
void	(*h9_notekick)(void*);

static Hnote*
mknote(char *msg, int flag)
{
	Hnote *n;

	n = mallocz(sizeof *n, 1);
	if(n == nil)
		return nil;
	kstrcpy(n->msg, msg, ERRMAX);
	n->flag = flag;
	n->ref.ref = 1;
	return n;
}

/*
 * 9front's pushnote: queues n (taking the caller's reference) and
 * interrupts the process. A note posted by the system to a process that
 * can't handle it will kill it, so the notes before it are dropped.
 */
static int
pushnote(Hproc *h, Hnote *n)
{
	lock(&h->nlk);
	if(h->p == nil){
		unlock(&h->nlk);
		freenote(n);
		return 0;
	}
	if(n->flag != NUser && (!h->notify || h->notified))
		freenotes(h);
	if(h->nnote >= NNOTE){
		unlock(&h->nlk);
		freenote(n);
		return 0;
	}
	h->note[h->nnote++] = n;
	/*
	 * The kick first: the exit loop interrupts a call it starts with the
	 * kick's flag set, and a call started before the flag is set sees
	 * this interrupt.
	 */
	if(h->aux != nil && h9_notekick != nil)
		h9_notekick(h->aux);
	procinterrupt(h->p);
	unlock(&h->nlk);
	return 1;
}

/*
 * drawterm's postnote, which kern files built with -Dpostnote=h9_postnote
 * (devpipe.c) call. A Proc that isn't an h9 process (a kproc) is only
 * interrupted, as drawterm's postnote does.
 */
int
h9_postnote(Proc *p, int dolock, char *msg, int flag)
{
	Hproc *h;
	Hnote *n;
	int r;

	USED(dolock);
	if(p == nil)
		return 0;
	lock(&tablk);
	for(h = table[prochash(p)]; h != nil; h = h->hash)
		if(h->p == p)
			break;
	if(h != nil)
		incref(&h->ref);
	unlock(&tablk);
	if(h == nil){
		procinterrupt(p);
		return 0;
	}
	r = 0;
	if((n = mknote(msg, flag)) != nil)
		r = pushnote(h, n);
	putproc(h);
	return r;
}

/* 9front's postnotepg, within machine m. */
static void
postnotepg(Hmach *m, ulong noteid, char *msg, int flag)
{
	Hnote *n;
	Hproc *h;
	int i;

	if((n = mknote(msg, flag)) == nil)
		return;
	lock(&tablk);
	for(i = 0; i < PROCHASH; i++)
		for(h = table[i]; h != nil; h = h->hash){
			if(h->mach != m || h->p == up || h->noteid != noteid)
				continue;
			incref(&n->ref);
			pushnote(h, n);
		}
	unlock(&tablk);
	freenote(n);
}

/*
 * Posts a note to the process with machine-local pid in the caller's
 * machine. Returns 1 if it was queued, 0 if the queue was full, or -1
 * with the error string set if there's no such process.
 */
int
h9_kern_postnote(ulong pid, char *msg, int flag)
{
	Hproc *self, *h;
	Hnote *n;
	int i, r;

	self = lookup(up);
	h = nil;
	lock(&tablk);
	for(i = 0; h == nil && i < PROCHASH; i++)
		for(h = table[i]; h != nil; h = h->hash)
			if(self != nil && h->mach == self->mach && h->pid == pid)
				break;
	if(h != nil)
		incref(&h->ref);
	unlock(&tablk);
	if(h == nil){
		kstrcpy(up->syserrstr, "process exited", ERRMAX);
		return -1;
	}
	r = 0;
	if((n = mknote(msg, flag)) != nil)
		r = pushnote(h, n);
	putproc(h);
	return r;
}

/*
 * The calling process's machine, with a reference for the caller, which
 * h9_kern_putmach releases. nil if the caller isn't an h9 process.
 */
void*
h9_kern_mach(void)
{
	Hproc *h;

	h = lookup(up);
	if(h == nil)
		return nil;
	incref(&h->mach->ref);
	return h->mach;
}

void
h9_kern_putmach(void *m)
{
	putmach(m);
}

/*
 * The machine of the h9 process using Fgrp f, with a reference, or nil.
 * For a kproc, which shares the Fgrp of the process that made it
 * (hostcmd.c).
 */
Hmach*
h9_fgrpmach(Fgrp *f)
{
	Hproc *h;
	Hmach *m;
	int i;

	if(f == nil)
		return nil;
	m = nil;
	lock(&tablk);
	for(i = 0; m == nil && i < PROCHASH; i++)
		for(h = table[i]; h != nil; h = h->hash)
			if(h->p != nil && h->p->fgrp == f){
				m = h->mach;
				incref(&m->ref);
				break;
			}
	unlock(&tablk);
	return m;
}

/*
 * Posts a note from the host side (Ctrl-C, hangup, a timeout) to machine
 * m: with all set, to every process; otherwise to the note group of its
 * first process (pid 1), which is the foreground group. Callable from any
 * thread, including ones that aren't kernel processes: it takes only
 * locks, never up or an error label, as h9_cons_wake doesn't. Returns
 * how many processes it reached.
 */
int
h9_kern_postmach(void *v, int all, char *msg, int flag)
{
	Hmach *m;
	Hnote *n;
	Hproc *h;
	ulong noteid;
	int i, found, count;

	m = v;
	if((n = mknote(msg, flag)) == nil)
		return 0;
	count = 0;
	lock(&tablk);
	noteid = 0;
	found = all;
	for(i = 0; !found && i < PROCHASH; i++)
		for(h = table[i]; h != nil; h = h->hash)
			if(h->mach == m && h->pid == 1){
				noteid = h->noteid;
				found = 1;
				break;
			}
	if(found)
		for(i = 0; i < PROCHASH; i++)
			for(h = table[i]; h != nil; h = h->hash){
				if(h->mach != m || (!all && h->noteid != noteid))
					continue;
				incref(&n->ref);
				count += pushnote(h, n);
			}
	unlock(&tablk);
	freenote(n);
	return count;
}

/* For devproc.c (hproc.h). */

void	(*h9_procstatus)(void*, char*, int, ulong*);
int	(*h9_procsegment)(void*, char*, int);
void	(*h9_stopkick)(void*);
long	(*h9_procdebug)(void*, int, int, uvlong, void*, long);

Hproc*
h9_uphproc(void)
{
	return uphproc();
}

/* The process with machine-local pid in machine m, with a reference, or nil. */
Hproc*
h9_pidlookup(Hmach *m, ulong pid)
{
	Hproc *h;
	int i;

	h = nil;
	lock(&tablk);
	for(i = 0; h == nil && i < PROCHASH; i++)
		for(h = table[i]; h != nil; h = h->hash)
			if(h->mach == m && h->pid == pid)
				break;
	if(h != nil)
		incref(&h->ref);
	unlock(&tablk);
	return h;
}

void
h9_putproc(Hproc *h)
{
	putproc(h);
}

/*
 * The pids in machine m, in ascending order: fills up to n of them into
 * pids and returns how many it filled.
 */
int
h9_pids(Hmach *m, ulong *pids, int n)
{
	Hproc *h;
	int i, count;

	count = 0;
	lock(&tablk);
	for(i = 0; i < PROCHASH; i++)
		for(h = table[i]; h != nil; h = h->hash)
			if(h->mach == m && h->pid != 0){
				if(count < n)
					pids[count] = h->pid;
				count++;
			}
	unlock(&tablk);
	if(count > n)
		count = n;
	for(i = 1; i < count; i++){
		ulong v;
		int j;

		v = pids[i];
		for(j = i; j > 0 && pids[j-1] > v; j--)
			pids[j] = pids[j-1];
		pids[j] = v;
	}
	return count;
}

Hnote*
h9_mknote(char *msg, int flag)
{
	return mknote(msg, flag);
}

void
h9_freenote(Hnote *n)
{
	freenote(n);
}

int
h9_pushnote(Hproc *h, Hnote *n)
{
	return pushnote(h, n);
}

void
h9_postnotepg(Hmach *m, ulong noteid, char *msg, int flag)
{
	postnotepg(m, noteid, msg, flag);
}

/*
 * Moves h into note group noteid, which some process in its machine must
 * be in already (9front's changenoteid, where users can't differ).
 * Returns 0, or -1 if there's no such group.
 */
int
h9_setnoteid(Hproc *h, ulong noteid)
{
	Hproc *q;
	int i, found;

	found = 0;
	lock(&tablk);
	for(i = 0; !found && i < PROCHASH; i++)
		for(q = table[i]; q != nil; q = q->hash)
			if(q->mach == h->mach && q->noteid == noteid){
				found = 1;
				break;
			}
	if(found)
		h->noteid = noteid;
	unlock(&tablk);
	return found ? 0 : -1;
}

/*
 * 9front's killproc for ctl kill: the process dies with "Killed" at its
 * next note delivery, whether or not it has a handler.
 */
void
h9_killproc(Hproc *h)
{
	lock(&h->nlk);
	if(h->p != nil){
		h->killed = 1;
		/* The kick first, as in pushnote. */
		if(h->aux != nil && h9_notekick != nil)
			h9_notekick(h->aux);
		procinterrupt(h->p);
	}
	unlock(&h->nlk);
}

/*
 * Records exec's argv for /proc/n/args: n bytes of NUL-terminated strings,
 * which the caller has cut to ARGSLEN at a character boundary.
 */
void
h9_kern_setargs(char *args, int n)
{
	Hproc *h;

	h = lookup(up);
	if(h == nil || n < 0 || n > ARGSLEN)
		return;
	lock(&h->alk);
	memmove(h->args, args, n);
	h->nargs = n;
	h->setargs = 0;
	unlock(&h->alk);
}

/* Posts a note to every process but the caller in its machine's note group noteid. */
void
h9_kern_postnotepg(ulong noteid, char *msg, int flag)
{
	Hproc *h;

	h = lookup(up);
	if(h != nil)
		postnotepg(h->mach, noteid, msg, flag);
}

/* The calling process's note group. */
ulong
h9_kern_noteid(void)
{
	Hproc *h;

	h = lookup(up);
	return h != nil ? h->noteid : 0;
}

/* Whether the calling process has a note handler (notify with a non-nil function). */
void
h9_kern_setnotify(int on)
{
	Hproc *h;

	h = lookup(up);
	if(h == nil)
		return;
	lock(&h->nlk);
	h->notify = on != 0;
	unlock(&h->nlk);
}

/* Whether the calling process has a note queued. */
int
h9_kern_notepending(void)
{
	Hproc *h;

	h = lookup(up);
	return h != nil && (h->nnote > 0 || h->killed);
}

/*
 * 9front's popnote, for delivery at a syscall exit or kick. Takes the
 * next note into msg (ERRMAX bytes), with " pc=" and pc appended to a
 * "sys:" note posted to this process alone, and says what to do:
 * Nhandle (the process is now in its handler until h9_kern_noted),
 * Nkill or Nkilldebug (it has no handler, or is in it already), or Nnone
 * (no note, or only user notes while in the handler, which wait).
 */
int
h9_kern_popnote(char *msg, uvlong pc)
{
	Hproc *h;
	Hnote *n;
	int l, r;

	h = lookup(up);
	if(h == nil)
		return Nnone;
	up->notepending = 0;
	lock(&h->nlk);
	if(h->killed){
		unlock(&h->nlk);
		kstrcpy(msg, "Killed", ERRMAX);
		return Nkill;
	}
	if(h->nnote == 0 || (h->notified && h->note[0]->flag == NUser)){
		unlock(&h->nlk);
		return Nnone;
	}
	freenote(h->lastnote);
	n = h->lastnote = h->note[0];
	if(--h->nnote > 0)
		memmove(&h->note[0], &h->note[1], h->nnote*sizeof(Hnote*));
	h->note[h->nnote] = nil;
	if(n->ref.ref == 1 && strncmp(n->msg, "sys:", 4) == 0){
		l = strlen(n->msg);
		snprint(n->msg+l, ERRMAX-l, " pc=%#llux", pc);
	}
	if(!h->notify || h->notified)
		r = n->flag == NDebug ? Nkilldebug : Nkill;
	else {
		h->notified = 1;
		r = Nhandle;
	}
	kstrcpy(msg, n->msg, ERRMAX);
	unlock(&h->nlk);
	return r;
}

/*
 * The bookkeeping of 9front's sysnoted. arg is noted's argument (NCONT 0,
 * NDFLT 1, NSAVE 2, NRSTR 3). Returns -1 for noted outside a handler with
 * anything but NRSTR (an error, Ebadarg); otherwise, for NDFLT or an
 * unknown arg, Nkill or Nkilldebug with the last note in msg, and Nnone
 * when the process carries on, out of the handler (NCONT, NSAVE, NRSTR).
 */
int
h9_kern_noted(int arg, char *msg)
{
	Hproc *h;
	int r;

	h = lookup(up);
	if(h == nil)
		return -1;
	lock(&h->nlk);
	if(!h->notified && arg != 3){
		unlock(&h->nlk);
		kstrcpy(up->syserrstr, Ebadarg, ERRMAX);
		return -1;
	}
	r = Nnone;
	switch(arg){
	case 0:
	case 2:
	case 3:
		h->notified = 0;
		break;
	default:
		if(h->lastnote != nil)
			h->lastnote->flag = NDebug;
		/* fall through */
	case 1:
		if(h->lastnote == nil){
			kstrcpy(msg, "Suicide", ERRMAX);
			r = Nkill;
		} else {
			kstrcpy(msg, h->lastnote->msg, ERRMAX);
			r = h->lastnote->flag == NDebug ? Nkilldebug : Nkill;
		}
		break;
	}
	unlock(&h->nlk);
	return r;
}

/* exec's reset of the note state: no handler, nothing queued. */
void
h9_kern_execnotes(void)
{
	Hproc *h;

	h = lookup(up);
	if(h == nil)
		return;
	lock(&h->nlk);
	freenotes(h);
	freenote(h->lastnote);
	h->lastnote = nil;
	h->notify = 0;
	h->notified = 0;
	unlock(&h->nlk);
}

/*
 * Debugging (design/0010-self-host.md): the process side of 9front's
 * procctl. A debugger's ctl stop, startstop or an exec with hang set
 * makes a stop request; the Zig exit loop checks for one at each stop
 * point (entering a syscall, before running guest code again after a
 * syscall, a kick, a fault or a breakpoint, and before delivering a
 * note). Stopped, the process sleeps on its own kernel thread until ctl
 * start, holding no vCPU.
 */

/*
 * Whether the calling process should stop here, as 9front's procctl
 * decides: for Pstopme always, for Ptraceme only with a note queued.
 * Takes the request.
 */
int
h9_kern_wantstop(void)
{
	Hproc *h;
	int r;

	h = lookup(up);
	if(h == nil)
		return 0;
	r = 0;
	lock(&h->nlk);
	switch(h->procctl){
	case Ptraceme:
		if(h->nnote == 0 && !h->killed)
			break;
		/* fall through */
	case Pstopme:
		h->procctl = 0;
		r = 1;
		break;
	}
	unlock(&h->nlk);
	return r;
}

static int
notstopped(void *a)
{
	return !((Hproc*)a)->stopped;
}

/*
 * Stops the calling process, waking a debugger waiting for that, and
 * sleeps until ctl start. Returns 0 when started; -1 when interrupted (a
 * note, a kill or the machine's teardown), still stopped, so the caller
 * can decide whether to sleep again or h9_kern_unstop. The caller saves
 * its registers for /proc/n/regs before calling.
 */
int
h9_kern_stopwait(void)
{
	Hproc *h;

	h = lookup(up);
	if(h == nil)
		return 0;
	lock(&h->nlk);
	h->stopped = 1;
	unlock(&h->nlk);
	wakeup(&h->stopr);
	if(waserror())
		return -1;
	sleep(&h->startr, notstopped, h);
	poperror();
	return 0;
}

/* Ends a stop without ctl start, for a process that's going to die. */
void
h9_kern_unstop(void)
{
	Hproc *h;

	h = lookup(up);
	if(h == nil)
		return;
	lock(&h->nlk);
	h->stopped = 0;
	unlock(&h->nlk);
}

/* Whether ctl kill has been written for the calling process. */
int
h9_kern_killed(void)
{
	Hproc *h;

	h = lookup(up);
	return h != nil && h->killed;
}

/*
 * exec's part, as 9front's sysexec: with ctl hang set, the process stops
 * before its first instruction. Returns whether it will.
 */
int
h9_kern_exechang(void)
{
	Hproc *h;
	int r;

	h = lookup(up);
	if(h == nil)
		return 0;
	lock(&h->nlk);
	r = h->hang;
	if(r)
		h->procctl = Pstopme;
	unlock(&h->nlk);
	return r;
}

/*
 * Keeps the image the calling process just executed, opened from path,
 * for /proc/n/text (9front serves the image's channel). Best effort: on
 * an error the process has no text.
 */
void
h9_kern_settextpath(char *path)
{
	Hproc *h;
	Chan *c, *old;

	h = lookup(up);
	if(h == nil)
		return;
	c = nil;
	if(path != nil){
		if(!waserror()){
			c = namec(path, Aopen, OREAD, 0);
			poperror();
		}
	}
	lock(&h->nlk);
	old = h->textc;
	h->textc = c;
	unlock(&h->nlk);
	if(old != nil)
		cclose(old);
}

/* The calling process's Egrp, for devenv; raises an error if it has none. */
void*
h9_upegrp(void)
{
	Hproc *h;

	h = lookup(up);
	if(h == nil || h->egrp == nil)
		error("no environment");
	return h->egrp;
}

/*
 * 9front's pgrpcpy: copies the mount table of from into to when flag has
 * RFNAMEG, and always the device mask.
 */
static void
pgrpcpy(Pgrp *to, Pgrp *from, int flag)
{
	Mount *n, *m, **link;
	Mhead *f, **l, *mh;
	int i;

	wlock(&to->ns);
	wlock(&from->ns);	/* must wlock to protect from->mntorder->norder */
	if(waserror()){
		wunlock(&from->ns);
		wunlock(&to->ns);
		nexterror();
	}

	memmove(to->devmask, from->devmask, sizeof from->devmask);

	if((flag & RFNAMEG) == 0)
		goto Done;

	for(i = 0; i < MNTHASH; i++){
		l = &to->mnthash[i];
		for(f = from->mnthash[i]; f != nil; f = f->hash){
			rlock(&f->lock);
			if(waserror()){
				runlock(&f->lock);
				nexterror();
			}
			mh = newmhead(f->from);
			*l = mh;
			l = &mh->hash;
			link = &mh->mount;
			for(m = f->mount; m != nil; m = m->next){
				n = newmount(m->to, m->mflag, m->spec);
				n->umh = mh;
				*link = n;
				link = &n->next;
				m->norder = n;	/* for the mntorder loop below */
			}
			runlock(&f->lock);
			poperror();
		}
	}
	/* add mounts in original mntorder */
	for(m = from->mntorder; m != nil; m = m->order){
		n = m->norder;
		m->norder = nil;
		pgrpinsert(to, n);
	}
Done:
	wunlock(&from->ns);
	wunlock(&to->ns);
	poperror();
}

/*
 * drawterm's closefgrp frees the fd table without closing its channels
 * (its kprocs never exit holding fds), so a pipe's write end would outlive
 * the last process holding it and its reader would never see EOF. This is
 * 9front's closefgrp. All Fgrp releases in this file go through it.
 */
static void
fgrpclose(Fgrp *f)
{
	int i;
	Chan *c;

	if(f == nil || decref(&f->ref))
		return;
	for(i = 0; i <= f->maxfd; i++)
		if((c = f->fd[i]) != nil){
			f->fd[i] = nil;
			cclose(c);
		}
	free(f->flag);
	free(f->fd);
	free(f);
}
#define closefgrp fgrpclose

void
h9_fgrpclose(Fgrp *f)
{
	fgrpclose(f);
}

/* Code using RFNOMNT expects to block all but these devices. */
static char nomntdevs[] = "|decp";

static void
checkflags(int flag)
{
	if((flag & (RFFDG|RFCFDG)) == (RFFDG|RFCFDG))
		error(Ebadarg);
	if((flag & (RFNAMEG|RFCNAMEG)) == (RFNAMEG|RFCNAMEG))
		error(Ebadarg);
	if((flag & (RFENVG|RFCENVG)) == (RFENVG|RFCENVG))
		error(Ebadarg);
}

/* Swaps the error strings after a caught error, as sysfile.c's wrappers do. */
static int
syserr(void)
{
	char *p;

	p = up->syserrstr;
	up->syserrstr = up->errstr;
	up->errstr = p;
	return -1;
}

typedef struct Spawn Spawn;
struct Spawn {
	void	(*fn)(void*);
	void	*arg;
};

static Proc *bootproc;

extern void h9_tsleepinit(void);	/* tsleep.c */
extern void h9_semainit(void);		/* sema.c */

/*
 * Called once the kernel is up, from the boot Proc (glue.c). Starts the
 * timer kproc that tsleep needs, and sets up the semaphore wait lists.
 */
void
h9_proc_boot(void)
{
	bootproc = up;
	h9_semainit();
	h9_tsleepinit();
}

void h9_kern_exit(void);

static void
spawntramp(void *v)
{
	Spawn s;
	Hproc *h;

	s = *(Spawn*)v;
	free(v);
	/* Now that up is set, kernel calls (and their errors) are allowed. */
	if(waserror())
		panic("h9_kern_spawn: %s", up->errstr);
	h = uphproc();
	up->slash = cclone(bootproc->slash);
	up->dot = cclone(bootproc->slash);
	up->pgrp = newpgrp();
	up->fgrp = dupfgrp(nil);
	up->rgrp = newrgrp();
	h->egrp = h9_egrpnew();
	poperror();
	s.fn(s.arg);
	h9_kern_exit();
}

/*
 * Runs fn(arg) on a new kernel process with its own thread, a fresh
 * namespace (just #/, as the boot Proc has), no fds, an empty environment
 * and its own rendezvous group; it has no parent. Unlike drawterm's kproc
 * it can be called from a thread that isn't a Proc: it only allocates
 * here, and the new thread sets up its groups once up is set. Returns 0,
 * or -1 if allocation fails.
 */
int
h9_kern_spawn(char *name, void (*fn)(void*), void *arg)
{
	Proc *p;
	Spawn *s;
	Hproc *h;

	s = malloc(sizeof *s);
	if(s == nil)
		return -1;
	s->fn = fn;
	s->arg = arg;
	p = newproc();
	h = newhproc(p, name);
	if(h != nil)
		h->mach = mallocz(sizeof *h->mach, 1);
	if(h == nil || h->mach == nil){
		free(h);
		free(s);
		free(p);
		return -1;
	}
	h->mach->ref.ref = 1;
	h->mach->nlive = 1;
	h->noteid = newnoteid(h->mach);
	p->fn = spawntramp;
	p->arg = s;
	strecpy(p->text, p->text+sizeof p->text, name);
	enter(h);
	osproc(p);
	return 0;
}

/*
 * Makes the calling thread, which isn't a Proc, a kernel process for good:
 * h9_kern_spawn's cloning from the boot Proc, without a new thread. It
 * has no machine, so notes never reach it. For macOS --gfx, where AppKit
 * runs on the process's main thread and drawterm's Cocoa delegate sleeps
 * and starts kprocs there (design/0015-gfx.md). Returns 0, or -1 if
 * allocation fails.
 */
int
h9_kern_adopt(char *name)
{
	Proc *p;

	p = newproc();
	if(p == nil)
		return -1;
	strecpy(p->text, p->text+sizeof p->text, name);
	_setproc(p);
	if(waserror())
		panic("h9_kern_adopt: %s", up->errstr);
	up->slash = cclone(bootproc->slash);
	up->dot = cclone(bootproc->slash);
	up->pgrp = newpgrp();
	up->fgrp = dupfgrp(nil);
	up->rgrp = newrgrp();
	poperror();
	return 0;
}

/*
 * Runs fn(arg) in the calling Proc with a fresh namespace, no fds and its
 * own rendezvous group, as a spawned process starts, and puts the Proc's
 * own back after. The kprocs fn starts share these, not the caller's: a
 * GUI backend's event and resize kprocs outlive the guest process whose
 * attach of #i started them (src/kern/gfx.c).
 */
void
h9_kern_isolated(void (*fn)(void*), void *arg)
{
	Pgrp *pg;
	Fgrp *fg;
	Rgrp *rg;
	Chan *slash, *dot;

	pg = up->pgrp;
	fg = up->fgrp;
	rg = up->rgrp;
	slash = up->slash;
	dot = up->dot;
	up->pgrp = newpgrp();
	up->fgrp = dupfgrp(nil);
	up->rgrp = newrgrp();
	up->slash = cclone(bootproc->slash);
	up->dot = cclone(bootproc->slash);
	if(waserror()){
		closepgrp(up->pgrp);
		closefgrp(up->fgrp);
		closergrp(up->rgrp);
		cclose(up->slash);
		cclose(up->dot);
		up->pgrp = pg;
		up->fgrp = fg;
		up->rgrp = rg;
		up->slash = slash;
		up->dot = dot;
		nexterror();
	}
	fn(arg);
	poperror();
	closepgrp(up->pgrp);
	closefgrp(up->fgrp);
	closergrp(up->rgrp);
	cclose(up->slash);
	cclose(up->dot);
	up->pgrp = pg;
	up->fgrp = fg;
	up->rgrp = rg;
	up->slash = slash;
	up->dot = dot;
}

static void
forktramp(void *v)
{
	Spawn s;

	s = *(Spawn*)v;
	free(v);
	s.fn(s.arg);
	h9_kern_exit();
}

/*
 * rfork with RFPROC: runs fn(arg) on a new kernel process that is a child
 * of the caller, with groups shared or copied from the caller's as flag
 * says (9front's sysrfork). pid is the child's machine-local pid. RFMEM
 * is the caller's business. The child inherits the note handler and,
 * without RFNOTEG, the note group, but no queued notes. Returns 0, or -1
 * with the error string set; on error, fn never runs.
 */
int
h9_kern_fork(int flag, ulong pid, void (*fn)(void*), void *arg)
{
	Proc *p;
	Hproc *h, *ph;
	Spawn *s;

	p = nil;
	h = nil;
	s = nil;
	if(waserror()){
		if(p != nil){
			if(p->fgrp != nil)
				closefgrp(p->fgrp);
			if(p->pgrp != nil)
				closepgrp(p->pgrp);
			if(p->rgrp != nil)
				closergrp(p->rgrp);
			if(p->dot != nil)
				cclose(p->dot);
			if(p->slash != nil)
				cclose(p->slash);
			free(p);
		}
		if(h != nil){
			if(h->textc != nil)
				cclose(h->textc);
			if(h->egrp != nil)
				h9_egrpclose(h->egrp);
			putmach(h->mach);
			free(h);
		}
		free(s);
		return syserr();
	}
	if((flag & RFPROC) == 0)
		error(Ebadarg);
	checkflags(flag);
	ph = uphproc();

	s = malloc(sizeof *s);
	if(s == nil)
		error(Enomem);
	s->fn = fn;
	s->arg = arg;
	p = newproc();
	h = newhproc(p, ph->text);
	if(h == nil)
		error(Enomem);
	h->pid = pid;
	h->ppid = ph->pid;
	h->mach = ph->mach;
	incref(&h->mach->ref);
	h->notify = ph->notify;
	h->noteid = (flag & RFNOTEG) ? newnoteid(h->mach) : ph->noteid;
	/* As 9front's sysrfork: the child inherits hang, and runs the same image. */
	h->hang = ph->hang;
	lock(&ph->nlk);
	if((h->textc = ph->textc) != nil)
		incref(&h->textc->ref);
	unlock(&ph->nlk);
	strecpy(p->text, p->text+sizeof p->text, up->text);

	p->slash = up->slash;
	incref(&p->slash->ref);
	p->dot = up->dot;
	incref(&p->dot->ref);

	/* File descriptors */
	if(flag & (RFFDG|RFCFDG)){
		if(flag & RFFDG)
			p->fgrp = dupfgrp(up->fgrp);
		else
			p->fgrp = dupfgrp(nil);
	} else {
		p->fgrp = up->fgrp;
		incref(&up->fgrp->ref);
	}

	/* Process groups */
	if(flag & (RFNAMEG|RFCNAMEG)){
		p->pgrp = newpgrp();
		pgrpcpy(p->pgrp, up->pgrp, flag);
	} else {
		p->pgrp = up->pgrp;
		incref(&up->pgrp->ref);
	}

	/* Rendezvous group */
	if(flag & RFREND)
		p->rgrp = newrgrp();
	else {
		p->rgrp = up->rgrp;
		incref(&up->rgrp->ref);
	}

	/* Environment group */
	if(flag & (RFENVG|RFCENVG)){
		if(flag & RFENVG)
			h->egrp = h9_egrpcopy(ph->egrp);
		else
			h->egrp = h9_egrpnew();
	} else {
		h->egrp = ph->egrp;
		h9_egrpincref(ph->egrp);
	}
	poperror();

	if(flag & RFNOMNT)
		devmask(p->pgrp, 1, nomntdevs);

	if((flag & RFNOWAIT) == 0){
		incref(&ph->ref);
		h->parent = ph;
		lock(&ph->exl);
		ph->nchild++;
		unlock(&ph->exl);
	}

	lock(&h->mach->lk);
	h->mach->nlive++;
	unlock(&h->mach->lk);

	p->fn = forktramp;
	p->arg = s;
	enter(h);
	osproc(p);
	return 0;
}

/* Swap the caller's groups under h->debug, for devproc's readers. */
static void
swapfgrp(Hproc *h, Fgrp *f)
{
	qlock(&h->debug);
	up->fgrp = f;
	qunlock(&h->debug);
}

static void
swappgrp(Hproc *h, Pgrp *pg)
{
	qlock(&h->debug);
	up->pgrp = pg;
	qunlock(&h->debug);
}

/* chdir, as drawterm's syschdir, with dot swapped under the record's debug lock. */
int
h9_kern_chdir(char *name)
{
	Hproc *h;
	Chan *c, *old;

	if(waserror())
		return syserr();
	c = namec(name, Atodir, 0, 0);
	poperror();
	h = lookup(up);
	if(h != nil)
		qlock(&h->debug);
	old = up->dot;
	up->dot = c;
	if(h != nil)
		qunlock(&h->debug);
	cclose(old);
	return 0;
}

/*
 * rfork without RFPROC: changes the caller's own groups (9front's
 * sysrfork). Returns 0, or -1 with the error string set.
 */
int
h9_kern_rfork(int flag)
{
	Fgrp *ofg;
	Pgrp *opg;
	Rgrp *org;
	void *oeg;
	Hproc *h;

	if(waserror())
		return syserr();
	checkflags(flag);
	if(flag & (RFPROC|RFMEM|RFNOWAIT))
		error(Ebadarg);
	h = uphproc();
	poperror();

	ofg = up->fgrp;
	opg = up->pgrp;
	org = up->rgrp;
	oeg = h->egrp;

	if(waserror()){
		if(up->fgrp != ofg){
			closefgrp(up->fgrp);
			swapfgrp(h, ofg);
		}
		if(up->pgrp != opg){
			closepgrp(up->pgrp);
			swappgrp(h, opg);
		}
		if(up->rgrp != org){
			closergrp(up->rgrp);
			up->rgrp = org;
		}
		if(h->egrp != oeg){
			h9_egrpclose(h->egrp);
			h->egrp = oeg;
		}
		return syserr();
	}

	/* File descriptors */
	if(flag & (RFFDG|RFCFDG)){
		if(flag & RFFDG)
			swapfgrp(h, dupfgrp(ofg));
		else
			swapfgrp(h, dupfgrp(nil));
	}

	/* Process group */
	if(flag & (RFNAMEG|RFCNAMEG)){
		swappgrp(h, newpgrp());
		pgrpcpy(up->pgrp, opg, flag);
	}

	/* Rendezvous group */
	if(flag & RFREND)
		up->rgrp = newrgrp();

	/* Environment group */
	if(flag & (RFENVG|RFCENVG)){
		if(flag & RFENVG)
			h->egrp = h9_egrpcopy(oeg);
		else
			h->egrp = h9_egrpnew();
	}

	if(ofg != up->fgrp)
		closefgrp(ofg);
	if(opg != up->pgrp)
		closepgrp(opg);
	if(org != up->rgrp)
		closergrp(org);
	if(oeg != h->egrp)
		h9_egrpclose(oeg);

	poperror();

	if(flag & RFNOMNT)
		devmask(up->pgrp, 1, nomntdevs);
	if(flag & RFNOTEG){
		ulong id;

		id = newnoteid(h->mach);
		lock(&tablk);	/* postnotepg reads noteid under tablk */
		h->noteid = id;
		unlock(&tablk);
	}
	return 0;
}

/*
 * Lets go of the calling process's fds, namespace, current directory and
 * image (for /proc/n/text) before it ends, so that what they hold (an
 * overlay's pages, say) is freed while the machine that owns it is still
 * there: the process's
 * thread can outlive the machine's wait for it. dot and slash become #/,
 * since pexit closes them. The machine's last process to get here also
 * closes what's posted in its /srv (devsrv.c), which nothing else holds.
 */
void
h9_kern_release(void)
{
	Chan *c;
	Hproc *h;
	Hmach *m;
	int last;

	if(up->fgrp != nil){
		fgrpclose(up->fgrp);
		up->fgrp = nil;
	}
	if(up->pgrp != nil){
		closepgrp(up->pgrp);
		up->pgrp = nil;
	}
	c = up->dot;
	up->dot = cclone(bootproc->slash);
	cclose(c);
	c = up->slash;
	up->slash = cclone(bootproc->slash);
	cclose(c);

	h = lookup(up);
	/* The image's channel (/proc/n/text) can hold an overlay too. */
	if(h != nil){
		lock(&h->nlk);
		c = h->textc;
		h->textc = nil;
		unlock(&h->nlk);
		if(c != nil)
			cclose(c);
	}
	if(h == nil || h->released)
		return;
	h->released = 1;
	m = h->mach;
	lock(&m->lk);
	last = --m->nlive == 0;
	unlock(&m->lk);
	if(last){
		h9_srvmachclose(m);
		h9_hstream_machend(m);
		h9_hostcmd_machend(m);
	}
}

/*
 * Ends the calling kernel process; it doesn't return. The parent, if any,
 * gets a wait record built from the exit string set with h9_kern_setexits,
 * as 9front's pexit builds it.
 */
void
h9_kern_exit(void)
{
	Hproc *h, *ph;
	Hwait *w;
	Chan *c;

	h = lookup(up);
	if(h == nil){
		pexit("", 1);
		return;
	}
	/* Normally gone already, with h9_kern_release. */
	lock(&h->nlk);
	c = h->textc;
	h->textc = nil;
	unlock(&h->nlk);
	if(c != nil)
		cclose(c);
	leave(h);
	/* Notes posted from now on are dropped; the Proc goes with pexit. */
	qlock(&h->debug);
	lock(&h->nlk);
	h->p = nil;
	h->aux = nil;
	h->killed = 0;
	h->stopped = 0;
	h->procctl = 0;
	freenotes(h);
	unlock(&h->nlk);
	qunlock(&h->debug);
	/* A debugger waiting for it to stop finds it gone (9front's pexit). */
	wakeup(&h->stopr);

	ph = h->parent;
	if(ph != nil){
		w = mallocz(sizeof *w, 1);
		if(w != nil){
			w->pid = h->pid;
			w->time[2] = ticks() - h->start;
			if(h->exitstr[0])
				snprint(w->msg, sizeof w->msg, "%s %lud: %s", h->text, h->pid, h->exitstr);
		}
		lock(&ph->exl);
		if(!ph->dead){
			ph->nchild--;
			if(w != nil && ph->nwait < Maxwait){
				w->next = ph->waitq;
				ph->waitq = w;
				ph->nwait++;
				w = nil;
				wakeup(&ph->waitr);
			}
		}
		unlock(&ph->exl);
		free(w);
		h->parent = nil;
		putproc(ph);
	}

	/* Prevent my children from leaving waits; wake /proc/n/wait readers. */
	lock(&h->exl);
	h->dead = 1;
	wakeup(&h->waitr);
	h->nchild = h->nwait = 0;
	while((w = h->waitq) != nil){
		h->waitq = w->next;
		free(w);
	}
	unlock(&h->exl);

	if(h->egrp != nil){
		h9_egrpclose(h->egrp);
		h->egrp = nil;
	}
	putproc(h);
	/* drawterm's pexit would leak the fds' channels. */
	if(up->fgrp != nil){
		fgrpclose(up->fgrp);
		up->fgrp = nil;
	}
	pexit("", 1);
}

static int
haswaitq(void *x)
{
	return ((Hproc*)x)->waitq != nil;
}

/*
 * await: waits for a child to exit and formats its wait record into buf
 * as 9front's sysawait does ("pid utime stime real 'msg'"). Returns the
 * length, or -1 with the error string set: no children ("no living
 * children"), another await in progress, or interrupted.
 */
int
h9_kern_await(char *buf, int n)
{
	Hproc *h;
	Hwait *w;
	int len;

	if(waserror())
		return syserr();
	h = uphproc();
	if(!canqlock(&h->qwaitr))
		error(Einuse);
	if(waserror()){
		qunlock(&h->qwaitr);
		nexterror();
	}
	lock(&h->exl);
	while(h->waitq == nil){
		if(h->nchild == 0){
			unlock(&h->exl);
			error(Enochild);
		}
		unlock(&h->exl);
		sleep(&h->waitr, haswaitq, h);
		lock(&h->exl);
	}
	w = h->waitq;
	h->waitq = w->next;
	h->nwait--;
	unlock(&h->exl);
	qunlock(&h->qwaitr);
	poperror();
	poperror();

	len = snprint(buf, n, "%lud %lud %lud %lud %q", w->pid, w->time[0], w->time[1], w->time[2], w->msg);
	free(w);
	return len;
}

/* The exit string the parent's wait record will carry; empty for success. */
void
h9_kern_setexits(char *msg)
{
	Hproc *h;

	h = lookup(up);
	if(h != nil)
		strecpy(h->exitstr, h->exitstr+sizeof h->exitstr, msg);
}

/* The calling process's machine-local pid, and setting it. */
ulong
h9_kern_gpid(void)
{
	Hproc *h;

	h = lookup(up);
	return h != nil ? h->pid : 0;
}

/* The calling process's parent's pid when it was made, as /proc/n/ppid. */
ulong
h9_kern_gppid(void)
{
	Hproc *h;

	h = lookup(up);
	return h != nil ? h->ppid : 0;
}

void
h9_kern_setgpid(ulong pid)
{
	Hproc *h;

	h = lookup(up);
	if(h != nil)
		h->pid = pid;
}

/* The process's name in wait records; exec sets it to the program's. */
void
h9_kern_settext(char *text)
{
	Hproc *h;

	h = lookup(up);
	if(h != nil)
		strecpy(h->text, h->text+sizeof h->text, text);
	strecpy(up->text, up->text+sizeof up->text, text);
}

/* The Zig process behind the calling kernel process. */
void*
h9_kern_aux(void)
{
	Hproc *h;

	h = lookup(up);
	return h != nil ? h->aux : nil;
}

void
h9_kern_setaux(void *aux)
{
	Hproc *h;

	h = lookup(up);
	if(h == nil)
		return;
	/* h9_notekick reads aux under nlk. */
	lock(&h->nlk);
	h->aux = aux;
	unlock(&h->nlk);
}

extern int sysclose(int);

/* Closes the calling process's close-on-exec fds, as exec does. */
void
h9_kern_closeexec(void)
{
	Fgrp *f;
	int i, cexec;

	f = up->fgrp;
	for(i = 0; ; i++){
		lock(&f->ref.lk);
		if(i > f->maxfd){
			unlock(&f->ref.lk);
			break;
		}
		cexec = f->fd[i] != nil && (f->flag[i] & CCEXEC) != 0;
		unlock(&f->ref.lk);
		if(cexec)
			sysclose(i);
	}
}
