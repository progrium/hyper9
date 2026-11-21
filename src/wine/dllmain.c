/*
 * winedraw.drv, the PE side of Wine's display driver for Plan 9 draw
 * (design/wine-draw.md). It finds its Unix library the way Wine's own
 * builtin DLLs do (winecrt0's __wine_init_unix_call), registers the
 * driver through it, and starts the two threads that turn /dev/mouse and
 * /dev/kbd into input: they run in the Unix library and return only if
 * the files can't be opened, which is usual in every process but the
 * first, since one reader at a time may have them.
 *
 * Built with zig cc for x86_64-windows-gnu with no C library, so it
 * needs only kernel32; ntdll's two entry points are looked up.
 */

#include <windows.h>

#include "unixlib.h"

typedef UINT64 unixlib_handle_t;
typedef LONG(WINAPI *dispatcher_t)(unixlib_handle_t, unsigned int, void *);
typedef LONG(WINAPI *query_vm_t)(HANDLE, const void *, ULONG, void *, SIZE_T, SIZE_T *);

enum { MemoryWineUnixFuncs = 1000 };

extern IMAGE_DOS_HEADER __ImageBase;

static unixlib_handle_t handle;
static dispatcher_t dispatcher;

static LONG call(unsigned int code, void *args)
{
    return dispatcher(handle, code, args);
}

static DWORD WINAPI mouse_thread(void *arg)
{
    call(winedraw_read_mouse, NULL);
    return 0;
}

static DWORD WINAPI kbd_thread(void *arg)
{
    call(winedraw_read_kbd, NULL);
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    HMODULE ntdll;
    query_vm_t query_vm;
    dispatcher_t *d;
    HANDLE t;

    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    DisableThreadLibraryCalls(instance);
    if (!(ntdll = GetModuleHandleA("ntdll.dll"))) return FALSE;
    query_vm = (query_vm_t)(void *)GetProcAddress(ntdll, "NtQueryVirtualMemory");
    d = (dispatcher_t *)(void *)GetProcAddress(ntdll, "__wine_unix_call_dispatcher");
    if (!query_vm || !d || !*d) return FALSE;
    dispatcher = *d;
    if (query_vm(GetCurrentProcess(), &__ImageBase, MemoryWineUnixFuncs, &handle, sizeof handle, NULL)) return FALSE;
    if (call(winedraw_init, NULL)) return FALSE;
    if ((t = CreateThread(NULL, 0, mouse_thread, NULL, 0, NULL))) CloseHandle(t);
    if ((t = CreateThread(NULL, 0, kbd_thread, NULL, 0, NULL))) CloseHandle(t);
    return TRUE;
}

/* The entry point, with no C runtime to call DllMain for us. */
BOOL WINAPI winedraw_entry(HINSTANCE instance, DWORD reason, void *reserved)
{
    return DllMain(instance, reason, reserved);
}
