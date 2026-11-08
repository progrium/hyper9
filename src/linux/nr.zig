//! Linux syscall numbers for arm64 (the generic table) and amd64, from the
//! kernel's headers (include/uapi/asm-generic/unistd.h and
//! arch/x86/entry/syscalls/syscall_64.tbl). Generated; see
//! design/0018-linux-personality.md.

const std = @import("std");

/// Every call either architecture has, by name.
pub const Sys = enum(u16) {
    _sysctl,
    accept,
    accept4,
    access,
    acct,
    add_key,
    adjtimex,
    afs_syscall,
    alarm,
    arch_prctl,
    arch_specific_syscall,
    bind,
    bpf,
    brk,
    cachestat,
    capget,
    capset,
    chdir,
    chmod,
    chown,
    chroot,
    clock_adjtime,
    clock_getres,
    clock_gettime,
    clock_nanosleep,
    clock_settime,
    clone,
    clone3,
    close,
    close_range,
    connect,
    copy_file_range,
    creat,
    create_module,
    delete_module,
    dup,
    dup2,
    dup3,
    epoll_create,
    epoll_create1,
    epoll_ctl,
    epoll_ctl_old,
    epoll_pwait,
    epoll_pwait2,
    epoll_wait,
    epoll_wait_old,
    eventfd,
    eventfd2,
    execve,
    execveat,
    exit,
    exit_group,
    faccessat,
    faccessat2,
    fadvise64,
    fallocate,
    fanotify_init,
    fanotify_mark,
    fchdir,
    fchmod,
    fchmodat,
    fchmodat2,
    fchown,
    fchownat,
    fcntl,
    fdatasync,
    fgetxattr,
    finit_module,
    flistxattr,
    flock,
    fork,
    fremovexattr,
    fsconfig,
    fsetxattr,
    fsmount,
    fsopen,
    fspick,
    fstat,
    fstatfs,
    fsync,
    ftruncate,
    futex,
    futex_requeue,
    futex_wait,
    futex_waitv,
    futex_wake,
    futimesat,
    get_kernel_syms,
    get_mempolicy,
    get_robust_list,
    get_thread_area,
    getcpu,
    getcwd,
    getdents,
    getdents64,
    getegid,
    geteuid,
    getgid,
    getgroups,
    getitimer,
    getpeername,
    getpgid,
    getpgrp,
    getpid,
    getpmsg,
    getppid,
    getpriority,
    getrandom,
    getresgid,
    getresuid,
    getrlimit,
    getrusage,
    getsid,
    getsockname,
    getsockopt,
    gettid,
    gettimeofday,
    getuid,
    getxattr,
    init_module,
    inotify_add_watch,
    inotify_init,
    inotify_init1,
    inotify_rm_watch,
    io_cancel,
    io_destroy,
    io_getevents,
    io_pgetevents,
    io_setup,
    io_submit,
    io_uring_enter,
    io_uring_register,
    io_uring_setup,
    ioctl,
    ioperm,
    iopl,
    ioprio_get,
    ioprio_set,
    kcmp,
    kexec_file_load,
    kexec_load,
    keyctl,
    kill,
    landlock_add_rule,
    landlock_create_ruleset,
    landlock_restrict_self,
    lchown,
    lgetxattr,
    link,
    linkat,
    listen,
    listmount,
    listxattr,
    llistxattr,
    lookup_dcookie,
    lremovexattr,
    lseek,
    lsetxattr,
    lsm_get_self_attr,
    lsm_list_modules,
    lsm_set_self_attr,
    lstat,
    madvise,
    map_shadow_stack,
    mbind,
    membarrier,
    memfd_create,
    memfd_secret,
    migrate_pages,
    mincore,
    mkdir,
    mkdirat,
    mknod,
    mknodat,
    mlock,
    mlock2,
    mlockall,
    mmap,
    modify_ldt,
    mount,
    mount_setattr,
    move_mount,
    move_pages,
    mprotect,
    mq_getsetattr,
    mq_notify,
    mq_open,
    mq_timedreceive,
    mq_timedsend,
    mq_unlink,
    mremap,
    msgctl,
    msgget,
    msgrcv,
    msgsnd,
    msync,
    munlock,
    munlockall,
    munmap,
    name_to_handle_at,
    nanosleep,
    newfstatat,
    nfsservctl,
    open,
    open_by_handle_at,
    open_tree,
    openat,
    openat2,
    pause,
    perf_event_open,
    personality,
    pidfd_getfd,
    pidfd_open,
    pidfd_send_signal,
    pipe,
    pipe2,
    pivot_root,
    pkey_alloc,
    pkey_free,
    pkey_mprotect,
    poll,
    ppoll,
    prctl,
    pread64,
    preadv,
    preadv2,
    prlimit64,
    process_madvise,
    process_mrelease,
    process_vm_readv,
    process_vm_writev,
    pselect6,
    ptrace,
    putpmsg,
    pwrite64,
    pwritev,
    pwritev2,
    query_module,
    quotactl,
    quotactl_fd,
    read,
    readahead,
    readlink,
    readlinkat,
    readv,
    reboot,
    recvfrom,
    recvmmsg,
    recvmsg,
    remap_file_pages,
    removexattr,
    rename,
    renameat,
    renameat2,
    request_key,
    restart_syscall,
    rmdir,
    rseq,
    rt_sigaction,
    rt_sigpending,
    rt_sigprocmask,
    rt_sigqueueinfo,
    rt_sigreturn,
    rt_sigsuspend,
    rt_sigtimedwait,
    rt_tgsigqueueinfo,
    sched_get_priority_max,
    sched_get_priority_min,
    sched_getaffinity,
    sched_getattr,
    sched_getparam,
    sched_getscheduler,
    sched_rr_get_interval,
    sched_setaffinity,
    sched_setattr,
    sched_setparam,
    sched_setscheduler,
    sched_yield,
    seccomp,
    security,
    @"select",
    semctl,
    semget,
    semop,
    semtimedop,
    sendfile,
    sendmmsg,
    sendmsg,
    sendto,
    set_mempolicy,
    set_mempolicy_home_node,
    set_robust_list,
    set_thread_area,
    set_tid_address,
    setdomainname,
    setfsgid,
    setfsuid,
    setgid,
    setgroups,
    sethostname,
    setitimer,
    setns,
    setpgid,
    setpriority,
    setregid,
    setresgid,
    setresuid,
    setreuid,
    setrlimit,
    setsid,
    setsockopt,
    settimeofday,
    setuid,
    setxattr,
    shmat,
    shmctl,
    shmdt,
    shmget,
    shutdown,
    sigaltstack,
    signalfd,
    signalfd4,
    socket,
    socketpair,
    splice,
    stat,
    statfs,
    statmount,
    statx,
    swapoff,
    swapon,
    symlink,
    symlinkat,
    sync,
    sync_file_range,
    syncfs,
    sysfs,
    sysinfo,
    syslog,
    tee,
    tgkill,
    time,
    timer_create,
    timer_delete,
    timer_getoverrun,
    timer_gettime,
    timer_settime,
    timerfd_create,
    timerfd_gettime,
    timerfd_settime,
    times,
    tkill,
    truncate,
    tuxcall,
    umask,
    umount2,
    uname,
    unlink,
    unlinkat,
    unshare,
    uselib,
    userfaultfd,
    ustat,
    utime,
    utimensat,
    utimes,
    vfork,
    vhangup,
    vmsplice,
    vserver,
    wait4,
    waitid,
    write,
    writev,
    _,
};

/// arm64's numbers, indexed by number; null where there's no call.
pub const arm64 = blk: {
    @setEvalBranchQuota(100000);
    var t: [462]?Sys = @splat(null);
    t[0] = .@"io_setup";
    t[1] = .@"io_destroy";
    t[2] = .@"io_submit";
    t[3] = .@"io_cancel";
    t[4] = .@"io_getevents";
    t[5] = .@"setxattr";
    t[6] = .@"lsetxattr";
    t[7] = .@"fsetxattr";
    t[8] = .@"getxattr";
    t[9] = .@"lgetxattr";
    t[10] = .@"fgetxattr";
    t[11] = .@"listxattr";
    t[12] = .@"llistxattr";
    t[13] = .@"flistxattr";
    t[14] = .@"removexattr";
    t[15] = .@"lremovexattr";
    t[16] = .@"fremovexattr";
    t[17] = .@"getcwd";
    t[18] = .@"lookup_dcookie";
    t[19] = .@"eventfd2";
    t[20] = .@"epoll_create1";
    t[21] = .@"epoll_ctl";
    t[22] = .@"epoll_pwait";
    t[23] = .@"dup";
    t[24] = .@"dup3";
    t[25] = .@"fcntl";
    t[26] = .@"inotify_init1";
    t[27] = .@"inotify_add_watch";
    t[28] = .@"inotify_rm_watch";
    t[29] = .@"ioctl";
    t[30] = .@"ioprio_set";
    t[31] = .@"ioprio_get";
    t[32] = .@"flock";
    t[33] = .@"mknodat";
    t[34] = .@"mkdirat";
    t[35] = .@"unlinkat";
    t[36] = .@"symlinkat";
    t[37] = .@"linkat";
    t[38] = .@"renameat";
    t[39] = .@"umount2";
    t[40] = .@"mount";
    t[41] = .@"pivot_root";
    t[42] = .@"nfsservctl";
    t[43] = .@"statfs";
    t[44] = .@"fstatfs";
    t[45] = .@"truncate";
    t[46] = .@"ftruncate";
    t[47] = .@"fallocate";
    t[48] = .@"faccessat";
    t[49] = .@"chdir";
    t[50] = .@"fchdir";
    t[51] = .@"chroot";
    t[52] = .@"fchmod";
    t[53] = .@"fchmodat";
    t[54] = .@"fchownat";
    t[55] = .@"fchown";
    t[56] = .@"openat";
    t[57] = .@"close";
    t[58] = .@"vhangup";
    t[59] = .@"pipe2";
    t[60] = .@"quotactl";
    t[61] = .@"getdents64";
    t[62] = .@"lseek";
    t[63] = .@"read";
    t[64] = .@"write";
    t[65] = .@"readv";
    t[66] = .@"writev";
    t[67] = .@"pread64";
    t[68] = .@"pwrite64";
    t[69] = .@"preadv";
    t[70] = .@"pwritev";
    t[71] = .@"sendfile";
    t[72] = .@"pselect6";
    t[73] = .@"ppoll";
    t[74] = .@"signalfd4";
    t[75] = .@"vmsplice";
    t[76] = .@"splice";
    t[77] = .@"tee";
    t[78] = .@"readlinkat";
    t[79] = .@"newfstatat";
    t[80] = .@"fstat";
    t[81] = .@"sync";
    t[82] = .@"fsync";
    t[83] = .@"fdatasync";
    t[84] = .@"sync_file_range";
    t[85] = .@"timerfd_create";
    t[86] = .@"timerfd_settime";
    t[87] = .@"timerfd_gettime";
    t[88] = .@"utimensat";
    t[89] = .@"acct";
    t[90] = .@"capget";
    t[91] = .@"capset";
    t[92] = .@"personality";
    t[93] = .@"exit";
    t[94] = .@"exit_group";
    t[95] = .@"waitid";
    t[96] = .@"set_tid_address";
    t[97] = .@"unshare";
    t[98] = .@"futex";
    t[99] = .@"set_robust_list";
    t[100] = .@"get_robust_list";
    t[101] = .@"nanosleep";
    t[102] = .@"getitimer";
    t[103] = .@"setitimer";
    t[104] = .@"kexec_load";
    t[105] = .@"init_module";
    t[106] = .@"delete_module";
    t[107] = .@"timer_create";
    t[108] = .@"timer_gettime";
    t[109] = .@"timer_getoverrun";
    t[110] = .@"timer_settime";
    t[111] = .@"timer_delete";
    t[112] = .@"clock_settime";
    t[113] = .@"clock_gettime";
    t[114] = .@"clock_getres";
    t[115] = .@"clock_nanosleep";
    t[116] = .@"syslog";
    t[117] = .@"ptrace";
    t[118] = .@"sched_setparam";
    t[119] = .@"sched_setscheduler";
    t[120] = .@"sched_getscheduler";
    t[121] = .@"sched_getparam";
    t[122] = .@"sched_setaffinity";
    t[123] = .@"sched_getaffinity";
    t[124] = .@"sched_yield";
    t[125] = .@"sched_get_priority_max";
    t[126] = .@"sched_get_priority_min";
    t[127] = .@"sched_rr_get_interval";
    t[128] = .@"restart_syscall";
    t[129] = .@"kill";
    t[130] = .@"tkill";
    t[131] = .@"tgkill";
    t[132] = .@"sigaltstack";
    t[133] = .@"rt_sigsuspend";
    t[134] = .@"rt_sigaction";
    t[135] = .@"rt_sigprocmask";
    t[136] = .@"rt_sigpending";
    t[137] = .@"rt_sigtimedwait";
    t[138] = .@"rt_sigqueueinfo";
    t[139] = .@"rt_sigreturn";
    t[140] = .@"setpriority";
    t[141] = .@"getpriority";
    t[142] = .@"reboot";
    t[143] = .@"setregid";
    t[144] = .@"setgid";
    t[145] = .@"setreuid";
    t[146] = .@"setuid";
    t[147] = .@"setresuid";
    t[148] = .@"getresuid";
    t[149] = .@"setresgid";
    t[150] = .@"getresgid";
    t[151] = .@"setfsuid";
    t[152] = .@"setfsgid";
    t[153] = .@"times";
    t[154] = .@"setpgid";
    t[155] = .@"getpgid";
    t[156] = .@"getsid";
    t[157] = .@"setsid";
    t[158] = .@"getgroups";
    t[159] = .@"setgroups";
    t[160] = .@"uname";
    t[161] = .@"sethostname";
    t[162] = .@"setdomainname";
    t[163] = .@"getrlimit";
    t[164] = .@"setrlimit";
    t[165] = .@"getrusage";
    t[166] = .@"umask";
    t[167] = .@"prctl";
    t[168] = .@"getcpu";
    t[169] = .@"gettimeofday";
    t[170] = .@"settimeofday";
    t[171] = .@"adjtimex";
    t[172] = .@"getpid";
    t[173] = .@"getppid";
    t[174] = .@"getuid";
    t[175] = .@"geteuid";
    t[176] = .@"getgid";
    t[177] = .@"getegid";
    t[178] = .@"gettid";
    t[179] = .@"sysinfo";
    t[180] = .@"mq_open";
    t[181] = .@"mq_unlink";
    t[182] = .@"mq_timedsend";
    t[183] = .@"mq_timedreceive";
    t[184] = .@"mq_notify";
    t[185] = .@"mq_getsetattr";
    t[186] = .@"msgget";
    t[187] = .@"msgctl";
    t[188] = .@"msgrcv";
    t[189] = .@"msgsnd";
    t[190] = .@"semget";
    t[191] = .@"semctl";
    t[192] = .@"semtimedop";
    t[193] = .@"semop";
    t[194] = .@"shmget";
    t[195] = .@"shmctl";
    t[196] = .@"shmat";
    t[197] = .@"shmdt";
    t[198] = .@"socket";
    t[199] = .@"socketpair";
    t[200] = .@"bind";
    t[201] = .@"listen";
    t[202] = .@"accept";
    t[203] = .@"connect";
    t[204] = .@"getsockname";
    t[205] = .@"getpeername";
    t[206] = .@"sendto";
    t[207] = .@"recvfrom";
    t[208] = .@"setsockopt";
    t[209] = .@"getsockopt";
    t[210] = .@"shutdown";
    t[211] = .@"sendmsg";
    t[212] = .@"recvmsg";
    t[213] = .@"readahead";
    t[214] = .@"brk";
    t[215] = .@"munmap";
    t[216] = .@"mremap";
    t[217] = .@"add_key";
    t[218] = .@"request_key";
    t[219] = .@"keyctl";
    t[220] = .@"clone";
    t[221] = .@"execve";
    t[222] = .@"mmap";
    t[223] = .@"fadvise64";
    t[224] = .@"swapon";
    t[225] = .@"swapoff";
    t[226] = .@"mprotect";
    t[227] = .@"msync";
    t[228] = .@"mlock";
    t[229] = .@"munlock";
    t[230] = .@"mlockall";
    t[231] = .@"munlockall";
    t[232] = .@"mincore";
    t[233] = .@"madvise";
    t[234] = .@"remap_file_pages";
    t[235] = .@"mbind";
    t[236] = .@"get_mempolicy";
    t[237] = .@"set_mempolicy";
    t[238] = .@"migrate_pages";
    t[239] = .@"move_pages";
    t[240] = .@"rt_tgsigqueueinfo";
    t[241] = .@"perf_event_open";
    t[242] = .@"accept4";
    t[243] = .@"recvmmsg";
    t[244] = .@"arch_specific_syscall";
    t[260] = .@"wait4";
    t[261] = .@"prlimit64";
    t[262] = .@"fanotify_init";
    t[263] = .@"fanotify_mark";
    t[264] = .@"name_to_handle_at";
    t[265] = .@"open_by_handle_at";
    t[266] = .@"clock_adjtime";
    t[267] = .@"syncfs";
    t[268] = .@"setns";
    t[269] = .@"sendmmsg";
    t[270] = .@"process_vm_readv";
    t[271] = .@"process_vm_writev";
    t[272] = .@"kcmp";
    t[273] = .@"finit_module";
    t[274] = .@"sched_setattr";
    t[275] = .@"sched_getattr";
    t[276] = .@"renameat2";
    t[277] = .@"seccomp";
    t[278] = .@"getrandom";
    t[279] = .@"memfd_create";
    t[280] = .@"bpf";
    t[281] = .@"execveat";
    t[282] = .@"userfaultfd";
    t[283] = .@"membarrier";
    t[284] = .@"mlock2";
    t[285] = .@"copy_file_range";
    t[286] = .@"preadv2";
    t[287] = .@"pwritev2";
    t[288] = .@"pkey_mprotect";
    t[289] = .@"pkey_alloc";
    t[290] = .@"pkey_free";
    t[291] = .@"statx";
    t[292] = .@"io_pgetevents";
    t[293] = .@"rseq";
    t[294] = .@"kexec_file_load";
    t[424] = .@"pidfd_send_signal";
    t[425] = .@"io_uring_setup";
    t[426] = .@"io_uring_enter";
    t[427] = .@"io_uring_register";
    t[428] = .@"open_tree";
    t[429] = .@"move_mount";
    t[430] = .@"fsopen";
    t[431] = .@"fsconfig";
    t[432] = .@"fsmount";
    t[433] = .@"fspick";
    t[434] = .@"pidfd_open";
    t[435] = .@"clone3";
    t[436] = .@"close_range";
    t[437] = .@"openat2";
    t[438] = .@"pidfd_getfd";
    t[439] = .@"faccessat2";
    t[440] = .@"process_madvise";
    t[441] = .@"epoll_pwait2";
    t[442] = .@"mount_setattr";
    t[443] = .@"quotactl_fd";
    t[444] = .@"landlock_create_ruleset";
    t[445] = .@"landlock_add_rule";
    t[446] = .@"landlock_restrict_self";
    t[448] = .@"process_mrelease";
    t[449] = .@"futex_waitv";
    t[450] = .@"set_mempolicy_home_node";
    t[451] = .@"cachestat";
    t[452] = .@"fchmodat2";
    t[453] = .@"map_shadow_stack";
    t[454] = .@"futex_wake";
    t[455] = .@"futex_wait";
    t[456] = .@"futex_requeue";
    t[457] = .@"statmount";
    t[458] = .@"listmount";
    t[459] = .@"lsm_get_self_attr";
    t[460] = .@"lsm_set_self_attr";
    t[461] = .@"lsm_list_modules";
    break :blk t;
};

/// amd64's numbers, indexed by number; null where there's no call.
pub const amd64 = blk: {
    @setEvalBranchQuota(100000);
    var t: [462]?Sys = @splat(null);
    t[0] = .@"read";
    t[1] = .@"write";
    t[2] = .@"open";
    t[3] = .@"close";
    t[4] = .@"stat";
    t[5] = .@"fstat";
    t[6] = .@"lstat";
    t[7] = .@"poll";
    t[8] = .@"lseek";
    t[9] = .@"mmap";
    t[10] = .@"mprotect";
    t[11] = .@"munmap";
    t[12] = .@"brk";
    t[13] = .@"rt_sigaction";
    t[14] = .@"rt_sigprocmask";
    t[15] = .@"rt_sigreturn";
    t[16] = .@"ioctl";
    t[17] = .@"pread64";
    t[18] = .@"pwrite64";
    t[19] = .@"readv";
    t[20] = .@"writev";
    t[21] = .@"access";
    t[22] = .@"pipe";
    t[23] = .@"select";
    t[24] = .@"sched_yield";
    t[25] = .@"mremap";
    t[26] = .@"msync";
    t[27] = .@"mincore";
    t[28] = .@"madvise";
    t[29] = .@"shmget";
    t[30] = .@"shmat";
    t[31] = .@"shmctl";
    t[32] = .@"dup";
    t[33] = .@"dup2";
    t[34] = .@"pause";
    t[35] = .@"nanosleep";
    t[36] = .@"getitimer";
    t[37] = .@"alarm";
    t[38] = .@"setitimer";
    t[39] = .@"getpid";
    t[40] = .@"sendfile";
    t[41] = .@"socket";
    t[42] = .@"connect";
    t[43] = .@"accept";
    t[44] = .@"sendto";
    t[45] = .@"recvfrom";
    t[46] = .@"sendmsg";
    t[47] = .@"recvmsg";
    t[48] = .@"shutdown";
    t[49] = .@"bind";
    t[50] = .@"listen";
    t[51] = .@"getsockname";
    t[52] = .@"getpeername";
    t[53] = .@"socketpair";
    t[54] = .@"setsockopt";
    t[55] = .@"getsockopt";
    t[56] = .@"clone";
    t[57] = .@"fork";
    t[58] = .@"vfork";
    t[59] = .@"execve";
    t[60] = .@"exit";
    t[61] = .@"wait4";
    t[62] = .@"kill";
    t[63] = .@"uname";
    t[64] = .@"semget";
    t[65] = .@"semop";
    t[66] = .@"semctl";
    t[67] = .@"shmdt";
    t[68] = .@"msgget";
    t[69] = .@"msgsnd";
    t[70] = .@"msgrcv";
    t[71] = .@"msgctl";
    t[72] = .@"fcntl";
    t[73] = .@"flock";
    t[74] = .@"fsync";
    t[75] = .@"fdatasync";
    t[76] = .@"truncate";
    t[77] = .@"ftruncate";
    t[78] = .@"getdents";
    t[79] = .@"getcwd";
    t[80] = .@"chdir";
    t[81] = .@"fchdir";
    t[82] = .@"rename";
    t[83] = .@"mkdir";
    t[84] = .@"rmdir";
    t[85] = .@"creat";
    t[86] = .@"link";
    t[87] = .@"unlink";
    t[88] = .@"symlink";
    t[89] = .@"readlink";
    t[90] = .@"chmod";
    t[91] = .@"fchmod";
    t[92] = .@"chown";
    t[93] = .@"fchown";
    t[94] = .@"lchown";
    t[95] = .@"umask";
    t[96] = .@"gettimeofday";
    t[97] = .@"getrlimit";
    t[98] = .@"getrusage";
    t[99] = .@"sysinfo";
    t[100] = .@"times";
    t[101] = .@"ptrace";
    t[102] = .@"getuid";
    t[103] = .@"syslog";
    t[104] = .@"getgid";
    t[105] = .@"setuid";
    t[106] = .@"setgid";
    t[107] = .@"geteuid";
    t[108] = .@"getegid";
    t[109] = .@"setpgid";
    t[110] = .@"getppid";
    t[111] = .@"getpgrp";
    t[112] = .@"setsid";
    t[113] = .@"setreuid";
    t[114] = .@"setregid";
    t[115] = .@"getgroups";
    t[116] = .@"setgroups";
    t[117] = .@"setresuid";
    t[118] = .@"getresuid";
    t[119] = .@"setresgid";
    t[120] = .@"getresgid";
    t[121] = .@"getpgid";
    t[122] = .@"setfsuid";
    t[123] = .@"setfsgid";
    t[124] = .@"getsid";
    t[125] = .@"capget";
    t[126] = .@"capset";
    t[127] = .@"rt_sigpending";
    t[128] = .@"rt_sigtimedwait";
    t[129] = .@"rt_sigqueueinfo";
    t[130] = .@"rt_sigsuspend";
    t[131] = .@"sigaltstack";
    t[132] = .@"utime";
    t[133] = .@"mknod";
    t[134] = .@"uselib";
    t[135] = .@"personality";
    t[136] = .@"ustat";
    t[137] = .@"statfs";
    t[138] = .@"fstatfs";
    t[139] = .@"sysfs";
    t[140] = .@"getpriority";
    t[141] = .@"setpriority";
    t[142] = .@"sched_setparam";
    t[143] = .@"sched_getparam";
    t[144] = .@"sched_setscheduler";
    t[145] = .@"sched_getscheduler";
    t[146] = .@"sched_get_priority_max";
    t[147] = .@"sched_get_priority_min";
    t[148] = .@"sched_rr_get_interval";
    t[149] = .@"mlock";
    t[150] = .@"munlock";
    t[151] = .@"mlockall";
    t[152] = .@"munlockall";
    t[153] = .@"vhangup";
    t[154] = .@"modify_ldt";
    t[155] = .@"pivot_root";
    t[156] = .@"_sysctl";
    t[157] = .@"prctl";
    t[158] = .@"arch_prctl";
    t[159] = .@"adjtimex";
    t[160] = .@"setrlimit";
    t[161] = .@"chroot";
    t[162] = .@"sync";
    t[163] = .@"acct";
    t[164] = .@"settimeofday";
    t[165] = .@"mount";
    t[166] = .@"umount2";
    t[167] = .@"swapon";
    t[168] = .@"swapoff";
    t[169] = .@"reboot";
    t[170] = .@"sethostname";
    t[171] = .@"setdomainname";
    t[172] = .@"iopl";
    t[173] = .@"ioperm";
    t[174] = .@"create_module";
    t[175] = .@"init_module";
    t[176] = .@"delete_module";
    t[177] = .@"get_kernel_syms";
    t[178] = .@"query_module";
    t[179] = .@"quotactl";
    t[180] = .@"nfsservctl";
    t[181] = .@"getpmsg";
    t[182] = .@"putpmsg";
    t[183] = .@"afs_syscall";
    t[184] = .@"tuxcall";
    t[185] = .@"security";
    t[186] = .@"gettid";
    t[187] = .@"readahead";
    t[188] = .@"setxattr";
    t[189] = .@"lsetxattr";
    t[190] = .@"fsetxattr";
    t[191] = .@"getxattr";
    t[192] = .@"lgetxattr";
    t[193] = .@"fgetxattr";
    t[194] = .@"listxattr";
    t[195] = .@"llistxattr";
    t[196] = .@"flistxattr";
    t[197] = .@"removexattr";
    t[198] = .@"lremovexattr";
    t[199] = .@"fremovexattr";
    t[200] = .@"tkill";
    t[201] = .@"time";
    t[202] = .@"futex";
    t[203] = .@"sched_setaffinity";
    t[204] = .@"sched_getaffinity";
    t[205] = .@"set_thread_area";
    t[206] = .@"io_setup";
    t[207] = .@"io_destroy";
    t[208] = .@"io_getevents";
    t[209] = .@"io_submit";
    t[210] = .@"io_cancel";
    t[211] = .@"get_thread_area";
    t[212] = .@"lookup_dcookie";
    t[213] = .@"epoll_create";
    t[214] = .@"epoll_ctl_old";
    t[215] = .@"epoll_wait_old";
    t[216] = .@"remap_file_pages";
    t[217] = .@"getdents64";
    t[218] = .@"set_tid_address";
    t[219] = .@"restart_syscall";
    t[220] = .@"semtimedop";
    t[221] = .@"fadvise64";
    t[222] = .@"timer_create";
    t[223] = .@"timer_settime";
    t[224] = .@"timer_gettime";
    t[225] = .@"timer_getoverrun";
    t[226] = .@"timer_delete";
    t[227] = .@"clock_settime";
    t[228] = .@"clock_gettime";
    t[229] = .@"clock_getres";
    t[230] = .@"clock_nanosleep";
    t[231] = .@"exit_group";
    t[232] = .@"epoll_wait";
    t[233] = .@"epoll_ctl";
    t[234] = .@"tgkill";
    t[235] = .@"utimes";
    t[236] = .@"vserver";
    t[237] = .@"mbind";
    t[238] = .@"set_mempolicy";
    t[239] = .@"get_mempolicy";
    t[240] = .@"mq_open";
    t[241] = .@"mq_unlink";
    t[242] = .@"mq_timedsend";
    t[243] = .@"mq_timedreceive";
    t[244] = .@"mq_notify";
    t[245] = .@"mq_getsetattr";
    t[246] = .@"kexec_load";
    t[247] = .@"waitid";
    t[248] = .@"add_key";
    t[249] = .@"request_key";
    t[250] = .@"keyctl";
    t[251] = .@"ioprio_set";
    t[252] = .@"ioprio_get";
    t[253] = .@"inotify_init";
    t[254] = .@"inotify_add_watch";
    t[255] = .@"inotify_rm_watch";
    t[256] = .@"migrate_pages";
    t[257] = .@"openat";
    t[258] = .@"mkdirat";
    t[259] = .@"mknodat";
    t[260] = .@"fchownat";
    t[261] = .@"futimesat";
    t[262] = .@"newfstatat";
    t[263] = .@"unlinkat";
    t[264] = .@"renameat";
    t[265] = .@"linkat";
    t[266] = .@"symlinkat";
    t[267] = .@"readlinkat";
    t[268] = .@"fchmodat";
    t[269] = .@"faccessat";
    t[270] = .@"pselect6";
    t[271] = .@"ppoll";
    t[272] = .@"unshare";
    t[273] = .@"set_robust_list";
    t[274] = .@"get_robust_list";
    t[275] = .@"splice";
    t[276] = .@"tee";
    t[277] = .@"sync_file_range";
    t[278] = .@"vmsplice";
    t[279] = .@"move_pages";
    t[280] = .@"utimensat";
    t[281] = .@"epoll_pwait";
    t[282] = .@"signalfd";
    t[283] = .@"timerfd_create";
    t[284] = .@"eventfd";
    t[285] = .@"fallocate";
    t[286] = .@"timerfd_settime";
    t[287] = .@"timerfd_gettime";
    t[288] = .@"accept4";
    t[289] = .@"signalfd4";
    t[290] = .@"eventfd2";
    t[291] = .@"epoll_create1";
    t[292] = .@"dup3";
    t[293] = .@"pipe2";
    t[294] = .@"inotify_init1";
    t[295] = .@"preadv";
    t[296] = .@"pwritev";
    t[297] = .@"rt_tgsigqueueinfo";
    t[298] = .@"perf_event_open";
    t[299] = .@"recvmmsg";
    t[300] = .@"fanotify_init";
    t[301] = .@"fanotify_mark";
    t[302] = .@"prlimit64";
    t[303] = .@"name_to_handle_at";
    t[304] = .@"open_by_handle_at";
    t[305] = .@"clock_adjtime";
    t[306] = .@"syncfs";
    t[307] = .@"sendmmsg";
    t[308] = .@"setns";
    t[309] = .@"getcpu";
    t[310] = .@"process_vm_readv";
    t[311] = .@"process_vm_writev";
    t[312] = .@"kcmp";
    t[313] = .@"finit_module";
    t[314] = .@"sched_setattr";
    t[315] = .@"sched_getattr";
    t[316] = .@"renameat2";
    t[317] = .@"seccomp";
    t[318] = .@"getrandom";
    t[319] = .@"memfd_create";
    t[320] = .@"kexec_file_load";
    t[321] = .@"bpf";
    t[322] = .@"execveat";
    t[323] = .@"userfaultfd";
    t[324] = .@"membarrier";
    t[325] = .@"mlock2";
    t[326] = .@"copy_file_range";
    t[327] = .@"preadv2";
    t[328] = .@"pwritev2";
    t[329] = .@"pkey_mprotect";
    t[330] = .@"pkey_alloc";
    t[331] = .@"pkey_free";
    t[332] = .@"statx";
    t[333] = .@"io_pgetevents";
    t[334] = .@"rseq";
    t[424] = .@"pidfd_send_signal";
    t[425] = .@"io_uring_setup";
    t[426] = .@"io_uring_enter";
    t[427] = .@"io_uring_register";
    t[428] = .@"open_tree";
    t[429] = .@"move_mount";
    t[430] = .@"fsopen";
    t[431] = .@"fsconfig";
    t[432] = .@"fsmount";
    t[433] = .@"fspick";
    t[434] = .@"pidfd_open";
    t[435] = .@"clone3";
    t[436] = .@"close_range";
    t[437] = .@"openat2";
    t[438] = .@"pidfd_getfd";
    t[439] = .@"faccessat2";
    t[440] = .@"process_madvise";
    t[441] = .@"epoll_pwait2";
    t[442] = .@"mount_setattr";
    t[443] = .@"quotactl_fd";
    t[444] = .@"landlock_create_ruleset";
    t[445] = .@"landlock_add_rule";
    t[446] = .@"landlock_restrict_self";
    t[447] = .@"memfd_secret";
    t[448] = .@"process_mrelease";
    t[449] = .@"futex_waitv";
    t[450] = .@"set_mempolicy_home_node";
    t[451] = .@"cachestat";
    t[452] = .@"fchmodat2";
    t[453] = .@"map_shadow_stack";
    t[454] = .@"futex_wake";
    t[455] = .@"futex_wait";
    t[456] = .@"futex_requeue";
    t[457] = .@"statmount";
    t[458] = .@"listmount";
    t[459] = .@"lsm_get_self_attr";
    t[460] = .@"lsm_set_self_attr";
    t[461] = .@"lsm_list_modules";
    break :blk t;
};

/// The call `nr` names on `arch`, or null.
pub fn lookup(comptime arch: enum { arm64, amd64 }, nr: u64) ?Sys {
    const t = switch (arch) {
        .arm64 => &arm64,
        .amd64 => &amd64,
    };
    return if (nr < t.len) t[@intCast(nr)] else null;
}

test "numbers" {
    try std.testing.expectEqual(Sys.write, lookup(.arm64, 64).?);
    try std.testing.expectEqual(Sys.write, lookup(.amd64, 1).?);
    try std.testing.expectEqual(Sys.openat, lookup(.arm64, 56).?);
    try std.testing.expectEqual(Sys.exit_group, lookup(.amd64, 231).?);
    try std.testing.expectEqual(Sys.rt_sigreturn, lookup(.arm64, 139).?);
}
