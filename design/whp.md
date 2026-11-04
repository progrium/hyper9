---
slug: whp
title: WHP backend
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [vmm]
---

# Proposal: WHP backend

## Abstract

A vmm backend for the Windows Hypervisor Platform: x86\_64 first, then Windows on ARM. The suite that passes elsewhere passes on WHP.

## Background

This was milestone M9 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

From DESIGN.md's Hypervisor layer: the partition is created with `WHvCreatePartition` and `WHvSetupPartition`, memory is mapped with `WHvMapGpaRange`, vCPUs run with `WHvRunVirtualProcessor`, and a kick is `WHvCancelRunVirtualProcessor`. Access needs the optional Windows Hypervisor Platform feature. h9.exe already runs on the emulator on Windows arm64, with kern built from drawterm's win32 files.

## Done when

- The `[baseline]` cases pass on WHP.
- `--check` reports WHP's vCPU limit (the partition property).

## Open issues

- Whether the Windows Hypervisor Platform's arm64 support is solid enough to target, or whether Windows on ARM waits. (Moved from DESIGN.md's Open questions.)
- Windows builds need a WinHvPlatform import library (a .def file for Zig). (Moved from DESIGN.md's Open questions.)
- Whether an AppContainer or restricted token can still use WHP. (A research note planned for this milestone, for [host-sandbox](host-sandbox.md).)
