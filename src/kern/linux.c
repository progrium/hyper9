/*
 * Kernel helpers for the Linux ABI (design/epoch-0/linux-personality.md):
 * the per-process root swap at exec, walks relative to a directory fd,
 * fd flags, and await without blocking. Each returns -1 with the error
 * string set on failure, as glue.c's wrappers do.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "fscheck.h"
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

/*
 * Mark the Chan that is a root where .. stops (h9_fs_markroot): a
 * chroot's (design/epoch-0/linux-chroot.md), held in the record's lroot and as
 * slash, and a served attach root (kserve.c, design/epoch-0/kernel-serve.md),
 * held as its workers' slash. Only a chroot's makes the process's root
 * the Linux view. Not drawterm flags: only this file sets or reads them,
 * and clones don't copy them.
 */
enum { CLROOT = 0x4000, CSROOT = 0x8000 };

void	h9_fs_markroot(Chan*, int);

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
 * going to Linux, a path under /tmp or /mnt/term is kept, one in #L loses
 * the prefix, and any other gets /9 before it; going to 9front, /9 is
 * stripped and any other path gets #L before it. dot becomes a walk to
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
 * Sets the calling process's root: the Linux view (#L, renamed /) when
 * linux is set, and the machine's 9front root (#/) otherwise. A Chan's
 * mounts are keyed by its qid, so a fresh attach sees the machine's binds.
 */
static Chan*
topchan(char *name)
{
	Chan *c;

	c = namec(name, Atodir, 0, 0);
	pathclose(c->path);
	c->path = newpath("/");
	return c;
}

/*
 * The calling process's Linux root, referenced: its chroot's
 * (design/epoch-0/linux-chroot.md), or #L.
 */
static Chan*
linuxroot(void)
{
	Chan *c;

	c = h9_uphproc()->lroot;
	if(c == nil)
		return topchan("#L");
	incref(&c->ref);
	return c;
}

/*
 * Sets the calling process's root: the Linux view (#L, renamed /, or the
 * directory a chroot chose) when linux is set, and the machine's 9front
 * root (#/) otherwise. A Chan's mounts are keyed by its qid, so a fresh
 * attach sees the machine's binds.
 */
int
h9_linux_setslash(int tolinux)
{
	Chan *c;

	if(waserror())
		return syserr();
	c = tolinux ? linuxroot() : topchan("#/");
	poperror();
	cclose(swapchan(c, 1));
	renamedot(tolinux);
	return 0;
}

/* Whether the calling process's root is the Linux view, or a chroot in it. */
int
h9_linux_inview(void)
{
	return up->slash != nil && (devtab[up->slash->type]->dc == 'L' || (up->slash->flag & CLROOT) != 0);
}

/*
 * Whether the calling process's walks stop at links, for the kernel's
 * walk to follow from its root (design/epoch-0/linux-symlinks.md): a Linux
 * process's, whose root is the Linux view.
 */
int
h9_fs_linkwalk(void)
{
	return up != nil && h9_linux_inview();
}

/*
 * Makes fd's directory the calling process's dot, for a walk relative to
 * it (openat and friends), and returns the old dot for h9_linux_dotrestore.
 * The fd's Chan is open and an open Chan can't be cloned, so dot is a
 * fresh walk to the fd's path, checked to reach the same directory.
 */
static int
samedir(Chan *a, Chan *b)
{
	return a->type == b->type && a->dev == b->dev && a->qid.path == b->qid.path;
}

/*
 * Whether c is what's mounted on the mount point d. Atodir leaves a chan
 * before its mount point, as cd does, so a directory with something
 * bound on it, such as the Linux view's /tmp, walks to #L's own entry,
 * while the fd is the overlay's. Walks from d cross the mount.
 */
static int
mountedon(Chan *d, Chan *c)
{
	Chan *t;
	int ok;

	t = d;
	incref(&t->ref);
	ok = findmount(&t, nil, d->type, d->dev, d->qid) && samedir(t, c);
	cclose(t);
	return ok;
}

/*
 * namec(path, Atodir) from the top of the Linux view rather than the
 * calling process's chroot: an fd opened before a chroot was named from
 * there (design/epoch-0/linux-chroot.md).
 */
static Chan*
fromtop(char *path)
{
	Chan *old, *d;

	old = swapchan(topchan("#L"), 1);
	if(waserror()){
		cclose(swapchan(old, 1));
		nexterror();
	}
	d = namec(path, Atodir, 0, 0);
	poperror();
	cclose(swapchan(old, 1));
	return d;
}

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
	if((up->slash->flag & CLROOT) == 0)
		d = namec(chanpath(c), Atodir, 0, 0);
	else{
		/*
		 * In a chroot, the fd's path may be one from before it, named
		 * from the Linux view's top, as Linux lets an fd from outside
		 * a chroot be used in it.
		 */
		d = nil;
		if(!waserror()){
			d = namec(chanpath(c), Atodir, 0, 0);
			poperror();
		}
		if(d != nil && !samedir(d, c) && !mountedon(d, c)){
			cclose(d);
			d = nil;
		}
		if(d == nil)
			d = fromtop(chanpath(c));
	}
	if(!samedir(d, c) && !mountedon(d, c)){
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

/*
 * fd's channel, with a reference h9_linux_chanput releases: what a lazily
 * filled private file mapping reads its pages from (src/abi/linux/mm.zig),
 * after the fd is closed or renumbered. nil if fd isn't open for reading.
 */
void*
h9_linux_changet(int fd)
{
	Chan *c;

	if(waserror())
		return nil;
	c = fdtochan(fd, OREAD, 0, 1);
	poperror();
	return c;
}

/*
 * Reads up to n bytes at off from a h9_linux_changet channel: the count,
 * 0 at the end, or -1 with the error string set.
 */
long
h9_linux_chanpread(void *v, void *buf, long n, vlong off)
{
	Chan *c;
	long r;

	c = v;
	if(waserror())
		return syserr();
	r = devtab[c->type]->read(c, buf, n, off);
	poperror();
	return r;
}

void
h9_linux_chanput(void *v)
{
	if(waserror())
		return;
	cclose(v);
	poperror();
}

/*
 * syncfs(2): syncs the host file system behind fd's channel. Only devfs
 * has one; other devices, and 9P servers, have nothing to sync.
 */
int
h9_linux_syncfs(int fd)
{
	Chan *volatile c;

	c = nil;
	if(waserror()){
		if(c != nil)
			cclose(c);
		return syserr();
	}
	c = fdtochan(fd, -1, 0, 1);
	if(devtab[c->type]->dc == 'U')
		h9_fs_syncfs(c);
	cclose(c);
	poperror();
	return 0;
}

/* sync(2): syncs every host file system. */
int
h9_linux_sync(void)
{
	if(waserror())
		return syserr();
	h9_fs_sync();
	poperror();
	return 0;
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

typedef struct Wsleep Wsleep;
struct Wsleep
{
	Hproc	*ph;
	ulong	gen;
};

static int
waitchanged(void *a)
{
	Wsleep *x;

	x = a;
	return x->ph->wgen != x->gen;
}

static void
unsleep(Hproc *ph, Hproc *h)
{
	Hproc **l;

	for(l = &ph->wsleep; *l != nil; l = &(*l)->wnext)
		if(*l == h){
			*l = h->wnext;
			break;
		}
	h->wnext = nil;
}

/*
 * await for the Linux ABI: the wait record of the child `want`,
 * or of any child when want <= 0. Without block, returns 0 when there are
 * children but no such record yet, as wait4's WNOHANG. With peek, the
 * record stays, as waitid's WNOWAIT. Fails with Enochild when no child
 * could match, and is interrupted by notes.
 *
 * A Linux thread's children are its group leader's (RFLXTHREAD), so any
 * thread waits on the leader's records: Go's os/exec waits for a child
 * on whichever thread the goroutine runs on. Each waiter sleeps on its
 * own Rendez, on the leader's wsleep list, since several threads can
 * wait at once.
 */
int
h9_linux_await(char *buf, int n, int block, long want, int peek)
{
	Hproc *h, *ph;
	Hwait *w, **l, copy;
	Wsleep x;
	int len;

	if(waserror())
		return syserr();
	h = h9_uphproc();
	ph = h->waiter != nil ? h->waiter : h;
	lock(&ph->exl);
	for(;;){
		for(l = &ph->waitq; (w = *l) != nil; l = &w->next)
			if(want <= 0 || w->pid == want)
				break;
		if(w != nil)
			break;
		if(ph->nchild == 0 || ph->dead){
			unlock(&ph->exl);
			error(Enochild);
		}
		if(!block){
			unlock(&ph->exl);
			poperror();
			return 0;
		}
		x.ph = ph;
		x.gen = ph->wgen;
		h->wnext = ph->wsleep;
		ph->wsleep = h;
		unlock(&ph->exl);
		if(waserror()){
			lock(&ph->exl);
			unsleep(ph, h);
			unlock(&ph->exl);
			nexterror();
		}
		sleep(&h->lwaitr, waitchanged, &x);
		poperror();
		lock(&ph->exl);
		unsleep(ph, h);
	}
	if(peek){
		copy = *w;
		w = &copy;
	}else{
		*l = w->next;
		ph->nwait--;
	}
	unlock(&ph->exl);
	poperror();
	len = snprint(buf, n, "%lud %lud %lud %lud %q", w->pid, w->time[0], w->time[1], w->time[2], w->msg);
	if(!peek)
		free(w);
	return len;
}

/* The calling process's parent's pid, or 0 for a machine's first process,
 * as for Linux's init or a container's first process. */
ulong
h9_linux_ppid(void)
{
	Hproc *h;

	h = h9_uphproc();
	return h->ppid;
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
 * chroot(2) (design/epoch-0/linux-chroot.md): path, walked as any Linux path is,
 * becomes the calling process's Linux root, which its later forks keep
 * and exec doesn't change. Its absolute paths, its links' absolute
 * targets, and .. at the top stop there. The working directory stays as
 * it is; if it's under the new root, its name becomes the name from
 * there. A process can only name directories it can already reach, so
 * the root never widens past the Linux view: chroot to the view's own
 * top is no chroot at all.
 */
int
h9_linux_chroot(char *path)
{
	Hproc *h;
	Chan *c, *nc, *t, *old;
	char *p, *n, *s;
	int top;

	p = nil;
	c = nil;
	if(waserror()){
		free(p);
		if(c != nil)
			cclose(c);
		return syserr();
	}
	h = h9_uphproc();
	nc = namec(path, Atodir, 0, 0);
	/* A clone, so the walk's chan (up->slash itself, for "/") isn't changed. */
	if(waserror()){
		cclose(nc);
		nexterror();
	}
	c = cclone(nc);
	poperror();
	cclose(nc);
	t = topchan("#L");
	top = samedir(c, t) || mountedon(t, c);
	cclose(t);
	p = strdup(chanpath(c));
	if(p == nil)
		error(Enomem);
	if(top){
		cclose(c);
		c = nil;
	}else{
		h9_fs_markroot(c, 1);
	}

	/* The working directory's name from the new root, if it's under it. */
	n = nil;
	s = up->dot != nil && up->dot->path != nil ? up->dot->path->s : nil;
	if(s != nil && strcmp(p, "/") != 0 && under(s, p)){
		n = strdup(s[strlen(p)] != 0 ? s+strlen(p) : "/");
		if(n == nil)
			error(Enomem);
	}
	free(p);
	p = n;

	old = h->lroot;
	h->lroot = c;
	c = nil;
	if(old != nil)
		cclose(old);
	cclose(swapchan(linuxroot(), 1));

	/*
	 * Renamed by a walk from the new root, as renamedot does, so its
	 * Path is a proper one; kept as it was if that walk goes elsewhere.
	 */
	if(p != nil && !waserror()){
		t = namec(p, Atodir, 0, 0);
		poperror();
		if(samedir(t, up->dot) || mountedon(t, up->dot))
			cclose(swapchan(t, 0));
		else
			cclose(t);
	}
	free(p);
	poperror();
	return 0;
}

/*
 * Whether c is the calling process's chroot's root, where .. stays
 * (chan.c's walkl), as Linux's does at a process's root. Not for the
 * Linux view's own top, whose devices already keep .. there.
 */
int
h9_fs_atroot(Chan *c)
{
	Chan *r;

	if(up == nil || (r = up->slash) == nil || (r->flag & (CLROOT|CSROOT)) == 0)
		return 0;
	return samedir(c, r) || mountedon(r, c);
}

/*
 * Makes c, a channel of the caller's own (a clone), a root where ..
 * stops once it's a process's slash: named "/", and marked as a chroot's
 * (lx set) or a served attach root's.
 */
void
h9_fs_markroot(Chan *c, int lx)
{
	pathclose(c->path);
	c->path = newpath("/");
	c->flag |= lx ? CLROOT : CSROOT;
}

/*
 * futex (design/epoch-0/linux-threads.md): waiters queued by key (the
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
