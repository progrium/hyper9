/*
 * #y: a machine's console. drawterm's #c/cons reads and writes the host
 * process's fds 0 and 1; this device serves each machine's Stdio instead,
 * through leaf calls into Zig (SPEC.md, seam rule 3). The namespace
 * builder binds it over /dev, so /dev/cons is this device and the rest of
 * #c stays visible.
 *
 * The attach spec names the machine: #y<id>. The leaves never raise kernel
 * errors; they return -1 and this file raises the error.
 *
 * A read never blocks in a host call: a reader thread in Zig
 * (src/consin.zig) reads the host stream, and the guest sleeps here until
 * it has input, so a note or a teardown interrupts the read with Eintr.
 * Processes in a tree share the console, so readers take turns. A QLock
 * can't be interrupted and a Rendez holds only one sleeper, so a reader
 * waiting for its turn sleeps in short slices and checks for a note.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

/* Implemented in Zig (src/kern.zig). */
extern long h9_cons_read(ulong machine, void *buf, long n);
extern int h9_cons_ready(ulong machine);
extern long h9_cons_write(ulong machine, int fd, void *buf, long n);
extern void h9_cons_raw(ulong machine, int on);
extern void h9_cons_echo(ulong machine, int on);

enum {
	Maxcons	= 64,	/* src/kern.zig's max_consoles */
	Wouldblock = -2,
};

typedef struct Hcons Hcons;
struct Hcons
{
	Lock	lk;
	int	busy;	/* a reader has its turn */
	int	nctl;	/* open consctl files; the last close turns raw off */
	Rendez	r;	/* the reader with the turn, waiting for input */
};

static Hcons hcons[Maxcons];

static int
ready(void *a)
{
	return h9_cons_ready((ulong)((Hcons*)a - hcons));
}

/* Called by the reader thread (not a Proc) when input arrives. */
extern void h9_pollwake(void);

void
h9_cons_wake(ulong id)
{
	if(id < Maxcons)
		wakeup(&hcons[id].r);
	h9_pollwake();	/* a Linux poll or epoll on the console (linuxnet.c) */
}

static void
taketurn(Hcons *h)
{
	for(;;){
		lock(&h->lk);
		if(!h->busy){
			h->busy = 1;
			unlock(&h->lk);
			return;
		}
		unlock(&h->lk);
		if(up->notepending){
			up->notepending = 0;
			error(Eintr);
		}
		osmsleep(5);
	}
}

static void
giveturn(Hcons *h)
{
	lock(&h->lk);
	h->busy = 0;
	unlock(&h->lk);
}

static long
consread(ulong id, void *va, long n)
{
	Hcons *h;
	long r;

	if(id >= Maxcons)
		error(Eio);
	h = &hcons[id];
	taketurn(h);
	if(waserror()){
		giveturn(h);
		nexterror();
	}
	while((r = h9_cons_read(id, va, n)) == Wouldblock)
		sleep(&h->r, ready, h);
	poperror();
	giveturn(h);
	if(r < 0)
		error(Eio);
	return r;
}

enum {
	Qdir,
	Qcons,
	Qconsctl,
	Qstderr,	/* h9 extension: writes go to the host stderr */
};

static Dirtab hconsdir[] = {
	".",		{Qdir, 0, QTDIR},	0,	DMDIR|0555,
	"cons",		{Qcons},		0,	0660,
	"consctl",	{Qconsctl},		0,	0220,
	"stderr",	{Qstderr},		0,	0220,
};

static Chan*
hconsattach(char *spec)
{
	Chan *c;
	char *e;
	ulong id;

	id = strtoul(spec, &e, 10);
	if(*spec == 0 || *e != 0)
		error(Ebadspec);
	c = devattach('y', spec);
	c->dev = id;
	return c;
}

static Walkqid*
hconswalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, hconsdir, nelem(hconsdir), devgen);
}

static int
hconsstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, hconsdir, nelem(hconsdir), devgen);
}

static Chan*
hconsopen(Chan *c, int omode)
{
	Hcons *h;

	c = devopen(c, omode, hconsdir, nelem(hconsdir), devgen);
	if((ulong)c->qid.path == Qconsctl && c->dev < Maxcons){
		h = &hcons[c->dev];
		lock(&h->lk);
		h->nctl++;
		unlock(&h->lk);
	}
	return c;
}

/* As drawterm's and 9front's: the last close of consctl turns raw off, and echo back on. */
static void
hconsclose(Chan *c)
{
	Hcons *h;
	int last;

	if((ulong)c->qid.path != Qconsctl || (c->flag&COPEN) == 0 || c->dev >= Maxcons)
		return;
	h = &hcons[c->dev];
	lock(&h->lk);
	last = --h->nctl == 0;
	unlock(&h->lk);
	if(last){
		h9_cons_raw(c->dev, 0);
		h9_cons_echo(c->dev, 1);
	}
}

/*
 * consctl: rawon and rawoff, separated by spaces, as drawterm's, and
 * h9's echooff and echoon, which keep the line discipline.
 */
static void
consctl(ulong id, char *a, long n)
{
	char buf[256];

	if(n >= sizeof buf)
		n = sizeof buf - 1;
	memmove(buf, a, n);
	buf[n] = 0;
	for(a = buf; a != nil;){
		if(strncmp(a, "rawon", 5) == 0)
			h9_cons_raw(id, 1);
		else if(strncmp(a, "rawoff", 6) == 0)
			h9_cons_raw(id, 0);
		else if(strncmp(a, "echooff", 7) == 0)
			h9_cons_echo(id, 0);
		else if(strncmp(a, "echoon", 6) == 0)
			h9_cons_echo(id, 1);
		if((a = strchr(a, ' ')) != nil)
			a++;
	}
}

static long
hconsread(Chan *c, void *va, long n, vlong off)
{
	USED(off);
	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, va, n, hconsdir, nelem(hconsdir), devgen);
	case Qcons:
		return consread(c->dev, va, n);
	}
	error(Egreg);
	return -1;
}

static long
hconswrite(Chan *c, void *va, long n, vlong off)
{
	long r;

	USED(off);
	switch((ulong)c->qid.path){
	case Qcons:
	case Qstderr:
		r = h9_cons_write(c->dev, c->qid.path == Qcons ? 1 : 2, va, n);
		if(r < 0)
			error(Eio);
		return r;
	case Qconsctl:
		consctl(c->dev, va, n);
		return n;
	}
	error(Egreg);
	return -1;
}

Dev hconsdevtab = {
	'y',
	"hcons",

	devreset,
	devinit,
	devshutdown,
	hconsattach,
	hconswalk,
	hconsstat,
	hconsopen,
	devcreate,
	hconsclose,
	hconsread,
	devbread,
	hconswrite,
	devbwrite,
	devremove,
	devwstat,
};
