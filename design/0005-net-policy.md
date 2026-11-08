---
id: 5
slug: net-policy
title: Outbound-only network by default, and --net-allow
status: implemented
created: 2026-11-03
authors: [progrium]
depends: []
areas: [sandbox, cli, kern]
---

# Proposal: outbound-only network by default, and --net-allow

Nov 5, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Enforce `--net=outbound` and make it the default profile's setting: guests can dial out but not announce. Add `--net-allow PATTERN`, an egress allowlist of dial-string patterns that devip checks on every `connect`, with addresses, CIDR ranges, `*`, or host names. Without patterns, `connect` still refuses link-local addresses, which keeps cloud metadata endpoints out of reach. Name patterns are also enforced at devip's built-in `cs`, so a guest can't make the host resolve names the allowlist doesn't cover. Enforcement is a leaf hook in devip, like devfs's `h9_fs_check`: the same on every vmm backend and every host, with no host firewall involved.

## Background

This was part of milestone M5 ("servers") in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). DESIGN.md's capability table had two rows for it:

| Capability | Mechanism |
| --- | --- |
| `net.outbound` | devip refuses `announce` |
| `net.allow` | devip checks each `connect` against dial-string patterns (`tcp!10.0.0.0/8!564`); an egress allowlist isobox can't offer |

Its vendor-hooks paragraph planned `h9_net_check(op, addr, port)` in devip, a leaf like `h9_fs_check` that returns an int and never raises kernel errors itself.

### h9 today

`--net` takes `disable`, `outbound`, or `enable` (`src/policy.zig`):

- **`disable`** masks `#I` in the device mask after the namespace is built, so the guest can't attach it again. The tight profile's default.
- **`enable`** binds `#I` at `/net` with nothing else restricted. The default profile's default.
- **`outbound`** is accepted but not enforced. The plan lists `net.outbound` as `unenforced`, the network is left as `enable` leaves it, and `--strict` refuses it with exit 2.

`--print` says "the network is not restricted beyond --net=disable" whenever `#I` is visible.

### drawterm's devip

drawterm's `#I` (`third_party/drawterm/kern/devip.c`) serves `/net/tcp` (30 conversations) and `/net/udp` (10). Each is the usual clone, ctl, data, listen, local, remote, and status files, backed by host sockets through `devip-posix.c` or `devip-win32.c`. Everything a guest does with the network passes through two functions:

- **`ipwrite` on a ctl file** handles three text messages:
  - `connect addr!port[!r] [lport]`: parse, bind the local port if given, create the socket, then `so_connect`.
  - `announce [addr!]port`: bind, then `so_listen`.
  - `bind port`: set the local port.
  
  The listen file's open calls `so_accept`, which only works on an announced conversation.
- **`cswrite` on `/net/cs`** translates `proto!host!port` into `/net/proto/clone addr!port` lines. It resolves `host` with the host's `getaddrinfo` (`so_gethostbyname`), and `port` with the host's services or a built-in table of Plan 9 service names.

  libc's `dial` and `announce` use `/net/cs` when they can open it. So in an h9 guest, every name lookup is a DNS query by the host's resolver, with a name the guest chose.

drawterm has no `#I` icmp, so there's no ping.

### What uses it

In the pinned userland:
- Clients dial through libc's `dial`.
- Servers announce through `announce` and `listen`. That covers `aux/listen` and `aux/listen1`, and the services they start.
- `hget` can't run on h9 yet: it's a script around webfs, and webfs mounts itself with `mount`, which h9 doesn't serve.

## Proposal

### Modes

| `--net` | `#I` | `connect` | `announce` |
| --- | --- | --- | --- |
| `disable` | Masked | - | - |
| `outbound` | Bound | Allowed, or checked against `--net-allow` | Refused |
| `enable` | Bound | Allowed, or checked against `--net-allow` | Allowed |

- The default profile's default becomes **`outbound`**. The tight profile's stays `disable`. `--sandbox DIR` is the tight profile, so it's unchanged.
- `net.outbound` becomes an enforced capability: listed under `enforces:` when it applies, and no longer refused by `--strict`.
- `bind` messages stay allowed in every mode. A client may pick its local port, and binding doesn't accept connections; only `announce` followed by a listen does.
- UDP follows the same rules. A UDP `connect` is checked like a TCP one, and a UDP `announce`, which is how a UDP server receives from anyone, is refused under `outbound`.
- **Link-local is refused without patterns.** When no `--net-allow` is given, `connect` refuses 169.254.0.0/16 and fe80::/10 in both `outbound` and `enable`. That range holds the cloud metadata endpoint at 169.254.169.254, and ordinary guest programs don't need it. Loopback stays allowed, so a guest can still reach a dev server on the host.

### `--net-allow PATTERN`

`--net-allow` is repeatable. When any pattern is given, every `connect` must match one, in either mode that allows `connect`. The patterns are then the whole policy: the built-in link-local refusal no longer applies, so `'*!*!*'` or `'tcp!169.254.169.254!80'` reaches link-local addresses if the user wants that. A pattern is a dial string, `proto!host!port`:

| Part | Forms |
| --- | --- |
| `proto` | `tcp`, `udp`, or `net` or `*` for both |
| `host` | An IPv4 or IPv6 address (`10.0.0.5`, `::1`); a CIDR range (`10.0.0.0/8`, `fd00::/8`); `*` for any address; a host name (`api.example.com`); or a name wildcard covering one or more labels (`*.example.com`) |
| `port` | A number (`443`), a range (`8000-8099`), or `*` |

- **Address patterns** are checked at `connect` against the address in the ctl message, which is always numeric by then: devip's `setraddrport` parses it with `parseip`.
- **IPv4 is matched as IPv4.** devip keeps IPv4 addresses as IPv4-mapped IPv6 (`::ffff:a.b.c.d`). The check unmaps them first, so `10.0.0.0/8` and the link-local refusal match however the address was written, and an IPv6 pattern never matches an IPv4 address by accident.
- **Name patterns** need the name, which the ctl message doesn't carry. So h9 remembers it at `/net/cs`.
  - When the guest asks `cs` to translate `proto!name!port` and `name` matches a name pattern, `cs` resolves it as today.
  - h9 records the addresses it returned in the machine's resolved-name table, as (proto, address, port, name).
  - A later `connect` to one of those addresses is allowed if the name that produced it matches a name pattern with that proto and port.
- **Names that no pattern covers** aren't resolved at all. `cs` refuses them before calling the host's resolver, so the guest can't put data into DNS queries. A literal address in a `cs` request doesn't touch the resolver, so it's translated as today, and checked at `connect`.
- **Patterns with `*` for the host** cover every name, so every `cs` lookup is allowed for them.
- A name pattern can also be dialed by address without `cs`, if the guest learned the address some other way. The connect is allowed only if the address is in the table, so in practice names have to go through `cs`.
- **devip's `cs` is the only resolver name patterns see.** It's the one libc's `dial` uses, and a guest can't put its own `ndb/cs` over `/net/cs` while h9 doesn't serve `mount`. A guest that runs its own resolver (`ndb/dns`, over UDP) needs an address pattern for the resolver and for what it dials.

`--net-allow` with `--net=disable` is a usage error (exit 2), like `--write=none` with `--writable`. Bad patterns are usage errors too, with the pattern and what's wrong in the message.

### Errors

A refused `connect` or `announce` raises "permission denied", as devfs does for a path the policy refuses. A `cs` lookup refused for its name raises "no translation for host found", as an unknown name does. That's what libc's `dial` already reports for a name it can't use. The guest sees the same errors on every host and backend.

### The hook

The policy lives in Zig, as the filesystem's does. devip calls it through leaf functions, following DESIGN.md's seam rule 3: a leaf returns a verdict and raises no kernel error itself. The C side raises the error.

```c
/* src/kern/netcheck.h */
enum { H9_NETCONNECT = 0, H9_NETANNOUNCE = 1 };
/* 0 if allowed, -1 if not. proto is S_TCP or S_UDP; addr is IPaddrlen bytes. */
int  h9_net_check(int op, int proto, uchar *addr, int port);
/* 0 if cs may resolve this name for proto and port, -1 if not. */
int  h9_net_lookup(int proto, char *name, int port);
/* Records the addresses cs resolved for an allowed name. */
void h9_net_resolved(int proto, char *name, int port, uchar (*addrs)[IPaddrlen], int n);
```

In `devip.c`, which both `devip-posix.c` and `devip-win32.c` use, so there's one change for every host:

1. **`setraddrport`:** after parsing, call `h9_net_check(H9_NETCONNECT, …)`, and raise "permission denied" on -1. Both forms of `connect` go through it before `setlport` binds a port or `so_connect` touches the host.
2. **`announce`:** call `h9_net_check(H9_NETANNOUNCE, …)` before `setladdrport`, so a refused announce binds nothing.
3. **`cswrite`:** after splitting the request and looking up the port, call `h9_net_lookup` before `so_gethostbyname`, and `h9_net_resolved` after it.

Each is a call and an error. The header and the Zig side are h9's own: `src/kern/netcheck.c` and the leaves in `src/kern.zig`. As for devfs, the machine's compiled plan is found through the calling host thread, and kernel threads without one aren't restricted.

### The resolved-name table

The table belongs to the machine, so one machine's lookups don't allow another's connects when several share a host process.

- **Size:** it keeps the most recent 1024 entries.
- **Expiry:** entries never expire otherwise, since a guest may connect long after it resolved. A connect to an address whose entry was dropped is refused, which a guest sees as the "permission denied" it would get for any address outside the list.
- **Format:** the same one cs produces, so `--trace` can show which name allowed a connect.

### The plan

- `Policy` gains `net_allow: []const []const u8`, parsed at `compile` into patterns kept on the `Plan`.
- `enforces:` lists `net.outbound` under `outbound`, and `net.allow` when there are patterns.
- `--print` prints the patterns after the namespace:

```text
$ h9 --print --net-allow 'tcp!*.example.com!443' --net-allow 'udp!10.0.0.53!53'
profile:  default
enforces: env.scrub fs.read.scope fs.write.scope ipc.restrict kernel.isolation net.allow net.outbound
limits:   write=scope net=outbound
net-allow:
  tcp!*.example.com!443
  udp!10.0.0.53!53
...
caveats:
  - name patterns trust the host's resolver: a name is allowed to reach whatever address it resolves to
  ...
```

The caveat "the network is not restricted beyond --net=disable" is replaced, depending on the setup:

| Setup | Caveat |
| --- | --- |
| No patterns | "outbound connections can reach any address the host can except link-local, including its loopback and local network" |
| No patterns | "refusing link-local doesn't cover every cloud metadata endpoint: some, such as fd00:ec2::254 and 100.100.100.200, use other ranges" |
| No patterns | "the guest can make the host resolve any name" |
| Name patterns | "name patterns trust the host's resolver: a name is allowed to reach whatever address it resolves to" |
| `enable` | "servers in the guest are reachable by anything that can reach the host's ports" |

### CLI

| Flag | Meaning |
| --- | --- |
| `--net disable\|outbound\|enable` | As above. The default profile defaults to `outbound`. |
| `--net-allow PATTERN` (repeatable) | Allows `connect` only to matching addresses, and `cs` lookups only of matching names |

```sh
h9 --net=enable aux/listen1 -t tcp!*!8080 /bin/cat           # a server needs --net=enable now
h9 --net-allow 'tcp!10.0.0.0/8!564' --rc 'srv tcp!10.0.0.5!564 fs'   # egress to file servers only
h9 --net-allow 'tcp!*.example.com!443' myclient              # by name, through cs
```

The second example needs [devsrv](0008-devsrv.md) for `srv` to post to `/srv`; the connect it makes is allowed today.

## Rationale

**Enforcement in devip, not the host.**
- **Why not the host:** the host could filter instead, with seccomp and Landlock TCP ports on Linux, Seatbelt's `network-outbound` on macOS, or the Windows firewall. Those are per-OS. They can't all express CIDR ranges or names, and they apply to the whole h9 process, so every machine in an embedder gets the same rules.
- **What devip gives:** filtering in devip makes the policy the same on every host and backend, per machine, as the rest of the sandbox already is.
- **The host sandbox later:** [host-sandbox](host-sandbox.md) can still add a host-level layer as defence in depth, compiled from the same plan.

**A hook in the vendored devip, not a wrapper device.**
- **The wrapper alternative:** h9's own `src/kern/devtab.c` could put a wrapper in front of `ipdevtab` that inspects writes before passing them on. That keeps the vendored tree untouched.
- **Why not:** it would have to decode devip's qid layout and conversation state, which are private to `devip.c` (`TYPE`, `PROTO`, `Qctl`, `Qcs`). It would also re-parse the ctl text the same way devip does, and quietly break when upstream changes either.
- **The hooks:** three calls at the points where devip itself parses, as devfs already carries its sandbox hooks, are smaller and can't drift from what devip does.

**Names at cs, addresses at connect.** Checking only at `cs` wouldn't work: a guest can write a numeric address straight into a ctl file. Checking only at `connect` would make name patterns impossible, since the ctl message carries no name, and it would leave the host's resolver open to any name. So each check sits where its information is.

**Outbound by default.**
- **Why not enable:** most guest programs are clients. A server in the default profile listens on the host's ports, reachable by anything that can reach the host, which is rarely what a user running `h9 mk` meant.
- **Why not disable:** it would break every client, which the tight profile already offers for those who want it.
- **The cost:** a compatibility change for servers, which need `--net=enable` (see Compatibility).

**Link-local refused by default, loopback allowed.**
- **Link-local:** 169.254.169.254 is how a sandboxed client is usually turned against cloud credentials, and real guest programs almost never need link-local addresses. Refusing them costs little.
- **Loopback:** refusing it would break `h9 mk` with tests against a local dev server, the main use of the default profile. The tight profile is there for those who want the network closed, and the caveat says loopback is reachable.
- **Only without patterns:** once `--net-allow` is given, the list is the whole policy. Keeping the refusal under patterns would need a rule for whether `*` includes link-local, the kind of precedence `--net-deny` would bring. One rule is easier to explain and to show in `--print`.
- **Not complete:** some providers' metadata endpoints are outside link-local (AWS's IPv6 `fd00:ec2::254`, Alibaba's 100.100.100.200). Refusing those by default would mean a list of provider ranges in h9, and ULA and CGNAT ranges have real uses. The caveat names them; `--net-allow` is the way to close them.

**No `--net-deny`.** An allowlist is the safe form: deny rules beside an allowlist add precedence rules, and a denylist alone misses what it didn't list. The obvious use for one, keeping link-local addresses away from the guest, is handled by the default instead.

**No `--net-allow-file` yet.** Nothing needs long allowlists yet. Embedders set `Policy.net_allow` directly, and a shell can build the flags from a file. If long lists come up, one general mechanism, such as `@file` arguments or a profile file, would serve every flag rather than this one.

**No DNS for the guest.** Serving DNS to the guest in a way the policy sees, so `ndb/dns` users get name patterns too, would be a new device or file with its own design. If it's wanted, it's a separate proposal, going through the same `h9_net_lookup` hook. Until then, `cs` is the only resolver name patterns cover.

**No inbound filtering in `--net-allow`.** Under `--net=enable`, `--net-allow` could also restrict who may connect in, checked at `so_accept`. It isn't, for three reasons:
- **The port would mean something else.** For a `connect` it's the remote port. For an accepted connection the useful one is the local port, and the remote one is arbitrary.
- **Peer addresses are weak.** Filtering by source address is undone by NAT, and by spoofing for UDP.
- **The control that matters is what's announced.** If inbound control is wanted, a separate `--net-listen PATTERN` checked against the local address and port at `announce` would do it. `h9_net_check(H9_NETANNOUNCE, …)` already gets both, so it needs no fourth hook. It can come in a follow-up when there's a use.

**Service names in patterns.** Only numbers, ranges, and `*` are accepted. Service names would have to be resolved by the host's services database at compile time, and the result would differ between hosts. A plan should mean the same thing everywhere.

## Compatibility

- **Default profile:** servers that announce stop working without `--net=enable`. They get "permission denied" from `announce`, so `aux/listen1` exits with "announce tcp!*!8080: permission denied". Clients are unaffected, unless they dial link-local addresses.
- **Link-local:** without `--net-allow`, a `connect` to 169.254.0.0/16 or fe80::/10 is refused in both `outbound` and `enable`. A guest that needs it names it in a pattern.
- **`--net=outbound`:** now enforced. Scripts that passed it, and got `enable` with a caveat, now get what they asked for. `--strict --net=outbound` stops being a usage error.
- **New flag:** `--net-allow`. Nothing existing changes meaning.
- **`--print`:** a `net-allow:` section, new `enforces:` entries, and new caveat text.
- **`Machine.Options.policy`:** gains `net_allow`. An embedder that builds `Policy` directly and leaves `net` null gets `outbound` instead of `enable`.
- **Vendored tree:** `devip.c` gains three hook calls and an include, like devfs. `scripts/vendor-drawterm.sh` merges them across upstream updates.
- **CLI exit codes:** `--net-allow` with `--net=disable`, or with a bad pattern, is exit 2.

## Security

- **What the guest can no longer do:**
  - listen on the host's ports in the default profile
  - with `--net-allow`, connect anywhere outside the list
  - with `--net-allow`, make the host resolve names outside it
- **What it still can, by default:** with no patterns, `outbound` reaches every address the host can except link-local. That includes the host's loopback services and its local network, which is what a client-friendly default means. Link-local is refused, which covers the common cloud metadata endpoint at 169.254.169.254, but not those some providers put elsewhere. The plan says both in its caveats.
- **Trust in the host's resolver.** A name pattern allows whatever its name resolves to. Anyone who controls the name's DNS, or the host's resolver, can point it at an internal address. The plan lists this as a caveat. Use address or CIDR patterns where that matters.
- **Rebinding.** The table records what a name resolved to when the guest asked. A later DNS change doesn't take back a connect to an address already recorded. It also can't add new addresses without a new `cs` request, which is checked.
- **No race between check and use.** The check and the socket call run on the same kernel thread with the parsed address in hand. Nothing between them reads guest memory again.
- **Testing the boundary:** the integration cases below include a refused connect that a host listener must never see, and a refused name that would have resolved, which shows the check runs before the host's resolver.

## Done when

Integration cases tagged `[net-policy]`. They run h9 against listeners the test opens on 127.0.0.1, and use rc to write `/net` ctl files directly, so they need no client program the tree doesn't have:

- `test "the default profile refuses announce [net-policy]"`: `aux/listen1 -t tcp!127.0.0.1!PORT /bin/cat` exits with "permission denied".
- `test "--net=enable allows a server [net-policy]"`: the same `listen1 -1` under `--net=enable` answers one connection from the test.
- `test "outbound allows connect [net-policy]"`: rc dials the test's listener through `/net/tcp/clone` and sends a line the test reads.
- `test "outbound refuses link-local without patterns [net-policy]"`: rc's `connect 169.254.169.254!80` gets "permission denied", in both `outbound` and `enable`.
- `test "a pattern allows link-local [net-policy]"`: under `--net-allow 'tcp!169.254.0.0/16!*'`, the same connect isn't refused by the policy. The test checks the error, since nothing listens there.
- `test "--net-allow refuses a connect outside it, and the host sees nothing [net-policy]"`
- `test "--net-allow allows a matching CIDR and port [net-policy]"`
- `test "a name pattern allows a connect through cs [net-policy]"`: `tcp!localhost!PORT`, translated through `/net/cs`.
- `test "a name outside --net-allow isn't resolved [net-policy]"`: under `--net-allow 'tcp!127.0.0.1!PORT'`, cs answers "no translation for host found" for `tcp!localhost!PORT`, although `localhost` resolves on every host. So the refusal comes before the resolver.
- `test "a UDP announce is refused under outbound [net-policy]"`
- `test "--net-allow with --net=disable is a usage error [net-policy]"`
- `test "--print shows net-allow patterns and caveats [net-policy]"`
- `test "--strict accepts --net=outbound [net-policy]"`

Unit tests in `src/policy.zig` for pattern parsing and matching: IPv4 and IPv6 CIDR edges, IPv4-mapped addresses matching IPv4 patterns, and the link-local refusal but not IPv6 ones, port ranges, name wildcards at label boundaries (`*.example.com` matches `a.example.com` but not `example.com` or `badexample.com`), and the table's eviction.

## Implementation

1. Pattern parsing and matching in `src/policy.zig`, `Policy.net_allow`, the `outbound` default, the link-local refusal without patterns, `net.outbound`, and `net.allow` in `enforces:`, the new caveats, `--print`'s section, and the usage errors. Unit tests.
2. `src/kern/netcheck.h` and `netcheck.c`, the leaves in `src/kern.zig`, and the per-machine resolved-name table.
3. The three hook calls in `third_party/drawterm/kern/devip.c`.
4. `--net-allow` in `src/cli.zig` and the README's sandbox table.
5. The integration cases.
6. DESIGN.md: `net.outbound` and `net.allow` join the capability table, the default profile's network row becomes outbound, the vendor-hooks paragraph gains `h9_net_check`, and the CLI table gains `--net-allow`. Set `status: implemented`.

## Updates

- 2026-11-05: Refinements made while implementing it:
  - `--net-allow` is a usage error under the tight profile's implicit `--net=disable` too, not only an explicit one, since the patterns would never apply. `--sandbox DIR --net=outbound --net-allow …` is the way to combine them.
  - A cs request for a protocol other than `tcp` or `udp` is refused when patterns are given, since no pattern can name it.
  - A `connect` port outside 0-65535 matches no pattern.
  - The resolved-name table records each answer `cs` gives for a name, so a name looked up repeatedly takes several of its 1024 entries; the oldest are dropped first, as planned. `--trace` doesn't print which name allowed a connect yet.
  - Besides the integration cases, `tests/backends.zig` has `[net-policy]` cases that write `#I` ctl and `cs` files from small arm64 programs (`tests/fixtures/net`), so the devip hooks are exercised on the emulator without a root tree.
  - A UDP or TCP `announce` with port 0 fails in drawterm's devip before and after this change ("bad file descriptor"), since it binds only a nonzero port; the cases use a fixed port.
