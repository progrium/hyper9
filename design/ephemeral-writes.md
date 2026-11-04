---
slug: ephemeral-writes
title: Ephemeral writes and a private /tmp
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [sandbox, cli]
---

# Proposal: ephemeral writes and a private /tmp

## Abstract

Enforce `--write=ephemeral` with a ramfs union-bound over the writable paths, so new files vanish on exit, and give each machine a private ramfs `/tmp` instead of the host's temp directory.

## Background

This was part of milestone M5 ("servers") in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). The design text below is as it stood there. Rationale, Compatibility, Security and Implementation are to be written before filing.

Today `--write=ephemeral` is accepted but not enforced: writes are denied, the plan lists it as `unenforced`, and `--strict` refuses it. `/tmp` is the host's temp directory, read-write, in the default profile, and not writable in the tight profile.

From DESIGN.md's capability table:

| Capability | Mechanism |
| --- | --- |
| `fs.write.ephemeral` | A ramfs union-bound with `bind -c` over writable paths; new files go to the ramfs and vanish on exit |

```sh
h9 --write=ephemeral --rc 'mk clean && mk && ./6.out'      # writes vanish
```

## Done when

- Under `--write=ephemeral`, a file written in the cwd is readable inside the run and absent on the host afterwards.
- `/tmp` is private to the machine in both profiles, and writable in the tight one.

## Open issues

- Whether the ramfs is a guest ramfs process or a kernel device. A guest ramfs mounts through a pipe and needs no devsrv; a device avoids a process per machine.
