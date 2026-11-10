/*
 * h9's side of drawterm's screen interface when a GUI backend is built in
 * (design/0015-gfx.md): what drawterm's main.c and cpu.c would define, and
 * wrappers around the backend's screeninit and clipboard. The backend's
 * own source is compiled unmodified, with src/kern/gfx-gui.h renaming the
 * entry points wrapped here. src/kern/nogfx.c replaces this file and the
 * backend with -Dgfx=none.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include <draw.h>
#include <memdraw.h>
#include "screen.h"

/*
 * drawterm's cpu.c globals, which the backends read. geometry is X11's
 * window geometry (drawterm's -g): nil takes the backend's default size.
 * scalef is Cocoa's screen scale (drawterm's -x), set from --gfx-scale.
 */
char *geometry;
int scalef;

/* --gfx=noclip: /dev/snarf is a buffer here, never the host clipboard. */
int h9_gfx_noclip;
static Lock cliplk;
static char *clipbuf;

/* Set by src/gfx.zig: takes a closed window through the hangup path. */
void (*h9_gfx_onclose)(void);

/* The screen has opened (cpubody ran, or the first screeninit did). */
static int screenready;

extern void h9_gui_screeninit(void);	/* the backend's */
extern char *h9_gui_clipread(void);
extern int h9_gui_clipwrite(char*);
extern void h9_kern_isolated(void (*)(void*), void*);	/* proc.c */
#ifdef H9_GFX_X11
extern void h9_gui_setcursor(void);
extern void h9_gui_mouseset(Point);
#endif

static void
guiinit(void *arg)
{
	USED(arg);
	h9_gui_screeninit();
}

/*
 * The first attach of #i calls this, from whichever guest process made
 * it. The backend starts kprocs (X11's event loop, Win32's window thread,
 * term.c's resize proc) that live as long as h9 and would otherwise share
 * that process's namespace and fds, so it runs in a namespace of its own.
 * term.c points kernel prints at the screen; they stay on the host
 * terminal, which is h9's console.
 */
void
screeninit(void)
{
	h9_kern_isolated(guiinit, nil);
	screenputs = 0;
	screenready = 1;
#ifdef H9_GFX_X11
	/* The cursor a guest set before the screen opened. */
	h9_gui_setcursor();
#endif
}

#ifdef H9_GFX_X11
/*
 * X11's cursor calls use the display, which screeninit opens: a guest that
 * binds /dev/mouse before /dev/draw (rio's namespace does) set the cursor
 * with no display, which crashed in Xlib. Until the screen is open they do
 * nothing; screeninit sets the cursor then.
 */
void
setcursor(void)
{
	if(screenready)
		h9_gui_setcursor();
}

void
mouseset(Point xy)
{
	if(screenready)
		h9_gui_mouseset(xy);
}
#endif

/*
 * drawterm's backends call cpubody once the GUI is up, to run the rest of
 * drawterm; only Cocoa's does in h9, from a kproc its app delegate starts
 * (gfx.main runs AppKit). It opens the screen there, as drawterm's cpu
 * session's first attach would, and returns: the machine's run waits for
 * it (h9_gfx_ready).
 */
void
cpubody(void)
{
	if(gscreen == nil)
		screeninit();
	screenready = 1;
}

int
h9_gfx_ready(void)
{
	return screenready;
}

char*
clipread(void)
{
	char *s;

	if(!h9_gfx_noclip)
		return h9_gui_clipread();
	lock(&cliplk);
	s = strdup(clipbuf != nil ? clipbuf : "");
	unlock(&cliplk);
	return s;
}

int
clipwrite(char *buf)
{
	char *s;

	if(!h9_gfx_noclip)
		return h9_gui_clipwrite(buf);
	s = strdup(buf);
	lock(&cliplk);
	free(clipbuf);
	clipbuf = s;
	unlock(&cliplk);
	return 0;
}

/*
 * The backends' exit, on their event thread when the window is closed:
 * the machine gets hangup, as when the terminal closes, and its run ends
 * after the grace period. h9 exits when the run ends; until then this
 * thread parks, so nothing else in the backend runs.
 */
void
h9_gfx_exit(int code)
{
	USED(code);
	if(h9_gfx_onclose != nil)
		h9_gfx_onclose();
	for(;;)
		osmsleep(60*60*1000);
}

/*
 * #i attaches without opening the screen: devdraw's attach opens it, so
 * the namespace's bind of #i would open a window for every --gfx run.
 * It's opened at the first walk into #i instead, which every draw client
 * makes, so a program that never draws opens no window. Listing /dev
 * reads #i's own directory, which needs no screen.
 */
extern Dev drawdevtab;
static QLock drawopenlk;
static int drawopened;

static void
drawensure(void)
{
	Chan *c;

	if(drawopened)
		return;
	qlock(&drawopenlk);
	if(waserror()){
		qunlock(&drawopenlk);
		nexterror();
	}
	if(!drawopened){
		c = drawdevtab.attach("");
		cclose(c);
		drawopened = 1;
	}
	poperror();
	qunlock(&drawopenlk);
}

static Chan*
lazyattach(char *spec)
{
	return devattach('i', spec);
}

static Walkqid*
lazywalk(Chan *c, Chan *nc, char **name, int nname)
{
	if(nname == 0 && !drawopened)
		return devwalk(c, nc, name, 0, nil, 0, devgen);
	drawensure();
	return drawdevtab.walk(c, nc, name, nname);
}

/* #i's own directory, which lists draw and winname without the screen. */
static int
istop(Chan *c)
{
	return c->qid.path == 0;
}

static int
lazystat(Chan *c, uchar *db, int n)
{
	if(!istop(c))
		drawensure();
	return drawdevtab.stat(c, db, n);
}

static Chan*
lazyopen(Chan *c, int omode)
{
	if(!istop(c))
		drawensure();
	return drawdevtab.open(c, omode);
}

static void
lazyclose(Chan *c)
{
	drawdevtab.close(c);
}

static long
lazyread(Chan *c, void *a, long n, vlong off)
{
	return drawdevtab.read(c, a, n, off);
}

static long
lazywrite(Chan *c, void *a, long n, vlong off)
{
	return drawdevtab.write(c, a, n, off);
}

static void
lazyreset(void)
{
	drawdevtab.reset();
}

static void
lazyinit(void)
{
	drawdevtab.init();
}

static void
lazyshutdown(void)
{
	drawdevtab.shutdown();
}

static Chan*
lazycreate(Chan *c, char *name, int omode, ulong perm)
{
	return drawdevtab.create(c, name, omode, perm);
}

static void
lazyremove(Chan *c)
{
	drawdevtab.remove(c);
}

static int
lazywstat(Chan *c, uchar *db, int n)
{
	return drawdevtab.wstat(c, db, n);
}

Dev h9drawdevtab = {
	'i',
	"draw",

	lazyreset,
	lazyinit,
	lazyshutdown,
	lazyattach,
	lazywalk,
	lazystat,
	lazyopen,
	lazycreate,
	lazyclose,
	lazyread,
	devbread,
	lazywrite,
	devbwrite,
	lazyremove,
	lazywstat,
};

/*
 * devcons serves /dev/snarf, from the clipboard, whenever there's a
 * screen, and it's never masked. Opening it is limited to processes with
 * #i unmasked, so only the machine with the window reaches the clipboard,
 * and it opens the screen there: rio opens /dev/snarf before the display,
 * and serves its own snarf buffer to its windows when that fails.
 */
extern Dev consdevtab;
extern Dirtab *snarftab;

static Chan*
consopen(Chan *c, int omode)
{
	if(c->qid.path == snarftab->qid.path && !(c->qid.type & QTDIR)){
		if(devmasked(up->pgrp, devno('i')))
			error(Egreg);
		drawensure();
	}
	return consdevtab.open(c, omode);
}

static void consreset(void) { consdevtab.reset(); }
static void consinit(void) { consdevtab.init(); }
static void consshutdown(void) { consdevtab.shutdown(); }
static Chan *consattach(char *spec) { return consdevtab.attach(spec); }
static Walkqid *conswalk(Chan *c, Chan *nc, char **name, int nname) { return consdevtab.walk(c, nc, name, nname); }
static int consstat(Chan *c, uchar *db, int n) { return consdevtab.stat(c, db, n); }
static Chan *conscreate(Chan *c, char *name, int omode, ulong perm) { return consdevtab.create(c, name, omode, perm); }
static void consclose(Chan *c) { consdevtab.close(c); }
static long consread(Chan *c, void *a, long n, vlong off) { return consdevtab.read(c, a, n, off); }
static long conswrite(Chan *c, void *a, long n, vlong off) { return consdevtab.write(c, a, n, off); }
static void consremove(Chan *c) { consdevtab.remove(c); }
static int conswstat(Chan *c, uchar *db, int n) { return consdevtab.wstat(c, db, n); }

Dev h9consdevtab = {
	'c',
	"cons",

	consreset,
	consinit,
	consshutdown,
	consattach,
	conswalk,
	consstat,
	consopen,
	conscreate,
	consclose,
	consread,
	devbread,
	conswrite,
	devbwrite,
	consremove,
	conswstat,
};

/*
 * /dev/kbd. drawterm's devkbd serves the window's keys as 'r' and 'R'
 * messages (a rune pressed or released), the format 9front's kbdfs reads
 * from the kernel. Programs read kbdfs's own: 'k' and 'K' with the keys
 * held after a press or release, and 'c' for each character typed, which
 * is how rio gets text for its windows. h9 runs no kbdfs, so #b serves
 * that format itself: the backends' kbdkey comes here (gfx-gui.h), and
 * devkbd is used only for its open, which allows one reader.
 *
 * While nothing has /dev/kbd open the keys are dropped. devkbd would put
 * them on drawterm's console queue, whose echo writes them to the host's
 * stdout, and nothing in h9 reads that queue (/dev/cons is #y).
 */
#include "keyboard.h"

extern Dev kbddevtab;
static Lock kbdlk;
static int kbdopen;
static Queue *kbdq9;
static Rune kbddown[32];
static int nkbddown;

enum { Qkbd = 1 };	/* devkbd.c's */

static int
ismod(Rune r)
{
	switch(r){
	case Kshift:
	case Kctl:
	case Kalt:
	case Kaltgr:
	case Kmod4:
	case Kcaps:
	case Knum:
		return 1;
	}
	return 0;
}

static int
isdown(Rune r)
{
	int i;

	for(i = 0; i < nkbddown; i++)
		if(kbddown[i] == r)
			return 1;
	return 0;
}

/* Queues 'k' or 'K' and the keys held. Called with kbdlk held. */
static void
kbdstate(int c)
{
	char buf[2+nelem(kbddown)*UTFmax];
	int i, n;

	buf[0] = c;
	n = 1;
	for(i = 0; i < nkbddown; i++)
		n += runetochar(buf+n, &kbddown[i]);
	buf[n++] = 0;
	qproduce(kbdq9, buf, n);
}

static void
kbdunhold(Rune r)
{
	int i;

	for(i = 0; i < nkbddown; i++)
		if(kbddown[i] == r){
			memmove(kbddown+i, kbddown+i+1, (nkbddown-i-1)*sizeof kbddown[0]);
			nkbddown--;
			i--;
		}
}

void
h9_kbdkey(Rune r, int down)
{
	char buf[1+UTFmax+1];
	Rune c;
	int n;

	if(r == 0 || !kbdopen)
		return;
	lock(&kbdlk);
	if(kbdq9 == nil || !kbdopen){
		unlock(&kbdlk);
		return;
	}
	if(down){
		if(!isdown(r) && nkbddown < nelem(kbddown)){
			kbddown[nkbddown++] = r;
			kbdstate('k');
		}
		if(!ismod(r)){
			/* ^X forms, as kbdfs makes them */
			c = r;
			if(isdown(Kctl) && c >= '@' && c < 0x80 && c != 0x7F)
				c &= 0x1F;
			buf[0] = 'c';
			n = 1 + runetochar(buf+1, &c);
			buf[n++] = 0;
			qproduce(kbdq9, buf, n);
		}
	} else {
		/* A key pressed with shift held may be released without it. */
		n = nkbddown;
		kbdunhold(r);
		if(r >= 'a' && r <= 'z')
			kbdunhold(r - 'a' + 'A');
		else if(r >= 'A' && r <= 'Z')
			kbdunhold(r - 'A' + 'a');
		if(nkbddown != n)
			kbdstate('K');
	}
	unlock(&kbdlk);
}

static Chan*
kbdopen_(Chan *c, int omode)
{
	c = kbddevtab.open(c, omode);
	if(c->qid.path == Qkbd){
		lock(&kbdlk);
		if(kbdq9 == nil){
			/* Room for a burst of keys (each is up to three messages) on a slow machine. */
			kbdq9 = qopen(64*1024, Qmsg, 0, 0);
			if(kbdq9 != nil)
				qnoblock(kbdq9, 1);
		} else
			qreopen(kbdq9);
		nkbddown = 0;
		kbdopen = 1;
		unlock(&kbdlk);
	}
	return c;
}

static void
kbdclose_(Chan *c)
{
	if(c->qid.path == Qkbd && (c->flag & COPEN)){
		lock(&kbdlk);
		kbdopen = 0;
		if(kbdq9 != nil)
			qhangup(kbdq9, nil);
		unlock(&kbdlk);
	}
	kbddevtab.close(c);
}

static long
kbdread_(Chan *c, void *a, long n, vlong off)
{
	if(c->qid.path == Qkbd){
		if(kbdq9 == nil)
			error(Egreg);
		return qread(kbdq9, a, n);
	}
	return kbddevtab.read(c, a, n, off);
}

static void kbdreset_(void) { kbddevtab.reset(); }
static void kbdinit_(void) { kbddevtab.init(); }
static void kbdshutdown_(void) { kbddevtab.shutdown(); }
static Chan *kbdattach_(char *spec) { return kbddevtab.attach(spec); }
static Walkqid *kbdwalk_(Chan *c, Chan *nc, char **name, int nname) { return kbddevtab.walk(c, nc, name, nname); }
static int kbdstat_(Chan *c, uchar *db, int n) { return kbddevtab.stat(c, db, n); }
static Chan *kbdcreate_(Chan *c, char *name, int omode, ulong perm) { return kbddevtab.create(c, name, omode, perm); }
static long kbdwrite_(Chan *c, void *a, long n, vlong off) { return kbddevtab.write(c, a, n, off); }
static void kbdremove_(Chan *c) { kbddevtab.remove(c); }
static int kbdwstat_(Chan *c, uchar *db, int n) { return kbddevtab.wstat(c, db, n); }

Dev h9kbddevtab = {
	'b',
	"kbd",

	kbdreset_,
	kbdinit_,
	kbdshutdown_,
	kbdattach_,
	kbdwalk_,
	kbdstat_,
	kbdopen_,
	kbdcreate_,
	kbdclose_,
	kbdread_,
	devbread,
	kbdwrite_,
	devbwrite,
	kbdremove_,
	kbdwstat_,
};
