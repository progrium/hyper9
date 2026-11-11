# Proposals

Design changes to h9 go through proposals: one Markdown file each in this directory, named by its slug, with frontmatter for status, dependencies, and where its work lives. [SPEC.md](../SPEC.md) describes h9 as built; proposals say what changes and why. The order of work comes from the dependency graph, not from milestones. The process is adapted from Go's ([golang/proposal](https://github.com/golang/proposal)), was adopted as [proposals](proposals.md), and was reworked by [proposal-flow](proposal-flow.md) so work can start on a branch before or alongside its proposal.

## When a proposal is needed

A proposal is needed for:

- changes to the `vmm` interface, the `Machine` API, or `Machine.Options`
- CLI flags and exit codes
- sandbox capabilities, profiles, and defaults
- new backends, personalities, devices, or root types
- changes to `third_party/` beyond merging upstream
- changes to this process

It isn't needed for bug fixes, workarounds, performance work that doesn't change behaviour, or internal refactors; their reasoning goes in code comments and commit messages. If in doubt, draft one: a short proposal costs little.

## Writing one

`zig build design -- new <slug>` copies [TEMPLATE.md](TEMPLATE.md) to `design/<slug>.md` with the frontmatter filled in. A slug is lowercase words of letters and digits joined by dashes (`linux-personality`, `9p-roots`), unique, not all digits, and never changed. The file keeps that name for good. Write a line per paragraph.

The sections are Abstract, Background, Proposal, Rationale, Compatibility, Security, Done criteria, Implementation, and Open issues, and, once decided, Updates or Declined. Rationale should cover the alternatives that were rejected, so the question isn't asked again.

A proposal says what changes and why, never what's built so far. "hx64 isn't built yet" in a body goes stale the day hx64 merges. What's built is in `status`, `branch`, the Done criteria checkboxes, and dated Updates notes. A proposal with parts that finish at different times is split into one proposal per part, each with its own Done criteria, and the parts `depends` on each other where they need to.

## Done criteria

Done criteria is a checklist of the demo commands and the cases that prove the proposal. Each top-level item is a checkbox:

- `- [ ]` not done yet
- `- [x]` done
- `- [~]` waived, with the reason after the item: `- [~] The headless cases pass on the web host. Waived: they run on native backends only, and the Chromium cases cover the same paths.`

Items can have notes or sub-items indented under them, and prose between items gives context. Checking or waiving an item is the one edit allowed to an accepted proposal's body. A reason that needs more than a line also gets a dated note under Updates.

`check` fails on an implemented proposal with an unchecked item, and on a top-level item that isn't a checkbox. It warns on a proposed or accepted proposal whose items are all checked or waived, since it's probably implemented.

## Signature

A proposal is signed with a line under its title: `Nov 11, 2026 · Jeff Lindsay, [h.d.a.](README.md#signature)`. h.d.a. means AI-assisted work substantially directed by the named person, who takes responsibility for the result. It's the named person's sign-off: they directed the work, reviewed it closely enough to understand and defend it, and take responsibility for it, however much of it AI wrote. Readers can trust that a person stands behind a signed doc. Older signatures carry the definition in an `<abbr>` tag instead of the link, and both forms are valid.

Only a deliberate act by the named person adds a signature. There are three ways to do it:

- **A PR comment.** `/sign <slug>` on a PR, or `/sign spec` for SPEC.md, makes [design-sign.yml](../.github/workflows/design-sign.yml) add the commenter's signature, dated the day of the comment, on the PR's branch, and reply with the commit. It acts only on PRs from this repository, never on a bot's comment, and only for logins in [SIGNERS](SIGNERS) on main, so a PR can't add its own signer. The doc can be read rendered on GitHub, even from a phone, right before signing it.
- **`zig build design -- sign <slug>`** (or `sign spec`), at a terminal. It takes the name for your `gh` login, or for git's `user.name`, from SIGNERS, shows what you're signing, and asks you to type the slug to confirm you've reviewed it. It runs only when stdin is a terminal. It replaces an older signature of yours with today's date, and refuses if you already signed today.
- **By hand**, typing the line.

A signature is dated, and re-signed with a new date after significant changes. An unsigned draft usually hasn't been fully reviewed or understood by its `authors`, and an unsigned proposal is unlikely to be accepted. Agents never sign, run `sign`, post `/sign`, or edit SIGNERS. `check` doesn't require a signature, but it fails on a signature line in neither form, or one naming someone who isn't in SIGNERS. [SPEC.md](../SPEC.md) is signed the same way, by the person who last reviewed it as a whole.

## States

| Status | Meaning |
| --- | --- |
| `draft` | Being written. No issue is needed. |
| `proposed` | Filed as a GitHub issue to get feedback there. Optional. |
| `accepted` | Decided, and ready for someone to start or finish, but nobody is working on it now. Optional. |
| `implemented` | Built and on main, with every Done criteria item checked or waived, and SPEC.md describing it. |
| `declined` | Decided against; kept, with a Declined section giving the reason, so the reasoning can be found later. |
| `hold` | Paused, with a reason on the issue, or in an Updates note if there's no issue. |
| `superseded` | Replaced by `superseded-by`. |

A draft can become any of the others, and a proposed proposal any but `draft`. `proposed` and `accepted` are both optional: a proposal can go from `draft` straight to `implemented` when the work is done and a person directed it. Feedback on an issue is wanted for some proposals and not others, and `proposed` is where it goes when it's wanted.

Status changes ride in the PR that makes them; they don't need a commit of their own. `zig build design -- log <slug>` shows a proposal's status and branch changes, with their commits, from the history of its frontmatter.

## Branches

`branch` lists the git branches where a proposal's work lives, usually named after its slug: `branch: [hcpu, hx64]`. It's empty until work starts, and allowed in any state, so a spike for a draft is recorded too. The PR that finishes a proposal sets `status: implemented` and `branch: [main]` in its last commit, so the squash merge carries both. `implemented` requires `branch: [main]`, and `main` is allowed only on an implemented proposal.

The tool computes these from the frontmatter and git, and `list`, `ready`, and STATUS.md show them:

- **ready:** accepted, with no branch, and every dependency implemented.
- **in progress:** not implemented, with a branch that has had a commit in the last 7 days.
- **stalled:** not implemented, with a branch that hasn't, or that no longer exists.

Branches are read from `refs/remotes/origin/` and local refs, so fetch them first for an up-to-date answer. `check` warns about a branch it can't find, rather than failing, since a PR's checkout may not have every ref.

## Filing an issue

`zig build design -- propose <slug>` opens the GitHub issue (title `proposal: <title>`, the `Proposal` label, the Abstract, and a link to the file as the body), sets the proposal's `id` to the issue number and its status to `proposed`, and commits. Nothing is renamed. It asks first, as it creates the issue as the account `gh` is logged in as, and it refuses if an open issue already has the same title, so a retried run doesn't open a twin. `--dry-run` shows what it would do, `--yes` skips the question, and `--issue N` uses an issue that already exists, without touching GitHub.

Discussion of a proposed proposal happens on its issue, and the doc is revised in commits. `id` is only the issue's number. Proposals are always referred to by slug: in `depends`, `superseded-by`, test tags, and links.

## Frontmatter

```yaml
---
id: 42
slug: linux-personality
title: Linux personality
status: accepted
created: 2026-11-03
authors: [progrium]
depends: [symlinks-in-root, exit-status]
areas: [kern, vmm, cli, sandbox]
branch: [linux-personality]
superseded-by:
---
```

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | no | The GitHub issue number, once it has one |
| `slug` | always | Its permanent name, and its file's |
| `title` | always | Also the issue title, after `proposal: ` |
| `status` | always | See States |
| `created` | always | `YYYY-MM-DD` |
| `authors` | always | GitHub logins |
| `depends` | always, may be `[]` | Proposals, by slug, that must be implemented before this one can be |
| `areas` | no | Free-form tags for filtering: `vmm`, `kern`, `cli`, `sandbox`, `build`, `tests`, `process`, and so on |
| `branch` | when work has started; `[main]` once implemented | See Branches |
| `superseded-by` | when `superseded` | The proposal that replaces it, by slug |

The syntax is a strict subset of YAML: one `key: value` per line, values are scalars or flow lists (`[a, b]`), with no nesting, quoting, or multi-line values. Since nothing is quoted, a value can't contain `: ` or ` #` or start with a YAML indicator such as `#`, and list items are plain words. Only facts are stored. Whether a proposal is ready, in progress, or stalled, and what it blocks, are computed by the tool. STATUS.md lists proposals in the rough order they were written, by `created` and then `id`.

## After acceptance

An accepted proposal's body isn't edited, except to check off or waive its Done criteria. A discovery during implementation that refines the design gets a dated note under an Updates section at the end; one that changes the design gets a new proposal, which supersedes the old one or is added to its `depends`. A dependency found during implementation is added to `depends` in the same PR, with a line saying so.

The PR that finishes a proposal updates SPEC.md to describe what was built, tags the passing cases, checks off its Done criteria, and sets `status: implemented` and `branch: [main]`. SPEC.md never describes unbuilt features, and proposals aren't updated to describe the current system. SPEC.md links to a proposal only where the proposal gives more information or context, such as the alternatives behind a decision.

## Declining

A declined proposal stays in `design/`, as Go's do, so the next person with the idea finds the answer and the reasoning behind it. To decline one, set `status: declined` and add a Declined section at the end of the doc. The section is dated, says in a few lines why it was declined, and links the issue comment or discussion that decided it, if there is one. It also names what would change the answer, if anything, so a later proposal knows what it has to address. A proposal with an issue has the issue closed as not planned, linking the commit.

The rest of the body isn't edited, as with an accepted proposal. A Declined section looks like this:

```markdown
## Declined

- 2026-11-09: The guest can already do this with `bind`, and a new flag would be one more thing to keep compatible ([discussion](https://github.com/progrium/hyper9/issues/42#issuecomment-1)). A use `bind` can't cover would reopen it.
```

To reconsider a declined proposal, write a new one that links the old one and answers its Declined section, rather than reopening the old one. A draft nobody needs any more can simply be deleted, or, if its reasoning is worth keeping, declined. `check` fails on a declined proposal without a `## Declined` section, and on an accepted proposal that depends on a declined one.

## Tests

Cases are tagged with the proposal they prove, by slug, in brackets at the end of the name: `test "ls /bin | wc -l (demo) [baseline]"`, `test "ramfs posts to /srv [devsrv]"`. Integration cases are in `tests/*.zig`, and web cases in `tests/web/*.mjs` (`await test('name [browser-gfx]', ...)`). An integration case whose proposal isn't implemented skips in `zig build integration`, unless `-Dpending` is given, and stops skipping in the commit that marks the proposal implemented. Untagged cases always run. Write tags as `[a, b]`, with a comma and a space; `check` enforces it, since `zig build proposal` matches them by text.

`zig build proposal -Dp=<slug>` runs one proposal's demos, integration cases, and web test files, whatever its status. Demos that aren't cases are registered for their proposal in `build.zig` (`addDemo`). A web test file runs whole, for any proposal one of its cases is tagged with.

## Checks

`check` is meant to run before every PR is merged, and `status` on main after each merge. Which workflows run them, and how, can change without a proposal.

## The tool

`zig build design -- <command>`, from [tools/design.zig](../tools/design.zig):

| Command | Does |
| --- | --- |
| `list [--status S] [--area A]` | A table of slug, issue, status, the computed state, and title |
| `ready` | Accepted proposals with no branch whose dependencies are all implemented: what can be picked up now |
| `graph` | The dependency graph, as Mermaid |
| `status` | Rewrites [STATUS.md](STATUS.md), the proposal table and graph; run on main, not in PRs |
| `new <slug> [--title T] [--author LOGIN]` | Starts a draft from the template |
| `propose <slug> [--yes] [--dry-run] [--issue N]` | Opens its issue and makes it proposed, as above |
| `log <slug>` | Its status and branch changes, with their commits |
| `sign <slug or spec>` | Signs a doc you've reviewed, as above |
| `check` | Validates the proposals, test tags, signatures, and links to `design/` |

[STATUS.md](STATUS.md) is generated, and only main commits it: [.github/workflows/design-status.yml](../.github/workflows/design-status.yml) runs `status` after each push to main that touches `design/` or the tool, and daily, since in progress and stalled change as branches age. It commits the result if it changed. PRs leave it alone, even when they change a proposal's status or dependencies, so two open PRs never conflict over it. `list` and `ready` give the current state on any branch.

`check` fails on bad frontmatter (including values YAML would read differently and the removed `likely-accept` and `likely-decline`), tags not written as `[a, b]`, a duplicate slug or id, a file not named for its slug, `proposed` without an `id`, a reference by number or one that doesn't resolve (in `depends`, `superseded-by`, or a test tag), a dependency cycle, an implemented proposal with a dependency that isn't, an accepted proposal that depends on a declined one, a declined proposal without a `## Declined` section, `superseded` without `superseded-by`, `implemented` without `branch: [main]` or `main` on anything else, a Done criteria item that isn't a checkbox or is open on an implemented proposal, a `## Done when` heading, a malformed signature or one by someone not in SIGNERS, and a link to a file under `design/` that doesn't exist, from any file git tracks outside `third_party/`.
