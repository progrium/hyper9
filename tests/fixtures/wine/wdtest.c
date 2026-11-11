/*
 * wdtest.exe: a Win32 program for the wine-draw cases (design/wine-draw.md),
 * built with zig cc for x86_64-windows-gnu and run under Wine on h9's
 * Linux personality. It opens a window at (100,100), 300x200, whose
 * client area is red. A click turns it green and prints "click X Y"
 * (client coordinates); a typed character prints "char C", and 'q' closes
 * the window and ends the program.
 */

#include <stdio.h>
#include <windows.h>

static COLORREF color = RGB(255, 0, 0);

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_PAINT: {
        PAINTSTRUCT ps;
        RECT r;
        HDC dc = BeginPaint(hwnd, &ps);
        HBRUSH b = CreateSolidBrush(color);
        GetClientRect(hwnd, &r);
        FillRect(dc, &r, b);
        DeleteObject(b);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_LBUTTONDOWN:
        printf("click %d %d\n", (short)LOWORD(lp), (short)HIWORD(lp));
        fflush(stdout);
        color = RGB(0, 255, 0);
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    case WM_CHAR:
        printf("char %c\n", (char)wp);
        fflush(stdout);
        if (wp == 'q') DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

int main(void)
{
    WNDCLASSA wc = { 0 };
    MSG m;
    HWND hwnd;

    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.lpszClassName = "wdtest";
    if (!RegisterClassA(&wc)) return 1;
    hwnd = CreateWindowA("wdtest", "wdtest", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 300, 200, NULL, NULL,
                         wc.hInstance, NULL);
    if (!hwnd) return 1;
    SetForegroundWindow(hwnd);
    printf("ready\n");
    fflush(stdout);
    while (GetMessageA(&m, NULL, 0, 0) > 0) {
        TranslateMessage(&m);
        DispatchMessageA(&m);
    }
    return 0;
}
