/*
 * #p: /proc. Ported from 9front's port/devproc.c at the pinned release
 * (NINEFRONT_REV), serving h9's process records (proc.c, hproc.h)
 * instead of 9front's Proc table. See DESIGN.md, "Process model".
 *
 * A machine sees only its own processes: the directory lists and walks
 * the caller's machine, by machine-local pid, and the pid in a qid is
 * looked up in the caller's machine on every open, read and write.
 *
 * Served: args, ctl (kill, hang, nohang, close, closefiles), fd, note,
 * noteid, notepg, ns, ppid, status and wait. mem, regs, fpregs, segment
 * and text (acid) wait for design/self-host.md; kregs, kfpregs, proc, profile, syscall,
 * trace and watchpt have no meaning here. The CPU times in status are 0.
 *
 * The record's debug QLock stands in for 9front's p->debug: the process
 * takes it to swap its groups (rfork, chdir) and to mark itself gone at
 * exit, so a reader that holds it can take references to the groups.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"

enum
{
	Qdir,
	Qargs,
	Qctl,
	Qfd,
	Qnote,
	Qnoteid,
	Qnotepg,
	Qns,
	Qppid,
	Qstatus,
	Qwait,
};

enum
{
	CMclose,
	CMclosefiles,
	CMhang,
	CMkill,
	CMnohang,
};

enum
{
	QSHIFT	= 5,		/* the file's Q in the low bits, the pid above */
	Procmode = 0640,	/* 9front's default p->procmode */
	Npids	= 1024,		/* processes listed in /proc */
	PriNormal = 10,
};

#define	QID(q)		((ulong)(q).path & ((1<<QSHIFT)-1))
#define	PIDQ(q)		((ulong)((q).path >> QSHIFT))

Dirtab procdir[] =
{
	"args",		{Qargs},	0,			0660,
	"ctl",		{Qctl},		0,			0000,
	"fd",		{Qfd},		0,			0444,
	"note",		{Qnote},	0,			0000,
	"noteid",	{Qnoteid},	0,			0664,
	"notepg",	{Qnotepg},	0,			0000,
	"ns",		{Qns},		0,			0444,
	"ppid",		{Qppid},	0,			0444,
	"status",	{Qstatus},	0,			0444,
	"wait",		{Qwait},	0,			0400,
};

static
Cmdtab proccmd[] = {
	CMclose,		"close",		2,
	CMclosefiles,		"closefiles",		1,
	CMhang,			"hang",			1,
	CMkill,			"kill",			1,
	CMnohang,		"nohang",		1,
};

extern int procfdprint(Chan*, int, int, char*, int);

static Hmach*
upmach(void)
{
	return h9_uphproc()->mach;
}

/* The process the chan names, in the caller's machine, with a reference. */
static Hproc*
chanproc(Chan *c)
{
	Hproc *h;

	h = h9_pidlookup(upmach(), PIDQ(c->qid));
	if(h == nil)
		error(Eprocdied);
	return h;
}

static int
procgen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Qid qid;
	Hproc *h;
	Dirtab *t;
	ulong pid, perm, pids[Npids];
	char *ename;
	int n;

	USED(tab, ntab);
	if(s == DEVDOTDOT){
		mkqid(&qid, Qdir, 0, QTDIR);
		devdir(c, qid, "#p", 0, eve, 0555, dp);
		return 1;
	}

	if(c->qid.path == Qdir){
		if(name != nil){
			/* ignore s and use name to find pid */
			pid = strtoul(name, &ename, 10);
			if(pid == 0 || ename[0] != '\0')
				return -1;
		} else {
			n = h9_pids(upmach(), pids, nelem(pids));
			if(s >= n)
				return -1;
			pid = pids[s];
		}
		h = h9_pidlookup(upmach(), pid);
		if(h == nil)
			return name != nil ? -1 : 0;
		h9_putproc(h);
		/* String comparison is done in devwalk so name must match its formatted pid. */
		snprint(up->genbuf, sizeof up->genbuf, "%lud", pid);
		if(name != nil && strcmp(name, up->genbuf) != 0)
			return -1;
		mkqid(&qid, pid<<QSHIFT, pid, QTDIR);
		devdir(c, qid, up->genbuf, 0, eve, 0555, dp);
		return 1;
	}

	if(s >= nelem(procdir))
		return -1;
	t = &procdir[s];
	pid = PIDQ(c->qid);
	h = h9_pidlookup(upmach(), pid);
	if(h == nil)
		return -1;
	perm = t->perm;
	if(perm == 0)
		perm = Procmode;
	else	/* just copy read bits */
		perm |= Procmode & 0444;
	n = 0;
	if(t->qid.path == Qwait)
		n = h->nwait;	/* incorrect size, but >0 means there's something to read */
	h9_putproc(h);
	mkqid(&qid, (pid<<QSHIFT)|t->qid.path, c->qid.vers, QTFILE);
	devdir(c, qid, t->name, n, eve, perm, dp);
	return 1;
}

static Chan*
procattach(char *spec)
{
	return devattach('p', spec);
}

static Walkqid*
procwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, 0, 0, procgen);
}

static int
procstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, 0, 0, procgen);
}

static Chan*
procopen(Chan *c, int omode0)
{
	Hproc *h;
	Chan *tc;
	ulong vers;
	int omode;

	if(c->qid.type & QTDIR)
		return devopen(c, omode0, 0, 0, procgen);

	h = chanproc(c);
	if(waserror()){
		h9_putproc(h);
		nexterror();
	}
	omode = openmode(omode0);
	vers = h->pid;
	switch(QID(c->qid)){
	case Qstatus:
	case Qppid:
	case Qns:
	case Qfd:
		if(omode != OREAD)
			error(Eperm);
		break;

	case Qctl:
	case Qargs:
	case Qwait:
	case Qnoteid:
	case Qnote:
		break;

	case Qnotepg:
		if(omode != OWRITE)
			error(Eperm);
		/* Remember the group, as 9front does: writes go to it. */
		vers = h->noteid;
		break;

	default:
		error(Egreg);
	}
	if(vers == 0)
		error(Eprocdied);
	c->qid.vers = vers;
	tc = devopen(c, omode, 0, 0, procgen);
	poperror();
	h9_putproc(h);
	return tc;
}

static void
procclose(Chan *c)
{
	USED(c);
}

static int
procargs(Hproc *h, char *buf, int nbuf)
{
	int j, k, m, n;
	char *a;

	lock(&h->alk);
	if(h->setargs){
		j = snprint(buf, nbuf, "%s [%s]", h->text, h->args);
		unlock(&h->alk);
		return j;
	}
	a = h->args;
	n = h->nargs;
	for(j = 0; j < nbuf - 1; j += m){
		if(n <= 0)
			break;
		if(j != 0)
			buf[j++] = ' ';
		m = snprint(buf+j, nbuf-j, "%q", a);
		k = strlen(a) + 1;
		a += k;
		n -= k;
	}
	unlock(&h->alk);
	return j;
}

static void
int2flag(int flag, char *s)
{
	if(flag == 0){
		*s = '\0';
		return;
	}
	*s++ = '-';
	if(flag & MAFTER)
		*s++ = 'a';
	if(flag & MBEFORE)
		*s++ = 'b';
	if(flag & MCREATE)
		*s++ = 'c';
	if(flag & MCACHE)
		*s++ = 'C';
	*s = '\0';
}

/*
 * The target's groups and dot, with references, taken under its debug
 * lock so it can't swap or drop them meanwhile. Raises Eprocdied if it
 * has gone.
 */
typedef struct Groups Groups;
struct Groups
{
	Pgrp	*pg;
	Fgrp	*fg;
	Chan	*dot;
};

static void
takegroups(Hproc *h, Groups *g)
{
	Proc *p;

	memset(g, 0, sizeof *g);
	qlock(&h->debug);
	p = h->p;
	if(p == nil || p->dot == nil){
		qunlock(&h->debug);
		error(Eprocdied);
	}
	g->dot = p->dot;
	incref(&g->dot->ref);
	if((g->pg = p->pgrp) != nil)
		incref(&g->pg->ref);
	if((g->fg = p->fgrp) != nil)
		incref(&g->fg->ref);
	qunlock(&h->debug);
}

static void
dropgroups(Groups *g)
{
	if(g->pg != nil)
		closepgrp(g->pg);
	if(g->fg != nil)
		h9_fgrpclose(g->fg);
	if(g->dot != nil)
		cclose(g->dot);
}

static int
readns1(Chan *c, Groups *g, char *buf, int nbuf)
{
	Pgrp *pg;
	Mount *f;
	char flag[10];
	int i;

	pg = g->pg;
	if(pg == nil)
		error(Eprocdied);
	if(c->nrock < 0)
		return 0;

	rlock(&pg->ns);
	i = 0;
	for(f = pg->mntorder; f != nil; f = f->order)
		if(i++ >= c->nrock)
			break;
	if(f == nil){
		c->nrock = -1;
		i = snprint(buf, nbuf, "cd %q\n", chanpath(g->dot));
	} else {
		c->nrock = i;
		int2flag(f->mflag, flag);
		if(strcmp(chanpath(f->to), "#M") == 0)
			i = snprint(buf, nbuf, *f->spec?
				"mount %s %q %q %q\n": "mount %s %q %q\n", flag,
				chanpath(f->to->mchan), chanpath(f->umh->from), f->spec);
		else
			i = snprint(buf, nbuf, "bind %s %q %q\n", flag,
				chanpath(f->to), chanpath(f->umh->from));
	}
	runlock(&pg->ns);
	return i;
}

static int
readfd1(Chan *c, Groups *g, char *buf, int nbuf)
{
	Fgrp *fg;
	int n, i;

	fg = g->fg;
	if(fg == nil)
		return 0;
	if(c->nrock == 0){
		c->nrock = 1;
		return snprint(buf, nbuf, "%s\n", chanpath(g->dot));
	}
	lock(&fg->ref.lk);
	n = 0;
	for(;;){
		i = c->nrock-1;
		if(i < 0 || i > fg->maxfd)
			break;
		c->nrock++;
		if(fg->fd[i] != nil){
			n = procfdprint(fg->fd[i], i, 0, buf, nbuf);
			break;
		}
	}
	unlock(&fg->ref.lk);
	return n;
}

static int
prochaswaitq(void *x)
{
	Hproc *h;

	h = x;
	return h->p == nil || h->waitq != nil;
}

static long
statusread(Hproc *h, char *buf, int nbuf)
{
	char state[KNAMELEN];
	ulong mem;

	strcpy(state, "New");
	mem = 0;
	lock(&h->nlk);
	if(h->p == nil)
		strcpy(state, "Moribund");
	else if(h->aux != nil && h9_procstatus != nil)
		h9_procstatus(h->aux, state, sizeof state, &mem);
	unlock(&h->nlk);
	return snprint(buf, nbuf,
		"%-27s %-27s %-11s "
		"%11lud %11lud %11lud "
		"%11lud %11lud %11lud "
		"%11lud %11lud %11lud\n",
		h->text, eve, state,
		0UL, 0UL, (ulong)(ticks() - h->start),
		0UL, 0UL, 0UL,
		mem, (ulong)PriNormal, (ulong)PriNormal);
}

static long
procread(Chan *c, void *va, long n, vlong off)
{
	char statbuf[1024];
	ulong offset;
	int i, j;
	Hproc *h;
	Hwait *w;
	Groups g;

	offset = off;
	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, 0, 0, procgen);

	h = chanproc(c);
	if(waserror()){
		h9_putproc(h);
		nexterror();
	}

	switch(QID(c->qid)){
	case Qctl:
		n = readnum(offset, va, n, h->pid, NUMSIZE);
		break;

	case Qnoteid:
		n = readnum(offset, va, n, h->noteid, NUMSIZE);
		break;

	case Qppid:
		n = readnum(offset, va, n, h->ppid, NUMSIZE);
		break;

	case Qstatus:
		j = statusread(h, statbuf, sizeof statbuf);
		goto statbufread;

	case Qargs:
		j = procargs(h, statbuf, sizeof statbuf);
		goto statbufread;

	case Qwait:
		if(!canqlock(&h->qwaitr))
			error(Einuse);
		if(waserror()){
			qunlock(&h->qwaitr);
			nexterror();
		}
		lock(&h->exl);
		while(h->waitq == nil && h->p != nil){
			if(h->p == up && h->nchild == 0){
				unlock(&h->exl);
				error(Enochild);
			}
			unlock(&h->exl);
			sleep(&h->waitr, prochaswaitq, h);
			lock(&h->exl);
		}
		if(h->waitq == nil){
			unlock(&h->exl);
			error(Eprocdied);
		}
		w = h->waitq;
		h->waitq = w->next;
		h->nwait--;
		unlock(&h->exl);
		qunlock(&h->qwaitr);
		poperror();
		j = snprint(statbuf, sizeof statbuf, "%lud %lud %lud %lud %q",
			w->pid, w->time[0], w->time[1], w->time[2], w->msg);
		free(w);
		offset = 0;
		goto statbufread;

	case Qns:
	case Qfd:
		takegroups(h, &g);
		if(waserror()){
			dropgroups(&g);
			nexterror();
		}
		if(offset == 0 || offset != c->mrock)
			c->nrock = c->mrock = 0;
		j = 0;
		do {
			if(QID(c->qid) == Qns)
				j = readns1(c, &g, statbuf, sizeof statbuf);
			else
				j = readfd1(c, &g, statbuf, sizeof statbuf);
			if(j == 0)
				break;
			c->mrock += j;
		} while(c->mrock <= offset);
		poperror();
		dropgroups(&g);
		i = c->mrock - offset;
		if(i <= 0 || i > j){
			n = 0;
			break;
		}
		if(i < n)
			n = i;
		offset = j - i;
		goto statbufread;

	case Qnote:
		if(n < 1)	/* must accept at least the '\0' */
			error(Etoosmall);
		lock(&h->nlk);
		if(h->nnote == 0)
			n = 0;
		else {
			i = strlen(h->note[0]->msg) + 1;
			if(i < n)
				n = i;
			memmove(va, h->note[0]->msg, n-1);
			((char*)va)[n-1] = '\0';
			h9_freenote(h->note[0]);
			if(--h->nnote > 0)
				memmove(&h->note[0], &h->note[1], h->nnote*sizeof(Hnote*));
			h->note[h->nnote] = nil;
		}
		unlock(&h->nlk);
		break;

	default:
		error(Egreg);
	statbufread:
		if(offset >= j)
			n = 0;
		else {
			if(offset+n > j)
				n = j - offset;
			memmove(va, statbuf+offset, n);
		}
		break;
	}
	poperror();
	h9_putproc(h);
	return n;
}

static void
procctlclosefiles(Hproc *h, int all, int fd)
{
	Groups g;
	Fgrp *f;
	Chan *c;

	if(fd < 0)
		error(Ebadfd);
	takegroups(h, &g);
	f = g.fg;
	if(f == nil){
		dropgroups(&g);
		error(Eprocdied);
	}
	lock(&f->ref.lk);
	while(fd <= f->maxfd){
		c = f->fd[fd];
		if(c != nil){
			f->fd[fd] = nil;
			unlock(&f->ref.lk);
			cclose(c);
			lock(&f->ref.lk);
		}
		if(!all)
			break;
		fd++;
	}
	unlock(&f->ref.lk);
	dropgroups(&g);
}

static void
procctlreq(Hproc *h, char *va, int n)
{
	Cmdbuf *cb;
	Cmdtab *ct;

	cb = parsecmd(va, n);
	if(waserror()){
		free(cb);
		nexterror();
	}
	ct = lookupcmd(cb, proccmd, nelem(proccmd));
	switch(ct->index){
	case CMclose:
		procctlclosefiles(h, 0, atoi(cb->f[1]));
		break;
	case CMclosefiles:
		procctlclosefiles(h, 1, 0);
		break;
	case CMhang:
		h->hang = 1;
		break;
	case CMkill:
		h9_killproc(h);
		break;
	case CMnohang:
		h->hang = 0;
		break;
	default:
		error(Ebadctl);
	}
	poperror();
	free(cb);
}

static long
procwrite(Chan *c, void *va, long n, vlong off)
{
	char buf[ERRMAX];
	ulong offset;
	Hproc *h;
	Hnote *nt;

	offset = off;
	if(c->qid.type & QTDIR)
		error(Eisdir);

	/* use the remembered noteid in the channel qid */
	if(QID(c->qid) == Qnotepg){
		if(n >= sizeof buf)
			error(Etoobig);
		memmove(buf, va, n);
		buf[n] = 0;
		h9_postnotepg(upmach(), c->qid.vers, buf, NUser);
		return n;
	}

	h = chanproc(c);
	if(waserror()){
		h9_putproc(h);
		nexterror();
	}
	switch(QID(c->qid)){
	case Qargs:
		if(offset != 0 || n >= sizeof buf || n >= ARGSLEN)
			error(Etoobig);
		lock(&h->alk);
		memmove(h->args, va, n);
		h->args[n] = 0;
		h->nargs = 0;
		h->setargs = 1;
		unlock(&h->alk);
		break;

	case Qctl:
		procctlreq(h, va, n);
		break;

	case Qnote:
		if(n >= sizeof buf)
			error(Etoobig);
		memmove(buf, va, n);
		buf[n] = 0;
		if((nt = h9_mknote(buf, NUser)) == nil)
			error(Enomem);
		if(!h9_pushnote(h, nt))
			error("note not posted");
		break;

	case Qnoteid:
		if(offset != 0 || n >= sizeof buf)
			error(Etoobig);
		memmove(buf, va, n);
		buf[n] = 0;
		if(atoi(buf) <= 0)
			error(Ebadarg);
		if(h9_setnoteid(h, atoi(buf)) < 0)
			error(Eperm);
		break;

	default:
		error(Egreg);
	}
	poperror();
	h9_putproc(h);
	return n;
}

Dev procdevtab = {
	'p',
	"proc",

	devreset,
	devinit,
	devshutdown,
	procattach,
	procwalk,
	procstat,
	procopen,
	devcreate,
	procclose,
	procread,
	devbread,
	procwrite,
	devbwrite,
	devremove,
	devwstat,
};
