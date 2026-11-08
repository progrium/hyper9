/*
 * Kernel helpers for the Linux personality (design/0018-linux-personality.md):
 * the per-process root swap at exec, walks relative to a directory fd,
 * fd flags, and await without blocking. Each returns -1 with the error
 * string set on failure, as glue.c's wrappers do.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"
#include "tsleep.h"

/* Swaps the error strings after a caught error, as proc.c's syserr does. */
static int
syserr(void)
{
	char *p;

	p = up->syserrstr;
	up->syserrstr = up->errstr;
	up->errstr = p;
	return -1;
}

/* Swaps up->dot, or up->slash with which != 0, holding the record's debug lock as chdir does. */
static Chan*
swapchan(Chan *c, int which)
{
	Hproc *h;
	Chan *old;

	h = h9_uphproc();
	qlock(&h->debug);
	if(which){
		old = up->slash;
		up->slash = c;
	} else {
		old = up->dot;
		up->dot = c;
	}
	qunlock(&h->debug);
	return old;
}

/* Whether path s is p or under it. */
static int
under(char *s, char *p)
{
	int n;

	n = strlen(p);
	return strncmp(s, p, n) == 0 && (s[n] == 0 || s[n] == '/');
}

/*
 * Renames dot's path for the other view (design/0018, "The Linux view"):
 * going to Linux, a path under /tmp or /mnt/term is kept, one in #λ loses
 * the prefix, and any other gets /9 before it; going to 9front, /9 is
 * stripped and any other path gets #λ before it. dot becomes a walk to
 * the new name from the new root, so its path is a proper one, if that
 * reaches the same directory; otherwise it's kept as it was.
 */
static void
renamedot(int tolinux)
{
	Chan *c, *d;
	char *s, *n;

	d = up->dot;
	if(d == nil || d->path == nil)
		return;
	s = d->path->s;
	if(tolinux){
		if(strncmp(s, "#\xce\xbb", 3) == 0)
			n = smprint("%s", s[3] ? s+3 : "/");
		else if(under(s, "/tmp") || under(s, "/mnt/term") || s[0] != '/')
			return;
		else
			n = smprint("/9%s", strcmp(s, "/") == 0 ? "" : s);
	} else {
		if(under(s, "/9"))
			n = smprint("%s", s[2] ? s+2 : "/");
		else if(under(s, "/tmp") || under(s, "/mnt/term") || s[0] != '/')
			return;
		else
			n = smprint("#\xce\xbb%s", strcmp(s, "/") == 0 ? "" : s);
	}
	if(n == nil)
		return;
	if(waserror()){
		free(n);
		return;
	}
	c = namec(n, Atodir, 0, 0);
	poperror();
	free(n);
	if(c->type != d->type || c->dev != d->dev || c->qid.path != d->qid.path){
		cclose(c);
		return;
	}
	cclose(swapchan(c, 0));
}

/*
 * Sets the calling process's root: the Linux view (#λ, renamed /) when
 * linux is set, and the machine's 9front root (#/) otherwise. A Chan's
 * mounts are keyed by its qid, so a fresh attach sees the machine's binds.
 */
int
h9_linux_setslash(int tolinux)
{
	Chan *c;

	if(waserror())
		return syserr();
	c = namec(tolinux ? "#λ" : "#/", Atodir, 0, 0);
	pathclose(c->path);
	c->path = newpath("/");
	poperror();
	cclose(swapchan(c, 1));
	renamedot(tolinux);
	return 0;
}

/* Whether the calling process's root is the Linux view. */
int
h9_linux_inview(void)
{
	return up->slash != nil && devtab[up->slash->type]->dc == L'λ';
}

/*
 * Makes fd's directory the calling process's dot, for a walk relative to
 * it (openat and friends), and returns the old dot for h9_linux_dotrestore.
 * The fd's Chan is open and an open Chan can't be cloned, so dot is a
 * fresh walk to the fd's path, checked to reach the same directory.
 */
void*
h9_linux_dotfd(int fd)
{
	Chan *c, *d;

	if(waserror()){
		syserr();
		return nil;
	}
	c = fdtochan(fd, -1, 0, 1);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	if((c->qid.type & QTDIR) == 0)
		error(Enotdir);
	d = namec(chanpath(c), Atodir, 0, 0);
	if(d->type != c->type || d->dev != c->dev || d->qid.path != c->qid.path){
		cclose(d);
		error("directory moved");
	}
	poperror();
	cclose(c);
	poperror();
	return swapchan(d, 0);
}

void
h9_linux_dotrestore(void *old)
{
	cclose(swapchan(old, 0));
}

/*
 * What fd is: its device's character, qid path and type, and open mode,
 * and whether it's close-on-exec. For isatty, d_type and fcntl.
 */
int
h9_linux_fdinfo(int fd, int *dc, ulong *dev, uvlong *qpath, int *qtype, int *mode, int *cexec)
{
	Chan *c;
	Fgrp *f;

	if(waserror())
		return syserr();
	c = fdtochan(fd, -1, 0, 1);
	*dc = devtab[c->type]->dc;
	*dev = c->dev;
	*qpath = c->qid.path;
	*qtype = c->qid.type;
	*mode = c->mode;
	cclose(c);
	poperror();
	f = up->fgrp;
	lock(&f->ref.lk);
	*cexec = fd <= f->maxfd && (f->flag[fd] & CCEXEC) != 0;
	unlock(&f->ref.lk);
	return 0;
}

/*
 * fd's channel, as an identity for the open file description it is (dup
 * and fork share it), and *refs, the references to it besides this call's.
 * 0 if fd isn't open.
 */
uintptr
h9_linux_fdchan(int fd, long *refs)
{
	Chan *c;
	uintptr id;

	if(waserror())
		return 0;
	c = fdtochan(fd, -1, 0, 1);
	id = (uintptr)c;
	*refs = c->ref.ref - 1;
	cclose(c);
	poperror();
	return id;
}

/* The CPU time the calling process's wait record reports, in ms. */
void
h9_linux_setcputime(ulong user, ulong sys)
{
	Hproc *h;

	h = h9_uphproc();
	h->cputime[0] = user;
	h->cputime[1] = sys;
}

/* Sets or clears fd's close-on-exec flag. */
int
h9_linux_setcexec(int fd, int on)
{
	Fgrp *f;

	f = up->fgrp;
	lock(&f->ref.lk);
	if(fd < 0 || fd > f->maxfd || f->fd[fd] == nil){
		unlock(&f->ref.lk);
		kstrcpy(up->syserrstr, Ebadfd, ERRMAX);
		return -1;
	}
	if(on)
		f->flag[fd] |= CCEXEC;
	else
		f->flag[fd] &= ~CCEXEC;
	unlock(&f->ref.lk);
	return 0;
}

/* The highest fd in use, or -1. */
int
h9_linux_maxfd(void)
{
	Fgrp *f;
	int i, n;

	f = up->fgrp;
	lock(&f->ref.lk);
	n = -1;
	for(i = 0; i <= f->maxfd; i++)
		if(f->fd[i] != nil)
			n = i;
	unlock(&f->ref.lk);
	return n;
}

/*
 * Lists the open fds into fds (up to n) and returns how many there are,
 * for /proc/n/fd.
 */
int
h9_linux_fds(int *fds, int n)
{
	Fgrp *f;
	int i, count;

	f = up->fgrp;
	count = 0;
	lock(&f->ref.lk);
	for(i = 0; i <= f->maxfd; i++)
		if(f->fd[i] != nil){
			if(count < n)
				fds[count] = i;
			count++;
		}
	unlock(&f->ref.lk);
	return count;
}

static int
haswait(void *a)
{
	Hproc *h;

	h = a;
	return h->waitq != nil || h->nchild == 0;
}

/*
 * await without blocking (block == 0): returns 0 when children are alive
 * but none has exited, as wait4's WNOHANG. With block set, it's await.
 * Fails with Enochild when there are no children, and is interrupted by
 * notes.
 */
int
h9_linux_await(char *buf, int n, int block)
{
	Hproc *h;
	Hwait *w;
	int len;

	if(waserror())
		return syserr();
	h = h9_uphproc();
	lock(&h->exl);
	while(h->waitq == nil){
		if(h->nchild == 0){
			unlock(&h->exl);
			error(Enochild);
		}
		unlock(&h->exl);
		if(!block){
			poperror();
			return 0;
		}
		sleep(&h->waitr, haswait, h);
		lock(&h->exl);
	}
	w = h->waitq;
	h->waitq = w->next;
	h->nwait--;
	unlock(&h->exl);
	poperror();
	len = snprint(buf, n, "%lud %lud %lud %lud %q", w->pid, w->time[0], w->time[1], w->time[2], w->msg);
	free(w);
	return len;
}

/* The calling process's parent's pid, or 1 for a machine's first process. */
ulong
h9_linux_ppid(void)
{
	Hproc *h;

	h = h9_uphproc();
	return h->ppid != 0 ? h->ppid : 1;
}

/* The calling process's working directory as a path in its view. */
int
h9_linux_getcwd(char *buf, int n)
{
	if(up->dot == nil || n <= 0){
		kstrcpy(up->syserrstr, Enonexist, ERRMAX);
		return -1;
	}
	return snprint(buf, n, "%s", chanpath(up->dot));
}

/* Makes fd's directory the working directory. */
int
h9_linux_fchdir(int fd)
{
	void *old;

	old = h9_linux_dotfd(fd);
	if(old == nil)
		return -1;
	cclose(old);
	return 0;
}

/*
 * futex (design/0049-linux-threads.md): waiters queued by key (the
 * address space) and guest address, sleeping with drawterm's sleep, so a
 * note interrupts them as it does any wait. The value check and the
 * enqueue are under the same lock a waker takes, so a wake after the
 * guest changes the word can't fall between them.
 */
typedef struct Fwait Fwait;
struct Fwait
{
	void	*key;
	uvlong	addr;
	u32int	bitset;
	int	woken;
	Rendez	r;
	Fwait	*next;
};

enum { Nfhash = 64 };
static Lock flk;
static Fwait *fq[Nfhash];

static int
fhash(void *key, uvlong addr)
{
	return (((uintptr)key >> 4) ^ (addr >> 2)) & (Nfhash-1);
}

static void
fenq(Fwait *w)
{
	int h;

	h = fhash(w->key, w->addr);
	w->next = fq[h];
	fq[h] = w;
}

/* Removes w from its queue, if it's still on one. With flk held. */
static void
fdeq(Fwait *w)
{
	Fwait **l;

	for(l = &fq[fhash(w->key, w->addr)]; *l != nil; l = &(*l)->next)
		if(*l == w){
			*l = w->next;
			return;
		}
}

static int
fwoken(void *a)
{
	return ((Fwait*)a)->woken;
}

/*
 * Waits on addr if *word is val: returns 0 when woken, 1 if *word wasn't
 * val (EAGAIN), 2 at the timeout (ms >= 0), and -1 with the error set
 * when a note interrupted it.
 */
int
h9_futex_wait(void *key, uvlong addr, u32int *word, u32int val, u32int bitset, long ms)
{
	Fwait w;

	memset(&w, 0, sizeof w);
	w.key = key;
	w.addr = addr;
	w.bitset = bitset;
	lock(&flk);
	if(__atomic_load_n(word, __ATOMIC_SEQ_CST) != val){
		unlock(&flk);
		return 1;
	}
	fenq(&w);
	unlock(&flk);
	if(waserror()){
		lock(&flk);
		fdeq(&w);
		unlock(&flk);
		return syserr();
	}
	if(ms < 0)
		sleep(&w.r, fwoken, &w);
	else if(ms > 0)
		tsleep(&w.r, fwoken, &w, ms);
	poperror();
	/* A waker sets woken and calls wakeup with flk held, so once this has
	 * the lock, no waker still touches w. */
	lock(&flk);
	fdeq(&w);
	unlock(&flk);
	return w.woken ? 0 : 2;
}

/*
 * Wakes up to n waiters on addr whose bitset meets bitset, and moves up
 * to nreq more to addr2 (requeue). With word set, does nothing and
 * returns -2 unless *word is val (FUTEX_CMP_REQUEUE's EAGAIN). Returns
 * how many were woken and requeued.
 */
int
h9_futex_wake(void *key, uvlong addr, int n, u32int bitset, uvlong addr2, int nreq, u32int *word, u32int val)
{
	Fwait **l, *w, *moved;
	int woken, req;

	woken = 0;
	req = 0;
	moved = nil;
	lock(&flk);
	if(word != nil && __atomic_load_n(word, __ATOMIC_SEQ_CST) != val){
		unlock(&flk);
		return -2;
	}
	l = &fq[fhash(key, addr)];
	while((w = *l) != nil){
		if(w->key != key || w->addr != addr || (w->bitset & bitset) == 0){
			l = &w->next;
			continue;
		}
		if(woken < n){
			*l = w->next;
			w->woken = 1;
			wakeup(&w->r);
			woken++;
		} else if(req < nreq){
			*l = w->next;
			w->next = moved;
			moved = w;
			req++;
		} else
			break;
	}
	while((w = moved) != nil){
		moved = w->next;
		w->addr = addr2;
		fenq(w);
	}
	unlock(&flk);
	return woken + req;
}
