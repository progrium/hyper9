---
slug: gfx
title: Graphics (--gfx)
status: draft
created: 2026-11-03
authors: [progrium]
depends: [devsrv]
areas: [cli, kern]
---

# Proposal: graphics (--gfx)

## Abstract

`--gfx` opens one host window through drawterm's GUI backend and serves `/dev/draw`, `/dev/mouse` and `/dev/kbd`, with snarf mapped to the host clipboard, so rio and acme run in a host window.

## Background

This was milestone M7 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

**Graphics (`--gfx`):** opens one host window through drawterm's GUI backend (Cocoa/Metal, X11 or Wayland, Win32) and serves `/dev/draw`, `/dev/mouse` and `/dev/kbd`, plus snarf mapped to the host clipboard. One screen per machine: running rio gives the full desktop. A seamless mode, where each rio window becomes a host window, is a later project.

devdraw, devmouse and the GUI backends are vendored from drawterm already; kern is built today with no-op GUI stubs in `src/kern/glue.c`. rio posts its file server to `/srv`, hence [devsrv](devsrv.md).

| Flag | Meaning |
| --- | --- |
| `--gfx` | Opens a host window and serves `/dev/draw`, `/dev/mouse` and `/dev/kbd` |

## Done when

- rio and acme run in a host window.

## Open issues

- Which Mach and WindowServer lookups `--gfx` needs under Seatbelt, for [host-sandbox](host-sandbox.md). (A research note planned for this milestone.)
- macOS builds: the Cocoa backend (`screen.m`) is Objective-C, and HVF needs the macOS SDK plus an entitlement signature, so macOS builds run on a Mac, or use rcodesign when cross-building. (Moved from DESIGN.md's Open questions.)
