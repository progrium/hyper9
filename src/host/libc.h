/*
 * What the host devices' Zig (src/host/devfs.zig and the rest) sees of
 * the host's C library, through translate-c for the target, so struct
 * stat, struct dirent, and the open flags are the C library's own on
 * every POSIX host and on WASI. Windows declares its calls in Zig.
 */
#ifndef _WIN32
#define _FILE_OFFSET_BITS 64
#include "musl_timespec.h"
#ifndef __APPLE__
#define _GNU_SOURCE 1
#endif
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <dirent.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <limits.h>
#endif
