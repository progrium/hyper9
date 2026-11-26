/*
 * h9's side of drawterm's screen interface when a GUI backend is built in
 * (design/epoch-0/gfx.md): what drawterm's main.c and cpu.c would define, and
 * wrappers around the backend's screeninit and clipboard. The backend's
 * own source is compiled unmodified, with src/host/gfx-gui.h renaming the
 * entry points wrapped here. src/kern/nogfx.c replaces this file and the
 * backend with -Dgfx=none.
 *
 * The devices h9 serves over drawterm's devdraw, devcons, devkbd, and
 * devmouse (#i opening the screen lazily, /dev/screen, /dev/snarf's
 * limit, kbdfs's format on /dev/kbd, /dev/kbdin, and /dev/mousein) are
 * src/kern/dev/gfx.zig.
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
 * Which screen the machine with --gfx asked for (design/epoch-0/headless-screen.md),
 * set by src/gfx.zig when it claims the screen: the headless screen
 * (src/host/gfx-headless.c, h9_hl_*) or the window backend (renamed h9_gui_*
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
 * For the devices in src/kern/dev/gfx.zig, which need the screen's
 * image. Neither raises.
 */

/*
 * /dev/screen's frame: the screen as an uncompressed image(6) file, in a
 * buffer of *np bytes the caller frees, taken under drawlock, so it's one
 * consistent frame. nil, with the reason in *err, if there's none.
 */
uchar*
h9_gfx_screenshot(long *np, char **err)
{
	char cbuf[20];
	Memimage *i;
	Rectangle r;
	uchar *buf;
	long bpl, n;
	int hdr;

	buf = nil;
	qlock(&drawlock);
	if((i = gscreen) == nil){
		*err = "no frame buffer";
		goto out;
	}
	r = i->r;
	bpl = bytesperline(r, i->depth);
	hdr = 5*12;
	n = hdr + bpl*Dy(r);
	buf = malloc(n+1);
	if(buf == nil){
		*err = Enomem;
		goto out;
	}
	snprint((char*)buf, hdr+1, "%11s %11d %11d %11d %11d ",
		chantostr(cbuf, i->chan), r.min.x, r.min.y, r.max.x, r.max.y);
	if(unloadmemimage(i, r, buf+hdr, n-hdr) < 0){
		free(buf);
		buf = nil;
		*err = "can't read the screen";
		goto out;
	}
	*np = n;
out:
	qunlock(&drawlock);
	return buf;
}

/*
 * A /dev/mousein event, of the kind its first letter says: 'A' for the
 * pointer at x, y, 'a' for x and y scaled from 0 to 2^31 across the
 * screen, and any other for x and y relative to where it is. A msec of 0
 * is now.
 */
void
h9_gfx_mousein(int kind, int x, int y, int b, ulong msec)
{
	Memimage *i;
	vlong v;

	if(msec == 0)
		msec = ticks();
	switch(kind){
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
}
