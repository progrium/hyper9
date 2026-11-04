---
slug: overlay
title: Copy-on-write overlay as the root's default
status: draft
created: 2026-11-03
authors: [progrium]
depends: [ephemeral-writes]
areas: [sandbox, cli, kern]
---

# Proposal: copy-on-write overlay as the root's default

## Abstract

A copy-on-write overlay device, shared with image-backed roots, enforces `--write=overlay` and becomes the root's default: writes to the root succeed and vanish.

## Background

This was part of milestone M10 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

Today `--write=overlay` is accepted but not enforced: writes are denied, the plan lists it as `unenforced`, and `--strict` refuses it. The root tree is read-only, and installing into it needs `--writable "$H9ROOT"`.

From DESIGN.md's capability table:

| Capability | Mechanism |
| --- | --- |
| `fs.write.overlay` | A copy-on-write overlay device, shared with image-backed roots |

With it, the default profile's root row becomes: read-only underneath, with an ephemeral overlay, so writes succeed and vanish.

```sh
h9 --strict --write=overlay mk                             # a usage error, exit 2, until this is built
```

## Done when

- A write to the root under the default profile succeeds inside the run and leaves the root tree unchanged.
- `--strict --write=overlay` is accepted.
