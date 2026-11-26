//! The Win32 calls, types, and constants the host devices make and use
//! (src/host/devfs_win32.zig), declared here rather than through
//! translate-c of windows.h, and the host's errors as the kernel's error
//! strings.

const std = @import("std");
const kern = @import("kern");

pub const HANDLE = std.os.windows.HANDLE;
pub const BOOL = c_int;
pub const DWORD = u32;
pub const WCHAR = u16;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xffffffff;
pub const INVALID_SET_FILE_POINTER: DWORD = 0xffffffff;
pub const MAX_PATH = 260;

pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};

pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    dwReserved0: DWORD,
    dwReserved1: DWORD,
    cFileName: [MAX_PATH]WCHAR,
    cAlternateFileName: [14]WCHAR,
};

pub const WIN32_FILE_ATTRIBUTE_DATA = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
};

pub const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    dwVolumeSerialNumber: DWORD,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    nNumberOfLinks: DWORD,
    nFileIndexHigh: DWORD,
    nFileIndexLow: DWORD,
};

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const DELETE: DWORD = 0x00010000;
pub const FILE_READ_ATTRIBUTES: DWORD = 0x0080;
pub const FILE_WRITE_ATTRIBUTES: DWORD = 0x0100;
pub const FILE_SHARE_READ: DWORD = 0x1;
pub const FILE_SHARE_WRITE: DWORD = 0x2;
pub const FILE_SHARE_DELETE: DWORD = 0x4;
pub const CREATE_NEW: DWORD = 1;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_ATTRIBUTE_READONLY: DWORD = 0x1;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const FILE_ATTRIBUTE_REPARSE_POINT: DWORD = 0x400;
pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
pub const FILE_FLAG_OPEN_REPARSE_POINT: DWORD = 0x00200000;
pub const IO_REPARSE_TAG_MOUNT_POINT: DWORD = 0xA0000003;
pub const IO_REPARSE_TAG_SYMLINK: DWORD = 0xA000000C;
pub const FILE_BEGIN: DWORD = 0;
pub const FILE_NAME_NORMALIZED: DWORD = 0;
pub const VOLUME_NAME_DOS: DWORD = 0;
pub const ERROR_ALREADY_EXISTS: DWORD = 183;
pub const CP_UTF8: c_uint = 65001;
pub const GetFileExInfoStandard: c_int = 0;
pub const FileDispositionInfoEx: c_int = 21;

pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn FindClose(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn FindNextFileW(h: HANDLE, wfd: *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLogicalDriveStringsW(n: DWORD, buf: [*]WCHAR) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetFileAttributesExW(path: [*:0]const WCHAR, level: c_int, info: *WIN32_FILE_ATTRIBUTE_DATA) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetVolumeInformationW(root: [*:0]const WCHAR, name: ?[*]WCHAR, nname: DWORD, serial: ?*DWORD, complen: ?*DWORD, flags: ?*DWORD, fsname: ?[*]WCHAR, nfsname: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(h: HANDLE, buf: ?*anyopaque, n: DWORD, got: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(h: HANDLE, buf: ?*const anyopaque, n: DWORD, put: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetFilePointer(h: HANDLE, lo: i32, hi: ?*i32, how: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn SetFilePointerEx(h: HANDLE, off: i64, new: ?*i64, how: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetEndOfFile(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetFileTime(h: HANDLE, create: ?*const FILETIME, access: ?*const FILETIME, write: ?*const FILETIME) callconv(.winapi) BOOL;
pub extern "kernel32" fn FlushFileBuffers(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileInformationByHandle(h: HANDLE, info: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetFileInformationByHandle(h: HANDLE, class: c_int, info: *const anyopaque, n: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFinalPathNameByHandleW(h: HANDLE, buf: [*]WCHAR, n: DWORD, flags: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn MultiByteToWideChar(cp: c_uint, flags: DWORD, s: [*]const u8, n: c_int, w: ?[*]WCHAR, nw: c_int) callconv(.winapi) c_int;
pub extern "kernel32" fn WideCharToMultiByte(cp: c_uint, flags: DWORD, w: [*]const WCHAR, nw: c_int, s: ?[*]u8, n: c_int, def: ?[*]const u8, used: ?*BOOL) callconv(.winapi) c_int;
pub extern "kernel32" fn FormatMessageA(flags: DWORD, src: ?*const anyopaque, id: DWORD, lang: DWORD, buf: [*]u8, n: DWORD, args: ?*anyopaque) callconv(.winapi) DWORD;

// src/host/hostsock-win32.c: a socket error as a POSIX host names it.
extern fn h9so_errstr(e: c_int) ?[*:0]const u8;

const FORMAT_MESSAGE_FROM_SYSTEM: DWORD = 0x1000;

/// The host's last error as the process's error string (drawterm's
/// oserrstr, with h9's changes): a socket error reads as it does on a
/// POSIX host, and a system message loses its line breaks and its
/// sentence's period.
pub fn oserr() error{Kernel} {
    const e = GetLastError();
    const p: [*]u8 = kern.up().errstr;
    const max: usize = kern.ERRMAX;
    if (h9so_errstr(@bitCast(e))) |s| {
        kern.chan.kstrcpy(p, s, kern.ERRMAX);
        return error.Kernel;
    }
    const r = FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM, null, e, 0x400, p, @intCast(max), null);
    if (r == 0) {
        const m = std.fmt.bufPrint(p[0 .. max - 1], "windows error {d}", .{e}) catch p[0..0];
        p[m.len] = 0;
        return error.Kernel;
    }
    var q: usize = 0;
    var i: usize = 0;
    while (i < max and p[i] != 0) : (i += 1) {
        if (p[i] == '\r') continue;
        p[q] = if (p[i] == '\n') ' ' else p[i];
        q += 1;
    }
    while (q > 0 and (p[q - 1] == ' ' or p[q - 1] == '.')) q -= 1;
    p[q] = 0;
    return error.Kernel;
}

fn c_oserrstr() callconv(.c) void {
    oserr() catch {};
}

/// oserr for the host's C (src/host/hostsock.h's oserrstr and oserror).
pub fn exportC() void {
    @export(&c_oserrstr, .{ .name = "h9_oserrstr" });
}
