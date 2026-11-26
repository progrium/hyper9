/*
 * What the kernel's Zig takes from the host's C library through
 * src/kern/port.h: glue.zig's host user and timer, on POSIX hosts.
 */
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <pwd.h>
