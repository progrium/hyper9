/*
 * Included ahead of a drawterm GUI backend's own source (build.zig passes
 * it with -include), so the vendored files compile unmodified
 * (design/epoch-0/gfx.md):
 *
 * - The backend's side of drawterm's screen interface (screeninit,
 *   attachscreen, flushmemscreen, screensize, getcolor, setcolor,
 *   setcursor, mouseset, clipread and clipwrite) is renamed h9_gui_*, so
 *   src/kern/gfx.c can wrap it, and the headless screen
 *   (src/host/gfx-headless.c, design/epoch-0/headless-screen.md) can link beside
 *   it: gfx.c calls one or the other, by the screen the machine asked for.
 *   It wraps screeninit to start the backend's kprocs outside the guest's
 *   namespace and keep kernel prints on the host terminal, and the
 *   clipboard for --gfx=noclip. Its keys go to h9_kbdkey, which serves
 *   them on /dev/kbd as kbdfs would.
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
#define attachscreen h9_gui_attachscreen
#define flushmemscreen h9_gui_flushmemscreen
#define screensize h9_gui_screensize
#define getcolor h9_gui_getcolor
#define setcolor h9_gui_setcolor
#define setcursor h9_gui_setcursor
#define mouseset h9_gui_mouseset
#define clipread h9_gui_clipread
#define clipwrite h9_gui_clipwrite
#define kbdkey h9_kbdkey

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
