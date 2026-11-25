---
slug: linux-dns
title: Name patterns for a Linux guest's DNS
status: draft
created: 2026-11-25
authors: [progrium]
depends: []
areas: [kern, sandbox, linux]
branch: []
---

# Proposal: Name patterns for a Linux guest's DNS

## Abstract

Make `--net-allow` name patterns work for Linux programs. A Linux program resolves names with its own DNS client and then connects by address, so h9 never sees the name, and every name pattern refuses the connect. Under an allowlist with a name pattern, h9 answers the machine's DNS itself: each query to port 53 goes to a resolver h9 runs for the machine, which refuses names no pattern covers, forwards the rest to the host's DNS servers, and records the addresses in each answer in the machine's resolved-name table before the guest sees them. A later connect to one of those addresses is then allowed as it is after `cs` resolves the name. The guest's DNS servers no longer need patterns of their own, and the guarantee [net-policy](epoch-0/net-policy.md) gives 9front programs, that the guest can't make the host resolve names the allowlist doesn't cover, holds for Linux programs too.

## Background

[net-policy](epoch-0/net-policy.md) checks a `connect` against `--net-allow`'s dial-string patterns. A name pattern (`tcp!registry.npmjs.org!443`, or `tcp!*.example.com!443`) can't be checked at `connect`, whose address is numeric, so devip's `cs` resolves only names a pattern covers, and records what each one resolved to in the machine's resolved-name table (`NameTable` in `src/policy.zig`, the 1024 most recent entries). A later `connect` to a recorded address is allowed if its name matches a name pattern with the connect's protocol and port.

A Linux program never goes through `cs`. [linux-net](epoch-0/linux-net.md) gives it its own DNS: musl, glibc, c-ares, and Go's resolver read `/etc/resolv.conf` (the root's, or the one `#Letc` supplies, naming the host's DNS servers), send their queries to port 53 on those servers through devip, and connect to the address in the answer. So, under an allowlist with name patterns:

- **The query is refused**, unless a pattern happens to cover the server (`udp!10.0.0.2!53`). Port 53 is allowed to the host's servers only without patterns (spec/abi-linux.md: "`--net-allow` patterns must cover them").
- **If the query is allowed, the connect is refused anyway.** The answer goes straight to the guest, the resolved-name table never hears of it, and the connect by address matches no pattern.

Name patterns are therefore useless to Linux programs, which are most of what h9 runs with an allowlist. h9x, which builds Linux apps with a registry allowlist (`tcp!registry.npmjs.org!443`, `tcp!pypi.org!443`, and the rest) per build phase, has to run its builds with an open network until this is fixed. Behind an HTTPS proxy the allowlist works, because the program connects to the proxy's address and the proxy resolves the name, but that leaves the allowlist checking only the proxy.

[virtual-loopback](virtual-loopback.md) notes the same gap for `host.h9.internal`: a Linux program that resolves with its own DNS client won't find the name, because h9 doesn't see the query.

## Proposal

### When it applies

A machine **resolves for the guest** when its policy has at least one name pattern in `--net-allow`, and `--net` isn't `disable`. Without name patterns (no allowlist, or addresses and ranges only), DNS is unchanged: queries go to whatever server the guest names, under the connect check as today.

### The machine's resolver

A machine that resolves for the guest has a resolver: a UDP socket and a TCP listener that h9 opens on the host's loopback, on ports the host chooses, when the machine starts, and closes when it ends. It belongs to the machine, as the resolved-name table does, so two machines in one process never share one.

**Redirecting port 53.** In devip, a `connect` to port 53 on any address, TCP or UDP, is made to the machine's resolver instead, after its own checks and without the allowlist's. The same goes for a Linux `sendto` to port 53 on an unconnected UDP socket (`h9_linux_socksend` in `src/kern/linuxnet.c`). The conversation's `remote` file, and `getpeername`, still give the address the guest dialled, and a `recvfrom` on a redirected socket gives that address as the source, since musl matches replies by the address it sent to. Everything else about the socket, from readiness and `poll` to non-blocking I/O, is a host socket's, as it is today.

**Answering.** For each query, which is a UDP message or a TCP message with its two-byte length:

1. A message that isn't a query with exactly one question gets `FORMERR`.
2. The question's name, lowercased and without a trailing dot, is checked as `cs` checks one, with `h9_net_lookup`'s rule: it must match a name pattern, for any protocol and port. A name no pattern covers gets `REFUSED`, and is never sent to the host's servers. `localhost` and `host.h9.internal` are answered as [virtual-loopback](virtual-loopback.md)'s `cs` answers them, if that proposal is implemented.
3. An allowed query is forwarded, as it came, to the host's DNS servers (`Machine.Options.nameservers`, in order, over the same transport), and the first answer comes back. If none answers within 5 seconds, the guest gets `SERVFAIL`.
4. Before the answer is passed on, each `A` and `AAAA` record in its answer section whose owner is the question's name, or a name the answer's `CNAME` records lead to from it, is recorded in the resolved-name table under the question's name. Records for other names, and the authority and additional sections, are passed on but not recorded.
5. Every query type is forwarded, so `HTTPS`, `SRV`, `MX`, and `TXT` lookups of an allowed name work, and only `A` and `AAAA` records are recorded. A truncated UDP answer is passed on truncated, and the guest's retry over TCP goes to the resolver's TCP listener.

### Recording without a port

`cs` records a name with the protocol and port of the dial string it translated. A DNS answer has neither, so the resolver's entries match any protocol and port. `NameTable.allows` then checks the recorded name against the patterns with the protocol and port of the `connect` being decided, as it does now. A name allowed as `tcp!api.example.com!443` therefore allows a connect to its address on TCP port 443 only, whichever lookup recorded it.

### The DNS servers' own rule

Under a machine that resolves for the guest, a connect to port 53 never reaches the host's DNS servers directly, so the rule that lets port 53 reach them, even when they're link-local, and the requirement that `--net-allow` cover them, no longer apply there. An address pattern that covers a DNS server (`udp!10.0.0.53!53`) doesn't take its queries out of the resolver either: every query is checked and recorded.

### `--print`

The plan's caveats gain a line when a machine resolves for the guest: "DNS queries to port 53 go to h9's resolver, which forwards names the allowlist covers to the host's DNS servers". The caveat about a Linux program reaching the host's link-local DNS server is left out in that case. `enforces:` is unchanged, since `net.allow` already names the check.

### 9front programs

A 9front program resolves through `cs` and needs none of this. Its own `ndb/dns`, if it runs one, connects to port 53 through devip and gets the machine's resolver like any other program.

## Rationale

**Answer DNS in h9, rather than check connects some other way.** Name patterns need a name at connect time, and only DNS knows which name an address came from. h9 sees every query, because every guest socket is a devip conversation, so answering there needs no help from the guest or its root.

**Forward the query rather than resolve it with the host's `getaddrinfo`.** Building an answer from `getaddrinfo` would lose the record types programs ask for (`HTTPS` and `SRV`, which curl, Go, and Node query), TTLs, and `CNAME` chains, and it would block a host thread per query. Forwarding the guest's own message to the servers it would have used changes nothing the guest sees, except for refused names.

**Redirect every port-53 connect, not only the ones to the host's servers.** A root with its own `/etc/resolv.conf` names its own servers (`8.8.8.8`, or a container's `127.0.0.11`), which the allowlist wouldn't otherwise allow. Taking every port-53 query keeps those roots working and means there's one way out for DNS.

**A host loopback socket rather than an in-kernel conversation.** A resolver on the host's loopback is an ordinary host socket to the guest, so `poll`, `epoll`, `recvfrom`, non-blocking connects, and the host-socket watcher work without new code, and the change in devip is a destination rewrite at connect. An in-kernel conversation, like [virtual-loopback](virtual-loopback.md)'s, would avoid the host socket. If that proposal is implemented, the resolver can move into the kernel and use its queues, without changing what the guest sees.

**Record answers under the question's name, not each record's owner.** The question is what the policy checked, as `cs` checks the dial string's name and not the canonical name `getaddrinfo` follows to. Recording a `CNAME`'s target under its own name would allow a connect only if that name matched a pattern too, which breaks every name served from a CDN.

**Not a DNS server on a reserved address.** Pointing `#Letc`'s `resolv.conf` at an address like 169.254.0.53 would catch only roots without their own `resolv.conf`, and would still need the redirect for the rest.

**Not proxying names (a SOCKS or HTTP proxy in h9).** That would need every program configured to use it, and it doesn't cover programs that ignore proxy settings, such as Node's `fetch` without `NODE_USE_ENV_PROXY`.

## Compatibility

- **CLI flags and exit codes:** none change.
- **`Machine.Options`:** `nameservers` is now also where a machine that resolves for the guest forwards its queries. Each entry may give a port, `ADDR!PORT`, for embedders and tests that run their own server, and the CLI still passes the host's servers on port 53.
- **Sandbox defaults:** the default profile has no allowlist, so it's unchanged. A machine with name patterns now resolves names they cover for Linux programs, and refuses the rest with `REFUSED` rather than a refused connect to port 53, which programs report as a failed lookup either way.
- **Policies with an address pattern for a DNS server:** the pattern still parses and is still honoured for other ports, but port-53 traffic to that server goes through the resolver, which forwards to `nameservers`, not to the server the pattern names. A program that needs a particular server's answers, under name patterns, can't have them. See Open issues.
- **The root tree:** unchanged. `#Letc`'s `resolv.conf` still names the host's servers.
- **`third_party/`:** devip's connect (`third_party/drawterm/kern/devip.c`) gains one hook after `h9_net_check`, `h9_net_redirect`, which may replace the address and port it dials. The rest is in `src/kern/linuxnet.c` and project-owned Zig.

## Security

The guest can newly reach, through the resolver, the host's DNS servers, for names the allowlist covers only. That's what `cs` already gives 9front programs: the host resolves an allowed name on the guest's behalf, and a name pattern trusts the host's resolver for the addresses it returns, as `--print`'s caveat says.

- **Names outside the allowlist** are never sent anywhere. The guest can't use DNS to make the host resolve, or leak data through, a name no pattern covers.
- **Subdomains of a wildcard pattern** can be queried freely, so `tcp!*.example.com!443` lets the guest send data to example.com's DNS servers in query names. That's true of `cs` today, and it's the meaning of a wildcard.
- **The resolver's sockets** are on the host's loopback, where other host processes can reach them. They answer only names the machine's allowlist covers, from servers the host already uses, so another process learns nothing it couldn't ask the host's resolver for. devip tells the resolver the host port of each conversation it redirects, and the resolver records answers only for those, so a host process can't add entries to the machine's table.
- **The resolved-name table** gains entries from DNS answers, each limited by the patterns at connect time as now. A guest that floods it with lookups of allowed names only evicts its own entries.
- **Answers are passed on as the server sent them.** h9 parses them only to record addresses, with bounds checks on every name and record, and a message it can't parse is passed on unrecorded.

## Done criteria

- [ ] `test "a Linux program's lookup of an allowed name connects [linux-dns]"` passes: a Linux root, `--net-allow` naming a name the test's stub DNS server answers with a local listener's address, and `wget` or `nc` reaching the listener by name.
- [ ] `test "a name outside --net-allow gets REFUSED, and isn't forwarded [linux-dns]"` passes: the stub server sees no query.
- [ ] `test "a connect by address without a lookup is refused [linux-dns]"` passes.
- [ ] `test "a CNAME's addresses are recorded under the question's name [linux-dns]"` passes.
- [ ] `test "a truncated answer retries over TCP through the resolver [linux-dns]"` passes.
- [ ] `test "a root's own resolv.conf server is redirected too [linux-dns]"` passes.
- [ ] `test "without name patterns, port 53 isn't redirected [linux-dns]"` passes.
- [ ] `test "--print shows the resolver caveat [linux-dns]"` passes.
- [ ] The backends' cases pass with a stub server given through `Machine.Options.nameservers` as `127.0.0.1!PORT`.
- [ ] h9x builds Railpack's node-npm example with its registry allowlist and no proxy.
- [ ] spec/sandbox.md and spec/abi-linux.md describe the resolver, and MANUAL.md's `--net-allow` section says name patterns work for Linux programs.

## Implementation

1. `NameTable` entries with no protocol or port, and `allows` matching them against the connect's.
2. The resolver in Zig: the per-machine UDP socket and TCP listener, a host thread that answers them, the message checks, forwarding, and recording. It's unit-tested against canned messages.
3. `h9_net_redirect` in devip's connect, and the `sendto` and `recvfrom` rewrites in `src/kern/linuxnet.c`.
4. `nameservers` with ports, the `--print` caveat, and the integration and backend cases with a stub server.
5. The spec and MANUAL.md.

## Open issues

- **Policies that name a DNS server.** Should an address pattern covering a server on port 53 send that server's queries to it directly, through the resolver's checks, rather than to `nameservers`? That keeps a split-horizon server reachable, at the cost of forwarding to an address the guest chose.
- **DNS over TLS and HTTPS.** A program that resolves over port 853, or over HTTPS to a public resolver, bypasses this, and its connects are refused unless a pattern covers the resolver. Refusing them is the safe result, but it may surprise users of Firefox-like clients.
- **The table's size.** 1024 entries may not hold every name a large build resolves. Entries could expire by TTL instead of by count.
