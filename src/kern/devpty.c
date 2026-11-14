/*
 * #τ: pseudoterminal pairs (design/linux-pty.md). The Linux view serves
 * /dev/ptmx as #τ/ptmx and /dev/pts as #τ itself.
 *
 *	#τ/ptmx	a clone file: each open makes a pair and returns its master
 *	#τ/N	pair N's slave, which opens while the master is open and
 *		the pair is unlocked
 *
 * A pair has a queue each way, 64 KiB as Linux's N_TTY buffer is: the
 * master's writes are the slave's reads, and the other way round. It
 * also keeps the Linux state of the terminal: its termios, window size,
 * foreground process group, session, and lock. The Linux personality
 * reads and writes that through h9_pty_get and h9_pty_set, on an fd of
 * either side; the ioctls are its interface (src/linux/sys.zig), and the
 * state is only stored here. Data passes through unchanged: this is a raw
 * pty, without a line discipline.
 *
 * Until the slave first opens, a master read waits, as on Linux. When
 * the slave's last open closes, the master reads what's left and then
 * an end of file, which the personality makes EIO, as Linux has it;
 * opening the slave again reopens it. When the master closes, the slave
 * reads to an end of file, its writes fail with EIO, the session's
 * terminal is gone, and the foreground group is sent SIGHUP through
 * h9_ptyhup. A pair goes when both sides have closed, and its number is
 * reused.
 *
 * Pairs belong to the machine of the process that opened ptmx, and
 * numbers start at 0 on each machine: a machine's #τ lists and opens
 * only its own.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"

enum
{
	Tau = 0x3C4,

	Qdir = 0,
	Qptmx,
	Qmaster,
	Qslave,

	Npty = 4096,		/* pairs per machine, as Linux's kernel.pty.max */
	Ptyq = 64*1024,		/* each way, as Linux's N_TTY buffer */
	Termlen = 60,		/* the personality's termios, of which the kernel's is the first 36 bytes */
};

#define QTYPE(p)	((int)((p) & 0xf))
#define QNUM(p)	((int)((p) >> 4))
#define QPATH(t, n)	(((uvlong)(n) << 4) | (t))

static char Eptyio[] = "errno 5";	/* EIO, through attr.errno */

typedef struct Pty Pty;
struct Pty
{
	Lock	lk;	/* the fields below */
	Pty	*next;
	void	*mach;	/* the Hmach it belongs to, as a key */
	int	n;
	int	mopen;	/* opens of the master */
	int	sopen;	/* opens of the slave */
	Queue	*in;	/* master to slave */
	Queue	*out;	/* slave to master */

	uchar	termios[Termlen];
	ushort	winsz[4];	/* rows, cols, xpixel, ypixel */
	ulong	fg;	/* the foreground process group, or 0 */
	ulong	sid;	/* the session it's the terminal of, or 0 */
	int	locked;
};

/* The pair state h9_pty_get and h9_pty_set copy; src/linux/kc.zig's PtyState. */
typedef struct Ptystate Ptystate;
struct Ptystate
{
	uchar	termios[Termlen];
	ushort	winsz[4];
	uint	fg;
	uint	sid;
	int	locked;
	int	n;
	int	master;
	int	slaveopen;
};

enum
{
	Stermios = 1<<0,
	Swinsz = 1<<1,
	Sfg = 1<<2,
	Ssid = 1<<3,
	Slock = 1<<4,
};

static struct
{
	Lock	lk;
	Pty	*list;
} ptys;

/* The personality's default termios, set on each new pair (h9_pty_setdefault). */
static uchar defterm[Termlen];

/*
 * Posts SIGHUP to process group fg of the calling process's machine
 * (src/machine.zig), when a master's last close hangs the pair up.
 */
void	(*h9_ptyhup)(ulong fg, ulong sid);

static void*
upmach(void)
{
	return h9_uphproc()->mach;
}

/* Pair n of the caller's machine, or nil; under ptys.lk. */
static Pty*
lookup(void *m, int n)
{
	Pty *p;

	for(p = ptys.list; p != nil; p = p->next)
		if(p->mach == m && p->n == n)
			return p;
	return nil;
}

static Pty*
newpty(void)
{
	Pty *p, **l;
	void *m;
	int n;

	p = malloc(sizeof *p);
	if(p == nil)
		exhausted("memory");
	memset(p, 0, sizeof *p);
	p->in = qopen(Ptyq, 0, 0, 0);
	p->out = qopen(Ptyq, 0, 0, 0);
	if(p->in == nil || p->out == nil){
		free(p->in);
		free(p->out);
		free(p);
		exhausted("memory");
	}
	memmove(p->termios, defterm, Termlen);
	m = upmach();
	p->mach = m;
	p->mopen = 1;
	p->locked = 1;
	lock(&ptys.lk);
	for(n = 0; n < Npty; n++)
		if(lookup(m, n) == nil)
			break;
	if(n == Npty){
		unlock(&ptys.lk);
		qfree(p->in);
		qfree(p->out);
		free(p);
		error("no free ptys");
	}
	p->n = n;
	/* Kept in number order, so the directory lists them so. */
	for(l = &ptys.list; *l != nil && ((*l)->mach != m || (*l)->n < n); l = &(*l)->next)
		;
	p->next = *l;
	*l = p;
	unlock(&ptys.lk);
	return p;
}

/* Takes p off the list and frees it; both sides have closed. */
static void
freepty(Pty *p)
{
	Pty **l;

	lock(&ptys.lk);
	for(l = &ptys.list; *l != nil; l = &(*l)->next)
		if(*l == p){
			*l = p->next;
			break;
		}
	unlock(&ptys.lk);
	qfree(p->in);
	qfree(p->out);
	free(p);
}

static void
ptyinit(void)
{
	/* c_iflag ICRNL|IXON, c_oflag OPOST|ONLCR, c_cflag CS8|CREAD|B38400, c_lflag ISIG|ICANON|ECHO|ECHOE|ECHOK|IEXTEN|ECHOCTL|ECHOKE */
	static uchar cc[] = {3, 0x1c, 0x7f, 0x15, 4, 0, 1, 0, 0x11, 0x13, 0x1a};
	ulong f[4] = {0400|02000, 01|04, 060|0200|017, 01|02|010|020|040|0100000|01000|04000};
	int i;

	for(i = 0; i < 4; i++){
		defterm[4*i] = f[i];
		defterm[4*i+1] = f[i]>>8;
		defterm[4*i+2] = f[i]>>16;
		defterm[4*i+3] = f[i]>>24;
	}
	memmove(defterm+17, cc, sizeof cc);
}

static int
ptygen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Qid q;
	Pty *p;
	void *m;
	char *end;
	int n;

	USED(tab, ntab);
	if(s == DEVDOTDOT){
		mkqid(&q, QPATH(Qdir, 0), 0, QTDIR);
		devdir(c, q, "#τ", 0, eve, DMDIR|0555, dp);
		return 1;
	}
	if(name != nil && strcmp(name, "ptmx") == 0)
		s = 0;
	else if(name != nil){
		n = strtoul(name, &end, 10);
		if(*end != 0 || name[0] == 0 || (name[0] == '0' && name[1] != 0))
			return -1;
		lock(&ptys.lk);
		p = lookup(upmach(), n);
		unlock(&ptys.lk);
		if(p == nil)
			return -1;
		mkqid(&q, QPATH(Qslave, n), 0, QTFILE);
		snprint(up->genbuf, sizeof up->genbuf, "%d", n);
		devdir(c, q, up->genbuf, 0, eve, 0620, dp);
		return 1;
	}
	if(s == 0){
		mkqid(&q, QPATH(Qptmx, 0), 0, QTFILE);
		devdir(c, q, "ptmx", 0, eve, 0666, dp);
		return 1;
	}
	s--;
	m = upmach();
	n = -1;
	lock(&ptys.lk);
	for(p = ptys.list; p != nil; p = p->next)
		if(p->mach == m && s-- == 0){
			n = p->n;
			break;
		}
	unlock(&ptys.lk);
	if(n < 0)
		return -1;
	mkqid(&q, QPATH(Qslave, n), 0, QTFILE);
	snprint(up->genbuf, sizeof up->genbuf, "%d", n);
	devdir(c, q, up->genbuf, 0, eve, 0620, dp);
	return 1;
}

static Chan*
ptyattach(char *spec)
{
	Chan *c;

	c = devattach(Tau, spec);
	mkqid(&c->qid, QPATH(Qdir, 0), 0, QTDIR);
	return c;
}

static Walkqid*
ptywalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, ptygen);
}

static int
ptystat(Chan *c, uchar *db, int n)
{
	Dir d;
	Qid q;
	char buf[16];

	switch(QTYPE(c->qid.path)){
	case Qdir:
		devdir(c, c->qid, "#τ", 0, eve, DMDIR|0555, &d);
		break;
	case Qptmx:
	case Qmaster:
		/* A master is ptmx's, as on Linux: its rdev is 5,2. */
		mkqid(&q, c->qid.path, 0, QTFILE);
		devdir(c, q, "ptmx", 0, eve, 0666, &d);
		break;
	case Qslave:
		snprint(buf, sizeof buf, "%d", QNUM(c->qid.path));
		devdir(c, c->qid, buf, 0, eve, 0620, &d);
		break;
	default:
		error(Egreg);
	}
	n = convD2M(&d, db, n);
	if(n == 0)
		error(Ebadarg);
	return n;
}

static Chan*
ptyopen(Chan *c, int omode)
{
	Pty *p;
	int t;

	t = QTYPE(c->qid.path);
	if(t == Qdir){
		if(omode != OREAD)
			error(Eperm);
		c->mode = openmode(omode);
		c->flag |= COPEN;
		c->offset = 0;
		return c;
	}
	c->aux = nil;
	if(t == Qptmx){
		p = newpty();
		mkqid(&c->qid, QPATH(Qmaster, p->n), 0, QTFILE);
	}else if(t == Qslave){
		lock(&ptys.lk);
		p = lookup(upmach(), QNUM(c->qid.path));
		if(p != nil){
			lock(&p->lk);
			if(p->mopen == 0 || p->locked){
				unlock(&p->lk);
				p = nil;
			}else{
				if(p->sopen++ == 0)
					qreopen(p->out);
				unlock(&p->lk);
			}
		}
		unlock(&ptys.lk);
		if(p == nil)
			error(Eptyio);
	}else
		error(Egreg);
	c->aux = p;
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	c->iounit = qiomaxatomic;
	return c;
}

static void
ptyclose(Chan *c)
{
	Pty *p;
	ulong fg, sid;
	int gone, hup;

	p = c->aux;
	if((c->flag & COPEN) == 0 || p == nil)
		return;
	c->aux = nil;
	hup = 0;
	fg = sid = 0;
	lock(&p->lk);
	if(QTYPE(c->qid.path) == Qmaster){
		if(--p->mopen == 0){
			/* The slave reads an end of file (Ehungup's), and writes EIO. */
			qhangup(p->in, nil);
			qhangup(p->out, Eptyio);
			hup = p->sopen > 0 && p->fg != 0;
			fg = p->fg;
			sid = p->sid;
			p->sid = 0;
			p->fg = 0;
		}
	}else if(--p->sopen == 0)
		qhangup(p->out, Eptyio);
	gone = p->mopen == 0 && p->sopen == 0;
	unlock(&p->lk);
	if(gone)
		freepty(p);
	if(hup && h9_ptyhup != nil)
		h9_ptyhup(fg, sid);
}

static Pty*
chanpty(Chan *c)
{
	Pty *p;

	p = c->aux;
	if(p == nil)
		error(Egreg);
	return p;
}

static long
ptyread(Chan *c, void *va, long n, vlong off)
{
	Pty *p;

	USED(off);
	switch(QTYPE(c->qid.path)){
	case Qdir:
		return devdirread(c, va, n, nil, 0, ptygen);
	case Qmaster:
		p = chanpty(c);
		return qread(p->out, va, n);
	case Qslave:
		p = chanpty(c);
		return qread(p->in, va, n);
	}
	error(Egreg);
	return -1;
}

static long
ptywrite(Chan *c, void *va, long n, vlong off)
{
	Pty *p;

	USED(off);
	/* An empty block would read as an end of file. */
	if(n == 0)
		return 0;
	switch(QTYPE(c->qid.path)){
	case Qmaster:
		p = chanpty(c);
		return qwrite(p->in, va, n);
	case Qslave:
		p = chanpty(c);
		return qwrite(p->out, va, n);
	}
	error(Eperm);
	return -1;
}

Dev ptydevtab = {
	Tau,
	"pty",

	devreset,
	ptyinit,
	devshutdown,
	ptyattach,
	ptywalk,
	ptystat,
	ptyopen,
	devcreate,
	ptyclose,
	ptyread,
	devbread,
	ptywrite,
	devbwrite,
	devremove,
	devwstat,
};

/*
 * The queue a read of c takes from (wr == 0) or a write to c adds to,
 * for Linux poll (src/kern/linuxnet.c); nil if c isn't an open side.
 */
Queue*
h9_ptyq(Chan *c, int wr)
{
	Pty *p;

	p = c->aux;
	if(p == nil || (c->flag & COPEN) == 0)
		return nil;
	switch(QTYPE(c->qid.path)){
	case Qmaster:
		return wr ? p->in : p->out;
	case Qslave:
		return wr ? p->out : p->in;
	}
	return nil;
}

/* The pair behind fd, with whether it's the master; nil if it isn't one. */
static Pty*
fdpty(int fd, Chan **cp)
{
	Chan *c;

	c = fdtochan(fd, -1, 0, 1);
	if(devtab[c->type]->dc != Tau || c->aux == nil || (c->flag & COPEN) == 0){
		cclose(c);
		return nil;
	}
	*cp = c;
	return c->aux;
}

/*
 * Copies the state of the pair behind fd into *s. Returns 0, or -1 if
 * fd isn't a side of a pair.
 */
int
h9_pty_get(int fd, Ptystate *s)
{
	Chan *c;
	Pty *p;

	if(waserror())
		return -1;
	p = fdpty(fd, &c);
	poperror();
	if(p == nil)
		return -1;
	lock(&p->lk);
	memmove(s->termios, p->termios, Termlen);
	memmove(s->winsz, p->winsz, sizeof s->winsz);
	s->fg = p->fg;
	s->sid = p->sid;
	s->locked = p->locked;
	s->n = p->n;
	s->master = QTYPE(c->qid.path) == Qmaster;
	s->slaveopen = p->sopen > 0;
	unlock(&p->lk);
	cclose(c);
	return 0;
}

/*
 * Sets the fields of the pair behind fd that `what` names (Stermios,
 * Swinsz, Sfg, Ssid, and Slock) from *s. With Ssid and Sfg together
 * and `excl`, it sets them only if the pair is no session's terminal
 * yet, as an open of the slave by a session leader takes it. Returns 0,
 * 1 if excl left it as it was, or -1 if fd isn't a side of a pair.
 */
int
h9_pty_set(int fd, Ptystate *s, int what, int excl)
{
	Chan *c;
	Pty *p;
	int r;

	if(waserror())
		return -1;
	p = fdpty(fd, &c);
	poperror();
	if(p == nil)
		return -1;
	r = 0;
	lock(&p->lk);
	if(excl && p->sid != 0)
		r = 1;
	else{
		if(what & Stermios)
			memmove(p->termios, s->termios, Termlen);
		if(what & Swinsz)
			memmove(p->winsz, s->winsz, sizeof p->winsz);
		if(what & Sfg)
			p->fg = s->fg;
		if(what & Ssid)
			p->sid = s->sid;
		if(what & Slock)
			p->locked = s->locked;
	}
	unlock(&p->lk);
	cclose(c);
	return r;
}

/*
 * The number of the caller's machine's pair that is session sid's
 * terminal, or -1: what /dev/tty opens.
 */
int
h9_pty_bysid(ulong sid)
{
	Pty *p;
	void *m;
	int n;

	if(sid == 0)
		return -1;
	m = upmach();
	n = -1;
	lock(&ptys.lk);
	for(p = ptys.list; p != nil; p = p->next)
		if(p->mach == m && p->sid == sid && p->mopen > 0){
			n = p->n;
			break;
		}
	unlock(&ptys.lk);
	return n;
}

/*
 * Bytes queued for fd: to read (wr == 0) or written and not yet read
 * (wr == 1); -1 if fd isn't a side of a pair. With flush, they're
 * discarded instead, and the count is 0.
 */
long
h9_pty_queued(int fd, int wr, int flush)
{
	Chan *c;
	Queue *q;
	long n;

	if(waserror())
		return -1;
	c = fdtochan(fd, -1, 0, 1);
	n = -1;
	if(devtab[c->type]->dc == Tau && (q = h9_ptyq(c, wr)) != nil){
		if(flush){
			qflush(q);
			n = 0;
		}else
			n = qlen(q);
	}
	poperror();
	cclose(c);
	return n;
}

void
h9_pty_sethup(void (*f)(ulong, ulong))
{
	h9_ptyhup = f;
}
