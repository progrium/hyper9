/*
 * roundf386.so: a roundf for 32-bit Wine on musl, loaded with LD_PRELOAD
 * (design/wine-draw.md, "Wine on 386").
 *
 * Windows programs run with the x87 precision set to 53 bits (control
 * word 0x27f), and Wine's Unix side runs with whatever the program left.
 * Alpine's i386 musl roundf gives 1.0 for any argument of 1 or more at
 * that precision, on real hardware as under h9. win32u rounds its DPI
 * scaling with roundf, so every window and monitor rect comes out 96
 * times too big, or 1 pixel. This roundf uses only integer operations,
 * so the precision doesn't matter.
 */

#include <stdint.h>

float roundf(float x)
{
    union { float f; uint32_t i; } u = { x };
    int e = (u.i >> 23) & 0xff;

    if (e >= 0x7f + 23) return x; /* integral, infinite or NaN */
    if (e < 0x7f - 1) {           /* |x| < 0.5 */
        u.i &= 0x80000000;
        return u.f;
    }
    if (e == 0x7f - 1) {          /* 0.5 <= |x| < 1 */
        u.i = (u.i & 0x80000000) | 0x3f800000;
        return u.f;
    }
    /* Add a half at the lowest integer bit, then drop the fraction; a
     * carry into the exponent is the right answer (1.5 -> 2). */
    uint32_t frac = 0x007fffff >> (e - 0x7f);
    u.i += 0x00400000 >> (e - 0x7f);
    u.i &= ~frac;
    return u.f;
}
