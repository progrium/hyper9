/*
 * The C side of h9's devcons hooks (src/kern/consx.h), in 9front's
 * formats (port/devcons.c at the pinned release).
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "consx.h"

extern ulong	h9_kern_gpid(void);
extern ulong	h9_kern_gppid(void);

enum
{
	VLNUMSIZE	= 22,
	Fasthz		= 1000000000,	/* ticks are nanoseconds */
	Maxcpus		= 1024,
};

/* A number right-justified in size-1 characters and a space, as 9front's readnum. */
static long
readnum9(ulong off, char *buf, long n, ulong val, int size)
{
	char tmp[64];

	snprint(tmp, sizeof tmp, "%*lud", size-1, val);
	tmp[size-1] = ' ';
	if(off >= size)
		return 0;
	if(off+n > size)
		n = size-off;
	memmove(buf, tmp+off, n);
	return n;
}

static long
readstr9(ulong off, char *buf, long n, char *str)
{
	long size;

	size = strlen(str);
	if(off >= size)
		return 0;
	if(off+n > size)
		n = size-off;
	memmove(buf, str+off, n);
	return n;
}

long
h9_cons_pid(ulong off, char *buf, long n)
{
	return readnum9(off, buf, n, h9_kern_gpid(), NUMSIZE);
}

long
h9_cons_ppid(ulong off, char *buf, long n)
{
	return readnum9(off, buf, n, h9_kern_gppid(), NUMSIZE);
}

static void
vlong2be(uchar *t, uvlong v)
{
	int i;

	for(i = 7; i >= 0; i--){
		t[i] = v;
		v >>= 8;
	}
}

/*
 * Wall nanoseconds, ticks, fasthz and monotonic nanoseconds, big-endian;
 * a short read gets the leading words that fit. Ticks are the monotonic
 * nanoseconds, so fasthz is 10⁹.
 */
long
h9_cons_bintime(char *buf, long n)
{
	uchar *b;
	vlong wall, mono;
	long i;

	b = (uchar*)buf;
	wall = h9_clock_wall();
	mono = h9_clock_mono();
	i = 0;
	if(n >= 4*8){
		vlong2be(b+3*8, mono);
		i += 8;
	}
	if(n >= 3*8){
		vlong2be(b+2*8, Fasthz);
		i += 8;
	}
	if(n >= 2*8){
		vlong2be(b+8, mono);
		i += 8;
	}
	if(n >= 8){
		vlong2be(b, wall);
		i += 8;
	}
	return i;
}

/* secs nanosecs fastticks fasthz, as drawterm's readtime lays them out. */
long
h9_cons_time(ulong off, char *buf, long n)
{
	char str[7*NUMSIZE];
	vlong wall;

	wall = h9_clock_wall();
	snprint(str, sizeof str, "%*.0lud %*.0llud %*.0llud %*.0llud ",
		NUMSIZE-1, (ulong)(wall/1000000000LL),
		VLNUMSIZE-1, wall,
		VLNUMSIZE-1, h9_clock_mono(),
		VLNUMSIZE-1, (vlong)Fasthz);
	return readstr9(off, buf, n, str);
}

/*
 * One line per CPU in 9front's layout: ten NUMSIZE columns (id, context
 * switches, interrupts, syscalls, page faults, TLB faults, TLB purges,
 * load, idle and interrupt percentages) and a newline. h9 keeps none of
 * the counters, so they're zero. Lines are made on the fly, so a read at
 * any offset sees the same file without allocating it.
 */
long
h9_cons_sysstat(ulong off, char *buf, long n)
{
	enum { Line = 10*NUMSIZE + 1 };
	char line[Line];
	ulong id, ncpu, size, o, m;
	long done;
	int j;

	ncpu = h9_cons_ncpu();
	if(ncpu < 1)
		ncpu = 1;
	if(ncpu > Maxcpus)
		ncpu = Maxcpus;
	size = ncpu*Line;
	done = 0;
	while(n > 0 && off < size){
		id = off/Line;
		o = off%Line;
		readnum9(0, line, NUMSIZE, id, NUMSIZE);
		for(j = 1; j < 10; j++)
			readnum9(0, line+j*NUMSIZE, NUMSIZE, 0, NUMSIZE);
		line[Line-1] = '\n';
		m = Line-o;
		if(m > n)
			m = n;
		memmove(buf+done, line+o, m);
		done += m;
		off += m;
		n -= m;
	}
	return done;
}
