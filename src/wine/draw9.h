/*
 * A small client for Plan 9's draw device (draw(3)), for programs that
 * run on h9's Linux personality and reach the window through /dev/9
 * (design/wine-draw.md): winedraw.so, and the test fixture that reads
 * the screen back. It speaks the protocol directly, with the Linux libc
 * alone: messages are little-endian, buffered, and written to the
 * connection's data file in whole messages.
 *
 * Header-only, so each user compiles the parts it needs.
 */

#ifndef DRAW9_H
#define DRAW9_H

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* draw(2) channel descriptors */
#define D9_CHAN(t, n) ((((t) & 15) << 4) | ((n) & 15))
#define D9_XRGB32 ((D9_CHAN(6, 8) << 24) | (D9_CHAN(0, 8) << 16) | (D9_CHAN(1, 8) << 8) | D9_CHAN(2, 8))
#define D9_GREY1 D9_CHAN(3, 1)

enum { d9_refbackup = 0, d9_refnone = 1 };

struct d9_rect { int minx, miny, maxx, maxy; };

struct d9_conn {
    int ctl, data;
    int client;
    char dir[64];
    unsigned char buf[8000];
    int n;
};

/* A channel descriptor from its name, as strtochan(2): "x8r8g8b8". */
static inline unsigned int d9_strtochan(const char *s)
{
    static const char names[] = "rgbkamx";
    unsigned int c = 0;
    const char *t;

    for (; s[0] && s[1]; s += 2) {
        if (!(t = strchr(names, s[0])) || s[1] < '1' || s[1] > '8') return 0;
        c = c << 8 | D9_CHAN(t - names, s[1] - '0');
    }
    return c;
}

static inline int d9_dx(struct d9_rect r) { return r.maxx - r.minx; }
static inline int d9_dy(struct d9_rect r) { return r.maxy - r.miny; }

/* The 144 bytes of image info that draw/new and ctl answer with. */
static inline int d9_info(const char *s, int n, int *id, char *chan, struct d9_rect *r)
{
    char tmp[12 * 12 + 1];
    int v[12];
    char ch[16];

    if (n < 12 * 12) return -1;
    memcpy(tmp, s, 12 * 12);
    tmp[12 * 12] = 0;
    if (sscanf(tmp, "%d %d %15s %d %d %d %d %d %d %d %d %d", &v[0], &v[1], ch, &v[3], &v[4], &v[5], &v[6], &v[7],
               &v[8], &v[9], &v[10], &v[11]) != 12)
        return -1;
    if (id) *id = v[1];
    if (chan) strcpy(chan, ch);
    if (r) *r = (struct d9_rect){ v[4], v[5], v[6], v[7] };
    return v[0];
}

/* Opens a connection under dev (such as "/dev/9"). */
static inline int d9_open(struct d9_conn *c, const char *dev)
{
    char path[128], info[12 * 12];
    int fd, n;

    memset(c, 0, sizeof *c);
    c->ctl = c->data = -1;
    snprintf(path, sizeof path, "%s/draw/new", dev);
    if ((fd = open(path, O_RDWR | O_CLOEXEC)) < 0) return -1;
    n = read(fd, info, sizeof info);
    if ((c->client = d9_info(info, n, NULL, NULL, NULL)) < 0) {
        close(fd);
        errno = EIO;
        return -1;
    }
    c->ctl = fd;
    snprintf(c->dir, sizeof c->dir, "%s/draw/%d", dev, c->client);
    snprintf(path, sizeof path, "%s/data", c->dir);
    if ((c->data = open(path, O_RDWR | O_CLOEXEC)) < 0) {
        close(c->ctl);
        return -1;
    }
    return 0;
}

static inline void d9_close(struct d9_conn *c)
{
    if (c->data >= 0) close(c->data);
    if (c->ctl >= 0) close(c->ctl);
    c->ctl = c->data = -1;
}

/* Writes what's buffered. Each message is whole, so an error names one. */
static inline int d9_flushbuf(struct d9_conn *c)
{
    int n = c->n;

    c->n = 0;
    if (n == 0) return 0;
    return write(c->data, c->buf, n) == n ? 0 : -1;
}

/* Room for a message of n bytes, written out first if it won't fit. */
static inline unsigned char *d9_msg(struct d9_conn *c, int n)
{
    unsigned char *p;

    if (n > (int)sizeof c->buf) return NULL;
    if (c->n + n > (int)sizeof c->buf && d9_flushbuf(c) < 0) return NULL;
    p = c->buf + c->n;
    c->n += n;
    return p;
}

static inline unsigned char *d9_l(unsigned char *p, unsigned int v)
{
    p[0] = v;
    p[1] = v >> 8;
    p[2] = v >> 16;
    p[3] = v >> 24;
    return p + 4;
}

static inline unsigned char *d9_r(unsigned char *p, struct d9_rect r)
{
    p = d9_l(p, r.minx);
    p = d9_l(p, r.miny);
    p = d9_l(p, r.maxx);
    return d9_l(p, r.maxy);
}

/* 'n': attaches the image published as name, and reads its info. */
static inline int d9_named(struct d9_conn *c, int id, const char *name, char *chan, struct d9_rect *r)
{
    int len = strlen(name);
    unsigned char *p;
    char info[12 * 12];
    int n;

    if (len == 0 || len > 255 || !(p = d9_msg(c, 1 + 4 + 1 + len))) return -1;
    *p++ = 'n';
    p = d9_l(p, id);
    *p++ = len;
    memcpy(p, name, len);
    if (d9_flushbuf(c) < 0) return -1;
    n = pread(c->ctl, info, sizeof info, 0);
    return d9_info(info, n, NULL, chan, r) < 0 ? -1 : 0;
}

/* 'b': allocates an image, or a window on screen (screen nonzero). */
static inline int d9_alloc(struct d9_conn *c, int id, int screen, int refresh, unsigned int chan, int repl,
                           struct d9_rect r, unsigned int rgba)
{
    unsigned char *p = d9_msg(c, 1 + 4 + 4 + 1 + 4 + 1 + 16 + 16 + 4);
    struct d9_rect clip = repl ? (struct d9_rect){ -0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF } : r;

    if (!p) return -1;
    *p++ = 'b';
    p = d9_l(p, id);
    p = d9_l(p, screen);
    *p++ = refresh;
    p = d9_l(p, chan);
    *p++ = repl;
    p = d9_r(p, r);
    p = d9_r(p, clip);
    d9_l(p, rgba);
    return 0;
}

/* 'f': frees an image or window. */
static inline int d9_free(struct d9_conn *c, int id)
{
    unsigned char *p = d9_msg(c, 1 + 4);

    if (!p) return -1;
    *p++ = 'f';
    d9_l(p, id);
    return 0;
}

/* 'A': makes a screen of windows over image, filled with fill. */
static inline int d9_allocscreen(struct d9_conn *c, int id, int image, int fill, int public_)
{
    unsigned char *p = d9_msg(c, 1 + 4 + 4 + 4 + 1);

    if (!p) return -1;
    *p++ = 'A';
    p = d9_l(p, id);
    p = d9_l(p, image);
    p = d9_l(p, fill);
    *p = public_;
    return 0;
}

/* 'S': uses another client's public screen. */
static inline int d9_usescreen(struct d9_conn *c, int id, unsigned int chan)
{
    unsigned char *p = d9_msg(c, 1 + 4 + 4);

    if (!p) return -1;
    *p++ = 'S';
    p = d9_l(p, id);
    d9_l(p, chan);
    return 0;
}

/* 'd': draws src through mask onto r of dst. */
static inline int d9_draw(struct d9_conn *c, int dst, int src, int mask, struct d9_rect r, int sx, int sy, int mx,
                          int my)
{
    unsigned char *p = d9_msg(c, 1 + 4 * 3 + 16 + 8 + 8);

    if (!p) return -1;
    *p++ = 'd';
    p = d9_l(p, dst);
    p = d9_l(p, src);
    p = d9_l(p, mask);
    p = d9_r(p, r);
    p = d9_l(p, sx);
    p = d9_l(p, sy);
    p = d9_l(p, mx);
    d9_l(p, my);
    return 0;
}

/* 't': puts windows on top (top set) or at the bottom. */
static inline int d9_top(struct d9_conn *c, int id, int top)
{
    unsigned char *p = d9_msg(c, 1 + 1 + 2 + 4);

    if (!p) return -1;
    *p++ = 't';
    *p++ = top;
    *p++ = 1;
    *p++ = 0;
    d9_l(p, id);
    return 0;
}

/*
 * 'y': loads rows of 32-bit pixels into r of image id, from bits laid
 * out stride bytes a row with r's top-left at bits. Split into messages
 * that fit the buffer.
 */
static inline int d9_load32(struct d9_conn *c, int id, struct d9_rect r, const unsigned char *bits, int stride)
{
    int bpl = 4 * d9_dx(r), rows, y;
    unsigned char *p;

    if (bpl <= 0 || d9_dy(r) <= 0) return 0;
    rows = (sizeof c->buf - 21) / bpl;
    if (rows < 1) {
        /* A row wider than a message: a column strip at a time. */
        int w = (sizeof c->buf - 21) / 4, x;

        for (x = r.minx; x < r.maxx; x += w) {
            struct d9_rect s = { x, r.miny, x + w < r.maxx ? x + w : r.maxx, r.maxy };
            if (d9_load32(c, id, s, bits + 4 * (x - r.minx), stride) < 0) return -1;
        }
        return 0;
    }
    for (y = r.miny; y < r.maxy; y += rows) {
        struct d9_rect s = { r.minx, y, r.maxx, y + rows < r.maxy ? y + rows : r.maxy };
        int i, n = d9_dy(s);

        if (!(p = d9_msg(c, 21 + n * bpl))) return -1;
        *p++ = 'y';
        p = d9_l(p, id);
        p = d9_r(p, s);
        for (i = 0; i < n; i++, p += bpl) memcpy(p, bits + (size_t)(y - r.miny + i) * stride, bpl);
    }
    return 0;
}

/* 'v': flushes to the screen. */
static inline int d9_flush(struct d9_conn *c)
{
    unsigned char *p = d9_msg(c, 1);

    if (!p) return -1;
    *p = 'v';
    return d9_flushbuf(c);
}

#endif
