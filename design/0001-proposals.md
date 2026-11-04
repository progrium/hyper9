---
id: 1
slug: proposals
title: Proposals replace milestones and the design changelog
status: implemented
created: 2026-11-03
authors: [progrium]
depends: []
areas: [process, build, tests]
---

# Proposal: proposals replace milestones and the design changelog

Nov 3, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Design changes to h9 go through proposals: one Markdown file each under `design/`, with frontmatter for status and dependencies, numbered by the GitHub issue where it's discussed. Milestones go away; the order of work comes from the dependency graph. DESIGN.md becomes a description of h9 as built, with no milestone list and no changelog. A small Zig tool lists, checks and files proposals, and the integration tests are tagged with proposals instead of milestones. The process is adapted from Go's ([golang/proposal](https://github.com/golang/proposal)).

## Background

DESIGN.md does three jobs at once. It describes how h9 works, it plans what comes next (the Milestones section, and design text for features that don't exist yet, such as 9P roots and host self-sandboxing), and it records why things changed (the Changelog, filed under the milestone in progress). Each job makes the others worse:

- **The plan is a line.** Milestones are numbered, so anything new lands after M10 or forces a renumbering, even when it depends on nothing pending. A Linux personality, for example, needs only what M3 and M4 already provide, but has nowhere to go except "M11".
- **Milestones bundle unrelated work.** M5 holds devsrv, semaphores, segattach, network policy, ephemeral writes and Go compatibility. They can't be decided, started or finished separately, and Go compatibility's real dependency (semaphores) isn't written down anywhere.
- **The changelog mixes kinds of entry.** Design decisions (the sandbox becomes a capability policy) sit next to workarounds (`__clear_cache` on Linux arm64, `memccpy` on musl), which belong in code comments and commit messages. The section grows with every change and is read in order, so the doc keeps getting longer and more linear.
- **There's no place for an idea that isn't accepted yet.** A design that's still being argued either goes into DESIGN.md, as if decided, or lives only in a conversation.
- **Agents follow the rule they're given.** AGENTS.md tells them to edit DESIGN.md and add a changelog entry, so every agent-driven decision lands in the doc directly, with no point where a person accepts it.

Go solves the same problems with proposals: a proposal is identified by an issue, discussed there, written up as `design/NNNN-shortname.md` only when the discussion asks for detail, and decided after a final comment period. Go keeps its design docs as history and its spec as the description of the current system.

## Proposal

### Layout

```
DESIGN.md                    h9 as built: architecture, invariants, decisions
design/
  README.md                  the process
  TEMPLATE.md
  proposals.md               this proposal, while it's a draft
  0042-linux-personality.md  a filed proposal
tools/
  design.zig                 the design tool
  frontmatter.zig            the parser, shared with build.zig
```

Proposals live in this repository, not a separate one as in Go, so agents see them next to the code and a proposal and its first implementation can land in one PR.

### Identity: slugs, then issue numbers

Every proposal has a `slug`: lowercase words joined by dashes, unique across all proposals, and never changed. A draft has only the slug, and its file is `design/<slug>.md`. Filing creates the GitHub issue; from then on the proposal's `id` is the issue number and its file is `design/NNNN-<slug>.md`, padded to four digits for looks (sorting is numeric). The slug stays as an alias, so anything that referred to the draft by slug still resolves.

A proposal can't leave `draft` without an `id`: drafting needs no GitHub, but deciding needs an issue to discuss it on. A proposal that starts as a Go-style issue with no doc gets its file with its number from the start, when one is needed. An issue-only proposal can't appear in `depends`, so anything another proposal depends on gets a file, even a short one.

### Frontmatter

```yaml
---
id: 42
slug: linux-personality
title: Linux personality
status: accepted
created: 2026-11-03
authors: [progrium]
depends: [43, symlinks-in-root]
areas: [kern, vmm, cli, sandbox]
superseded-by:
---
```

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | once filed | The GitHub issue number |
| `slug` | always | Permanent name; an alias for `id` |
| `title` | always | Also the issue title, after `proposal: ` |
| `status` | always | See States |
| `created` | always | `YYYY-MM-DD` |
| `authors` | always | GitHub logins |
| `depends` | always, may be `[]` | Proposals that must be implemented before this one can be; ids or slugs |
| `areas` | no | Free-form tags for filtering: `vmm`, `kern`, `cli`, `sandbox`, `build`, `tests`, `process` and so on |
| `superseded-by` | when `superseded` | The proposal that replaces it |

The syntax is a strict subset of YAML: one `key: value` per line, values are scalars or flow lists (`[a, b]`), no nesting, quoting or multi-line values. That keeps the parser small enough to share between the tool and `build.zig` without a YAML library.

Only facts are stored. Whether a proposal is *ready* (accepted, with every dependency implemented), what it *blocks* (the reverse of `depends`) and what's *in progress* are computed by the tool, so they can't drift.

### States

| Status | Meaning |
| --- | --- |
| `draft` | Being written or discussed; the only state allowed without an `id` |
| `likely-accept`, `likely-decline` | The final comment period: at least three days, announced on the issue, for second thoughts. Significant new discussion moves it back to `draft`. |
| `accepted` | Decided. Work can start once every dependency is implemented. |
| `declined` | Decided against; kept, so the reasoning can be found later. The issue is closed. |
| `hold` | Paused, with a reason on the issue |
| `implemented` | Built, its "Done when" cases exist and pass, and DESIGN.md describes it. The tool doesn't enforce the cases, so a proposal with nothing to test, such as a process change, can still be marked implemented; the PR says why. |
| `superseded` | Replaced by `superseded-by` |

Each status change is its own commit (`design: 42 likely-accept`), so `git log design/` is the record of decisions. The issue's labels may mirror the status, but the frontmatter is authoritative. At most three proposals sit in `likely-accept` or `likely-decline` at a time, so finishing decisions comes before starting new ones (Go's Incoming column does this for a larger group).

### Scope

A proposal is needed for:

- changes to the `vmm` interface, the `Machine` API or `Machine.Options`
- CLI flags and exit codes
- sandbox capabilities, profiles and defaults
- new backends, personalities, devices or root types
- changes to `third_party/` beyond merging upstream
- changes to this process

It isn't needed for bug fixes, workarounds, performance work that doesn't change behaviour, or internal refactors; their reasoning goes in code comments and commit messages. If in doubt, draft one: a short proposal costs little.

### Template

`design/TEMPLATE.md` follows Go's, with three changes. Compatibility covers what h9 has instead of a Go 1 promise. Security is new, because most of h9's design choices are sandbox choices. And "Done when" replaces the milestone demos. Proposals are written with a line per paragraph, as DESIGN.md is.

1. **Abstract:** a short summary.
2. **Background:** the problem, and what exists today.
3. **Proposal:** a precise statement of the change.
4. **Rationale:** alternatives and trade-offs, including the ones rejected, so the question isn't asked again.
5. **Compatibility:** effects on CLI flags, `Machine.Options`, sandbox defaults, the root tree and `third_party/`.
6. **Security:** what the guest can newly reach, and how the policy covers it.
7. **Done when:** the demo commands and the integration cases that prove it, by name.
8. **Implementation:** the steps, in order.
9. **Open issues:** questions without answers yet. May be omitted.
10. **Updates:** dated notes added after acceptance. Omitted until there's one.

### After acceptance

An accepted proposal's body isn't edited. A discovery during implementation that refines the design gets a dated note under Updates; one that changes the design gets a new proposal, which supersedes the old one or is added to its `depends`. A dependency found during implementation is added to `depends` in the same PR, with a line saying so.

The PR that finishes a proposal updates DESIGN.md to describe what was built, tags the passing cases, and sets `status: implemented`. DESIGN.md never describes unbuilt features; proposals never get updated to describe the current system. DESIGN.md links to a proposal only where the proposal gives more information or context, such as the alternatives behind a decision, not as a rule for every section, and the tool doesn't check those links.

### Tests

Integration cases are tagged with the proposal they prove, in brackets at the end of the name: `test "ls /bin | wc -l [baseline]"`, `test "ramfs posts to /srv [devsrv]"`. A tag is an id or a slug. Demo cases keep the word `demo` in the name.

`build.zig` reads the frontmatter through `tools/frontmatter.zig` and passes the tags of proposals that aren't `implemented` to the test binary (`H9_TEST_PENDING_TAGS`), which skips those cases unless `-Dpending` is given. That replaces the `"M5: ..."` naming convention: a case is pending because its proposal is, not because of how it's named, and it stops skipping in the commit that sets `implemented`.

| Today | After |
| --- | --- |
| `(M2)`, `(M3)`, `(M4)` in case names | `[baseline]` |
| `"M5: ..."` pending cases | `[slug]` of the proposal, skipped until implemented |
| `zig build m1` … `zig build m4` | removed, with no aliases; `zig build proposal -Dp=baseline` runs every baseline demo and case |
| `zig build integration` | unchanged: every case of an implemented proposal |
| (none) | `zig build proposal -Dp=<id or slug>`: one proposal's cases, pending or not |

### The tool

`zig build design -- <command>`, built from `tools/design.zig`:

| Command | Does |
| --- | --- |
| `list [--status S] [--area A]` | A table of id, slug, title, status, and ready or blocked by what |
| `ready` | Accepted proposals whose dependencies are all implemented: what can be started now |
| `graph` | The dependency graph as Mermaid, for the README |
| `new <slug>` | Copies the template to `design/<slug>.md` with the frontmatter filled in |
| `file <slug>` | Creates the issue with `gh` (title, `Proposal` label, the Abstract and a link to the file as the body), renames the file, sets `id`, rewrites slug references to the number, and commits |
| `fix` | Rewrites slug references to filed proposals as numbers |
| `check` | Validates everything below; run in CI and by agents before a PR |

`check` fails on:

- bad frontmatter: a missing required field, an unknown status, a malformed date
- a duplicate slug or id, or a filename that doesn't match them
- a status past `draft` without an `id`
- a reference that doesn't resolve, in `depends`, `superseded-by` or a test tag
- a dependency cycle
- an `implemented` proposal with a dependency that isn't
- an `accepted` proposal that depends on a `declined` one
- `superseded` without `superseded-by`
- more than three proposals in a final comment period

It warns on a slug reference to a filed proposal, so a branch drafted before the filing still passes after a rebase; `fix` cleans it up.

### Migration

1. **Baseline.** M0 to M4 are done and described by DESIGN.md as it stands. They become one proposal, `0000-baseline.md` (`slug: baseline`, `status: implemented`, no issue). Its body is the record of how h9 got here: the M0 to M4 entries from the Milestones section, with their demos, and DESIGN.md's Changelog, moved unchanged with its dated entries and milestone headings. The one M5 entry so far (the rename from hp9 to h9) moves with it, since it predates proposals. Like any implemented proposal, it isn't edited afterwards. Finished work gets no retroactive proposals.
2. **DESIGN.md.** The Milestones and Changelog sections are removed, and DESIGN.md links to the baseline proposal for the history. Design text for unbuilt work moves into proposals, leaving DESIGN.md about what exists. Milestone references in the remaining text ("from M5", "M10") are dropped, or become links where the proposal adds context.
3. **Remaining milestones become proposals**, split by feature rather than kept as bundles. Each starts as a `draft` with its existing design text, and is filed and accepted as work reaches it:

    | Slug | Depends on |
    | --- | --- |
    | `devsrv` | |
    | `semaphores` (rendezvous, semacquire, tsemacquire, semrelease) | |
    | `segattach` | |
    | `net-policy` (outbound by default, `--net-allow`) | |
    | `ephemeral-writes` (`--write=ephemeral`, private `/tmp`) | |
    | `go-compat` (`/dev/bintime`, `_NSEC`) | `semaphores` |
    | `self-host` (compilers, mk, acid's `/proc` files) | `segattach` |
    | `gfx` (`--gfx`, devdraw) | `devsrv` |
    | `kvm` | |
    | `whp` | |
    | `9p-roots` | `devsrv` |
    | `image-roots` (cwfs, gefs) | `9p-roots` |
    | `overlay` (copy-on-write, the root's default) | `ephemeral-writes` |
    | `host-sandbox` (Seatbelt, Landlock and seccomp, AppContainer) | `kvm`, `whp` |

    The research notes each milestone was meant to record (Seatbelt with `--gfx`, Landlock with KVM, AppContainer with WHP) go into the relevant proposal's Open issues.
4. **Tests and build.** Case tags and build steps change as in Tests.
5. **README.** The status checklist is replaced by a table generated by `list`, plus the `graph` output.
6. **AGENTS.md.** The rule to edit DESIGN.md and add a changelog entry is replaced by:

    > When a task would change anything listed under Scope in `design/README.md`, find the accepted proposal that covers it and check that it's ready (`zig build design -- ready`). If there's none, don't implement the change: draft one with `zig build design -- new <slug>`, leave it as a draft, and stop. Cite the proposal in implementation PRs, and tag new integration cases with it. Never edit an accepted proposal's body: add a dated note under Updates, or draft a new proposal. Add a dependency you discover to `depends` in the same PR, and say so. The PR that finishes a proposal updates DESIGN.md to match and sets `status: implemented`. Run `zig build design -- check` before opening a PR.

## Rationale

**Keep milestones and add proposals beside them.** Milestones would still impose a line and bundle unrelated work, and every proposal would need a milestone, which is the decision this replaces. The thing milestones did well, a demo that proves the work done, moves into each proposal's "Done when".

**A separate proposals repository, as in Go.** Go's has many contributors and a review group; h9's main readers are one person and the agents working in this repository. In-repo proposals can land with their first implementation, and agents find them without cloning anything.

**Status on GitHub (labels or a project board) instead of frontmatter.** Agents would need the GitHub API to know what's ready, CI couldn't check the graph offline, and decisions wouldn't be in git history. Labels can still mirror the status.

**Issue numbers only, with no drafts before filing.** Every idea would need an issue before it's written down, and agents drafting offline couldn't. Temporary numbers (`d1`, random hex) collide across branches and mean nothing in a `depends` list. A slug that becomes an alias does neither.

**Sequential local numbers, with issues optional.** Simpler, but discussion would have no fixed home, and two branches would assign the same number. Issue numbers are assigned by GitHub, so they're unique by construction.

**Full YAML frontmatter.** Needs a YAML library in `build.zig` or a second language. The subset covers every field.

**A Python tool, like `scripts/mkroot.py`.** It would need its own frontmatter parser, while `build.zig` needs one in Zig for the test tags. One parser in Zig serves both, and `zig` is already required.

**No final comment period, with one decider.** Many proposals will be drafted by agents. A few days between "this looks right" and "accepted" is where a person reviews them, and it costs nothing when nobody objects.

## Compatibility

No user-visible change to h9: no CLI flags, `Machine.Options` or sandbox defaults change. Developer-facing changes:

- `zig build m1` … `m4` are removed, with no aliases; `zig build proposal -Dp=baseline` runs the same demos and cases.
- Integration case names change from `(Mn)` to `[tag]`, which changes `zig build test` filters that match on them.
- DESIGN.md loses its Milestones and Changelog sections; both are preserved in `design/0000-baseline.md`.
- AGENTS.md's rule for design changes changes, as above.

## Security

None for the guest or the host. `file` runs `gh` with the user's credentials and creates an issue; it prints what it will create and asks before doing it, unless given `--yes`.

## Done when

- `zig build design -- check` passes on the migrated tree, and fails on a fixture set under `tools/testdata/` covering each failure listed under The tool.
- `zig build design -- ready` lists the proposals from Migration that are accepted and unblocked.
- `zig build proposal -Dp=baseline` runs every case formerly tagged `(M2)`, `(M3)` or `(M4)` and every former M0 to M4 demo, and they pass.
- A case tagged with a draft proposal skips in `zig build integration` and runs with `-Dpending`.
- `zig build design -- new linux-personality` followed by `file linux-personality` (against a test repository, or with `--dry-run`) produces `design/NNNN-linux-personality.md` and rewrites a slug reference to it elsewhere.
- DESIGN.md has no Milestones or Changelog section and no milestone references, and `0000-baseline.md` holds both, with every Changelog entry unchanged.

## Implementation

1. `tools/frontmatter.zig` and `tools/design.zig` with `list`, `ready`, `graph`, `new` and `check`, and the fixtures.
2. `design/README.md` (the process: States, Scope, After acceptance, the tool) and `design/TEMPLATE.md`.
3. `0000-baseline.md`, holding the M0 to M4 milestones and the Changelog moved out of DESIGN.md.
4. The draft proposals from Migration, with their design text moved out of DESIGN.md.
5. Test tags, `H9_TEST_PENDING_TAGS`, and the `proposal` build step; the `m1`–`m4` steps removed.
6. `file` and `fix`.
7. README and AGENTS.md.

This proposal is decided under the current process, since the new one doesn't exist yet: it's filed by hand, and accepted by a commit to this file. It becomes the first proposal to reach `implemented` under its own rules.

## Updates

- 2026-11-03: Refinements made while implementing it:
  - `file --issue N` numbers a draft for an issue that already exists, without touching GitHub, as when an issue is opened by hand (this one was).
  - `readme` rewrites a generated table and graph between markers in the top-level README, and `check` warns when it's out of date.
  - The tags of proposals that aren't implemented are compiled into the integration tests as a build option (`design.pending_tags`), rather than passed as `H9_TEST_PENDING_TAGS`, so a binary from `zig build install-tests` knows them too. `-Dpending` sets `H9_TEST_PENDING`, as before.
  - The baseline demos that need a root tree are left out of `zig build proposal -Dp=baseline` when there's no tree, as the integration cases skip, rather than failing; the hello demos always run.
  - Slugs may start with a digit (`9p-roots`), but can't be all digits, which would read as an id. The baseline's id 0 isn't an issue, so references to it keep its slug, and `fix` leaves them alone.
  - Migration added three drafts the table didn't list, for DESIGN.md text with nowhere else to go: `zig-interpreter` (the emulator's second step), `hide-host-paths` (an open question) and `ci` (the CI plan). The `self-host` and `9p-roots` drafts don't depend on `segattach` and `devsrv`: nothing in their design text needs them, and `self-host` notes it may gain a dependency.
  - Milestone names were also replaced in source comments and scripts, and `--print`'s network caveat now reads "the network is not restricted beyond --net=disable".
  - `image-roots` depends on `devsrv` as well as `9p-roots`, since it posts to `/srv`.
  - `check` also refuses scalar values that YAML would read differently, since values are never quoted (a `: ` or ` #` inside, or a leading indicator such as `#` or `-` followed by a space), and list items that aren't plain words. That keeps the frontmatter a true subset of YAML; the baseline's title lost its colon for it.
  - `check` refuses test tags not written as `[a, b]`, since `zig build proposal -Dp` matches them by text, and `fix` rewrites them.
  - `file` also rewrites links to the draft's old path (`design/<slug>.md` in any tracked file, and `](<slug>.md` within `design/`), refreshes the README table, and commits a draft that was never committed.
  - The Done when item for `file` is met with `--issue N`, which numbers a draft offline. `--dry-run` changes nothing, as its name says.
