/*
 * #λ: the Linux view's root (design/0018-linux-personality.md, "The Linux
 * view"). Its root directory holds 9, tmp and mnt/term as mount points,
 * and it serves dev, proc and sys itself. The namespace builder binds the
 * Linux root tree after it, so the tree's own files show through, and
 * binds the 9front root, /tmp, /mnt/term, the console and #d onto its
 * mount points, and the machine's 9front /dev onto dev/9, so a Linux
 * program reaches the window's draw files (design/wine-draw.md).
 *
 * The tree is a fixed table; /proc adds a directory for each of the
 * machine's processes, with the same entries for each, and /proc/n/fd
 * lists the process's open fds. A qid path holds the table index in its
 * low byte, the fd above it and the pid above that; devices under /dev
 * also set Qchr, so stat reports them as character devices
 * (src/linux/sys.zig).
 *
 * Text files are made when they're opened, by h9_linux_gen (Zig) or
 * here, and read from that copy.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"

enum
{
	Lambda = 0x3BB,

	Qroot = 0,
	Q9, Qtmp, Qmnt, Qterm, Qtermcwd, Qdev, Qproc, Qsys,
	/* dev */
	Qnull, Qzero, Qfull, Qrandom, Qurandom, Qtty, Qconsole, Qfddir, Qstdin, Qstdout, Qstderr, Qpts, Qshm, Qdev9,
	/* proc */
	Qself, Qthreadself, Qcpuinfo, Qmeminfo, Qstat, Quptime, Qmounts, Qloadavg, Qversion, Qfilesystems,
	Qpsys, Qkernel, Qrandomdir, Quuid, Qbootid, Qvm, Qovercommit, Qosrelease, Qostype, Qhostname, Qpidmax,
	/* sys */
	Qdevices, Qsystem, Qcpu, Qonline, Qpossible,
	/* #λetc: an /etc to union after the root's */
	Qetc, Qresolv,
	/* /proc/n */
	Qpid, Qexe, Qcwd, Qmaps, Qpfd, Qpstat, Qstatus, Qstatm, Qcmdline, Qenviron, Qcomm, Qpmounts, Qtask,
	Qfdent,
	Nq,

	Qnone = 0xff,
	Qfirstpid = Qexe,	/* a /proc/n entry */

	FDSHIFT = 8,
	PIDSHIFT = 24,
};

#define Qchr	((uvlong)1<<40)
#define QFILE(p)	((int)((p) & 0xff))
#define QFD(p)	((int)(((p) >> FDSHIFT) & 0xffff))
#define QPID(p)	((ulong)(((p) >> PIDSHIFT) & 0xffff))

typedef struct Lent Lent;
struct Lent
{
	char	*name;
	int	parent;
	int	mode;	/* DMDIR|0555 or a file's mode */
	int	chr;	/* a character device */
};

static Lent tab[Nq] = {
	[Qroot]	{"#λ", Qroot, DMDIR|0555},
	[Q9]	{"9", Qroot, DMDIR|0555},
	[Qtmp]	{"tmp", Qroot, DMDIR|0777},
	[Qmnt]	{"mnt", Qroot, DMDIR|0555},
	[Qterm]	{"term", Qmnt, DMDIR|0555},
	[Qtermcwd]	{"cwd", Qterm, DMDIR|0555},
	[Qdev]	{"dev", Qroot, DMDIR|0555},
	[Qproc]	{"proc", Qroot, DMDIR|0555},
	[Qsys]	{"sys", Qroot, DMDIR|0555},

	[Qnull]	{"null", Qdev, 0666, 1},
	[Qzero]	{"zero", Qdev, 0666, 1},
	[Qfull]	{"full", Qdev, 0666, 1},
	[Qrandom]	{"random", Qdev, 0444, 1},
	[Qurandom]	{"urandom", Qdev, 0444, 1},
	[Qtty]	{"tty", Qdev, 0666, 1},
	[Qconsole]	{"console", Qdev, 0666, 1},
	[Qfddir]	{"fd", Qdev, DMDIR|0555},
	[Qstdin]	{"stdin", Qdev, 0666, 1},
	[Qstdout]	{"stdout", Qdev, 0666, 1},
	[Qstderr]	{"stderr", Qdev, 0666, 1},
	[Qpts]	{"pts", Qdev, DMDIR|0555},
	[Qshm]	{"shm", Qdev, DMDIR|0777},
	[Qdev9]	{"9", Qdev, DMDIR|0555},

	[Qself]	{"self", Qproc, DMDIR|0555},
	[Qthreadself]	{"thread-self", Qproc, DMDIR|0555},
	[Qcpuinfo]	{"cpuinfo", Qproc, 0444},
	[Qmeminfo]	{"meminfo", Qproc, 0444},
	[Qstat]	{"stat", Qproc, 0444},
	[Quptime]	{"uptime", Qproc, 0444},
	[Qmounts]	{"mounts", Qproc, 0444},
	[Qloadavg]	{"loadavg", Qproc, 0444},
	[Qversion]	{"version", Qproc, 0444},
	[Qfilesystems]	{"filesystems", Qproc, 0444},
	[Qpsys]	{"sys", Qproc, DMDIR|0555},
	[Qkernel]	{"kernel", Qpsys, DMDIR|0555},
	[Qrandomdir]	{"random", Qkernel, DMDIR|0555},
	[Quuid]	{"uuid", Qrandomdir, 0444},
	[Qbootid]	{"boot_id", Qrandomdir, 0444},
	[Qvm]	{"vm", Qpsys, DMDIR|0555},
	[Qovercommit]	{"overcommit_memory", Qvm, 0444},
	[Qosrelease]	{"osrelease", Qkernel, 0444},
	[Qostype]	{"ostype", Qkernel, 0444},
	[Qhostname]	{"hostname", Qkernel, 0444},
	[Qpidmax]	{"pid_max", Qkernel, 0444},

	[Qdevices]	{"devices", Qsys, DMDIR|0555},
	[Qsystem]	{"system", Qdevices, DMDIR|0555},
	[Qcpu]	{"cpu", Qsystem, DMDIR|0555},
	[Qonline]	{"online", Qcpu, 0444},
	[Qpossible]	{"possible", Qcpu, 0444},

	[Qetc]	{"etc", Qetc, DMDIR|0555},
	[Qresolv]	{"resolv.conf", Qetc, 0444},

	[Qpid]	{"", Qproc, DMDIR|0555},
	[Qexe]	{"exe", Qpid, 0777},
	[Qcwd]	{"cwd", Qpid, 0777},
	[Qmaps]	{"maps", Qpid, 0444},
	[Qpfd]	{"fd", Qpid, DMDIR|0500},
	[Qpstat]	{"stat", Qpid, 0444},
	[Qstatus]	{"status", Qpid, 0444},
	[Qstatm]	{"statm", Qpid, 0444},
	[Qcmdline]	{"cmdline", Qpid, 0444},
	[Qenviron]	{"environ", Qpid, 0400},
	[Qcomm]	{"comm", Qpid, 0444},
	[Qpmounts]	{"mounts", Qpid, 0444},
	[Qtask]	{"task", Qpid, DMDIR|0555},
	[Qfdent]	{"", Qpfd, 0777},
};

/*
 * Implemented in Zig (src/machine.zig): writes the text of file q into
 * buf, for the process whose Zig record is aux (nil for the machine-wide
 * files), and returns its length, or -1 if it has none.
 */
int	(*h9_linuxgen)(void *aux, char *name, ulong pid, char *buf, int n);

extern void	(*h9_procstatus)(void*, char*, int, ulong*);	/* proc.c */
extern void	(*h9_procthreads)(void*, ulong*, ulong*);	/* proc.c */

enum
{
	Npids = 1024,
	Ntext = 64*1024,
};

static Hmach*
upmach(void)
{
	return h9_uphproc()->mach;
}

static uvlong
mkpath(int q, ulong pid, int fd)
{
	uvlong p;

	p = q | ((uvlong)fd << FDSHIFT) | ((uvlong)pid << PIDSHIFT);
	if(tab[q].chr)
		p |= Qchr;
	return p;
}

static void
mkentry(Chan *c, int q, ulong pid, int fd, Dir *dp)
{
	Qid qid;
	char *name;
	int mode;

	mode = tab[q].mode;
	mkqid(&qid, mkpath(q, pid, fd), 0, (mode & DMDIR) ? QTDIR : QTFILE);
	name = tab[q].name;
	if(q == Qpid){
		snprint(up->genbuf, sizeof up->genbuf, "%lud", pid);
		name = up->genbuf;
	} else if(q == Qfdent){
		snprint(up->genbuf, sizeof up->genbuf, "%d", fd);
		name = up->genbuf;
	}
	devdir(c, qid, name, 0, eve, mode, dp);
	/*
	 * /proc and /sys files are length 0, as on Linux, but resolv.conf
	 * stands in for a regular file: c-ares (curl, so git over https)
	 * sizes it with lseek, reads nothing from a 0-length one, and falls
	 * back to a nameserver at 127.0.0.1.
	 */
	if(q == Qresolv && h9_linuxgen != nil){
		char *buf;
		int n;

		buf = smalloc(Ntext);
		n = h9_linuxgen(nil, name, 0, buf, Ntext);
		free(buf);
		if(n > 0)
			dp->length = n;
	}
	if(tab[q].chr)
		dp->qid.path |= Qchr;
}

/* Whether pid is a process of the caller's machine. */
static int
pidok(ulong pid)
{
	Hproc *h;

	h = h9_pidlookup(upmach(), pid);
	if(h == nil)
		return 0;
	h9_putproc(h);
	return 1;
}

/* The fds open in process pid, into fds (up to n); returns how many. */
static int
pidfds(ulong pid, int *fds, int n)
{
	Hproc *h;
	Fgrp *f;
	int i, count;

	h = h9_pidlookup(upmach(), pid);
	if(h == nil)
		return 0;
	count = 0;
	qlock(&h->debug);
	if(h->p != nil && (f = h->p->fgrp) != nil){
		lock(&f->ref.lk);
		for(i = 0; i <= f->maxfd; i++)
			if(f->fd[i] != nil && count < n)
				fds[count++] = i;
		unlock(&f->ref.lk);
	}
	qunlock(&h->debug);
	h9_putproc(h);
	return count;
}

/* The thread group of pid: its own pid unless it's a Linux thread. */
static ulong
tgidof(ulong pid)
{
	ulong tgid, nthr;
	Hproc *h;

	tgid = pid;
	h = h9_pidlookup(upmach(), pid);
	if(h != nil){
		if(h->aux != nil && h9_procthreads != nil)
			h9_procthreads(h->aux, &tgid, &nthr);
		h9_putproc(h);
	}
	return tgid;
}

/*
 * The pids of thread group tg, or with tg 0 the pids /proc lists: as on
 * Linux, each group's leader and not its other threads, which are still
 * there by name and in the leader's task directory (htop and btop would
 * show each thread as a process).
 */
static int
procpids(ulong tg, ulong *pids, int n)
{
	int i, m;
	ulong tgid;

	n = h9_pids(upmach(), pids, n);
	for(i = m = 0; i < n; i++){
		tgid = tgidof(pids[i]);
		if(tg == 0 ? tgid == pids[i] : tgid == tg)
			pids[m++] = pids[i];
	}
	return m;
}

static int
linuxgen(Chan *c, char *name, Dirtab *dt, int ntab, int s, Dir *dp)
{
	int q, i, n, fds[256];
	ulong pid, pids[Npids];
	char *end;

	USED(dt, ntab);
	q = QFILE(c->qid.path);
	pid = QPID(c->qid.path);
	if(q >= Nq)
		return -1;
	if(s == DEVDOTDOT){
		if(q == Qpid)
			mkentry(c, Qproc, 0, 0, dp);
		else if(q == Qpfd || q == Qtask)
			mkentry(c, Qpid, pid, 0, dp);
		else
			mkentry(c, tab[q].parent, 0, 0, dp);
		return 1;
	}
	if(q == Qpid){
		for(i = Qfirstpid; i < Qfdent; i++){
			if(name != nil ? strcmp(tab[i].name, name) == 0 : s-- == 0){
				mkentry(c, i, pid, 0, dp);
				return 1;
			}
		}
		return -1;
	}
	if(q == Qpfd){
		if(name != nil){
			i = strtoul(name, &end, 10);
			if(*end != 0 || name[0] == 0)
				return -1;
			n = pidfds(pid, fds, nelem(fds));
			while(n-- > 0)
				if(fds[n] == i){
					mkentry(c, Qfdent, pid, i, dp);
					return 1;
				}
			return -1;
		}
		n = pidfds(pid, fds, nelem(fds));
		if(s >= n)
			return -1;
		mkentry(c, Qfdent, pid, fds[s], dp);
		return 1;
	}
	if(q == Qtask){
		/* task/n is /proc/n, for each thread n of the group. */
		if(name != nil){
			n = strtoul(name, &end, 10);
			if(*end != 0 || name[0] == 0 || !pidok(n) || tgidof(n) != pid)
				return -1;
			mkentry(c, Qpid, n, 0, dp);
			return 1;
		}
		n = procpids(pid, pids, nelem(pids));
		if(s >= n)
			return -1;
		mkentry(c, Qpid, pids[s], 0, dp);
		return 1;
	}
	if(q == Qproc && name != nil){
		/* self and thread-self are the caller's own directory. */
		if(strcmp(name, "self") == 0 || strcmp(name, "thread-self") == 0){
			pid = h9_uphproc()->pid;
			mkentry(c, Qpid, pid, 0, dp);
			strecpy(up->genbuf, up->genbuf+sizeof up->genbuf, name);
			dp->name = up->genbuf;
			return 1;
		}
		pid = strtoul(name, &end, 10);
		if(*end == 0 && name[0] != 0){
			if(!pidok(pid))
				return -1;
			mkentry(c, Qpid, pid, 0, dp);
			return strcmp(dp->name, name) == 0 ? 1 : -1;
		}
	}
	for(i = 1; i < Qpid; i++){
		if(tab[i].parent != q || i == q)
			continue;
		if(name != nil ? strcmp(tab[i].name, name) == 0 : s-- == 0){
			mkentry(c, i, 0, 0, dp);
			return 1;
		}
	}
	if(q == Qproc && name == nil){
		n = procpids(0, pids, nelem(pids));
		if(s >= n)
			return -1;
		mkentry(c, Qpid, pids[s], 0, dp);
		return 1;
	}
	return -1;
}

/*
 * #λ is the Linux view's top; #λetc is a directory of files the
 * machine makes for a root that lacks them, bound after the root's /etc
 * (design/0050-linux-net.md, "DNS").
 */
static Chan*
linuxattach(char *spec)
{
	Chan *c;

	if(strcmp(spec, "etc") == 0){
		c = devattach(Lambda, spec);
		mkqid(&c->qid, mkpath(Qetc, 0, 0), 0, QTDIR);
		return c;
	}
	if(*spec != 0)
		error(Ebadspec);
	return devattach(Lambda, spec);
}

static Walkqid*
linuxwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, linuxgen);
}

static int
linuxstat(Chan *c, uchar *db, int n)
{
	Dir d;
	int q;

	q = QFILE(c->qid.path);
	if(q >= Nq)
		error(Enonexist);
	mkentry(c, q, QPID(c->qid.path), QFD(c->qid.path), &d);
	n = convD2M(&d, db, n);
	if(n == 0)
		error(Ebadarg);
	return n;
}

/* A file's text, made at open. */
typedef struct Text Text;
struct Text
{
	int	n;
	char	buf[1];
};

static int
cmdline(ulong pid, char *buf, int n, int comm)
{
	Hproc *h;
	int len, i;

	h = h9_pidlookup(upmach(), pid);
	if(h == nil)
		error(Eprocdied);
	if(comm){
		len = snprint(buf, n, "%s\n", h->text);
	} else {
		lock(&h->alk);
		len = h->nargs;
		if(len > n)
			len = n;
		memmove(buf, h->args, len);
		unlock(&h->alk);
		if(len == 0)
			len = snprint(buf, n, "%s", h->text) + 1;
		for(i = 0; i < len; i++)
			if(buf[i] == ' ' && h->setargs)
				buf[i] = 0;
	}
	h9_putproc(h);
	return len;
}

static int
pstat(ulong pid, char *buf, int n, int status)	/* status: 0 stat, 1 status, 2 statm */
{
	Hproc *h;
	ulong ppid, mem, tgid, nthr;
	char state[64];
	char *st;

	h = h9_pidlookup(upmach(), pid);
	if(h == nil)
		error(Eprocdied);
	ppid = h->ppid;
	mem = 0;
	state[0] = 0;
	tgid = pid;
	nthr = 1;
	if(h->aux != nil && h9_procstatus != nil)
		h9_procstatus(h->aux, state, sizeof state, &mem);
	if(h->aux != nil && h9_procthreads != nil)
		h9_procthreads(h->aux, &tgid, &nthr);
	st = strcmp(state, "Running") == 0 ? "R" : "S";
	if(status == 2)
		/* Pages: size resident shared text lib data dt. htop drops a
		 * process whose statm it can't read. */
		n = snprint(buf, n, "%lud %lud 0 0 0 %lud 0\n", mem/4, mem/4, mem/4);
	else if(status)
		n = snprint(buf, n,
			"Name:\t%s\nUmask:\t0022\nState:\t%s (%s)\nTgid:\t%lud\nNgid:\t0\nPid:\t%lud\nPPid:\t%lud\n"
			"TracerPid:\t0\nUid:\t0\t0\t0\t0\nGid:\t0\t0\t0\t0\nFDSize:\t64\nGroups:\t\n"
			"VmPeak:\t%8lud kB\nVmSize:\t%8lud kB\nVmRSS:\t%8lud kB\nThreads:\t%lud\n"
			"SigQ:\t0/0\nSigPnd:\t0000000000000000\nShdPnd:\t0000000000000000\n"
			"Cpus_allowed_list:\t0\n",
			h->text, st, st[0] == 'R' ? "running" : "sleeping", tgid, pid, ppid, mem, mem, mem, nthr);
	else
		/* All 52 fields: procps and busybox read past rss. */
		n = snprint(buf, n, "%lud (%s) %s %lud %lud %lud 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 %lud 0 %lud %lud %lud"
			" 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n",
			pid, h->text, st, ppid, pid, pid, nthr, h->start, mem*1024, mem/4);
	h9_putproc(h);
	return n;
}

static Chan*
linuxopen(Chan *c, int omode)
{
	int q, n;
	ulong pid;
	Text *t;
	Hproc *h;
	void *aux;

	q = QFILE(c->qid.path);
	pid = QPID(c->qid.path);
	if(q >= Nq)
		error(Enonexist);
	if((c->qid.type & QTDIR) && (omode & 3) != OREAD)
		error(Eisdir);
	if((omode & 3) != OREAD && !(tab[q].mode & 0222))
		error(Eperm);
	if(q == Qpid || q == Qpfd || q == Qtask)
		if(!pidok(pid))
			error(Eprocdied);
	c->aux = nil;
	if(!(c->qid.type & QTDIR) && !tab[q].chr && q != Qexe && q != Qcwd && q != Qfdent){
		t = smalloc(sizeof(Text) + Ntext);
		if(waserror()){
			free(t);
			nexterror();
		}
		n = -1;
		switch(q){
		case Qcmdline:
			n = cmdline(pid, t->buf, Ntext, 0);
			break;
		case Qcomm:
			n = cmdline(pid, t->buf, Ntext, 1);
			break;
		case Qpstat:
			n = pstat(pid, t->buf, Ntext, 0);
			break;
		case Qstatus:
			n = pstat(pid, t->buf, Ntext, 1);
			break;
		case Qstatm:
			n = pstat(pid, t->buf, Ntext, 2);
			break;
		case Qovercommit:
			n = snprint(t->buf, Ntext, "0\n");
			break;
		case Qostype:
			n = snprint(t->buf, Ntext, "Linux\n");
			break;
		case Qpidmax:
			n = snprint(t->buf, Ntext, "32768\n");
			break;
		default:
			aux = nil;
			if(q >= Qfirstpid){
				h = h9_pidlookup(upmach(), pid);
				if(h == nil)
					error(Eprocdied);
				/* aux is the Zig process only under nlk (h9_kern_setaux). */
				lock(&h->nlk);
				aux = h->aux;
				if(h9_linuxgen != nil && aux != nil)
					n = h9_linuxgen(aux, tab[q].name, pid, t->buf, Ntext);
				unlock(&h->nlk);
				h9_putproc(h);
			} else if(h9_linuxgen != nil)
				n = h9_linuxgen(nil, tab[q].name, pid, t->buf, Ntext);
			break;
		}
		poperror();
		if(n < 0)
			n = 0;
		t->n = n;
		c->aux = t;
	}
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
linuxclose(Chan *c)
{
	if((c->flag & COPEN) && c->aux != nil){
		free(c->aux);
		c->aux = nil;
	}
}

static long
linuxread(Chan *c, void *va, long n, vlong off)
{
	Text *t;
	int q;

	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, nil, 0, linuxgen);
	q = QFILE(c->qid.path);
	switch(q){
	case Qnull:
		return 0;
	case Qfull:
	case Qzero:
		memset(va, 0, n);
		return n;
	case Qrandom:
	case Qurandom:
		return randomread(va, n);
	}
	t = c->aux;
	if(t == nil || off < 0)
		return 0;
	if(off >= t->n)
		return 0;
	if(n > t->n - off)
		n = t->n - off;
	memmove(va, t->buf + off, n);
	return n;
}

static long
linuxwrite(Chan *c, void *va, long n, vlong off)
{
	USED(va, off);
	switch(QFILE(c->qid.path)){
	case Qnull:
	case Qzero:
	case Qrandom:
	case Qurandom:
		return n;
	case Qfull:
		error("no space left on device");
	}
	error(Eperm);
	return 0;
}

static void
linuxremove(Chan *c)
{
	USED(c);
	error(Eperm);
}

static int
linuxwstat(Chan *c, uchar *db, int n)
{
	USED(c, db, n);
	error(Eperm);
	return 0;
}

Dev linuxdevtab = {
	Lambda,
	"linux",

	devreset,
	devinit,
	devshutdown,
	linuxattach,
	linuxwalk,
	linuxstat,
	linuxopen,
	devcreate,
	linuxclose,
	linuxread,
	devbread,
	linuxwrite,
	devbwrite,
	linuxremove,
	linuxwstat,
};

void
h9_linux_setgen(int (*f)(void*, char*, ulong, char*, int))
{
	h9_linuxgen = f;
}
