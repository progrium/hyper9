---
slug: proposal-flow
title: A proposal lifecycle for building first, branches, Done criteria, and easier signing
status: draft
created: 2026-11-11
authors: [progrium]
depends: [proposals]
areas: [process, build, tests]
branch: [claude/project-thread-2k7msi]
---

# Proposal: a proposal lifecycle for building first, branches, Done criteria, and easier signing

Nov 11, 2026 · Jeff Lindsay, [h.d.a.](README.md#signature)

## Abstract

The proposal process from [proposals](proposals.md) assumes a proposal is designed, filed, discussed in a final comment period, and accepted before any work starts. In practice, work often starts on a branch first, and the proposal is written alongside the code or after it. This proposal changes the lifecycle to fit. It drops the final comment period. It adds a `proposed` state for a proposal filed as an issue for feedback, which is optional, as `accepted` is. It adds a `branch` field that says where a proposal's work lives, from which the tool computes in progress and stalled. Files are named by slug alone, and proposals are referred to by slug everywhere. Done when becomes Done criteria, a checklist that `check` holds an implemented proposal to. Signing gets a shorter line, a `/sign` PR comment, and a `sign` command, all of which still need the named person to act.

## Background

The process has been used for 53 proposals in a week. Some parts work well: the dependency graph, `ready`, tags on integration cases, signatures, and STATUS.md regenerated on main. Others don't match how work happens:

- **The final comment period is never used.** No commit has ever set `likely-accept`. A filed proposal usually goes to `accepted` the same day, and only one decline (image-roots) used `likely-decline`. Discussion happens in project threads, not on issues: the 44 Proposal issues have 4 comments between them.
- **Work often comes first.** hcpu's h86 and ha64 were built on the `vcpu` branch, and its proposal "records their design". builtin-root was revised to match what was built, and linux-i386 was implemented before it was filed. remote-net was drafted and implemented the same day, then folded into linux-net's Updates. wine-draw is still a draft with its implementation merged (#129). The process has no state for "being built" and no path from a draft to implemented, so these cases bend the rules, and AGENTS.md's "draft one and stop" is overridden whenever a person directs the work.
- **`draft` means two things.** A draft is either an idea that has never been filed (15 of them) or a filed proposal being discussed (8). The status doesn't say which, and the filename's number is the only way to tell.
- **Nothing says when a proposal falls behind its code.** browser-gfx merged and stayed `accepted`, because one Done when item never ran and nothing flagged it. hcpu said hx64 wasn't built after #168 merged it. Done when is prose, so neither `check` nor a reader can tell which items are done.
- **Renaming on filing breaks links.** A draft is `design/<slug>.md` and a filed one is `design/NNNN-<slug>.md`, so every filing and rename changes a path that code, docs, and other proposals link to. `file` rewrites links in the tree it runs in, but not on branches: wine-draw was filed while its implementation was on a branch, and when #129 merged it brought about 10 links to the old path in `src/wine/`, `build.zig`, `DEVELOPING.md`, and `src/web/`. The h86-ha64 rename left another. It's also why slugs have to start with a letter, and why `fix` exists to rewrite slugs as numbers.
- **One commit per status change doesn't survive squash merges.** PRs are squash-merged, so a status change made in a PR lands in the PR's one commit (#115, #118), and `git log design/` isn't the record of decisions the rule meant it to be.

## Proposal

### States

| Status | Meaning |
| --- | --- |
| `draft` | Being written. No issue is needed. |
| `proposed` | Filed as a GitHub issue to get feedback there. Optional. |
| `accepted` | Decided, and ready for someone to start or finish, but nobody is working on it now. Optional. |
| `implemented` | Built and on main, with every Done criteria item checked or waived, and SPEC.md describing it. |
| `declined` | Decided against, with a Declined section, as now. |
| `hold` | Paused, with a reason, as now. |
| `superseded` | Replaced by `superseded-by`, as now. |

A proposal moves from `draft` to `proposed`, `accepted`, `implemented`, `declined`, or `hold`, and from `proposed` to any of the last four. `likely-accept` and `likely-decline` are removed, along with the limit of three proposals in a final comment period. A proposal can go from `draft` straight to `implemented` when the work is done and a person directed it, as hcpu's first two CPUs were.

`declined` still needs a dated `## Declined` section, and a proposal with an issue has the issue closed as not planned. To reconsider a declined proposal, write a new one, as now.

### Branches

A new frontmatter field, `branch`, is a list of the git branches where the proposal's work lives, usually named after its slug: `branch: [hcpu, hx64]`. It's empty or absent until work starts, and is allowed in any state, so a spike branch for a draft is recorded too. When the work merges, the PR that finishes it sets `status: implemented` and `branch: [main]` in its last commit, so the squash merge carries both. `implemented` requires `branch: [main]`, and `main` is allowed in `branch` only when the proposal is implemented.

The tool computes these from the frontmatter and git, as it computes ready now, and STATUS.md, `list`, and `ready` show them:

- **ready:** `accepted`, every dependency implemented, and no branch.
- **in progress:** not implemented, and a branch whose last commit is recent.
- **stalled:** not implemented, with a branch whose last commit is more than 7 days old, or that no longer exists.

The tool reads branches from `refs/remotes/origin/`, falling back to local refs, so whatever runs `status` needs them fetched. A branch that can't be found is a warning, not an error, since a PR's checkout may not have every ref.

### Names and references

Every proposal's file is `design/<slug>.md`, from its first draft on. Filing no longer renames anything. `depends`, `superseded-by`, test tags, and links all name proposals by slug, and `check` refuses a number in any of them. A slug is lowercase words of letters and digits joined by dashes, and starts with a letter, as now: `new` refuses one that starts with a digit, and `check` fails on one without an issue, while `9p-roots`, which already has one, keeps its slug.

`id` is renamed `issue`, an optional field: the number of the proposal's GitHub issue, when it has one. Since proposals aren't numbered any more, the name says what the number is. STATUS.md and `list` order proposals by `created`, then by `issue`, which gives the rough order the numbered filenames gave.

### Closing issues

A proposal's issue closes when the proposal reaches main as `implemented` (completed), or as `declined` or `superseded` (not planned). `zig build design -- close-issues` closes each such issue that's still open, with a comment linking the doc, and the workflow that regenerates STATUS.md on main runs it after each merge. Today #35 and #120 are implemented and still open.

### Done criteria

The Done when section is renamed Done criteria and written as a checklist. Each item is one of:

- `- [ ]` not done yet
- `- [x]` done
- `- [~]` waived, with the reason after the item: `- [~] The headless cases pass on the web host. Waived: they run on native backends only, and the Chromium cases cover the same paths.`

Prose between items is allowed, for context. Checking or waiving an item is the one edit allowed to an accepted proposal's body. A waived item also gets a dated note under Updates if the reason needs more than a line.

`check` fails on an `implemented` proposal with an unchecked item, and on an item in Done criteria that isn't a checkbox. It warns on a `proposed` or `accepted` proposal whose items are all checked or waived, since it's probably implemented.

### Status claims in the body

A proposal's body says what changes and why, and never what's built so far ("hx64 isn't built yet"). What's built is in `status`, `branch`, the Done criteria checkboxes, and dated Updates notes. A proposal with parts that finish at different times is split into one proposal per part, each with its own Done criteria, and the parts `depends` on each other where they need to.

### The tool

- `new <slug>` is unchanged, except that the template has Done criteria as a checklist.
- `file` is renamed `propose`. It opens the issue, sets `issue`, and sets `status: proposed`, with no rename. `--issue N`, `--dry-run`, and `--yes` stay. Before creating an issue, it looks for an open Proposal issue with the same title, through the REST API, so a retried run doesn't open a duplicate (#78 and #81, #79 and #87, and #80 and #95 are duplicates from re-filing).
- `fix` is removed, since there are no numbers to rewrite.
- `close-issues` closes the issues of proposals that are implemented, declined, or superseded, as above.
- `log <slug>` prints the proposal's status and branch changes, with commits and dates, from the history of its frontmatter. It replaces one commit per status change as the record of decisions, so that rule is dropped.
- `list`, `ready`, and `status` show ready, in progress, and stalled.
- `check` validates `branch`, the Done criteria checklist, slug-only references, and links to `design/*.md` from any tracked file, not just from `design/`. It scans test tags in `tests/*.zig` and `tests/web/*.mjs`, and `zig build proposal -Dp=<slug>` runs the web cases too.

### Signing

A signature still means what README's Signature section says: the named person directed the work, reviewed it closely enough to understand and defend it, and takes responsibility for it. What changes is how the line gets there. Today it's typed by hand, with an `<abbr>` tag, in a local checkout, and "a tool never adds it". That makes signing the slowest step for a doc that's otherwise ready. The rule becomes that only a deliberate act by the named person adds a signature, and there are three ways to do it:

- **A shorter line.** A signature is `Nov 11, 2026 · Jeff Lindsay, [h.d.a.](README.md#signature)`, linking to the definition instead of carrying it in a tooltip. SPEC.md links `design/README.md#signature`. Existing signatures in the `<abbr>` form stay as they are, since a signature is never edited by anyone but the person it names, and both forms are valid.
- **A PR comment.** A comment of `/sign <slug>` on a PR makes a workflow add the signature to that proposal on the PR's branch and commit it, dated the day of the comment, using the name for the commenter's login. `/sign spec` signs SPEC.md the same way. Logins and names come from `design/SIGNERS`, one `login Full Name` per line, and the workflow ignores comments from anyone else and from bots. It replies on the PR with the commit, or with why it didn't sign. GitHub vouches for who wrote the comment, and the doc can be read rendered on GitHub, from a phone, right before signing it.
- **`zig build design -- sign <slug>`**, at a terminal. It adds the line with today's date and the name `design/SIGNERS` gives for the login in `gh` or, failing that, git's `user.name`. It runs only when stdin is a terminal, shows the doc's title and signer, and asks the person to type the slug to confirm they've reviewed it. It refuses a doc already signed today by the same person, and replaces an older signature by the same person with the new date.

Agents never run `sign`, and never post `/sign`, write a signature line, or edit `design/SIGNERS`. AGENTS.md says so. `check` still doesn't enforce signatures, but it does check that a signature line is in one of the two forms and names someone in `design/SIGNERS`, so a typo doesn't pass as a signature.

### Running the checks

README says that `check` is meant to run before every PR is merged, and that `status` runs on main after each merge. It doesn't say which workflow runs them or how, so CI can change without a proposal.

## Rationale

**Keep the final comment period, but make it optional.** A rule that's never followed teaches readers to ignore the rules around it. `proposed` is where feedback goes when it's wanted, and a later proposal can add a waiting period to it if more people start deciding.

**Make `proposed` required.** Then every proposal would need an issue before it could be accepted. Most decisions here are made in conversation and no one comments on the issue, so requiring one adds a step without adding review.

**Add an `in-progress` status instead of `branch`.** A status has to be set and cleared by hand, and it would go stale exactly as `accepted` did on browser-gfx. A branch is a fact the tool can check against git, and in progress and stalled follow from it. It also records where the work is, which a status can't.

**A single `branch` value.** hcpu's work landed from `vcpu`, then from hx64's branch. A list keeps both.

**Leave `branch` empty once implemented, instead of `main`.** `implemented` already implies main, so `main` is redundant. Requiring it keeps the field's meaning the same in every state, so a reader never has to know the rule, and `check` can catch a status and branch that disagree.

**Keep numbered filenames.** They sort in filing order, but that order was rough, and it costs a rename and broken links on every filing, a rule about how slugs start, and a `fix` command. STATUS.md can show the same order without them.

**Keep numbers as references beside slugs.** Two names for one proposal means `check` has to warn about one of them forever. Slugs say what a proposal is about, and they never change.

**Tick Done criteria in a separate list, outside the body.** Keeping the items and their checkboxes together is easier to read, and checking off an item doesn't change the design, which is what the rule against editing an accepted body protects.

**Keep signatures by hand only.** The point of hand-signing is that a person, not an agent, decides a doc is theirs. A PR comment or an interactive command is just as deliberate, and the comment is better evidence of who did it than a line anyone can type. What the rules need to stop is an agent signing, and AGENTS.md, the allowlist, the bot check, and the terminal check cover that.

**Use GitHub's PR approval as the signature.** It's one click, but it approves a whole PR, not one doc, and it isn't in the doc where readers look. It also can't be given by a PR's own author, which is usually the person who'd sign.

**A `Proposal:` trailer on implementation PRs**, so the tool can find drafts that merged code cites. It would catch a draft like wine-draw whose code merged, but `branch` and Done criteria cover most of that, and a trailer is one more thing every PR has to remember.

**Drop the rule that slugs start with a letter**, since nothing sorts by filename any more. It's kept: a slug that starts with a letter reads as a name, and the rule costs nothing.

## Compatibility

The CLI, `Machine.Options`, sandbox defaults, the root tree, and `third_party/` are unaffected. This changes only `design/`, the design tool, test tag text, and links.

The migration is one mechanical change:

- Every `design/NNNN-<slug>.md` is renamed `design/<slug>.md`, `id` becomes `issue`, and the baseline loses `id: 0`.
- Numeric references in `depends`, `superseded-by`, and test tags are rewritten as slugs (`[18]` becomes `[linux-personality]`, and `depends: [13, 21]` becomes `depends: [9p-roots, websocket-9p]`), as are links to the old paths in any tracked file.
- Any proposal at `likely-accept` or `likely-decline` goes back to `draft`. None are today.
- Every filed `draft` becomes `proposed`.
- Done when is renamed Done criteria in every proposal, and its items become checkboxes. For implemented proposals, items are checked. browser-gfx's headless `[gfx]` item is waived with the reason from its Updates note.
- `branch: [main]` is added to every implemented proposal.

Existing issues keep their numbers, and each proposal keeps its number, as `issue`. Old links to `design/NNNN-<slug>.md` from outside the repository break. They can't be redirected from a Markdown repository, but the slug in the old filename finds the file.

## Security

Nothing changes for the guest. The signing workflow writes to PR branches, so it runs only on `issue_comment` events for PRs from this repository, never from forks. It checks the commenter's login against `design/SIGNERS` on main, not on the PR's branch, so a PR can't add its own signer, and its token can write contents only.

## Done criteria

- [x] `zig build design -- check` passes on main after the migration, with no numbered filename, no numeric reference, and no dead link to `design/` from any tracked file.
- [x] `check` fails on each of: `implemented` without `branch: [main]`, `main` in `branch` on a proposal that isn't implemented, an unchecked Done criteria item on an implemented proposal, a Done criteria item that isn't a checkbox, a number in `depends` or a test tag, and a `likely-accept` or `likely-decline` status. Each has a case in `tools/testdata/check/`.
- [x] `check` warns on an accepted proposal whose Done criteria are all checked or waived, and on a branch it can't find.
- [x] `zig build design -- list` shows in progress for a proposal whose branch has a recent commit, and stalled for one whose branch is older than 7 days or gone, with a unit test of each.
- [x] `zig build design -- propose <slug> --dry-run` shows the issue it would open and `status: proposed`, without renaming the file, and refuses when an open issue has the same title.
- [x] `zig build design -- log browser-gfx` prints its status changes with their commits.
- [~] `zig build proposal -Dp=browser-gfx` runs the Chromium cases in `tests/web/gfx.mjs`. Waived: it needs a 386 root to run, and Jeff dropped the item rather than hold the proposal for it.
- [x] `zig build design -- sign proposal-flow` adds a signature in the short form with today's date, refuses when stdin isn't a terminal, and refuses unless the typed slug matches.
- [x] `zig build design -- close-issues --dry-run` lists the open issues of implemented proposals (#35 and #120 today), and `check` fails on the old `id` key and on a slug without an issue that starts with a digit.
- [x] After the merge, design-status closes #35 and #120 with a comment linking each doc.
- [ ] A `/sign <slug>` comment on a PR from a login in `design/SIGNERS` adds the signature on the PR's branch, and the same comment from a login that isn't listed does nothing but reply.
- [x] `check` fails on a signature line in neither form, or naming someone not in `design/SIGNERS`.
- [x] design/README.md, TEMPLATE.md, AGENTS.md, and DEVELOPING.md describe the new states, `branch`, Done criteria, `propose`, and `log`, and nothing describes `likely-accept`, `fix`, or numbered filenames, and README's Signature section describes the short form, `sign`, and `/sign`.

## Implementation

1. Change `tools/frontmatter.zig` and `tools/design.zig`: the new states, `branch`, slug-only references, Done criteria parsing, and the new `check` rules, with their cases in `tools/testdata/check/`.
2. Add the computed in progress and stalled to `list`, `ready`, and `status`, reading branches from git.
3. Rename `file` to `propose`, with the duplicate-issue check. Add `log`, and remove `fix`.
4. Scan `tests/web/*.mjs` for tags, and register the web cases with `zig build proposal`.
5. Write the migration as a one-time script, run it, and commit the result alone, so the mechanical change is reviewable apart from the tool. The script isn't kept, since it has nothing left to do once it has run.
6. Add `design/SIGNERS`, `sign`, and the `/sign` workflow, and the `check` rule for signature lines.
7. Rewrite design/README.md, TEMPLATE.md, and the design parts of AGENTS.md and DEVELOPING.md. AGENTS.md's "draft one and stop" becomes: stop and draft one unless the person you're working for directs the work, in which case the PR adds or updates the proposal, its `branch`, and its Done criteria as it goes. The rule about signature lines also forbids running `sign`, posting `/sign`, and editing `design/SIGNERS`.
8. Add a dated note under the Updates section of [proposals](proposals.md) that points here, and set this proposal to `implemented` with `branch: [main]`.

This proposal is the first to use the new flow: it goes from `draft` to `implemented` in the PR that does the work.

## Open issues

- Should `close-issues` also set each issue's labels from `status`?

## Updates

- 2026-11-11: Merged in #175. design-status's first run on main closed #120 with `close-issues`. #35 had already been closed by GitHub when #175 merged, because the PR's description said it would "close #35", so `close-issues` found it closed and left it alone.
