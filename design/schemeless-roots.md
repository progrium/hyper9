---
slug: schemeless-roots
title: Schemeless roots
status: draft
created: 2026-11-08
authors: [progrium]
depends: [13, 21]
areas: [cli]
---

# Proposal: Schemeless roots

## Abstract

`--root example.com/9p` means `--root wss://example.com/9p`. A `--root` or `$H9ROOT` value that has no scheme or dial-string prefix, isn't a host path that exists, and is shaped like `host[:port]/path` is read as a `wss://` URL. Every value that works today keeps its meaning, because an existing path is always checked first. `ws://` stays explicit.

## Background

[9p-roots](0013-9p-roots.md) reads `--root` by prefix, then by stat: `tcp!` and `unix!` are dial strings, and anything else is a host path, which is a directory or a socket ([image-roots](0014-image-roots.md) proposes a regular file as a disk image). [websocket-9p](0021-websocket-9p.md) added `ws://` and `wss://` URLs, recognized by their prefix so that "it can't be confused with a host path or a `tcp!` dial string" (`cli.rootArg`, `ws.Url.is`).

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
4. **A value shaped like a URL without its scheme** (below): the URL `wss://` followed by the value.
5. **Anything else:** "not found", as now.

### The shape

A value is shaped like a URL without its scheme when all of these hold:

- It doesn't start with `.`, `/`, `~`, or `-`, and doesn't contain `\`, `!`, `@`, or whitespace. That leaves out relative paths written with `./` or `../`, absolute paths, home-relative paths, Windows paths, dial strings, and userinfo, which `ws.Url.parse` refuses anyway.
- Its authority, the part before the first `/` or `?`, is `host` or `host:port`, where `port` is 1 to 65535 in decimal and `host` is either a bracketed IPv6 literal or a name of letters, digits, `-`, and `.`, with no empty label and no label starting or ending with `-`.
- The host has a `.` in it, or is bracketed, or the authority has a port. `fs.example.com/9p`, `10.0.0.5/9p`, `[::1]:8443/9p`, and `localhost:8443/9p` qualify; `root/9p` and `localhost/9p` don't.
- The authority is followed by a `/` or a `?`, or has a port. `fs.example.com/` and `fs.example.com:443` qualify; a bare `fs.example.com` doesn't, so that a missing file named `9front.img` or `root.tar` is still "not found" and is never sent to a resolver.
- `ws.Url.parse` accepts `wss://` followed by the value.

The rule is `cli.schemelessRoot(arena, arg) ?[]const u8`, which returns the `wss://` URL or null, and has no I/O. `resolveRoot` calls it only when the path in step 3 doesn't exist.

### What the user sees

The URL is what h9 uses from then on: `Root.ws` holds `wss://…`, `--root-header` and `--root-ca` accept the root as they accept a `wss://` one, and `--print`, `--check`, and errors show the `wss://` URL, so the reading h9 chose is always visible. A failed connection names both readings:

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

**Only a value that's shaped like a URL.** Without a shape check, every missing path would turn into a TLS connection to somewhere, and a typo would become a DNS query and a confusing TLS error rather than "not found". Requiring a dotted host (or a port) and a path (or a port) keeps nearly every mistyped local path out: `root`, `9front.img`, `.local/9front/root`, and `dist/root` all stay paths. What's left are missing relative paths whose first component has a dot, such as `build.d/root`; those dial, and the error says so.

**No list of top-level domains.** Telling `example.com` from `build.d` by its last label would need the public suffix list, which changes, and would still read `notes.md/x` as a host. A missing path is rare enough, and the error clear enough, that the simpler rule wins.

**`wss://`, never `ws://`, even for localhost.** Defaulting to plaintext would make the shortest form the unsafe one, and a page served over `https` can't open `ws://` at all. A local test server is the one place `ws://` is common, and there it's worth typing. Loopback is an open issue below.

**Not a new prefix.** A `ws!host!port` dial string was rejected by websocket-9p because a path and a query don't fit in it. A shorter scheme, like `9p:`, would still need typing and would be one more form to learn.

**Image references.** A container image reference like `ghcr.io/org/root:latest` has the same shape and would be read as `wss://ghcr.io/org/root:latest`. h9 has no registry roots, so nothing breaks today. If one is proposed, it needs its own prefix (`oci:` or similar), and this rule is why.

## Compatibility

- **`--root` and `$H9ROOT`:** every value that resolved before resolves to the same root. A value that failed with "not found" and has the shape above now connects to a `wss://` URL.
- **Exit codes:** unchanged. A schemeless root that can't be reached is 125, as "not found" was.
- **`--root-header` and `--root-ca`:** accepted with a schemeless root, which is a `wss://` root.
- **`--print` and `--check`:** show the `wss://` URL.
- **`Machine.Options`, namespace files, `wsmount`, the browser host's JS API, the sandbox defaults, and `third_party/`:** unchanged.

## Security

- **New requests from the host.** A missing path that has the shape above makes h9 resolve its first component and open a TLS connection to it, so a mistyped path of that shape goes to the host's resolver and, if it resolves, to a server. The shape check keeps this to values with a dotted host and a path, and the connection is made before the program runs, as every root's is.
- **Transport:** always TLS, verified against the host's bundle or `--root-ca`'s, as for any `wss://` root. Nothing is ever sent in plaintext unless `ws://` is typed.
- **The guest** reaches nothing new. The root is a host-made connection, outside `--net`, as websocket-9p's roots are.
- **Shadowing.** A directory in the working directory named like a host takes precedence over the URL. Anyone who can create that directory can already choose what a relative `--root` means, so this adds no new control, but a script that wants the server for certain writes `wss://`.

## Done when

The unit test in `src/cli.zig`, `test "schemelessRoot reads host/path as wss:// and leaves paths alone"`, covers the shapes above, both ways. Integration cases tagged `[schemeless-roots]`:

- `test "a schemeless --root prints as its wss:// URL [schemeless-roots]"`: `--print --root fs.example.com/9p` shows `wss://fs.example.com/9p` without connecting.
- `test "an existing directory with a dotted name is a host root, not a URL [schemeless-roots]"`
- `test "an unreachable schemeless root exits 125 naming both readings [schemeless-roots]"`
- `test "$H9ROOT is read as a schemeless root [schemeless-roots]"`
- `test "--root-ca is accepted with a schemeless root [schemeless-roots]"`
- `test "a missing path without a dotted host is still not found [schemeless-roots]"`: `root`, `9front.img`, and `dist/root`.

Demo: `h9 --print --root fs.example.com/9p ls` shows the `wss://` URL in the plan's root comment.

## Implementation

1. `cli.schemelessRoot` and its unit test.
2. `resolveRoot`'s fallback, and the two-reading error in `rootError`.
3. The integration cases.
4. README's and MANUAL.md's `--root` notes, and DESIGN.md's root filesystem paragraph and CLI flag table. Set `status: implemented`.

## Open issues

- **Loopback.** Should `localhost:port/…`, `127.0.0.1:port/…`, and `[::1]:port/…` imply `ws://` instead, since a local server rarely has a certificate? It's friendlier for tests, but it makes the default depend on the host, and a local TLS server would then need its scheme typed.
- **A bare host.** Should `fs.example.com`, with no path or port, be accepted as `wss://fs.example.com/`? It's the most natural thing to type, but it's also the shape of a missing file named `root.tar` or `9front.img`.
