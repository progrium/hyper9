---
slug: self-host
title: Self-hosting
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [kern, tests]
---

# Proposal: self-hosting

## Abstract

The 9front compilers, linkers and mk run inside h9 and can rebuild the 9front userland. devproc gains the files acid needs (`mem`, `regs`, `fpregs`, `segment` and `text`), so programs can be debugged inside too.

## Background

This was milestone M6 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

Self-hosting is one of DESIGN.md's goals, and a source of test binaries. Installing into the read-only root needs `--writable "$H9ROOT"`. The root tree needs `/sys/src`, which `scripts/mkroot.py --src` keeps.

devproc serves `/proc/n/{note,notepg,noteid,ctl,status,ns,fd,args,ppid,wait}` today. acid also needs `mem`, `regs`, `fpregs`, `segment` and `text`, which would come from h9's process records as the rest do.

The integration tests would add a self-build of a few `/sys/src/cmd` programs.

## Done when

- Rebuild `/sys/src/cmd/ls` inside, and the rebuilt binary runs.
- acid attaches to a running process and prints its registers and a stack trace.

## Open issues

- Which calls the compilers, linkers and mk need that h9 doesn't serve yet; the milestone plan didn't say, so this proposal may gain dependencies (perhaps [segattach](segattach.md)).
- Should the host-tree root go through devfs as-is, or get a faster read path for exec and compilers? (Moved from DESIGN.md's Open questions.)
