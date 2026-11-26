---
slug: libh9
title: libh9, machines behind a C ABI
status: draft
created: 2026-11-26
authors: [progrium]
depends: []
areas: [api, build]
branch: [claude/project-thread-prxykq]
---

# Proposal: libh9, machines behind a C ABI

## Abstract

h9's machines are a Zig library, so only Zig programs can embed them. This proposal adds libh9: a shared library with a small C ABI over `Machine`, in which a machine is configured with the `h9` command's own flags. Releases ship it for Linux (glibc) on amd64 and arm64, macOS on arm64, and Windows on amd64. Its first user is go-h9, a Go package that loads it without cgo.

## Background

[docs/embedding.md](../docs/embedding.md) covers embedding from Zig, through the `h9` module. A program in another language has to run the `h9` command as a child process, which costs a process per run and gives no handle on a running machine.

A proof of concept in November (`docs/embedding/capi.zig`, never merged) showed a Go program running concurrent machines through a shared library loaded with purego, `CGO_ENABLED=0`. It found two things a shared build needs: drawterm's C must be built with hidden visibility, since its `error` bound to glibc's and killed the host, and h9's signal handlers need `SA_ONSTACK` in a Go host. Its ABI ran one a.out with fixed options.

The namespace kernel already ships a C library, `libh9ns.a` with [h9ns.h](../src/nskernel/h9ns.h) ([namespace-kernel](epoch-0/namespace-kernel.md)), but it has nothing for running programs.

## Proposal

`zig build libh9` builds [src/capi.zig](../src/capi.zig) as a shared library, `libh9.so`, `libh9.dylib`, or `h9.dll`, into `zig-out/libh9` with [src/capi/h9.h](../src/capi/h9.h). The ABI:

- `h9_machine_new(flags, nflags, errbuf, errcap)` makes a machine from `h9` command flags, parsed by [src/cli.zig](../src/cli.zig) and resolved as [src/main.zig](../src/main.zig) resolves them, without the environment: no `$H9ROOT`, `$TMPDIR`, proxies, or host cwd. With nothing on `/`, the root is the built-in one. The command's own modes (`--check`, `--version`, `--help`, `--print`, and `--rc`) are refused, and so, for now, are `--gfx`, `--serve`, `--trace`, and `--cred`.
- `h9_machine_run(m, argv, argc, aout, aoutlen, in, out, err, status, statuscap)` runs one program: the a.out or ELF bytes given, or `argv[0]` looked up in the namespace. `in`, `out`, and `err` are host descriptors (HANDLEs on Windows) for this run alone, or `H9_NOFD`. It returns `H9_EXITED` or `H9_KILLED` with the message, or -1 with why it didn't run.
- `h9_machine_signal(m, H9_INTERRUPT | H9_HANGUP | H9_STOP)` is `Machine.Signals`.
- `h9_machine_engine`, `h9_machine_arch`, `h9_machine_free`, `h9_version`, and `h9_abi_version`.

`H9_ABI_VERSION` changes with every change to the ABI until a later proposal declares it stable.

On ELF hosts, a version script exports only these names. Drawterm's C is built with `-fvisibility=hidden` everywhere, which changes nothing in a static link. After each machine is made, libh9 adds `SA_ONSTACK` to the handlers h9 installed: std.Io.Threaded's `SIGIO` and `SIGPIPE`, and KVM's kick signal.

`scripts/release.sh` adds `libh9-<version>-<target>` archives for `x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos`, and `x86_64-windows-gnu`, with `h9.h` and the licences. Linux's are built against glibc, because a program that loads a shared library has glibc's loader.

[docs/embedding/hello.c](../docs/embedding/hello.c) is a C program on libh9, built by `zig build libh9-example`, and `zig build test` runs it on the hello fixture with hcpu.

## Rationale

**Flags, not a struct of options.** `Machine.Options` has some forty fields and grows with each proposal. A C struct for it would fix a layout that every change breaks, and a setter per field would make the ABI as large as the options. The flags are already specified ([spec/cli.md](../spec/cli.md)), parsed, and documented in the manual, and a new one reaches libh9 with no change to the ABI. The cost is that errors come back as text, which is what the command prints anyway.

**Standard I/O per run.** The proof of concept took the console's descriptors when the machine was made. A host that copies output through a pipe, as Go's `io.Writer` needs, then can't tell when a run's output is all through. Per run, the host closes its end when the run returns and waits for the copy to finish, as `os/exec` does.

**A shared library, not a static one.** A static `libh9.a` would need cgo in Go, and the host's C toolchain to link Zig's output and drawterm's C, on each platform. A shared library loads into a Go program built without cgo, and cross-compiles. go-h9 fetches it from releases, since `go get` can't run the Zig build.

**Its own library, not part of libh9ns.** The namespace kernel is built without the engines on purpose, so a namespace host stays small.

**Not in Zig's module.** The `h9` Zig module stays the full API. libh9 is the subset that's worth fixing in C.

## Compatibility

No change to CLI flags, exit codes, `Machine.Options`, or sandbox defaults. `src/stdin.zig` gains `initFd`, for a descriptor other than stdin. `-fvisibility=hidden` on drawterm's C changes nothing in the `h9` binary or `libh9ns.a`.

## Security

None new. A machine made through libh9 has the policy its flags give, compiled as the command's are, and the library reads no environment, so nothing outside the flags widens it.

## Done criteria

- [x] `zig build libh9` builds libh9 and installs h9.h on Linux, macOS, and Windows.
- [x] `zig build test` runs docs/embedding/hello.c on the hello fixture.
- [x] `scripts/release.sh` builds the libh9 archives.
- [ ] go-h9's tests pass against libh9 on Linux (amd64 and arm64), macOS, and Windows.
- [ ] A release has the libh9 archives, and go-h9 is pinned to it.

## Implementation

1. src/capi.zig, src/capi/h9.h, and `zig build libh9`.
2. docs/embedding/hello.c, and the "From C and other languages" section of docs/embedding.md.
3. The release archives.
4. go-h9, in its own repository, with CI that builds libh9 from this repository.

## Open issues

- `--gfx` needs the main thread on macOS (`h9.gfx.main`), which a host language owns. `--serve`, `--trace`, and `--cred` need a way to report addresses and to run helpers from the host's environment.
- An in-process 9P server (Go's, for example) can be mounted with an `.fd` mount today through the `fd` mount kind, once the flags can name a descriptor.
