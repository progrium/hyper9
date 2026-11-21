# The CLI

This describes, as built, the `h9` command: how it parses its arguments and finds the program, its flags, the guest's default environment, exit codes, signals, and the structure of the code behind it. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [CLI](#cli)
  - [Parsing rules](#parsing-rules)
  - [Program resolution](#program-resolution)
  - [Flags](#flags)
  - [Default guest environment](#default-guest-environment)
  - [Exit codes](#exit-codes)
  - [Signals and TTY](#signals-and-tty)
  - [Code structure](#code-structure)

## CLI

The CLI is a thin wrapper: it parses argv into `Machine.Options`, runs one machine, and maps the result to an exit code.

```
h9 [h9-flags] [--] program [args...]
h9 [h9-flags] --rc 'command line'
h9 [h9-flags] --rc                  # login rc: the root's default command
h9 [h9-flags] rc                    # interactive shell
h9 [h9-flags]                       # no program: prints the usage to stderr, exit 2
h9 [h9-flags] --serve ADDR...       # no program: serves the namespace until a note
h9 --version | --check | --help      # tool functions; -h alone is --help
```

### Parsing rules

- No subcommands. `h9 ls` must run 9front's `ls`, so tool functions such as `--version` and `--check` are flags instead.
- Flag parsing stops at the first non-flag, as with `env` and `nice`, so `h9 ls -l` passes `-l` to `ls`. `--` ends h9's flags explicitly.
- Long flags only, so h9's flags are never confused with Plan 9-style short flags. There are no short aliases. The exception is `-h` as the only argument, which is `--help`: alone it can't be a program's flag, and anywhere else it's a program name or argument.

### Program resolution

| Argument | Resolution |
| --- | --- |
| Starts with `./` or `../` (`./hello`, `../out/x`) | A host path relative to the host cwd, read on the host. It doesn't need to be in the guest namespace. |
| Absolute (`/bin/cat`) | A guest path, resolved in the guest namespace. To run an absolute host path, use the guest view of it (`/mnt/term/...`) or a relative path. |
| Bare name or other relative path (`ls`, `aux/vga`) | Looked up in the guest namespace through `$path` (default `(. /bin)`) |
| `--rc 'cmd'` | Runs `/bin/rc -c 'cmd'`; the remaining arguments become `$*` |
| `--rc` as the last argument | Runs a login rc: `rc -l -i` when h9's stdin is a host terminal, and otherwise `rc -l -c '. /fd/0'`, which reads stdin as a script. Either way rcmain sources `/rc/lib/rcmain.local` and then `$home/lib/profile` if they exist and `/bin/test` does, so a root sets its default command in `rcmain.local`, ending it with `exec prog` to replace the shell ([default-command](../design/epoch-0/default-command.md)). Without one, it's a plain rc. `--rc=` is still `rc -c ''` |
| `--ns file` | Runs `newns` with the file before the program |

A guest program follows `#!` as exec does, so rc scripts such as `man` and `lc` run directly. A host program (`./x`) must be an a.out; run a host script with `h9 rc ./x`.

### Flags

| Flag | Meaning |
| --- | --- |
| `--backend auto\|hvf\|kvm\|native\|whp\|emu\|v86` | `auto` (the default) uses the host hypervisor, and otherwise falls back to the emulator with a warning; it never selects native (not a security boundary), which needs an explicit `--backend native`. `v86` is an alias of `emu` |
| `--arch arm64\|amd64\|386` | The architecture of the binaries to run, which also picks `/$cputype/bin`. Without it a host program runs as its header says, and a guest one as the host's architecture |
| `--root DIR\|DIAL\|SOCKET\|URL` | The root tree: a host directory, a 9P server's dial string (`tcp!host!port`, `tcp!host` for port 564, or `unix!path`), the path of a unix socket, or a `ws://` or `wss://` URL of a 9P server behind a WebSocket, whose scheme can be left off when the value isn't an existing path (`wss://`, or `ws://` for a loopback host). If omitted, use `$H9ROOT` (same forms), then the default install location (`.local/9front/root` in development builds until there's an installer), then the built-in root (`--builtin`). A path that's neither a directory nor a socket, a failed connection or attach, and a unix socket root on Windows are exit 125 |
| `--root-spec NAME` | The attach name sent to a 9P root. Empty by default |
| `--root-user NAME` | The uname sent in h9's attaches to a 9P root. The machine's user by default |
| `--root-header 'NAME: VALUE'\|@FILE` (repeatable) | A header for a WebSocket root's handshake, or one per line from a file (blank lines skipped). Headers that change the handshake (`Host`, `Upgrade`, `Connection`, `Sec-WebSocket-*`, `Content-Length`, `Transfer-Encoding`) are refused. Without a `ws://` or `wss://` root, a bad header or a missing file is exit 2 |
| `--cred PATTERN=COMMAND` (repeatable) | A credential helper for host-made WebSocket handshakes whose URL matches PATTERN (see [Credential helpers](ninep.md#credential-helpers)). `$H9CRED` adds a list of the same, separated by `;`, after these. A pattern that's empty, has a scheme, or has `*` anywhere but a leading `*.` followed by a domain, or an empty command, is exit 2 |
| `--root-ca FILE` | A PEM bundle that a `wss://` root's certificate must chain to, instead of the host's. Without a `wss://` root, or a missing file, is exit 2. `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY` choose an HTTP `CONNECT` proxy for WebSocket roots and mounts |
| `--root-index FILE\|URL` | A metadata index for a 9P root, used instead of its `.fs/index` (see Metadata indexes). A URL is `https://` or `http://`. With a host directory root, exit 2; a file that can't be read or a URL that can't be fetched, exit 125 |
| `--index auto\|none` | `auto`, the default, uses an index wherever one is found; `none` puts no `#ι` in any mount |
| `--index-cache DIR` | Where compiled indexes are cached. By default `$XDG_CACHE_HOME/h9/index`, `~/Library/Caches/h9/index` on macOS, `%LOCALAPPDATA%\h9\index` on Windows |
| `-v`, `--verbose` | Notes on stderr about how the run went: each index's source, size, check, and demotions, and the root's request counts at the end. `-v` is the one short flag, and only before the program |
| `--root-contained` | The root tree's symlinks resolve inside it: an absolute target starts at the tree's top and `..` stops there, as for a Linux root or a container image ("Contained trees"). With a 9P root, exit 2 |
| `--env name=value` (repeatable) | Sets a guest environment variable. The host environment isn't imported. |
| `--cwd PATH` | The guest cwd. Defaults to `/mnt/term/cwd`, the host cwd bound into the guest |
| `--rc 'cmd'` | See program resolution |
| `--ns file` | Replays a namespace file (newns syntax: `bind`, `mount`, `unmount`, `cd`, `clear`, with `-a -b -c -C`) after the policy's namespace and before the program is looked up. It's a guest path, read as newns reads it, and `--print`'s namespace output replays as is, its `ro`/`rw`/`eph` column included; a bind from a bare `#O` makes a fresh overlay over its target. Failed operations are skipped, as in newns; a syntax error is exit 125. |
| `--profile default\|tight` | Sets the sandbox defaults (see Sandbox policy). Explicit flags override it. |
| `--readable PATH` (repeatable) | Binds a host path read-only at `/mnt/term/PATH` |
| `--writable PATH` (repeatable) | Binds a host path read-write; under the cwd it overrides a read-only cwd |
| `--read-deny PATH` (repeatable) | Hides a host path inside a bound tree |
| `--write none\|scope\|ephemeral\|overlay` | Deny writes; persist only writable paths (`scope`); `scope` plus a copy-on-write overlay over the root, discarded at exit (`overlay`, the default); or make the root and writable paths overlays in memory, discarded at exit (`ephemeral`) |
| `--net disable\|outbound\|enable` | Network policy: mask `#I`, refuse `announce` (the default profile's default), or allow it |
| `--net-allow PATTERN` (repeatable) | Allows `connect` only to matching addresses, and `cs` lookups only of matching names (`proto!host!port`) |
| `--serve unix!PATH\|tcp!HOST!PORT\|ws://HOST:PORT[/PATH]` (repeatable) | Serves the machine's namespace over 9P while the program runs, one `exportfs` per connection (see Serving). Port 0 picks a free port, printed as `serve: ADDR`. With no program, the run only serves. On the browser host, exit 2; an address that can't be listened on is exit 125 |
| `--serve-root PATH` | The guest path each connection exports, absolute. `/` by default |
| `--serve-token @FILE` | A token, the file's one word, that WebSocket listeners require as `Authorization: Bearer TOKEN` or `?token=TOKEN`. A missing file is exit 125 |
| `--serve-origin ORIGIN` (repeatable) | An `Origin` WebSocket listeners accept; `*` for any, which needs `--serve-token`. A request with no `Origin` is accepted |
| `--serve-net` | Exports `/net` too. Without it, the server Proc unmounts `/net` |
| `--memory SIZE` | Caps guest memory (`512m`, `2g`) |
| `--pids N`, `--cpus N` | Caps processes and concurrently running vCPUs |
| `--timeout DURATION` | Posts `hangup` at a deadline, waits up to 2 s, then tears down the machine |
| `--print` | Prints the compiled policy and namespace, then exits |
| `--host-fs` | Exposes all of `#U`, not just the root and cwd |
| `--no-guest-tools` | Leaves out the `#H/bin` bind of h9's own commands and masks `#H` |
| `--builtin auto\|only\|before\|after\|off` | How the built-in root takes part ([builtin-root](../design/epoch-0/builtin-root.md)). `auto`, the default, is `only` when no 9front root is found and `off` otherwise; a Linux root alone doesn't count, so it gets the built-in root as its `/9`. `only` makes it `/` even if `$H9ROOT` or the development tree would give a root; with `--root` it's exit 2. `before` binds its `/$cputype/bin` before the root's `/bin`, so its commands win, and `after` binds it after the root's `/bin` and `/rc/bin`, to fill gaps; without a root, both are `only`. `off` is no built-in root, and no `/9` for a Linux root alone: with no root found, only a host a.out runs and anything else is exit 125. A program that isn't found over the built-in root alone is exit 127 with a hint to pass `--root` |
| `--sandbox DIR` | The tight profile with only DIR bound, read-write, as the cwd. Can't be combined with `--host-fs` |
| `--trace[=FILE]` | ratrace-style syscall log, with the Ureg and a symbolized PC when the guest faults, to stderr by default |
| `--gfx[=noclip]` | Gives the machine one host window (see Graphics), with `/dev/draw`, `/dev/mouse`, `/dev/cursor`, and `/dev/kbd` in it, and `/dev/snarf` as the host clipboard; `=noclip` keeps `/dev/snarf` in the h9 process instead. Exit 125 if this build has no GUI backend, there's no display, or another machine in the process has the window |
| `--gfx-scale N` | The window's scale, drawterm's `-x` (Cocoa only): 0 draws in backing pixels, 1 (the default) in points, N in backing pixels divided by N. Needs `--gfx` |
| `--check` | Runs a test program on each backend built in, or just `--backend`'s (on HVF this also checks the entitlement), reports the vCPU limit, and runs `/bin/echo` from the root tree, or from the built-in root when there's none (`root: built-in (9front 11952 slim, arm64; no tree found)`), then a 9P root's index notes. Exits 0, or 125 if h9 can't run programs from the root |
| `--version` | Prints the h9 version (`git describe`, or `-Dversion` in releases), the pinned 9front release and drawterm revision, the backends built in, the GUI backend (`gfx:`), and the built-in root's contents (`built-in root: 9front 11952 slim, arm64 amd64 386 (44 commands)`, or `skeleton only`) |
| `--help`, `-h` | Prints the usage to stdout and exits 0 (`-h` only as the only argument) |

### Default guest environment

`user` is the host user name, `home=/usr/$user`, `path=(. /bin)`, `cputype` and `objtype` come from the machine's architecture (`386` for 386), `sysname=h9`, `service=terminal`, `timezone` (copied from the root's `/adm/timezone/local`, as 9front's boot does), `serve` under `--serve` (see Serving), and `NPROC`, the CPUs the machine may use (`--cpus`, or the host's count capped by the vCPU limit), as `/dev/sysstat` lists them ([self-host](../design/epoch-0/self-host.md)). Everything else has to be passed with `--env`, which keeps host secrets out of the guest by default.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | `exits(nil)` or `exits("")` |
| 1–255 | An `exits` string that's that number in decimal: digits only, no sign, leading zero, or spaces. Nothing is printed, so rc's `exit 3` and Go's `os.Exit(3)` exit 3 ([go-compat](../design/epoch-0/go-compat.md)) |
| 1 | Any other `exits` string, including `"0"`, which is also printed to stderr; or the first process was killed by a note that isn't a signal |
| 2 | Usage error |
| 124 | `--timeout` stopped the program (`h9: prog: h9: timeout`), as coreutils `timeout` |
| 125 | h9 itself failed: no hypervisor, VM creation failed, the root wasn't found, a 9P root's connection, handshake, or attach failed, a namespace file's WebSocket mount failed, or a `--serve` listener couldn't listen (`h9: serve tcp!127.0.0.1!5640: address in use`); or the run ended with `halted`, an unexpected VM exit, or an internal error |
| 126 | The program was found but isn't a runnable a.out (bad magic or wrong architecture) |
| 127 | The program wasn't found |
| 128+N | The first process was killed by a note that's signal N ([exit-status](../design/epoch-0/exit-status.md)): see below |

The 125–127 codes follow `env` and `docker run`. A guest can exit with them too, but h9 prints a message whenever it fails itself and a numeric `exits` prints nothing, so scripts can still tell h9 failures from guest failures. The mapping is in `src/cli.zig` and applies to every program; `Machine` returns the `exits` string unchanged, so library callers decide for themselves.

A first process killed by a note exits as a host shell reports a death by signal, 128 plus the host's number for the signal (`cli.killedStatus`):

| Note | Exit code | Printed |
| --- | --- | --- |
| One APE's `sigtab` (`/sys/src/ape/lib/ap/plan9/signal.c`) maps to a signal, by prefix: `interrupt` is SIGINT, `hangup` SIGHUP, `kill` and `die` SIGKILL, `sys: write on closed pipe` SIGPIPE, `sys: fp:` SIGFPE, and so on | 128 + the host's number, so 130 for `interrupt` | Nothing for `interrupt` and a closed pipe; otherwise `h9: prog: note` |
| `linux: signal N` (from the Linux personality) | 128 + the host's number for Linux signal N, matched by name; 1 if the host has no such signal | As above |
| Another `sys: trap: …` or `sys: bad address …` fault | 139 (SIGSEGV) | `h9: prog: note` |
| `h9: timeout` | 124 | `h9: prog: h9: timeout` |
| `h9: machine stopped` | 128 + the host signal that started the teardown (130, 129, or 143), or 125 if none did | `h9: prog: h9: machine stopped` |
| `halted`, `sys: trap: unexpected exit …`, `h9: <error>` | 125 | `h9: prog: note` |
| Anything else | 1 | `h9: prog: note` |

Signal numbers are the host's (`std.posix.SIG`), since a host shell decodes the status, so `usr1` is 138 on Linux and 158 on macOS; Windows uses Linux's numbers, as Git Bash and MSYS expect. A unit test checks the copy of `sigtab` in `src/cli.zig` against the pinned 9front source when it's been fetched. h9 exits with the status rather than re-raising the signal on itself.

### Signals and TTY

- **Ctrl-C:** posts an `interrupt` note to the foreground note group; a program it kills exits 130. A second Ctrl-C within a second tears down the machine, which exits 130 too.
- **SIGTERM and SIGHUP:** post a `hangup` note to every process, then tear down the machine 2 s later, or sooner if it has exited by then. A program the note kills exits 129; a teardown exits 143 after SIGTERM and 129 after SIGHUP. `src/hostsig.zig` records which host signal started a teardown (the first one wins); on Windows, closing the console counts as SIGHUP, and logoff and shutdown as SIGTERM.
- **Raw mode:** the host TTY goes raw only when the guest writes `rawon` to `/dev/consctl`, and goes back on `rawoff`, on the last close of `/dev/consctl` (as on 9front), at the end of the run, and on a panic.

How each host delivers these:

| | Linux and macOS | Windows |
| --- | --- | --- |
| Ctrl-C | The terminal driver turns it into SIGINT (ISIG) in cooked mode | `CTRL_C_EVENT` to a `SetConsoleCtrlHandler` handler, while `ENABLE_PROCESSED_INPUT` is on |
| Ctrl-C in raw mode | ISIG is off, so 0x03 reaches the guest as a key, as Del does on 9front under rawon | Processed input is off, so the same |
| Hangup | SIGHUP (terminal closed), SIGTERM | `CTRL_CLOSE_EVENT`, `CTRL_LOGOFF_EVENT`, `CTRL_SHUTDOWN_EVENT`; Windows kills the process about 5 s after these, so the grace period has to be shorter. `CTRL_BREAK_EVENT` posts `interrupt` |
| Raw mode | termios: clear ICANON, ECHO, and ISIG | Console mode: clear `ENABLE_LINE_INPUT`, `ENABLE_ECHO_INPUT`, and `ENABLE_PROCESSED_INPUT`; set `ENABLE_VIRTUAL_TERMINAL_INPUT` |
| Line endings | The driver gives `\n` | A console in line mode gives `\r\n`, which the stdin reader turns into `\n` |

The CLI's handlers (`src/hostsig.zig`) only record the event: on POSIX a signal handler writes a byte to a self-pipe that a watcher thread reads, and on Windows the console control handler runs on its own thread already.

The watcher calls `Machine.Signals` (`interrupt`, `hangup`, `stop`), which sets a bit and wakes `Machine.run`'s waiting thread, and that thread posts the notes. Posting from a thread that isn't a kernel process is safe because the post (`h9_kern_postmach`) only queues the note and calls drawterm's `procinterrupt`, neither of which uses `up`.

Raw mode reaches the CLI through `Machine.Stdio.raw`, a callback the console device calls on `rawon` and `rawoff`; the library itself never touches the host terminal.

On Windows the close handler waits out the grace period before returning, since Windows ends the process when it returns.

### Code structure

| File | Role |
| --- | --- |
| `src/main.zig` | argv to `cli.parse`, then the host-side work the library leaves to its embedder (resolving paths and roots, reading the host's nameservers, WebSocket options), `Machine.init` and `run`, and the exit code |
| `src/cli.zig` | Pure parsing from `[]const []const u8` to a `Config` or a usage error. No I/O; unit-tested. |
| `src/root.zig` | Exports `Machine` and `Machine.Options`. No CLI types. |

```zig
pub const Options = struct {
    backend: vmm.BackendKind = .auto,
    arch: ?vmm.Arch = null,             // null: the host's
    root: ?Root = null,                 // .dir (host directory), .tcp (dial string), .unix (socket path) or .ws (URL)
    root_spec: []const u8 = "",         // attach name for a 9P root
    root_user: ?[]const u8 = null,      // attach uname for a 9P root; null: the machine's user
    root_headers: []const []const u8 = &.{}, // handshake headers for a WebSocket root, checked
    root_ca: ?[]const u8 = null,        // PEM bundle for a wss:// root; null: the host's
    root_contained: bool = false,       // resolve a host root's symlinks inside it
    index: IndexMode = .auto,           // .none: no metadata index for any mount
    root_index: ?RootIndex = null,      // .path or .url: the 9P root's index, instead of its .fs/index
    index_cache: ?[]const u8 = null,    // where compiled indexes are cached; null: nowhere
    root_index_counts: ?struct { entries: u32, dirs: u32 } = null, // for --print only
    verbose: bool = false,              // notes on stdio.err, such as the index's check
    linux_root: ?[]const u8 = null,     // the Linux view's /
    nameservers: []const []const u8 = &.{}, // the host's DNS servers, for a Linux root's resolv.conf
    nine_prog: bool = false,            // resolve the program in the 9front view even with a Linux root
    console_tty: bool = true,           // whether a Linux program's isatty is true on the console
    proxy: ?Proxy = null,               // HTTP CONNECT proxies for WebSocket roots and mounts; null: direct
    cred_helpers: []const CredHelper = &.{}, // --cred and $H9CRED: { pattern, argv }, for host-made handshakes
    cwd: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    policy: Policy = .{},               // profile, binds, read-deny, net rules, limits, host_fs
    guest_tools: bool = true,           // bind #H/bin, h9's own commands, after /bin; false masks #H
    builtin: policy.Builtin = .off,     // the built-in root #Hroot: .only, or .before/.after another root's /bin
    trace: ?*std.Io.Writer = null,      // syscall lines, and a Ureg dump on each fault
    ns: ?[]const u8 = null,             // newns file to replay
    serve: []const Listen = &.{},       // .unix (path), .tcp (host!port), .ws (host:port/path); empty argv serves only
    serve_root: []const u8 = "/",       // the guest path each connection exports
    serve_token: ?[]const u8 = null,    // required on WebSocket listeners when set
    serve_origins: []const []const u8 = &.{}, // Origins WebSocket listeners accept; "*" for any
    serve_net: bool = false,            // export /net too
    owned_vcpus: ?u32 = null,           // for tests of the vCPU pool
    signals: ?*Signals = null,          // Ctrl-C and hangup from the embedder
    gfx: ?Gfx = null,                   // a host window; one machine in the process at a time
    stdio: Stdio,                       // host fds behind the console
};
pub fn run(m: *Machine, prog: Program, argv: []const []const u8) !ExitStatus;
pub fn serving(m: *const Machine) []const []const u8; // each listener's bound address, once run has opened them
```

`cli.zig` is the only code that knows flag strings; tests and other embedders build `Options` directly. `stdio` and `trace` are passed in rather than taken from the process. That keeps the machine API free of CLI-global state and lets integration tests capture a machine's output and syscall trace.
