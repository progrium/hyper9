/*
 * h9: the host-socket calls devip's h9 additions use (hostsock-posix.c,
 * hostsock-win32.c), for the Linux socket calls
 * (design/0050-linux-net.md). They raise kernel errors as devip's so_
 * calls do.
 */

enum {
	H9optnodelay,
	H9optkeepalive,
	H9optkeepidle,
	H9optkeepintvl,
	H9optkeepcnt,
	H9optreuseaddr,
	H9optrcvbuf,
	H9optsndbuf,
	H9optv6only,
	H9nopt,

	H9optset = 1<<30,	/* an option's slot holds value|H9optset once set */
};

/* so_socket, then the options set so far. */
int	h9so_socket(int type, unsigned char *addr, int *opts);
/* Starts a connect; 0 if it completed at once, 1 if it's in progress. */
int	h9so_connect_nb(int fd, unsigned char *raddr, unsigned short rport);
/* how is "rd", "wr" or "rdwr". */
void	h9so_shutdown(int fd, char *how);
/*
 * Closes a socket devip made. On Windows that's closesocket: the C
 * library's close doesn't take a socket, so the connection stayed open
 * until h9 exited, and Windows then reset it.
 */
void	h9so_close(int fd);
/* Records option name (nodelay, keepalive, ...) and applies it if fd >= 0. */
void	h9so_setopt(int fd, int *opts, char *name, int val);
/* Whether the host can make IPv6 sockets. */
int	h9so_hasv6(void);

/*
 * The host's interface addresses, for the Linux layer's netlink
 * (design/0050-linux-net.md): up to max, loopback included; the count.
 * addr is devip's 16 bytes, v4 mapped. 0 where the host can't say.
 * In hostif-posix.c, apart from drawterm's headers.
 */
typedef struct H9ifaddr H9ifaddr;
struct H9ifaddr {
	char		name[16];
	int		index;
	int		isup;
	int		loopback;
	int		mtu;
	unsigned char	addr[16];
	int		prefix;
};
int	h9so_ifaddrs(H9ifaddr *a, int max);

/* For src/kern/linuxnet.c; these don't raise errors. */
/* poll(2) bits that are ready on fd now (0 timeout); bits from POLLIN, POLLOUT, POLLERR, POLLHUP, POLLRDHUP. */
int	h9so_ready(int fd, int events);
/* The socket's pending error (SO_ERROR), as a Linux errno, and clears it. */
int	h9so_soerror(int fd);
/*
 * recvfrom and sendto with Linux's MSG_PEEK and MSG_DONTWAIT; -errno
 * (Linux's) on failure. Addresses are devip's: 16 bytes, v4 mapped. A
 * nil raddr receives without the source, or sends to the peer.
 */
long	h9so_recvfrom(int fd, void *buf, long n, int peek, int dontwait, unsigned char *raddr, unsigned short *rport);
long	h9so_sendto(int fd, void *buf, long n, int dontwait, unsigned char *raddr, unsigned short rport);

/* The watcher: wakes pollers when one of the sockets they wait on is ready. */
void	h9so_watchinit(void);
void	h9_kprocdetach(void);	/* proc.c */
void	h9so_watch(int fd, int events, void *owner);
void	h9so_unwatch(void *owner);

/* Linux errno values for host ones (they differ on macOS and Windows). */
int	h9so_linuxerrno(int hosterr);
