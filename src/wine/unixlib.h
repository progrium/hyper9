/* The calls winedraw.drv (PE) makes into winedraw.so (Unix). */

#ifndef WINEDRAW_UNIXLIB_H
#define WINEDRAW_UNIXLIB_H

enum winedraw_funcs
{
    winedraw_init,
    winedraw_read_mouse,
    winedraw_read_kbd,
    winedraw_func_count,
};

#endif
