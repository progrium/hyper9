/*
 * drawterm's screen interface without a GUI backend (-Dgfx=none,
 * design/0015-gfx.md): there's no screen, so an attach of #i fails with
 * "no frame buffer", /dev/snarf with Egreg, and the mouse never moves.
 * Machines mask #b, #i and #m anyway, since --gfx can't be given.
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

Memimage *gscreen;
void screeninit(void) {}
void screensize(Rectangle r, ulong chan) { USED(r, chan); }
Memdata *attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen) { return nil; }
void flushmemscreen(Rectangle r) { USED(r); }
void getcolor(ulong i, ulong *r, ulong *g, ulong *b) { *r = *g = *b = 0; }
void setcolor(ulong i, ulong r, ulong g, ulong b) { USED(i, r, g, b); }
void setcursor(void) {}
void mouseset(Point p) { USED(p); }
char *clipread(void) { return nil; }
int clipwrite(char *s) { USED(s); return 0; }
