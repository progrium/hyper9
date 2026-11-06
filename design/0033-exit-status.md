---
id: 33
slug: exit-status
title: Numeric exit statuses at the host boundary
status: draft
created: 2026-11-05
authors: [progrium]
depends: []
areas: [cli]
---

# Proposal: Numeric exit statuses at the host boundary

## Abstract

When the guest's `exits` string is a decimal number from 1 to 255, the h9 CLI exits with that number and doesn't print the string. That's the convention APE and rc already use inside 9front, so `rc -c 'exit 3'`, an APE program's `exit(3)` and, under the [Linux personality](0018-linux-personality.md), a Linux program's `exit(3)` all reach the host as status 3. Any other non-empty string still prints and exits 1. The `Machine` API doesn't change: library callers still get the string.

## Background

A 9front process ends with an `exits` string: empty for success, anything else for failure. The h9 CLI maps that onto a host exit status (DESIGN.md, Exit codes): 0 for an empty string, 1 for any other, with the string printed to stderr. A process killed by a note also exits 1. h9's own failures use 2 (usage), 125, 126 and 127, which follow `env` and `docker run` so that scripts can tell h9's failures from the guest's.

Inside 9front there's already a numeric convention:

- **APE's `_exit(n)`** (`/sys/src/ape/lib/ap/plan9/_exit.c`) writes `n & 0xff` as a decimal `exits` string.
- **APE's `wait`** (`wait.c`, `waitstatus`) reads it back: a decimal string from 0 to 255 is that status, a string that starts with a known note (`interrupt`, `hangup`, `kill`, `sys: write on closed pipe`, … from `signal.c`'s `sigtab`) is death by that signal, and anything else is status 1.
- **rc's `exit 3`** ends with `exits("3")`.

h9 ignores this at the host boundary. Today:

```text
$ h9 --rc 'exit 3'; echo $?
3
1
```

So host scripts and build tools that run an APE port or an rc script under h9 lose the real status, and see a stray number on stderr. The Linux personality makes this much more common: every Linux program reports its status as a number, and its callers depend on it.

## Proposal

The CLI's mapping from a guest's end to a host exit status becomes:

| The first process ended with | Host exit status | Printed to stderr |
| --- | --- | --- |
| `exits(nil)` or `exits("")` | 0 | nothing |
| `exits("N")`, where N is a decimal from 1 to 255 | N | nothing |
| Any other `exits` string | 1 | the string |
| Killed by a note | 1 (see Open issues) | `h9: prog: note`, as today |

"A decimal" means the whole string is one or more ASCII digits with no sign, no leading zeros and no surrounding space, so `"3"` counts and `"03"`, `"+3"` and `"3 "` don't. That's stricter than APE's `strtol`, so that h9 never turns a message that only starts with digits into a status.

`Machine.Status` keeps the string. The mapping is the CLI's, in `src/main.zig`, so embedders choose their own.

The README's and DESIGN.md's exit-code tables gain the new row.

## Rationale

**APE's convention, not a new one.** APE and rc already write decimal statuses, and APE's `wait` already reads them, so the convention is 9front's. h9 only stops discarding it at the edge.

**Strict decimals.** APE accepts anything `strtol` parses to the end, which includes a leading sign and spaces. A 9front program's message is more likely than a status to start with digits by accident, so the stricter rule loses nothing real and avoids surprises.

**Not printing the number.** The printed string exists to explain a failure that has no other channel. A numeric status is the explanation, in the form the caller wants, and a program that exits 3 has usually already printed its own message.

**In the CLI, not `Machine`.** Exit codes are a host-process idea. Library callers already get the string and can apply APE's rules, or their own.

**Its own proposal, not part of the Linux personality.** Nothing in it is Linux-specific, it's useful today for rc and APE, and it changes behaviour for existing 9front users. The personality depends on it, so a Linux program's `exit(n)` reaches the host unchanged.

## Compatibility

- **Exit codes:** a guest that ends with a decimal string from 1 to 255 now exits with that number instead of 1, and the string is no longer printed. Scripts that only test for zero are unaffected. Scripts that test for exactly 1, or read the printed number, change.
- No flags, `Machine.Options` or vendored code change.

## Security

None. The guest already chooses its `exits` string; this only changes which host status it becomes. A guest could already make h9 exit 1; it can now pick any status from 1 to 255, including h9's own (see Open issues), which tells a script nothing it could trust anyway.

## Done when

- `test "rc exit 3 is h9's exit 3, with nothing printed [exit-status]"`
- `test "exits with a word still exits 1 and prints it [exit-status]"`
- `test "exits 03 is not a status: exit 1, printed [exit-status]"`
- `test "exits 256 is not a status: exit 1, printed [exit-status]"`

Demo: `h9 --rc 'exit 3'; echo $?` prints `3`.

## Implementation

1. The mapping in `src/main.zig`, with unit tests for the decimal rule. The cases above.
2. The exit-code tables in README.md and DESIGN.md.

## Open issues

- **Killed processes.** Today a process killed by a note exits 1. Shells report a death by signal N as 128+N, and APE's `sigtab` already maps notes to signals (`interrupt` to `SIGINT`, so 130; `hangup`, 129; `kill`, 137; `sys: write on closed pipe`, 141). Should h9 do the same, so Ctrl-C under h9 looks to the host like Ctrl-C anywhere else? A note that isn't in the table, such as a fault, would need a choice: 1, or a fixed signal such as `SIGSEGV` (139). The Linux personality's `linux: signal N` notes would map to 128+N either way.
- **Collisions with h9's own codes.** A guest that exits `"2"`, `"125"`, `"126"` or `"127"` would be indistinguishable from an h9 usage error or failure, which DESIGN.md currently says scripts can tell apart. `env` and `docker run` accept the same overlap. The alternatives are to pass those statuses through anyway, and weaken that promise to "h9 never uses 1 or 3 to 124 for itself"; or to remap them to 1, which keeps h9's codes unique but hides real statuses, such as a Linux tool's 2 for misuse, which is common.
