/*
 * FIFOs for the Linux personality (design/linux-fifo.md).
 *
 * A FIFO file (an overlay's Nfifo node, or a host FIFO in a devfs tree)
 * is never read or written itself. A Linux open of one joins a pipe kept
 * for it in a table keyed by the file's identity: its device, instance,
 * and qid path, as src/linux/locks.zig keys file locks. A host file's
 * qid path is its host device and inode, so its key leaves out devfs's
 * attach number, and machines in one h9 process that open one host FIFO
 * share its pipe. One table serves every machine.
 *
 * The pipe is devpipe's, in FIFO mode (h9_fifopipe): one queue that every
 * open reads and writes, with its opens counted by mode, so read, write,
 * poll, and fstat are a pipe's. The entry holds the pipe's directory,
 * and goes once nothing has the pipe open: its queue is empty then, so a
 * later open starts afresh, as on Linux.
 *
 * The open rules are Linux's. An open joins the pipe first, so that the
 * other end's waiters see it, and then O_RDONLY waits for a writer and
 * O_WRONLY for a reader, unless one has come since the wait began (as
 * Linux's open counters say), even if it has gone again; a note
 * interrupts the wait, and the join is undone. With O_NONBLOCK, a read
 * open returns at once, and a write open with no reader fails ("no
 * reader", the caller's ENXIO). O_RDWR returns at once, as both.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#include "fscheck.h"
#include "tsleep.h"

extern Chan *h9_fifopipe(void);
extern int h9_fiforefs(Chan*, int);
extern Chan *h9_overlay_lower(Chan*);

typedef struct Fifo Fifo;
typedef struct Wait Wait;

struct Fifo
{
	Fifo	*next;
	int	dc;
	ulong	dev;
	uvlong	path;
	Chan	*dir;	/* the pipe's directory */
	ulong	gen[2];	/* opens for reading (0) and for writing (1) so far */
	Rendez	r;
};

struct Wait
{
	Fifo	*f;
	int	end;	/* the end waited for: 0 a reader, 1 a writer */
	ulong	gen;
};

static QLock fifolk;
static Fifo *fifos;

static char Enoreader[] = "no reader";

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

/* The key for c's file: a host file's by its host identity, through an overlay. */
static void
fifokey(Chan *c, int *dc, ulong *dev, uvlong *path)
{
	Chan *l;

	l = h9_overlay_lower(c);
	if(l != nil)
		c = l;
	*dc = devtab[c->type]->dc;
	*dev = *dc == 'U' ? 0 : c->dev;
	*path = c->qid.path;
	if(l != nil)
		cclose(l);
}

/* Drops entries nothing has open. With fifolk held. */
static void
fifogc(void)
{
	Fifo **l, *f;

	for(l = &fifos; (f = *l) != nil;){
		if(h9_fiforefs(f->dir, 0) == 0 && h9_fiforefs(f->dir, 1) == 0){
			*l = f->next;
			cclose(f->dir);
			free(f);
			continue;
		}
		l = &f->next;
	}
}

/* The entry for the key, made if there's none. With fifolk held. */
static Fifo*
fifoget(int dc, ulong dev, uvlong path)
{
	Fifo *f;

	for(f = fifos; f != nil; f = f->next)
		if(f->dc == dc && f->dev == dev && f->path == path)
			return f;
	f = mallocz(sizeof(Fifo), 1);
	if(f == nil)
		error(Enomem);
	if(waserror()){
		free(f);
		nexterror();
	}
	f->dir = h9_fifopipe();
	poperror();
	f->dc = dc;
	f->dev = dev;
	f->path = path;
	f->next = fifos;
	fifos = f;
	return f;
}

/* Whether the end w waits for has an open, or has had one since the wait began. */
static int
arrived(void *a)
{
	Wait *w;

	w = a;
	return w->f->gen[w->end] != w->gen || h9_fiforefs(w->f->dir, w->end) > 0;
}

/* An open of f's pipe's data file in mode. */
static Chan*
fifochan(Fifo *f, int mode)
{
	Walkqid *wq;
	Chan *c;
	char *name;

	name = "data";
	wq = devtab[f->dir->type]->walk(f->dir, nil, &name, 1);
	if(wq == nil)
		error(Enonexist);
	c = wq->clone;
	free(wq);
	if(c == nil)
		error(Enonexist);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	c = devtab[c->type]->open(c, mode);
	poperror();
	return c;
}

/*
 * Whether fd is a FIFO's file, which a Linux open must join instead
 * (h9_linux_fifojoin): 1 or 0, or -1 with the error set.
 */
int
h9_linux_isfifo(int fd)
{
	Chan *c;
	int r;

	if(waserror())
		return syserr();
	c = fdtochan(fd, -1, 0, 1);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	r = (c->qid.type & QTDIR) == 0 && h9_fs_chanisfifo(c);
	poperror();
	cclose(c);
	poperror();
	return r;
}

/*
 * Replaces fd, an open FIFO file, with an open of its pipe in mode
 * (OREAD, OWRITE, or ORDWR), waiting for the other end unless nonblock
 * or ORDWR. Returns 0, or -1 with the error set: "no reader" for a
 * nonblocking write open with no reader, or the note's interruption.
 */
int
h9_linux_fifojoin(int fd, int mode, int nonblock)
{
	Chan *volatile c, *old;
	Fifo *f;
	Fgrp *fg;
	Wait w;
	int dc, rd, wr;
	ulong dev;
	uvlong path;

	c = nil;
	if(waserror()){
		if(c != nil)
			cclose(c);
		return syserr();
	}
	c = fdtochan(fd, -1, 0, 1);
	fifokey(c, &dc, &dev, &path);
	cclose(c);
	c = nil;
	rd = mode != OWRITE;
	wr = mode != OREAD;
	qlock(&fifolk);
	if(waserror()){
		qunlock(&fifolk);
		nexterror();
	}
	fifogc();
	f = fifoget(dc, dev, path);
	if(wr && !rd && nonblock && h9_fiforefs(f->dir, 0) == 0)
		error(Enoreader);
	c = fifochan(f, mode);
	if(rd)
		f->gen[0]++;
	if(wr)
		f->gen[1]++;
	wakeup(&f->r);
	if(!(rd && wr) && !nonblock){
		w.f = f;
		w.end = rd;
		w.gen = f->gen[w.end];
		while(!arrived(&w)){
			qunlock(&fifolk);
			if(waserror()){
				qlock(&fifolk);
				nexterror();
			}
			tsleep(&f->r, arrived, &w, 100);
			poperror();
			qlock(&fifolk);
		}
	}
	poperror();
	qunlock(&fifolk);
	fg = up->fgrp;
	lock(&fg->ref.lk);
	if(fd > fg->maxfd || (old = fg->fd[fd]) == nil){
		unlock(&fg->ref.lk);
		error(Ebadfd);
	}
	fg->fd[fd] = c;
	unlock(&fg->ref.lk);
	c = nil;
	cclose(old);
	poperror();
	return 0;
}
