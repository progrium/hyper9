# The CLI

This describes, as built, the `h9` command: how it parses its arguments and finds the program, its flags, the guest's default environment, exit codes, signals, and the structure of the code behind it. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [CLI](#cli)
  - [Parsing rules](#parsing-rules)
  - [Program resolution](#program-resolution)
  - [Flags](#flags)
  - [Flags as plan lines](#flags-as-plan-lines)
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
h9 --plan FILE|- [narrowing flags] [program [args...]]  # a plan file; - is stdin
h9 --version | --check | --help      # tool functions; -h alone is --help
```

### Parsing rules

- No subcommands. `h9 ls` must run 9front's `ls`, so tool functions such as `--version` and `--check` are flags instead.
- Flag parsing stops at the first non-flag, as with `env` and `nice`, so `h9 ls -l` passes `-l` to `ls`. `--` ends h9's flags explicitly.
- Long flags only, so h9's flags are never confused with Plan 9-style short flags. There are no short aliases. The exception is `-h` as the only argument, which is `--help`: alone it can't be a program's flag, and anywhere else it's a program name or argument.

### Program resolution

| Argument | Resolution |
| --- | --- |
| Starts with `./` or `../` (`./hello`, `../out/x`) | A host path relative to the host cwd, read on the host. An a.out or ELF binary doesn't need to be in the guest namespace; a `#!` script runs by its guest path (below). |
| Absolute (`/bin/cat`) | A guest path, resolved in the guest namespace. To run an absolute host path, use the guest view of it (`/mnt/term/...`) or a relative path. |
| Bare name or other relative path (`ls`, `aux/vga`) | Looked up in the guest namespace through `$path` (default `(. /bin)`) |
| `--rc 'cmd'` | Runs `/bin/rc -c 'cmd'`; the remaining arguments become `$*` |
| `--rc` as the last argument | Runs a login rc: `rc -l -i` when h9's stdin is a host terminal, and otherwise `rc -l -c '. /fd/0'`, which reads stdin as a script. Either way rcmain sources `/rc/lib/rcmain.local` and then `$home/lib/profile` if they exist and `/bin/test` does, so a root sets its default command in `rcmain.local`, ending it with `exec prog` to replace the shell ([default-command](../design/epoch-0/default-command.md)). Without one, it's a plain rc. `--rc=` is still `rc -c ''` |
| `--ns 'LINES'\|@FILE` | Replays namespace lines before the program |

A guest program follows `#!` as exec does, so rc scripts such as `man` and `lc` run directly.

A host program that starts with `#!` runs as a guest program by its guest path ([host-scripts](../design/epoch-0/host-scripts.md)), since its interpreter, a guest program, opens the script by name. The CLI resolves the host path (symlinks included) and maps it as the policy binds it: under the cwd to `/mnt/term/cwd/...`, in a root `--dir` to its path in the root, under a `--readable` or `--writable` path (or anything, with `--host-fs`) to `/mnt/term/<host path>`, and under another `--dir` mount to its path under the mount's destination. So `$0` is that guest path, and the interpreter is resolved in the guest; a missing one gives 127. A script the guest can't read (outside every bound path, or hidden by `--read-deny`) fails before the machine starts with 126 and a message naming the flag that would share it. Nothing is bound for the script: the sandbox is as it would be without it. Without `--arch`, a script runs the host's architecture, as a guest program does.

### Flags

| Flag | Meaning |
| --- | --- |
| `--engine auto\|hvf\|kvm\|whp\|sud\|hcpu` | `auto` (the default) uses the host hypervisor, and otherwise falls back to hcpu with a warning; it never selects `sud` (not a security boundary), which needs an explicit `--engine sud`. For one release, `--backend` is accepted as an alias of `--engine`, and `native`, `emu`, and `v86` as aliases of `sud`, `hcpu`, and `hcpu` ([renames](../design/epoch-0/renames.md)); the usage text doesn't mention them, and `auto` never selects `sud` by either name |
| `--arch arm64\|amd64\|386` | The architecture of the binaries to run, which also picks `/$cputype/bin`. Without it a host program runs as its header says, and a guest one as the host's architecture |
| `--dir PATH[:DST[:OPTS]]` | A host directory or file, through `#U` ([mounts](../design/epoch-0/mounts.md)); its path joins the access rules, readable, or writable with `rw`. `contained` resolves its symlinks inside it, as on `#L` always. A missing path is exit 125 |
| `--url URL[:DST[:OPTS]]` | A 9P server: `tcp://HOST:PORT[/SPEC]`, `unix:///PATH`, `ws://`, or `wss://`. `http://` and `https://` probe: a WebSocket if the server answers the upgrade with 101, and otherwise a static dotfs tree when `URL/.fs/index` answers 200 (see [Static trees](ninep.md#static-trees)); neither is exit 125, naming both. With no scheme, `http://` for a loopback host and `https://` for any other. A DST of `/srv/NAME` posts the connection without mounting it. `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY` choose an HTTP `CONNECT` proxy for the connections h9 makes. Under `--write=none`, exit 2. A failed connection or attach is exit 125 |
| `--archive FILE[:DST[:OPTS]]` | A tar, gzipped tar, or `.h9a`, unpacked once into an `#O` instance before the program runs, counted against `--memory` |
| `--builtin[=DST[:OPTS]]` | The built-in root ([builtin-root](../design/epoch-0/builtin-root.md)). Bare, it's the bottom of `/` |
| `--tmp DST[:OPTS]` | An empty tree in memory |
| `--bind SRC:DST[:OPTS]` (repeatable) | A bind of a guest path or `#` device, run after every mount flag, in order; options `b`, `a`, `c`, and `r` |
| Mount options | `ro`, `rw`, `eph` (writes in memory; the default on `/` and `#L`), `up` or `upper` (the writable layer over what's beneath: on a stack, on top of every other member whatever its order, and elsewhere over what's at DST; see [Up layers](sandbox.md#up-layers)), `b` and `a` (on top of or at the bottom of a stack; before or after elsewhere), `c` (creates go here), `r` (merge at every depth), and for `--url` `spec=`, `user=`, `header='NAME: VALUE'\|@FILE` (repeatable; headers that change the handshake are refused), `ca=FILE`, and `index=FILE\|URL` (a metadata index instead of the server's `.fs/index`; one that can't be read is exit 125). A long form, `src=SRC,dst=DST,OPT,...`, takes values with colons, and double quotes around a value with commas. Conflicting options are exit 2 |
| No mount on `/` | `$H9ROOT` (a URL if it has `://`, and otherwise a `--dir`), then the built-in root. `--root`, its `--root-*` flags, and `--builtin MODE` are exit 2, naming their replacement |
| `--cred PATTERN=COMMAND` (repeatable) | A credential helper for the WebSocket handshakes and static-tree fetches h9 makes whose URL matches PATTERN (see [Credential helpers](ninep.md#credential-helpers)). `$H9CRED` adds a list of the same, separated by `;`, after these. A pattern that's empty, has a scheme, or has `*` anywhere but a leading `*.` followed by a domain, or an empty command, is exit 2 |
| `--index auto\|none` | `auto`, the default, uses an index wherever one is found; `none` puts no `#ι` in any mount |
| `--index-cache DIR` | Where compiled indexes, and static trees' checked files (under `blobs`), are cached. By default `$XDG_CACHE_HOME/h9/index`, `~/Library/Caches/h9/index` on macOS, `%LOCALAPPDATA%\h9\index` on Windows |
| `-v`, `--verbose` | Notes on stderr about how the run went: each index's source, size, check, and demotions, and the root's request counts at the end. `-v` is the one short flag, and only before the program |
| `--env name=value` (repeatable) | Sets a guest environment variable. The host environment isn't imported. |
| `--cwd PATH` | The guest cwd. Defaults to `/mnt/term/cwd`, the host cwd bound into the guest |
| `--rc 'cmd'` | See program resolution |
| `--ns 'LINES'\|@FILE` (repeatable) | Replays namespace lines (newns syntax: `bind`, `mount`, `unmount`, `cd`, `clear`, with `-a -b -c -C`, and `bind -r`), separated by `;` outside quotes, or a host file read on the host with `@FILE`, in order after the mounts and binds and before the program is looked up. A bare file name is exit 125 with a hint to use `@`. `--print`'s namespace output replays as is, its `ro`/`rw`/`eph`/`up` column included, and `bind -u` with it; a bind from a bare `#O` makes a fresh overlay over its target. Failed operations are skipped, as in newns, but a URL mount that fails, and a syntax error, are exit 125. |
| `--profile default\|tight` | Sets the sandbox defaults (see Sandbox policy). Explicit flags override it. |
| `--readable PATH` (repeatable) | Binds a host path read-only at `/mnt/term/PATH` |
| `--writable PATH` (repeatable) | Binds a host path read-write; under the cwd it overrides a read-only cwd |
| `--read-deny PATH` (repeatable) | Hides a host path inside a bound tree |
| `--write none\|scope\|ephemeral\|overlay` | Deny writes; persist only writable paths (`scope`); `scope` plus a copy-on-write overlay over the root, discarded at exit (`overlay`, the default); or make the root and writable paths overlays in memory, discarded at exit (`ephemeral`) |
| `--net disable\|outbound\|enable` | Network policy: mask `#I`, refuse `announce` (the default profile's default), or allow it |
| `--net-allow PATTERN` (repeatable) | Allows `connect` only to matching addresses, and `cs` lookups only of matching names (`proto!host!port`) |
| `--serve unix!PATH\|tcp!HOST!PORT\|ws://HOST:PORT[/PATH]` (repeatable) | Serves the machine's namespace over 9P while the program runs, from the kernel's 9P server (see Serving). Port 0 picks a free port, printed as `serve: ADDR`. With no program, the run only serves. On the web host, exit 2; an address that can't be listened on is exit 125 |
| `--serve-root PATH` | The guest path each connection exports, absolute. `/` by default |
| `--serve-token @FILE` | A token, the file's one word, that WebSocket listeners require as `Authorization: Bearer TOKEN` or `?token=TOKEN`. A missing file is exit 125 |
| `--serve-origin ORIGIN` (repeatable) | An `Origin` WebSocket listeners accept; `*` for any, which needs `--serve-token`. A request with no `Origin` is accepted |
| `--serve-net` | Exports `/net` too. Without it, the server Proc unmounts `/net` |
| `--memory SIZE` | Caps guest memory (`512m`, `2g`) |
| `--pids N`, `--cpus N` | Caps processes and concurrently running vCPUs |
| `--timeout DURATION` | Posts `hangup` at a deadline, waits up to 2 s, then tears down the machine |
| `--plan FILE\|-` | Runs a plan ([plan-format](../design/plan-format.md); the format is [Plans](sandbox.md#plans)), read on the host before the machine starts, from standard input with `-`, and as a stream, so `<(...)` works. Flags given with it are applied after it and can only narrow it (see [Flags as plan lines](#flags-as-plan-lines)); one that would widen it is exit 2, naming the plan's line (`h9: --plan p: memory 1G widens the plan's line 4: memory 256M`). A program on the command line replaces the plan's `run` line, and without either it's exit 2. A line the plan can't take is exit 2 with its number (`h9: --plan p: line 3: unknown line 'frobnicate'`), and a file that can't be read is exit 125. `--trace`, `-v`, `--index`, `--index-cache`, `--cred`, and `--print` aren't plan lines and apply as usual |
| `--print` | Writes the plan the flags compile to, every default spelled out, then what h9 builds from it as comments (the compiled policy, namespace, access, and caveats), and exits. `h9 --plan <(h9 FLAGS --print)` runs the same machine (see [Plans](sandbox.md#plans)) |
| `--host-fs` | Exposes all of `#U`, not just the root and cwd |
| `--no-guest-tools` | Leaves out the `#H/bin` bind of h9's own commands and masks `#H` |
| `--sandbox DIR` | The tight profile with only DIR bound, read-write, as the cwd. Can't be combined with `--host-fs` |
| `--trace[=FILE]` | ratrace-style syscall log, with the Ureg and a symbolized PC when the guest faults, to stderr by default |
| `--gfx[=noclip]` | Gives the machine one host window (see Graphics), with `/dev/draw`, `/dev/mouse`, `/dev/cursor`, and `/dev/kbd` in it, and `/dev/snarf` as the host clipboard; `=noclip` keeps `/dev/snarf` in the h9 process instead. Exit 125 if this build has no GUI backend, there's no display, or another machine in the process has the window |
| `--gfx=headless` | Gives the machine the headless screen, a screen in memory, instead of a window ([headless-screen](../design/epoch-0/headless-screen.md)), with the same files; `/dev/snarf` is a buffer in the h9 process. `--gfx`, `--gfx=noclip`, or `--gfx-scale` with it is a usage error. Exit 125 in a `-Dgfx=none` build or on the web host |
| `--gfx-scale N` | The window's scale, drawterm's `-x` (Cocoa only): 0 draws in backing pixels, 1 (the default) in points, N in backing pixels divided by N. Needs `--gfx` |
| `--gfx-size WxH` | The headless screen's size, each from 1 to 16384, `1024x768` by default. Needs `--gfx=headless` |
| `--check` | Runs a test program on each engine built in, or just `--engine`'s (on HVF this also checks the entitlement), reports the vCPU limit, and runs `/bin/echo` from the root tree, or from the built-in root when there's none (`root: built-in (9front 11952 slim, arm64; no tree found)`), then a 9P root's index notes. Exits 0, or 125 if h9 can't run programs from the root |
| `--version` | Prints the h9 version (`git describe`, or `-Dversion` in releases), the pinned 9front release and drawterm revision, the engines built in, the GUI backend (`gfx:`, with `headless` after a window backend, such as `gfx: cocoa, headless`), and the built-in root's contents (`built-in root: 9front 11952 slim, arm64 amd64 386 (44 commands)`, or `skeleton only`) |
| `--help`, `-h` | Prints the usage to stdout and exits 0 (`-h` only as the only argument) |

### Flags as plan lines

Each flag that decides what the machine is compiles to a plan line ([plan-format](../design/plan-format.md)), and `--print` writes them. Given with `--plan`, a flag narrows the plan's line of the same kind (`src/policy.zig`'s `narrow`, the one rule child machines will use too): what's lower, read-only, or removed is taken, and anything wider is exit 2.

| Flag | Plan line | With `--plan` |
| --- | --- | --- |
| `--dir`, `--url`, `--archive`, `--builtin`, `--tmp` | `dir VALUE`, `url VALUE`, `archive VALUE`, `builtin [VALUE]`, `tmp VALUE`, each the flag's value; bare `builtin` is the bottom of `/` | Only a plan's own mount, made no more writable (`rw` to `eph` or `ro`); a new one widens |
| `--bind SRC:DST[:OPTS]` | `bind SRC:DST[:OPTS]`, one value | A new one widens |
| `--ns 'LINES'\|@FILE` | The lines themselves: `bind` and `mount` with two values or more, `unmount`, `cd`, `clear` | New lines widen |
| `--profile P` | `profile P`, which also sets what the profile defaults | `tight` narrows the network to `disable`, the timeout to 10 minutes, and the cwd to read-only |
| `--write M` | `write M` | `none` narrows anything; `ephemeral` narrows `scope` and `overlay`. A `none` makes writable paths readable and mounts `ro` |
| `--net M` | `net M` | `disable` < `outbound` < `enable` |
| `--net-allow PATTERN` | `netallow PATTERN` | Only the plan's patterns, or any when the plan has none |
| `--readable PATH` | `allow read PATH` | A path the plan shares, or a writable one made read-only |
| `--writable PATH` | `allow write PATH` | Only under a writable path of the plan's |
| `--read-deny PATH` | `deny read PATH` | Always narrows |
| `--host-fs`, `--no-guest-tools` | `devices [host-fs] [guest-tools]` | Can be left out, not added |
| `--memory SIZE`, `--pids N`, `--cpus N`, `--timeout D` | `memory SIZE`, `pids N`, `cpus N`, `timeout D`; one that's unset is a comment, such as `# memory: the engine's default` | Lower only |
| `--engine E` | `engine E` | The plan's engine, any under no `engine` line, and any but `sud` under `auto` |
| `--arch A` | `arch A` | The plan's, or any under no `arch` line |
| `--env NAME=VALUE` | `env NAME=VALUE` | Adds or replaces a variable |
| `--cwd PATH`, `--sandbox DIR` | `cwd PATH rw\|ro`; `--sandbox DIR` is `profile tight` and `cwd DIR rw` with only DIR bound | The plan's cwd; `rw` only if the plan's is |
| `--gfx[=noclip]`, `--gfx-scale N`, `--gfx=headless`, `--gfx-size WxH` | `gfx window [noclip] [scale=N]`, `gfx headless [WxH]` | Only with the plan's `gfx` line, the clipboard taken away but not given |
| `--serve ADDR`, `--serve-root P`, `--serve-token @FILE`, `--serve-origin O`, `--serve-net` | `serve ADDR`, `serveroot P`, `servetoken @FILE`, `serveorigin O`, `servenet` | Only the plan's addresses, a root under its root, and fewer origins |
| A program, `--rc 'cmd'`, `--rc` | `run PROG ARGS...`, `run /bin/rc -c cmd`, `run /bin/rc -l` | Replaces the run |

A URL's query and a header's inline value can hold a secret, so `--print` writes them as `…`, as it always elided them, and `--plan` refuses a line with `…` (exit 2) rather than run a different machine: a plan names them in a file (`header=@FILE`, `servetoken @FILE`) or has them written in by hand. A mount's `b3=HASH` pins its tree by its index's BLAKE3 hash ([Pinned roots](sandbox.md#pinned-roots)).

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
| `linux: signal N` (from the Linux ABI) | 128 + the host's number for Linux signal N, matched by name; 1 if the host has no such signal | As above |
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
    engine: engine.Choice = .auto,
    arch: ?engine.Arch = null,             // null: the host's
    mounts: []const Mount = &.{},       // the mount flags, in order: .dir, .url, .archive, .builtin, .tmp, or .fd (a host descriptor, with fd_write for a pipe pair), with dst and options
    binds: []const Bind = &.{},         // --bind lines, after every mount
    index: IndexMode = .auto,           // .none: no metadata index for any mount
    root_index: ?RootIndex = null,      // .path or .url: the 9P root's index, instead of its .fs/index
    index_cache: ?[]const u8 = null,    // where compiled indexes and static trees' files are cached; null: nowhere
    tmp_dir: []const u8 = "/tmp",       // where static trees' sockets go; the CLI's is $TMPDIR
    root_index_counts: ?struct { entries: u32, dirs: u32 } = null, // for --print only
    verbose: bool = false,              // notes on stdio.err, such as the index's check
    nameservers: []const []const u8 = &.{}, // the host's DNS servers, for a Linux root's resolv.conf
    nine_prog: bool = false,            // resolve the program in the 9front view even with a Linux tree
    console_tty: bool = true,           // whether a Linux program's isatty is true on the console
    proxy: ?Proxy = null,               // HTTP CONNECT proxies for the connections h9 makes; null: direct
    cred_helpers: []const CredHelper = &.{}, // --cred and $H9CRED: { pattern, argv }, for host-made handshakes
    cwd: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    policy: Policy = .{},               // profile, binds, read-deny, net rules, limits, host_fs
    guest_tools: bool = true,           // bind #H/bin, h9's own commands, after /bin; false masks #H
    trace: ?*std.Io.Writer = null,      // syscall lines, and a Ureg dump on each fault
    ns: []const []const u8 = &.{},      // namespace text to replay, in order; the CLI reads --ns @FILE
    serve: []const Listen = &.{},       // .unix (path), .tcp (host!port), .ws (host:port/path); empty argv serves only
    serve_root: []const u8 = "/",       // the guest path each connection exports
    serve_token: ?[]const u8 = null,    // required on WebSocket listeners when set
    serve_origins: []const []const u8 = &.{}, // Origins WebSocket listeners accept; "*" for any
    serve_net: bool = false,            // export /net too
    signals: ?*Signals = null,          // Ctrl-C and hangup from the embedder
    gfx: ?Gfx = null,                   // a host window or the headless screen (.screen, .size); one machine in the process at a time
    plan: ?[]const u8 = null,           // a plan's text, in place of the fields a plan covers (design/plan-format.md); host paths absolute
    stdio: Stdio,                       // host fds behind the console

    pub fn toPlan(o: Options, arena: Allocator) ![]const u8; // these options as a plan's text, which .plan takes back
    pub fn toSpec(o: Options, arena: Allocator) !policy.Spec; // the same, parsed
};
pub fn run(m: *Machine, prog: Program, argv: []const []const u8) !ExitStatus;
pub fn serving(m: *const Machine) []const []const u8; // each listener's bound address, once run has opened them
pub fn planRun(m: *const Machine) ?[]const []const u8; // a plan's run line, for the embedder to run
```

`Machine.init(gpa, io, .{ .plan = text, .stdio = ... })` takes a plan as `h9 --plan` does: its lines replace the mounts, binds, `ns`, `policy`, `guest_tools`, `engine`, `arch`, `env`, `cwd`, `gfx`, and the serve fields, and the rest (stdio, trace, signals, caches, credential helpers, and `.fd` mounts, which a plan can't hold as text) come from the other fields. A plan that doesn't parse is `error.BadPlan`, with the line and why in `initExplained`'s message. `Options.toPlan` is its inverse, so `.{ .plan = try opts.toPlan(arena) }` is the same machine as `opts`.

`cli.zig` is the only code that knows flag strings; tests and other embedders build `Options` directly. `stdio` and `trace` are passed in rather than taken from the process. That keeps the machine API free of CLI-global state and lets integration tests capture a machine's output and syscall trace.
