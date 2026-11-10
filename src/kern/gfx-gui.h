/*
 * Included ahead of a drawterm GUI backend's own source (build.zig passes
 * it with -include), so the vendored files compile unmodified
 * (design/0015-gfx.md):
 *
 * - The backend's screeninit, clipread and clipwrite (and on X11,
 *   setcursor and mouseset) are renamed, so
 *   src/kern/gfx.c can wrap them: screeninit to start the backend's
 *   kprocs outside the guest's namespace and keep kernel prints on the
 *   host terminal, and the clipboard for --gfx=noclip. Its keys go
 *   to h9_kbdkey, which serves them on /dev/kbd as kbdfs would.
 * - With H9_GUI_EXIT, the backend's process exits (exit on X11,
 *   ExitProcess on Win32) go to h9_gfx_exit, which takes a closed window
 *   through the machine's hangup path. Win32's FreeConsole would detach
 *   h9 from its terminal, which stays the console, so it does nothing.
 *
 * The exit redirections are function-like and defined after the system
 * headers, so the headers' own declarations (Windows' are dllimport)
 * keep their names.
 */

#define screeninit h9_gui_screeninit
#define clipread h9_gui_clipread
#define clipwrite h9_gui_clipwrite
#define kbdkey h9_kbdkey

/*
 * X11 opens its display in screeninit, but a guest can bind #m before its
 * first attach of #i, and devmouse's attach sets the cursor: gfx.c skips
 * the cursor calls until the screen is open, then sets it.
 */
#ifdef H9_GFX_X11
#define setcursor h9_gui_setcursor
#define mouseset h9_gui_mouseset
#endif

#ifdef H9_GUI_EXIT
#ifdef WINDOWS
#define _WIN32_WINNT 0x0500	/* gui-win32/screen.c's own value */
#include <windows.h>
#define ExitProcess(n) h9_gfx_exit(n)
#define FreeConsole() TRUE
#else
#include <stdlib.h>
#define exit(n) h9_gfx_exit(n)
#endif
extern void h9_gfx_exit(int) __attribute__((noreturn));
#endif
