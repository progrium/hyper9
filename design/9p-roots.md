---
slug: 9p-roots
title: 9P roots
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [cli, kern]
---

# Proposal: 9P roots

## Abstract

`--root tcp!host!port` (or a unix socket path) dials a 9P server and mounts it through devmnt as the guest's `/`, instead of a host directory.

## Background

This was part of milestone M10 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

From DESIGN.md's root filesystem list, the second of three, after the host tree that's built today:

2. **9P mount:** `--root tcp!host!564` (or a unix socket path) dials and mounts through devmnt. Covers remote file servers and u9fs.

devmnt, drawterm's 9P client, is already built in. Program lookup already goes through the kernel along `$path`, so it works the same over a 9P root.

| Flag | Meaning |
| --- | --- |
| `--root DIR\|tcp!host!port\|/path.sock` | The root tree. If omitted, use `$H9ROOT`, then the default install location |

## Done when

- h9 runs `/bin/ls` from a root served over 9P by u9fs or a remote 9front file server.

## Open issues

- How the sandbox policy treats a dialed root, since it's reached through the network rather than `#U`.
