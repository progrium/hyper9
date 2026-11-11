/*
 * h9's sandbox hooks for devip (design/net-policy.md). The leaves
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

/* 0 if allowed, -1 if not. addr is IPaddrlen bytes. */
int	h9_net_check(int op, int proto, uchar *addr, int port);
/* 0 if cs may resolve this name for proto and port, -1 if not. */
int	h9_net_lookup(int proto, char *name, int port);
/* Records the addresses cs resolved for an allowed name. */
void	h9_net_resolved(int proto, char *name, int port, uchar (*addrs)[IPaddrlen], int n);
/* cs's protocol name as S_TCP or S_UDP, or -1 (src/kern/netcheck.c). */
int	h9_net_proto(char *name);
