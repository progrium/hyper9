/*
 * The browser host's GUI backend (-Dgfx=web, design/browser-gfx.md):
 * drawterm's screen interface on a page's <canvas>, which the page has
 * moved into h9's Worker as an OffscreenCanvas. The JS half is gfxImports
 * in src/web/h9-web.js, which owns the canvas, and createMachine's event
 * handlers in the page.
 *
 * - The screen, gscreen, stays in wasm memory as XBGR32, whose
 *   little-endian bytes are R, G, B and X, an ImageData row's order.
 *   flushmemscreen only tells the JS host which rectangle changed; it
 *   copies the rectangle onto the canvas once a frame, outside any
 *   coroutine, so the kernel never waits for the canvas.
 * - The page's pointer, keys, size changes and pastes queue up in the
 *   JS host. gfxinput, a kernel process, waits for them with a
 *   Suspending import and hands them to absmousetrack, h9_kbdkey and
 *   screenresize, as the X11 backend's event thread does, so the input
 *   paths run with up set.
 * - /dev/snarf is a buffer here. A paste into the canvas replaces it, and
 *   a write to it is posted to the page, which copies it to the page's
 *   clipboard. The guest never reads the clipboard itself.
 *
 * Like the headless backend, this is h9's own source, so it defines the
 * names src/kern/gfx-gui.h would otherwise rename, and isn't compiled with
 * that header.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "screen.h"

#include "../web/coro.h"

#define IMPORT(n) __attribute__((import_module("h9"), import_name(#n)))

/*
 * The JS host's side (h9-web.js, gfxImports). gfx_wait is Suspending: it
 * parks the calling coroutine until events arrive.
 */
IMPORT(gfx_present) int js_gfx_present(void);
IMPORT(gfx_size) void js_gfx_size(int *wh);
IMPORT(gfx_screen) void js_gfx_screen(uchar *base, int stride, int dx, int dy);
IMPORT(gfx_flush) void js_gfx_flush(int minx, int miny, int maxx, int maxy);
IMPORT(gfx_wait) int js_gfx_wait(int *ev, int n);
IMPORT(gfx_paste) int js_gfx_paste(char *p, int n);
IMPORT(gfx_snarf) void js_gfx_snarf(char *p, int n);
IMPORT(gfx_cursor) void js_gfx_cursor(uchar *c);

uintptr h9_get_sp(void);
void h9_set_sp(uintptr);

extern void h9_kbdkey(Rune, int);	/* gfx.c */

/* The events gfx_wait returns, four ints each (h9-web.js's GfxEv). */
enum {
	Evkey = 1,	/* rune, down */
	Evmouse,	/* x, y, buttons */
	Evresize,	/* dx, dy */
	Evpaste,	/* the text's length in bytes, read with gfx_paste */
	Evsize = 4,
	Nev = 64,	/* events taken per wait */
	Maxpaste = 1<<20,
};

Memimage *gscreen;
static ulong pal[256];
static Lock cliplk;
static char *clip;

/* Whether the page gave this machine a canvas. */
int
h9_gfx_web_present(void)
{
	return js_gfx_present();
}

/*
 * Calls gfx_wait as a park: other coroutines run while it waits, so
 * what's per thread is saved around it, as coro.zig's blocking does.
 */
static int
waitevents(int *ev, int n)
{
	H9coro *me;
	uintptr sp;
	int r;

	me = h9_coro_self();
	h9_coro_save(me);
	sp = h9_get_sp();
	r = js_gfx_wait(ev, n);
	h9_set_sp(sp);
	h9_coro_restore(me);
	return r;
}

static void
paste(int n)
{
	char *s;

	if(n < 0 || n > Maxpaste)
		return;
	s = malloc(n+1);
	if(s == nil)
		return;
	n = js_gfx_paste(s, n);
	s[n < 0 ? 0 : n] = 0;
	lock(&cliplk);
	free(clip);
	clip = s;
	unlock(&cliplk);
}

static void
gfxinput(void *arg)
{
	int ev[Nev*Evsize], *e, n;

	USED(arg);
	for(;;){
		n = waitevents(ev, nelem(ev));
		for(e = ev; e < ev+n; e += Evsize)
			switch(e[0]){
			case Evkey:
				h9_kbdkey(e[1], e[2]);
				break;
			case Evmouse:
				absmousetrack(e[1], e[2], e[3], ticks());
				break;
			case Evresize:
				if(e[1] > 0 && e[2] > 0)
					screenresize(Rect(0, 0, e[1], e[2]));
				break;
			case Evpaste:
				paste(e[1]);
				break;
			}
	}
}

/* Renamed by gfx-gui.h in drawterm's backends; src/kern/gfx.c wraps it. */
void
h9_gui_screeninit(void)
{
	Rectangle r;
	int wh[2];

	memimageinit();
	js_gfx_size(wh);
	if(wh[0] <= 0 || wh[1] <= 0){
		wh[0] = 1024;
		wh[1] = 768;
	}
	r = Rect(0, 0, wh[0], wh[1]);
	screensize(r, XBGR32);
	if(gscreen == nil)
		panic("screensize failed");
	gscreen->clipr = r;
	kproc("gfxinput", gfxinput, nil);
	qlock(&drawlock);
	terminit();
	flushmemscreen(gscreen->clipr);
	qunlock(&drawlock);
}

/* Called with drawlock held, from screeninit and term.c's resize kproc. */
void
screensize(Rectangle r, ulong chan)
{
	Memimage *i;

	if((i = allocmemimage(r, chan)) == nil)
		return;
	if(gscreen != nil)
		freememimage(gscreen);
	gscreen = i;
	gscreen->clipr = ZR;
	js_gfx_screen(byteaddr(gscreen, r.min), gscreen->width*sizeof(ulong), Dx(r), Dy(r));
}

Memdata*
attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen)
{
	*r = gscreen->clipr;
	*chan = gscreen->chan;
	*depth = gscreen->depth;
	*width = gscreen->width;
	*softscreen = 1;
	gscreen->data->ref++;
	return gscreen->data;
}

/* Marks r for the next frame's copy onto the canvas. */
void
flushmemscreen(Rectangle r)
{
	if(gscreen == nil || rectclip(&r, gscreen->clipr) == 0)
		return;
	r = rectsubpt(r, gscreen->r.min);
	js_gfx_flush(r.min.x, r.min.y, r.max.x, r.max.y);
}

/* gscreen is 32-bit, so 8-bit colour maps are only kept, as headless does. */
void
getcolor(ulong i, ulong *r, ulong *g, ulong *b)
{
	ulong v;

	v = pal[i&0xFF];
	*r = (v>>16)&0xFF;
	*g = (v>>8)&0xFF;
	*b = v&0xFF;
}

void
setcolor(ulong i, ulong r, ulong g, ulong b)
{
	pal[i&0xFF] = ((r&0xFF)<<16) | ((g&0xFF)<<8) | (b&0xFF);
}

/*
 * The cursor goes to the page as /dev/cursor's 72 bytes (the offset as two
 * little-endian ints, then clr and set), which it draws into a CSS cursor;
 * nil is the arrow, the page's default cursor.
 */
void
setcursor(void)
{
	uchar c[72];
	int isarrow;

	lock(&cursor.lk);
	isarrow = eqpt(cursor.offset, arrow.offset)
		&& memcmp(cursor.clr, arrow.clr, sizeof cursor.clr) == 0
		&& memcmp(cursor.set, arrow.set, sizeof cursor.set) == 0;
	c[0] = cursor.offset.x;
	c[1] = cursor.offset.x>>8;
	c[2] = cursor.offset.x>>16;
	c[3] = cursor.offset.x>>24;
	c[4] = cursor.offset.y;
	c[5] = cursor.offset.y>>8;
	c[6] = cursor.offset.y>>16;
	c[7] = cursor.offset.y>>24;
	memmove(c+8, cursor.clr, 2*16);
	memmove(c+40, cursor.set, 2*16);
	unlock(&cursor.lk);
	js_gfx_cursor(isarrow ? nil : c);
}

/* A page can't move the pointer, so rio's and acme's warps don't happen. */
void
mouseset(Point p)
{
	USED(p);
}

/*
 * The snarf buffer, for the page's clipboard (clipboard: "page"). With
 * "private" (--gfx=noclip) gfx.c keeps its own and never calls these.
 */
char*
h9_gui_clipread(void)
{
	char *s;

	lock(&cliplk);
	s = strdup(clip != nil ? clip : "");
	unlock(&cliplk);
	return s;
}

int
h9_gui_clipwrite(char *buf)
{
	char *s;

	s = strdup(buf);
	if(s == nil)
		return -1;
	lock(&cliplk);
	free(clip);
	clip = s;
	unlock(&cliplk);
	js_gfx_snarf(s, strlen(s));
	return 0;
}
