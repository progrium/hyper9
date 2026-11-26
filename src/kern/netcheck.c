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

int
h9_net_redirect(int proto, uchar *addr, int *port, int *sfd, int *opts)
{
	uchar orig[IPaddrlen];
	int oport, r;

	memmove(orig, addr, IPaddrlen);
	oport = *port;
	r = h9_dns_target(proto, addr, port);
	if(r <= 0)
		return r;
	/* Made for the resolver's address, so it's an IPv4 socket whatever the guest dialled. */
	if(*sfd == -1)
		*sfd = h9so_socket(proto, addr, opts);
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
