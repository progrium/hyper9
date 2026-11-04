---
slug: hide-host-paths
title: Hide host paths in /proc/n/ns
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [sandbox, kern]
---

# Proposal: hide host paths in /proc/n/ns

## Abstract

`/proc/n/ns` prints the host paths of bound host trees, which tells the guest the host's layout. The stricter profiles should hide or rewrite them.

## Background

This was an open question in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)):

> `/proc/n/ns` shows the host paths of bound host trees (`bind '#U/Users/…' /mnt/term/cwd`), which tells the guest the host's layout. The stricter profiles should hide them, or show the guest path or a placeholder instead; which one, and whether `--ns` can still replay the result, is open.

`--print` lists this as a caveat today. Rationale, Compatibility, Security and Implementation are to be written before filing.

## Done when

- Under `--profile=tight`, no host path appears in `/proc/n/ns`.

## Open issues

- Hide the binds, show the guest path, or show a placeholder; and whether `--ns` can still replay the result.
