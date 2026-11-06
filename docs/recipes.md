# h9 recipes

Short answers to "how do I do X with h9". Each recipe is a command or a small
file you can copy, with a line or two on why it works. The
[manual](../MANUAL.md) explains the ideas behind them, and these recipes link
to its chapters rather than repeat them.

Most recipes use only what's on `main`. The WebSocket ones depend on
websocket-9p (`--root ws://...`, `/net/ws` and `wsmount`), which isn't
merged yet, and are marked *Needs
[#38](https://github.com/progrium/hyper9/pull/38)*.

The examples run on a Mac with `h9`. On Linux and Windows, use `h9-emu` the
same way ([manual, chapter 2](../MANUAL.md#2-installing)).

- [Sandboxing](#sandboxing)
- [Files and scratch space](#files-and-scratch-space)
- [Serving and mounting 9P](#serving-and-mounting-9p)
- [Building 9front software](#building-9front-software)
- [Using 9front tools from the host](#using-9front-tools-from-the-host)
- [Go programs](#go-programs)

## Sandboxing

[Chapter 22](../MANUAL.md#22-sandboxing) of the manual describes the
profiles, capabilities and `--print`, and ends with one-line recipes for the
common cases. These go a step further.

### Try an untrusted script, then decide what to keep

`--write=ephemeral` throws every change away when the machine ends. To see
the changes before you decide, have the machine write its result to
standard output as a tar archive, and unpack that somewhere else to review:

```sh
host$ h9 --write=ephemeral --net=disable --timeout 5m \
	--rc '{ rc ./untrusted.rc } >[1=2]; tar c .' > result.tar
host$ mkdir review && tar -xf result.tar -C review
host$ diff -ru . review
```

The script's own output goes to standard error (`>[1=2]`), so only the
archive reaches `result.tar`. The script runs against an in-memory copy of
your directory and never writes to the host. Copy what you want from
`review` when you're happy with it. The same works for a `mk` target:
replace `rc ./untrusted.rc` with `mk`.

### Check the sandbox before CI runs anything

`--print` shows what the sandbox enforces without running anything, so a CI
job can refuse to run if someone loosens the flags. Check for the
capabilities you rely on in the `enforces:` line:

```sh
flags="--profile=tight --write=ephemeral --memory 1g --timeout 10m --pids 64"
plan=$(h9 --print $flags mk test)
for cap in net.disable fs.write.ephemeral res.memory proc.timeout; do
	echo "$plan" | grep -q "^enforces:.* $cap" || { echo "sandbox lacks $cap" >&2; exit 1; }
done
h9 --strict $flags mk test
```

`--strict` makes h9 exit 2 instead of quietly falling back when it can't
enforce something you asked for, such as `--write=overlay` today.

### Find out what a program tried to reach

When a sandboxed program fails, `--trace` shows each system call it made,
and its errors name the rule that stopped it:

```sh
host$ h9 --profile=tight --trace=trace.txt ./tool; grep -e 'permission denied' -e 'does not exist' trace.txt
```

A refused network connection shows up as a failed `write` to a
`/net/tcp/n/ctl` file, and a hidden or unshared host path as a failed
`open` or `stat` with `file does not exist`. The table in
[chapter 27](../MANUAL.md#27-debugging) says where each error comes from.

### Run tests in GitHub Actions

GitHub's Linux runners have no nested virtualization, so CI uses `h9-emu`.
Until h9 has releases, build it in the job. On a glibc host such as Ubuntu,
build for musl, since the prebuilt Unicorn library is musl only:

```yaml
jobs:
  plan9:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build h9-emu
        run: |
          pip install ziglang==0.16.0
          git clone --depth 1 https://github.com/progrium/hyper9 "$RUNNER_TEMP/hyper9"
          cd "$RUNNER_TEMP/hyper9"
          ./scripts/fetch.sh
          python -m ziglang build -Demu=unicorn -Dtarget=x86_64-linux-musl
          echo "$RUNNER_TEMP/hyper9/zig-out/bin" >> "$GITHUB_PATH"
      - uses: actions/setup-go@v5
        with:
          go-version: stable
      - name: Test on Plan 9
        run: |
          mkdir -p goroot/{bin,dev,env,fd,mnt/term/cwd,net,proc,srv,tmp}
          GOOS=plan9 GOARCH=amd64 go test -c -o pkg.test ./pkg
          h9 --root goroot --cwd ./pkg --net=disable --timeout 10m ./pkg.test -test.v -test.short
```

`fetch.sh` also downloads the 9front image, which this job doesn't use.

That's enough for Go programs, which don't need a 9front root (see
[Go programs](#go-programs)). For 9front's own commands the job also needs a
root tree. `scripts/mkroot.py` makes one with QEMU, and for x86\_64 runners
it needs `--arch amd64`, which takes a few minutes, so cache
`.local/9front` with `actions/cache`, keyed on `scripts/pins.sh`.

## Files and scratch space

### Make `/n` and `/mnt` work as on 9front

On 9front, `mntgen` makes any directory you name under `/n` and `/mnt`
appear when you use it, so mount points are never missing. h9 doesn't start
it, which is why the manual makes mount points in `/tmp`. You can start it
yourself:

```sh
host$ h9 --rc 'mntgen && mntgen /mnt && webfs && hget http://example.com/ | sed 3q'
```

`mntgen` mounts itself after what's already there, on `/n` by default, so
the root tree's directories and h9's binds, such as `/mnt/term`, stay as
they were. After it runs, `webfs` can mount on `/mnt/web` and `9fs` on
`/n/whatever` without any `mkdir`:

```sh
host$ h9 --rc 'mntgen && 9fs sources && ls /n/sources'
```

### Give the guest a home directory

h9 sets `$home` to `/usr/$user`, which isn't in the root tree, and the root
is read-only ([appendix C](../MANUAL.md#c-the-root-tree)). Programs that
keep files in `$home` (`$home/lib/profile`, acme's and mail's settings)
work once it exists. Mount a `ramfs` before `/usr` so you can create it,
and bind a host directory onto it so it lasts:

```sh
host$ mkdir -p ~/.h9home/lib
host$ h9 --writable ~/.h9home \
	--rc 'ramfs -S usr && mount -bc /srv/usr /usr && mkdir $home && bind -c /mnt/term$1 $home && cd && rc -li' \
	~/.h9home
```

`mount -b` puts the empty `ramfs` in front of the root's `/usr`, so
`/usr/glenda` is still there, and `-c` sends new files to the `ramfs`. `rc
-li` reads `$home/lib/profile`, which you edit on the host, and prompts. Without the
`bind` line the home directory is in memory and disappears with the
machine.

### Add files to a read-only directory for one run

The same union trick works on any directory in the root: mounting a `ramfs`
before it lets you create new files there while the existing ones stay
read-only. For example, extra `ndb` entries for one run:

```sh
host$ h9 --rc 'ramfs -S ndb && mount -bc /srv/ndb /lib/ndb && cp ./mysite /lib/ndb/mysite && ndb/query -f /lib/ndb/mysite sys myhost'
```

To change files that are already in the root, use `--write=ephemeral
--writable "$H9ROOT"` instead ([chapter 18](../MANUAL.md#18-building-software-inside-h9)).

### Share scratch space between two machines

Each machine has its own `/srv` and `/tmp`, and machines can't see each
other's. To share a tree, have one machine serve it with `exportfs` on a
loopback port and the other mount it:

```sh
host$ h9 --net=enable --rc 'ramfs -S s && mkdir /tmp/s && mount -c /srv/s /tmp/s && aux/listen1 -t tcp!127.0.0.1!5650 /bin/exportfs -r /tmp/s' &
host$ h9 --rc 'srv tcp!127.0.0.1!5650 s && mkdir /tmp/s && mount -c /srv/s /tmp/s && date > /tmp/s/now'
host$ h9 --rc 'srv tcp!127.0.0.1!5650 s && mkdir /tmp/s && mount /srv/s /tmp/s && cat /tmp/s/now'
```

The server runs until you stop it. Anything on your host can reach a
listening port, so keep it on `127.0.0.1`
([chapter 15](../MANUAL.md#15-networking)).

## Serving and mounting 9P

[Chapter 16](../MANUAL.md#16-file-servers-srv-and-9p-mounts) explains
`/srv`, mounts and 9P roots, and shows one h9 serving its root to another.

### Serve a host directory to h9 from Go

Any 9P2000 server that doesn't ask for authentication can be h9's root or a
mount inside it. In Go, the `ufs` server from
[Harvey-OS/ninep](https://github.com/Harvey-OS/ninep) serves a directory:

```sh
host$ cp -R "$H9ROOT/" /tmp/rootcopy
host$ go run github.com/Harvey-OS/ninep/cmd/ufs@latest -root /tmp/rootcopy -addr 127.0.0.1:5640 &
host$ h9 --root 'tcp!127.0.0.1!5640' ls /
```

`ufs` serves its directory read-write, and h9 passes writes through to it,
so a 9P root is writable wherever the server allows. That's why this serves
a copy. `-root` must be a real directory, not a symlink such as
`.local/9front/root`, since `ufs` doesn't follow it. To mount a directory inside
the guest instead of using it as the root:

```sh
host$ go run github.com/Harvey-OS/ninep/cmd/ufs@latest -root ~/data -addr 127.0.0.1:5641 &
host$ h9 --rc 'srv tcp!127.0.0.1!5641 data && mkdir /tmp/data && mount /srv/data /tmp/data && ls /tmp/data'
```

A tree used as the root must have the directories h9 binds onto (`/dev`,
`/env`, `/fd`, `/mnt/term/cwd`, `/net`, `/proc`, `/srv`, `/tmp`, `/bin`),
and binaries for the architecture you run if you want commands.

When you write your own server, check that it answers a walk of several
names with the qids of the names it found, and an error only when the first
name is missing, as `walk(5)` says. h9's kernel relies on that to cross mount
points, and a server that returns an error for a partial walk fails with
`No such path: '/dev'` or similar as soon as h9 builds its namespace. Two
popular Go packages get this wrong: `knusbaum/go9p` and the latest
`aqwari.net/net/styx`.

### Serve 9P over WebSocket

*Needs [#38](https://github.com/progrium/hyper9/pull/38).*

`--root ws://...` and `wss://...` take a 9P server behind a WebSocket. The
quickest way to get one is a relay in front of a TCP server, such as the one
h9's tests use, here in front of the `ufs` server above:

```sh
host$ zig build wsrelay -- 8080 5640 &
host$ h9 --root ws://localhost:8080/9p ls /
```

To serve 9P on a WebSocket from your own Go program, hand each WebSocket
connection to the 9P server as a `net.Conn`. With `ufs` and
[coder/websocket](https://github.com/coder/websocket):

```go
// wsfs serves a host directory over 9P on WebSocket at ws://ADDR/9p.
//
//	go run . -root DIR -ws 127.0.0.1:8080
package main

import (
	"context"
	"flag"
	"log"
	"net"
	"net/http"
	"sync"

	ufs "github.com/Harvey-OS/ninep/filesystem"
	"github.com/coder/websocket"
)

// conn tells the handler when the 9P server is done with a connection.
type conn struct {
	net.Conn
	once sync.Once
	done chan struct{}
}

func (c *conn) Close() error {
	c.once.Do(func() { close(c.done) })
	return c.Conn.Close()
}

func main() {
	addr := flag.String("ws", "127.0.0.1:8080", "address to listen on")
	flag.Parse() // ufs reads -root DIR from the same flags

	srv, err := ufs.NewUFS()
	if err != nil {
		log.Fatal(err)
	}
	http.HandleFunc("/9p", func(w http.ResponseWriter, r *http.Request) {
		ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"9p"}})
		if err != nil {
			return
		}
		ws.SetReadLimit(1 << 20)
		c := &conn{Conn: websocket.NetConn(context.Background(), ws, websocket.MessageBinary), done: make(chan struct{})}
		if err := srv.Accept(c); err != nil {
			c.Close()
			return
		}
		<-c.done
	})
	log.Fatal(http.ListenAndServe(*addr, nil))
}
```

```sh
host$ go run . -root /tmp/rootcopy -ws 127.0.0.1:8080 &
host$ h9 --root ws://127.0.0.1:8080/9p ls /
```

Put it behind TLS and a token check for anything but local use, and pass
the token with `--root-header @FILE` so it stays out of `ps`.

Serving a root from a web page, so a browser tab is the file server, needs
the browser host ([browser-host](../design/0012-browser-host.md)) and isn't
available yet.

### Mount a remote file server

The manual's example mounts a TCP server with `srv` and `mount`. With
`mntgen` running (above), `9fs` handles the usual servers by name:

```sh
host$ h9 --net-allow 'tcp!9p.io!564' --rc 'mntgen && 9fs sources && ls /n/sources/contrib | sed 5q'
```

Over a WebSocket, `wsmount` does the dial and the mount, with `-h` for
headers. Passing the header as an argument keeps the token out of the
command text. *Needs [#38](https://github.com/progrium/hyper9/pull/38).*

```sh
host$ h9 --rc 'mkdir /tmp/fs && wsmount -h $1 wss://fs.example/9p /tmp/fs && ls /tmp/fs' "Authorization: Bearer $TOKEN"
```

A namespace file can mount a URL too, so a project can carry its mounts in
a file next to its code ([chapter 24](../MANUAL.md#24-namespace-files-with---ns)).
A namespace file can't make directories, so mount on one the root already
has, such as the empty `/n`:

```sh
host$ cat ns
mount -c wss://fs.example/9p /n
host$ h9 --ns ns ls /n
```

## Building 9front software

[Chapter 18](../MANUAL.md#18-building-software-inside-h9) covers the
compilers, `mk`, and installing into the root.

### Build for every architecture

`$objtype` picks the target, and a mkfile that uses `mkone` (like the one in
chapter 18) names each result by its architecture's letter, so one loop
builds all three:

```sh
host$ h9 --rc 'for(objtype in arm64 amd64 386) mk'
host$ ls *.out
6.out  7.out  8.out
host$ h9 ./7.out && h9-emu ./6.out && h9-emu ./8.out
```

The root tree needs each architecture's libraries for this, so make it with
`mkroot.py --arch 386,amd64`. h9 reads a host program's header to pick its
architecture, so the amd64 and 386 builds run on the emulator.

### Build a POSIX C program with `pcc`

Programs written for Unix build with APE, Plan 9's POSIX environment,
through `pcc`:

```sh
host$ cat hello.c
#include <stdio.h>
#include <unistd.h>

int
main(void)
{
	printf("hello from APE, pid %d\n", getpid());
	return 0;
}
host$ h9 pcc -o hello hello.c && h9 ./hello
```

`pcc` takes `-D_POSIX_SOURCE`, `-D_BSD_EXTENSION` and the other
feature macros in `pcc(1)`. Most small portable programs build unchanged.

### Try an install without changing the root

With `BIN=/$objtype/bin` in the mkfile, install into the root for one run
only, to check that a build installs and runs before you install it for
real:

```sh
host$ h9 --write=ephemeral --writable "$H9ROOT" --rc 'mk install && hello'
```

The root's copy-on-write overlay is in memory and disappears with the
machine. Drop `--write=ephemeral` to keep the install.

## Using 9front tools from the host

[Chapter 25](../MANUAL.md#25-using-h9-from-host-scripts-and-tools) covers
pipelines, exit codes, quoting with `--rc`, and simple wrappers.

### A `9` command for any 9front tool

Like plan9port's `9`, this runs any 9front command, and also lets it read
host files outside the current directory, which h9 otherwise hides. It
shares each such file read-only and rewrites the argument to the file's path
inside the machine:

```bash
#!/usr/bin/env bash
# 9 CMD [ARGS...]: run a 9front command on host files. Files under the
# current directory work as they are; an argument that names an existing
# host file elsewhere (/etc/hosts, ../notes.txt) is shared read-only and
# rewritten to its path inside the machine.
set -euo pipefail
cmd=$1; shift
flags=() args=()
for a in "$@"; do
	case $a in
	/*|../*)
		if [ -e "$a" ]; then
			p=$(cd "$(dirname "$a")" && pwd -P)/$(basename "$a")
			flags+=(--readable "$p")
			a=/mnt/term$p
		fi ;;
	esac
	args+=("$a")
done
exec h9 ${flags[@]+"${flags[@]}"} "$cmd" "${args[@]}"
```

```sh
host$ 9 wc -l /etc/hosts ../notes.txt
host$ git log --format=%an | 9 sort | 9 uniq -c | 9 sort -nr | sed 5q
```

The odd-looking `${flags[@]+...}` keeps the script working with macOS's
bash 3.2 when there are no flags.

### Structural regular expressions on host files

`ssam` is `sam` as a stream editor. Its commands work on any span of text,
not just lines, which makes some edits one command that `sed` needs a script
for:

```sh
host$ h9 ssam 'x/oldName/ c/newName/' < main.c > main.c.new
host$ h9 ssam -n 'x/(.+\n)+/ g/TODO/ p' < notes.txt
```

The first renames every `oldName`, wherever it is on a line, and prints the
whole file. The second splits the text into paragraphs and prints those
that mention `TODO`. `sam -d` edits a file in place, with
the same commands, if you'd rather work interactively.

### Run an rc script

There's no `#!` support for host files yet
([host-scripts](../design/host-scripts.md)), so run a script from your
directory by naming `rc`:

```sh
host$ h9 rc build.rc arg1 arg2
```

`rc` finds `build.rc` in the current directory, which is your host
directory, and gives it `arg1 arg2` as `$*`. A script installed in the root,
or in a directory bound onto `/bin`, can use `#!/bin/rc` and run by name.

## Go programs

[Chapter 19](../MANUAL.md#19-go-programs) covers what works and the memory
a Go program needs.

### Run Go programs without a 9front root

A Go program is self-contained, so it doesn't need 9front's files: an empty
tree with the directories h9 binds onto is enough. That makes Go testing
work in CI without building a root tree:

```sh
host$ mkdir -p goroot/{bin,dev,env,fd,mnt/term/cwd,net,proc,srv,tmp}
host$ GOOS=plan9 GOARCH=amd64 go build -o hello .
host$ h9 --root goroot ./hello
```

The program still sees your current directory at `/mnt/term/cwd`, the
network and `/tmp`; it just has no 9front commands to run.

### Run a package's tests on Plan 9

Build the test binary for Plan 9 on the host, then run it with the
package's directory as the current one, so `testdata` is where the tests
expect it:

```sh
host$ GOOS=plan9 GOARCH=amd64 go test -c -o pkg.test ./pkg
host$ h9 --root goroot --cwd ./pkg ./pkg.test -test.v -test.short
```

`pkg.test` is read from where you ran h9, before `--cwd` applies. Add
`--net=disable --timeout 10m` for CI, and raise `--memory` if a test
allocates a lot. Tests that run `go` or other commands
with `os/exec` need `--memory 4G` and an amd64 root tree with those
commands.

### Serve HTTP from a Go program in h9

A Go server in the guest listens on the host's ports, with `--net=enable`:

```go
package main

import (
	"log"
	"net/http"
)

func main() {
	log.Fatal(http.ListenAndServe("127.0.0.1:8080", http.FileServer(http.Dir("."))))
}
```

```sh
host$ GOOS=plan9 GOARCH=amd64 go build -o serve . && h9 --root goroot --net=enable ./serve &
host$ curl http://127.0.0.1:8080/
```

The server sees only what h9 shares, so this serves your current directory
and nothing else. Add `--profile=tight --net=enable` to make it read-only.
