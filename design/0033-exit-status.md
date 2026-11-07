---
id: 33
slug: exit-status
title: Host exit statuses for processes killed by notes
status: implemented
created: 2026-11-05
authors: [progrium]
depends: []
areas: [cli]
---

# Proposal: Host exit statuses for processes killed by notes

Nov 6, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

When the first process is killed by a note, the h9 CLI exits with a status a host shell would recognise instead of always exiting 1: 128+N for a note APE maps to signal N, so Ctrl-C under h9 exits 130 like Ctrl-C anywhere else; 139 for a fault; 124 for `--timeout`; and 1 for any other note. The `Machine` API doesn't change: library callers still get the note.

## Background

A 9front process ends with an `exits` string, or is killed by a note it didn't handle. The h9 CLI maps that onto a host exit status (DESIGN.md, Exit codes). [go-compat](0007-go-compat.md) already made a decimal `exits` string from 1 to 255 that status, in `cli.exitStatus` in `src/cli.zig`, so `h9 --rc 'exit 3'` exits 3. That's APE's convention: `_exit(n)` writes `n` in decimal, and APE's `wait` reads it back.

A killed process is still a flat 1. `src/main.zig` prints `h9: prog: note` and exits 1 for every `.killed` status, whether the note was `interrupt` from Ctrl-C, `hangup` from SIGTERM, a fault, h9's own `h9: timeout` or `h9: machine stopped`, or an internal failure such as `halted`.

```text
$ h9 --rc 'sleep 100'      # then Ctrl-C
h9: rc: interrupt
$ echo $?
1
```

Host shells report a death by signal N as 128+N, and scripts depend on it: 130 means the user pressed Ctrl-C, 141 a closed pipe, 124 a `timeout`. APE's `wait` already maps notes to signals with `sigtab` in `/sys/src/ape/lib/ap/plan9/signal.c`, so the mapping exists inside 9front. The [Linux personality](0018-linux-personality.md) adds `linux: signal N` notes, and its `wait4` treats a fault note as `SIGSEGV`; the host boundary should agree with both.

## Proposal

The CLI's mapping for a killed first process becomes:

| The first process was killed by | Host exit status | Printed to stderr |
| --- | --- | --- |
| A note APE's `sigtab` maps to signal S, such as `interrupt` (S = SIGINT) | 128 + the host's number for S, so 130 | nothing for `interrupt` and `sys: write on closed pipe`; otherwise `h9: prog: note` |
| `linux: signal N` | 128 + the host's number for Linux signal N | as above, by signal |
| Another fault note (`sys: trap: …`, `sys: fp: …`, `sys: bad address …`) | 139 (`SIGSEGV`) | `h9: prog: note`, as today |
| `h9: timeout` (from `--timeout`) | 124 | `h9: prog: h9: timeout`, as today |
| `h9: machine stopped` (the run was torn down after a host signal) | 128 + that host signal: 130 for a second Ctrl-C, 129 for SIGHUP, 143 for SIGTERM | as today |
| `halted`, `sys: trap: unexpected exit …`, `h9: <error>` | 125 | as today |
| Any other note | 1 | `h9: prog: note`, as today |

Notes match `sigtab` as APE's `wait` matches them, so `sys: trap: …` notes that `sigtab` lists, such as an illegal instruction, take their own signal, and the rest fall to the fault row. The note names are the ones in the pinned 9front's `sigtab`; the implementation checks the table against it.

Signal numbers are the host's, from `std.posix.SIG`, not APE's or Linux's: most agree, but some, such as `SIGBUS`, `SIGUSR1` and `SIGUSR2`, differ between Linux and macOS, and the status should be what a host shell would show for that signal. A Linux signal number is translated by name, and one with no host equivalent exits 1. Windows hosts use the Linux numbers, which is what Git Bash and MSYS expect.

The mapping sits beside `exitStatus` in `src/cli.zig`. To tell a teardown by SIGHUP or SIGTERM from one by Ctrl-C, the CLI records which host signal started it in `src/hostsig.zig`; `Machine.Status` doesn't change.

The DESIGN.md and README exit-code tables gain 124 and the killed rows, and DESIGN.md's Signals and TTY section says what each host signal exits with.

## Rationale

**128+N, as shells and `docker run` do.** A script that wraps h9 should see the same status as when it wraps the program directly. Ctrl-C exiting 1 looks like an ordinary failure, so a build loop carries on past it.

**APE's `sigtab`, not a new table.** APE's `wait` already decides which notes are which signals, so an APE parent inside the guest and a host parent outside agree.

**Host signal numbers.** The status is read by a host shell, which decodes it with the host's numbers. Using APE's or Linux's numbers on macOS would make `kill -l $((status-128))` name the wrong signal.

**Faults as `SIGSEGV`.** A 9front fault note doesn't say which Unix signal it would be, and 139 is what a crashed program usually reports. It matches the Linux personality's `wait4`. The alternative, 1, makes a crash look like an ordinary failure.

**Unknown notes stay 1.** A note that isn't a signal is a message, as an `exits` string is, so it gets the same status as an `exits` string that isn't a number.

**124 for `--timeout`.** That's coreutils `timeout`, and it says something more specific than SIGHUP's 129, which is what the `hangup` note `--timeout` posts would otherwise give. It's h9's first own code below 125; DESIGN.md's table lists it.

**125 for h9's own failures mid-run.** `halted`, an unexpected VM exit and an internal error are h9 or hypervisor failures, not the guest's, and 125 already means "h9 itself failed".

**Not printing for `interrupt` and closed pipes.** Shells are silent for both: the user knows they pressed Ctrl-C, and `h9 cat big | head` shouldn't print noise. Other signals still print, as shells print `Killed` or `Hangup`.

**Exiting, not re-raising.** h9 could kill itself with the signal so its parent sees `WIFSIGNALED`, which is more exact: bash stops a loop when a child dies of SIGINT, but not when it exits 130. But it doesn't exist on Windows, would have to reset the handler and raw mode first, and `docker run` exits 130 too. A later proposal can add it.

**Collisions with h9's own codes.** A guest can exit 2, 124, 125, 126 or 127 itself, as with `env` or `docker run`. That's already the documented rule (DESIGN.md, Exit codes; [go-compat](0007-go-compat.md)): h9 prints a message whenever it fails itself, and a numeric `exits` prints nothing, so scripts can still tell them apart. Remapping those statuses to 1 would hide real ones, such as `grep` or `diff` exiting 2. 124 keeps the same rule, because `--timeout` prints `h9: prog: h9: timeout`.

**In the CLI, not `Machine`.** Exit codes are a host-process idea. Library callers already get the note and can apply their own rules.

## Compatibility

- **Exit codes:** a killed program now exits 124, 125 or 128+N instead of 1, and Ctrl-C and closed pipes no longer print. Scripts that only test for zero are unaffected. Scripts that test for exactly 1 after a kill or a timeout change.
- A serve-only run ended by a note still exits 0 ([serve](0035-serve.md)).
- No flags, `Machine.Options` or vendored code change.

## Security

None. The guest could already pick any status from 1 to 255 with a numeric `exits` string; this only changes how notes, which the guest or the host sends, become a status.

## Done when

- `test "a program killed by interrupt exits 130, with nothing printed [exit-status]"`
- `test "a program killed by hangup exits 129 and prints the note [exit-status]"`
- `test "a fault exits 139 and prints the note [exit-status]"`
- `test "--timeout exits 124 [exit-status]"`
- `test "a note that isn't a signal exits 1 and prints it [exit-status]"`

Demo: `h9 --rc 'sleep 100'`, press Ctrl-C, then `echo $?` prints `130`.

## Implementation

1. The note mapping in `src/cli.zig`, beside `exitStatus`, with unit tests for each row, checked against the pinned `sigtab`.
2. Record the host signal that started a teardown in `src/hostsig.zig`, and use the mapping in `src/main.zig`'s `.killed` branch.
3. The cases above.
4. The exit-code tables in README.md and DESIGN.md, and DESIGN.md's Signals and TTY section.

## Open issues

- **`h9: machine stopped` after `--timeout`.** If a timed-out program ignores `hangup` and the machine is torn down, `Machine` reports `h9: timeout`, so it exits 124. That seems right; check that no path reports `machine stopped` instead.

## Updates

- 2026-11-07: Implemented. Choices made where this doc was open or silent:
  - `h9: machine stopped` with no host signal behind it (an embedder's own stop) exits 125, as h9's own failure.
  - On Windows, closing the console counts as SIGHUP and logoff or shutdown as SIGTERM. When several host signals arrive, the first one to start a teardown names it.
  - SIGTERM gets its own event in `src/hostsig.zig`'s self-pipe, so it can be told from SIGHUP.
  - `Killed`, from `/proc/n/ctl kill`, isn't in `sigtab` (which matches case-sensitively), so it exits 1, as APE's `wait` would decide.
  - The open issue holds: `Machine.run` reports `h9: timeout` on every teardown path of a run that timed out, and the `--timeout exits 124` case uses an rc that ignores the hangup to cover the teardown path.
  - An extra case, `a run torn down after SIGTERM exits 143`, covers the host-signal record.
