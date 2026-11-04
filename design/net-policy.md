---
slug: net-policy
title: Outbound-only network by default, and --net-allow
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [sandbox, cli, kern]
---

# Proposal: outbound-only network by default, and --net-allow

## Abstract

Enforce `--net=outbound`, with devip refusing `announce`, and make it the default profile's network setting. Add `--net-allow DIALSTRING`, an egress allowlist that devip checks on each `connect`.

## Background

This was part of milestone M5 ("servers") in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

Today `--net=outbound` is accepted but not enforced: the plan lists it as `unenforced` and the network is left as it is, and `--strict` refuses it.

From DESIGN.md's capability table:

| Capability | Mechanism |
| --- | --- |
| `net.outbound` | devip refuses `announce` |
| `net.allow` | devip checks each `connect` against dial-string patterns (`tcp!10.0.0.0/8!564`); an egress allowlist isobox can't offer |

From the vendor hooks: `h9_net_check(op, addr, port)` in devip, a leaf like `h9_fs_check` in devfs, which returns an int and never raises kernel errors itself.

The default profile's network would go from full to outbound only, with `--net=enable` for servers.

| Flag | Meaning |
| --- | --- |
| `--net-allow DIALSTRING` (repeatable) | Allows `connect` only to matching addresses, such as `tcp!10.0.0.0/8!564` |

```sh
h9 --net=outbound hget https://9front.org/ > index.html    # clients work, listening fails
h9 --net-allow 'tcp!10.0.0.0/8!564' --net-allow 'tcp!*!443' \
    --rc 'srv tcp!10.0.0.5!564 fs && mount /srv/fs /n/fs'   # egress allowlist
```

## Done when

- `aux/listen1` fails under the default profile.
- `hget` works under `--net=outbound`.
- A `connect` outside `--net-allow` fails, and one inside it succeeds.

## Open issues

- The second example needs `srv` and `/srv`, so it's a [devsrv](devsrv.md) case too.
