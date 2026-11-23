---
slug: retire-unicorn
title: Retire Unicorn as an engine
status: draft
created: 2026-11-21
authors: [progrium]
depends: [hcpu]
areas: [vmm, build, tests]
branch: [retire-unicorn]
---

# Proposal: Retire Unicorn as an engine

## Abstract

Once [hcpu](hcpu.md) is implemented, h9's own CPUs run every guest on every host, and `h9-emu` is no longer released. Unicorn is still in the tree after that: an engine behind `-Demu=unicorn`, a source build for Windows, patches, a fetch step, and documentation. This proposal removes it as an engine. `-Demu` goes, since there's one emulator and it's always built in. `src/vmm/unicorn.zig`, `build/unicorn.zig`, `third_party/unicorn/`, and the GPLv2 release path go. What stays is Unicorn as a test oracle for `zig build lockstep`, linked only into that test tool from the prebuilt library, and never into anything h9 ships.

## Background

[hcpu](hcpu.md) replaces Unicorn in three steps: hcpu becomes the default emulator for the MIT `h9`, `h9-emu` stops being released once hx64 passes, and `-Demu=unicorn` stays "for lockstep testing after that". It stops there. What's left costs:

- **A second engine to keep working.** `src/vmm/unicorn.zig` is about 1,000 lines with its own workarounds (the virtual-TLB hook, trap pages, the FXSAVE image, the read-only GDT page, and the time-sliced lock), and every change to the engine interface has to be made in it.
- **A source build.** `build/unicorn.zig`, `third_party/unicorn/`'s patches and per-host config headers exist for Windows and for the GPLv2 source tarball.
- **A build option that changes what h9 is.** `-Demu=unicorn` makes a GPLv2 binary. Cases, demos, and docs say which they need.
- **Uses that outlived their reason.** DEVELOPING.md builds an `h9-emu` to run `zig build mkroot` for amd64, and the web integration run's WebSocket cases and `zig build go-stdtest` ask for `-Demu=unicorn`, each because Unicorn was the only emulator when it was written.

## Proposal

- **The engine goes.** `src/vmm/unicorn.zig` and `unicorn_compat_aarch64.S` are deleted. `--backend emu` is hcpu, with no build in which it's anything else.
- **`-Demu` goes.** hcpu is always built in. `-Dno-jit`, `-Djit-check`, `-Djit-verify`, and `-Dhcpu-debug` stay. `-Dunicorn=prebuilt|source` goes with the source build.
- **The source build goes.** `build/unicorn.zig`, `third_party/unicorn/`, and the patched-source fetch in `scripts/fetch.sh` are deleted.
- **The release path goes.** `scripts/release.sh` no longer builds `h9-emu` or its source tarball, and README.md, LICENSE, and DEVELOPING.md no longer describe a GPLv2 build.
- **The uses move to hcpu.** `mkroot` for another architecture, the WebSocket cases' server, `go-stdtest`, and `zig build bench`'s emulator rows run on hcpu.
- **The oracle stays.** `zig build lockstep` and the fuzzers' lockstep mode keep comparing T0 against Unicorn, instruction by instruction. `src/vmm/lockstep.zig` moves to `tools/`, links the prebuilt `libunicorn.a` when it's been fetched, and fails with a hint when it hasn't. The fuzzers link it when it's there and run without lockstep when it isn't. Nothing else links it.

## Rationale

**Why remove an engine that works.** It's the only engine with a different licence, the only one that serializes guest threads, and the only one that isn't h9's or a host's. Each rename, interface change, and new exit kind is done once more for it, and nobody runs it.

**Why keep it as an oracle.** h86 has no other. ha64 can be checked against an arm64 host's CPU and hx64 against an x86-64 host's, but no engine runs 386 code on a real CPU, since h9 doesn't support 386 on the hypervisors. An independent implementation is what makes lockstep worth having, and a test tool that links a GPLv2 library doesn't affect what's shipped.

**Why not vendor it for the oracle.** The prebuilt wheel covers the hosts where lockstep runs (macOS arm64 and Linux). Windows doesn't run lockstep.

## Compatibility

- **CLI.** `--backend emu` is unchanged. A build can no longer be made in which it's Unicorn.
- **Build.** `-Demu` and `-Dunicorn` are removed, and passing either is an error that says hcpu is built in.
- **Releases.** No `h9-emu` assets, which [hcpu](hcpu.md) already decided. The source tarball for it goes too.
- **Licences.** h9 is MIT with no GPLv2 build. LICENSE and README.md drop the paragraph about it.
- **[renames](renames.md).** It says a `-Demu=unicorn` build's emulator is the `unicorn` engine, and that `-Demu` keeps its name. If this lands first, neither exists and renames needs no `unicorn` value. It's a draft and can say so.
- **`third_party/`.** `third_party/unicorn/` is removed.

## Security

None. Guests reach nothing new, and one engine's worth of code leaves the trusted base.

## Done criteria

- [x] `git grep -il unicorn` finds only `tools/lockstep.zig` and its aarch64 compat stub, its build step, the fuzzers that use it (`tests/jit/fuzz_*.zig` and `src/jit/check/fuzz_a64.zig`), `scripts/` lines that fetch the prebuilt library, `design/`, the spec's one paragraph on the oracle, and DEVELOPING.md's.
- [x] `zig build -Demu=unicorn` fails with a message that hcpu is built in.
- [x] `zig build lockstep` passes for h86, ha64, and hx64 with the library fetched, and fails with a hint without it.
- [ ] `zig build mkroot` for amd64 on an arm64 host, the web integration run's WebSocket cases, and `zig build go-stdtest` pass on hcpu.
- [ ] `scripts/release.sh` produces no `h9-emu` asset.
- [x] [spec/engines.md](../spec/engines.md) has no Unicorn engine section, and README.md, LICENSE, and DEVELOPING.md describe one licence.

## Implementation

1. Move mkroot, the WebSocket cases' server, go-stdtest, and bench to hcpu.
2. Move lockstep to `tools/` with its own link step.
3. Delete the engine, `-Demu`, and `-Dunicorn`.
4. Delete the source build, `third_party/unicorn/`, and the release path.
5. The spec and the docs.

## Open issues

- Whether to remove the oracle too. It would take another independent 386 implementation to check h86 against, such as QEMU's user mode run as a separate process, and lockstep by instruction over a process boundary is slow. As written, the oracle stays.
- Whether this lands before or after [renames](renames.md). Before is less work for renames.

## Updates

- 2026-11-23: Work started on the `retire-unicorn` branch. The fuzzers (`zig build fuzz-a64`, `fuzz-x86`, and `fuzz-x64`) were also users of Unicorn as an oracle, which Background didn't list, so they keep their lockstep mode: they link the prebuilt library when it's been fetched and run with the region check alone when it hasn't. The Proposal's oracle bullet and the first Done criteria item say so. On Linux the prebuilt library is for musl, so the tools that link it are built for the host architecture's musl target, whatever `-Dtarget` says. The emu demos, which ran only with `-Demu=unicorn`, now run on hcpu, and `tools/workloads/run.sh` takes T0 as its reference where there's no native run.
- 2026-11-23: On an x86-64 Linux VM with no KVM: `zig build test` passes; `zig build lockstep` passes its four tests (arm64, i386, and amd64) with the library fetched and fails with the fetch hint without it; `fuzz-a64`, `fuzz-x86`, and `fuzz-x64` ran 300 programs each in lockstep with no divergence; `zig build mkroot` built `/amd64` on hcpu, the mirror of the arm64 host case; `zig build integration -Dweb -Darch=arm64` passes 28 of the 37 `[websocket-9p]` cases with the native h9 on hcpu as their server, skips 8, and fails `--net=outbound binds only /net/ws on the web host`, which doesn't use the server; and `zig build go-stdtest -- time` passes 177 of `time`'s tests on hcpu, with two failing because the guest can't see the host's GOROOT. mkroot on an arm64 host and `scripts/release.sh`, which runs on macOS, are still to check.
