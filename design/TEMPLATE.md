---
slug: [slug]
title: [Title]
status: draft
created: [YYYY-MM-DD]
authors: [[login]]
depends: []
areas: []
---

# Proposal: [Title]

[Copy with `zig build design -- new <slug>`, which fills in the frontmatter. The process is in [README.md](README.md). Write a line per paragraph, as DESIGN.md does. Delete these bracketed notes as you go.]

## Abstract

[A short summary of the proposal. Filing copies it into the GitHub issue.]

## Background

[The problem, and what exists today.]

## Proposal

[A precise statement of the change.]

## Rationale

[Alternatives and trade-offs, including the ones rejected, so the question isn't asked again.]

## Compatibility

[Effects on CLI flags and exit codes, `Machine.Options`, sandbox defaults, the root tree and `third_party/`.]

## Security

[What the guest can newly reach, and how the policy covers it. "None" with a reason is fine.]

## Done when

[The demo commands and the integration cases, by name, that prove it. Tag the cases with this proposal: `test "name [slug]"`.]

## Implementation

[The steps, in order.]

## Open issues

[Questions without answers yet. Delete the section if there are none.]
