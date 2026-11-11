/*
 * #H: h9's own commands for the guest (design/guest-tools.md), a
 * read-only tree built into the h9 binary from src/guest/. The namespace
 * builder binds #H/bin after /bin, so anything the root has of the same
 * name wins.
 *
 * The table comes from one leaf, h9_tools_table (src/kern.zig), called
 * once at reset. After that this is plain C over constant memory and never
 * calls into Zig. An entry's index is its qid path, so qids are the same
 * on every run of one h9 build. Entry 0 is the top directory, and every
 * entry comes after its parent.
 *
 * The attach spec "root" serves a second table the same way: the
 * built-in root (design/builtin-root.md), multicall's 9front commands and
 * the directories h9 binds onto. A channel's dev is the table it's on, so
 * the two trees' qids, which overlap, never compare equal as mount points.
 *
 * Writes, creates, removes and wstats fail with "permission denied".
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

/* As src/kern.zig's Htool. */
typedef struct Htool Htool;
struct Htool
{
	char	*name;
	u32int	parent;
	u32int	mode;	/* DMDIR|0555, 0555 or 0444; 0775 and 0664 in the root */
	uchar	*data;
	u32int	len;
};

/* Implemented in Zig (src/kern.zig). */
extern Htool *h9_tools_table(int *n);
extern Htool *h9_root_table(int *n);

enum
{
	Ttools,	/* #H: guest-tools' scripts */
	Troot,	/* #Hroot: the built-in root */
	Ntab,
};

static Htool *tabs[Ntab];
static int ntabs[Ntab];

/* The table c is on, by its dev, and its length. */
#define TAB(c)	tabs[(c)->dev < Ntab ? (c)->dev : Ttools]
#define NTAB(c)	ntabs[(c)->dev < Ntab ? (c)->dev : Ttools]

static void
htoolsreset(void)
{
	tabs[Ttools] = h9_tools_table(&ntabs[Ttools]);
	tabs[Troot] = h9_root_table(&ntabs[Troot]);
}

static void
mkentry(Chan *c, int i, Dir *dp)
{
	Qid q;
	Htool *t;

	t = &TAB(c)[i];
	mkqid(&q, i, 0, (t->mode & DMDIR) ? QTDIR : QTFILE);
	devdir(c, q, i == 0 ? (c->dev == Troot ? "/" : "#H") : t->name, (t->mode & DMDIR) ? 0 : t->len, up->user, t->mode & ~DMDIR, dp);
}

/*
 * Lists a directory's children as s goes up, or finds one by name, as
 * devwalk and devdirread expect.
 */
static int
htoolsgen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	int i;
	ulong d;

	Htool *tools;

	USED(tab, ntab);
	tools = TAB(c);
	d = c->qid.path;
	if(d >= NTAB(c))
		return -1;
	if(s == DEVDOTDOT){
		mkentry(c, tools[d].parent, dp);
		return 1;
	}
	for(i = 1; i < NTAB(c); i++){
		if(tools[i].parent != d)
			continue;
		if(name != nil ? strcmp(tools[i].name, name) == 0 : s-- == 0){
			mkentry(c, i, dp);
			return 1;
		}
	}
	return -1;
}

static Chan*
htoolsattach(char *spec)
{
	Chan *c;
	int t;

	if(*spec == 0)
		t = Ttools;
	else if(strcmp(spec, "root") == 0)
		t = Troot;
	else
		error(Ebadspec);
	if(ntabs[t] == 0)
		error(Enonexist);
	c = devattach('H', spec);
	c->dev = t;
	return c;
}

static Walkqid*
htoolswalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, htoolsgen);
}

static int
htoolsstat(Chan *c, uchar *db, int n)
{
	Dir d;

	if(c->qid.path >= NTAB(c))
		error(Enonexist);
	mkentry(c, c->qid.path, &d);
	n = convD2M(&d, db, n);
	if(n == 0)
		error(Ebadarg);
	return n;
}

static Chan*
htoolsopen(Chan *c, int omode)
{
	if(omode & (OTRUNC|ORCLOSE))
		error(Eperm);
	switch(omode & 3){
	case OREAD:
	case OEXEC:
		break;
	default:
		error(Eperm);
	}
	if((c->qid.type & QTDIR) && (omode & 3) != OREAD)
		error(Eperm);
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
htoolsclose(Chan *c)
{
	USED(c);
}

static long
htoolsread(Chan *c, void *va, long n, vlong off)
{
	Htool *t;

	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, nil, 0, htoolsgen);
	if(c->qid.path >= NTAB(c))
		error(Enonexist);
	t = &TAB(c)[c->qid.path];
	if(off < 0)
		error(Ebadarg);
	if(off >= t->len)
		return 0;
	if(n > t->len - off)
		n = t->len - off;
	memmove(va, t->data + off, n);
	return n;
}

static long
htoolswrite(Chan *c, void *va, long n, vlong off)
{
	USED(c, va, n, off);
	error(Eperm);
	return 0;
}

static void
htoolsremove(Chan *c)
{
	USED(c);
	error(Eperm);
}

static int
htoolswstat(Chan *c, uchar *db, int n)
{
	USED(c, db, n);
	error(Eperm);
	return 0;
}

Dev htoolsdevtab = {
	'H',
	"htools",

	htoolsreset,
	devinit,
	devshutdown,
	htoolsattach,
	htoolswalk,
	htoolsstat,
	htoolsopen,
	devcreate,
	htoolsclose,
	htoolsread,
	devbread,
	htoolswrite,
	devbwrite,
	htoolsremove,
	htoolswstat,
};
