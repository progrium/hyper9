/*
 * The C side of devip's sandbox hooks (src/kern/netcheck.h). The policy
 * itself, and the machine's resolved-name table, are in Zig.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "ip.h"
#include "devip.h"
#include "netcheck.h"
#include "hostsock.h"

int
h9_net_proto(char *name)
{
	if(strcmp(name, "tcp") == 0)
		return S_TCP;
	if(strcmp(name, "udp") == 0)
		return S_UDP;
	return -1;
}

/*
 * The host port of sfd, bound to addr (the resolver's loopback) if it has
 * none. A socket that isn't bound has port 0 on POSIX hosts, but on
 * Windows getsockname fails on it (WSAEINVAL), so a failure is port 0 too.
 */
static int
dnslport(int sfd, uchar *addr)
{
	uchar laddr[IPaddrlen];
	ushort lport;

	lport = 0;
	if(!waserror()){
		so_getsockname(sfd, laddr, &lport);
		poperror();
	}
	if(lport == 0){
		so_bind(sfd, 0, 0, addr);
		so_getsockname(sfd, laddr, &lport);
	}
	return lport;
}

/*
 * The host sockets of probe-only UDP conversations (design/linux-dns.md,
 * Updates). getaddrinfo ranks its answers by connecting a UDP socket to
 * each address, which sends nothing, and reading its source address, so
 * a connect to an address recorded for an allowed name is made on the
 * host whatever its port, and its socket is marked here: devip's write
 * and the Linux layer's send refuse to send on it. Host sockets are the
 * process's, so one table serves every machine. The mark is set or
 * cleared at each connect, and cleared by h9so_close before the socket
 * is closed, so a later socket with the same number starts unmarked.
 */
enum {
	Nprobe = 1024,
};

static struct {
	Lock	lk;
	int	fd[Nprobe];
	int	n;
} probes;

static int
probeslot(int sfd)
{
	int i;

	for(i = 0; i < probes.n; i++)
		if(probes.fd[i] == sfd)
			return i;
	return -1;
}

/* Marks or unmarks sfd; -1 if there's no room to mark it. */
static int
probemark(int sfd, int on)
{
	int i, r;

	r = 0;
	lock(&probes.lk);
	i = probeslot(sfd);
	if(on && i < 0){
		if(probes.n < Nprobe)
			probes.fd[probes.n++] = sfd;
		else
			r = -1;
	}else if(!on && i >= 0)
		probes.fd[i] = probes.fd[--probes.n];
	unlock(&probes.lk);
	return r;
}

int
h9_net_send(int sfd)
{
	int i;

	if(sfd == -1)
		return 0;
	lock(&probes.lk);
	i = probeslot(sfd);
	unlock(&probes.lk);
	return i < 0 ? 0 : -1;
}

void
h9_net_closed(int sfd)
{
	if(sfd != -1)
		probemark(sfd, 0);
}

/*
 * A UDP connect that isn't redirected: marks its socket probe-only if
 * h9_net_check allowed it only as a probe, making the socket first so
 * there's one to mark, and unmarks it otherwise, since a conversation
 * may connect again. -1 refuses the connect.
 */
static int
probe(int proto, uchar *addr, int port, int *sfd, int *opts)
{
	if(proto != S_UDP)
		return 0;
	if(h9_net_check(H9_NETCONNECT, proto, addr, port) <= 0){
		if(*sfd != -1)
			probemark(*sfd, 0);
		return 0;
	}
	if(*sfd == -1)
		*sfd = h9so_socket(proto, addr, opts);
	return probemark(*sfd, 1);
}

int
h9_net_redirect(int proto, uchar *addr, int *port, int *sfd, int *opts)
{
	uchar orig[IPaddrlen];
	int oport, r;

	memmove(orig, addr, IPaddrlen);
	oport = *port;
	r = h9_dns_target(proto, addr, port);
	if(r == 0)
		return probe(proto, addr, *port, sfd, opts);
	if(r < 0)
		return r;
	/* Made for the resolver's address, so it's an IPv4 socket whatever the guest dialled. */
	if(*sfd == -1)
		*sfd = h9so_socket(proto, addr, opts);
	probemark(*sfd, 0);
	h9_dns_register(proto, dnslport(*sfd, addr), orig, oport);
	return 1;
}

int
h9_net_redirectto(int proto, int sfd, uchar *addr, int *port)
{
	uchar orig[IPaddrlen];
	int oport, r;

	memmove(orig, addr, IPaddrlen);
	oport = *port;
	r = h9_dns_target(proto, addr, port);
	if(r <= 0)
		return r;
	if(waserror())
		return -1;
	h9_dns_register(proto, dnslport(sfd, addr), orig, oport);
	poperror();
	return 1;
}

void
h9_net_unredirect(int proto, int sfd, uchar *addr, ushort *port)
{
	uchar laddr[IPaddrlen];
	ushort lport;

	if(!h9_dns_self(proto, addr, *port))
		return;
	if(waserror())
		return;
	so_getsockname(sfd, laddr, &lport);
	poperror();
	h9_dns_peer(proto, lport, addr, port);
}
