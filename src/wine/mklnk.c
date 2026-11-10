/*
 * mklnk: makes a Windows shortcut (.lnk), for the web demo's Wine prefix
 * (scripts/wine-web.sh): Wine's desktop and Start menu list the
 * shortcuts in their folders.
 *
 *   mklnk FILE.lnk TARGET [DESCRIPTION [ICONFILE ICONINDEX]]
 *
 * It makes FILE's directory if it isn't there. The icon is TARGET's
 * first unless ICONFILE gives another, as a resource id when ICONINDEX
 * is negative: Wine's desktop leaves out a shortcut without an icon.
 */

#define COBJMACROS
#include <windows.h>
#include <shlobj.h>
#include <stdio.h>

int wmain(int argc, wchar_t **argv)
{
    IShellLinkW *link;
    IPersistFile *file;
    wchar_t dir[MAX_PATH], *slash;
    HRESULT hr;

    if (argc < 3) {
        fprintf(stderr, "usage: mklnk FILE.lnk TARGET [DESCRIPTION [ICONFILE ICONINDEX]]\n");
        return 2;
    }
    lstrcpynW(dir, argv[1], MAX_PATH);
    if ((slash = wcsrchr(dir, '\\'))) {
        *slash = 0;
        SHCreateDirectoryExW(NULL, dir, NULL);
    }
    CoInitialize(NULL);
    hr = CoCreateInstance(&CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, (void **)&link);
    if (FAILED(hr)) goto fail;
    IShellLinkW_SetPath(link, argv[2]);
    if (argc > 5) IShellLinkW_SetIconLocation(link, argv[4], _wtoi(argv[5]));
    else IShellLinkW_SetIconLocation(link, argv[2], 0);
    if (argc > 3) IShellLinkW_SetDescription(link, argv[3]);
    hr = IShellLinkW_QueryInterface(link, &IID_IPersistFile, (void **)&file);
    if (FAILED(hr)) goto fail;
    hr = IPersistFile_Save(file, argv[1], TRUE);
    if (FAILED(hr)) goto fail;
    IPersistFile_Release(file);
    IShellLinkW_Release(link);
    return 0;
fail:
    fprintf(stderr, "mklnk: %ls: error %08lx\n", argv[1], (unsigned long)hr);
    return 1;
}
