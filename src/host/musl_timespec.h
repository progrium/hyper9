/*
 * musl declares struct timespec with unnamed bit-fields, padding tv_nsec
 * out to time_t's width where long is narrower, and Zig's translate-c
 * turns any struct with a bit-field into an opaque type. That makes
 * struct timespec opaque, and struct stat with it, on every musl target,
 * though on a 64-bit one the padding is zero wide (issue 351). So for
 * translate-c on musl (build.zig defines H9_MUSL), declare the struct
 * with the same layout and no bit-fields, and tell musl's
 * bits/alltypes.h it's defined. Include this before any system header.
 */
#if defined(H9_MUSL) && !defined(__DEFINED_struct_timespec)
#define __DEFINED_struct_timespec
#if defined(__LP64__) || defined(_LP64)
struct timespec { long tv_sec; long tv_nsec; };
#elif defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
struct timespec { long long tv_sec; int __pad; long tv_nsec; };
#else
struct timespec { long long tv_sec; long tv_nsec; int __pad; };
#endif
#endif
