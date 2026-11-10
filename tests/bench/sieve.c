// Sieve of Eratosthenes over 4 million bytes: byte loads and stores.
typedef unsigned int u32;

#define N (4 << 20)

u32 compute(void) {
    unsigned char a[N];
    for (u32 i = 0; i < N; i++) a[i] = 1;
    a[0] = a[1] = 0;
    for (u32 i = 2; i * i < N; i++)
        if (a[i])
            for (u32 j = i * i; j < N; j += i) a[j] = 0;
    u32 n = 0;
    for (u32 i = 0; i < N; i++) n += a[i];
    return n;
}
