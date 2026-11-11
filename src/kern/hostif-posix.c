/*
 * h9: the host's interface addresses for the Linux layer's netlink
 * (src/kern/hostsock.h, design/linux-net.md). Kept apart from
 * hostsock-posix.c because getifaddrs's headers and drawterm's don't
 * mix.
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <string.h>

#include "hostsock.h"

static int
prefixlen(const unsigned char *m, int n)
{
	int i, b;
	unsigned char c;

	b = 0;
	for(i = 0; i < n; i++){
		if(m[i] == 0xff){
			b += 8;
			continue;
		}
		for(c = m[i]; c & 0x80; c <<= 1)
			b++;
		break;
	}
	return b;
}

int
h9so_ifaddrs(H9ifaddr *a, int max)
{
	static const unsigned char v4mapped[12] = {0,0,0,0,0,0,0,0,0,0,0xff,0xff};
	struct ifaddrs *ifs, *i;
	H9ifaddr *o;
	int n;

	if(getifaddrs(&ifs) < 0)
		return 0;
	n = 0;
	for(i = ifs; i != NULL && n < max; i = i->ifa_next){
		if(i->ifa_addr == NULL)
			continue;
		o = &a[n];
		memset(o, 0, sizeof *o);
		switch(i->ifa_addr->sa_family){
		case AF_INET:
			memcpy(o->addr, v4mapped, 12);
			memcpy(o->addr+12, &((struct sockaddr_in*)i->ifa_addr)->sin_addr, 4);
			o->prefix = 32;
			if(i->ifa_netmask != NULL)
				o->prefix = prefixlen((unsigned char*)&((struct sockaddr_in*)i->ifa_netmask)->sin_addr, 4);
			break;
		case AF_INET6:
			memcpy(o->addr, &((struct sockaddr_in6*)i->ifa_addr)->sin6_addr, 16);
			o->prefix = 128;
			if(i->ifa_netmask != NULL)
				o->prefix = prefixlen((unsigned char*)&((struct sockaddr_in6*)i->ifa_netmask)->sin6_addr, 16);
			break;
		default:
			continue;
		}
		strncpy(o->name, i->ifa_name, sizeof o->name - 1);
		o->index = if_nametoindex(i->ifa_name);
		o->isup = (i->ifa_flags & IFF_UP) != 0;
		o->loopback = (i->ifa_flags & IFF_LOOPBACK) != 0;
		o->mtu = o->loopback ? 65536 : 1500;
		n++;
	}
	freeifaddrs(ifs);
	return n;
}
