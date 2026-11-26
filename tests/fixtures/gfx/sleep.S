// Sleeps for a minute, for the window to be closed (tests/engines.zig,
// design/epoch-0/gfx.md).

#include "lib.S"

	LI x1, 60000
	SYS 17			// sleep
	b ok
