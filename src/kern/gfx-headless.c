/*
 * The headless screen (design/epoch-0/headless-screen.md, design/epoch-0/gfx.md): a
 * screen in memory. It implements drawterm's screen interface as the
 * window-system backends do, without a window: flushes go nowhere and the
 * "host clipboard" is a buffer in the h9 process.
 *
 * It's linked into every native build with graphics, beside the window
 * backend if there is one, so its side of the interface is named h9_hl_*
 * and src/kern/gfx.c calls it for a machine that asked for the headless
 * screen. In a build with only this screen (-Dgfx=headless) it defines
 * gscreen too; beside a window backend, the backend's gscreen is the one
 * screen the process has, whichever of the two opened it.
 *
 * src/gfx.zig's `headless` hooks inject input, read the clipboard and the
 * screen's pixels, and close the "window".
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include <draw.h>
#include <memdraw.h>
#include "screen.h"

extern void h9_kbdkey(Rune, int);	/* src/kern/dev/gfx.zig */
extern int h9_gfx_headless_open(void);	/* gfx.c */
void h9_hl_screensize(Rectangle, ulong);

#ifndef H9_GFX_WINDOW
Memimage *gscreen;
#endif

extern int h9_gfx_headless_dx, h9_gfx_headless_dy;	/* gfx.c */

static ulong pal[256];
static Lock cliplk;
static char *clip;

void
h9_hl_screeninit(void)
{
	Rectangle r;

	memimageinit();
	r = Rect(0, 0, h9_gfx_headless_dx, h9_gfx_headless_dy);
	h9_hl_screensize(r, XRGB32);
	if(gscreen == nil)
		panic("screensize failed");
	gscreen->clipr = r;
	qlock(&drawlock);
	terminit();
	qunlock(&drawlock);
}

void
h9_hl_screensize(Rectangle r, ulong chan)
{
	Memimage *i;

	if((i = allocmemimage(r, chan)) == nil)
		return;
	if(gscreen != nil)
		freememimage(gscreen);
	gscreen = i;
	gscreen->clipr = ZR;
}

Memdata*
h9_hl_attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen)
{
	*r = gscreen->clipr;
	*chan = gscreen->chan;
	*depth = gscreen->depth;
	*width = gscreen->width;
	*softscreen = 1;
	gscreen->data->ref++;
	return gscreen->data;
}

void
h9_hl_flushmemscreen(Rectangle r)
{
	USED(r);
}

void
h9_hl_getcolor(ulong i, ulong *r, ulong *g, ulong *b)
{
	ulong v;

	v = pal[i&0xFF];
	*r = (v>>16)&0xFF;
	*g = (v>>8)&0xFF;
	*b = v&0xFF;
}

void
h9_hl_setcolor(ulong i, ulong r, ulong g, ulong b)
{
	pal[i&0xFF] = ((r&0xFF)<<16) | ((g&0xFF)<<8) | (b&0xFF);
}

char*
h9_hl_clipread(void)
{
	char *s;

	lock(&cliplk);
	s = strdup(clip != nil ? clip : "");
	unlock(&cliplk);
	return s;
}

int
h9_hl_clipwrite(char *buf)
{
	char *s;

	s = strdup(buf);
	lock(&cliplk);
	free(clip);
	clip = s;
	unlock(&cliplk);
	return 0;
}

/*
 * The test hooks. They're called from a test's own thread, which isn't a
 * kernel Proc, as a window system's callbacks would be on Cocoa's main
 * thread before adoption: only locks and wakeups, no sleeping.
 */

/* A key press or release in the window. */
void
h9_gfx_headless_key(Rune r, int down)
{
	h9_kbdkey(r, down);
}

/* The mouse at x, y with buttons b (1 left, 2 middle, 4 right). */
void
h9_gfx_headless_mouse(int x, int y, int b)
{
	absmousetrack(x, y, b, ticks());
}

/* The headless screen's "host clipboard": a copy the caller frees with free(). */
char*
h9_gfx_headless_clipread(void)
{
	return h9_hl_clipread();
}

void
h9_gfx_headless_clipwrite(char *s)
{
	h9_hl_clipwrite(s);
}

/*
 * The screen's size, and its pixels as XRGB32 rows copied into buf (n
 * bytes, at least 4*Dx*Dy). Returns 0, or -1 before the headless screen
 * opens (or when the process's screen is a window). Not locked against
 * drawing, so it's for a quiet screen; /dev/screen is the locked read.
 */
int
h9_gfx_headless_size(int *dx, int *dy)
{
	if(gscreen == nil || !h9_gfx_headless_open())
		return -1;
	*dx = Dx(gscreen->r);
	*dy = Dy(gscreen->r);
	return 0;
}

int
h9_gfx_headless_pixels(uchar *buf, long n)
{
	int y, dx, dy;
	uchar *row;

	if(gscreen == nil || !h9_gfx_headless_open())
		return -1;
	dx = Dx(gscreen->r);
	dy = Dy(gscreen->r);
	if(n < 4L*dx*dy)
		return -1;
	for(y = 0; y < dy; y++){
		row = byteaddr(gscreen, Pt(gscreen->r.min.x, gscreen->r.min.y+y));
		memmove(buf + 4L*dx*y, row, 4L*dx);
	}
	return 0;
}

/* Closing the window, as a window system's close button does. */
void
h9_gfx_headless_close(void)
{
	extern void (*h9_gfx_onclose)(void);

	if(h9_gfx_onclose != nil)
		h9_gfx_onclose();
}
