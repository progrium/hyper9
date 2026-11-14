#include	"u.h"
#include	"lib.h"
#include	"dat.h"
#include	"fns.h"
#include	"error.h"

#include	"netif.h"

typedef struct Pipe	Pipe;
struct Pipe
{
	QLock lk;
	Pipe	*next;
	int	ref;
	ulong	path;
	Queue	*q[2];
	int	qref[2];
	int	fifo;	/* h9: a Linux FIFO's pipe (h9_fifopipe) */
	int	fref[2];	/* h9: a FIFO's opens for reading and for writing */
};

struct
{
	Lock lk;
	ulong	path;
} pipealloc;

enum
{
	Qdir,
	Qdata0,
	Qdata1,
};

Dirtab pipedir[] =
{
	".",		{Qdir,0,QTDIR},	0,		DMDIR|0500,
	"data",		{Qdata0},	0,		0600,
	"data1",	{Qdata1},	0,		0600,
};
#define NPIPEDIR 3

static void
pipeinit(void)
{
	if(conf.pipeqsize == 0){
		if(conf.nmach > 1)
			conf.pipeqsize = 256*1024;
		else
			conf.pipeqsize = 32*1024;
	}
}

/*
 *  create a pipe, no streams are created until an open
 */
static Chan*
pipeattach(char *spec)
{
	Pipe *p;
	Chan *c;

	c = devattach('|', spec);
	p = malloc(sizeof(Pipe));
	if(p == 0)
		exhausted("memory");
	p->ref = 1;

	p->q[0] = qopen(conf.pipeqsize, 0, 0, 0);
	if(p->q[0] == 0){
		free(p);
		exhausted("memory");
	}
	p->q[1] = qopen(conf.pipeqsize, 0, 0, 0);
	if(p->q[1] == 0){
		free(p->q[0]);
		free(p);
		exhausted("memory");
	}

	lock(&pipealloc.lk);
	p->path = ++pipealloc.path;
	unlock(&pipealloc.lk);

	mkqid(&c->qid, NETQID(2*p->path, Qdir), 0, QTDIR);
	c->aux = p;
	c->dev = 0;
	return c;
}

static int
pipegen(Chan *c, char *name, Dirtab *tab, int ntab, int i, Dir *dp)
{
	Qid q;
	int len;
	Pipe *p;

	USED(name);

	if(i == DEVDOTDOT){
		devdir(c, c->qid, "#|", 0, eve, DMDIR|0555, dp);
		return 1;
	}
	i++;	/* skip . */
	if(tab==0 || i>=ntab)
		return -1;

	tab += i;
	p = c->aux;
	switch((ulong)tab->qid.path){
	case Qdata0:
		len = qlen(p->q[0]);
		break;
	case Qdata1:
		len = qlen(p->q[1]);
		break;
	default:
		len = tab->length;
		break;
	}
	mkqid(&q, NETQID(NETID(c->qid.path), tab->qid.path), 0, QTFILE);
	devdir(c, q, tab->name, len, eve, tab->perm, dp);
	return 1;
}


static Walkqid*
pipewalk(Chan *c, Chan *nc, char **name, int nname)
{
	Walkqid *wq;
	Pipe *p;

	wq = devwalk(c, nc, name, nname, pipedir, NPIPEDIR, pipegen);
	if(wq != nil && wq->clone != nil && wq->clone != c){
		p = c->aux;
		qlock(&p->lk);
		p->ref++;
		if(c->flag & COPEN){
			print("channel open in pipewalk\n");
			switch(NETTYPE(c->qid.path)){
			case Qdata0:
				p->qref[0]++;
				break;
			case Qdata1:
				p->qref[1]++;
				break;
			}
		}
		qunlock(&p->lk);
	}
	return wq;
}

static int
pipestat(Chan *c, uchar *db, int n)
{
	Pipe *p;
	Dir dir;

	p = c->aux;

	switch(NETTYPE(c->qid.path)){
	case Qdir:
		devdir(c, c->qid, ".", 0, eve, DMDIR|0555, &dir);
		break;
	case Qdata0:
		devdir(c, c->qid, "data", qlen(p->q[0]), eve, 0600, &dir);
		break;
	case Qdata1:
		devdir(c, c->qid, "data1", qlen(p->q[1]), eve, 0600, &dir);
		break;
	default:
		panic("pipestat");
	}
	n = convD2M(&dir, db, n);
	if(n < BIT16SZ)
		error(Eshortstat);
	return n;
}

/*
 * h9: a Linux FIFO's pipe (design/linux-fifo.md) has one queue, q[0],
 * that every open reads and writes, as a Linux pipe does, whichever data
 * file it's of. Its opens are counted by their mode: ORDWR is a reader and
 * a writer. Once the last writer closes, readers drain the queue and then
 * read EOF, as does a reader that opens with no writer; once the last
 * reader closes, writes fail. A reader and a writer both open again make
 * a working pipe, and the last close of all empties it.
 */
static void
fifoopen(Pipe *p, int mode)
{
	if(mode != OWRITE)
		p->fref[0]++;
	if(mode != OREAD)
		p->fref[1]++;
	if(p->fref[0] > 0 && p->fref[1] > 0)
		qreopen(p->q[0]);
	else if(p->fref[1] == 0)
		qhangup(p->q[0], 0);	/* a reader with no writer reads EOF */
}

static void
fifoclose(Pipe *p, int mode)
{
	if(mode != OWRITE && --p->fref[0] == 0)
		qhangup(p->q[0], 0);
	if(mode != OREAD && --p->fref[1] == 0)
		qhangup(p->q[0], 0);
	if(p->fref[0] == 0 && p->fref[1] == 0){
		qclose(p->q[0]);
		qreopen(p->q[0]);
	}
}

/*
 * h9: a FIFO read at the end of a hung-up queue is EOF however often
 * it's read, as on Linux; qread fails a fourth.
 */
static int
fifoeof(Pipe *p)
{
	return p->fifo && qisclosed(p->q[0]) && qlen(p->q[0]) == 0;
}

/*
 *  if the stream doesn't exist, create it
 */
static Chan*
pipeopen(Chan *c, int omode)
{
	Pipe *p;

	if(c->qid.type & QTDIR){
		if(omode != OREAD)
			error(Ebadarg);
		c->mode = omode;
		c->flag |= COPEN;
		c->offset = 0;
		return c;
	}

	p = c->aux;
	qlock(&p->lk);
	if(p->fifo)
		fifoopen(p, openmode(omode));
	else
	switch(NETTYPE(c->qid.path)){
	case Qdata0:
		p->qref[0]++;
		break;
	case Qdata1:
		p->qref[1]++;
		break;
	}
	qunlock(&p->lk);

	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	c->iounit = qiomaxatomic;
	return c;
}

static void
pipeclose(Chan *c)
{
	Pipe *p;

	p = c->aux;
	qlock(&p->lk);

	if((c->flag & COPEN) && p->fifo && NETTYPE(c->qid.path) != Qdir)
		fifoclose(p, c->mode);
	else if(c->flag & COPEN){
		/*
		 *  closing either side hangs up the stream
		 */
		switch(NETTYPE(c->qid.path)){
		case Qdata0:
			p->qref[0]--;
			if(p->qref[0] == 0){
				qhangup(p->q[1], 0);
				qclose(p->q[0]);
			}
			break;
		case Qdata1:
			p->qref[1]--;
			if(p->qref[1] == 0){
				qhangup(p->q[0], 0);
				qclose(p->q[1]);
			}
			break;
		}
	}


	/*
	 *  if both sides are closed, they are reusable
	 */
	if(!p->fifo && p->qref[0] == 0 && p->qref[1] == 0){
		qreopen(p->q[0]);
		qreopen(p->q[1]);
	}

	/*
	 *  free the structure on last close
	 */
	p->ref--;
	if(p->ref == 0){
		qunlock(&p->lk);
		free(p->q[0]);
		free(p->q[1]);
		free(p);
	} else
		qunlock(&p->lk);
}

static long
piperead(Chan *c, void *va, long n, vlong offset)
{
	Pipe *p;

	USED(offset);

	p = c->aux;

	switch(NETTYPE(c->qid.path)){
	case Qdir:
		return devdirread(c, va, n, pipedir, NPIPEDIR, pipegen);
	case Qdata0:
	case Qdata1:
		if(fifoeof(p))
			return 0;
		return qread(p->q[NETTYPE(c->qid.path) == Qdata1 && !p->fifo], va, n);
	default:
		panic("piperead");
	}
	return -1;	/* not reached */
}

static Block*
pipebread(Chan *c, long n, ulong offset)
{
	Pipe *p;

	p = c->aux;

	switch(NETTYPE(c->qid.path)){
	case Qdata0:
	case Qdata1:
		if(fifoeof(p))
			return allocb(0);
		return qbread(p->q[NETTYPE(c->qid.path) == Qdata1 && !p->fifo], n);
	}

	return devbread(c, n, offset);
}

/*
 *  a write to a closed pipe causes a note to be sent to
 *  the process.
 */
static long
pipewrite(Chan *c, void *va, long n, vlong offset)
{
	Pipe *p;

	USED(offset);

	if(waserror()) {
		/* avoid notes when pipe is a mounted queue */
		if((c->flag & CMSG) == 0)
			postnote(up, 1, "sys: write on closed pipe", NUser);
		nexterror();
	}

	p = c->aux;

	switch(NETTYPE(c->qid.path)){
	case Qdata0:
		n = qwrite(p->q[p->fifo ? 0 : 1], va, n);
		break;

	case Qdata1:
		n = qwrite(p->q[0], va, n);
		break;

	default:
		panic("pipewrite");
	}

	poperror();
	return n;
}

static long
pipebwrite(Chan *c, Block *bp, ulong offset)
{
	long n;
	Pipe *p;

	USED(offset);

	if(waserror()) {
		/* avoid notes when pipe is a mounted queue */
		if((c->flag & CMSG) == 0)
			postnote(up, 1, "sys: write on closed pipe", NUser);
		nexterror();
	}

	p = c->aux;
	switch(NETTYPE(c->qid.path)){
	case Qdata0:
		n = qbwrite(p->q[p->fifo ? 0 : 1], bp);
		break;

	case Qdata1:
		n = qbwrite(p->q[0], bp);
		break;

	default:
		n = 0;
		panic("pipebwrite");
	}

	poperror();
	return n;
}

Dev pipedevtab = {
	'|',
	"pipe",

	devreset,
	pipeinit,
	devshutdown,
	pipeattach,
	pipewalk,
	pipestat,
	pipeopen,
	devcreate,
	pipeclose,
	piperead,
	pipebread,
	pipewrite,
	pipebwrite,
	devremove,
	devwstat,
};

/*
 * h9: the queue a read of c takes from (wr == 0) or a write to c adds
 * to, for Linux poll (src/kern/linuxnet.c); nil if c isn't a data file.
 */
Queue*
h9_pipeq(Chan *c, int wr)
{
	Pipe *p;

	p = c->aux;
	if(p == nil)
		return nil;
	if(p->fifo && NETTYPE(c->qid.path) != Qdir)
		return p->q[0];
	switch(NETTYPE(c->qid.path)){
	case Qdata0:
		return p->q[wr ? 1 : 0];
	case Qdata1:
		return p->q[wr ? 0 : 1];
	}
	return nil;
}

/*
 * h9: a new pipe for a Linux FIFO (src/kern/fifo.c), as its directory's
 * chan, and opens of its data file (see fifoopen).
 */
Chan*
h9_fifopipe(void)
{
	Chan *c;

	c = pipeattach(nil);
	((Pipe*)c->aux)->fifo = 1;
	return c;
}

/* h9: a FIFO's opens for reading (end 0) or writing (end 1), by its directory's chan. */
int
h9_fiforefs(Chan *dir, int end)
{
	Pipe *p;
	int n;

	p = dir->aux;
	qlock(&p->lk);
	n = p->fref[end != 0];
	qunlock(&p->lk);
	return n;
}

