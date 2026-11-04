# Proposals

Design changes to h9 go through proposals: one Markdown file each in this directory, with frontmatter for status and dependencies, numbered by the GitHub issue where it's discussed. [DESIGN.md](../DESIGN.md) describes h9 as built; proposals say what changes and why. The order of work comes from the dependency graph, not from milestones. The process is adapted from Go's ([golang/proposal](https://github.com/golang/proposal)), and was itself adopted as [proposal 1](0001-proposals.md).

## When a proposal is needed

A proposal is needed for:

- changes to the `vmm` interface, the `Machine` API or `Machine.Options`
- CLI flags and exit codes
- sandbox capabilities, profiles and defaults
- new backends, personalities, devices or root types
- changes to `third_party/` beyond merging upstream
- changes to this process

It isn't needed for bug fixes, workarounds, performance work that doesn't change behaviour, or internal refactors; their reasoning goes in code comments and commit messages. If in doubt, draft one: a short proposal costs little.

## Writing one

`zig build design -- new <slug>` copies [TEMPLATE.md](TEMPLATE.md) to `design/<slug>.md` with the frontmatter filled in. A slug is lowercase words of letters and digits joined by dashes (`linux-personality`, `9p-roots`), unique, and never changed. Write a line per paragraph.

The sections are Abstract, Background, Proposal, Rationale, Compatibility, Security, Done when, Implementation and Open issues, and, after acceptance, Updates. Rationale should cover the alternatives that were rejected, so the question isn't asked again. Done when names the demo commands and the integration cases that prove the proposal, the way the old milestone demos did.

## Filing and numbering

A draft has only its slug, and its file is `design/<slug>.md`. `zig build design -- file <slug>` creates the GitHub issue (title `proposal: <title>`, the `Proposal` label, the Abstract and a link to the file as the body), renames the file to `design/NNNN-<slug>.md` with its `id` set to the issue number, rewrites references to the slug as the number and links to the old path, refreshes the README table, and commits. It asks first, as it creates the issue as the account `gh` is logged in as; `--dry-run` shows what it would do, and `--yes` skips the question. `--issue N` numbers the draft for an issue that already exists, without touching GitHub.

Discussion happens on the issue. The doc is revised in commits. A proposal can't leave `draft` without an `id`: drafting needs no GitHub, but deciding needs an issue to discuss it on. The slug stays as an alias after filing, so a reference written before the number existed still resolves. The [baseline](0000-baseline.md), the work done before proposals, is `id: 0` and has no issue.

## Frontmatter

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
| `depends` | always, may be `[]` | Proposals that must be implemented before this one can be, by id or slug |
| `areas` | no | Free-form tags for filtering: `vmm`, `kern`, `cli`, `sandbox`, `build`, `tests`, `process` and so on |
| `superseded-by` | when `superseded` | The proposal that replaces it |

The syntax is a strict subset of YAML: one `key: value` per line, values are scalars or flow lists (`[a, b]`), with no nesting, quoting or multi-line values. Since nothing is quoted, a value can't contain `: ` or ` #` or start with a YAML indicator such as `#`, and list items are plain words. Only facts are stored. Whether a proposal is ready (accepted, with every dependency implemented) and what it blocks are computed by the tool.

## States

| Status | Meaning |
| --- | --- |
| `draft` | Being written or discussed; the only state allowed without an `id` |
| `likely-accept`, `likely-decline` | The final comment period: at least three days, announced on the issue, for second thoughts. Significant new discussion moves it back to `draft`. |
| `accepted` | Decided. Work can start once every dependency is implemented. |
| `declined` | Decided against; kept, so the reasoning can be found later. The issue is closed. |
| `hold` | Paused, with a reason on the issue |
| `implemented` | Built, its Done when cases exist and pass, and DESIGN.md describes it. The tool doesn't enforce the cases, so a proposal with nothing to test can still be marked implemented; the PR says why. |
| `superseded` | Replaced by `superseded-by` |

Each status change is its own commit (`design: 42 likely-accept`), so `git log design/` is the record of decisions. The frontmatter is authoritative; issue labels may mirror it. At most three proposals sit in a final comment period at a time, so finishing decisions comes before starting new ones.

## After acceptance

An accepted proposal's body isn't edited. A discovery during implementation that refines the design gets a dated note under an Updates section at the end; one that changes the design gets a new proposal, which supersedes the old one or is added to its `depends`. A dependency found during implementation is added to `depends` in the same PR, with a line saying so.

The PR that finishes a proposal updates DESIGN.md to describe what was built, tags the passing cases, and sets `status: implemented`. DESIGN.md never describes unbuilt features, and proposals aren't updated to describe the current system. DESIGN.md links to a proposal only where the proposal gives more information or context, such as the alternatives behind a decision.

## Tests

Integration cases are tagged with the proposal they prove, by slug or id, in brackets at the end of the name: `test "ls /bin | wc -l (demo) [baseline]"`, `test "ramfs posts to /srv [devsrv]"`. A case whose proposal isn't implemented skips in `zig build integration` and `zig build test`, unless `-Dpending` is given, and stops skipping in the commit that marks the proposal implemented. Untagged cases always run. Write tags as `[a, b]`, with a comma and a space; `check` enforces it, since `zig build proposal` matches them by text.

`zig build proposal -Dp=<id or slug>` runs one proposal's demos and cases, whatever its status. Demos that aren't integration cases are registered for their proposal in `build.zig` (`addDemo`).

## The tool

`zig build design -- <command>`, from [tools/design.zig](../tools/design.zig):

| Command | Does |
| --- | --- |
| `list [--status S] [--area A]` | A table of id, slug, status, ready or what it needs, and title |
| `ready` | Accepted proposals whose dependencies are all implemented: what can be started now |
| `graph` | The dependency graph, as Mermaid |
| `readme` | Rewrites the proposal table and graph in the top-level README, between its `design:begin` and `design:end` markers |
| `new <slug> [--title T] [--author LOGIN]` | Starts a draft from the template |
| `file <slug> [--yes] [--dry-run] [--issue N]` | Files a draft, as above |
| `fix` | Rewrites slug references to filed proposals as numbers |
| `check` | Validates the proposals and test tags; run in CI and before a PR |

`check` fails on bad frontmatter (including values YAML would read differently), tags not written as `[a, b]`, a duplicate slug or id, a filename that doesn't match them, a status past `draft` without an `id`, a reference that doesn't resolve (in `depends`, `superseded-by` or a test tag), a dependency cycle, an implemented proposal with a dependency that isn't, an accepted proposal that depends on a declined one, `superseded` without `superseded-by`, and more than three proposals in a final comment period. It warns on a slug reference to a filed proposal, which `fix` rewrites, and on an out-of-date README table, which `readme` rewrites.
