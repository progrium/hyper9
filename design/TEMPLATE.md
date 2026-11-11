---
slug: [slug]
title: [Title]
status: draft
created: [YYYY-MM-DD]
authors: [[login]]
depends: []
areas: []
branch: []
---

# Proposal: [Title]

[Copy with `zig build design -- new <slug>`, which fills in the frontmatter. The process is in [README.md](README.md). Write a line per paragraph, as SPEC.md does. Delete these bracketed notes as you go.]

[Sign here once you've reviewed the whole doc and take responsibility for it, by hand, with `zig build design -- sign <slug>`, or with a `/sign <slug>` comment on the PR, as described under Signature in README.md. Agents never sign.]

## Abstract

[A short summary of the proposal. `propose` copies it into the GitHub issue.]

## Background

[The problem, and what exists today.]

## Proposal

[A precise statement of the change. Say what changes, never what's built so far: that's for `status`, `branch`, Done criteria, and Updates.]

## Rationale

[Alternatives and trade-offs, including the ones rejected, so the question isn't asked again.]

## Compatibility

[Effects on CLI flags and exit codes, `Machine.Options`, sandbox defaults, the root tree, and `third_party/`.]

## Security

[What the guest can newly reach, and how the policy covers it. "None" with a reason is fine.]

## Done criteria

[A checklist of the demo commands and the cases, by name, that prove it. Tag the cases with this proposal: `test "name [slug]"`. Check items off as they're done, or waive one with `- [~] the item. Waived: why`.]

- [ ] [An item.]

## Implementation

[The steps, in order.]

## Open issues

[Questions without answers yet. Delete the section if there are none.]
