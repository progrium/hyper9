/*
 * An empty library named win32u.so, linked against only so that
 * winedraw.so lists win32u.so as needed: Wine loads a driver's Unix
 * library with its own dependencies in scope, and the driver calls
 * win32u's Unix side (NtUser*, window_surface_*). The symbols are left
 * undefined at link time and found in Wine's own win32u.so when the
 * driver is loaded, so h9's build needs no Wine binaries.
 */
