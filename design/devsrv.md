---
slug: devsrv
title: devsrv and /srv
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [kern]
---

# Proposal: devsrv and /srv

## Abstract

Add devsrv (`#s`), ported from 9front, so guest file servers can post themselves to `/srv` and other processes in the machine can mount them. factotum, exportfs and rio need it.

## Background

This was part of milestone M5 ("servers") in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

From DESIGN.md's table of kernel pieces added by h9:

| Piece | Why |
| --- | --- |
| devsrv `#s` | Guest file servers post themselves; needed for factotum, exportfs and rio |
| devshr, devcap | Later: shared /srv namespaces and hostowner capabilities |

The namespace builder would bind `#s` at `/srv` along with `#c`, `#p`, `#d`, `#e` and `#I`.

## Done when

- ramfs posts to `/srv` and is mounted by another process in the same machine.
- factotum runs.

## Open issues

- Whether devshr and devcap belong here or in proposals of their own.
- Whether each machine gets its own `/srv`, as each gets its own `/proc`, when several machines share a host process.
