---
slug: ci
title: Continuous integration
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [build, tests]
---

# Proposal: continuous integration

## Abstract

CI on hosted runners: the full suite on the emulator on every runner, `zig build design -- check`, and the root tree cached so QEMU only runs when the pinned release changes.

## Background

DESIGN.md's Testing and CI section described this plan, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

- The full suite runs on the emulator on every hosted CI runner, and Linux CI also runs it on KVM. macOS (HVF) and Windows (WHP) need self-hosted machines, because hosted runners there generally lack nested virtualization.
- CI isn't set up yet. When it is, one Linux job runs `scripts/fetch.sh` and `scripts/mkroot.py` and caches `.local/9front/root-<release>` keyed on `NINEFRONT_RELEASE` and a hash of `mkroot.py`; the other jobs restore that cache, so QEMU (slow without hardware acceleration on hosted runners) only runs when the pin or the script changes. The prebuilt Unicorn in `.local/unicorn` is cached the same way, keyed on `UNICORN_VERSION`. Integration tests skip, rather than fail, when no root tree is present.

Running on KVM depends on [kvm](kvm.md), which can be added to CI when it lands.

## Done when

- Every push runs `zig build test -Demu=unicorn` with a root tree on Linux arm64 and macOS hosted runners, and `zig build design -- check`.

## Open issues

- Running 9front's own regression tests, where they exist, alongside the integration cases. (DESIGN.md's test plan listed them.)
