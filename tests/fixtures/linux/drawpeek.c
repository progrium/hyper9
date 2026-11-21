/*
 * drawpeek: reads the window's pixels back through /dev/9/draw, for the
 * wine-draw cases (design/wine-draw.md). Each argument is X,Y,RRGGBB, a
 * point relative to the window and the color expected there. drawpeek
 * reads the points until all have their colors, at most every tenth of a
 * second for the number of seconds in $DRAWPEEK_WAIT (default 60), and
 * prints "ok drawpeek", or "FAIL" and each point's color.
 *
 * "drawpeek -o FILE" instead writes the whole window to FILE as a PPM
 * image, to look at.
 *
 * It reads through an image of its own in x8r8g8b8, drawn from the
 * window, so the window's own channel format doesn't matter.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "draw9.h"

enum { id_win = 1, id_img, id_opaque };

static int peek(struct d9_conn *c, struct d9_rect wr, int x, int y, unsigned int *rgb)
{
    unsigned char *p, px[4];
    struct d9_rect one = { wr.minx + x, wr.miny + y, wr.minx + x + 1, wr.miny + y + 1 };

    d9_draw(c, id_img, id_win, id_opaque, (struct d9_rect){ 0, 0, 1, 1 }, one.minx, one.miny, 0, 0);
    if (!(p = d9_msg(c, 1 + 4 + 16))) return -1;
    *p++ = 'r';
    p = d9_l(p, id_img);
    d9_r(p, (struct d9_rect){ 0, 0, 1, 1 });
    if (d9_flushbuf(c) < 0) return -1;
    if (read(c->data, px, 4) != 4) return -1;
    *rgb = px[2] << 16 | px[1] << 8 | px[0];
    return 0;
}

/* Writes the window to path as a binary PPM, a band of rows at a time. */
static int dump(struct d9_conn *c, struct d9_rect wr, const char *path)
{
    int w = d9_dx(wr), h = d9_dy(wr), band = 4000 / (4 * w) > 0 ? 4000 / (4 * w) : 1;
    unsigned char *row = malloc(4 * w * band), *p;
    FILE *f = fopen(path, "wb");

    if (!row || !f) return -1;
    d9_free(c, id_img);
    d9_alloc(c, id_img, 0, d9_refnone, D9_XRGB32, 0, (struct d9_rect){ 0, 0, w, band }, 0);
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int y = 0; y < h; y += band) {
        int n = y + band <= h ? band : h - y;
        d9_draw(c, id_img, id_win, id_opaque, (struct d9_rect){ 0, 0, w, n }, wr.minx, wr.miny + y, 0, 0);
        if (!(p = d9_msg(c, 1 + 4 + 16))) return -1;
        *p++ = 'r';
        p = d9_l(p, id_img);
        d9_r(p, (struct d9_rect){ 0, 0, w, n });
        if (d9_flushbuf(c) < 0 || read(c->data, row, 4 * w * n) != 4 * w * n) return -1;
        for (int i = 0; i < w * n; i++) {
            fputc(row[4 * i + 2], f);
            fputc(row[4 * i + 1], f);
            fputc(row[4 * i], f);
        }
    }
    return fclose(f);
}

int main(int argc, char **argv)
{
    struct d9_conn c;
    struct d9_rect wr;
    char name[64], chan[16];
    int fd, n, i, wait = getenv("DRAWPEEK_WAIT") ? atoi(getenv("DRAWPEEK_WAIT")) : 60;
    unsigned int got[16];

    setvbuf(stdout, 0, _IONBF, 0);
    if (argc < 2 || argc > 17) {
        fprintf(stderr, "usage: drawpeek X,Y,RRGGBB...\n");
        return 2;
    }
    if ((fd = open("/dev/9/winname", O_RDONLY)) < 0 || (n = read(fd, name, sizeof name - 1)) <= 0) {
        printf("FAIL drawpeek: /dev/9/winname: %s\n", strerror(errno));
        return 1;
    }
    name[n] = 0;
    close(fd);
    if (d9_open(&c, "/dev/9") < 0 || d9_named(&c, id_win, name, chan, &wr) < 0) {
        printf("FAIL drawpeek: draw: %s\n", strerror(errno));
        return 1;
    }
    d9_alloc(&c, id_img, 0, d9_refnone, D9_XRGB32, 0, (struct d9_rect){ 0, 0, 1, 1 }, 0);
    d9_alloc(&c, id_opaque, 0, d9_refnone, D9_GREY1, 1, (struct d9_rect){ 0, 0, 1, 1 }, 0xFFFFFFFF);
    if (d9_flushbuf(&c) < 0) {
        printf("FAIL drawpeek: alloc: %s\n", strerror(errno));
        return 1;
    }
    if (argc == 3 && strcmp(argv[1], "-o") == 0) {
        if (dump(&c, wr, argv[2]) < 0) {
            printf("FAIL drawpeek: %s: %s\n", argv[2], strerror(errno));
            return 1;
        }
        return 0;
    }
    for (int tries = 0; tries <= wait * 10; tries++) {
        int all = 1;

        for (i = 1; i < argc; i++) {
            int x, y;
            unsigned int want;

            if (sscanf(argv[i], "%d,%d,%x", &x, &y, &want) != 3) {
                fprintf(stderr, "drawpeek: bad point %s\n", argv[i]);
                return 2;
            }
            if (peek(&c, wr, x, y, &got[i - 1]) < 0) {
                printf("FAIL drawpeek: read: %s\n", strerror(errno));
                return 1;
            }
            if (got[i - 1] != want) all = 0;
        }
        if (all) {
            printf("ok drawpeek\n");
            return 0;
        }
        nanosleep(&(struct timespec){ 0, 100 * 1000 * 1000 }, NULL);
    }
    printf("FAIL drawpeek:");
    for (i = 1; i < argc; i++) printf(" %s=%06x", argv[i], got[i - 1]);
    printf("\n");
    return 1;
}
