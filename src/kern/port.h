/*
 * What the kernel's Zig (src/kern/port.zig) sees of its C, through
 * translate-c with the kernel's own flags: the types and functions of
 * drawterm's kern and h9's additions, so structure layouts are the C
 * compiler's on every target.
 */
#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#include "tsleep.h"
#include "devx.h"
