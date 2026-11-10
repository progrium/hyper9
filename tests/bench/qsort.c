// Quicksort of 500,000 pseudo-random words: compares, swaps, and recursion.
typedef unsigned int u32;

static void sort(u32 *a, int lo, int hi) {
    while (lo < hi) {
        u32 p = a[lo + (hi - lo) / 2];
        int i = lo, j = hi;
        while (i <= j) {
            while (a[i] < p) i++;
            while (a[j] > p) j--;
            if (i <= j) {
                u32 t = a[i];
                a[i] = a[j];
                a[j] = t;
                i++;
                j--;
            }
        }
        // The smaller side recursively, so the stack stays shallow.
        if (j - lo < hi - i) {
            sort(a, lo, j);
            lo = i;
        } else {
            sort(a, i, hi);
            hi = j;
        }
    }
}

#define N 500000

u32 compute(void) {
    u32 a[N];
    u32 x = 1;
    for (u32 i = 0; i < N; i++) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        a[i] = x;
    }
    sort(a, 0, N - 1);
    u32 h = 0;
    for (u32 i = 0; i < N; i++) {
        if (i > 0 && a[i - 1] > a[i]) return 0;
        h = h * 31 + a[i];
    }
    return h;
}
