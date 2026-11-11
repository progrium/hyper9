---
id: 76
slug: schemeless-roots
title: Schemeless roots
status: implemented
created: 2026-11-08
authors: [progrium]
depends: [9p-roots, websocket-9p]
areas: [cli]
branch: [main]
---

# Proposal: Schemeless roots

Nov 8, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

`--root example.com/9p` means `--root wss://example.com/9p`, and `--root localhost:8080/9p` means `--root ws://localhost:8080/9p`. A `--root` or `$H9ROOT` value that has no scheme or dial-string prefix, isn't a host path that exists, and is shaped like `host[:port][/path]` is read as a URL: `ws://` for a loopback host, and `wss://` for any other. Every value that works today keeps its meaning, because an existing path is always checked first.

## Background

[9p-roots](9p-roots.md) reads `--root` by prefix, then by stat: `tcp!` and `unix!` are dial strings, and anything else is a host path, which is a directory or a socket ([image-roots](image-roots.md) proposes a regular file as a disk image). [websocket-9p](websocket-9p.md) added `ws://` and `wss://` URLs, recognized by their prefix so that "it can't be confused with a host path or a `tcp!` dial string" (`cli.rootArg`, `ws.Url.is`).

So a WebSocket root has to be typed with its scheme. Almost every one is `wss://`: a page served over `https` can only open `wss://`, the servers people run for this sit behind TLS, and `ws://` is mostly for a server on localhost in a test. Typing `wss://` is the same small tax every time, and leaving it off today gives "root example.com/9p: not found", which says nothing about URLs.

A value without a scheme is also a legal relative path, so the question is whether h9 can tell the two apart without guessing wrong about a path that works today.

### h9 today

`resolveRoot` in `src/main.zig` calls `cli.rootArg`, which returns `.ws`, `.tcp`, `.unix`, or `.path`. A `.path` goes through `realPath` and `statFile`: a directory is `Root.dir`, a socket is `Root.unix`, anything else is "not a directory or socket", and a missing path is "not found". Both are exit 125.

## Proposal

### The reading of `--root`

`--root` and `$H9ROOT` are read in this order. The first that applies wins:

1. **`ws://…` or `wss://…`:** a WebSocket URL, as now.
2. **`tcp!…` or `unix!…`:** a dial string, as now.
3. **A host path that exists:** a directory, a socket (or, with image-roots, an image), as now. A path that exists but is none of these is still "not a directory or socket", and is never retried as a URL.
4. **A value shaped like a URL without its scheme** (below): the URL `ws://` followed by the value if its host is loopback, and `wss://` followed by the value otherwise.
5. **Anything else:** "not found", as now.

### The shape

A value is shaped like a URL without its scheme when all of these hold:

- It doesn't start with `.`, `/`, `~`, or `-`, and doesn't contain `\`, `!`, `@`, or whitespace. That leaves out relative paths written with `./` or `../`, absolute paths, home-relative paths, Windows paths, dial strings, and userinfo, which `ws.Url.parse` refuses anyway.
- Its authority, the part before the first `/` or `?`, is `host` or `host:port`, where `port` is 1 to 65535 in decimal and `host` is either a bracketed IPv6 literal or a name of letters, digits, `-`, and `.`, with no empty label and no label starting or ending with `-`.
- The host is `localhost`, has a `.` in it, or is bracketed, or the authority has a port. `fs.example.com`, `fs.example.com/9p`, `10.0.0.5/9p`, `[::1]:8443/9p`, `localhost/9p`, and `fs:8443` qualify; `root`, `root/9p`, and `dist/root` don't.
- Nothing has to follow the authority: a bare host is a URL for `/`, so `fs.example.com` is `wss://fs.example.com/`.
- `ws.Url.parse` accepts the URL.

The host is loopback, and the scheme `ws://`, when it's `localhost`, an IPv4 address in `127.0.0.0/8`, or `[::1]`. A local server rarely has a certificate, so that's the scheme it's most often reached with. A local TLS server is written with `wss://`.

The rule is `cli.schemelessRoot(arena, arg) ?[]const u8`, which returns the URL or null, and has no I/O. `resolveRoot` calls it only when the path in step 3 doesn't exist.

### What the user sees

The URL is what h9 uses from then on: `Root.ws` holds `wss://…` or `ws://…`, `--root-header` and `--root-ca` accept the root as they accept one written with its scheme (so `--root-ca` with a loopback root is a usage error, as with `ws://`), and `--print`, `--check`, and errors show the URL, so the reading h9 chose is always visible. A failed connection names both readings:

```
$ h9 --root fs.example.com/9p ls
h9: root fs.example.com/9p: no such path; wss://fs.example.com/9p: connection refused
```

The exit code is 125, as for any root that can't be reached.

### Where it doesn't apply

- **Namespace files** and **`wsmount`** keep requiring a scheme. Their source is a name in the guest's namespace, where `fs.example.com/9p` is a relative guest path, and the guest's namespace isn't something to stat before the replay.
- **The browser host's `createMachine({ root })`** and the demo page's `?root=` keep requiring a scheme too. A string there without one is a relative URL of a root archive, so the same text already has a meaning. `h9-node` is the CLI, and follows the rule, with its paths read from `$PWD` as now.
- **`Machine.Options`** doesn't change. Embedders pass a full URL in `Root.ws`.

## Rationale

**Path first, then URL.** Checking for an existing path first means every value that works today keeps working, including a directory someone named `fs.example.com`. The cost is that the reading depends on the filesystem: the same `--root` can be a directory in one place and a URL in another. That's already true of 9p-roots' directory and socket, and `--print` shows which reading was taken. A URL-first rule would break relative paths with a dot in their first component, like `build.d/root`, for a small saving.

**Only a value that's shaped like a URL.** Without a shape check, every missing path would turn into a connection to somewhere, and a typo would become a DNS query and a confusing TLS error rather than "not found". Requiring a dotted host (or `localhost`, brackets, or a port) keeps most mistyped local paths out: `root`, `.local/9front/root`, `./9front.img`, and `dist/root` all stay paths. What's left are missing relative paths whose first component has a dot, such as `build.d/root`, `9front.img`, or `root.tar`; those dial, and the error says so.

**A bare host.** `fs.example.com` is the most natural thing to type, so it's accepted, as `/`. The cost is that a missing file in the working directory with a dot in its name, like `9front.img`, is now looked up as a host before it fails. The error names both readings, and `./9front.img` is always a path.

**No list of top-level domains.** Telling `example.com` from `build.d` by its last label would need the public suffix list, which changes, and would still read `notes.md/x` as a host. A missing path is rare enough, and the error clear enough, that the simpler rule wins.

**`wss://` by default, `ws://` for loopback.** Defaulting to plaintext would make the shortest form the unsafe one for a remote server, and a page served over `https` can't open `ws://` at all. A local test server is the one place `ws://` is common, and plaintext to loopback never leaves the host, so there the default is `ws://`. Only literal loopback names count: a name that resolves to `127.0.0.1` isn't checked, since that would make the scheme depend on DNS.

**Not a new prefix.** A `ws!host!port` dial string was rejected by websocket-9p because a path and a query don't fit in it. A shorter scheme, like `9p:`, would still need typing and would be one more form to learn.

**Image references.** A container image reference like `ghcr.io/org/root:latest` has the same shape and would be read as `wss://ghcr.io/org/root:latest`. h9 has no registry roots, so nothing breaks today. If one is proposed, it needs its own prefix (`oci:` or similar), and this rule is why.

## Compatibility

- **`--root` and `$H9ROOT`:** every value that resolved before resolves to the same root. A value that failed with "not found" and has the shape above now connects to a `wss://` URL, or a `ws://` one for loopback.
- **Exit codes:** unchanged. A schemeless root that can't be reached is 125, as "not found" was.
- **`--root-header` and `--root-ca`:** accepted with a schemeless root as with the URL it reads as. `--root-ca` with a loopback root is exit 2, as with `ws://`.
- **`--print` and `--check`:** show the URL.
- **`Machine.Options`, namespace files, `wsmount`, the browser host's JS API, the sandbox defaults, and `third_party/`:** unchanged.

## Security

- **New requests from the host.** A missing path that has the shape above makes h9 resolve its first component and open a TLS connection to it, so a mistyped path of that shape goes to the host's resolver and, if it resolves, to a server. The shape check keeps this to values with a dotted host, and the connection is made before the program runs, as every root's is.
- **Transport:** TLS, verified against the host's bundle or `--root-ca`'s, as for any `wss://` root, for every host but loopback. A loopback root is plaintext, as `ws://` is, and the plan's unencrypted caveat applies; that traffic doesn't leave the host. Nothing goes over the network in plaintext unless `ws://` is typed.
- **The guest** reaches nothing new. The root is a host-made connection, outside `--net`, as websocket-9p's roots are.
- **Shadowing.** A directory in the working directory named like a host takes precedence over the URL. Anyone who can create that directory can already choose what a relative `--root` means, so this adds no new control, but a script that wants the server for certain writes `wss://`.

## Done criteria

The unit test in `src/cli.zig`, `test "schemelessRoot reads host/path as wss:// and leaves paths alone"`, covers the shapes above, both ways. Integration cases tagged `[schemeless-roots]`:

- [x] `test "a schemeless --root prints as its wss:// URL [schemeless-roots]"`: `--print --root fs.example.com/9p` shows `wss://fs.example.com/9p` without connecting, and `--print --root fs.example.com` shows `wss://fs.example.com/`.
- [x] `test "a schemeless loopback root is ws:// and runs /bin/ls [schemeless-roots]"`: `--root 127.0.0.1:PORT/9p` against websocket-9p's relay.
- [x] `test "an existing directory with a dotted name is a host root, not a URL [schemeless-roots]"`
- [x] `test "an unreachable schemeless root exits 125 naming both readings [schemeless-roots]"`
- [x] `test "$H9ROOT is read as a schemeless root [schemeless-roots]"`
- [x] `test "--root-ca is accepted with a schemeless root [schemeless-roots]"`
- [x] `test "a missing path without a dotted host is still not found [schemeless-roots]"`: `root`, `./9front.img`, and `dist/root`.

Demo: `h9 --print --root fs.example.com/9p ls` shows the `wss://` URL in the plan's root comment.

## Implementation

1. `cli.schemelessRoot` and its unit test.
2. `resolveRoot`'s fallback, and the two-reading error in `rootError`.
3. The integration cases.
4. README's and MANUAL.md's `--root` notes, and SPEC.md's root filesystem paragraph and CLI flag table. Set `status: implemented`.

## Updates

- 2026-11-08: Implemented. Refinements made while implementing it:
  - A schemeless root that can't be reached keeps the connection error as every WebSocket root gives it (`h9: PROG: root wss://fs.example.com/9p: connection refused`), and a second line says how h9 got there: `h9: root fs.example.com/9p: no such path, so h9 read it as wss://fs.example.com/9p`. The Machine names the root by its URL and doesn't know the CLI's spelling, so the CLI adds the line rather than the Machine joining both readings into one.
  - A bare host gains a trailing `/` (`fs.example.com` is `wss://fs.example.com/`), and a host is followed by `?` with no `/` as written (`fs.example.com?t=1` is `wss://fs.example.com?t=1`).
  - `--check` names a WebSocket root by its URL rather than the argument, so it shows the reading too.
  - The missing-path case uses `no-such-root` rather than `root`, so a file of that name in the working directory can't make it pass for the wrong reason.
