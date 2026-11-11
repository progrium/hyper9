/*
 * macOS --gfx (design/gfx.md): closing the window or choosing Quit
 * ends AppKit, which calls exit itself. h9 observes the app's termination
 * instead, and src/gfx.zig's handler takes it through the machine's
 * hangup path and exits with the run's status, as the Windows console's
 * close handler does.
 */
#import <Cocoa/Cocoa.h>

/* Set by src/gfx.zig; doesn't return. */
void (*h9_gfx_onterminate)(void);

/* Called on the main thread before AppKit runs (guimain). */
void
h9_gfx_cocoa_observe(void)
{
	[[NSNotificationCenter defaultCenter]
		addObserverForName:NSApplicationWillTerminateNotification
		object:nil
		queue:nil
		usingBlock:^(NSNotification *n){
			(void)n;
			if(h9_gfx_onterminate != NULL)
				h9_gfx_onterminate();
		}];
}
