---
slug: segattach
title: segattach and shared segments
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [kern, vmm]
---

# Proposal: segattach and shared segments

## Abstract

Serve `segattach`, `segdetach`, `segfree` and `segbrk` with named shared segments, each backed by one set of guest-physical pages mapped into every address space that attaches it.

## Background

This was part of milestone M5 ("servers") in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

From DESIGN.md's process model table:

| Plan 9 call | Implementation |
| --- | --- |
| `segattach` / `segdetach` / `segfree` | Named shared segments, backed by one set of guest-physical pages |

`segbrk`, which grows an attached segment as `brk_` grows the data segment, isn't served either (the process model table listed it with `brk_`). `rfork(RFMEM)` already shares text, data and bss and would share segattach pages too. Segments are Zig objects in `src/segment.zig`, attached to every address space that shares them.

## Done when

- A segment attached by one process is visible to another that attaches it by name, and is freed when the last one detaches.
