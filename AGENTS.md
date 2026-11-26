# Guidance for coding agents

## Start here

- Read [DEVELOPING.md](DEVELOPING.md) for setup, build commands, and repository layout.
- Read [SPEC.md](SPEC.md) before changing architecture or behavior that crosses components. It's the overview of the spec, and lists the files under `spec/` that describe each part of h9 as built; read the ones that cover what you're changing, and verify in the source what is implemented today.
- Read [spec/jit.md](spec/jit.md), [spec/h86.md](spec/h86.md), and [spec/ha64.md](spec/ha64.md) before changing h9's own CPUs (`src/engine/hcpu/interp/`, `src/engine/hcpu/jit/`, and `src/engine/hcpu/engine.zig`); like SPEC.md, they describe what's built.
- Read [design/README.md](design/README.md) before changing anything a proposal covers. Changes to the design go through proposals in `design/`.
- Check the existing code and tests before proposing or changing behavior. Keep changes focused and preserve established decisions unless the task explicitly calls for revisiting them.

## Project conventions

- This is a Zig project targeting native 9front executables on host hypervisors. Use the Zig version and setup described in DEVELOPING.md.
- Keep the public machine/library API independent of CLI-global state; keep the CLI a thin wrapper.
- Keep hypervisor-specific behavior behind the `src/engine.zig` interface and its engine implementations.
- Treat `third_party/drawterm` as vendored upstream code. Prefer changes in project-owned code; modify the vendor tree only when necessary, and keep such changes minimal. It is a squashed git subtree: update it only with `scripts/vendor-drawterm.sh`, never by copying files over it.
- Update MANUAL.md for user-visible changes, and DEVELOPING.md for changes to building or testing. Keep README.md short: it introduces h9 and links out, so a new feature goes there only if it belongs among its few examples.

## Proposals

- When a task would change anything listed under "When a proposal is needed" in `design/README.md`, find the proposal that covers it (`zig build design -- list`). If there's none, draft one with `zig build design -- new <slug>` and stop, unless the person you're working for directs you to build it. Then the PR adds or updates the proposal as it goes: its `branch` (the PR's branch), its Done criteria checkboxes, and its status.
- Refer to proposals by slug everywhere: in `depends`, test tags, links (`design/<slug>.md`, or `design/epoch-N/<slug>.md` once it's archived), comments, and PRs. Tag new cases with it: `test "name [slug]"`.
- A proposal's body says what changes and why, never what's built so far. Record progress in `status`, `branch`, the Done criteria checkboxes, and dated Updates notes.
- Never edit an accepted proposal's body, except to check off or waive a Done criteria item: add a dated note under its Updates section, or draft a new proposal.
- Never add, copy, or re-date a signature line (`Mon D, YYYY · Name, h.d.a.`) in a proposal or `SPEC.md`, run `zig build design -- sign`, post a `/sign` comment, or edit `design/SIGNERS`; only the named person signs, after reviewing the doc (see Signature in `design/README.md`). Don't remove an existing signature either. If you substantially change a signed doc, tell the user it may need re-signing.
- Add a dependency you discover to the proposal's `depends` in the same PR, and say so.
- The PR that finishes a proposal updates the spec to describe what was built (the file under `spec/` that covers it, or `SPEC.md` for the overview and the decisions table), checks off its Done criteria, and sets `status: implemented` and `branch: [main]`. The spec describes only what's built.
- Bug fixes, workarounds, and refactors that don't change behavior need no proposal; explain them in code comments and commit messages.
- Closed proposals are archived in `design/epoch-N/` by `zig build design -- archive`, in a PR of its own. Don't run it in a PR that does anything else, and don't move a proposal by hand.
- Run `zig build design -- check` before opening a PR. Don't run `zig build design -- status` or commit `design/STATUS.md` in a PR: a workflow regenerates it on main after each merge, so PRs don't conflict over it.

## Validate changes

Run the narrowest relevant check, and run broader checks when the change warrants them:

```sh
zig build test
zig build
zig build integration
zig build proposal -Dp=baseline
zig build kern
zig build design -- check
```

`zig build test` runs the unit and engine tests, and `zig build integration` runs the integration cases. They don't overlap, so `zig build test integration` runs both, each once.

DEVELOPING.md documents setup, including `scripts/env.sh` and `scripts/fetch.sh`.
