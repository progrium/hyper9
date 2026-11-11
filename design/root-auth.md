---
slug: root-auth
title: Authenticated 9P roots
status: draft
created: 2026-11-06
authors: [progrium]
depends: [ninep-roots]
areas: [cli, kern, sandbox]
---

# Proposal: Authenticated 9P roots

## Abstract

A [9P root](ninep-roots.md) can be a server that wants `p9any` authentication, such as a 9front file server or `exportfs` behind `aux/listen1` without `-t`. h9 runs the client side of `p9any` (dp9ik, or p9sk1) on the host over the mount's auth fid before attaching, with a key given by `--root-auth`. The guest never holds the key.

## Background

- **ninep-roots** mounts with no auth fd. A server that answers `Tauth` with a fid, rather than an error, gets "authentication required", exit 125.
- **devmnt** already has `mntauth`, which sends `Tauth` and returns the auth fid as a channel, and drawterm's `bindmount` takes an auth channel. [devsrv](devsrv.md) serves the guest's `fauth` through `mntauth`.
- **drawterm's `cpu.c`** has a `p9any` client: the negotiation, dp9ik, and p9sk1, ticket requests to an auth server (`authdial`, `gettickets`), and key lookup from a secstore-style list (`findkey`) or a prompt (`getkey`). It uses `libauthsrv` and `libsec`, which h9 already builds, and isn't itself built: `build.zig` leaves out `cpu.c` and `libauth`.

## Proposal

[To be written. The shape:]

- **`--root-auth SOURCE`:**
  - `key=FILE`: a factotum key line (`key proto=dp9ik dom=… user=… !password=…`), read from FILE, which h9 checks is readable only by its owner.
  - `factotum`: a host factotum (plan9port's), reached as `posix-factotum.c` reaches it, through `$NAMESPACE/factotum`. POSIX only.
  - `prompt`: ask on the terminal, as drawterm does.
- **`--root-authserver HOST`:** the auth server's address; default the root's host, as drawterm's `-a` defaults to `$auth`.
- **Flow:** `mntauth` on the root's channel, `p9any` on the resulting auth channel on the host, then the mount with that auth channel and `--root-user` (which must match the key's user).
- **Code:** `p9any` and the ticket helpers taken from `cpu.c` into project code (`src/kern/rootauth.c`), not built from the vendored file, since `cpu.c` is drawterm's `main`.
- **`--print`** shows `auth=dp9ik user@dom` with no secret. `--ns`'s `mount '#s/root'` lines re-attach with the same auth.
- **Failures:** a missing or wrong key, an unreachable auth server, or a protocol the server doesn't offer exit 125.

## Rationale

[To be written: why on the host and not a guest factotum; why not run the guest's factotum before the root exists; why no secstore.]

## Compatibility

[New flags; `Machine.Options` gains the auth source; no change without `--root-auth`.]

## Security

[The key's lifetime in h9's memory; nothing in the guest; the auth server's connection isn't under the net policy, like the root's.]

## Done criteria

[Cases against a second h9 running `exportfs` with authentication and an `authsrv` from the root tree, tagged `[root-auth]`.]

## Implementation

[To be written.]

## Open issues

- Whether the guest should also get a factotum holding the same key, so its own `mount /srv/root …` attaches can authenticate.
- A Windows equivalent of `factotum`.
- **The server side, for [serve](serve.md).** serve's TCP listeners are unauthenticated: a guest-side factotum for `exportfs` would put the key in the guest. h9 could instead run the server side of `p9any` on the host, in front of the connection, before handing it to exportfs, with a key given as `--root-auth` gives one. That needs the server half of dp9ik and p9sk1 (drawterm has only clients) and an auth server reachable from the host. A follow-up proposal, if a use appears that a WebSocket token or a unix socket's permissions can't serve.
