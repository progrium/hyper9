---
slug: credential-helpers
title: Credential helpers for WebSocket 9P
status: draft
created: 2026-11-07
authors: [progrium]
depends: [21, 22]
areas: [cli, kern, sandbox, web]
---

# Proposal: Credential helpers for WebSocket 9P

## Abstract

Before each WebSocket handshake it makes, h9 can run a host command, a credential helper, chosen by matching the URL against patterns given with `--cred`, and send the headers it prints with the handshake. The helper runs on every handshake: the root's, a namespace file's mounts, and every reconnect [dotl](0022-dotl.md) makes under `9P2000.L.Z`. So short-lived tokens work for runs of any length, and namespace files hold no secrets. The guest never sees the helper, its output, or the headers. A server can also name the uid it serves files as, and dotl maps that uid to the machine's user without a `--user-map`.

## Background

- **[websocket-9p](0021-websocket-9p.md)** sends `--root-header 'Name: value'` or `--root-header @FILE` with the root's handshake. Namespace-file `mount` lines send no headers, so a token goes in the URL's query. Guest conversations can set headers through `ctl`.
- **Tokens are short-lived.** OIDC access tokens usually last minutes; hankoid's default is 5. A static header file works for the first handshake and fails on any later one.
- **dotl reconnects.** With `9P2000.L.Z`, dotl replays fids on a new connection with `Trebind`, so a dropped WebSocket doesn't fail open files. Each reconnect is a new handshake and needs a credential that's valid when it's made.
- **Tokens in URLs leak:** into server and proxy logs, into `--print`, and into namespace files the guest can read.
- **[root-auth](root-auth.md)** sets the rule that the guest never holds a key. It covers p9any for 9front servers; this proposal covers HTTP-layer credentials for WebSocket servers.
- **Users in .L.** dotl names .L uids through `--user-map`. Without one, the machine's user goes out as the host uid, and any other uid N shows as the name "N". A server that serves every client as one fixed uid, as a multi-tenant gateway over ZeroFS does, then shows every file as owned by a number.

## Prior art

Credential helpers are an established pattern. These are the ones this proposal borrows naming and ergonomics from, and where it departs from them.

- **[git credential helpers](https://git-scm.com/docs/gitcredentials).** `credential.helper` names a helper, and a bare name runs as the git subcommand `git credential-NAME`. Config can be scoped by URL (`[credential "https://example.com"]`), and the path is ignored by default, since most people have one credential per host. The protocol is `key=value` lines with `fill`, `approve`, and `reject` actions. Taken from git: the name *credential helper*, matching on URL at host granularity by default, and telling the helper when a credential was rejected.
- **[Docker credential helpers](https://github.com/docker/cli/blob/master/docs/reference/commandline/login.md).** `credsStore` sets a global helper, and `credHelpers` maps a registry host to a helper, run as `docker-credential-SUFFIX`. A registry with its own helper never falls back to the global store. Taken from Docker: a pattern-to-command map in which the most specific match wins outright.
- **Go's [`GOAUTH`](https://pkg.go.dev/cmd/go#hdr-GOAUTH_environment_variable)** (Go 1.24). A list of commands and built-in methods (`off`, `netrc`, `git`). A command prints URL prefixes, a blank line, then MIME headers to send to URLs under those prefixes. After a failed request the command runs again with the response on stdin. Cloud providers ship commands for it, such as `gcloud artifacts go auth`. Taken from GOAUTH: headers as the output format, which is also what `--root-header @FILE` reads, and the retry with the failed response on stdin.
- **[Kubernetes exec credential plugins](https://kubernetes.io/docs/reference/config-api/client-authentication.v1/).** kubectl runs a plugin that returns an `ExecCredential`: a bearer token and an optional expiry. The request can carry the server's response to a 401, so the plugin knows the last credential failed. The docs ask that tokens only pass in memory between the client and the plugin. Kubernetes also keeps per-cluster plugin config apart from secrets, so the kubeconfig needs none, which is this proposal's argument for namespace files.
- **[AWS `credential_process`](https://docs.aws.amazon.com/sdkref/latest/guide/feature-process-credentials.html).** The SDK runs a command and reads JSON from stdout. An `Expiration` field makes the SDK refresh when it passes; without one, the credentials are treated as long-lived.
- **[Cargo credential providers](https://doc.rust-lang.org/cargo/reference/registry-authentication.html).** The simplest, `cargo:token-from-stdout CMD`, takes a token from a command's stdout. The full [protocol](https://doc.rust-lang.org/cargo/reference/credential-provider-protocol.html) is JSON over stdin and stdout, with a cache hint of `never`, `session`, or `expires`, and the token is sent as the `Authorization` header.
- **Plan 9 factotum.** The native precedent. Programs don't handle secrets: they ask factotum to run a protocol, and keys are chosen by attributes such as `proto`, `dom`, and `server`, not by the program. root-auth applies this to p9any. This proposal applies the same separation to HTTP: the helper holds the secret, and h9 carries headers it doesn't interpret.

This proposal takes the name from git and Docker, the most-specific-wins pattern map from Docker, header blocks as output from GOAUTH, and the retry with the failure on stdin from GOAUTH and kubectl. It leaves out client-side caching, which AWS, kubectl, and Cargo do, and the multi-action protocols of git, Docker, and Cargo. Rationale says why.

## Proposal

### `--cred`

| Flag | Meaning |
| --- | --- |
| `--cred 'PATTERN=COMMAND'` | Repeatable. Runs COMMAND for handshakes whose URL matches PATTERN |
| `$H9CRED` | The same, with entries separated by `;`, as `GOAUTH` separates its commands. `--cred` entries come first |

**Patterns** are scheme-less URL prefixes: `progrium.wanix.io`, `progrium.wanix.io/data/projects`, `*.wanix.io`.

- A leading `*.` matches one or more host labels. A pattern without a path matches every path on its host.
- The longest matching pattern wins, and only it runs, as with Docker's per-registry helpers.
- `*.` or `*` alone, with no domain after it, is a usage error.
- Patterns match `ws://` URLs too, but a match on `ws://` warns on stderr that the headers cross the network in plaintext.

**COMMAND** is split on spaces, as Cargo splits provider strings. A first word without a `/` is looked up in `PATH`, with no prefix added: a helper is any program, and a `h9-credential-` prefix would add no safety.

### The exchange

h9 runs `COMMAND get URL`, with the full URL, path, and query included.

- **stdin:** empty on a first attempt. On a retry, the failed handshake's status line and response headers (below).
- **stdout:** zero or more `Name: value` lines, the format of `--root-header @FILE`, checked by `ws.checkHeader`. A header that would change the handshake (`Host`, `Upgrade`, `Connection`, `Sec-WebSocket-*`) is an error, as it is for `--root-header`. A blank line or EOF ends the output.
- **stderr** passes through to h9's stderr.
- **Exit status:** nonzero is a failure, and its first stderr line goes into the error.
- **Timeout:** 30 seconds. A helper that has to prompt does so on the controlling terminal. A login that takes longer, such as an OAuth device flow, belongs in a separate step before h9 runs.

Printing nothing and exiting 0 means "no credential", and the handshake goes ahead without one.

### When it runs

- **The root's handshake,** before the program starts.
- **Namespace-file `mount` lines** with `ws://` or `wss://` sources, during replay.
- **Every dotl reconnect** of either. The reconnect waits for the helper, and a helper failure counts as a failed reconnect attempt under dotl's existing limits.
- **Not guest conversations** on `/net/ws` (see Security).

Headers from `--root-header` still apply to the root. If both give a header of the same name, `--root-header`'s wins, so a run can override one header without replacing the helper.

### Retry on 401

If a handshake gets `401` or `403`, h9 runs the helper once more with the response on stdin:

```text
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer error="invalid_token"
```

If that retry fails too, the handshake fails as it does today: before the program starts, exit 125 with `root wss://…: server answered 401 Unauthorized (after credential helper retry)`; on a reconnect, as a hangup. The response tells the helper to drop a cached token and refresh, which covers git's `reject` without a second action.

### The server's identity: `9P-Uid` and `9P-User`

A server can name, in its `101` response, the uid it serves the client as and the name for it:

```text
HTTP/1.1 101 Switching Protocols
9P-Uid: 1000
9P-User: progrium
```

When neither `--user-map` nor `--root-user` is given, dotl's user map maps that uid to that name, both ways, for that connection, and the root's attach sends that name as `uname` and that uid as `n_uname`. A `--user-map` wins over the headers. A name longer than the kernel's 27-byte user names is ignored, with a warning.

### Browser host

The web host has no processes. `h9-web.js` takes an embedder callback, `credentials(url, failedResponse)`, that returns header lines and is called at the same points a helper would run. A browser `WebSocket` can't set request headers, so on the web host the callback may instead return a URL to connect to, which supports a server that issues single-use tickets for the query.

### `Machine.Options`

```zig
pub const CredHelper = struct {
    /// Scheme-less URL prefix; a leading `*.` matches host labels.
    pattern: []const u8,
    /// Command and arguments, run as `argv… get URL`.
    argv: []const []const u8,
};
/// Credential helpers for host-made WebSocket handshakes.
cred_helpers: []const CredHelper = &.{},
```

### `--print`

The plan shows the pattern and command that applied, never the headers:

```text
mount '#s/root' / ''	# wss://progrium.wanix.io/data, cred *.wanix.io=wanix token
```

## Rationale

**Run on every handshake rather than cache.** AWS, kubectl, and Cargo cache by an expiry the helper reports. h9 handshakes are rare, one per mount plus reconnects, and a helper that wants caching can do it itself, as git's `credential-cache` does. Not caching keeps secrets out of h9 between handshakes and keeps expiry and clock-skew rules out of h9. Revisit if a helper turns out slow enough to stall reconnects.

**Headers as output, not JSON or `key=value`.** Headers are what h9 sends and what `--root-header @FILE` already reads, so `cat tokenfile` is a valid helper. Bearer tokens, cookies, and custom headers need no schema, and GOAUTH shows the format is enough in a widely used tool.

**One action, `get`.** h9 never stores credentials: logging in is the helper's own command (`wanix login`, `gh auth login`), and the retry's stdin carries the rejection. Naming the action leaves room for more later without breaking helpers.

**Longest match wins, with no fallthrough.** With fallthrough, a broad helper would be asked about URLs meant for a narrower one and could produce a credential it shouldn't. Docker's per-registry helpers work the same way.

**Not a factotum protocol.** p9any belongs in root-auth. HTTP credentials are opaque to h9, and a factotum would only pass them through. A plan9port factotum can still be a helper: a command that reads a `proto=pass` key and prints a header.

**Server identity in response headers, not helper output.** Only the server knows which uid it serves a client as, so the uid has to come from the server, and the name comes with it. The user map is then right even with a helper that knows nothing about uids, and `--user-map` still wins for anyone who wants to choose.

**Rejected:**

- **Tokens in the query.** They leak into logs, `--print`, and the guest.
- **`$VAR` expansion in namespace files.** The guest reads those files, and it puts secrets in the environment.
- **A static header file per pattern.** It can't refresh, which is the problem this proposal solves.

## Compatibility

- **CLI:** new `--cred` and `$H9CRED`. A missing or failing helper before the program starts is exit 125. A malformed `--cred` is a usage error, exit 2.
- Without `--cred`, nothing changes, except the `9P-Uid` and `9P-User` mapping for servers that send those headers.
- **`Machine.Options`** gains `cred_helpers`. **`h9-web.js`** gains the `credentials` callback.
- **Sandbox:** helpers run as the host user, outside the sandbox, as h9's own connections do.
- No change to the root tree or `third_party/`.

## Security

- **The guest gains nothing new.** Helpers run on the host, their output goes only into handshakes h9 makes, and devhstream never shows headers.
- **Guest conversations get no credentials.** Otherwise a guest whose root is `wss://progrium.wanix.io/data/projects` could open `wss://progrium.wanix.io/data` with the host's credential and reach all of the user's data. Opting guests in, per pattern, is an open issue.
- **Helpers are trusted code.** A pattern sends whatever its helper prints to every matching host, so patterns should be narrow. `*.` must be followed by a domain.
- **Cleartext:** a match on a `ws://` URL warns, since the credential crosses the network unencrypted.
- **Secrets in memory:** helper output lives in h9's memory for one handshake, then is zeroed and freed, following kubectl's in-memory guidance. It never reaches `--print`, logs, or test output; the plan names headers only.
- **`9P-User` is the server's claim about the client's name.** It only changes names shown inside the guest. It never selects a key, or a uid on any other connection.

## Done when

**Demo:**

```sh
h9 --cred '*.wanix.io=wanix token' --root wss://progrium.wanix.io/data rc -c 'ls -l /'
```

shows files owned by `progrium`. Restarting the server mid-`cat` of a large file finishes the `cat` after a reconnect with a fresh token.

**Cases:**

- `test "a --cred helper's headers are sent with the root's handshake [credential-helpers]"`
- `test "only the longest matching pattern's helper runs [credential-helpers]"`
- `test "a namespace-file wss mount runs the helper during replay [credential-helpers]"`
- `test "a .L.Z reconnect runs the helper again and sends the new token [credential-helpers]"`
- `test "a 401 reruns the helper once with the response on stdin [credential-helpers]"`
- `test "a helper failure before start exits 125 with its stderr [credential-helpers]"`
- `test "a helper may not set reserved handshake headers [credential-helpers]"`
- `test "--root-header wins over a helper's header of the same name [credential-helpers]"`
- `test "guest /net/ws conversations never run a helper [credential-helpers]"`
- `test "9P-Uid and 9P-User name files without --user-map [credential-helpers]"`
- `test "--user-map wins over 9P-Uid [credential-helpers]"`
- `test "--print shows the pattern and command, not headers [credential-helpers]"`

A fixture helper prints a token that changes on every call, and a fixture server accepts only the newest token.

## Implementation

1. `src/cred.zig`: pattern parsing and matching, the exchange (running the command, the retry's stdin, parsing output with `ws.checkHeader`, the timeout), and zeroing buffers. Unit tests against fixture scripts.
2. `src/cli.zig` and `src/main.zig`: `--cred` and `$H9CRED`, into `Machine.Options.cred_helpers`.
3. `src/hstream.zig`: before a host-made handshake, `cred.headersFor(url, prev)`, merged with `--root-header`, and the 401 retry in `openHost`. Guest conversations unchanged.
4. dotl's reconnect goes through the same open path, so it gets the helper with no change of its own. The reconnect case confirms it.
5. `src/ws.zig`: return `9P-Uid` and `9P-User` from `readResponse`. dotl's user map takes them as the connection's default.
6. `h9-web.js`: the `credentials` callback, including the URL form.
7. `--print` and the plan.

## Open issues

- **Guest opt-in.** Something like `--cred-guest PATTERN` for guests that should open credentialed conversations, with its own scope rules, such as only paths under the root's.
- **Header names.** `9P-Uid` and `9P-User`, or a single structured header? Is there a convention among other 9P-over-WebSocket servers to match?
- **The machine's user.** Should `9P-User` from the root also become the machine's user (`$user`, hostowner)? As written it only feeds the user map and the attach.
- **Concurrency.** When many connections reconnect at once, should h9 coalesce helper runs per pattern?
- **Windows:** command lookup and the controlling terminal.
