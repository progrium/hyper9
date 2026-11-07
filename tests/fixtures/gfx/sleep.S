// Sleeps for a minute, for the window to be closed (tests/backends.zig,
// design/0015-gfx.md).

#include "lib.S"

	LI x1, 60000
	SYS 17			// sleep
	b ok
