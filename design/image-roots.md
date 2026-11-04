---
slug: image-roots
title: Disk-image roots
status: draft
created: 2026-11-03
authors: [progrium]
depends: [devsrv, 9p-roots]
areas: [cli, kern]
---

# Proposal: disk-image roots

## Abstract

cwfs or gefs runs as a guest process over a disk image exposed as a host file, posts itself to `/srv`, and is mounted as the guest's root.

## Background

This was part of milestone M10 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

From DESIGN.md's root filesystem list, the third of three:

3. **Disk image:** cwfs or gefs runs as a guest process over an image file exposed as a host file, and posts to `#s`. This is also a good stress test of the process model.

It posts through [devsrv](devsrv.md), and the root is mounted as a [9P root](9p-roots.md) is.

## Done when

- h9 boots a 9front disk image's file system as its root and runs `/bin/ls` from it.
