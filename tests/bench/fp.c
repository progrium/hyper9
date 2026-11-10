// Double-precision arithmetic: a Leibniz series and a Newton square root,
// adds, multiplies, divides, and conversions.
typedef unsigned int u32;

u32 compute(void) {
    double s = 0, sign = 1;
    for (u32 i = 0; i < 4000000; i++) {
        s += sign / (2.0 * i + 1.0);
        sign = -sign;
    }
    double r = 0;
    for (u32 i = 1; i < 200000; i++) {
        double x = i, g = x / 2 + 1;
        for (int k = 0; k < 6; k++) g = 0.5 * (g + x / g);
        r += g;
    }
    return (u32)(int)(s * 1e8) ^ (u32)(int)r;
}
