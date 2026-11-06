---
id: 32
slug: guest-tools
title: h9's own commands in the guest
status: draft
created: 2026-11-06
authors: [progrium]
depends: []
areas: [kern, sandbox, build]
---

# Proposal: h9's own commands in the guest

Nov 6, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

h9 builds a small read-only tree of its own scripts into its binary and serves it to the guest through a new device, `#H`. The namespace builder binds it after `/bin`, so commands such as [websocket-9p](0021-websocket-9p.md)'s `wsmount` and [dotl](0022-dotl.md)'s `dotlfs` are on the guest's path, and anything the root provides with the same name wins. The plan shows the bind, and `--no-guest-tools` leaves it out. The root tree itself stays exactly as fetched.

## Background

- **The root is 9front's, as is.** h9 binds a host tree, or with [9p-roots](0013-9p-roots.md) a server's, as the guest's `/`, and adds devices and binds over it. It never writes files into the root, and a 9P root or image root can't be written anyway.
- **Proposals are starting to need commands.** websocket-9p's `wsmount` wraps `/net/ws` and `mount`. dotl's `dotlfs` wraps `#ℓ`. Each is a few lines of rc that exist only because of an h9 device, so 9front won't have them. Both drafts left "how is it shipped" open, and so would the next one.
- **`/bin` is a union.** The plan binds `/$cputype/bin` at `/bin` and then `/rc/bin` after it (`src/policy.zig`), as 9front's namespace does.
- **drawterm's devroot** keeps static files in tables compiled into the kernel (`addbootfile` puts them in `#/boot`), which shows the pattern, but its tables are fixed-size, and `#/` is the guest's root device for other purposes.

## Proposal

### The tree

`src/guest/` in the repository holds the files, laid out as they appear to the guest:

```text
src/guest/
  bin/
    wsmount     # from websocket-9p
    dotlfs      # from dotl
```

The build embeds the tree in the h9 binary as a generated Zig table of paths, modes and contents. A file's mode comes from its repository mode: executable files are 0555, others 0444. Directories are 0555.

Only rc scripts and data are allowed. Binaries are per architecture, would need building for each root, and would make h9 a distributor of 9front programs, so they aren't in scope (Rationale). The build fails on a file in `src/guest/` that doesn't start with `#!/bin/rc` and is executable.

Each proposal that adds a command lists it in its Implementation and Done when, and adds the file here. This proposal adds none of its own. The tree starts empty and `#H/bin` is an empty directory until websocket-9p or dotl lands.

### `#H`

`src/kern/devhtools.c` serves the table read-only:

- Attach takes no spec. Walks, `stat` and reads come from the table through one leaf, `h9_tools_table`, which returns the table's address and length once at reset. After that the device is plain C over constant memory, so it never calls into Zig on a guest thread.
- Every write, create, remove and `wstat` fails with "permission denied".
- Files are owned by the machine's user, with qids fixed at build time, so `ls -l` and caches see the same file on every run of one h9 version.

The device character is `H`, for h9.

### The bind

The plan adds one bind, after `/rc/bin`:

```text
  bind -a '#H/bin' /bin                                   # h9's commands
```

It's in both profiles, and on every host, including the browser host. It's after the root's directories, so a root that has its own `wsmount` keeps it, and a user's `bind -b $home/bin/rc /bin` in their profile goes in front as usual.

| Flag | Meaning |
| --- | --- |
| `--no-guest-tools` | Leaves out the bind and masks `#H` |

`Machine.Options` gains `guest_tools: bool = true`.

## Rationale

**A device, not files in the root.** h9 takes the root as given and can't write a 9P or image root at all. Writing into a host root would change the user's files. A device bound in is how h9 adds everything else, and the plan shows it.

**Embedded, not a host directory.** A host directory beside the binary would have to be found, kept in step with the binary's version, and allowed through the sandbox. Embedding means the commands always match the devices they wrap, and h9 stays one file.

**After `/bin`, not before.** h9's commands fill gaps, they don't override 9front. If 9front ever ships a `wsmount`, it wins without h9 changing.

**rc only.** Every command these proposals need is a few lines of rc around `ctl` files and `mount`. Binaries would need building for each architecture's root, by the code under test, as [self-host](0010-self-host.md) does, or shipping 9front-built ones, which turns h9 into a distribution. If a proposal ever needs a binary, it can propose that.

**One proposal for all of them.** The question "how does h9 ship a guest command" is the same for every proposal that needs one. Answering it once keeps websocket-9p and dotl about their devices.

**Not upstream in 9front.** The scripts wrap devices that only h9 has. 9front wouldn't want them until it has the devices too.

**`#H`, not a directory in devroot.** devroot's tables are fixed-size and in the vendored tree. A small device of h9's own keeps the vendor tree unchanged and can be masked on its own.

## Compatibility

- **CLI:** new `--no-guest-tools`.
- **`Machine.Options`:** new `guest_tools`.
- **The namespace:** `/bin` gains `#H/bin`, after everything else. With an empty tree, nothing visible changes. Each command that lands later appears in `/bin` unless the root has one of the same name.
- **`--print`:** the new bind. `--ns` replays it as an ordinary bind.
- **The root tree and `third_party/`:** unchanged.

## Security

The device serves constant, read-only files that are built into the h9 binary, so the guest gains nothing it couldn't already type. The commands use only devices and syscalls the guest already has, under the same policy. `--no-guest-tools` removes them for embedders that want the namespace to hold exactly what the root provides.

## Done when

Integration cases tagged `[guest-tools]`, with a test-only script in the table:

- `test "#H/bin is bound after /bin and its scripts run [guest-tools]"`
- `test "a root command of the same name wins over #H's [guest-tools]"`
- `test "#H refuses writes [guest-tools]"`
- `test "--no-guest-tools leaves out the bind and masks #H [guest-tools]"`
- `test "--print shows the #H bind [guest-tools]"`

The build check that rejects a non-rc executable is a `zig build test` case.

## Implementation

1. The build step that embeds `src/guest/` as a table, with the rc check.
2. `src/kern/devhtools.c`, its `devtab.c` entry, and `h9_tools_table` in `src/kern.zig`.
3. The bind and `--no-guest-tools` in `src/policy.zig`, `src/cli.zig` and `Machine.Options`.
4. README: the flag, and a line on where `wsmount` and the like come from. DESIGN.md: `#H` in the "Added by us" table, the namespace listing, the CLI flag table and `Machine.Options`. Set `status: implemented`.

## Open issues

- **Man pages.** `man wsmount` would need `/sys/man` entries. A `#H/sys/man/1` bound after the root's `/sys/man/1` would work the same way, if commands grow enough to need them.
