/*
 * h9's sandbox hooks for devip (design/epoch-0/net-policy.md). The leaves
 * are in Zig (src/kern.zig): each returns a verdict and raises no kernel
 * error; devip raises "permission denied" or "no translation for host
 * found" itself. The operations match policy.NetOp, and proto is devip's
 * S_TCP or S_UDP (policy.NetProto); any other value is refused when
 * --net-allow patterns are given.
 */
enum {
	H9_NETCONNECT = 0,
	H9_NETANNOUNCE = 1,
};

/*
 * 0 if allowed, -1 if not. addr is IPaddrlen bytes. 1 for a UDP connect
 * allowed only as a route probe (design/linux-dns.md, Updates): to an
 * address the resolved-name table recorded for an allowed name. It is
 * made on the host, but h9_net_redirect marks the conversation's host
 * socket probe-only, and h9_net_send refuses its sends; a sendto's own
 * check takes only 0.
 */
int	h9_net_check(int op, int proto, uchar *addr, int port);
/* 0 if host socket sfd may send, -1 if it's a probe-only conversation's. */
int	h9_net_send(int sfd);
/* Forgets sfd's probe mark; h9so_close calls it before it closes sfd. */
void	h9_net_closed(int sfd);
/* 0 if cs may resolve this name for proto and port, -1 if not. */
int	h9_net_lookup(int proto, char *name, int port);
/* Records the addresses cs resolved for an allowed name. */
void	h9_net_resolved(int proto, char *name, int port, uchar (*addrs)[IPaddrlen], int n);
/* cs's protocol name as S_TCP or S_UDP, or -1 (src/kern/netcheck.c). */
int	h9_net_proto(char *name);

/*
 * The machine's resolver (design/linux-dns.md). Under an allowlist with
 * a name pattern, a connect to port 53 passes h9_net_check and goes to
 * the resolver instead: devip's connect calls h9_net_redirect, which
 * rewrites addr and *port to the resolver's on the host's loopback,
 * binds the conversation's host socket there first (making it in *sfd
 * with opts if it has none) and tells the resolver its host port. 1 if
 * redirected, 0 if not, -1 if it would be and can't be, which refuses
 * the connect. A UDP connect that isn't redirected is marked
 * probe-only or not, as h9_net_check says, making its socket first for
 * a probe.
 */
int	h9_net_redirect(int proto, uchar *addr, int *port, int *sfd, int *opts);
/* h9_net_redirect for a sendto on host socket sfd (src/kern/linuxnet.c). */
int	h9_net_redirectto(int proto, int sfd, uchar *addr, int *port);
/* Gives a reply from the resolver on sfd the address the guest dialled. */
void	h9_net_unredirect(int proto, int sfd, uchar *addr, ushort *port);

/* The Zig leaves behind them (src/kern.zig). */
int	h9_dns_target(int proto, uchar *addr, int *port);
void	h9_dns_register(int proto, int lport, uchar *orig, int oport);
int	h9_dns_peer(int proto, int lport, uchar *addr, ushort *port);
int	h9_dns_self(int proto, uchar *addr, int port);
