# Guidance for coding agents

## Start here

- Read [README.md](README.md) for setup, build commands, and repository layout.
- Read [DESIGN.md](DESIGN.md) before changing architecture or behavior that crosses components. It describes h9 as built; verify in the source what is implemented today.
- Read [design/README.md](design/README.md) before changing anything a proposal covers. Changes to the design go through proposals in `design/`.
- Check the existing code and tests before proposing or changing behavior. Keep changes focused and preserve established decisions unless the task explicitly calls for revisiting them.

## Project conventions

- This is a Zig project targeting native 9front executables on host hypervisors. Use the Zig version and setup described in the README.
- Keep the public machine/library API independent of CLI-global state; keep the CLI a thin wrapper.
- Keep hypervisor-specific behavior behind the `src/vmm.zig` interface and its backend implementations.
- Treat `third_party/drawterm` as vendored upstream code. Prefer changes in project-owned code; modify the vendor tree only when necessary, and keep such changes minimal. It is a squashed git subtree: update it only with `scripts/vendor-drawterm.sh`, never by copying files over it.
- Update the README for user-visible changes.

## Proposals

- When a task would change anything listed under "When a proposal is needed" in `design/README.md`, find the accepted proposal that covers it and check that it's ready (`zig build design -- ready`). If there's none, don't implement the change: draft one with `zig build design -- new <slug>`, leave it as a draft, and stop.
- Cite the proposal in implementation PRs, and tag new integration cases with it: `test "name [slug]"`.
- Never edit an accepted proposal's body: add a dated note under its Updates section, or draft a new proposal.
- Add a dependency you discover to the proposal's `depends` in the same PR, and say so.
- The PR that finishes a proposal updates `DESIGN.md` to describe what was built and sets `status: implemented`. `DESIGN.md` describes only what's built.
- Bug fixes, workarounds and refactors that don't change behavior need no proposal; explain them in code comments and commit messages.
- Run `zig build design -- check` before opening a PR, and `zig build design -- readme` when a proposal's status or dependencies change.

## Validate changes

Run the narrowest relevant check, and run broader checks when the change warrants them:

```sh
zig build test
zig build
zig build proposal -Dp=baseline
zig build kern
zig build design -- check
```

The README documents setup, including `scripts/env.sh` and `scripts/fetch.sh`.
