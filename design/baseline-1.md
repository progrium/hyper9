---
slug: baseline-1
title: Baseline 1 (h9 at the end of epoch 0)
status: draft
created: 2026-11-21
authors: [progrium]
depends: [renames, cow-fork, retire-unicorn]
areas: [process]
branch: []
---

# Proposal: Baseline 1

## Abstract

The second baseline, which closes epoch 0 and opens epoch 1 ([epochs](epoch-0/epochs.md)). It records where h9 stood when it was cut: the commit, what h9 had become, each of epoch 0's proposals with a line on what it decided, and the open proposals carried into epoch 1. It also restates what h9 is, in SPEC.md's title and overview, since "Plan 9 executables on host hypervisors" no longer describes it. It's cut after the work that was mostly built in epoch 0 has landed and the parts have their new names, so that everything in epoch 1 is written against one vocabulary and one description. Until it's cut this file is a draft that says what the baseline will hold, and the tables are filled in by the PR that cuts it.

## Background

[baseline](epoch-0/baseline.md) recorded the work before proposals, milestones M0 to M4. Epoch 0 is everything since: about 60 proposals, which took h9 from a runner for 9front binaries on three hypervisors to a kernel that also runs Linux binaries, has its own CPUs for three architectures, runs in a browser, serves its namespace over 9P, and sandboxes by namespace.

A reader today has to go through those proposals in order to learn why h9 is the way it is, and the first line of SPEC.md still describes the project of M0. Epoch 1's proposals ([kernel-port](kernel-port.md), [scheduler](scheduler.md), [memory-model](memory-model.md), [file-interface](file-interface.md), [host-handles](host-handles.md), and [plan-format](plan-format.md)) change h9's structure, and each needs to say what it's changing from.

## Proposal

### What depends on what

The baseline is cut once these are implemented:

- **[renames](renames.md),** so the baseline, the spec, and epoch 1 say ABI, engine, `sud`, and `hcpu`. It depends on [hcpu](hcpu.md).
- **[cow-fork](cow-fork.md),** which is partly built and which [memory-model](memory-model.md) builds on.
- **[retire-unicorn](retire-unicorn.md),** so the baseline describes one emulator.

Other open proposals don't hold it up. They're carried over, and listed as such.

### What the baseline holds

When it's cut, this file gains:

- **The commit** on main that it describes, and the 9front release and drawterm revision pinned then.
- **What h9 is,** in a few paragraphs: the statement that replaces SPEC.md's title and opening.
- **Epoch 0's proposals,** as a table of slug, status, and one line on what each decided or why it was declined, in the order they were written. It's the index to `design/epoch-0/`.
- **Carried over:** the proposals still open, with their status.
- **Epoch 1's direction:** the proposals above, and how they depend on each other.
- **Settled questions** from epoch 0 that aren't in any one proposal, as [baseline](epoch-0/baseline.md) has for the milestones.

### SPEC.md

SPEC.md's title becomes "Design: h9, a namespace kernel for Plan 9 and Linux executables", and its Overview's first paragraph, Goals, and Non-goals are rewritten to match what's built: a kernel with per-process namespaces, two ABIs, and engines that are hypervisors, stub processes, and h9's own CPUs. The decisions table is brought up to date. Nothing is described that isn't built.

### Cutting it

The PR that cuts the baseline is the last of epoch 0. Before it, `zig build design -- archive` is run in its own PR while the current epoch is still 0, so every closed proposal of epoch 0 is in `design/epoch-0/`. The cutting PR then fills in this file, updates SPEC.md, and sets `status: implemented`, which opens epoch 1: from then on `archive` moves closed proposals into `design/epoch-1/`. This file stays at the top of `design/` through epoch 1 and is archived with it.

## Rationale

**Why a baseline at all, and not just the next proposal.** Sixty proposals is past what anyone reads in order, and the archive made room at the top of `design/` without making the history easier to enter. A baseline is the one page to read first.

**Why wait for renames, cow-fork, and retire-unicorn.** A baseline written before the renames would describe h9 in words the next proposal abandons. cow-fork is half merged, and a baseline that says "partly" is a poor foundation for [memory-model](memory-model.md). Unicorn is the difference between "the emulator" being one thing and two.

**Why not wait for more.** [namespace-kernel](namespace-kernel.md), [kernel-serve](kernel-serve.md), [mounts](mounts.md), and [child-machines](child-machines.md) are designs that epoch 1 builds on, and none is far enough along to hold a baseline for. Waiting for them would put the baseline after the work it's meant to orient.

**Why retitle SPEC.md here.** The title is the claim about what h9 is, and the baseline is where that claim is restated on purpose. [renames](renames.md) leaves it alone for that reason.

## Compatibility

None for users: no code changes. `archive` files closed proposals under `design/epoch-1/` once this is implemented.

## Security

None. It's a record.

## Done criteria

- [ ] [renames](renames.md), [cow-fork](cow-fork.md), and [retire-unicorn](retire-unicorn.md) are implemented.
- [ ] `zig build design -- archive --dry-run` reports nothing to archive, with the current epoch still 0.
- [ ] This file has the commit, the statement of what h9 is, the table of epoch 0's proposals with every proposal in `design/epoch-0/` on a line, and the carried-over list.
- [ ] SPEC.md has the new title and overview, its decisions table matches what's built, and it's signed by the person who reviewed it as a whole.
- [ ] `zig build design -- check` passes, and `zig build design -- status` shows an Epoch 0 table and an empty Epoch 1.

## Implementation

1. Wait for the three dependencies.
2. Run `archive` in a PR of its own.
3. Write the table of epoch 0's proposals, from each one's Abstract and Declined or Updates sections.
4. Write what h9 is, here and in SPEC.md.
5. Set `status: implemented` and `branch: [main]`.

## Open issues

- The new title. "A namespace kernel for Plan 9 and Linux executables" is a proposal, and it's the sentence people will repeat.
- Whether [retire-unicorn](retire-unicorn.md) should hold the baseline up, or be carried over if it isn't done when renames is.
- Whether the table of epoch 0's proposals is written by hand or generated by the tool from each proposal's frontmatter and Abstract.
