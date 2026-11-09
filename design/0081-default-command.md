---
id: 81
slug: default-command
title: A default command from the root
status: implemented
created: 2026-11-07
authors: [progrium]
depends: []
areas: [cli, docs, tests]
---

# Proposal: A default command from the root

Nov 8, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

`h9 --rc` with no command line runs a login rc, `rc -l`, interactive on a terminal. 9front's `rcmain` already gives a login shell a hook: it sources `/rc/lib/rcmain.local` and then `$home/lib/profile` before reading commands. So a root sets its own default command in `/rc/lib/rcmain.local`, the way a 9front profile starts `rio`. Ending it with `exec prog` works like Docker's `CMD`, and leaving out the `exec` runs setup and then an rc. Nothing new is defined: no file, flag, variable, or root metadata. A root that has no `rcmain.local` gets a plain rc, so the built-in root works unchanged. Bare `h9` still prints the usage, so the feature is opt-in.

## Background

What exists today:

- **`--rc 'cmd'`** runs `/bin/rc -c cmd`, and any remaining arguments become `$*` (`src/main.zig`). `--rc` needs a value: `h9 --rc` alone is a usage error, exit 2.
- **`h9 rc`** runs rc with whatever flags follow. The interactive cases in `tests/integration.zig` pass `rc -i`, since the guest's stdin isn't named `/dev/cons` and rc doesn't turn on `-i` by itself.
- **Bare `h9`** prints the usage and exits 2 (DESIGN.md, CLI).
- **[The userland guide](../docs/userland.md)** section 4 already shows a root carrying its own login setup in `/rc/lib/rcmain.local` and running it with `h9 --root ~/slim rc -l`. It also notes that `h9 --rc` doesn't read it.
- **h9 sets the environment** a profile reads: `$user` is the host user, `$home` is `/usr/$user` (created in the overlay when the root lacks it), `$service` is `terminal`, and the cwd is `/mnt/term/cwd`.

9front's `rcmain`, which every root already has, runs the login hook like this:

```rc
if(! ~ $#cflag 0){
	if(flag l){
		if(/bin/test -r /rc/lib/rcmain.local) . /rc/lib/rcmain.local
		if(/bin/test -r $home/lib/profile) . $home/lib/profile
	}
	status=''
	eval $cflag
}
if not if(flag i){
	if(flag l){ ...the same two lines... }
	status=''
	if(! ~ $#* 0) . $*
	. -i /fd/0
}
if not if(~ $#* 0) . /fd/0
```

So `-l` takes effect only with `-c` or `-i`. A non-interactive `rc -l` that reads stdin skips both files.

What's missing is a way to say "run this root the way it wants to be run" without writing its command on every h9 command line. Docker answers this with `CMD` and `ENTRYPOINT` in the image's metadata. 9front's answer is the login profile: `/usr/glenda/lib/profile` sets up the namespace and then starts `rio` when `$service` is `terminal`.

## Proposal

**`--rc` with no command line runs a login rc.** When `--rc` is the last argument, h9 runs:

- `rc -l -i` when h9's stdin is a terminal, as `isatty` reports on the host. This is an interactive login shell.
- `rc -l -c '. /fd/0'` otherwise. rc runs the login files and then reads commands from stdin, the same as `rc` reading a script on stdin.

Both forms run `/rc/lib/rcmain.local` and then `$home/lib/profile` if they exist, so the rcmain logic above works without changing it.

**A root's default command goes in `/rc/lib/rcmain.local`.** That's the root-wide file: it doesn't depend on the user's name, and it runs before the user's own profile. A root author writes:

```rc
# /rc/lib/rcmain.local: this root's default command.
bind -a /mnt/term/cwd /usr/$user
exec myserver -p 8080
```

`h9 --root ./myroot --rc` then runs `myserver`, and `exec` makes its exit status h9's. Without the `exec`, the file just does setup, and the user lands in rc once it finishes. Arguments still override the default, as `docker run img cmd` does: `h9 --root ./myroot myserver -p 9090` or `h9 --root ./myroot --rc 'cmd'` runs only what it names.

**`$home/lib/profile` stays the user's.** rcmain reads it after `rcmain.local`, so a root with a `/usr/<name>` tree for a fixed user, or a user who has written one in a writable root, can add to the root's setup. Roots shouldn't use it for their default, since `$home` follows the host user's name.

**What a root needs:**

| Path | Why |
| --- | --- |
| `/bin/rc`, `/rc/lib/rcmain` | Already required for `--rc` |
| `/bin/test` | rcmain tests each login file with `/bin/test -r`. Without it, both files are skipped silently. The built-in root's `slim` set has it. |
| `/rc/lib/rcmain.local` | Optional: the default command. Without it, `h9 --rc` is a plain rc. |
| Whatever the default runs | As for any program |

The built-in root, the stock 9front tree, and slim roots need no changes. None of them has an `rcmain.local`. The stock tree's only profile is glenda's, which runs only when the host user is named `glenda`.

**Docs.** The README's usage line becomes `--rc ['command']`, and DESIGN.md's CLI section gains `h9 [h9-flags] --rc   # login rc: the root's default command`. Section 4 of the userland guide replaces `rc -l` with `--rc` and adds the `exec` form.

## Rationale

**Reuse rc's login hook, not new metadata.** Docker needs `CMD` because an image has no shell convention of its own. A 9front root already has one, and it's what 9front itself uses to pick a session's program. A root that's also a real 9front tree behaves the same way under h9 as on a terminal. No h9 code has to read a manifest, and `--print`, `--check`, and the sandbox don't change.

**`rcmain.local` over `$home/lib/profile`.** h9 sets `$user` to the host user, so a root can't ship a profile at a path that works for everyone. Changing that by fixing `$user` for a root would mean inventing something new. `rcmain.local` is the 9front file for site-wide login setup, and it's absent from the stock tree, so a root that adds one changes nothing for other users.

**`/bin/init`, `termrc`, and `cpurc` were rejected.** On 9front, `init` runs `termrc` or `cpurc` to bring the machine up: devices, network, `aux/timesync`, the mouse, and the screen. h9 builds the namespace and devices itself, and a stock `termrc` would start programs that don't belong in a machine like h9's. Those files configure a computer, not a session, and nobody looks there for a program's default command.

**Opt-in through `--rc`, not bare `h9`.** Making bare `h9` run the default would change a usage error into a running machine. A typo in a script would then start a shell that waits on stdin. `--rc` alone reads as "an rc, the way the root sets it up", and it's the flag that already means rc.

**Choosing `-i` from the host's terminal.** rc can't tell that the guest's stdin is a terminal, which is why the tests pass `-i`. h9 already knows from the host. Turning on `-i` without a terminal would print prompts into piped output and keep going after errors. Leaving out `-c` without a terminal would skip the login files.

**`h9 rc -l` keeps working.** It's the explicit spelling, and it doesn't choose `-i` for you. `--rc` alone is shorthand for the common case.

## Compatibility

- **CLI:** `h9 --rc` with nothing after it was a usage error and now runs. Since `--rc` takes the next argument as its value, the bare form works only as the last argument: in `h9 --rc --root x`, `--root` is the command line, as it is today. `--rc=` (empty) stays `rc -c ''`. Exit codes are unchanged. A default that `exec`s a program exits with that program's status. Otherwise rc's `$status` maps as for `--rc 'cmd'`.
- **`Machine.Options`:** unchanged. The CLI builds the argv, as it already does for `--rc`.
- **`h9-binfmt`** ([host-binfmt](host-binfmt.md)) still refuses `--rc` in `H9FLAGS`.
- **Sandbox defaults, the root tree, and `third_party/`:** unchanged.

## Security

None. The login files are in the root, which already chooses every program the guest runs, and they run with the guest's namespace and policy. `--rc` alone does nothing that `h9 rc -l -i` doesn't already do.

## Done when

Demo: a slim root built as in the userland guide, with `/rc/lib/rcmain.local` holding `echo hello from the root`. `echo 'echo $user' | h9 --root ~/slim --rc` prints `hello from the root` and then the user's name. With `exec echo hello from the root` instead, `h9 --root ~/slim --rc` prints the line and exits 0 without reading stdin. With no `rcmain.local`, `h9 --rc` on a terminal is an interactive rc.

Integration cases, with a root in a temporary directory that holds `rc/lib/rcmain` and `rc/lib/rcmain.local` and gets its commands from `--builtin=before`:

- `test "--rc alone runs the root's rcmain.local, then stdin [81]"`
- `test "an exec in rcmain.local sets the exit status [81]"`
- `test "--rc alone without rcmain.local is a plain rc [81]"` on the built-in root
- `test "--rc alone on a terminal is an interactive login rc [81]"`, through `spawnTerm`
- `test "--rc 'cmd' doesn't read rcmain.local [81]"`

Unit cases in `src/cli.zig`: `--rc` as the last argument parses as a login rc, and `--rc=` parses as an empty command line.

## Implementation

1. `src/cli.zig`: when `value` returns no value for `--rc`, set `c.rc_login = true` instead of returning `error.Usage`, and count it as a program in the run-mode check. Add the unit cases.
2. `src/main.zig`: when `rc_login` is set, build `rc -l -i` or `rc -l -c '. /fd/0'`, depending on `isatty` of the host's stdin. Then run `/bin/rc` as `--rc` does.
3. The integration cases.
4. The README usage, DESIGN.md's CLI section, the usage text in `src/cli.zig`, and section 4 of `docs/userland.md`.

## Open issues

- Should `--check` say whether the root has a default command (an `rcmain.local`) and whether `/bin/test` is present? Missing `/bin/test` is the one way the hook fails silently.
- Should [browser-host](0012-browser-host.md)'s page, which starts an interactive rc, start a login rc instead, so a root's default runs in the browser too?

## Updates

**Nov 8, 2026.** The integration cases don't use `--builtin=before`, since [builtin-root](0087-builtin-root.md) isn't built yet. They run over the stock tree, which has no `rcmain.local`, and union a scratch directory's `rcmain.local` onto `/rc/lib` with `--ns`, so `rcmain` and `/bin/test` come from the root. The plain-rc case runs on the stock tree rather than the built-in root.
