---
slug: kvm
title: KVM backend
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [vmm]
---

# Proposal: KVM backend

## Abstract

A vmm backend for Linux's KVM: arm64 first, then the amd64 shim on x86\_64. The suite that passes on HVF and the emulator passes on KVM, in CI.

## Background

This was milestone M8 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

The vmm interface was shaped for KVM from the start (DESIGN.md, Hypervisor layer): the VM is created with `KVM_CREATE_VM`, memory is mapped with `KVM_SET_USER_MEMORY_REGION`, vCPUs run with `KVM_RUN`, and a kick is `immediate_exit` plus a signal to the thread. Access needs read/write on `/dev/kvm`. The portability rules apply: the shim exits through an MMIO doorbell, since arm64 KVM handles HVC itself unless hypercall filtering is configured; one large guest-physical region is mapped once, since KVM caps the number of memory slots; and guest page tables use 4K pages.

On amd64 the shim has to do bring-up that HVF lets the host do on arm64: long mode with a GDT, an IDT and the SYSCALL MSRs, and switching CR3 when the host asks. The exit is `OUT`.

`--check` already reports `/dev/kvm` access through this backend once it exists, and `--backend kvm` already selects it.

## Done when

- The `[baseline]` cases pass on KVM, on arm64 and on x86\_64, in CI.
- `--check` reports KVM's vCPU limit.

## Open issues

- KVM's vCPU limit (`KVM_CAP_MAX_VCPUS`), measured as HVF's was, and whether the vCPU pool needs changes for it.
- Landlock for paths and TCP ports plus seccomp, with `/dev/kvm` already open; the syscalls `KVM_RUN` and vCPU threads need; the Landlock ABI each target distro ships. (A research note planned for this milestone, for [host-sandbox](host-sandbox.md).)
- When to add the binfmt\_misc registration on Linux, so that `./prog` runs directly. (Moved from DESIGN.md's Open questions.)
