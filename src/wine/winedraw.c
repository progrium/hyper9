/*
 * winedraw.so, the Unix side of Wine's display driver for Plan 9 draw
 * (design/wine-draw.md). Wine's win32u renders every window into a
 * window surface; this driver puts those surfaces on the screen through
 * /dev/9/draw and turns /dev/9/mouse and /dev/9/kbd into Windows input.
 *
 * Each top-level window is a draw window (a layer) on one public screen
 * that every Wine process in the machine shares, so devdraw does the
 * stacking and clipping across processes, as rio's windows get it. The
 * first process to draw makes the screen over the machine's window and
 * publishes it under a fixed id; the others use it. A layer keeps its own
 * backing store (Refbackup), so a window uncovered by another is redrawn
 * by devdraw, not by Wine.
 *
 * A surface's flush loads its dirty rows into a staging image in Wine's
 * pixel format (draw's x8r8g8b8 is Windows' 32-bit BGRX, byte for byte),
 * then draws that onto the layer, which converts to the screen's format.
 *
 * Input: the mouse and keyboard files allow one reader each, so the first
 * Wine process to start (usually explorer, the desktop) reads them for all
 * and sends hardware input, which wineserver routes to the window under
 * the pointer or with the focus. A key is a scan code from the US layout,
 * which win32u's default keyboard tables translate.
 */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winbase.h"
#include "winternl.h"
#include "ntgdi.h"
#include "ntuser.h"
#include "wine/gdi_driver.h"
#include "wine/unixlib.h"

#include "draw9.h"
#include "unixlib.h"

#define DEV "/dev/9"

/* The shared screen's id: the same in every process. "WINE". */
enum { screen_id = 0x454e4957 };

/* Image ids in this process's connection. */
enum {
    id_window = 1, /* the machine's window, by name */
    id_fill,       /* the screen's background */
    id_opaque,     /* a mask that lets everything through */
    id_first,      /* layers and staging images from here */
};

static int debug;

#define DTRACE(...)                                     \
    do {                                               \
        if (debug) fprintf(stderr, "winedraw: " __VA_ARGS__); \
    } while (0)

static pthread_mutex_t draw_lock = PTHREAD_MUTEX_INITIALIZER;
static struct d9_conn conn;
static int conn_state; /* 0 unopened, 1 open, -1 failed */
static struct d9_rect screen_r;
static int next_id = id_first;

/* A top-level window with a surface of ours. */
struct win
{
    struct win *next;
    HWND hwnd;
    int layer;      /* 0 when not shown */
    RECT visible;   /* screen coordinates */
};

static struct win *wins;

struct draw_surface
{
    struct window_surface header;
    int staging;    /* x8r8g8b8 image the surface's size */
};

static const struct window_surface_funcs draw_surface_funcs;

/* The screen's size, from the window draw/new names. */
static int screen_size(struct d9_rect *r)
{
    char name[64], chan[16];
    struct d9_conn c;
    int fd, n, ret = -1;

    if ((fd = open(DEV "/winname", O_RDONLY | O_CLOEXEC)) < 0) return -1;
    n = read(fd, name, sizeof name - 1);
    close(fd);
    if (n <= 0) return -1;
    name[n] = 0;
    if (d9_open(&c, DEV) < 0) return -1;
    if (d9_named(&c, id_window, name, chan, r) == 0) ret = 0;
    d9_close(&c);
    return ret;
}

/*
 * Opens this process's connection and joins the screen, making it if no
 * process has. Called with draw_lock held.
 */
static int conn_open(void)
{
    char name[64], chan[16];
    int fd, n;

    if (conn_state) return conn_state > 0 ? 0 : -1;
    conn_state = -1;
    if ((fd = open(DEV "/winname", O_RDONLY | O_CLOEXEC)) < 0) return -1;
    n = read(fd, name, sizeof name - 1);
    close(fd);
    if (n <= 0) return -1;
    name[n] = 0;
    if (d9_open(&conn, DEV) < 0) return -1;
    if (d9_named(&conn, id_window, name, chan, &screen_r) < 0) goto fail;
    DTRACE("window %s %d,%d-%d,%d %s\n", name, screen_r.minx, screen_r.miny, screen_r.maxx, screen_r.maxy, chan);
    d9_alloc(&conn, id_opaque, 0, d9_refnone, D9_GREY1, 1, (struct d9_rect){ 0, 0, 1, 1 }, 0xFFFFFFFF);
    if (d9_flushbuf(&conn) < 0) goto fail;
    /* Another process's screen, or a new one. Two processes racing to make
     * it: the loser's 'A' fails, and it uses the winner's, which may take a
     * moment to appear. */
    for (int tries = 0; tries < 20; tries++) {
        if (tries) usleep(50000);
        /* draw checks that the screen's channel is the one we expect. */
        d9_usescreen(&conn, screen_id, d9_strtochan(chan));
        if (d9_flushbuf(&conn) == 0) {
            conn_state = 1;
            return 0;
        }
        /* The background: Windows' default desktop color. */
        d9_alloc(&conn, id_fill, 0, d9_refnone, D9_XRGB32, 1, (struct d9_rect){ 0, 0, 1, 1 }, 0x3A6EA5FF);
        d9_allocscreen(&conn, screen_id, id_window, id_fill, 1);
        d9_draw(&conn, id_window, id_fill, id_opaque, screen_r, 0, 0, 0, 0);
        if (d9_flush(&conn) == 0) {
            conn_state = 1;
            return 0;
        }
        d9_free(&conn, id_fill);
        d9_flushbuf(&conn);
    }
fail:
    DTRACE("can't open draw: %s\n", strerror(errno));
    d9_close(&conn);
    conn_state = 0; /* try again next time */
    return -1;
}

static struct win *win_get(HWND hwnd, int create)
{
    struct win *w;

    for (w = wins; w; w = w->next)
        if (w->hwnd == hwnd) return w;
    if (!create || !(w = calloc(1, sizeof *w))) return NULL;
    w->hwnd = hwnd;
    w->next = wins;
    wins = w;
    return w;
}

static void win_hide(struct win *w)
{
    if (!w->layer) return;
    d9_free(&conn, w->layer);
    d9_flush(&conn);
    w->layer = 0;
}

static struct d9_rect to_draw(RECT r)
{
    return (struct d9_rect){ screen_r.minx + r.left, screen_r.miny + r.top, screen_r.minx + r.right,
                             screen_r.miny + r.bottom };
}

/* Called with draw_lock held. */
static int win_show(struct win *w)
{
    if (w->layer) return 0;
    if (IsRectEmpty(&w->visible)) return -1;
    w->layer = next_id++;
    d9_alloc(&conn, w->layer, screen_id, d9_refbackup, D9_XRGB32, 0, to_draw(w->visible), 0xFFFFFFFF);
    if (d9_flushbuf(&conn) < 0) {
        DTRACE("layer for %p: %s\n", w->hwnd, strerror(errno));
        w->layer = 0;
        return -1;
    }
    return 0;
}

/***********************************************************************
 * Window surfaces
 */

static struct draw_surface *get_draw_surface(struct window_surface *surface)
{
    return (struct draw_surface *)surface;
}

static void draw_surface_set_clip(struct window_surface *surface, const RECT *rects, UINT count)
{
}

static BOOL draw_surface_flush(struct window_surface *surface, const RECT *rect, const RECT *dirty,
                               const BITMAPINFO *color_info, const void *color_bits, BOOL shape_changed,
                               const BITMAPINFO *shape_info, const void *shape_bits)
{
    struct draw_surface *s = get_draw_surface(surface);
    int width = color_info->bmiHeader.biWidth;
    int height = abs(color_info->bmiHeader.biHeight);
    struct d9_rect d, dst;
    struct win *w;
    RECT vis;

    pthread_mutex_lock(&draw_lock);
    if (!(w = win_get(surface->hwnd, 0)) || win_show(w) < 0) {
        pthread_mutex_unlock(&draw_lock);
        return TRUE;
    }
    /* dirty is in the surface's coordinates; rect places the surface
     * relative to the window's visible rect. */
    d = (struct d9_rect){ dirty->left, dirty->top, dirty->right, dirty->bottom };
    if (d.minx < 0) d.minx = 0;
    if (d.miny < 0) d.miny = 0;
    if (d.maxx > width) d.maxx = width;
    if (d.maxy > height) d.maxy = height;
    vis = w->visible;
    if (d.minx >= d.maxx || d.miny >= d.maxy) goto done;
    d9_load32(&conn, s->staging, d, (const unsigned char *)color_bits + (size_t)d.miny * width * 4 + d.minx * 4,
              width * 4);
    dst = to_draw((RECT){ vis.left + rect->left + d.minx, vis.top + rect->top + d.miny, vis.left + rect->left + d.maxx,
                          vis.top + rect->top + d.maxy });
    d9_draw(&conn, w->layer, s->staging, id_opaque, dst, d.minx, d.miny, 0, 0);
    if (d9_flush(&conn) < 0) DTRACE("flush %p: %s\n", surface->hwnd, strerror(errno));
done:
    pthread_mutex_unlock(&draw_lock);
    return TRUE;
}

static void draw_surface_destroy(struct window_surface *surface)
{
    struct draw_surface *s = get_draw_surface(surface);

    pthread_mutex_lock(&draw_lock);
    if (s->staging) {
        d9_free(&conn, s->staging);
        d9_flushbuf(&conn);
    }
    pthread_mutex_unlock(&draw_lock);
}

static const struct window_surface_funcs draw_surface_funcs = {
    draw_surface_set_clip,
    draw_surface_flush,
    draw_surface_destroy,
};

static BOOL DRAW_CreateWindowSurface(HWND hwnd, BOOL layered, const RECT *surface_rect, struct window_surface **surface)
{
    char buffer[FIELD_OFFSET(BITMAPINFO, bmiColors[256])];
    BITMAPINFO *info = (BITMAPINFO *)buffer;
    int width = surface_rect->right - surface_rect->left;
    int height = surface_rect->bottom - surface_rect->top;
    struct window_surface *previous, *ws;
    struct draw_surface *s;
    int staging;

    DTRACE("create surface %p layered %d %d,%d-%d,%d previous %p\n", hwnd, layered, (int)surface_rect->left,
           (int)surface_rect->top, (int)surface_rect->right, (int)surface_rect->bottom, *surface);
    if ((previous = *surface) && previous->funcs == &draw_surface_funcs && EqualRect(&previous->rect, surface_rect))
        return TRUE;
    if (NtUserGetAncestor(hwnd, GA_PARENT) != NtUserGetDesktopWindow()) return FALSE;

    pthread_mutex_lock(&draw_lock);
    if (conn_open() < 0) {
        pthread_mutex_unlock(&draw_lock);
        return FALSE;
    }
    staging = next_id++;
    d9_alloc(&conn, staging, 0, d9_refnone, D9_XRGB32, 0, (struct d9_rect){ 0, 0, width, height }, 0);
    if (d9_flushbuf(&conn) < 0) {
        pthread_mutex_unlock(&draw_lock);
        return FALSE;
    }
    win_get(hwnd, 1);
    pthread_mutex_unlock(&draw_lock);

    memset(info, 0, sizeof(*info));
    info->bmiHeader.biSize = sizeof(info->bmiHeader);
    info->bmiHeader.biWidth = width;
    info->bmiHeader.biHeight = -height; /* top-down */
    info->bmiHeader.biPlanes = 1;
    info->bmiHeader.biBitCount = 32;
    info->bmiHeader.biSizeImage = width * height * 4;
    info->bmiHeader.biCompression = BI_RGB;

    if (!(ws = window_surface_create(sizeof(*s), &draw_surface_funcs, hwnd, surface_rect, info, 0))) {
        pthread_mutex_lock(&draw_lock);
        d9_free(&conn, staging);
        d9_flushbuf(&conn);
        pthread_mutex_unlock(&draw_lock);
        return FALSE;
    }
    get_draw_surface(ws)->staging = staging;
    if (previous) window_surface_release(previous);
    *surface = ws;
    DTRACE("surface %p for %p %dx%d\n", ws, hwnd, width, height);
    return TRUE;
}

/* Makes the next flush send the whole surface, for a new or moved layer. */
static void surface_redraw(struct window_surface *surface)
{
    window_surface_lock(surface);
    surface->bounds = surface->rect;
    OffsetRect(&surface->bounds, -surface->rect.left, -surface->rect.top);
    window_surface_unlock(surface);
    window_surface_flush(surface);
}

static void DRAW_WindowPosChanged(HWND hwnd, HWND insert_after, HWND owner_hint, UINT swp_flags,
                                  const struct window_rects *rects, struct window_surface *surface)
{
    struct win *w;
    BOOL visible = (NtUserGetWindowLongW(hwnd, GWL_STYLE) & WS_VISIBLE) != 0;
    int moved = 0, shown = 0;

    pthread_mutex_lock(&draw_lock);
    if (!(w = win_get(hwnd, 0))) {
        pthread_mutex_unlock(&draw_lock);
        return;
    }
    DTRACE("pos %p %d,%d-%d,%d after %p flags %#x visible %d\n", hwnd, (int)rects->visible.left,
           (int)rects->visible.top, (int)rects->visible.right, (int)rects->visible.bottom, insert_after, swp_flags,
           visible);
    if (!EqualRect(&w->visible, &rects->visible)) {
        w->visible = rects->visible;
        moved = 1;
    }
    if (!visible || !surface || surface->funcs != &draw_surface_funcs) {
        win_hide(w);
    } else {
        if (moved) win_hide(w);
        shown = !w->layer && win_show(w) == 0;
        if (w->layer && !(swp_flags & SWP_NOZORDER) && (insert_after == HWND_TOP || insert_after == HWND_TOPMOST)) {
            d9_top(&conn, w->layer, 1);
            d9_flush(&conn);
        }
    }
    pthread_mutex_unlock(&draw_lock);
    if (shown) surface_redraw(surface);
}

static void DRAW_DestroyWindow(HWND hwnd)
{
    struct win **pp, *w;

    pthread_mutex_lock(&draw_lock);
    for (pp = &wins; (w = *pp); pp = &w->next)
        if (w->hwnd == hwnd) {
            win_hide(w);
            *pp = w->next;
            free(w);
            break;
        }
    pthread_mutex_unlock(&draw_lock);
}

static void DRAW_ActivateWindow(HWND hwnd, HWND previous)
{
    struct win *w;

    pthread_mutex_lock(&draw_lock);
    if ((w = win_get(NtUserGetAncestor(hwnd, GA_ROOT), 0)) && w->layer) {
        d9_top(&conn, w->layer, 1);
        d9_flush(&conn);
    }
    pthread_mutex_unlock(&draw_lock);
}

/***********************************************************************
 * The display
 */

static UINT DRAW_UpdateDisplayDevices(const struct gdi_device_manager *manager, void *param)
{
    static const struct pci_id pci_id;
    struct gdi_monitor monitor = { 0 };
    DEVMODEW mode = { 0 };
    struct d9_rect r;

    if (screen_size(&r) < 0) return STATUS_NOT_SUPPORTED;
    manager->add_gpu("Plan 9 draw", &pci_id, NULL, param);
    manager->add_source("draw", DISPLAY_DEVICE_ATTACHED_TO_DESKTOP | DISPLAY_DEVICE_PRIMARY_DEVICE,
                        NtUserGetSystemDpiForProcess(NULL), param);
    SetRect(&monitor.rc_monitor, 0, 0, d9_dx(r), d9_dy(r));
    monitor.rc_work = monitor.rc_monitor;
    manager->add_monitor(&monitor, param);
    mode.dmSize = sizeof(mode);
    mode.dmFields = DM_DISPLAYORIENTATION | DM_BITSPERPEL | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFLAGS |
                    DM_DISPLAYFREQUENCY;
    mode.dmDisplayOrientation = DMDO_DEFAULT;
    mode.dmBitsPerPel = 32;
    mode.dmPelsWidth = d9_dx(r);
    mode.dmPelsHeight = d9_dy(r);
    mode.dmDisplayFrequency = 60;
    manager->add_modes(&mode, 1, &mode, param);
    DTRACE("display %dx%d dpi %u\n", d9_dx(r), d9_dy(r), NtUserGetSystemDpiForProcess(NULL));
    return STATUS_SUCCESS;
}

/***********************************************************************
 * Input
 */

static NTSTATUS read_mouse(void *arg)
{
    char m[49];
    int fd, n, x, y, b, msec, old = 0;
    struct d9_rect r;

    if (screen_size(&r) < 0) return STATUS_UNSUCCESSFUL;
    if ((fd = open(DEV "/mouse", O_RDWR | O_CLOEXEC)) < 0) return STATUS_UNSUCCESSFUL;
    DTRACE("reading the mouse\n");
    while ((n = read(fd, m, sizeof m)) > 0) {
        INPUT input = { 0 };
        HWND hwnd;
        int i;
        static const struct { int bit; DWORD down; } buttons[] = {
            { 1, MOUSEEVENTF_LEFTDOWN }, { 2, MOUSEEVENTF_MIDDLEDOWN }, { 4, MOUSEEVENTF_RIGHTDOWN },
        };

        if (m[0] == 'r') {
            /* The window was resized: Wine's display follows it. */
            screen_size(&r);
            continue;
        }
        if (m[0] != 'm' || n < 1 + 4 * 12 || sscanf(m + 1, "%d %d %d %d", &x, &y, &b, &msec) != 4) continue;
        x -= r.minx;
        y -= r.miny;
        hwnd = NtUserWindowFromPoint(x, y);
        input.type = INPUT_MOUSE;
        input.mi.dx = x;
        input.mi.dy = y;
        input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
        NtUserSendHardwareInput(hwnd, 0, &input, 0);
        for (i = 0; i < 3; i++) {
            if ((b ^ old) & buttons[i].bit) {
                input.mi.dwFlags = buttons[i].down;
                if (!(b & buttons[i].bit)) input.mi.dwFlags <<= 1; /* the UP flag */
                NtUserSendHardwareInput(hwnd, 0, &input, 0);
            }
        }
        /* Buttons 4 and 5 are the wheel's notches. */
        if ((b & ~old) & (8 | 16)) {
            input.mi.dwFlags = MOUSEEVENTF_WHEEL;
            input.mi.mouseData = (b & 8) ? WHEEL_DELTA : -WHEEL_DELTA;
            NtUserSendHardwareInput(hwnd, 0, &input, 0);
            input.mi.mouseData = 0;
        }
        old = b;
    }
    close(fd);
    return STATUS_UNSUCCESSFUL;
}

/* Plan 9's runes for keys that aren't characters (keyboard.h). */
enum {
    KF = 0xF000,
    Spec = 0xF800,
    Khome = KF | 0x0D,
    Kup = KF | 0x0E,
    Kdown = Spec | 0x00,
    Kpgup = KF | 0x0F,
    Kprint = KF | 0x10,
    Kleft = KF | 0x11,
    Kright = KF | 0x12,
    Kpgdown = KF | 0x13,
    Kins = KF | 0x14,
    Kalt = KF | 0x15,
    Kshift = KF | 0x16,
    Kctl = KF | 0x17,
    Kend = KF | 0x18,
    Kscroll = KF | 0x19,
    Kbreak = Spec | 0x61,
    Kcaps = Spec | 0x64,
    Knum = Spec | 0x65,
    Kaltgr = Spec | 0x67,
    Kmod4 = Spec | 0x68,
};

/* A rune's PC scan code on a US keyboard; 0xe0xx for the extended keys. */
static unsigned int scan_code(unsigned int r)
{
    static const char row1[] = "1234567890-=", row1s[] = "!@#$%^&*()_+";
    static const char row2[] = "qwertyuiop[]", row2s[] = "QWERTYUIOP{}";
    static const char row3[] = "asdfghjkl;'`", row3s[] = "ASDFGHJKL:\"~";
    static const char row4[] = "\\zxcvbnm,./", row4s[] = "|ZXCVBNM<>?";
    const char *p;

    if (r >= KF + 1 && r <= KF + 10) return 0x3b + (r - KF - 1); /* F1-F10 */
    if (r == KF + 11) return 0x57;
    if (r == KF + 12) return 0x58;
    switch (r) {
    case 0x1b: return 0x01;
    case 0x08: return 0x0e;
    case '\t': return 0x0f;
    case '\n':
    case '\r': return 0x1c;
    case ' ': return 0x39;
    case 0x7f: return 0xe053; /* Delete */
    case Kctl: return 0x1d;
    case Kshift: return 0x2a;
    case Kalt: return 0x38;
    case Kaltgr: return 0xe038;
    case Kmod4: return 0xe05b;
    case Kcaps: return 0x3a;
    case Knum: return 0x45;
    case Kscroll: return 0x46;
    case Khome: return 0xe047;
    case Kup: return 0xe048;
    case Kpgup: return 0xe049;
    case Kleft: return 0xe04b;
    case Kright: return 0xe04d;
    case Kend: return 0xe04f;
    case Kdown: return 0xe050;
    case Kpgdown: return 0xe051;
    case Kins: return 0xe052;
    case Kprint: return 0xe037;
    case Kbreak: return 0xe046;
    }
    if (r > 0 && r < 0x80) {
        if ((p = strchr(row1, r)) || (p = strchr(row1s, r)))
            return 0x02 + (p - (strchr(row1, r) ? row1 : row1s));
        if ((p = strchr(row2, r)) || (p = strchr(row2s, r)))
            return 0x10 + (p - (strchr(row2, r) ? row2 : row2s));
        if ((p = strchr(row3, r)) || (p = strchr(row3s, r))) {
            int i = p - (strchr(row3, r) ? row3 : row3s);
            return i == 11 ? 0x29 : 0x1e + i;
        }
        if ((p = strchr(row4, r)) || (p = strchr(row4s, r))) {
            int i = p - (strchr(row4, r) ? row4 : row4s);
            return i == 0 ? 0x2b : 0x2c + i - 1;
        }
    }
    return 0;
}

/* The runes in a UTF-8 string, at most max of them. */
static int runes(const char *s, unsigned int *out, int max)
{
    const unsigned char *p = (const unsigned char *)s;
    int n = 0;

    while (*p && n < max) {
        unsigned int c = *p++;
        if (c >= 0xf0) {
            c = (c & 7) << 18;
            for (int i = 2; i >= 0 && *p; i--) c |= (*p++ & 0x3f) << (6 * i);
        } else if (c >= 0xe0) {
            c = (c & 15) << 12;
            for (int i = 1; i >= 0 && *p; i--) c |= (*p++ & 0x3f) << (6 * i);
        } else if (c >= 0xc0) {
            c = (c & 31) << 6;
            if (*p) c |= *p++ & 0x3f;
        }
        out[n++] = c;
    }
    return n;
}

static int has(const unsigned int *set, int n, unsigned int r)
{
    for (int i = 0; i < n; i++)
        if (set[i] == r) return 1;
    return 0;
}

static void send_key(unsigned int scan, int up)
{
    INPUT input = { 0 };

    if (!scan) return;
    input.type = INPUT_KEYBOARD;
    input.ki.wScan = scan & 0xff;
    input.ki.dwFlags = KEYEVENTF_SCANCODE;
    if (scan & 0xff00) input.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
    if (up) input.ki.dwFlags |= KEYEVENTF_KEYUP;
    NtUserSendHardwareInput(NtUserGetForegroundWindow(), 0, &input, 0);
}

static NTSTATUS read_kbd(void *arg)
{
    unsigned int held[32], now[32];
    int nheld = 0, nnow, fd, n, i;
    char m[256];

    if ((fd = open(DEV "/kbd", O_RDONLY | O_CLOEXEC)) < 0) return STATUS_UNSUCCESSFUL;
    DTRACE("reading the keyboard\n");
    while ((n = read(fd, m, sizeof m - 1)) > 0) {
        m[n] = 0;
        if (m[0] != 'k' && m[0] != 'K') continue;
        /* The keys held now; the difference from before is what went
         * down or up. Shifted forms are the same key. */
        nnow = runes(m + 1, now, 32);
        for (i = 0; i < nheld; i++)
            if (!has(now, nnow, held[i]) && !has(now, nnow, scan_code(held[i]) ? held[i] : 0))
                send_key(scan_code(held[i]), 1);
        for (i = 0; i < nnow; i++)
            if (!has(held, nheld, now[i])) send_key(scan_code(now[i]), 0);
        memcpy(held, now, nnow * sizeof now[0]);
        nheld = nnow;
    }
    close(fd);
    return STATUS_UNSUCCESSFUL;
}

/***********************************************************************
 * Registration
 */

static const struct user_driver_funcs draw_funcs = {
    .pUpdateDisplayDevices = DRAW_UpdateDisplayDevices,
    .pCreateWindowSurface = DRAW_CreateWindowSurface,
    .pWindowPosChanged = DRAW_WindowPosChanged,
    .pDestroyWindow = DRAW_DestroyWindow,
    .pActivateWindow = DRAW_ActivateWindow,
};

static NTSTATUS init(void *arg)
{
    debug = getenv("WINEDRAW_DEBUG") != NULL;
    if (access(DEV "/draw/new", F_OK) < 0) {
        DTRACE("no %s/draw: no window\n", DEV);
        return STATUS_UNSUCCESSFUL;
    }
    __wine_set_user_driver(&draw_funcs, WINE_GDI_DRIVER_VERSION);
    return STATUS_SUCCESS;
}

const unixlib_entry_t __wine_unix_call_funcs[] = {
    init,
    read_mouse,
    read_kbd,
};

const unixlib_entry_t __wine_unix_call_wow64_funcs[] = {
    init,
    read_mouse,
    read_kbd,
};
