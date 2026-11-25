/*
 * h9's side of drawterm's screen interface when a GUI backend is built in
 * (design/epoch-0/gfx.md): what drawterm's main.c and cpu.c would define, and
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

/*
 * Which screen the machine with --gfx asked for (design/headless-screen.md),
 * set by src/gfx.zig when it claims the screen: the headless screen
 * (src/kern/gfx-headless.c, h9_hl_*) or the window backend (renamed h9_gui_*
 * by gfx-gui.h). H9_GFX_HEADLESS means the headless screen is linked in,
 * H9_GFX_WINDOW that a window backend is; the web host's canvas
 * (gfx-web.c) is neither, and defines the rest of the interface itself.
 * The screen opens once per process, so h9_gfx_opened says which one did,
 * and src/gfx.zig refuses a later claim for the other.
 */
int h9_gfx_headless;
int h9_gfx_opened;	/* 0 not yet, 1 the window, 2 the headless screen */
/* The headless screen's size, set by src/gfx.zig before it opens. */
int h9_gfx_headless_dx = 1024;
int h9_gfx_headless_dy = 768;

#if defined(H9_GFX_HEADLESS) && defined(H9_GFX_WINDOW)
#define HEADLESS (h9_gfx_headless)
#elif defined(H9_GFX_HEADLESS)
#define HEADLESS 1
#else
#define HEADLESS 0
#endif

extern void h9_kern_isolated(void (*)(void*), void*);	/* proc.c */
#if defined(H9_GFX_WINDOW) || !defined(H9_GFX_HEADLESS)
extern void h9_gui_screeninit(void);	/* the backend's */
extern char *h9_gui_clipread(void);
extern int h9_gui_clipwrite(char*);
#endif
#ifdef H9_GFX_WINDOW
extern Memdata *h9_gui_attachscreen(Rectangle*, ulong*, int*, int*, int*);
extern void h9_gui_flushmemscreen(Rectangle);
extern void h9_gui_screensize(Rectangle, ulong);
extern void h9_gui_getcolor(ulong, ulong*, ulong*, ulong*);
extern void h9_gui_setcolor(ulong, ulong, ulong, ulong);
extern void h9_gui_setcursor(void);
extern void h9_gui_mouseset(Point);
#endif
#ifdef H9_GFX_HEADLESS
extern void h9_hl_screeninit(void);
extern char *h9_hl_clipread(void);
extern int h9_hl_clipwrite(char*);
extern Memdata *h9_hl_attachscreen(Rectangle*, ulong*, int*, int*, int*);
extern void h9_hl_flushmemscreen(Rectangle);
extern void h9_hl_screensize(Rectangle, ulong);
extern void h9_hl_getcolor(ulong, ulong*, ulong*, ulong*);
extern void h9_hl_setcolor(ulong, ulong, ulong, ulong);
#endif

/* Whether the process's screen is open and is the headless one. */
int
h9_gfx_headless_open(void)
{
	return h9_gfx_opened == 2;
}

static void
guiinit(void *arg)
{
	USED(arg);
#ifdef H9_GFX_HEADLESS
	if(HEADLESS){
		h9_hl_screeninit();
		return;
	}
#endif
#if defined(H9_GFX_WINDOW) || !defined(H9_GFX_HEADLESS)
	h9_gui_screeninit();
#endif
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
	h9_gfx_opened = HEADLESS ? 2 : 1;
	h9_kern_isolated(guiinit, nil);
	screenputs = 0;
	screenready = 1;
#ifdef H9_GFX_X11
	/* The cursor a guest set before the screen opened. */
	if(!HEADLESS)
		h9_gui_setcursor();
#endif
}

#ifdef H9_GFX_WINDOW
#ifdef H9_GFX_HEADLESS
#define SCREEN(f) (HEADLESS ? h9_hl_##f : h9_gui_##f)
#else
#define SCREEN(f) h9_gui_##f
#endif

Memdata*
attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen)
{
	return SCREEN(attachscreen)(r, chan, depth, width, softscreen);
}

void
flushmemscreen(Rectangle r)
{
	SCREEN(flushmemscreen)(r);
}

void
screensize(Rectangle r, ulong chan)
{
	SCREEN(screensize)(r, chan);
}

void
getcolor(ulong i, ulong *r, ulong *g, ulong *b)
{
	SCREEN(getcolor)(i, r, g, b);
}

void
setcolor(ulong i, ulong r, ulong g, ulong b)
{
	SCREEN(setcolor)(i, r, g, b);
}

/*
 * The cursor is the window's; the headless screen has none. X11's cursor
 * calls use the display, which screeninit opens: a guest that binds
 * /dev/mouse before /dev/draw (rio's namespace does) set the cursor with
 * no display, which crashed in Xlib. Until the screen is open they do
 * nothing there; screeninit sets the cursor then.
 */
void
setcursor(void)
{
	if(HEADLESS)
		return;
#ifdef H9_GFX_X11
	if(!screenready)
		return;
#endif
	h9_gui_setcursor();
}

void
mouseset(Point xy)
{
	if(HEADLESS)
		return;
#ifdef H9_GFX_X11
	if(!screenready)
		return;
#endif
	h9_gui_mouseset(xy);
}
#elif defined(H9_GFX_HEADLESS)
/* A build whose only screen is the headless one (-Dgfx=headless). */
Memdata*
attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen)
{
	return h9_hl_attachscreen(r, chan, depth, width, softscreen);
}

void flushmemscreen(Rectangle r) { h9_hl_flushmemscreen(r); }
void screensize(Rectangle r, ulong chan) { h9_hl_screensize(r, chan); }
void getcolor(ulong i, ulong *r, ulong *g, ulong *b) { h9_hl_getcolor(i, r, g, b); }
void setcolor(ulong i, ulong r, ulong g, ulong b) { h9_hl_setcolor(i, r, g, b); }
void setcursor(void) {}
void mouseset(Point xy) { USED(xy); }
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

static char*
hostclipread(void)
{
#ifdef H9_GFX_HEADLESS
	if(HEADLESS)
		return h9_hl_clipread();
#endif
#if defined(H9_GFX_WINDOW) || !defined(H9_GFX_HEADLESS)
	return h9_gui_clipread();
#else
	return nil;
#endif
}

static int
hostclipwrite(char *buf)
{
#ifdef H9_GFX_HEADLESS
	if(HEADLESS)
		return h9_hl_clipwrite(buf);
#endif
#if defined(H9_GFX_WINDOW) || !defined(H9_GFX_HEADLESS)
	return h9_gui_clipwrite(buf);
#else
	return 0;
#endif
}

char*
clipread(void)
{
	char *s;

	if(!h9_gfx_noclip)
		return hostclipread();
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
		return hostclipwrite(buf);
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

/*
 * /dev/screen (design/headless-screen.md): #i's top directory gains a
 * third file beside draw and winname, the screen as an uncompressed
 * image(6) file, as 9front's /dev/screen is. Each open takes a copy of
 * the screen under drawlock, so a read sees one consistent frame, and
 * reads come from that copy. Its qid is above any devdraw makes.
 */
#define QSCREEN ((uvlong)1<<40)

typedef struct Shot Shot;
struct Shot {
	long n;
	uchar *buf;
};

/* #i's top directory, as devdraw's drawgen makes it, with screen added. */
static int
topgen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Qid q;

	USED(name, tab, ntab);
	q.vers = 0;
	switch(s){
	case DEVDOTDOT:
		mkqid(&q, 0, 0, QTDIR);
		devdir(c, q, "#i", 0, eve, 0500, dp);
		return 1;
	case 0:
		mkqid(&q, 4, 0, QTDIR);	/* devdraw's Q2nd */
		devdir(c, q, "draw", 0, eve, 0555, dp);
		return 1;
	case 1:
		mkqid(&q, 2, 0, QTFILE);	/* devdraw's Qwinname */
		devdir(c, q, "winname", 0, eve, 0444, dp);
		return 1;
	case 2:
		mkqid(&q, QSCREEN, 0, QTFILE);
		devdir(c, q, "screen", 0, eve, 0444, dp);
		return 1;
	}
	return -1;
}

static int
isscreen(Chan *c)
{
	return c->qid.path == QSCREEN;
}

static Shot*
screenshot(void)
{
	char cbuf[20];
	Memimage *i;
	Rectangle r;
	Shot *sh;
	long bpl;
	int hdr;

	sh = smalloc(sizeof *sh);
	qlock(&drawlock);
	if(waserror()){
		qunlock(&drawlock);
		free(sh->buf);
		free(sh);
		nexterror();
	}
	if((i = gscreen) == nil)
		error("no frame buffer");
	r = i->r;
	bpl = bytesperline(r, i->depth);
	hdr = 5*12;
	sh->n = hdr + bpl*Dy(r);
	sh->buf = malloc(sh->n+1);
	if(sh->buf == nil)
		error(Enomem);
	snprint((char*)sh->buf, hdr+1, "%11s %11d %11d %11d %11d ",
		chantostr(cbuf, i->chan), r.min.x, r.min.y, r.max.x, r.max.y);
	if(unloadmemimage(i, r, sh->buf+hdr, sh->n-hdr) < 0)
		error("can't read the screen");
	poperror();
	qunlock(&drawlock);
	return sh;
}

static Walkqid*
lazywalk(Chan *c, Chan *nc, char **name, int nname)
{
	if(nname == 0 && !drawopened)
		return devwalk(c, nc, name, 0, nil, 0, devgen);
	if(nname > 0 && c->qid.path == 0 && strcmp(name[0], "screen") == 0)
		return devwalk(c, nc, name, nname, nil, 0, topgen);
	drawensure();
	return drawdevtab.walk(c, nc, name, nname);
}

/* #i's own directory, which lists draw, winname and screen without the screen. */
static int
istop(Chan *c)
{
	return c->qid.path == 0;
}

static int
lazystat(Chan *c, uchar *db, int n)
{
	if(isscreen(c))
		return devstat(c, db, n, nil, 0, topgen);
	if(!istop(c))
		drawensure();
	return drawdevtab.stat(c, db, n);
}

static Chan*
lazyopen(Chan *c, int omode)
{
	if(isscreen(c)){
		drawensure();
		c = devopen(c, omode, nil, 0, topgen);
		c->aux = screenshot();
		return c;
	}
	if(!istop(c))
		drawensure();
	return drawdevtab.open(c, omode);
}

static void
lazyclose(Chan *c)
{
	Shot *sh;

	if(isscreen(c)){
		if((c->flag & COPEN) && (sh = c->aux) != nil){
			c->aux = nil;
			free(sh->buf);
			free(sh);
		}
		return;
	}
	drawdevtab.close(c);
}

static long
lazyread(Chan *c, void *a, long n, vlong off)
{
	Shot *sh;

	if(istop(c) && (c->qid.type & QTDIR))
		return devdirread(c, a, n, nil, 0, topgen);
	if(isscreen(c)){
		sh = c->aux;
		if(sh == nil || off >= sh->n)
			return 0;
		if(n > sh->n - off)
			n = sh->n - off;
		memmove(a, sh->buf+off, n);
		return n;
	}
	return drawdevtab.read(c, a, n, off);
}

static long
lazywrite(Chan *c, void *a, long n, vlong off)
{
	if(isscreen(c))
		error(Eperm);
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
	if(isscreen(c))
		error(Eperm);
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

enum {
	Qkbddir = 0,	/* devkbd.c's */
	Qkbd = 1,
	Qkbdin = 0x10,	/* ours */
};

/* devkbd's directory, with kbdin added (design/headless-screen.md). */
static Dirtab h9kbddir[] = {
	".",	{Qkbddir, 0, QTDIR},	0,	DMDIR|0555,
	"kbd",	{Qkbd},	0,	0444,
	"kbdin",	{Qkbdin},	0,	0222,
};

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
	if(c->qid.path == Qkbdin)
		return devopen(c, omode, h9kbddir, nelem(h9kbddir), devgen);
	c = kbddevtab.open(c, omode);
	if(c->qid.path == Qkbd){
		lock(&kbdlk);
		if(kbdq9 == nil){
			/* Room for a burst of keys (each is up to three messages) on a slow machine. */
			kbdq9 = qopen(64*1024, Qmsg, 0, 0);
			if(kbdq9 != nil)
				qnoblock(kbdq9, 1);
		} else {
			/*
			 * qreopen keeps what the last reader left unread, so
			 * without the flush a new reader starts mid-key, with
			 * the 'c' or 'K' of a key typed for someone else.
			 */
			qflush(kbdq9);
			qreopen(kbdq9);
		}
		nkbddown = 0;
		kbdopen = 1;
		unlock(&kbdlk);
	}
	return c;
}

static void
kbdclose_(Chan *c)
{
	if(c->qid.path == Qkbdin)
		return;
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
	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, h9kbddir, nelem(h9kbddir), devgen);
	if(c->qid.path == Qkbd){
		if(kbdq9 == nil)
			error(Egreg);
		return qread(kbdq9, a, n);
	}
	return kbddevtab.read(c, a, n, off);
}

/* A kbdfs message passed through to /dev/kbd's reader as it is. */
static void
kbdmsg(char *m, int n)
{
	lock(&kbdlk);
	if(kbdq9 != nil && kbdopen)
		qproduce(kbdq9, m, n);
	unlock(&kbdlk);
}

/*
 * /dev/kbdin, as kbdfs's kbdin reads it: a write that doesn't end in a
 * NUL is text, each rune typed (pressed, then released); one that does
 * is NUL-terminated messages, 'r' and 'R' with a rune pressed or
 * released, 'c' with a rune typed without key state, and any other
 * ('k' and 'K' with the keys held) passed to /dev/kbd's reader as it is.
 */
static long
kbdinwrite(char *a, long n)
{
	char *s, *p, *e;
	Rune r;
	int m;

	if(n <= 0)
		return n;
	s = smalloc(n+1);
	memmove(s, a, n);
	s[n] = 0;
	if(waserror()){
		free(s);
		nexterror();
	}
	if(s[n-1] != 0){
		for(p = s; *p; ){
			p += chartorune(&r, p);
			if(r == 0 || r == Runeerror)
				continue;
			h9_kbdkey(r, 1);
			h9_kbdkey(r, 0);
		}
	} else {
		e = s + n;
		for(p = s; p < e; p += m){
			m = strlen(p) + 1;
			if(m < 2)
				continue;
			switch(p[0]){
			case 'r':
			case 'R':
				chartorune(&r, p+1);
				if(r != 0)
					h9_kbdkey(r, p[0] == 'r');
				break;
			default:
				kbdmsg(p, m);
			}
		}
	}
	poperror();
	free(s);
	return n;
}

static long
kbdwrite_(Chan *c, void *a, long n, vlong off)
{
	if(c->qid.path == Qkbdin)
		return kbdinwrite(a, n);
	return kbddevtab.write(c, a, n, off);
}

static Walkqid*
kbdwalk_(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, h9kbddir, nelem(h9kbddir), devgen);
}

static int
kbdstat_(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, h9kbddir, nelem(h9kbddir), devgen);
}

static void kbdreset_(void) { kbddevtab.reset(); }
static void kbdinit_(void) { kbddevtab.init(); }
static void kbdshutdown_(void) { kbddevtab.shutdown(); }
static Chan *kbdattach_(char *spec) { return kbddevtab.attach(spec); }
static Chan *kbdcreate_(Chan *c, char *name, int omode, ulong perm) { return kbddevtab.create(c, name, omode, perm); }
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

/*
 * /dev/mousein (design/headless-screen.md), beside devmouse's files, as
 * 9front's devmouse serves it: each write is one event in /dev/mouse's
 * format, 'A' then x, y, buttons and msec for the pointer at x, y, 'a'
 * for x and y scaled from 0 to 2^31 across the screen, and any other
 * letter (/dev/mouse's 'm') for x and y relative to where it is. A msec
 * of 0 is now. They move the kernel's pointer, as the window's events
 * do, never the host's.
 */
extern Dev mousedevtab;

enum {
	Qmousedir = 0,	/* devmouse.c's */
	Qcursor,
	Qmouse,
	Qmousectl,
	Qmousein = 0x10,	/* ours */
};

static Dirtab h9mousedir[] = {
	".",	{Qmousedir, 0, QTDIR},	0,	DMDIR|0555,
	"cursor",	{Qcursor},	0,	0666,
	"mouse",	{Qmouse},	0,	0666,
	"mousectl",	{Qmousectl},	0,	0222,
	"mousein",	{Qmousein},	0,	0222,
};

static long
mouseinwrite(char *a, long n)
{
	char buf[64], *p;
	Memimage *i;
	vlong v;
	int x, y, b;
	ulong msec;

	/* The pointer stays put until there's a screen to move it on. */
	drawensure();
	if(n > sizeof buf - 1)
		n = sizeof buf - 1;
	memmove(buf, a, n);
	buf[n] = 0;
	x = strtol(buf+1, &p, 0);
	if(*p == 0)
		error(Eshort);
	y = strtol(p, &p, 0);
	if(*p == 0)
		error(Eshort);
	b = strtol(p, &p, 0);
	msec = (ulong)strtoll(p, 0, 0);
	if(msec == 0)
		msec = ticks();
	switch(buf[0]){
	case 'A':
		absmousetrack(x, y, b, msec);
		break;
	case 'a':
		if((i = gscreen) == nil)
			break;
		v = (vlong)(uint)x * Dx(i->clipr);
		x = (v >> 31) + i->clipr.min.x;
		v = (vlong)(uint)y * Dy(i->clipr);
		y = (v >> 31) + i->clipr.min.y;
		absmousetrack(x, y, b, msec);
		break;
	default:
		mousetrack(x, y, b, msec);
	}
	return n;
}

static Walkqid*
mousewalk_(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, h9mousedir, nelem(h9mousedir), devgen);
}

static int
mousestat_(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, h9mousedir, nelem(h9mousedir), devgen);
}

static Chan*
mouseopen_(Chan *c, int omode)
{
	if(c->qid.path == Qmousein)
		return devopen(c, omode, h9mousedir, nelem(h9mousedir), devgen);
	return mousedevtab.open(c, omode);
}

static void
mouseclose_(Chan *c)
{
	if(c->qid.path == Qmousein)
		return;
	mousedevtab.close(c);
}

static long
mouseread_(Chan *c, void *a, long n, vlong off)
{
	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, h9mousedir, nelem(h9mousedir), devgen);
	return mousedevtab.read(c, a, n, off);
}

static long
mousewrite_(Chan *c, void *a, long n, vlong off)
{
	if(c->qid.path == Qmousein)
		return mouseinwrite(a, n);
	return mousedevtab.write(c, a, n, off);
}

static void mousereset_(void) { mousedevtab.reset(); }
static void mouseinit_(void) { mousedevtab.init(); }
static void mouseshutdown_(void) { mousedevtab.shutdown(); }
static Chan *mouseattach_(char *spec) { return mousedevtab.attach(spec); }
static Chan *mousecreate_(Chan *c, char *name, int omode, ulong perm) { return mousedevtab.create(c, name, omode, perm); }
static void mouseremove_(Chan *c) { mousedevtab.remove(c); }
static int mousewstat_(Chan *c, uchar *db, int n) { return mousedevtab.wstat(c, db, n); }

Dev h9mousedevtab = {
	'm',
	"mouse",

	mousereset_,
	mouseinit_,
	mouseshutdown_,
	mouseattach_,
	mousewalk_,
	mousestat_,
	mouseopen_,
	mousecreate_,
	mouseclose_,
	mouseread_,
	devbread,
	mousewrite_,
	devbwrite,
	mouseremove_,
	mousewstat_,
};
