---
id: 107
slug: tilde-roots
title: Tilde roots from $H9ROOTPATH
status: draft
created: 2026-11-08
authors: [progrium]
depends: [13, 21, 76]
areas: [cli]
---

# Proposal: Tilde roots from $H9ROOTPATH

## Abstract

`$H9ROOTPATH` holds a space-separated list of root prefixes, and a `--root` or `$H9ROOT` value starting with `~` is the rest of a root under one of them. With `H9ROOTPATH="wss://roots.example.com/ $HOME/roots/"`, `--root=~alpine` means `wss://roots.example.com/alpine` if that server has it, and `$HOME/roots/alpine` otherwise. h9 tries the prefixes in order and takes the first that has the root: a path that exists, or a WebSocket handshake that's answered with 101. With one prefix there's nothing to try, and the value is expanded without connecting. Nothing changes when the variable isn't set.

## Background

A root is named in full every time. [9p-roots](0013-9p-roots.md) gave `--root` dial strings and sockets beside host directories, [websocket-9p](0021-websocket-9p.md) added `ws://` and `wss://` URLs, and [schemeless-roots](0076-schemeless-roots.md) let a URL's scheme be left off. Each of these shortens or widens what one value can say, but the value still names one place, from its host down to its last path component.

In practice, most of someone's roots live in a few places: a server of root trees (`wss://roots.example.com/alpine`, `…/debian`, `…/9front`), a directory of unpacked trees (`~/roots/alpine`, `~/roots/9front`), and maybe a server on localhost while one is being worked on. What changes from run to run is the last part. Typing the rest is the same tax schemeless-roots removed for `wss://`, only longer, and a script that hardcodes it can't be pointed at a mirror or a local copy without editing it.

Shells solved this for directories with `CDPATH`, and for commands with `PATH`: a list of prefixes in the environment, tried in order, so a short name finds the first place that has it.

### h9 today

`resolveRoot` in `src/main.zig` calls `cli.rootArg`, which returns `.ws`, `.tcp`, `.unix`, or `.path`. A `.path` that exists is a directory or socket; one that's missing is tried with `cli.schemelessRoot`, and is "not found" if that returns null. `schemelessRoot` refuses a value starting with `~`, so it can't be read as a URL, and h9 doesn't expand `~` itself: today `--root '~alpine'` is a relative path, and almost always "not found", exit 125.

## Proposal

### `$H9ROOTPATH`

`$H9ROOTPATH` is a list of prefixes separated by spaces or tabs. Empty entries are ignored, and a variable that's empty or only spaces is the same as unset. Each prefix is any start of a `--root` value: a `ws://` or `wss://` URL, a schemeless URL (`roots.example.com/`, `localhost:8080/`), a host path, or `unix!` and a directory. A prefix usually ends in `/`; h9 doesn't add one, so `wss://roots.example.com/r-` with `~alpine` is `wss://roots.example.com/r-alpine`.

```
export H9ROOTPATH="localhost:8080/ wss://roots.example.com/ $HOME/roots/"
h9 --root=~alpine sh -c 'cat /etc/os-release'
```

### Tilde roots

A `--root` or `$H9ROOT` value is a tilde root when `$H9ROOTPATH` is set, it starts with `~`, and it isn't `~/…`. Its rest is everything after the `~`, and may be empty. The rest has no whitespace, like any root value.

For each prefix, in order, the candidate is the prefix followed by the rest, read by the rules `--root` already has (websocket-9p's prefix, 9p-roots' dial strings and paths, and schemeless-roots' fallback). A candidate that itself starts with `~` is an error rather than a second expansion.

A tilde root is read before the path check, so with `$H9ROOTPATH` set, a directory in the working directory named `~alpine` is reached as `./~alpine`. Without the variable, a value starting with `~` is read as it is today.

### Trying candidates

With one prefix, its candidate is the root, without trying it first. It fails the way any root fails, and `--print` shows it without connecting.

With several, h9 tries them in order and takes the first that matches:

| Candidate | Matches | Goes on to the next | Stops with the error |
|---|---|---|---|
| Host path | It exists | It doesn't exist | It exists but isn't a directory or socket |
| `unix!` path | The socket exists | It doesn't exist | It isn't a socket |
| `ws://` or `wss://` URL | The handshake gets 101 | No answer: DNS failure, refused, or timed out; or 404 or 410 | Any other status (401, 403, 426, 5xx), or a TLS failure |
| `tcp!` dial string | It connects | No answer, as above | |

A server that answers with anything but "not here" stops the search, so a root that's on the first server but refused for a bad token is reported as that, and h9 doesn't quietly use a different server's root of the same name. A server that isn't running goes on to the next, so a local server listed first can be off without breaking anything.

Each try is a handshake with the root's `--root-header` lines and `--root-ca`, and the timeout websocket-9p's dial has. The handshake that matched is closed, and the machine dials the chosen URL as it dials any `wss://` root, so `Machine.Options` doesn't change. That costs one extra handshake, and only when there are several prefixes.

### What the user sees

The chosen root is what h9 uses from then on: `--print`, `--check`, and errors show its URL or path, so the prefix that was taken is always visible. `--print` with several prefixes tries them, since the choice depends on what's there.

When nothing matches, the error names every candidate, in order:

```
$ h9 --root=~alpine ls
h9: root ~alpine: not found under $H9ROOTPATH
h9:   ws://localhost:8080/alpine: connection refused
h9:   wss://roots.example.com/alpine: 404 Not Found
h9:   /home/jeff/roots/alpine: no such path
```

That's exit 125, as for any root that can't be reached. A tilde root with no `$H9ROOTPATH` set is the relative path it is today.

### The shell

Tilde expansion is done by the shell, before h9 starts: for an unquoted `~/roots`, a program receives `/home/jeff/roots`, and h9 doesn't expand `~` itself. Some programs expand `~/` in their own config files (OpenSSH, git), which is where expansion "in the program" is usually seen, but on a command line the shell has done it first. A shell expands `~NAME` at the start of a word to the home directory of user `NAME`, and `~` and `~/…` to `$HOME`. So the spelling that's documented is `--root=~alpine`: bash and zsh don't expand `~` after `=` in an argument that isn't an assignment (zsh only does with `MAGIC_EQUAL_SUBST`). The space-separated form needs quotes, `--root '~alpine'`, because:

- bash expands `~alpine` only when a user `alpine` exists, but users like `root`, `bin`, `daemon`, `git`, and `nobody` exist on most systems, so `--root ~root` becomes `--root /root`.
- zsh, the default shell on macOS, fails the command with "no such user or named directory: alpine" when there's no such user, and also expands names from `hash -d`.

`H9ROOT=~alpine` is an assignment, and is expanded as `--root ~alpine` is, so it needs quotes too: `H9ROOT='~alpine'`.

## Rationale

**A list in the environment.** The prefixes belong to the user's setup, not to a command line: the same `~alpine` should mean the team's server at work and a local copy on a plane. An environment variable is how `PATH` and `CDPATH` do it, and it's inherited by scripts and by h9 runs started from other tools, which a flag isn't. A config file would do the same with more machinery, and h9 has none yet.

**Spaces, not colons.** `PATH`'s `:` is in every URL, and `,` and `;` can be in a URL's path. A space can't be in a URL unencoded, and host paths with spaces are rare among root trees; one can be reached through a symlink. It's also how rc keeps lists, so the variable reads naturally in an rc profile.

**Tried in order, first match wins.** That's `PATH`'s rule, and it gives the user the precedence: a local server before the shared one, a mirror before the origin. Trying all of them in parallel and taking the first that answers would be faster when early prefixes are down, but it would make the choice depend on timing, and the same command could pick different roots from one run to the next. In order, it's deterministic.

**A handshake, not HEAD.** A `HEAD` request is the cheapest way to ask an HTTP server whether a path exists, but WebSocket servers don't answer it usefully: h9's own `--serve` ([serve](0035-serve.md)) answers any method but `GET` with 405, and a `GET` that isn't an upgrade with 426, whatever the path. The upgrade `GET` is the request a WebSocket server routes by path, and it costs the same round trip, so the probe is the handshake itself. If h9 gains roots fetched over plain `http://` or `https://`, `HEAD` is the probe for those.

**Not found goes on; refused stops.** Going on after every failure would turn a wrong token into a silent switch to another server's root. Stopping at every failure would make a list with a local server first useless whenever that server is off. The line between them is whether something answered and said the root isn't there.

**One prefix, no probe.** With one prefix, there's no choice to make, so `~alpine` is a textual shorthand and costs nothing. `--print` stays offline in the common case, as it is for every other root.

**Read before the path check.** schemeless-roots reads a path first, so that no value that works today changes meaning. A tilde root can't change any value's meaning unless the user sets `$H9ROOTPATH`, so that care isn't needed here, and checking the path first would make `~alpine` mean a stray directory in the working directory before the user's own prefixes.

**The marker.** `~` is short, reads as "relative to my roots" the way it reads as "relative to my home" in a shell, and `schemelessRoot` already refuses it, so it can't collide with a URL or a schemeless one. Its cost is the shell, above. The `--root=` spelling makes that go away for the flag, which is where it's typed most. The alternatives, and why each wasn't chosen:

| Marker | Example | For | Against |
|---|---|---|---|
| `~` (proposed) | `--root=~alpine` | Short; reads as "relative to a base", as in a shell; already refused by `schemelessRoot` | Expanded or rejected by the shell unless written with `=` or quoted; `~root` silently becomes `/root` in bash |
| `+` | `--root +alpine` | No shell expands it, so no quoting anywhere, `H9ROOT` included; never starts a root value today | Reads as "add" or as an option (`set +x`), not as "look up" |
| `:` | `--root :alpine` | Shell-safe; reads like a URL with its scheme taken from somewhere else | Easy to miss; looks like a typo for `host:port` |
| `@` | `--root @alpine` | Shell-safe in POSIX shells; reads as "at one of my places", like npm's `@scope/` | PowerShell splats `@name`; `schemelessRoot` already treats `@` as userinfo; `--root-header @FILE` uses `@` to mean a file |
| `%`, `^`, `=`, `#` | `--root %alpine` | Short | Each is special somewhere: `^` is negation under zsh's `EXTENDED_GLOB`, `=cmd` is a command's path in zsh, `#` starts a comment, and `%` is a job spec and reads as a format |
| A scheme-like prefix | `--root root:alpine` | Self-describing and shell-safe; fits the way `tcp!`, `unix!`, and `ws://` already mark kinds of root, and the `oci:` prefix schemeless-roots anticipates | Five characters to save typing; a new pseudo-scheme to learn; `root:alpine` has to be recognized before `schemelessRoot`, which would otherwise see a host and a port |
| A bare name | `--root alpine` | Shortest; the way `PATH` finds a command with no `/` | Ambiguous with a relative path; a missing directory would turn into network lookups, which schemeless-roots deliberately kept bare names out of |
| A flag | `--root-name alpine` | Unambiguous; no new syntax in root values | Longer than what it replaces for short URLs; `$H9ROOT` can't use it; one more flag |

`~` wins on reading naturally and costs nothing to parse, provided the docs lead with `--root=~name`. If the shell turns out to bite in practice, `+` is the next choice: it gives up the reading for a marker no shell touches.

**Literal concatenation.** h9 doesn't add a `/` between prefix and rest, so a prefix can be the start of a name (`wss://host/root-`). Adding one would be friendlier for a prefix that leaves it off, but would make `wss://host/r` and `wss://host/r/` the same, and couldn't express the name-prefix case at all.

**No query strings in prefixes.** A prefix with `?token=…` would put the rest after the query, which isn't what's meant. Tokens go in `--root-header` or, once it lands, a [credential helper](0119-credential-helpers.md), not in `$H9ROOTPATH`.

## Compatibility

- **`--root` and `$H9ROOT`:** without `$H9ROOTPATH`, unchanged. With it, a value starting with `~` but not `~/` is a tilde root; a directory with such a name is reached as `./~name`.
- **Exit codes:** unchanged. A tilde root with no match is 125.
- **`--root-header` and `--root-ca`:** apply to every WebSocket candidate tried, and to the chosen root, as they apply to any WebSocket root. `--root-ca` with only loopback candidates is exit 2, as with `ws://`.
- **`--print` and `--check`:** show the chosen root. With several prefixes, `--print` connects to try them.
- **`Machine.Options`, namespace files, `wsmount`, the browser host's JS API, the sandbox defaults, and `third_party/`:** unchanged.

## Security

- **Requests to every listed server.** With several prefixes, a tilde root makes a handshake to each one in turn until one matches, so each of those servers learns the root's name, the client's address, and, with `--root-header`, the header. The user chose those servers by listing them, but a token meant for one is sent to all of them until one matches. A credential helper, matched per URL, is the way to give different servers different credentials.
- **Transport:** each candidate's, as for the root it names: TLS for `wss://` and for a schemeless non-loopback host, verified against the host's bundle or `--root-ca`'s.
- **The environment picks the root.** Whoever can set `$H9ROOTPATH` chooses what `~alpine` means, as whoever can set `$H9ROOT` already chooses what the default root is. A script that needs a particular root writes it in full.
- **The guest** reaches nothing new. The root is a host-made connection, outside `--net`, as every root is.

## Done when

The unit test in `src/cli.zig`, `test "tildeRoot splits $H9ROOTPATH and joins each prefix with the rest"`, covers the list's parsing, `~/…` and bare `~`, literal concatenation, and a nested `~`. Integration cases tagged `[tilde-roots]`:

- `test "a tilde root with one prefix prints its URL without connecting [tilde-roots]"`
- `test "a tilde root takes the first prefix whose server has it [tilde-roots]"`: two `--serve` listeners, the first serving a different path, so it answers 404.
- `test "a tilde root skips a prefix whose server isn't running [tilde-roots]"`
- `test "a tilde root stops at a 401 rather than trying the next prefix [tilde-roots]"`: the first listener with `--serve-token`.
- `test "a tilde root over host directory prefixes runs /bin/ls [tilde-roots]"`
- `test "a tilde root with no match exits 125 naming each candidate [tilde-roots]"`
- `test "without $H9ROOTPATH a ~ value is a path, as before [tilde-roots]"`
- `test "$H9ROOT can be a tilde root [tilde-roots]"`

Demo: `H9ROOTPATH="localhost:8080/ $HOME/roots/" h9 --print --root=~9front ls` shows `$HOME/roots/9front` in the plan's root comment when no server is on port 8080.

## Implementation

1. `cli.tildeRoot(arena, arg, rootpath) ?[]const []const u8`, which returns the candidates or null and does no I/O, and its unit test.
2. `resolveRoot`'s tilde step, the tries for each kind of candidate, and the error that lists them. The WebSocket try reuses websocket-9p's dial and handshake with the same headers, CA, and proxy settings, and keeps the status from `ws.Response`.
3. The integration cases.
4. README's and MANUAL.md's `--root` notes, a paragraph on `$H9ROOTPATH` and the shell, and SPEC.md's root filesystem paragraph and CLI flag table. Set `status: implemented`.

## Open issues

- **The marker.** `~`, as proposed, or `+`, which no shell touches (see the table under Rationale). Accepting both would avoid the shell problem for `$H9ROOT` too, at the cost of two spellings for one thing.
- **Other places a root is named.** The `--layer` flag of [recursive unions](https://github.com/progrium/hyper9/issues/102) would read tilde values the same way. Namespace files and `wsmount` could too, but their sources are guest names, and the guest has no `$H9ROOTPATH`. The browser host has no environment; `createMachine` could take a `rootPath` list, and the demo page could read it from its query.
- **Keeping the probe's connection.** Handing the matched handshake's connection to the machine would save the extra handshake, but would need `Machine.Options` to take an open connection rather than a URL.
