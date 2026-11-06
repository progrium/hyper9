# h9 recipes

Quick things to do with h9. The [manual](../MANUAL.md) explains how they
work.

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

## Sandboxing

Let a script loose on your project, then throw its changes away:

```sh
h9 --write=ephemeral --net=disable --rc 'rc ./untrusted.rc; ls -l'
```

Same, but keep the result for review as a tar archive:

```sh
h9 --write=ephemeral --rc '{ rc ./untrusted.rc } >[1=2]; tar c .' > result.tar
```

Lock a CI job down:

```sh
h9 --profile=tight --memory 1g --timeout 10m --pids 64 mk test
```

Fail CI if the sandbox gets loosened:

```sh
h9 --print --profile=tight mk test | grep -q '^enforces:.* net.disable' || exit 1
```

Hide secrets from a tool that reads your project:

```sh
h9 --read-deny .env --read-deny secrets ./tool
```

See what a program tried and got refused:

```sh
h9 --trace=t.txt ./tool; grep 'permission denied' t.txt
```

## Files and mounts

Make `/n` and `/mnt` fill in on demand, as on 9front:

```sh
h9 --rc 'mntgen && mntgen /mnt && webfs && hget http://example.com/ | sed 3q'
```

Scratch space in memory:

```sh
h9 --rc 'ramfs -S s && mkdir /tmp/s && mount -c /srv/s /tmp/s && cd /tmp/s && ...'
```

A home directory that persists on the host:

```sh
mkdir -p ~/.h9home
h9 --writable ~/.h9home --env home=/mnt/term$HOME/.h9home rc -li
```

Mount a remote 9P server, allowing nothing else on the network:

```sh
h9 --net-allow 'tcp!fs.example.com!564' --rc 'srv tcp!fs.example.com!564 fs && mkdir /tmp/fs && mount /srv/fs /tmp/fs && ls /tmp/fs'
```

Mount a 9P server over WebSocket:

```sh
h9 --rc 'mkdir /tmp/fs && wsmount -h $1 wss://fs.example/9p /tmp/fs && ls /tmp/fs' "Authorization: Bearer $TOKEN"
```

## Serving 9P

Serve one h9's root tree to another:

```sh
h9 --net=enable aux/listen1 -t 'tcp!127.0.0.1!5640' /bin/exportfs -R -r / &
h9 --root 'tcp!127.0.0.1!5640' ls /
```

Serve a host directory from Go (it's served read-write, so use a copy):

```sh
go run github.com/Harvey-OS/ninep/cmd/ufs@latest -root /tmp/rootcopy -addr 127.0.0.1:5640 &
h9 --root 'tcp!127.0.0.1!5640' ls /
```

Put any of those behind a WebSocket:

```sh
zig build wsrelay -- 8080 5640 &
h9 --root ws://localhost:8080/9p ls /
```

Use a root over `wss://` with a token kept out of `ps`:

```sh
echo "Authorization: Bearer $TOKEN" > hdr && h9 --root wss://fs.example/9p --root-header @hdr ls /
```

Keep a project's mounts in a namespace file next to its code:

```sh
echo 'mount -c wss://fs.example/9p /n' > ns && h9 --ns ns ls /n
```

If you write your own 9P server, answer partial walks with the qids found so
far, not an error: h9 can't set up its namespace otherwise.

## Building

Compile a C program:

```sh
h9 --rc '7c hello.c && 7l -o hello hello.7' && h9 ./hello
```

Compile a POSIX C program:

```sh
h9 pcc -o hello hello.c && h9 ./hello
```

Build for every architecture (needs a root made with `mkroot.py --arch 386,amd64`):

```sh
h9 --rc 'for(objtype in arm64 amd64 386) mk'
```

Try `mk install` into the root without changing it:

```sh
h9 --write=ephemeral --writable "$H9ROOT" --rc 'mk install && hello'
```

## Go

Run a Go program (on Apple Silicon, use `h9-emu`):

```sh
GOOS=plan9 GOARCH=amd64 go build -o hello . && h9 ./hello
```

Skip the 9front root entirely, which Go doesn't need:

```sh
mkdir -p goroot/{bin,dev,env,fd,mnt/term/cwd,net,proc,srv,tmp}
h9 --root goroot ./hello
```

Run a package's tests on Plan 9:

```sh
GOOS=plan9 GOARCH=amd64 go test -c -o pkg.test ./pkg
h9 --root goroot --cwd ./pkg ./pkg.test -test.v
```

Serve HTTP from inside h9, sharing only the current directory, read-only:

```sh
h9 --profile=tight --net=enable ./server    # then curl localhost:8080 on the host
```
