---
slug: epochs
title: Epochs, and archiving closed proposals
status: implemented
created: 2026-11-21
authors: [progrium]
depends: [proposal-flow, spec-split]
areas: [process, build]
branch: [main]
---

# Proposal: Epochs, and archiving closed proposals

Nov 21, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

The top of `design/` holds the proposals still being decided or built. A proposal that's implemented, declined, or superseded is archived: `zig build design -- archive` moves it into the current epoch's folder, `design/epoch-N/`, and rewrites every link to it. An epoch is the stretch of work between two baselines. Epoch 0 runs from the first [baseline](baseline.md), and a later proposal named `baseline-1` will open epoch 1. Slugs, test tags, and `depends` don't change, because a proposal is still named by its slug wherever its file is.

## Background

`design/` had 60 proposals in one folder after three weeks, and 41 of them were closed: 34 implemented, 4 declined, and 3 superseded.

- **Open work is hard to see.** The folder listing, [STATUS.md](../STATUS.md)'s table, and its graph give a finished proposal the same room as a draft. The graph had 60 nodes, most of them green.
- **Closed proposals are frozen, and read as current.** An accepted proposal's body isn't edited ([proposals](proposals.md)), so a proposal from the first week still describes h9 in that week's words. Next to open drafts, nothing says it's a record and not a plan.
- **There's a precedent.** [baseline](baseline.md) folded everything before proposals into one document. Doing that again for the proposals since needs somewhere to put them.

The spec describes h9 as built ([spec-split](spec-split.md)), so a closed proposal is read for its reasoning: why a decision was made, and what was rejected.

## Proposal

### Epochs and baselines

- **An epoch** is the work between one baseline and the next, numbered from 0.
- **A baseline** is a short proposal that opens an epoch. It records where h9 stood: the commit, a table of the closed epoch's proposals with a line on each decision, and the open proposals carried over. `baseline` opened epoch 0, and `baseline-K` opens epoch K.
- **The current epoch** is the highest K with a `baseline-K` proposal, or 0 before there's one.

This proposal adds the folders and the tool. It doesn't cut a baseline: epoch 0 stays open, and when to write `baseline-1` is a separate decision.

### Archiving

`zig build design -- archive` moves each proposal at the top of `design/` whose status is `implemented`, `declined`, or `superseded` into `design/epoch-N/`, where N is the current epoch, with `git mv`. `--dry-run` lists what would move.

- **The baseline that opened the current epoch stays** at the top of `design/` until the next baseline, since it's what the open proposals build on. It's archived with the epoch it opened.
- **Archiving isn't part of finishing a proposal.** The PR that finishes one leaves its file where it is. `archive` is run now and then in a PR of its own, and always when a baseline is cut, because it touches every file that links to what it moves.
- **`check` doesn't ask for it.** A closed proposal at the top of `design/` is fine. A proposal in an epoch folder that isn't closed is an error.
- **A proposal is never moved back.** Reopening a decision takes a new proposal.

### Links

`archive` rewrites the links to each proposal it moves, in every file git tracks outside `third_party/`:

- `design/<slug>.md` anywhere becomes `design/epoch-N/<slug>.md`: Markdown links from any folder, comments in the source, and URLs on the site.
- In a file under `design/`, a relative link (`](<slug>.md)`) is rewritten for where both files now are: `](epoch-N/<slug>.md)` from the top, `](<slug>.md)` between two proposals in one epoch folder, and `](../<slug>.md)` from an archived proposal to an open one.
- In a file that moved, every other relative link gets one more `../`, including the link to README in a signature line. Links inside code blocks are left alone.

This edits the bodies of accepted proposals, which the process otherwise forbids. The exception is narrow: `archive` changes link targets and nothing else, and it's the only thing that does.

`check` knows the folders. A link to a proposal must name the folder it's in, and the error for one that doesn't says where the proposal is now.

### The tool

- **Reading.** Every command reads `design/*.md` and `design/epoch-*/*.md`. `list`, `log`, `sign`, `propose --issue`, and `close-issues` work on an archived proposal as before, and `new` refuses a slug that's used in any folder.
- **Signatures.** An archived proposal's signature links to `../README.md#signature`, which `check` accepts and `sign` writes.
- **STATUS.md.** The table and the graph cover the top of `design/` only, and the graph leaves out edges from archived proposals. A table per epoch follows, with each archived proposal's issue, status, and title.

## Rationale

- **Folders, not a frontmatter key.** An `epoch: 0` key would let the tool filter, but the folder listing on GitHub, which is how proposals are browsed, would stay 60 files long.
- **Move the files, and fix the links.** Leaving a stub at the old path would keep links working and double the files. A link checker and a rewriter cost less than a second copy of every name.
- **Slugs stay the reference.** Test tags, `depends`, `superseded-by`, and `zig build proposal -Dp=<slug>` never named a path, so none of them change.
- **Archiving apart from finishing.** If the finishing PR moved its own proposal, every feature PR would also rewrite links across the tree and conflict with the other open PRs. One archiving PR now and then keeps that in one place.
- **Not at the baseline only.** Waiting for a baseline to move anything would leave the folder as it is until then, and the files are frozen the day they close.
- **Numbered from 0.** The existing `baseline` then needs no rename, and a baseline's number is the epoch it opens.
- **`archive`, not `file`.** `file` was this tool's name for what's now `propose` ([proposal-flow](proposal-flow.md)).

## Compatibility

Nothing in h9 changes. For people and agents working in the tree:

- A branch that links to `design/<slug>.md` for a proposal archived since fails `check` when it rebases, with the new path in the message.
- Links from outside the repository to an archived proposal's old path break. GitHub issues opened by `propose` link to the proposal's file on a branch, and `close-issues` comments link to it on main, so the older ones now miss.
- A signature line in a moved proposal has its link target changed (`README.md` to `../README.md`). The date and the name aren't touched.

## Security

None. Only documents and the design tool change.

## Done criteria

- [x] `zig build design -- archive --dry-run` lists the closed proposals at the top of `design/`, and `archive` moves them into `design/epoch-0/`.
- [x] `zig build design -- check` passes after the move, so every link to a moved proposal resolves.
- [x] A second `archive` moves nothing and rewrites nothing.
- [x] The `epochs.txtar` check fixture passes: an open proposal in an epoch folder is an error, and a link to a proposal's old place names its new one.
- [x] The `archive: links follow a proposal into its epoch folder` test passes.
- [x] The build reads proposals through the tool's own scan (`frontmatter.scan`), so `zig build proposal -Dp=<slug>` and the pending tags cover archived proposals.

## Implementation

1. `tools/frontmatter.zig`: `scan` reads the epoch folders, and a proposal knows its epoch.
2. `tools/design.zig`: `check`'s placement rule and link forms, `archive`, the signature link from an epoch folder, and STATUS.md's layout.
3. `design/README.md` and `AGENTS.md`: the rule, and the command.
4. Run `archive`.

## Open issues

- **When to cut `baseline-1`.** Probably once the proposals that are mostly built have landed and the source tree's renames are done, so the baseline is written in the names the next epoch uses.
- **Whether main's workflow should archive.** `design-status.yml` could run `archive` after each merge, as it regenerates STATUS.md, at the cost of commits on main that move files under open PRs.
