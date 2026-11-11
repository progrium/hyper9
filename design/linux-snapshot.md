---
slug: linux-snapshot
title: Snapshot and restore a Linux process tree
status: draft
created: 2026-11-11
authors: [progrium]
depends: [18, 49, 12, 19]
areas: [linux, kern, web, cli]
---

# Proposal: Snapshot and restore a Linux process tree

## Abstract

Claude Code takes about 136 s to reach its first prompt in Chromium, against 15 s natively, and almost all of it is Bun and Claude Code's own startup run on ha64 in wasm. This proposal lets h9 stop a Linux thread group once it has drawn its first screen and gone idle, write its state (memory, registers, threads, file descriptors, kernel objects, and the files it wrote) to an image, and start a new machine from that image instead of from `execve`. An image made natively with `--backend emu` on ha64 restores in the browser host, where measurements below put the time to the prompt at roughly 5 to 10 s, well under the 70 s target. It's a research draft: it records what was measured, the design, the hard parts, and the cost, so the idea can be judged before anyone builds it.

## Background

The [browser host](0012-browser-host.md) runs arm64 Linux binaries on ha64 ([zig-interpreter](0019-zig-interpreter.md)), with T1 compiling hot blocks to wasm. Claude Code 2.1.311 (a 286 MB Bun executable) reaches its "Not logged in" screen in 136 s there, with `--memory 1G` and one CPU, against 15 s natively on ha64 (36 s with `--cpus 1`).

Measured on the fastclaude branch (f83dded) with the boot harness in `/mnt/project-files/fastclaude-harness/` and a timestamped `--trace` (the scripts are in `/mnt/project-files/fastclaude-snapshot/`). Tracing slows the browser run to 175 s; the shares below are of that run.

| Point in the boot | Native, ha64 (s) | Chromium, traced (s) | Share of the browser boot |
| --- | --- | --- | --- |
| First Linux syscall (h9 and the ELF loaded) | 0.9 | 1.6 | 1% |
| First look at `~/.claude` (the end of the part that doesn't depend on the user's files) | 5.5 | 17.2 | 10% |
| Config, managed settings, git, and credentials probes | 5.5 to 9.5 | 17 to 75 | 33% |
| Until the leader starts a ripgrep child (`clone(CLONE_VFORK)`, then `execve` of the same binary) | 16.5 | 173.0 | 89% |
| The "Not logged in" screen | 17.0 | 175.3 | 100% |

So the part of startup that's the same for every user is only the first 10% in the browser: Bun's own start, loading its module graph, and evaluating the bundle's top level. The rest is Claude Code's main path, which reads files, but in the browser product those files are the shipped root archive (`cc.h9a`), the fixed `.claude.json`, and an empty working directory, the same for every visitor.

The state at the prompt, from the same traces:

- One thread group: the leader and 7 other threads in the browser (19 clones natively, where JSC sizes its pools by CPU count), each blocked in `futex`, `epoll_pwait`, or a `clock_gettime` loop. The ripgrep child exits within about a second.
- File descriptors: the console (0, 1, 2, and dups of 1 and 2), two epoll instances, two or three eventfds, an `AF_UNIX` listener bound in the file system, and a few regular files.
- The console in raw mode, with the TUI's mode-setting escapes (bracketed paste, focus events, hidden cursor) already written.
- Files written during boot: `.claude.json` rewritten by rename, and directories made under `~/.claude`.
- Memory: the guest arena holds 660 MiB of resident pages. 540 MiB of them are byte-for-byte pages of the `claude` executable (its segments, and a second copy, likely Bun reading its embedded module graph); 99 MiB are other data, which compress to 15 MiB with zstd at level 12 (11 MiB with xz, 18 MiB with gzip). h9's own memory (decode caches and T1 code), about 270 MiB natively, isn't part of the guest's state.
- Randomness: BoringSSL's fork-detection probe (`madvise(..., -1)`) succeeds on h9, so BoringSSL treats fork detection as unavailable and takes fresh `getrandom` bytes for each `RAND_bytes`; JSC's `Math.random` seed, any UUID entropy Bun buffers, and Claude Code's session id are made once at startup.

### Prior art

- [CRIU](https://criu.org/) checkpoints Linux processes from outside, with a parasite in the target: it dumps VMAs and pages, reopens files by path at restore, rewinds interrupted syscalls so they restart, sets pids with `clone3`'s `set_tid`, and keeps `CLOCK_MONOTONIC` continuous with time namespaces. h9 is the kernel here, so it needs no parasite, and the same choices apply.
- [gVisor's checkpoint and restore](https://gvisor.dev/docs/user_guide/checkpoint_restore/) is the closest relative: a user-space kernel that serializes its own objects (generated savers for every struct) and reopens host files at restore. [Modal snapshots gVisor sandboxes](https://modal.com/blog/mem-snapshots) after imports to cut cold starts, the same trade as here.
- [Firecracker snapshots and Lambda SnapStart](https://docs.aws.amazon.com/lambda/latest/dg/microvms-images-snapshots.html) restore whole microVMs, mapping memory lazily. Their lesson is uniqueness: state made before the snapshot (seeds, ids, and connections) is shared by every restore ([Restoring Uniqueness in MicroVM Snapshots](https://arxiv.org/abs/2102.12892)); Linux's vmgenid and BoringSSL's [fork detection](https://boringssl.googlesource.com/boringssl/+/main/crypto/rand/fork_detect.cc) exist for it.
- v86 saves and restores its whole emulated machine, which its demos use to start Linux in the browser in seconds. Wizer snapshots a wasm instance's memory after an init function, but only when no stack is live.

## Proposal

Add a Linux process snapshot to the Linux personality ([linux-personality](0018-linux-personality.md)), at the level of h9's own objects, in a format that doesn't depend on the host, so one made natively restores on the web.

### Making an image

`h9 --snapshot=FILE [--snapshot-when=idle] ... prog args` runs the program as usual and, when the condition holds, stops the thread group, writes the image, and exits (or continues with `--snapshot-continue`, for checking).

The default condition, `idle`, is the natural one for a TUI: the group has written to the console, has no children, and every thread has been blocked in a wait the snapshot can restart (`futex` wait, `epoll_pwait`, `poll`, `ppoll`, `select`, `clock_nanosleep`, `nanosleep`, or a console `read`) for 500 ms. A guest that never settles fails the snapshot after a timeout with what each thread was doing.

The quiesce reuses the `/proc/n/ctl` `stop` path and the restart record each Linux process already keeps (`Process.restart`): each blocked thread is woken with an internal interrupt that isn't a signal, its call unwinds as `EINTR` would, and the snapshot rewinds its PC to the `svc` and restores `x0`, so the restored thread makes the same call again. A timed wait restarts with the time it had left; a spurious wakeup is allowed by every one of these calls.

The image is a small header and a list of typed records, versioned, with the pages compressed:

- **Header.** The image version, h9's build id, the architecture, `--cpus`, `--memory`, the hwcaps, the argv and environment, the terminal size, `CLOCK_MONOTONIC` and `CLOCK_REALTIME` at the snapshot, and the next pid.
- **Read set.** Every path the group opened, stat'ed, or listed during the boot, with what it found (a hash of the contents, or "absent"). A restore checks it against the machine's roots and refuses on any difference, so a changed root, a logged-in user, or a mounted working directory falls back to a cold boot instead of resuming a process that read something else.
- **File system delta.** The files, directories, symlinks, and removals the group made in the root's overlay ([ephemeral-writes](0006-ephemeral-writes.md)) and in `/tmp`.
- **Memory.** The Mm's VMAs (`mm.Vma`, with the kind, protection, name, offset, and file of each), the brk, and every resident page as one of: zero, a reference to a page of a file in the read set (path and offset, which covers the 540 MiB of the executable's pages), or data. Data pages are compressed with zstd.
- **Threads.** For each: the pid, the ha64 registers (`Cpu`: X0 to X30, SP, PC, NZCV, FPCR, FPSR, V0 to V31, TPIDR, and TPIDRRO, with the exclusive monitor cleared), the signal mask, pending signals, alternate stack, `clear_child_tid`, the robust list, and the restart record.
- **The group.** The tgid, pgid, and sid, the credentials and umask, the signal actions, rlimits, itimers, the cwd, and `/proc/self/exe`.
- **File descriptors.** By number, with their flags and offsets: the console, files by Linux path, `/dev` files, eventfds (count and flags), epoll instances (each interest's fd, events, and data), signalfds, `AF_UNIX` listeners (the bound path and backlog), and pipes and socketpairs whose both ends are in the group (with their buffered bytes). Anything else, such as a TCP socket, a directory being read, or a pipe to a process outside the group, fails the snapshot with the fd's name.
- **The console.** termios, raw mode, and the bytes written to the console since the start, which are the TUI's screen.

### Restoring

`Machine` gains a restore entry beside `run`: `h9 --restore=FILE` natively, and `machine.restore(url)` in `h9-web.js`. It boots the kernel and the roots as usual, checks the header against the machine (architecture, `--cpus`, `--memory`, and the hwcaps must match) and the read set against the roots, applies the file system delta to the overlay, and then builds the group:

1. Kernel processes with the image's pids (`h9_kern_spawn` with a pid to use, and the counter set past the image's next pid), the group, credentials, and signal state.
2. The Mm: VMAs as recorded, data pages copied into chunks, and file pages filled lazily from the root by the existing `Vma.src` path, so only the pages touched after the restore are read.
3. The fds, opened at their numbers: files by path through the Linux view, then the kernel objects (`#ε` instances, epoll interest lists, and the `AF_UNIX` listener posted in `#s` again with its kproc).
4. termios, and the console's recorded output written to the new terminal, so the screen is up before any guest code runs.
5. A per-machine offset that makes `CLOCK_MONOTONIC`, `CLOCK_BOOTTIME`, and ha64's `CNTVCT_EL0` (its `Clock.now` hook) carry on from the snapshot's values; `CLOCK_REALTIME` is the host's, as after a suspend.
6. Each thread's vCPU, started at its rewound PC. If the terminal size differs from the header's, the group gets `SIGWINCH`.

T1 starts empty, so the first keystrokes run on T0 until their blocks are hot. Shipping compiled regions with the image (ideas 7 and 8 of the speed-up list) is separate work that this makes more useful.

### Where images are made

The image is made natively with `--backend emu` (ha64), `--cpus 1`, `--memory 1G`, and the browser page's environment and terminal size, from the same root as `cc.h9a`. ha64 is the same CPU on both hosts, so the ID registers, `AT_HWCAP`, and everything JSC detects from them match; `--cpus 1` matches the thread counts and the affinity masks JSC and Bun record. `h9-node` can make the same image in wasm for a check that nothing native leaked in. A make step builds `cc.snap` beside `cc.h9a`.

## Rationale

**Snapshotting the whole wasm instance instead.** Copying h9.wasm's linear memory would be simplest, but every kernel process, h9 thread, and guest vCPU is a coroutine with a suspended JSPI stack, and V8 can't save one. Rebuilding them means restarting each from a known state anyway, which is this proposal without the portability. An Asyncify build would make stacks saveable, at a cost to every park and to code size, and was replaced by JSPI for that reason.

**Snapshotting earlier, before the user's files are read.** That image would be valid for any user state, but in the browser that point is 17 s into 175 s, so it saves about 10%: roughly 136 s becomes 120 s. The late image is valid for the shipped state, which is what every first visit has, and the read set makes the difference safe rather than assumed.

**Snapshotting just before the first frame** (the ripgrep spawn, 2.4 s before the prompt in the traced run) instead of at idle. It leaves the first render to run after the restore on a cold T1, which could take from a few seconds to over 20 (T0 in wasm runs about 7 times slower than natively); `idle` costs nothing more to make and leaves no work before the prompt.

**Using CRIU.** CRIU checkpoints host processes, and a guest here is h9's state, not a host process. Its decisions (restart interrupted calls, reopen files by path, fix pids, offset the clocks, and refuse what it can't save) are kept.

### Expected time to the prompt

| Step | Estimate |
| --- | --- |
| Page load, h9.wasm compile, kernel boot (the cold run's first syscall is at 1.6 s, which includes the ELF load) | 1 to 2 s |
| Fetch the image (15 MiB with zstd; served locally or from a CDN) | 0.1 to 2 s |
| Decompress and copy 99 MiB of data pages; map the rest lazily | under 1 s |
| Rebuild the group, replay the screen | under 0.5 s |
| Total to the drawn prompt | about 3 to 6 s; call it under 10 s |

The cost moves to the first interaction, which runs on a cold T1; that's unmeasured and the first thing a prototype should time. Even the before-the-first-frame variant should land well under 70 s.

## Compatibility

New CLI flags (`--snapshot`, `--snapshot-when`, `--snapshot-continue`, and `--restore`) and a `Machine` restore entry; nothing changes for runs without them. `h9-web.js` gains `machine.restore`. No change to `third_party/`.

An image is tied to h9's image version and to the read set, so a new h9 or Claude Code release means a new image; a mismatch is a clean refusal, and the page falls back to a cold boot.

## Security

An image is the process's memory, so it holds whatever the process held: images must be made from a clean root with no credentials, and the maker refuses if the read set includes `~/.claude/.credentials.json` or the environment has an API key.

Every restore of one image starts with the same memory. Crypto is fresh on h9 today, since BoringSSL takes new entropy per call, but JSC's `Math.random` state, any UUID entropy Bun buffers, and Claude Code's session id repeat across restores. If h9 implements `MADV_WIPEONFORK` (and fails `madvise` with unknown advice, as Linux does), a restore must wipe those pages as a fork would, or BoringSSL would then repeat its stream too. The session id repeating is a correctness issue for telemetry and session files, not a secret; whether that's acceptable, or needs a fresh id after restore from Claude Code, is an open issue.

A restore parses an image the page fetched, so the parser must treat it as untrusted, like a root archive. An image controls only the guest's memory, registers, and objects the guest could have made itself, and the policy applies to everything it reopens.

## Done when

- `h9 --snapshot=t.snap fixture` then `h9 --restore=t.snap` runs a fixture that starts threads, blocks in `futex`, `epoll_pwait`, and `nanosleep`, holds an eventfd, an epoll set, a pipe, and an `AF_UNIX` listener, and prints the same results as an uninterrupted run (`test "snapshot and restore a thread group [linux-snapshot]"`).
- A restore with a changed file in the read set is refused (`test "snapshot read set [linux-snapshot]"`).
- `CLOCK_MONOTONIC` doesn't go back or jump across a restore (`test "snapshot clocks [linux-snapshot]"`).
- An image made natively restores under `h9-node`.
- In Chromium, `cc.html?restore=cc.snap` shows "Not logged in" in under 10 s, and the login menu answers keys.

## Implementation

1. Quiesce: stop a group at idle, with each blocked thread rewound to restart its call. Test it by stopping and resuming in place.
2. The image writer and a restore in the same native process, for the fixture.
3. The read set and the file system delta.
4. Restore into a fresh machine natively (`--restore`), with pids, the clock offset, and the console replay.
5. The web host's `restore`, and the `cc.snap` build step.
6. Claude Code end to end, then the first-keystroke timing.

A rough cost is four to five weeks of focused work for v1, which saves only what the fixture and Claude Code use and refuses the rest: about a week for the quiesce and memory, a week for threads, signals, and fds, a week for the read set, the overlay, pids, clocks, and the console, and one or two for the web host and testing. Step 2 alone, in about a week, would show whether Claude Code survives a restore at all.

## Open issues

- Is a repeated session id, `Math.random` seed, and Bun UUID buffer acceptable for the browser demo, or does it need a fresh-id hook in Claude Code?
- How slow are the first keystrokes on a cold T1, and does shipping compiled regions with the image pay for itself?
- Should the page keep a returning user's `~/.claude` (in IndexedDB, say)? Then their read set differs and they'd cold-boot, unless the snapshot moves earlier for them.
- Should `idle` be the only condition, or should there be a syscall-pattern trigger for programs that never settle?
