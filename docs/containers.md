# Recreating Docker with h9

> A walkthrough for people who know Docker: how to get images, layers,
> volumes, port publishing, resource limits and a registry out of h9, and
> where the analogy stops. It assumes you've read Part I of the
> [manual](../MANUAL.md) and have a working `h9` and root tree. Commands use
> the manual's conventions: `host$` is your host shell, `%` is rc inside h9,
> and paths are from a Mac on Apple Silicon. Features that aren't in `main`
> yet name the proposal and the pull request they come with.

h9 isn't a container runtime, and this guide doesn't turn it into one. But
the things people reach for Docker to get, a known file system, isolation
from the host, a few directories shared in, a network policy, limits, and
images they can move between machines, are what an h9 machine already is.
Plan 9 gets them from per-process namespaces and 9P instead of from Linux
namespaces, cgroups and union file systems, so most Docker features turn out
to be a few binds.

> **Warning.** h9 is an in-development research prototype and its sandbox
> hasn't been audited ([manual, chapter 22](../MANUAL.md#22-sandboxing)).
> Don't run hostile code in it and call it contained.

## Contents

1. [The model](#1-the-model)
2. [The cheat sheet](#2-the-cheat-sheet)
3. [Images are root trees](#3-images-are-root-trees)
4. [FROM scratch: slim images](#4-from-scratch-slim-images)
5. [Entrypoints, environment and WORKDIR](#5-entrypoints-environment-and-workdir)
6. [Layers are union binds](#6-layers-are-union-binds)
7. [The container's writable layer](#7-the-containers-writable-layer)
8. [Building images](#8-building-images)
9. [Volumes](#9-volumes)
10. [Networking and published ports](#10-networking-and-published-ports)
11. [Resource limits](#11-resource-limits)
12. [docker inspect: reading the plan](#12-docker-inspect-reading-the-plan)
13. [Registries: serving images over 9P](#13-registries-serving-images-over-9p)
14. [Compose: several machines](#14-compose-several-machines)
15. [Running containers: stop, logs, restart, exec](#15-running-containers-stop-logs-restart-exec)
16. [What's missing](#16-whats-missing)
17. [Putting it together: h9box](#17-putting-it-together-h9box)

## 1. The model

| Docker | h9 |
| --- | --- |
| A daemon that owns images and containers | No daemon. `h9` is an ordinary process; when it exits, the machine is gone. |
| An image: layered tarballs plus a JSON config | A **root tree**: a directory of files (or a 9P server) served as `/`, plus a namespace file and an rc script for the config |
| A container: a process tree in Linux namespaces and cgroups | A **machine**: one `h9` invocation, with its own Plan 9 kernel, processes, `/srv`, `/env` and `/tmp` |
| An overlay file system stacking layers | Union directories, made with `bind -a` and `bind -b`, and the copy-on-write overlay device `#O` |
| Bind mounts and volumes | Host directories bound into the namespace with `--cwd`, `--readable` and `--writable` |
| Network namespaces, bridges, NAT | None: a guest uses the host's network stack, filtered by `--net` and `--net-allow` |
| cgroups | `--memory`, `--cpus`, `--pids`, `--timeout` |

Two differences shape everything below.

**Everything is already `--rm` and `--read-only`.** A machine starts from
its root tree and the flags each time, and leaves nothing behind but what it
wrote to host directories you made writable. The root is read-only unless you
say otherwise. There's no container to restart, commit or remove later.

**A namespace is cheap and per process.** In Docker, the file system view is
fixed when the container starts. In Plan 9 any process can rearrange its own
view with `bind` and `mount`, and its children inherit it. So "layering" is
something you do in a namespace file or in the entrypoint script, not
something the runtime does for you.

## 2. The cheat sheet

| Docker | h9 | Status |
| --- | --- | --- |
| `docker run IMAGE CMD` | `h9 --root IMAGE CMD` | main |
| `docker run --rm` | Always | main |
| `docker run --read-only` | The default: the root is read-only | main |
| `FROM scratch` + static binaries | A slim root tree: Plan 9 binaries are statically linked ([section 4](#4-from-scratch-slim-images)) | main |
| `ENTRYPOINT`, `CMD` | An rc script in the image, run by path; rc scripts with `#!` run as programs | main |
| `ENV`, `docker run -e` | `--env name=value`, or assignments in the entrypoint | main |
| `WORKDIR` | `cd` in the namespace file | main |
| Image layers | `bind -b` / `bind -a` lines in a namespace file, replayed with `--ns` | main |
| The container's writable layer | `--write=ephemeral --writable IMAGE`, or `bind -c '#O' DIR` in the namespace file | main |
| The same, as the default | `--write=overlay` | *Not yet available ([overlay](../design/0011-overlay.md))* |
| `docker build`, `RUN` | A host script running `h9 --root IMAGE --writable IMAGE ...` against a copy of the base ([section 8](#8-building-images)) | main |
| Multi-stage builds | Compile with the full root tree, copy the binary into a slim one | main |
| `docker commit` | Run with `--writable IMAGE` on a copy of the image | main |
| `-v host:container`, `--mount type=bind` | `--cwd DIR`, `--readable PATH`, `--writable PATH` | main |
| Hiding files from a bind mount | `--read-deny PATH` | main |
| `--tmpfs /tmp` | Always: every machine has a private `/tmp` in memory | main |
| `-p 8080:8080` | `--net=enable`; guest servers listen on the host's own ports, with no remapping | main |
| `--network none` | `--net=disable` | main |
| Egress allowlists | `--net-allow 'tcp!api.example.com!443'` | main |
| `--memory`, `--cpus`, `--pids-limit` | `--memory`, `--cpus`, `--pids` | main |
| `docker stop` (SIGTERM, then SIGKILL) | SIGTERM to `h9`: a `hangup` note to every process, then a stop 2 s later | main |
| `docker run --stop-timeout`, job deadlines | `--timeout DURATION` | main |
| `docker inspect` | `h9 --print` | main |
| Pulling from a registry | `--root tcp!host!port` (a 9P server) | main |
| The same, over HTTPS | `--root wss://host/path` ([websocket-9p](../design/0021-websocket-9p.md)) | main |
| Pulling a layer at run time | `mount 'wss://…' /dir` in the namespace file, or `wsmount` in the guest | main |
| `docker save`, `docker load` | `tar` the root tree | main |
| Multi-platform images | One tree with `/arm64/bin` and `/amd64/bin`; `--arch` picks | main |
| `docker compose` | A shell script that starts several `h9`s ([section 14](#14-compose-several-machines)) | main |
| `docker exec`, `docker ps`, detached containers | Nothing built in ([section 15](#15-running-containers-stop-logs-restart-exec)); serving a running machine's namespace is proposed | *Not yet available ([serve](../design/0035-serve.md), draft)* |
| Disk-image roots (like a squashfs image) | Proposed | *Not yet available ([image-roots](../design/0014-image-roots.md), draft)* |

## 3. Images are root trees

The root tree that `scripts/mkroot.py` builds is h9's equivalent of a
`debian` or `alpine` base image: about 250 MB of 9front, read-only, with
every program and library file. Every `h9` command that doesn't pass
`--root` already runs in it.

Any other directory that looks like a 9front tree works as `--root`:

```sh
host$ h9 --root ./images/greeter serve
```

So an image is just a directory, and the usual tools work on it: `du`,
`diff -r`, `git`, `rsync`, `tar`.

**Copying the base cheaply.** Most images start as a copy of the base tree
with things added. A plain `cp -R` copies 250 MB; a copy-on-write clone costs
almost nothing and shares blocks with the original until one side changes:

```sh
host$ cp -cR "$H9ROOT/." ./images/base          # macOS (APFS clones)
host$ cp -a --reflink=auto "$H9ROOT/." ./images/base   # Linux (Btrfs, XFS; a full copy elsewhere)
```

Don't use hard links (`cp -al`, `rsync --link-dest`) for an image you'll
write to: writing a hard-linked file through one image changes it in every
image that shares it, and in the base. That's the same caveat `--print`
gives for hard links under writable paths.

**Multiple architectures.** A tree holds binaries for each architecture
side by side, in `/arm64/bin`, `/amd64/bin` and `/386/bin`, and h9 binds
`/$cputype/bin` at `/bin`. One image directory is therefore already a
multi-platform image: `mkroot.py --arch 386,amd64` fills in the other two,
and `--arch` (or the host's architecture) picks which one runs. Only the
emulator runs amd64 and 386 on Apple Silicon.

## 4. FROM scratch: slim images

Plan 9 programs are statically linked. There's no `ld.so`, no shared
libraries and no package database, so a program needs only its binary and
whatever files it opens at run time. That makes slim images easy: copy the
programs you need into an otherwise empty tree.

h9 needs a few directories to exist in any root, because it binds devices
and the host's directories onto them:

| Directory | Needed for |
| --- | --- |
| `/dev` | The console. Required: without it, h9 stops with `bind #y /dev: file does not exist`. |
| `/bin` | The bind of `/$cputype/bin`. Without it, programs can only be run by full path, such as `/arm64/bin/hello`. |
| `/mnt/term/cwd` | The host's current directory. Without it h9 falls back to binding the cwd at `/mnt/term`, and paths in this guide that say `/mnt/term/cwd` won't exist. |
| `/env`, `/proc`, `/fd`, `/srv`, `/net` | The environment, processes, file descriptors, posted services, the network |
| `/tmp` | The machine's private `/tmp`, an overlay in memory over this directory |
| `/rc/bin`, `/rc/lib/rcmain` | rc, if the image uses it: rc reads `rcmain` when it starts |

Here's a script that makes one. It takes the programs from your full root
tree, as paths under `/$cputype/bin`:

```sh
#!/bin/sh
# mkslim: make a minimal root tree holding rc and the named programs.
# usage: mkslim IMAGE [PROGRAM...]   e.g. mkslim ./images/tools cat awk aux/listen1
# The programs come from $H9ROOT; ARCH picks the architecture (default arm64).
set -eu
: "${H9ROOT:?set H9ROOT to a full root tree}"
arch=${ARCH:-arm64}
img=$1; shift
for d in dev bin env proc fd srv net tmp mnt/term/cwd rc/bin rc/lib adm/timezone "$arch/bin"; do
	mkdir -p "$img/$d"
done
cp "$H9ROOT/rc/lib/rcmain" "$img/rc/lib/"
cp "$H9ROOT/adm/timezone/local" "$img/adm/timezone/" 2>/dev/null || true
for p in rc echo "$@"; do
	mkdir -p "$img/$arch/bin/$(dirname "$p")"
	cp "$H9ROOT/$arch/bin/$p" "$img/$arch/bin/$p"
done
```

```sh
host$ ./mkslim ./images/tools cat ls
host$ du -sh ./images/tools
host$ h9 --root ./images/tools --rc 'ls /bin; echo hello from a slim image'
```

A program that isn't in the image fails as it would anywhere: `h9 --root
./images/tools sed` exits 127. A program that opens files the image doesn't
have, such as `/lib/ndb/local`, `/sys/lib/tls/ca.pem` or a font, fails when
it opens them; `--trace` shows which file it was looking for ([manual,
chapter 27](../MANUAL.md#27-debugging)).

**A multi-stage build.** The 9front compilers are in the full tree, so build
there and copy the result into a slim image, the way a Dockerfile builds in
a `golang` stage and copies the binary into `scratch`:

```sh
host$ cat hello.c
#include <u.h>
#include <libc.h>

void
main(void)
{
	print("hello from a scratch image\n");
	exits(nil);
}
host$ h9 --rc '7c hello.c && 7l -o hello hello.7'      # stage 1: the full root
host$ mkdir -p images/hello/dev images/hello/bin images/hello/mnt/term/cwd images/hello/arm64/bin
host$ cp hello images/hello/arm64/bin/                   # stage 2: three directories and one file
host$ h9 --root ./images/hello hello
hello from a scratch image
```

That image is three empty directories (`/dev`, `/bin` and `/mnt/term/cwd`)
and one file. It has no rc, so the program has to be named directly, not run
through `--rc`.

## 5. Entrypoints, environment and WORKDIR

There's no image config file. Its parts go in two places:

- **The entrypoint is a script in the image.** h9 runs rc scripts that start
  with `#!` as programs, so `/app/bin/serve` can be the entrypoint, and its
  arguments are `CMD`. Defaults for environment variables go there too, as
  rc assignments that `--env` can override.
- **The namespace is a file in the image.** `--ns /app/ns` replays a
  namespace file from the root tree after h9 has built the machine's
  namespace and before it looks up the program ([manual, chapter
  24](../MANUAL.md#24-namespace-files-with---ns)). Its `bind` lines are the
  layers, and its `cd` line is `WORKDIR`.

The example used through the rest of this guide is a small web service, the
greeter. It's laid out like a project with a Dockerfile:

```text
greeter/
  app/
    ns          the namespace file
    bin/serve   the entrypoint
    bin/greet   answers one HTTP request
  build.sh      builds the image (section 8)
```

`app/ns` puts the app's own `bin` in front of `/bin`, so its commands are
found by name, and starts in `/app`:

```text
# /app/ns: the greeter's namespace, replayed with --ns /app/ns
bind -b /app/bin /bin
cd /app
```

`app/bin/serve` runs `greet` for every connection, on `$port` (8080 unless
`--env port=...` says otherwise):

```sh
#!/bin/rc
# serve: answer HTTP on $port with greet
if(~ $#port 0) port=8080
echo greeter: listening on $port >[1=2]
exec aux/listen1 -t 'tcp!*!'^$port /bin/greet
```

`app/bin/greet` is one HTTP exchange on standard input and output, which
`aux/listen1` connects to the call. It reads the request up to the blank
line, so the connection doesn't close with data unread, and answers:

```sh
#!/bin/rc
# greet: answer one HTTP request with $greeting
awk '/^\r?$/ { exit }'
if(~ $#greeting 0) greeting=hello
echo 'HTTP/1.0 200 OK'
echo 'Content-Type: text/plain'
echo
echo $greeting from `{cat /dev/sysname}
```

Make both executable (`chmod +x app/bin/*`): exec checks the host's mode
bits.

## 6. Layers are union binds

A Docker layer is a directory of changes stacked on the ones below it by an
overlay file system. In Plan 9, `bind -b new old` puts `new` in front of
`old`, so a lookup in `old` finds `new`'s files first, and `bind -a` puts it
behind. Each bind is a layer, applied to one directory rather than the
whole tree, and you can stack as many as you like. `/bin` is already one:
h9 binds `/$cputype/bin` and then `/rc/bin` after it.

**Layering the app over the stock root, without building anything.** During
development you don't need an image at all. Run from the `greeter`
directory, which h9 binds at `/mnt/term/cwd`, with a namespace file there
that puts `app/bin` in front of the stock `/bin`:

```sh
host$ cd greeter
host$ echo 'bind -b /mnt/term/cwd/app/bin /bin' > dev.ns
host$ h9 --ns dev.ns --net=enable serve &
host$ curl -s localhost:8080
hello from h9
```

That's `docker run -v $PWD:/app`: edit `app/bin/greet` on the host and the
next request runs the new version. A relative `--ns` path is read from
`/mnt/term/cwd`.

**Layers in the image.** Once the app is copied into an image at `/app`, the
image's own `/app/ns` does the same with `bind -b /app/bin /bin`. Layers can
also be separate trees inside the image, stacked by the namespace file:

```text
# /app/ns with two layers over the base's /bin and /lib
bind -b /layers/tools/arm64/bin /bin
bind -b /app/bin /bin
bind -b /layers/tools/lib /lib
cd /app
```

The last `bind -b` is on top, so `/app/bin` wins over the tools layer, which
wins over the base.

**What a union doesn't do.** A union merges one directory, not the
subdirectories below it: if `/layers/tools/lib` and `/lib` both have an
`ndb` directory, `/lib/ndb` is the one from whichever is first, not a merge
of the two. Bind the subdirectory too if you need that. There are no
whiteouts either: a layer can add or shadow files but can't make a lower
file disappear. To hide one, bind something over it, or leave it out of the
image.

**Layers from the host.** A layer can live outside the image: share it with
`--readable` and bind it in. A host path outside the root tree and the cwd
appears at `/mnt/term` followed by its host path ([manual, chapter
21](../MANUAL.md#21-sharing-files-with-the-host)):

```sh
host$ echo 'bind -b /mnt/term/Users/me/src/plugins/bin /bin' > plugins.ns
host$ h9 --readable ~/src/plugins --ns plugins.ns ls /bin
```

**Layers from the network.** With
[websocket-9p](../design/0021-websocket-9p.md), a namespace file can mount a
9P server behind a WebSocket, and then bind from it like any other
directory. The mount point has to exist in the image:

```text
mount 'wss://layers.example.com/tools' /layers/tools
bind -b /layers/tools/arm64/bin /bin
```

h9 makes that connection itself during the replay, before the device mask is
set, and it's outside the network policy, like a 9P root. A program inside
the machine can do the same later with `wsmount URL DIR`, one of h9's own
guest commands; that connection goes through `/net/ws` and is checked against
`--net` and `--net-allow` like any other dial.

## 7. The container's writable layer

A Docker container gets a writable layer over its image, thrown away with
`--rm`. In h9 the root is read-only by default, and there are three ways to
let a program write to it.

**The whole root, in memory.** Make the root a writable path and use
ephemeral writes: every writable path becomes a copy-on-write overlay in
memory, and nothing reaches the host.

```sh
host$ h9 --root ./images/base --writable ./images/base --write=ephemeral \
	--rc 'echo installed > /sys/lib/x && cat /sys/lib/x'
installed
host$ ls ./images/base/sys/lib/x
ls: ./images/base/sys/lib/x: No such file or directory
```

The catch is that `--write=ephemeral` applies to every writable path, the
cwd included, so a run like this can't also keep its output on the host.

**Some directories, in memory.** A namespace file line `bind -c '#O' DIR`
puts a fresh copy-on-write overlay over `DIR`, so that directory takes writes
for the run and the rest of the root stays read-only, while the cwd and
`--writable` paths still write to the host:

```text
# writable.ns: let the program change /usr and /lib/ndb for this run only
bind -c '#O' /usr
bind -c '#O' /lib/ndb
```

```sh
host$ h9 --ns writable.ns --rc 'mkdir /usr/me && echo hi > /usr/me/note && cat /usr/me/note'
hi
```

That's also how to give 9front programs the `$home` they expect, since the
root tree only has `/usr/glenda`. It works for ordinary directories in the
root; the [manual's known issue](../MANUAL.md#24-namespace-files-with---ns)
says why a target that is itself a bind or mount point, such as
`/mnt/term/cwd`, isn't one of them. Overlay writes count against `--memory`.

**The root, by default** *(Not yet available ([overlay](../design/0011-overlay.md)))*.
`--write=overlay` will put `#O` over the root, whatever kind of root it is,
with the cwd and `--writable` paths still writing to the host. That's
Docker's model exactly. Until it lands, it's accepted on the command line but
denies writes, and `--strict` refuses it.

**Committing.** To keep what a run wrote, run it against a copy of the
image with the copy writable. The copy is the new image:

```sh
host$ cp -cR images/base/. images/base-with-ndb
host$ h9 --root ./images/base-with-ndb --writable ./images/base-with-ndb \
	--rc "echo 'sys=build ip=10.0.0.5' >> /lib/ndb/local"
```

Ephemeral changes can't be saved from inside a run yet.

## 8. Building images

A Dockerfile is a list of steps that each produce a layer. Here the steps
are a shell script, and each `RUN` is an `h9` run with the image writable.
The greeter's `build.sh`:

```sh
#!/bin/sh
# build.sh: build the greeter image in ../images/greeter
set -eu
cd "$(dirname "$0")"
img=../images/greeter
rm -rf "$img"

# FROM scratch, with the programs the scripts use
../mkslim "$img" awk cat date aux/listen1

# COPY app /app
cp -R app "$img/app"
chmod +x "$img/app/bin/"*

# RUN: steps that run inside the image and write to it
h9 --root "$img" --writable "$img" --rc 'date > /app/built'

# a smoke test: does the entrypoint at least start?
h9 --root "$img" --ns /app/ns --net=enable --timeout 2s serve 2>&1 | grep -q listening
echo built "$img"
```

```sh
host$ ./greeter/build.sh
built ../images/greeter
host$ du -sh images/greeter
```

The `RUN` step writes into the image directory, so it works on the copy the
script just made and never on the base. When a step needs the full toolchain
(compilers, `mk`), run it with the stock root and the image's directory
writable, and copy the result in, as in [section 4](#4-from-scratch-slim-images).

There's no build cache. Each build starts over, which for a slim image is a
few `cp`s. For a fat one, start from a copy-on-write clone of the base
(section 3) so the copy is free, and order steps so `make`-style tools can
skip what hasn't changed.

**Running it:**

```sh
host$ mkdir -p data
host$ h9 --root ./images/greeter --ns /app/ns --net=enable --cwd ./data --env greeting=hi serve &
greeter: listening on 8080
host$ curl -s localhost:8080
hi from h9
```

## 9. Volumes

Every machine binds one host directory as its working directory,
`/mnt/term/cwd`: the directory you ran `h9` from, or `--cwd DIR`. There's no
way to start without one, so treat it as the container's main volume and
point it at the directory the program should own. Other host paths are
shared one at a time:

| Docker | h9 | Inside |
| --- | --- | --- |
| `-v $PWD:/work` | Run from that directory, or `--cwd DIR` | `/mnt/term/cwd` |
| `-v ./out:/out` | `--writable ./out` | `/mnt/term/cwd/out` if it's inside the cwd, `/mnt/term/<host path>` otherwise |
| `-v ./src:/src:ro` | `--readable ./src` | The same |
| `--read-only` volume for everything | `--profile=tight` (the cwd is read-only) or `--write=none` | |
| A volume over part of the image | `--writable PATH` where `PATH` is inside the root tree | `/` plus the path inside the tree |
| `--tmpfs` | `/tmp`, always; `bind -c '#O' DIR` for other directories | |
| An anonymous volume thrown away with the container | `--write=ephemeral`: writable paths become overlays in memory | |
| `.dockerignore`-like hiding of secrets | `--read-deny PATH`, which wins over every allow | |

The guest can't choose where a host directory appears, because h9 binds it
where its host path says. A namespace file can add a second name for it
anywhere that exists in the image, though, which is how to mount a volume at
`/data`:

```text
# /app/ns: the cwd is the greeter's data volume, also at /app/data
bind /mnt/term/cwd /app/data
```

`/app/data` has to exist in the image, as a mount point does in Linux.

## 10. Networking and published ports

A guest uses the host's network stack directly. There's no bridge, NAT or
container IP address, so connections come from your host's addresses, and a
guest server listens on the host's own port.

| Docker | h9 |
| --- | --- |
| Default bridge network, outbound allowed | `--net=outbound`, the default: connects allowed, listening refused |
| `-p 8080:8080` | `--net=enable`: the guest's `announce` listens on the host's port |
| `-p 127.0.0.1:8080:8080` | `--net=enable`, and announce on `tcp!127.0.0.1!8080` in the guest |
| `-p 9000:8080` (remapping) | No equivalent: pass the port in, as the greeter's `--env port=9000` does |
| `--network none` | `--net=disable` (`--profile=tight`'s default) |
| An egress allowlist (a Kubernetes NetworkPolicy, a filtering proxy) | `--net-allow PATTERN`, repeatable |
| Container DNS names (`db:5432`) | Use `127.0.0.1` and distinct ports ([section 14](#14-compose-several-machines)) |

Since nothing remaps ports, two machines can't both listen on 8080; give each
one its own port. Listening on `*` reaches anything that can reach your
host, as `-p` does, and `--print` lists that as a caveat.

`--net-allow` is a tighter egress policy than Docker has built in: every
connect has to match a pattern, and `/net/cs` resolves only names a pattern
covers ([manual, chapter 15](../MANUAL.md#15-networking)):

```sh
host$ h9 --net-allow 'tcp!api.github.com!443' --rc 'mkdir -p /tmp/m/web && bind -a /tmp/m /mnt && webfs && hget https://api.github.com/zen'
```

## 11. Resource limits

| Docker | h9 | What happens at the limit |
| --- | --- | --- |
| `--memory 512m` | `--memory 512m` (default 1 GB, at most 32 GB) | Allocation fails (`malloc` returns nil); `/tmp` and overlay writes fail with `file system full`. Overlay contents count too. |
| `--cpus 2` | `--cpus 2` | Nothing fails: past 2 processes running guest code, the rest wait |
| `--pids-limit 64` | `--pids 64` | `rfork` fails with `no procs` |
| `--stop-timeout`, a job's deadline | `--timeout 30s` | `hangup` to every process, a stop 2 s later, exit 1 |
| `--ulimit`, `--device-read-bps`, disk quotas | None | Writes to writable host paths aren't capped (`--print` says so) |

[Manual, chapter 23](../MANUAL.md#23-resource-limits) has the details.

## 12. docker inspect: reading the plan

`--print` compiles the flags into the machine's plan and prints it without
running anything: the capabilities in force, the limits, the devices a
program can't attach, the namespace in namespace-file syntax, the host paths
and their access, and the caveats. It's the closest thing to `docker
inspect`, and it works before the container exists:

```sh
host$ h9 --print --root ./images/greeter --ns /app/ns --net=enable --cwd ./data --memory 256m serve
```

Two things it shows that Docker users should know. The namespace part is the
whole container in a few lines, and it replays with `--ns`, so you can save it
as a starting point. And the `caveats:` section lists what this configuration
doesn't protect against.

`--strict` refuses to run, with exit 2, if a flag asks for something this
build can't enforce, such as `--write=overlay` today. Use it in scripts that
must not silently get a weaker sandbox than they asked for.

## 13. Registries: serving images over 9P

Docker images move as tarballs through a registry. h9 roots can come over
the network as a file server instead, read on demand, so a machine starts
without downloading the whole image.

**A local registry.** One h9 serves a directory of images over 9P with
`exportfs`, read-only, and any number of others use one as their root.
Run it from the directory holding the images, so they're under
`/mnt/term/cwd`:

```sh
host$ cd images
host$ h9 --net=enable --write=none aux/listen1 -t 'tcp!127.0.0.1!5640' /bin/exportfs -R -r /mnt/term/cwd/greeter &
host$ cd ..
host$ h9 --root 'tcp!127.0.0.1!5640' --ns /app/ns --net=enable --cwd ./data serve
```

`--ns /app/ns` is read from the 9P root, so the image's config travels with
it. `/tmp` is an overlay over the image's `/tmp`, as for a directory root.
The connection is plain, unauthenticated 9P, so keep TCP roots on a trusted
network ([manual, chapter 16](../MANUAL.md#16-file-servers-srv-and-9p-mounts));
servers that ask for authentication are [proposed](../design/root-auth.md).
On macOS and Linux a unix socket works too, as `--root unix!/path`.

`--root-spec NAME` sends an attach name, so a 9P server that offers several
trees under different names can serve several images on one port, the way a
registry serves `name:tag`. `exportfs -r` serves one tree; a server that
switches on the attach name would have to be written (`9p(2)`) or come from
elsewhere.

**Over HTTPS.** [websocket-9p](../design/0021-websocket-9p.md) adds
WebSocket roots, which go through HTTP proxies and TLS and can carry an
`Authorization` header, as a registry pull does:

```sh
host$ h9 --root wss://registry.example.com/greeter \
	--root-header "Authorization: Bearer $TOKEN" --ns /app/ns --net=enable serve
```

To try it locally, the repo's test relay forwards WebSocket connections to the
exportfs above:

```sh
host$ zig build wsrelay -- 8080 5640 &
host$ h9 --root ws://localhost:8080/9p --ns /app/ns --net=enable --env port=8081 serve
```

**Save and load.** An image directory is files, so `docker save` is `tar -C
images/greeter -czf greeter.tgz .` and `docker load` is untarring it. Keep
the mode bits: exec checks them.

## 14. Compose: several machines

A compose file declares services, the network between them and the order
they start in. With h9 that's a shell script: start each machine in the
background, keep the pids, and stop them on the way out. Machines can't see
each other's `/srv` or processes, so they talk over the network, on
`127.0.0.1` and distinct ports.

```sh
#!/bin/sh
# up.sh: the greeter, and a client that may only reach the greeter
set -u
pids=
trap 'kill $pids 2>/dev/null' EXIT INT TERM

h9 --root ./images/greeter --ns /app/ns --net=enable --cwd ./data \
	--env port=8080 --memory 256m serve &
pids="$pids $!"
sleep 1

h9 --net-allow 'tcp!127.0.0.1!8080' --rc '
	mkdir -p /tmp/m/web && bind -a /tmp/m /mnt && webfs
	hget http://127.0.0.1:8080/'
```

```sh
host$ ./up.sh
greeter: listening on 8080
hello from h9
```

The client runs in the stock root because it needs `webfs` and `hget`, and
its `--net-allow` lets it reach the greeter and nothing else. Killing a
service's `h9` with SIGTERM is `docker compose down` for it (section 15).

Services can share files the Plan 9 way, by serving them. A "database"
machine serving its data volume over 9P:

```sh
host$ h9 --net=enable --cwd ./db-data aux/listen1 -t 'tcp!127.0.0.1!5641' /bin/exportfs -r /mnt/term/cwd &
host$ h9 --net-allow 'tcp!127.0.0.1!5641' --rc 'srv tcp!127.0.0.1!5641 db && mkdir /tmp/db && mount /srv/db /tmp/db && ls /tmp/db'
```

## 15. Running containers: stop, logs, restart, exec

| Docker | h9 |
| --- | --- |
| `docker run -d` | Run `h9` in the background (`&`, `nohup`, a launchd or systemd unit) |
| `docker ps` | `pgrep -fl h9` |
| `docker stop` | `kill PID` (SIGTERM): every process gets `hangup`, and the machine stops 2 s later. A second Ctrl-C in the foreground stops it at once. |
| `docker kill` | `kill -9 PID` |
| `docker logs` | `h9`'s standard output and error: redirect them to a file |
| `--restart on-failure` | A loop in the unit or script, reading the exit code |
| `docker wait` | `wait PID`; the exit code follows the [manual's table](../MANUAL.md#exit-status) |
| `HEALTHCHECK` | A host-side probe, such as `curl -fs localhost:8080` |
| `docker exec` | None yet |

A restart policy that tells the program failing from h9 failing:

```sh
#!/bin/sh
# keep the greeter up; give up if h9 itself can't start it
while :; do
	h9 --root ./images/greeter --ns /app/ns --net=enable --cwd ./data serve
	code=$?
	case $code in
	2|125|126|127) echo "h9 failed ($code); not restarting" >&2; exit $code;;
	esac
	sleep 1
done
```

**Looking inside a running machine.** There's no `docker exec`: nothing
outside a machine can start a process in it, and machines can't see each
other. A service can choose to export its own namespace, though, and then
another machine can mount it and read its `/proc`, `/env` and files, which
covers much of what `exec` is used for. Add a line to the entrypoint before
it `exec`s:

```sh
aux/listen1 -t 'tcp!127.0.0.1!5650' /bin/exportfs -r / &
```

```sh
host$ h9 --net-allow 'tcp!127.0.0.1!5650' --rc 'srv tcp!127.0.0.1!5650 c && mkdir /tmp/c && mount /srv/c /tmp/c && ls /tmp/c/proc /tmp/c/env'
```

That export is unauthenticated and read-write, so keep it on loopback and
only for debugging. A machine serving its namespace as a built-in feature is
the [serve](../design/0035-serve.md) proposal, still a draft.

## 16. What's missing

Things Docker does that h9 doesn't, with the proposal that would change it
where there is one:

- **The root's writable layer as the default.** Use `--write=ephemeral
  --writable ROOT` or `bind -c '#O'` until
  [overlay](../design/0011-overlay.md) is built (accepted; no PR yet).
- **Exec, attach and inspecting a running machine.** See section 15;
  [serve](../design/0035-serve.md) is a draft.
- **Image files.** Images are directories or 9P servers; a single-file image
  you can attach read-only is [image-roots](../design/0014-image-roots.md), a
  draft.
- **Authenticated registries.** 9P roots can't ask for authentication yet
  ([root-auth](../design/root-auth.md), a draft). WebSocket roots can send a
  bearer token in a header.
- **A build cache, image IDs and digests.** Build scripts start over each
  time; `tar | shasum` gives a digest if you need one.
- **Network isolation between machines.** There's no private network: guests
  use the host's, so isolation is `--net-allow` on each side.
- **Disk quotas.** Writes to writable host paths aren't capped.
- **Running Linux images.** h9 runs 9front programs. A Linux personality is
  [proposed](../design/0018-linux-personality.md).
- **A daemon, an API, Windows and Linux hypervisors.** h9 is a command, not a
  service. On Linux and Windows it runs on the emulator until the
  [kvm](../design/0016-kvm.md) and [whp](../design/0017-whp.md) backends land.

## 17. Putting it together: h9box

Everything above fits in one shell script of about 200 lines,
[`h9box`](containers/h9box), a docker-like CLI where h9 does all the work.
Reading it is a good review of this guide, since each command is a few lines
over a feature from an earlier section. Put it on your `PATH`, with `H9ROOT`
set to the full root tree:

```text
h9box build NAME [DIR]              build DIR/Boxfile into the image NAME
h9box run [OPTS] IMAGE [CMD...]     run a machine from an image
h9box inspect [OPTS] IMAGE [CMD...] print the plan run would use
h9box images | tag | rm | save | load | serve
```

**Images** are root trees in `~/.h9box/images` (or `$H9BOX/images`), as in
[section 3](#3-images-are-root-trees). Each one has a `/box` directory with
the config Docker keeps in JSON, as three plain files:

| File | Holds | Used as |
| --- | --- | --- |
| `/box/ns` | `bind` and `cd` lines | `--ns /box/ns`: the layers and `WORKDIR` ([sections 5 and 6](#5-entrypoints-environment-and-workdir)) |
| `/box/env` | `name=value` lines | One `--env` each |
| `/box/cmd` | The command, one argument per line | The program and its arguments when `run` gets none |

Because the config is inside the tree, it travels with the image: `save`,
`tag` and `serve` don't need to know about it.

**A Boxfile** is a Dockerfile with fewer instructions. Here's the greeter's,
which replaces `build.sh` from [section 8](#8-building-images):

```text
# Boxfile: the greeter
FROM scratch
COPY --from=9front rc echo awk cat date aux/listen1
COPY app /app
BIND -b /app/bin /bin
WORKDIR /app
ENV greeting=hello
ENV port=8080
CMD serve
RUN date > /app/built
```

```sh
host$ cd greeter && rm app/ns
host$ h9box build greeter
RUN date > /app/built
greeter
host$ h9box run -p -e greeting=hi greeter &
greeter: listening on 8080
host$ curl -s localhost:8080
hi from h9
```

(`app/ns` goes because the Boxfile's `BIND` and `WORKDIR` lines write
`/box/ns` now.) The `build` function reads the Boxfile line by line:

- `FROM scratch` makes the skeleton from [section 4](#4-from-scratch-slim-images)
  (`/dev`, `/bin`, `/mnt/term/cwd` and the other mount points), `FROM 9front`
  clones `$H9ROOT`, and `FROM NAME` clones another image, its `/box` included,
  so the new image inherits its config as a Docker image does. The `clone`
  function uses `cp -c` on macOS and `--reflink` on Linux, so a fat base is
  nearly free ([section 3](#3-images-are-root-trees)).
- `COPY --from=9front PROGRAM...` copies statically linked programs out of
  the full tree, and `rc`'s `rcmain` with them. `COPY --from=NAME SRC DEST`
  copies out of another image, which is a multi-stage build.
- `RUN` is `h9 --root IMAGE --writable IMAGE --rc '...'`, with the image's
  namespace and environment, so it writes into the image being built
  ([section 7](#7-the-containers-writable-layer), "Committing"). Its cwd is
  the build directory, as Docker's build context is.
- `BIND` and `WORKDIR` append `bind` and `cd` lines to `/box/ns`, `ENV` a
  line to `/box/env`, and `CMD` writes `/box/cmd`.

The image is built in `NAME.new` and renamed over the old one at the end, so
a failed build leaves the previous image in place. There's no build cache.

**`run`** turns Docker's options into h9 flags, adds the image's
`--ns /box/ns` and `--env` flags in front of yours (so `-e` wins, since the
last `--env` for a name does), and runs the image's `CMD` if you don't give a
command:

| `h9box run` | h9 flag | Section |
| --- | --- | --- |
| `-e NAME=VALUE` | `--env NAME=VALUE` | [5](#5-entrypoints-environment-and-workdir) |
| `-v PATH` | `--writable PATH` | [9](#9-volumes) |
| `-r PATH` | `--readable PATH` | [9](#9-volumes) |
| `-p` | `--net=enable` | [10](#10-networking-and-published-ports) |
| `-w` | `--writable IMAGE --write=ephemeral`: the root takes writes, in memory | [7](#7-the-containers-writable-layer) |
| `--memory=256m`, `--net-allow=...`, any `--flag=value` | Passed through | [11](#11-resource-limits) |

h9 flags have to be written `--flag=value`, so `run` can tell them from the
image name. `-w` makes the volumes from `-v` ephemeral too, the limitation
[section 7](#7-the-containers-writable-layer) describes; `--write=overlay`
will remove it.

**`inspect`** is `run --print`, so it shows exactly the machine `run` would
start ([section 12](#12-docker-inspect-reading-the-plan)):

```sh
host$ h9box inspect -p --memory=256m greeter
```

**The rest** are one or two lines each: `images` is `du -sh` over the image
directories, `tag` is a clone, `rm` is `rm -rf`, `save` and `load` are `tar`,
and `serve` is the exportfs registry from [section 13](#13-registries-serving-images-over-9p).
An image name that's a dial string or a URL is used as `--root` directly, so
a served image runs like a local one:

```sh
host$ h9box serve greeter 5640 &
host$ h9box run -p -e port=8081 'tcp!127.0.0.1!5640'
host$ h9box run -p -e port=8082 ws://localhost:8080/9p     # through zig build wsrelay
```

For a served image, `run` reads `/box/env` and `/box/cmd` by running `cat`
in a machine on that root, so the image needs `cat`, or you name the command
yourself.

**What it leaves out** is what [section 16](#16-whats-missing) lists: there's
no `ps`, `stop`, `logs` or `exec`, because there's no daemon keeping track of
machines. `run` is the machine, so the host's job control is `ps` and `stop`,
and its standard output is the log. Adding them means keeping a pid file per
run in `$H9BOX`, which is a good exercise and the point where a real tool
would start.
