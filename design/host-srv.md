---
slug: host-srv
title: Posting host connections to /srv
status: draft
created: 2026-11-06
authors: [progrium]
depends: [8, 13]
areas: [cli, kern]
---

# Proposal: Posting host connections to /srv

## Abstract

h9 can connect to 9P servers on the host side and post each connection in the machine's `/srv` before the program starts: `--srv name=tcp!host!564`, `--srv name=unix!/run/fs.sock`. Namespace files and guest programs mount them as `mount /srv/name /n/x`, as on 9front. This generalises how [9p-roots](0013-9p-roots.md) posts its root as `/srv/root`.

## Background

- **9p-roots** connects to one server, posts its channel to `#s/root` with devsrv's `h9_srvpost`, and mounts it at `/`.
- **[devsrv](0008-devsrv.md)** gives each machine its own `/srv` board. Its compatibility notes say `mount /srv/x …` lines in a namespace file work only if something posted `/srv/x` before the replay, which in practice nothing does.
- **Embedders** who want to serve a host directory with their own 9P server, rather than devfs, have no way to hand the connection to the machine.

## Proposal

[To be written. The shape:]

- **`--srv NAME=DIAL|SOCKET`**, repeatable. The same forms as `--root`'s 9P roots, connected the same way (devip for TCP, `lfdchan` for unix sockets), and posted as `/srv/NAME`. `root` is reserved.
- **`Machine.Options.srv: []const Srv`**, each a name and a `Root` (`tcp`, `unix`, and later [websocket-9p](0021-websocket-9p.md)'s `ws`), plus a variant that takes an already-open host fd, for embedders.
- **Order:** posted after the root and before the `--ns` replay, so namespace files can mount them.
- **`--print`** lists them with a `post` line per entry; `--ns` has nothing new to parse.
- **Failures** connecting are exit 125, as for roots.

## Rationale

[To be written: why connect on the host rather than let the guest dial; why not reuse `--ns` for this; the net policy not applying, as for roots.]

## Compatibility

[New flag and option; nothing changes without them.]

## Security

[The guest reaches each posted server. The posts are per machine.]

## Done when

[Cases tagged `[host-srv]`: a namespace file mounts a posted server; a guest program mounts one; an unreachable one exits 125.]

## Implementation

[To be written.]
