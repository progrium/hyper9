# h9 recipes

Quick things to do with h9. The [manual](../MANUAL.md) explains how they
work.

Each recipe is also a plan ([plan-format](../design/plan-format.md)): a file
of the lines its flags compile to, which `h9 --plan FILE` runs and which can
be checked in, diffed, and reviewed. `h9 FLAGS --print` writes the full plan,
every default spelled out; the plans below have only the lines that differ
from the defaults, which is all a plan needs. A program after `--plan FILE`
replaces the plan's `run` line, and a flag after it can only narrow it, so
`h9 --plan ci.plan --memory 512m` works and `h9 --plan ci.plan --net=enable`
is exit 2.

```sh
h9 --profile=tight --timeout 10m --print mk test > ci.plan
h9 --plan ci.plan
```

## Everyday

Use 9front tools in a host pipeline:

```sh
git log --format=%an | h9 sort | h9 uniq -c | h9 sort -nr | sed 5q
```

Structural regex edits with `ssam`:

```sh
h9 ssam 'x/oldName/ c/newName/' < main.c > main.c.new
h9 ssam -n 'x/(.+\n)+/ g/TODO/ p' < notes.txt    # paragraphs mentioning TODO
```

Make any 9front tool a host command:

```sh
alias 9=h9          # then: 9 wc -l *.c
```

Run an rc script from your directory:

```sh
h9 rc build.rc arg1 arg2
```

Read a man page:

```sh
h9 man rc | less
```

These need no flags, so each is a plan of one line, its program: `run sort`,
`run ssam 'x/oldName/ c/newName/'`, `run rc build.rc arg1 arg2`, and
`run man rc`, run with `h9 --plan FILE`.

## Sandboxing

Let a script loose on your project, then throw its changes away:

```sh
h9 --write=ephemeral --net=disable --rc 'rc ./untrusted.rc; ls -l'
```

As a plan, `untrusted.plan`:

```text
write ephemeral
net disable
run /bin/rc -c 'rc ./untrusted.rc; ls -l'
```

Same, but keep the result for review as a tar archive:

```sh
h9 --write=ephemeral --rc '{ rc ./untrusted.rc } >[1=2]; tar c .' > result.tar
```

As a plan, `review.plan`, run with `h9 --plan review.plan > result.tar`:

```text
write ephemeral
run /bin/rc -c '{ rc ./untrusted.rc } >[1=2]; tar c .'
```

Lock a CI job down:

```sh
h9 --profile=tight --memory 1g --timeout 10m --pids 64 mk test
```

As a plan, `ci.plan`:

```text
profile tight
memory 1G
pids 64
timeout 10m
run mk test
```

Fail CI if the sandbox gets loosened:

```sh
h9 --print --profile=tight mk test | grep -q '^# enforces:.* net.disable' || exit 1
```

With the plan checked in, review its diff instead, or check it the same way:
`h9 --plan ci.plan --print | grep -q '^net disable$' || exit 1`.

Hide secrets from a tool that reads your project:

```sh
h9 --read-deny .env --read-deny secrets ./tool
```

As a plan, `tool.plan`:

```text
deny read .env
deny read secrets
run ./tool
```

See what a program tried and got refused:

```sh
h9 --trace=t.txt ./tool; grep 'permission denied' t.txt
```

`--trace` isn't a plan line, since it's about the run, not the machine, so
it goes beside one: `h9 --plan tool.plan --trace=t.txt`.

## Files and mounts

Make `/n` and `/mnt` fill in on demand, as on 9front:

```sh
h9 --rc 'mntgen && mntgen /mnt && webfs && hget http://example.com/ | sed 3q'
```

As a plan, `mntgen.plan`:

```text
run /bin/rc -c 'mntgen && mntgen /mnt && webfs && hget http://example.com/ | sed 3q'
```

Scratch space in memory:

```sh
h9 --rc 'ramfs -S s && mkdir /tmp/s && mount -c /srv/s /tmp/s && cd /tmp/s && ...'
```

As a plan, `scratch.plan`:

```text
run /bin/rc -c 'ramfs -S s && mkdir /tmp/s && mount -c /srv/s /tmp/s && cd /tmp/s && ...'
```

A home directory that persists on the host:

```sh
mkdir -p ~/.h9home
h9 --writable ~/.h9home --env home=/mnt/term$HOME/.h9home rc -li
```

As a plan, `home.plan`, with its paths written out, since a plan doesn't expand `$HOME`:

```text
allow write /Users/me/.h9home
env home=/mnt/term/Users/me/.h9home
run rc -li
```

Mount a remote 9P server, allowing nothing else on the network:

```sh
h9 --net-allow 'tcp!fs.example.com!564' --rc 'srv tcp!fs.example.com!564 fs && mkdir /tmp/fs && mount /srv/fs /tmp/fs && ls /tmp/fs'
```

As a plan, `fs.plan`:

```text
netallow tcp!fs.example.com!564
run /bin/rc -c 'srv tcp!fs.example.com!564 fs && mkdir /tmp/fs && mount /srv/fs /tmp/fs && ls /tmp/fs'
```

Mount a 9P server over WebSocket:

```sh
h9 --rc 'mkdir /tmp/fs && wsmount -h $1 wss://fs.example/9p /tmp/fs && ls /tmp/fs' "Authorization: Bearer $TOKEN"
```

As a plan, `wsfs.plan`, for a server that takes no token. A plan doesn't
hold a secret: the `wss://` root below names its header in a file instead.

```text
run /bin/rc -c 'mkdir /tmp/fs && wsmount wss://fs.example/9p /tmp/fs && ls /tmp/fs'
```

## Serving 9P

Serve one h9's root tree to another:

```sh
h9 --net=enable aux/listen1 -t 'tcp!127.0.0.1!5640' /bin/exportfs -R -r / &
h9 --url tcp://127.0.0.1:5640 ls /
```

As plans, the server's, `export.plan`, and the client's, `client.plan`:

```text
net enable
run aux/listen1 -t tcp!127.0.0.1!5640 /bin/exportfs -R -r /
```

```text
url tcp://127.0.0.1:5640
run ls /
```

Serve a host directory from Go (it's served read-write, so use a copy):

```sh
go run github.com/Harvey-OS/ninep/cmd/ufs@latest -root /tmp/rootcopy -addr 127.0.0.1:5640 &
h9 --url tcp://127.0.0.1:5640 ls /
```

As a plan, `client.plan`, as above:

```text
url tcp://127.0.0.1:5640
run ls /
```

Put any of those behind a WebSocket:

```sh
zig build wsrelay -- 8080 5640 &
h9 --url ws://localhost:8080/9p ls /
```

As a plan, `ws.plan`:

```text
url ws://localhost:8080/9p
run ls /
```

Use a root over `wss://` with a token kept out of `ps`:

```sh
echo "Authorization: Bearer $TOKEN" > hdr && h9 --url wss://fs.example/9p:/:header=@hdr ls /
```

As a plan, `wss.plan` (the header is named by its file, so the plan holds no secret`:

```text
url wss://fs.example/9p:/:header=@hdr
run ls /
```

Keep a project's mounts in a namespace file next to its code:

```sh
echo 'mount -c wss://fs.example/9p /n' > ns && h9 --ns ns ls /n
```

A plan takes namespace lines too, after its mounts, so the project's plan can
be the whole machine, `project.plan`:

```text
mount -c wss://fs.example/9p /n
run ls /n
```

Pin a tree, so the plan means the same tree wherever it runs: `b3=` is the
BLAKE3 hash of its index, and h9 refuses a tree whose index has another
(`b3sum` is any BLAKE3 tool):

```text
url 'src=https://fs.example/9p,dst=/,index=https://fs.example/9p/.fs/index,b3=9f2c4e7a1b3d5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcd'
run ls /
```

```sh
curl -s https://fs.example/9p/.fs/index | b3sum    # the hash for b3=
```

If you write your own 9P server, answer partial walks with the qids found so
far, not an error: h9 can't set up its namespace otherwise.

## Building

Compile a C program:

```sh
h9 --rc '7c hello.c && 7l -o hello hello.7' && h9 ./hello
```

As a plan, `cc.plan`:

```text
run /bin/rc -c '7c hello.c && 7l -o hello hello.7'
```

Compile a POSIX C program:

```sh
h9 pcc -o hello hello.c && h9 ./hello
```

As a plan, `pcc.plan`:

```text
run pcc -o hello hello.c
```

Build for every architecture (needs a root made with `zig build mkroot -- --arch 386,amd64`):

```sh
h9 --rc 'for(objtype in arm64 amd64 386) mk'
```

As a plan, `all.plan`:

```text
run /bin/rc -c 'for(objtype in arm64 amd64 386) mk'
```

Try `mk install` into the root without changing it:

```sh
h9 --write=ephemeral --writable "$H9ROOT" --rc 'mk install && hello'
```

As a plan, `install.plan`, with `$H9ROOT` written out`:

```text
write ephemeral
allow write /Users/me/h9root
run /bin/rc -c 'mk install && hello'
```

## Go

Run a Go program (on Apple Silicon, it runs on the emulator):

```sh
GOOS=plan9 GOARCH=amd64 go build -o hello . && h9 ./hello
```

As a plan, `hello.plan`:

```text
run ./hello
```

Skip the 9front root entirely, which Go doesn't need:

```sh
mkdir -p goroot/{bin,dev,env,fd,mnt/term/cwd,net,proc,srv,tmp}
h9 --dir goroot ./hello
```

As a plan, `goroot.plan`:

```text
dir goroot
run ./hello
```

Run a package's tests on Plan 9:

```sh
GOOS=plan9 GOARCH=amd64 go test -c -o pkg.test ./pkg
h9 --dir goroot --cwd ./pkg ./pkg.test -test.v
```

As a plan, `gotest.plan`:

```text
dir goroot
cwd ./pkg rw
run ./pkg.test -test.v
```

Serve HTTP from inside h9, sharing only the current directory, read-only:

```sh
h9 --profile=tight --net=enable ./server    # then curl localhost:8080 on the host
```

As a plan, `server.plan`:

```text
profile tight
net enable
run ./server
```
