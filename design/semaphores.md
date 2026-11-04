---
slug: semaphores
title: rendezvous and semaphores
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [kern]
---

# Proposal: rendezvous and semaphores

## Abstract

Serve `rendezvous`, `semacquire`, `tsemacquire` and `semrelease` with host kernel primitives built on drawterm's sleep/wakeup, so guest programs can synchronize. Go's runtime parks every lock on them.

## Background

This was part of milestone M5 ("servers") in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

From DESIGN.md's process model table:

| Plan 9 call | Implementation |
| --- | --- |
| `rendezvous` / `semacquire` / `tsemacquire` / `semrelease` | Host kernel primitives built on drawterm's sleep/wakeup |

drawterm already has a `sysrendezvous` wrapper in `kern/sysfile.c`; the semaphore calls need wrappers in the same style (DESIGN.md, Zig/C seam rules).

## Done when

- A program using `rendezvous` between two processes, and one using `semacquire`, `tsemacquire` with a timeout and `semrelease`, behave as on 9front.

## Open issues

- drawterm has no `tsleep` (`sleep` is served in 20 ms slices for that reason), so how `tsemacquire`'s timeout is implemented.
