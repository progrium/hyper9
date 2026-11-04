---
slug: zig-interpreter
title: A native Zig interpreter for the emulator
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [vmm]
---

# Proposal: a native Zig interpreter for the emulator

## Abstract

A second emulator backend, written in Zig: MIT, dependency-free and deterministic, covering the instructions 9front's compilers and libc's assembly routines emit, arm64 first. It would let the emulator ship in the MIT `h9` build, which Unicorn's GPLv2 prevents.

## Background

DESIGN.md's emulator section listed this as the second step, after Unicorn, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

2. **A native Zig interpreter later.** It would be MIT, dependency-free and deterministic. It covers the instruction subset that 9front's compilers and libc's assembly routines emit, arm64 first. Unicorn is the reference: single-step both and compare registers after every instruction.

The emulator's speed was measured against HVF: about 5× slower for arm64 compute and on par for syscalls, so the interpreter wasn't urgent (DESIGN.md, Limits and selection).

## Done when

- The `[baseline]` cases pass on the interpreter.
- Single-stepping the interpreter and Unicorn side by side gives the same registers after every instruction on those cases.
