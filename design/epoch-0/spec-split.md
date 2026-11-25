---
slug: spec-split
title: Splitting SPEC.md into files under spec/
status: implemented
created: 2026-11-21
authors: [progrium]
depends: [proposal-flow]
areas: [process]
branch: [main]
---

# Proposal: Splitting SPEC.md into files under spec/

Nov 21, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

SPEC.md becomes the overview of the spec: the goals, the decisions table, the architecture, and an index. Everything else moves, with its wording unchanged, into ten files under `spec/`, one per part of h9, beside the four that already describe h9's own CPUs. "The spec" in the process now means SPEC.md and those files, and the PR that finishes a proposal updates the file that covers what it built.

## Background

SPEC.md describes h9 as built, and every finishing PR adds to it ([proposals](proposals.md), [proposal-flow](proposal-flow.md)). It had grown to about 1,400 lines and 24,000 words in one file.

- **It's too long to read in one pass.** A person changing the CLI reads past the hypervisors, the Linux personality, and the kernel to get there, and a coding agent's file read stops short of the end.
- **Every finishing PR edits the same file.** Two open PRs that touch different parts of h9 still conflict in it.
- **Signing means re-reading all of it.** SPEC.md is signed by the person who last reviewed it as a whole, so a change to one section asks for a review of every section.
- **`spec/` already exists.** [hcpu](hcpu.md) put the CPUs' descriptions in `spec/jit.md`, `spec/h86.md`, `spec/hx64.md`, and `spec/ha64.md`, since they would have doubled SPEC.md.

## Proposal

### The files

| File | Sections of SPEC.md it takes |
| --- | --- |
| `SPEC.md` | Overview, Decisions, Architecture, and Sources, with a new index of the files below |
| `spec/engines.md` | Hypervisor layer (`vmm`), Native backend (`native`), Emulator backend (`emu`), and the shims from Guest shims and ABI |
| `spec/kernel.md` | Process model, and Kernel: drawterm `kern/` and the Zig seam |
| `spec/abi-plan9.md` | Binary ABI, a.out loading, and Syscall table from Guest shims and ABI, and Go programs |
| `spec/abi-linux.md` | Linux personality |
| `spec/ninep.md` | Root filesystem and 9P dialects from Filesystem, boot, and I/O, and Serving |
| `spec/machine.md` | Slim roots, Boot sequence, Terminal, and Graphics from Filesystem, boot, and I/O |
| `spec/sandbox.md` | The security stance and Sandbox policy from Security, debugging, and testing |
| `spec/cli.md` | CLI |
| `spec/host-js.md` | Browser host (`web`) |
| `spec/testing.md` | Debugging, and Testing and CI, from Security, debugging, and testing |

The four CPU files stay as they are.

### What a spec file looks like

Each file follows the CPU files: a title, one paragraph saying what it describes and linking back to SPEC.md, a contents list, and then its sections. Like SPEC.md, it describes only what's built, with a line per paragraph.

### What moves and what changes

The split moves text and doesn't reword it. The only changes are these:

- **Three headings go away.** "Guest shims and ABI", "Filesystem, boot, and I/O", and "Security, debugging, and testing" each held parts that now live in two files. Their subsections move up a heading level in the new files, the shims get a "Guest shims" heading in `spec/engines.md`, and the security stance paragraph gets a "Security stance" heading in `spec/sandbox.md`.
- **One paragraph changes sections.** The note crediting hyper-linux's shim sat at the end of Syscall table, and goes with the shims.
- **Relative links are rewritten** for the files' new place, and links between sections that are now in different files name the file.

### SPEC.md's index

SPEC.md lists every spec file and what it describes. It also keeps a table from each section it had before the split to the file that section is in now, because proposals, comments in the source, and other docs name those sections ("SPEC.md, Emulator backend"), and an accepted proposal's body isn't edited.

### The process

- **"The spec" is SPEC.md and the files under `spec/` that it lists.** `design/README.md` and `AGENTS.md` say so wherever they said SPEC.md.
- **A finishing PR updates the file that covers what it built,** and SPEC.md itself only for the overview and the decisions table.
- **A new spec file is added to SPEC.md's index** in the PR that adds it.

## Rationale

- **By part of h9, not by proposal.** A file per proposal would repeat `design/`, and the spec describes the system as it is, not how it got there.
- **File names for where the code is going.** `engines`, `abi-plan9`, `abi-linux`, and `host-js` use the names a later proposal will bring to the source tree, so the files aren't renamed again. The sections inside keep today's names (`vmm`, personality, browser host) until the code changes.
- **No rewording in the same change.** A move can be checked mechanically, by diffing the moved text, and a reworded move can't. Sentences that say "see Process model" for a section now in another file are left as they are, and can become links later.
- **SPEC.md stays.** Dozens of proposals, the README, the manual, and the site link to it, and a spec needs a front door. Moving the overview to `spec/README.md` would break those for no gain.
- **Comments in the source aren't changed here.** About 30 comments name a section as `SPEC.md, "Process model"`. The index resolves them, and changing them would touch files that open branches are editing.

## Compatibility

None for h9 itself: no code, flag, or behaviour changes. Links to `SPEC.md` still work. A link to an anchor of a moved section (`SPEC.md#linux-personality`) lands at the top of SPEC.md, whose index says where the section is; the two such links in the tree are updated.

Open branches that add to a moved section of SPEC.md conflict when they rebase, and resolve by putting their text in the new file.

## Security

None. Only documents change.

## Done criteria

- [x] Every line of the old SPEC.md is in the new SPEC.md or in exactly one file under `spec/`, apart from the old contents list and the three headings above.
- [x] Every relative link in the new files resolves.
- [x] `zig build design -- check` passes.
- [x] `design/README.md` and `AGENTS.md` describe the spec as SPEC.md plus `spec/`.

## Implementation

1. Split SPEC.md with a script, by heading, so the moved text is byte for byte the old text, and check that every line was placed.
2. Write SPEC.md's index and the table of old sections.
3. Update `design/README.md`, `AGENTS.md`, and the links in `docs/` and `site/` that named a moved section.

## Open issues

- **Signing spec files.** `zig build design -- sign spec` and `/sign spec` sign SPEC.md only, and `check` validates only its signature line. Signing each file under `spec/` separately, so a change to one asks for a review of one, needs the tool to take a file name.
- **Checking that a finishing PR touched the spec.** A proposal's `areas` could map to spec files, so `check` could tell when an implemented proposal's PR left the spec alone.
