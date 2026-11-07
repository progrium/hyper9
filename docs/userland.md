# Building your own userland

> A walkthrough for people who want h9 to run something other than the stock
> 9front tree: a trimmed 9front, a userland written from scratch, 9front with
> your own layer on top, or a tree served by a program. It assumes you've
> read the [manual](../MANUAL.md)'s chapters on namespaces (6), file servers
> (16), sharing files (21) and `--ns` (24). It uses the manual's conventions:
> `host$` is your host shell, `%` is rc inside h9, and the examples use a Mac
> with the user `me`.

## Contents

1. [What h9 takes from a root](#1-what-h9-takes-from-a-root)
2. [The smallest userland: one Go program](#2-the-smallest-userland-one-go-program)
3. [A userland from scratch, with its own init](#3-a-userland-from-scratch-with-its-own-init)
4. [A slim 9front](#4-a-slim-9front)
5. [Layering on the stock root instead of copying it](#5-layering-on-the-stock-root-instead-of-copying-it)
6. [Letting programs write to the root](#6-letting-programs-write-to-the-root)
7. [Serving a userland over 9P](#7-serving-a-userland-over-9p)
8. [Serving it over WebSocket](#8-serving-it-over-websocket)
9. [h9's own commands in your userland](#9-h9s-own-commands-in-your-userland)
10. [Shipping it](#10-shipping-it)

## 1. What h9 takes from a root

Nothing boots in h9. There's no init process, no `/lib/namespace` run at
login and no `/cfg` read at startup. h9 builds the machine's namespace
itself (`h9 --print` shows it), binds the root at `/`, and runs your program.
So a userland, to h9, is just a file tree, and the root needs only what that
namespace binds onto and what your programs read.

**The directories h9 binds onto.** A bind needs its target to exist. These
are the targets, in the order h9 binds them:

| Path | Needed? | What happens without it |
| --- | --- | --- |
| `/dev` | Yes | h9 exits 125: `bind #y /dev: file does not exist`. h9's console is bound here, and every program's standard input and output come from it. |
| `/mnt/term/cwd` | Yes, or at least `/mnt/term` | h9 exits 125: `bind #U/... /mnt/term/cwd: file does not exist`. Your host directory is bound here. With only `/mnt/term`, it's bound there instead. |
| `/bin` | Yes, to run programs by name | `h9 prog` exits 127. |
| `/env` | For rc and Go programs | The environment isn't there. Go programs crash with `fatal error: getenv before env init`. |
| `/fd`, `/proc`, `/srv`, `/net`, `/tmp` | Optional | The bind is skipped, and so is the private `/tmp` in memory. Most 9front programs expect them: rc reads `/fd/0`, for one. |
| `/mnt/term/...` | Optional | Paths you share with `--readable` and `--writable` appear under `/mnt/term` (manual chapter 21). |

**Programs.** h9 binds `/$cputype/bin` over `/bin`, then `/rc/bin` after it,
and both binds are skipped if their source doesn't exist. So you can put
binaries in `/arm64/bin` (or `/amd64/bin`) as 9front does, or straight into
`/bin` if your tree has no `/$cputype/bin` at all. An empty `/$cputype/bin`
hides your `/bin`, so leave it out rather than empty.

**Files h9 reads.** Only one: `/adm/timezone/local`, copied into
`$timezone` if it's there. `h9 --check` also runs `/bin/echo`, and reports
`no /bin/echo (is it a 9front root tree?)` with exit 125 without one, though
the root works.

**The environment.** h9 sets `user` (your host user name), `home`
(`/usr/$user`, whether or not it exists), `cputype` and `objtype` (the
machine's architecture), `sysname=h9`, `service=terminal`, `path=(. /bin)`
and `timezone`, then your `--env` values. Nothing from the host environment
comes in.

**The architecture.** Every binary in the tree must be for the architecture
the machine runs. h9 runs your host's architecture on the hypervisor:
arm64 on an Apple Silicon Mac. `h9-emu` also runs amd64 and 386 on the
emulator, and `--arch amd64` picks amd64. Without `--arch`, a program found
by name is run as the host's architecture, so on a Mac an amd64-only tree
needs `--arch amd64` or you get `wrong architecture` and exit 126.

## 2. The smallest userland: one Go program

Go cross-compiles to Plan 9, so a userland can be built entirely on the
host. Go has `plan9/amd64` and `plan9/386` ports but no `plan9/arm64`, so
these examples are amd64 and need `h9-emu` on a Mac (the manual's chapter 2
covers building it). On a Mac, add `--arch amd64` to every `h9` command in
sections 2, 3 and 7; it's left out below. h9 also prints `h9: warning: no
usable hypervisor; using the emulator`, which is left out of the output
shown.

```sh
host$ mkdir -p ~/myland/src/hello && cd ~/myland/src/hello
host$ cat > main.go <<'EOF'
package main

import (
	"fmt"
	"os"
)

func main() {
	name, _ := os.ReadFile("/dev/sysname")
	fmt.Printf("hello from %s, cputype %s\n", name, os.Getenv("cputype"))
	ents, _ := os.ReadDir("/")
	for _, e := range ents {
		fmt.Print(e.Name(), " ")
	}
	fmt.Println()
}
EOF
host$ go mod init hello
host$ GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 go build -o hello .
```

Now the tree: the mount points from section 1, and the program in `/bin`.

```sh
host$ cd ~/myland
host$ mkdir -p root/{bin,dev,env,fd,proc,srv,net,tmp,mnt/term/cwd}
host$ cp src/hello/hello root/bin/
host$ h9 --root root hello
hello from h9, cputype amd64
bin dev env fd mnt net proc srv tmp
```

That's a complete userland: one program, nine empty directories, and a
machine that starts in milliseconds. `h9 --root root --print hello` shows
the namespace h9 built over it.

## 3. A userland from scratch, with its own init

A real userland has more than one command. The usual trick for small ones
is a multi-call binary that picks its command from the name it was run as.
Host hard links give it several names, since h9 serves a host tree as it is.

This one has `echo`, `cat`, `ls` and `put` (copy standard input to a file),
and an `init` that sets up the namespace the way the userland wants it and
then runs a command in it. Here `init` makes your host directory the home
directory: it binds `/mnt/term/cwd` over `/usr/$user`, sets `$home` and
starts the command there.

```go
// box is a tiny multi-call userland: run it as box CMD ARGS, or under the
// name of a command.
package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"strings"
	"syscall"
)

var cmds = map[string]func(args []string) error{
	"echo": func(a []string) error { _, err := fmt.Println(strings.Join(a, " ")); return err },
	"cat": func(a []string) error {
		for _, name := range a {
			f, err := os.Open(name)
			if err != nil {
				return err
			}
			io.Copy(os.Stdout, f)
			f.Close()
		}
		return nil
	},
	"ls": func(a []string) error {
		if len(a) == 0 {
			a = []string{"."}
		}
		for _, d := range a {
			ents, err := os.ReadDir(d)
			if err != nil {
				return err
			}
			for _, e := range ents {
				fmt.Println(e.Name())
			}
		}
		return nil
	},
	// put FILE: copy standard input to FILE.
	"put": func(a []string) error {
		f, err := os.Create(a[0])
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = io.Copy(f, os.Stdin)
		return err
	},
	// init: bind the host directory over /usr/$user, then run a command there.
	"init": func(a []string) error {
		home := "/usr/" + os.Getenv("user")
		if err := syscall.Bind("/mnt/term/cwd", home, syscall.MREPL); err != nil {
			return err
		}
		os.Setenv("home", home)
		os.Chdir(home)
		cmd := exec.Command(a[0], a[1:]...)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	},
}

func main() {
	name, args := path.Base(os.Args[0]), os.Args[1:]
	if name == "box" && len(args) > 0 {
		name, args = args[0], args[1:]
	}
	cmd, ok := cmds[name]
	if !ok {
		fmt.Fprintln(os.Stderr, "box: no command", name)
		os.Exit(1)
	}
	if err := cmd(args); err != nil {
		fmt.Fprintln(os.Stderr, name+":", err)
		os.Exit(1)
	}
}
```

Build it into a tree with a home directory for your user and a message of
the day:

```sh
host$ cd ~/myland/src/box && go mod init box
host$ GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 go build -o box .
host$ cd ~/myland
host$ mkdir -p box/{bin,dev,env,fd,proc,srv,net,tmp,mnt/term/cwd,lib,usr/$USER}
host$ cp src/box/box box/bin/
host$ for c in echo cat ls put init; do ln box/bin/box box/bin/$c; done
host$ echo 'welcome to box' > box/lib/motd
host$ h9 --root box --check
...
root /Users/me/myland/box: ok, /bin/echo runs (amd64)
host$ h9 --root box cat /lib/motd
welcome to box
host$ cd ~/notes
host$ h9 --root ~/myland/box --memory 4g init ls
notes.txt
todo.txt
host$ h9 --root ~/myland/box --memory 4g init cat /usr/me/todo.txt
...
```

Two things to know:

- **Memory.** A Go program that starts other processes needs `--memory 4g`,
  because `rfork` copies the parent's memory eagerly (manual chapter 19).
  Without it, `init` fails with `fork/exec /bin/ls: virtual memory
  allocation failed`.
- **The bind is the init's own.** It's in `init`'s namespace and the
  command's, and ends with the machine, like every namespace change. Nothing
  in the tree or on the host changes. This is the job `/lib/namespace` and
  `$home/lib/profile` do on 9front, and in a userland of your own, a first
  program is the place for it: h9 runs whatever you name, so `init` is just
  the program you put in front.

## 4. A slim 9front

> Needs the 9front root tree, from `zig build mkroot`. Not yet run.

The stock tree is about 250 MB. If you only need rc and a handful of
commands, copy them into a tree of their own. 9front's programs are
statically linked, so a binary needs nothing beside it, but some read
files: rc reads `/rc/lib/rcmain` every time it starts, and fails without it.

```sh
host$ src=$H9ROOT dst=~/slim
host$ mkdir -p $dst/{dev,env,fd,proc,srv,net,tmp,mnt/term/cwd,usr/$USER}
host$ mkdir -p $dst/{arm64/bin,rc/bin,rc/lib,adm/timezone}
host$ for c in rc echo cat ls grep sed wc sort test mkdir rm cp mv date bind mount unmount ns; do
>   cp $src/arm64/bin/$c $dst/arm64/bin/
> done
host$ cp $src/rc/lib/rcmain $dst/rc/lib/
host$ cp $src/adm/timezone/local $dst/adm/timezone/
host$ h9 --root ~/slim --check
host$ h9 --root ~/slim --rc 'ls /bin | wc -l'
host$ du -sh ~/slim
```

Some of 9front's commands are rc scripts in `/rc/bin` (`lc`, `man`, `kill`,
`9fs`) rather than binaries, so copy those from `$src/rc/bin` instead, along
with whatever they run. `h9 --trace` (manual chapter 27) shows each file a
program opens, which is the quickest way to find what else a command needs:

```sh
host$ h9 --root ~/slim --trace mk 2>&1 | grep -E 'open|exec' | grep -- '-1'
```

**Your own profile.** rc runs `/rc/lib/rcmain` first, and with `-l` (a
login shell) rcmain runs `/rc/lib/rcmain.local` and then
`$home/lib/profile`. So a userland can carry its own login profile:

```sh
host$ cat > ~/slim/rc/lib/rcmain.local <<'EOF'
# Run by rc -l: the slim userland's login profile.
prompt=('slim% ' '	')
bind -c /mnt/term/cwd $home
cd
EOF
host$ h9 --root ~/slim rc -l
slim% pwd
/usr/me
```

`h9 --rc` runs `rc -c`, which doesn't read the profile; use `h9 rc -l -c
'...'` when you want it. Editing `rcmain` itself changes every rc, scripts
included, so keep anything there quick.

**Built as one binary.** Every 9front binary is a static link, so each
copy above carries its own libc. `zig build slim`, from an h9 checkout with
a root tree, builds the same kind of tree around
[9box](../design/0064-multicall.md): 9front's own commands, from the pinned
source, in one binary that picks the command by the name it runs as.

```sh
host$ zig build slim    # .local/9front/slim-11952-arm64: 42 commands
host$ h9 --root .local/9front/slim-11952-arm64 --rc 'ls /bin | wc -l'
host$ du -sh .local/9front/slim-11952-arm64
```

The commands are hard links to `/$cputype/bin/9box`. A tree that can't have
hard links (a copy onto another file server, say) takes
`-Dslim-links=stub`, where each command is a file holding `#!/bin/9box -!`;
the same tree also lets you bind over one command, which in a hard-link
tree covers them all, since hard links share a qid. `9box` alone lists its
commands, and `9box CMD ARGS` runs one. Add your own commands and scripts to
the tree as above; to box more of 9front's, add a line to `src/9box/slim`
(its name and its directory under `/sys/src/cmd`).

## 5. Layering on the stock root instead of copying it

> Needs the 9front root tree. Not yet run.

Often you want 9front plus a few things of your own: your commands in
`/bin`, a different profile, a replaced data file. You don't need a tree of
your own for that. Keep your layer in a host directory, share it, and bind
it over the stock root with a namespace file (manual chapter 24):

```sh
host$ mkdir -p ~/layer/bin ~/layer/rc/lib
host$ cat > ~/layer/bin/hi <<'EOF'
#!/bin/rc
echo hi from the layer, on $sysname
EOF
host$ chmod +x ~/layer/bin/hi
host$ cat > ~/layer/rc/lib/rcmain.local <<'EOF'
prompt=('layer% ' '	')
EOF
host$ cat > ~/layer/ns <<'EOF'
# Replayed after h9 builds its namespace, before the program runs.
bind -b /mnt/term/Users/me/layer/bin /bin
bind -a /mnt/term/Users/me/layer/rc/lib /rc/lib
EOF
host$ h9 --readable ~/layer --ns /mnt/term/Users/me/layer/ns hi
hi from the layer, on h9
```

- `--readable ~/layer` puts the layer at `/mnt/term/Users/me/layer`, and
  `--ns` takes a guest path, so the namespace file names it there.
- `bind -b` puts your `/bin` in front of 9front's, so a command of yours
  with the same name as one of 9front's wins. `bind -a` would put it after.
- The second line unions the layer's `rc/lib` after the stock one, which
  adds `rcmain.local` (the stock tree has none) and keeps 9front's
  `rcmain`. So `h9 --readable ~/layer --ns ... rc -l` gets the layer's
  prompt.
- To replace a file that does exist, bind a file over it:
  `bind /mnt/term/Users/me/layer/lib/motd /lib/motd`. A bind's target must
  exist, and a line that fails is skipped, as in 9front's `newns`.
- The replay happens before the program is looked up, so the program can
  come from the layer, and before rc starts, so rc reads files the layer
  replaced.

A wrapper keeps the flags out of your way:

```sh
#!/bin/sh
# ~/bin/9l: h9 with ~/layer over the stock root
layer=$HOME/layer
exec h9 --readable "$layer" --ns "/mnt/term$layer/ns" "$@"
```

## 6. Letting programs write to the root

The root is read-only unless you say otherwise. Three ways to change that,
from safest to least safe:

- **In memory, for one run.** `--write=ephemeral --writable ROOT` puts a
  copy-on-write overlay over the whole root. Programs can install, edit and
  delete anything, see their changes for the rest of the run, and the host
  tree is never written. `--print` shows it as `bind -c '#O' / eph`. Under
  `--write=ephemeral` your cwd is an overlay too, so nothing reaches the host
  at all.

  ```sh
  host$ echo data | h9 --root ~/myland/box --write=ephemeral --writable ~/myland/box put /lib/x
  host$ ls ~/myland/box/lib
  motd
  ```

- **For real.** `--writable ROOT` without `--write=ephemeral` lets programs
  change the host tree. That's how you install into your userland from
  inside it, for example with `mk install` (manual chapter 18).
- **A namespace file** can put a fresh overlay over one directory with
  `bind -c '#O' /lib`, leaving the rest read-only.

The [overlay](../design/0011-overlay.md) proposal, accepted but not built
yet, makes copy-on-write over the root the default (`--write=overlay`), with
the cwd and `--writable` paths still writing to the host.

## 7. Serving a userland over 9P

A root doesn't have to be a directory. `--root` also takes a 9P server: a
dial string such as `tcp!host!port`, `unix!/path`, or the path of a unix
socket (manual chapter 16). h9 connects before the program runs, mounts the
server at `/`, and binds its devices over it as for a directory. That opens
up userlands that are programs:

- one binary that carries its whole tree,
- files made on demand (a `/lib/motd` from a database, a `/bin` that fetches
  programs as they're run),
- one server holding several userlands, picked with `--root-spec`,
- a tree shared by many machines at once, on one host or across a network.

This server is written in Go with
[lionkov/go9p](https://github.com/lionkov/go9p). It embeds a tree from
section 3 at build time, makes the mount points `embed` leaves out because
they're empty, and adds `/lib/uptime`, whose contents are made on each read:

```go
// rootfs serves the tree embedded in it as a 9P root for h9, and adds one
// synthetic file, /lib/uptime, that's made fresh on every read.
package main

import (
	"embed"
	"io/fs"
	"log"
	"os"
	"path"
	"time"

	"github.com/lionkov/go9p/p"
	"github.com/lionkov/go9p/p/srv"
)

//go:embed root
var embedded embed.FS

// The mount points h9 binds onto. embed leaves out empty directories, so
// they're made here.
var mountPoints = []string{"dev", "env", "fd", "proc", "srv", "net", "tmp", "mnt/term/cwd"}

var start = time.Now()

// file serves a byte slice that gen makes when the file is read.
type file struct {
	srv.File
	gen func() []byte
}

func (f *file) Read(fid *srv.FFid, buf []byte, off uint64) (int, error) {
	b := f.gen()
	if off >= uint64(len(b)) {
		return 0, nil
	}
	return copy(buf, b[off:]), nil
}

var user = p.OsUsers.Uid2User(os.Geteuid())

// mkdir returns the directory at name, making it and its parents.
func mkdir(root *srv.File, name string) *srv.File {
	if name == "." {
		return root
	}
	parent := mkdir(root, path.Dir(name))
	if d := parent.Find(path.Base(name)); d != nil {
		return d
	}
	d := new(srv.File)
	if err := d.Add(parent, path.Base(name), user, nil, p.DMDIR|0555, nil); err != nil {
		log.Fatal(err)
	}
	return d
}

// add adds a file at name. h9 reads a program's length from its stat, so
// size should be the content's length; 0 suits a file read until EOF.
func add(root *srv.File, name string, mode uint32, size int, gen func() []byte) {
	f := &file{gen: gen}
	if err := f.Add(mkdir(root, path.Dir(name)), path.Base(name), user, nil, mode, f); err != nil {
		log.Fatal(err)
	}
	f.Length = uint64(size)
}

func main() {
	root := new(srv.File)
	if err := root.Add(nil, "/", user, nil, p.DMDIR|0555, nil); err != nil {
		log.Fatal(err)
	}
	tree, _ := fs.Sub(embedded, "root")
	fs.WalkDir(tree, ".", func(name string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			mkdir(root, name)
			return nil
		}
		b, err := fs.ReadFile(tree, name)
		mode := uint32(0444)
		if path.Dir(name) == "bin" {
			mode = 0555
		}
		add(root, name, mode, len(b), func() []byte { return b })
		return err
	})
	for _, name := range mountPoints {
		mkdir(root, name)
	}
	add(root, "lib/uptime", 0444, 0, func() []byte {
		return []byte(time.Since(start).Round(time.Second).String() + "\n")
	})

	// rootfs tcp 127.0.0.1:5640, or rootfs unix /tmp/rootfs.sock
	network, addr := "tcp", "127.0.0.1:5640"
	if len(os.Args) == 3 {
		network, addr = os.Args[1], os.Args[2]
	}
	s := srv.NewFileSrv(root)
	s.Start(s)
	log.Fatal(s.StartNetListener(network, addr))
}
```

Build it with a copy of the box tree beside it, without its hard links and
empty directories (`embed` keeps neither), and run it:

```sh
host$ mkdir -p ~/myland/src/rootfs && cd ~/myland/src/rootfs   # main.go above
host$ go mod init rootfs && go get github.com/lionkov/go9p/p/srv
host$ mkdir -p root/bin root/lib
host$ cp ~/myland/src/box/box ~/myland/src/hello/hello root/bin/
host$ cp ~/myland/box/lib/motd root/lib/
host$ go build -o rootfs . && ./rootfs &
host$ h9 --root 'tcp!127.0.0.1!5640' hello
hello from h9, cputype amd64
bin dev env fd lib mnt net proc srv tmp
host$ h9 --root 'tcp!127.0.0.1!5640' box cat /lib/motd /lib/uptime
welcome to box
42s
```

The server itself runs on the host, so it's built for the host
(no `GOOS=plan9`), and the programs it serves are built for Plan 9. A unix
socket works the same way, on macOS and Linux hosts:

```sh
host$ ./rootfs unix /tmp/rootfs.sock &
host$ h9 --root /tmp/rootfs.sock box cat /lib/motd
welcome to box
```

**What a server has to do for h9:**

- **No authentication.** h9 doesn't authenticate to a root yet
  ([root-auth](../design/root-auth.md) is a draft), so a server that wants it
  is refused with exit 125. A TCP root is plain 9P, so keep it on loopback or
  a network you trust.
- **Plain 9P2000.** Not 9P2000.u or 9P2000.L (the
  [dotl](../design/0022-dotl.md) draft would add .L).
- **Partial walks, as 9P specifies.** When a walk of several names fails
  partway, the server must answer with the names it did walk, not an error.
  The kernel walks `dev/cons` in one message to reach the console bound over
  the server's `/dev`, and a server that answers with an error makes h9
  fail with that error, before the program runs (`open /dev/cons: ...`).
  [knusbaum/go9p](https://github.com/knusbaum/go9p), for one, answers with
  an error, which is why this example uses lionkov/go9p.
- **The right length in `stat`.** h9 reads a program's length from its
  `stat` and reads that many bytes. A file that reports length 0 is read as
  empty, and running it gives `not a 9front executable`. Files read until
  end of file, like `/lib/uptime`, can report 0.
- **Writes are the server's business.** h9 sends writes to the server, which
  decides what's writable, so `--write=none` with a 9P root is a usage
  error. The private `/tmp` is still an overlay in memory, over the server's
  `/tmp`.

Another h9 can serve a tree too: the manual's chapter 16 runs `exportfs`
under `aux/listen1` in one h9 and uses it as the root of another. And with
`u9fs -a none`, a Unix machine can serve a directory.

## 8. Serving it over WebSocket

`--root` also takes `ws://` and `wss://` URLs, so a
userland can be served by a web server, through proxies, and to an h9 in a
browser tab once [browser-host](../design/0012-browser-host.md) exists.
Any 9P server can sit behind a relay that carries 9P in binary WebSocket
messages. h9 has one for testing, `zig build wsrelay`, which listens for
WebSocket connections on one port and relays each to a TCP 9P server on
another. With `rootfs` from section 7:

```sh
host$ ./rootfs &
host$ zig build wsrelay -- 8080 5640 &
host$ h9 --root ws://localhost:8080/9p box cat /lib/uptime
2m13s
```

`--root-header 'Authorization: Bearer ...'` (or `@FILE`) sends headers with
the handshake, and `--root-ca FILE` trusts a private CA for `wss://`.

The same URLs work in a namespace file's `mount` line, so a namespace file
can attach a served tree anywhere in a local userland:

```sh
host$ cat ns
mount 'ws://127.0.0.1:8080/9p' /n/served
host$ h9 --root ~/myland/box --ns ns ls /n/served/lib
motd
uptime
```

(For this one, the box tree needs an `/n` directory to mount on.) A guest can
dial one itself through `/net/ws`, subject to `--net` and `--net-allow`;
`wsmount` from section 9 wraps that as a command.

## 9. h9's own commands in your userland

h9 serves a small read-only tree of its own rc scripts from
its binary, as the device `#H`, and binds `#H/bin` after everything else in
`/bin`. `wsmount` is the first of them. For your userland that means:

- **Your commands win.** `#H/bin` comes after the root's `/bin`, so a
  command of yours with the same name hides h9's.
- **They're rc scripts.** They run only if your userland has `/bin/rc` and
  `/rc/lib/rcmain`, and whatever commands they use (`mount`, `echo`). In a
  userland without rc, like box, they're listed in `/bin` but fail to run.
- **`--no-guest-tools`** leaves out the bind and masks `#H`, so `/bin` holds
  exactly what your root provides. Embedders get the same with
  `Machine.Options.guest_tools = false`.

## 10. Shipping it

- **A tarball and `H9ROOT`.** A host-directory root is portable as is.
  Unpack it anywhere and point `H9ROOT` at it, or pass `--root`. Hard links,
  as in section 3, survive `tar`.
- **One binary.** `rootfs` from section 7 is the whole userland in one
  host program, for any host Go builds for.
- **A wrapper.** A short script that sets `--root`, `--arch` and any
  `--ns` turns your userland into a command, as in section 5.
- **Check it.** `h9 --root DIR --check` runs `/bin/echo` from the root,
  so include an `echo` if you want the check to pass.
- **Symlinks.** h9 follows symlinks in a host tree on the host and checks
  where they land. A relative link that stays inside the tree works, but an
  absolute one points into the host's file system, not your tree, and fails
  as if its target didn't exist. Use relative links, hard links or copies. The
  [symlinks-in-root](../design/0034-symlinks-in-root.md) draft would resolve
  them inside the tree.
- **Disk images.** A 9front disk image as the root is the
  [image-roots](../design/0014-image-roots.md) draft.
- **From a Zig program.** `Machine.Options` takes the root and
  `guest_tools`, so an embedder can run its own userland without the CLI.
  See [Embedding h9 in a Zig program](embedding.md).
