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
 * either side; the ioctls are its interface (src/linux/sys.zig). The
 * termios is applied here, as a line discipline (below).
 *
 * Until the slave first opens, a master read waits, as on Linux. When
 * the slave's last open closes, the master reads what's left and then
 * an end of file, which the personality makes EIO, as Linux has it;
 * opening the slave again reopens it. When the master closes, the slave
 * reads to an end of file, its writes fail with EIO, the session's
 * terminal is gone, and the foreground group is sent SIGHUP through
 * h9_ptysig. A pair goes when both sides have closed, and its number is
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
	Linemax = 4096,		/* a canonical line, as N_TTY's */
	Chunk = 4096,		/* input taken through the line discipline at a time */
	Maxsig = 8,

	/* Linux's termios flags and c_cc indices. */
	ISTRIP = 040, INLCR = 0100, IGNCR = 0200, ICRNL = 0400,
	OPOST = 01, ONLCR = 04, OCRNL = 010,
	ISIG = 01, ICANON = 02, ECHO = 010, ECHOE = 020, ECHOK = 040, ECHONL = 0100,
	NOFLSH = 0200, ECHOCTL = 01000, ECHOKE = 04000, IEXTEN = 0100000,
	VINTR = 0, VQUIT, VERASE, VKILL, VEOF, VTIME, VMIN, VSWTC, VSTART, VSTOP, VSUSP,
	VEOL, VREPRINT, VDISCARD, VWERASE, VLNEXT, VEOL2,
	Ccoff = 17,

	SIGHUP = 1, SIGINT = 2, SIGQUIT = 3, SIGTSTP = 20,
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

	uchar	line[Linemax];	/* the canonical line being edited */
	int	nline;
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
 * Posts Linux signal signo to process group pgrp of the calling
 * process's machine (src/machine.zig): SIGHUP when a master's last
 * close hangs the pair up, and SIGINT, SIGQUIT, and SIGTSTP for the
 * ISIG characters.
 */
void	(*h9_ptysig)(ulong pgrp, int signo);

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
	static uchar cc[] = {3, 0x1c, 0x7f, 0x15, 4, 0, 1, 0, 0x11, 0x13, 0x1a, 0, 0x12, 0x0f, 0x17, 0x16};	/* Linux's, through VLNEXT */
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


/*
 * The line discipline (design/linux-pty.md, step 2), as Linux's N_TTY
 * applies the pair's termios: input written to the master goes through
 * the input flags, ISIG, canonical editing, and echo on its way to the
 * slave, and the slave's writes through the output flags on their way
 * to the master. Echo is the slave's output too, so it reaches the
 * master after output processing. In canonical mode, each line (or a
 * VEOF) is a block of its own in the slave's queue, and a read takes at
 * most one, so it returns at most a line; an empty block is the end of
 * file VEOF on an empty line makes. Echo and lines are added without
 * waiting, and dropped when the queue is full, as N_TTY drops input
 * beyond its buffer; raw input waits for room, as a master write
 * does on Linux. VMIN and VTIME are the personality's (src/linux/sys.zig).
 */

static ulong
flag(Pty *p, int off)
{
	uchar *t;

	t = p->termios + off;
	return t[0] | t[1]<<8 | t[2]<<16 | (ulong)t[3]<<24;
}

static int
iscc(Pty *p, int c, int v)
{
	int cc;

	cc = p->termios[Ccoff+v];
	return cc != 0 && c == cc;	/* 0 is _POSIX_VDISABLE */
}

/* Output processing of c into b; returns the bytes it made. */
static int
opost(ulong oflag, int c, uchar *b)
{
	if(oflag & OPOST){
		if(c == '\n' && (oflag & ONLCR)){
			b[0] = '\r';
			b[1] = '\n';
			return 2;
		}
		if(c == '\r' && (oflag & OCRNL))
			c = '\n';
	}
	b[0] = c;
	return 1;
}

/* The width echo gives c: 2 for a control character shown as ^X. */
static int
ctlwidth(ulong lflag, int c)
{
	return (lflag & ECHOCTL) && (c < 0x20 || c == 0x7f) && c != '\t' && c != '\n' ? 2 : 1;
}

/* Echoes c into e (with output processing); returns the bytes. */
static int
echo1(Pty *p, ulong lflag, int c, uchar *e)
{
	if(ctlwidth(lflag, c) == 2){
		e[0] = '^';
		e[1] = c == 0x7f ? '?' : c + 0x40;
		return 2;
	}
	return opost(flag(p, 4), c, e);
}

/* Erases the last character of the line, echoing it away if ECHOE. */
static int
erase1(Pty *p, ulong lflag, uchar *e)
{
	int c, w, n;

	if(p->nline == 0)
		return 0;
	c = p->line[--p->nline];
	if(!(lflag & ECHO))
		return 0;
	if(!(lflag & ECHOE))
		return echo1(p, lflag, p->termios[Ccoff+VERASE], e);
	n = 0;
	for(w = ctlwidth(lflag, c); w > 0; w--){
		memmove(e+n, "\b \b", 3);
		n += 3;
	}
	return n;
}

typedef struct Seg Seg;
struct Seg
{
	int	off;
	int	len;
	int	line;	/* a canonical line, added without waiting */
};

/*
 * Takes up to Chunk bytes of master input through the discipline, under
 * p->lk: what the slave gets in d (as segments in sg), echo in e, and
 * signals in sigs. Returns how many segments.
 */
static int
discipline(Pty *p, uchar *a, int n, uchar *d, Seg *sg, uchar *e, int *ne, int *sigs, int *nsig)
{
	ulong iflag, lflag;
	int i, c, nd, ns, sig, raw0;

	iflag = flag(p, 0);
	lflag = flag(p, 12);
	nd = ns = 0;
	raw0 = -1;	/* where the raw segment being built starts in d */
	*ne = 0;
	*nsig = 0;
	for(i = 0; i < n; i++){
		c = a[i];
		if(iflag & ISTRIP)
			c &= 0x7f;
		if(c == '\r'){
			if(iflag & IGNCR)
				continue;
			if(iflag & ICRNL)
				c = '\n';
		}else if(c == '\n' && (iflag & INLCR))
			c = '\r';
		if(lflag & ISIG){
			sig = 0;
			if(iscc(p, c, VINTR))
				sig = SIGINT;
			else if(iscc(p, c, VQUIT))
				sig = SIGQUIT;
			else if(iscc(p, c, VSUSP))
				sig = SIGTSTP;
			if(sig != 0){
				if(!(lflag & NOFLSH)){
					qflush(p->in);
					p->nline = 0;
					/* Nothing written before it in this write reaches the slave either. */
					ns = 0;
					nd = 0;
					raw0 = -1;
				}
				if(lflag & ECHO)
					*ne += echo1(p, lflag, c, e + *ne);
				if(*nsig < Maxsig)
					sigs[(*nsig)++] = sig;
				continue;
			}
		}
		if(!(lflag & ICANON)){
			if(raw0 < 0){
				raw0 = nd;
				sg[ns].off = nd;
				sg[ns].len = 0;
				sg[ns].line = 0;
				ns++;
			}
			d[nd++] = c;
			sg[ns-1].len++;
			if(lflag & ECHO)
				*ne += echo1(p, lflag, c, e + *ne);
			continue;
		}
		if(iscc(p, c, VERASE)){
			*ne += erase1(p, lflag, e + *ne);
			continue;
		}
		if((lflag & IEXTEN) && iscc(p, c, VWERASE)){
			while(p->nline > 0 && (p->line[p->nline-1] == ' ' || p->line[p->nline-1] == '\t'))
				*ne += erase1(p, lflag, e + *ne);
			while(p->nline > 0 && p->line[p->nline-1] != ' ' && p->line[p->nline-1] != '\t')
				*ne += erase1(p, lflag, e + *ne);
			continue;
		}
		if(iscc(p, c, VKILL)){
			if((lflag & (ECHO|ECHOKE|ECHOE)) == (ECHO|ECHOKE|ECHOE)){
				while(p->nline > 0)
					*ne += erase1(p, lflag, e + *ne);
			}else{
				p->nline = 0;
				if(lflag & ECHO){
					*ne += echo1(p, lflag, c, e + *ne);
					if(lflag & ECHOK)
						*ne += opost(flag(p, 4), '\n', e + *ne);
				}
			}
			continue;
		}
		if(iscc(p, c, VEOF) || c == '\n' || iscc(p, c, VEOL) || ((lflag & IEXTEN) && iscc(p, c, VEOL2))){
			/* The line is done; VEOF itself isn't part of it. */
			if(!iscc(p, c, VEOF)){
				if(p->nline < Linemax)
					p->line[p->nline++] = c;
				if((lflag & ECHO) || (c == '\n' && (lflag & ECHONL)))
					*ne += echo1(p, lflag, c, e + *ne);
			}
			memmove(d+nd, p->line, p->nline);
			sg[ns].off = nd;
			sg[ns].len = p->nline;
			sg[ns].line = 1;
			ns++;
			nd += p->nline;
			p->nline = 0;
			raw0 = -1;
			continue;
		}
		/* An ordinary character: kept, with room left for the newline. */
		if(p->nline < Linemax-1){
			p->line[p->nline++] = c;
			if(lflag & ECHO)
				*ne += echo1(p, lflag, c, e + *ne);
		}
	}
	return ns;
}

static long
masterwrite(Pty *p, uchar *a, long n)
{
	uchar *d, *e;
	Seg *sg;
	int i, m, ns, ne, nsig, sigs[Maxsig];
	long done;
	ulong fg;

	/* d: the chunk and a line; e: echo, at most 6 bytes to erase each byte of the line and the chunk, and 3 to echo each of the chunk. */
	d = smalloc(Chunk + Linemax);
	e = smalloc(9*Chunk + 6*Linemax + 16);
	sg = smalloc((Chunk+1) * sizeof *sg);
	if(waserror()){
		free(d);
		free(e);
		free(sg);
		nexterror();
	}
	for(done = 0; done < n; done += m){
		m = n - done;
		if(m > Chunk)
			m = Chunk;
		lock(&p->lk);
		ns = discipline(p, a+done, m, d, sg, e, &ne, sigs, &nsig);
		fg = p->fg;
		unlock(&p->lk);
		if(ne > 0)
			qiwrite(p->out, e, ne);
		for(i = 0; i < ns; i++){
			if(sg[i].line)
				qiwrite(p->in, d+sg[i].off, sg[i].len);
			else if(sg[i].len > 0)
				qwrite(p->in, d+sg[i].off, sg[i].len);
		}
		for(i = 0; i < nsig; i++)
			if(fg != 0 && h9_ptysig != nil)
				h9_ptysig(fg, sigs[i]);
	}
	poperror();
	free(d);
	free(e);
	free(sg);
	return n;
}

static long
slavewrite(Pty *p, uchar *a, long n)
{
	uchar *b;
	ulong oflag;
	long i, m, done;
	int nb;

	lock(&p->lk);
	oflag = flag(p, 4);
	unlock(&p->lk);
	if(!(oflag & OPOST) || !(oflag & (ONLCR|OCRNL)))
		return qwrite(p->out, a, n);
	b = smalloc(2*Chunk);
	if(waserror()){
		free(b);
		nexterror();
	}
	for(done = 0; done < n; done += m){
		m = n - done;
		if(m > Chunk)
			m = Chunk;
		nb = 0;
		for(i = 0; i < m; i++)
			nb += opost(oflag, a[done+i], b+nb);
		qwrite(p->out, b, nb);
	}
	poperror();
	free(b);
	return n;
}

/* In canonical mode a read returns at most a line, the block it's in. */
static long
slaveread(Pty *p, uchar *va, long n)
{
	Block *b;
	int canon;

	lock(&p->lk);
	canon = (flag(p, 12) & ICANON) != 0;
	unlock(&p->lk);
	if(!canon)
		return qread(p->in, va, n);
	b = qbread(p->in, n);
	if(b == nil)
		return 0;
	n = BLEN(b);
	memmove(va, b->rp, n);
	freeb(b);
	return n;
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
	USED(sid);
	if(hup && h9_ptysig != nil)
		h9_ptysig(fg, SIGHUP);
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
		return slaveread(p, va, n);
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
		return masterwrite(p, va, n);
	case Qslave:
		p = chanpty(c);
		return slavewrite(p, va, n);
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
		if(what & Stermios){
			memmove(p->termios, s->termios, Termlen);
			/* Out of canonical mode, a line being edited is input to read. */
			if(!(flag(p, 12) & ICANON) && p->nline > 0){
				qiwrite(p->in, p->line, p->nline);
				p->nline = 0;
			}
		}
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
h9_pty_setsig(void (*f)(ulong, int))
{
	h9_ptysig = f;
}
