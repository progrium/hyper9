/*
 * #O: copy-on-write overlays (design/epoch-0/ephemeral-writes.md).
 *
 * An instance is a tree in memory, optionally above a lower directory
 * (a chan of another device, usually #U). Walks look in memory first and
 * fall through to the lower tree, whose own checks (devfs's h9_fs_check,
 * --read-deny, symlink resolution) apply. Creates, writes, removes and
 * renames land in memory: a lower file is copied up whole the first time
 * it's changed, and a removed lower name is hidden by a whiteout. The
 * lower tree is never written.
 *
 * Each node in the memory tree is one of:
 *	Ncopy	a file or directory that exists in memory, with its own data
 *		and Dir; a copied directory has nothing beneath it in the lower
 *		tree
 *	Nwhite	a name removed from the lower tree
 *	Nmark	a lower directory with changed children in memory; its Dir is
 *		a snapshot of the lower one's and its qid is the lower qid
 *	Nlink	a symbolic link made by the Linux ABI (h9_overlay_symlink),
 *		holding its target. A walk follows it, as devfs follows a contained
 *		tree's links: an absolute target from the instance root, a
 *		relative one from the link's directory. The chan keeps the link
 *		beside the target, so remove and rename act on the link, and
 *		h9_overlay_readlink reads it. A final link whose target is
 *		missing is walked to as itself, and opening it fails. Its qid
 *		has H9_QTSYMLINK. A Linux process's walk doesn't follow it,
 *		or a lower tree's link: it stops there, for the kernel's walk
 *		to follow from the process's root (design/epoch-0/linux-symlinks.md).
 *	Nfifo	a FIFO made by the Linux ABI (h9_overlay_mkfifo,
 *		design/epoch-0/linux-fifo.md): a file with no data, whose Dir has
 *		H9_DMFIFO. A Linux open of it joins a pipe (src/kern/fifo.c);
 *		a Plan 9 program reads it as empty and can't write it.
 *
 * Memory: data blocks, nodes, names and strings all come from the
 * machine's guest-physical page allocator through Zig leaves
 * (h9_overlay_alloc, src/kern.zig), so they count against --memory. Data
 * is a list of page-sized blocks. Nodes and strings come from a small
 * size-class allocator on the same pages, which returns its pages when the
 * instance is freed. Running out fails the operation with "file system
 * full" and changes nothing.
 *
 * Instances are made by the namespace builder (h9_overlay_new, or
 * h9_overlay_newpath from Zig) and bound with `bind '#O<n>' target`.
 * Attaching checks that the instance belongs to the caller's machine, so
 * machines in one host process can't reach each other's. The last close
 * of the last chan on an instance frees it.
 *
 * Tracking: once h9_overlay_track gives an instance a tracker, each
 * create, copy-up, remove and wstat calls h9_overlay_changed with the
 * changed path, for the root overlay's discarded-changes notice
 * (design/epoch-0/overlay.md). Writes to a file already in memory aren't
 * reported again: its create or copy-up was.
 *
 * Locking: each instance's tree is guarded by its QLock, held across
 * lower-device calls made for walks, copy-ups and directory reads. The
 * instance table is guarded by a Lock, which also guards instance
 * reference counts.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"
#include "fscheck.h"
#include "devx.h"

/* Implemented in Zig (src/kern.zig). They never raise kernel errors. */
extern void *h9_overlay_pool(void);
extern void *h9_overlay_alloc(void *pool, ulong n);
extern void h9_overlay_free(void *pool, void *p, ulong n);
extern void h9_overlay_changed(void *track, char *path);
/* src/kern/fscheck.c */
extern void *h9_plan_get(void);
/* The device switch's optional operations, which raise (src/kern/syswide.zig). */
extern int devreadlink(Chan*, char*, int);
extern void devsymlink(Chan*, char*, char*);
extern int devrename(Chan*, Chan*, char*);
extern void devgetattr(Chan*, uvlong, Attr*);
extern int h9_fs_linkwalk(void);
extern vlong h9_clock_mono(void);

enum
{
	Pgsize	= 4096,		/* engine.page_size */
	Ndirect	= 8,		/* data blocks held in the node */
	Perpage	= Pgsize/sizeof(void*),
	Minclass	= 5,	/* 32 bytes */
	Nclass	= 7,		/* 32..2048 */
	Pghdr	= 16,		/* per-page header of the small allocator */
	Maxname	= 1024,
	Maxinst	= 256,
	Copybuf	= 16*Pgsize,

	Ncopy	= 0,
	Nwhite,
	Nmark,
	Nlink,
	Nfifo,

	Maxlinks	= 40,	/* links followed in one walk, as Linux allows */
};

#define Maxfile	((vlong)(Ndirect + Perpage*Perpage) * Pgsize)
#define Copybit	(1ULL<<63)

static char Efull[] = "file system full";
static char Enotempty[] = "directory not empty";
static char Elocked[] = "file is locked";	/* ramfs's */

typedef struct Inst Inst;
typedef struct Node Node;
typedef struct Ovc Ovc;
typedef struct Pg Pg;
typedef struct Chunk Chunk;
typedef struct Member Member;
typedef struct Qmap Qmap;
typedef struct Unc Unc;
typedef struct Wce Wce;
typedef struct Wcache Wcache;

enum
{
	Cow	= 0,
	Union,

	Maxmembers	= 64,
	Qbuckets	= 256,
};

/* A union's member: a tree, rooted at a path in the union. */
struct Member
{
	int	id;
	Chan	*root;
	char	*at;		/* "" for the union's top, or a path such as "etc" */
	int	create;		/* creates may go here (bind -c) */
	int	isup;		/* the writable layer over the others (bind -u); only ever mem[0] */
};

struct Qmap
{
	Qmap	*next;
	int	type;
	int	dev;
	uvlong	path;
	uvlong	qpath;
};

struct Pg
{
	Pg	*next;
};

struct Chunk
{
	Chunk	*next;
};

struct Node
{
	int	kind;
	int	ref;		/* chans holding it, plus 1 while it's in the tree */
	int	inlower;	/* the lower tree has this name here */
	Node	*parent;	/* nil once detached */
	Node	*child;
	Node	*next;
	Node	*prev;	/* in the parent's child list, for unlinking in O(1) */
	Node	*hnext;	/* in the parent's hash chain */
	Node	**htab;	/* a directory's children by name, once it has many; host memory */
	int	hsize;
	int	nchild;
	char	*name;
	char	*uid;
	char	*gid;
	char	*muid;
	Qid	qid;
	ulong	mode;
	ulong	atime;
	ulong	mtime;
	vlong	length;
	uchar	*direct[Ndirect];
	uchar	***ind;		/* Perpage pointers to pages of Perpage block pointers */
	char	*link;		/* an Nlink's target */
	int	excl;		/* a DMEXCL file that a chan has open */
};

struct Inst
{
	int	id;
	int	ref;		/* under instlock */
	int	pinned;		/* made, not attached yet: the first attach takes this ref */
	void	*pool;
	QLock	ql;
	Chan	*lower;		/* root of the lower tree, or nil */
	Node	*root;
	uvlong	qidgen;
	Pg	*pages;		/* the small allocator's pages */
	Chunk	*free[Nclass];
	void	*track;	/* told of each change once set (h9_overlay_track), or nil */

	/* Unions (design/epoch-0/mounts.md, "Union instances"); see below. */
	int	mode;		/* Cow or Union */
	char	name[16];	/* a named union's name ("root", "linux"), or "" */
	Inst	*cow;		/* a named union's copy-on-write instance over it, not counted in ref */
	Inst	*over;		/* a cow instance's named union, which points back here */
	Member	*mem;		/* the members, top first; host memory */
	int	nmem;
	int	memgen;		/* the next member's id */
	Qmap	**qtab;		/* (device, dev, qid path) to the instance's qid path */
	ulong	qmem;		/* bytes of qid table and snapshots, counted against the pool */
	QLock	upql;		/* serializes changes to an up member's tree (design/epoch-0/upper-layers.md) */
	ulong	upgen;		/* counts directories made in the up member's tree; under ql */
	QLock	wcl;		/* the walk cache's lock */
	Wcache	*wc;		/* the walk cache (unstep), made on first use; under wcl */
};

/* A chan's state. */
struct Ovc
{
	Inst	*inst;
	Node	*node;		/* with a ref, or nil for a lower-only name */
	Chan	*lower;		/* the lower chan for this name, or nil */
	char	*path;		/* names from the instance root, '/'-separated */
	int	lopen;		/* lower is open; I/O goes to it */
	uchar	*dir;		/* directory snapshot */
	long	ndir;
	Node	*lnk;		/* with a ref: the link the walk's last name followed, or nil */
	char	*lpath;		/* lnk's path */
	int	excl;		/* this chan holds node's DMEXCL open */
	int	nlinks;		/* links followed in this walk */
};

/* A union chan's state. Its first field is the instance, as an Ovc's is. */
struct Unc
{
	Inst	*inst;
	char	*path;		/* names from the union's top */
	int	n;		/* members with this name */
	Chan	*mc[Maxmembers];	/* their chans: one for a file, each one's directory for a directory */
	int	mid[Maxmembers];	/* their member ids */
	int	mcreate[Maxmembers];
	int	lopen;		/* mc[0] is open; file I/O goes to it */
	uchar	*dir;		/* directory snapshot, from the pool */
	long	ndir;
	long	dircap;
	int	noup;		/* walks leave out the up member: what's below the layer */
	ulong	upseen;		/* the instance's upgen when the members were found */
};


static int
isunion(Chan *c)
{
	Ovc *o;

	o = c->aux;
	return o != nil && o->inst->mode == Union;
}

static Lock instlock;
static Inst *insts[Maxinst];
static int nextid;

/*
 * Pages and the small allocator.
 */

static void*
pgalloc(Inst *in)
{
	return h9_overlay_alloc(in->pool, Pgsize);
}

static void
pgfree(Inst *in, void *p)
{
	if(p != nil)
		h9_overlay_free(in->pool, p, Pgsize);
}

static int
sizeclass(ulong n)
{
	int c;

	for(c = 0; c < Nclass; c++)
		if(n <= (1UL<<(Minclass+c)))
			return c;
	return -1;
}

/* Zeroed memory for bookkeeping, or nil when the machine's memory is used up. */
static void*
ovmalloc(Inst *in, ulong n)
{
	int c;
	ulong sz, off;
	uchar *p;
	Chunk *k;

	c = sizeclass(n);
	if(c < 0)
		return nil;
	sz = 1UL<<(Minclass+c);
	if(in->free[c] == nil){
		p = pgalloc(in);
		if(p == nil)
			return nil;
		((Pg*)p)->next = in->pages;
		in->pages = (Pg*)p;
		for(off = Pghdr; off + sz <= Pgsize; off += sz){
			k = (Chunk*)(p+off);
			k->next = in->free[c];
			in->free[c] = k;
		}
	}
	k = in->free[c];
	in->free[c] = k->next;
	memset(k, 0, sz);
	return k;
}

static void
ovmfree(Inst *in, void *p, ulong n)
{
	int c;
	Chunk *k;

	if(p == nil)
		return;
	c = sizeclass(n);
	k = p;
	k->next = in->free[c];
	in->free[c] = k;
}

static char*
ovstrdup(Inst *in, char *s)
{
	char *p;
	ulong n;

	n = strlen(s)+1;
	p = ovmalloc(in, n);
	if(p != nil)
		memmove(p, s, n);
	return p;
}

static void
ovstrfree(Inst *in, char *s)
{
	if(s != nil)
		ovmfree(in, s, strlen(s)+1);
}

/*
 * Data blocks.
 */

/* The slot for block b, allocating index pages if alloc; nil if absent or out of memory. */
static uchar**
blkslot(Inst *in, Node *n, ulong b, int alloc)
{
	ulong i1, i2;

	if(b < Ndirect)
		return &n->direct[b];
	b -= Ndirect;
	i1 = b / Perpage;
	i2 = b % Perpage;
	if(i1 >= Perpage)
		return nil;
	if(n->ind == nil){
		if(!alloc || (n->ind = pgalloc(in)) == nil)
			return nil;
	}
	if(n->ind[i1] == nil){
		if(!alloc || (n->ind[i1] = pgalloc(in)) == nil)
			return nil;
	}
	return &n->ind[i1][i2];
}

/* Frees the blocks wholly at or beyond len, and zeroes the tail of the last one. */
static void
trimblocks(Inst *in, Node *n, vlong len)
{
	ulong b, first, i, j;
	uchar **s;

	first = (len + Pgsize - 1) / Pgsize;
	for(b = first; b < Ndirect; b++){
		pgfree(in, n->direct[b]);
		n->direct[b] = nil;
	}
	if(n->ind != nil){
		for(i = 0; i < Perpage; i++){
			if(n->ind[i] == nil)
				continue;
			for(j = 0; j < Perpage; j++){
				b = Ndirect + i*Perpage + j;
				if(b >= first && n->ind[i][j] != nil){
					pgfree(in, n->ind[i][j]);
					n->ind[i][j] = nil;
				}
			}
			if(Ndirect + (i+1)*Perpage <= first)
				continue;
			if(Ndirect + i*Perpage >= first){
				pgfree(in, n->ind[i]);
				n->ind[i] = nil;
			}
		}
		if(first <= Ndirect){
			pgfree(in, n->ind);
			n->ind = nil;
		}
	}
	if(len % Pgsize){
		s = blkslot(in, n, len / Pgsize, 0);
		if(s != nil && *s != nil)
			memset(*s + len % Pgsize, 0, Pgsize - len % Pgsize);
	}
}

static long
blkread(Inst *in, Node *n, uchar *a, long cnt, vlong off)
{
	long done, m, o;
	uchar **s;

	if(off >= n->length)
		return 0;
	if(off + cnt > n->length)
		cnt = n->length - off;
	for(done = 0; done < cnt; done += m){
		o = (off + done) % Pgsize;
		m = Pgsize - o;
		if(m > cnt - done)
			m = cnt - done;
		s = blkslot(in, n, (off + done) / Pgsize, 0);
		if(s == nil || *s == nil)
			memset(a + done, 0, m);
		else
			memmove(a + done, *s + o, m);
	}
	return cnt;
}

/* Writes all of a or nothing: raises Efull, leaving the length as it was. */
static void
blkwrite(Inst *in, Node *n, uchar *a, long cnt, vlong off)
{
	ulong b, last;
	long done, m, o;
	uchar **s;

	if(cnt <= 0)
		return;
	if(off < 0 || off + cnt > Maxfile)
		error(Etoobig);
	last = (off + cnt - 1) / Pgsize;
	for(b = off / Pgsize; b <= last; b++){
		s = blkslot(in, n, b, 1);
		if(s != nil && *s == nil)
			*s = pgalloc(in);
		if(s == nil || *s == nil){
			trimblocks(in, n, n->length);
			error(Efull);
		}
	}
	for(done = 0; done < cnt; done += m){
		o = (off + done) % Pgsize;
		m = Pgsize - o;
		if(m > cnt - done)
			m = cnt - done;
		s = blkslot(in, n, (off + done) / Pgsize, 0);
		memmove(*s + o, a + done, m);
	}
	if(off + cnt > n->length)
		n->length = off + cnt;
}

/*
 * Nodes.
 */

static void nodeunref(Inst*, Node*);

static void
nodefree(Inst *in, Node *n)
{
	Node *c, *nc;

	for(c = n->child; c != nil; c = nc){
		nc = c->next;
		c->parent = nil;
		c->next = nil;
		c->prev = nil;
		c->hnext = nil;
		nodeunref(in, c);
	}
	n->child = nil;
	free(n->htab);
	n->htab = nil;
	trimblocks(in, n, 0);
	ovstrfree(in, n->link);
	ovstrfree(in, n->name);
	ovstrfree(in, n->uid);
	ovstrfree(in, n->gid);
	ovstrfree(in, n->muid);
	ovmfree(in, n, sizeof(Node));
}

static void
nodeunref(Inst *in, Node *n)
{
	if(n != nil && --n->ref == 0)
		nodefree(in, n);
}

static ulong
namehash(char *name)
{
	ulong h;

	h = 2166136261U;
	while(*name != '\0')
		h = (h ^ (uchar)*name++) * 16777619U;
	return h;
}

/*
 * Rebuilds d's hash table with n buckets (a power of two). On failure the
 * old table stays: chains get longer, lookups stay right.
 */
static void
rehash(Node *d, int n)
{
	Node **t, *c;
	ulong h;

	t = mallocz(n * sizeof(Node*), 1);
	if(t == nil)
		return;
	for(c = d->child; c != nil; c = c->next){
		h = namehash(c->name) & (n - 1);
		c->hnext = t[h];
		t[h] = c;
	}
	free(d->htab);
	d->htab = t;
	d->hsize = n;
}

static Node*
findchild(Node *d, char *name)
{
	Node *c;

	if(d->htab != nil){
		for(c = d->htab[namehash(name) & (d->hsize - 1)]; c != nil; c = c->hnext)
			if(strcmp(c->name, name) == 0)
				return c;
		return nil;
	}
	for(c = d->child; c != nil; c = c->next)
		if(strcmp(c->name, name) == 0)
			return c;
	return nil;
}

enum { Hmin = 64 };	/* a directory with more children than this gets a table */

static void
ovlink(Node *d, Node *c)
{
	ulong h;

	c->parent = d;
	c->prev = nil;
	c->next = d->child;
	if(d->child != nil)
		d->child->prev = c;
	d->child = c;
	d->nchild++;
	if(d->htab != nil){
		h = namehash(c->name) & (d->hsize - 1);
		c->hnext = d->htab[h];
		d->htab[h] = c;
	}
	if(d->nchild > (d->htab != nil ? 2 * d->hsize : Hmin))
		rehash(d, d->htab != nil ? 2 * d->hsize : 2 * Hmin);
}

/* Takes c out of its directory and drops the tree's reference. */
static void
ovunlink(Inst *in, Node *c)
{
	Node *d, **l;

	d = c->parent;
	if(d == nil)
		return;
	if(c->prev != nil)
		c->prev->next = c->next;
	else
		d->child = c->next;
	if(c->next != nil)
		c->next->prev = c->prev;
	if(d->htab != nil)
		for(l = &d->htab[namehash(c->name) & (d->hsize - 1)]; *l != nil; l = &(*l)->hnext)
			if(*l == c){
				*l = c->hnext;
				break;
			}
	d->nchild--;
	c->parent = nil;
	c->next = nil;
	c->prev = nil;
	c->hnext = nil;
	nodeunref(in, c);
}

static void
setstrs(Inst *in, Node *n, char *uid, char *gid, char *muid)
{
	char *u, *g, *m;

	u = ovstrdup(in, uid);
	g = ovstrdup(in, gid);
	m = ovstrdup(in, muid);
	if(u == nil || g == nil || m == nil){
		ovstrfree(in, u);
		ovstrfree(in, g);
		ovstrfree(in, m);
		error(Efull);
	}
	ovstrfree(in, n->uid);
	ovstrfree(in, n->gid);
	ovstrfree(in, n->muid);
	n->uid = u;
	n->gid = g;
	n->muid = m;
}

static char*
ovuser(void)
{
	return up->user[0] != '\0' ? up->user : eve;
}

/* A new, unlinked node with a reference for the tree. */
static Node*
newnode(Inst *in, int kind, char *name)
{
	Node *n;

	if(strlen(name) >= Maxname)
		error(Etoolong);
	n = ovmalloc(in, sizeof(Node));
	if(n == nil)
		error(Efull);
	n->kind = kind;
	n->ref = 1;
	n->name = ovstrdup(in, name);
	if(n->name == nil){
		ovmfree(in, n, sizeof(Node));
		error(Efull);
	}
	if(waserror()){
		nodefree(in, n);
		nexterror();
	}
	if(kind != Nwhite)
		setstrs(in, n, eve, eve, eve);
	poperror();
	return n;
}

static void
newqid(Inst *in, Node *n, int dir)
{
	mkqid(&n->qid, Copybit | ++in->qidgen, 0, dir ? QTDIR : QTFILE);
}

static void
setdir(Inst *in, Node *n, Dir *d)
{
	setstrs(in, n, d->uid, d->gid, d->muid);
	n->mode = d->mode;
	n->atime = d->atime;
	n->mtime = d->mtime;
	n->length = d->length;
}

static void
node2dir(Chan *c, Node *n, Dir *d)
{
	d->type = devtab[c->type]->dc;
	d->dev = c->dev;
	d->qid = n->qid;
	d->mode = n->mode;
	if(n->kind == Nfifo)
		d->mode |= H9_DMFIFO;
	/* A link is one only to a Linux process (design/epoch-0/linux-symlinks.md). */
	if(n->kind == Nlink){
		if(h9_fs_linkwalk())
			d->mode |= H9_DMSYMLINK;
		else
			d->qid.type &= ~H9_QTSYMLINK;
	}
	d->atime = n->atime;
	d->mtime = n->mtime;
	d->length = (n->qid.type & QTDIR) ? 0 : n->length;
	d->name = n->parent == nil && n->name[0] == '\0' ? "/" : n->name;
	d->uid = n->uid;
	d->gid = n->gid;
	d->muid = n->muid;
}

/*
 * The lower tree.
 */

/* Walks lower by one name; nil (with the error set) if it isn't there. */
static Chan*
lowerwalk1(Chan *lc, char *name)
{
	Walkqid *wq;
	Chan *nc;

	wq = devtab[lc->type]->walk(lc, nil, &name, 1);
	if(wq == nil)
		return nil;
	nc = wq->clone;
	if(wq->nqid != 1 && nc != nil){
		cclose(nc);
		nc = nil;
	}
	free(wq);
	return nc;
}

/* Walks the instance's lower root by the first n names of path; nil if absent. */
static Chan*
lowerwalk(Inst *in, char *path, int n)
{
	Chan *c, *nc;
	char *s, *e, buf[Maxname];
	int i;

	if(in->lower == nil)
		return nil;
	c = cclone(in->lower);
	s = path;
	for(i = 0; i < n && *s != '\0'; i++){
		e = strchr(s, '/');
		if(e == nil)
			e = s + strlen(s);
		if(e - s >= sizeof buf){
			cclose(c);
			return nil;
		}
		memmove(buf, s, e - s);
		buf[e - s] = '\0';
		nc = lowerwalk1(c, buf);
		cclose(c);
		if(nc == nil)
			return nil;
		c = nc;
		s = *e ? e+1 : e;
	}
	return c;
}

/* The lower file's Dir, with its strings in strs (at least nstrs bytes). */
static void
lowerstat(Chan *lc, Dir *d, uchar *buf, int nbuf, char *strs)
{
	int n;

	n = devtab[lc->type]->stat(lc, buf, nbuf);
	if(n < BIT16SZ || convM2D(buf, n, d, strs) != n)
		error(Ebadstat);
}

/*
 * Chan state.
 */

static Ovc*
ovcnew(Inst *in, Node *n, Chan *lower, char *path)
{
	Ovc *o;

	o = mallocz(sizeof(Ovc), 1);
	if(o == nil)
		error(Enomem);
	o->path = strdup(path);
	if(o->path == nil){
		free(o);
		error(Enomem);
	}
	o->inst = in;
	o->node = n;
	if(n != nil)
		n->ref++;
	o->lower = lower;
	return o;
}

static void instdecref(Inst*);

static void
ovcfree(Ovc *o)
{
	Inst *in;

	if(o == nil)
		return;
	in = o->inst;
	if(o->lower != nil)
		cclose(o->lower);
	qlock(&in->ql);
	if(o->excl)
		o->node->excl = 0;
	nodeunref(in, o->node);
	nodeunref(in, o->lnk);
	qunlock(&in->ql);
	free(o->dir);
	free(o->lpath);
	free(o->path);
	free(o);
	instdecref(in);
}

static char*
pathjoin(char *dir, char *name)
{
	char *p;

	if(dir[0] == '\0')
		p = strdup(name);
	else{
		p = malloc(strlen(dir) + 1 + strlen(name) + 1);
		if(p != nil)
			sprint(p, "%s/%s", dir, name);
	}
	if(p == nil)
		error(Enomem);
	return p;
}

static int
npathelem(char *path)
{
	int n;

	if(path[0] == '\0')
		return 0;
	for(n = 1; *path; path++)
		if(*path == '/')
			n++;
	return n;
}

/* Copies the i'th name of path into buf. */
static void
pathelem(char *path, int i, char *buf)
{
	char *e;

	while(i-- > 0)
		path = strchr(path, '/') + 1;
	e = strchr(path, '/');
	if(e == nil)
		e = path + strlen(path);
	memmove(buf, path, e - path);
	buf[e - path] = '\0';
}

/*
 * Finds a lower-only name in memory, in case it has since been copied up,
 * marked or removed. Returns -1 if it's gone: removed, or a node that has
 * left the tree.
 */
static int
adopt(Ovc *o)
{
	Node *cur, *ch;
	char buf[Maxname];
	int i, n;

	if(o->node != nil){
		if(o->node != o->inst->root && o->node->parent == nil)
			return -1;
		return o->node->kind == Nwhite ? -1 : 0;
	}
	cur = o->inst->root;
	n = npathelem(o->path);
	for(i = 0; i < n; i++){
		pathelem(o->path, i, buf);
		ch = findchild(cur, buf);
		if(ch == nil)
			return 0;
		if(ch->kind == Nwhite)
			return -1;
		cur = ch;
	}
	o->node = cur;
	cur->ref++;
	return 0;
}

/*
 * An open file whose name was removed: its node lives on until the last
 * close, so stat and wstat (a truncate) still reach it, as they do on
 * Linux. WebKit makes its shared memory by opening a file in /dev/shm,
 * removing it, and then truncating it to size.
 */
static int
removedopen(Chan *c)
{
	Ovc *o;

	o = c->aux;
	return (c->flag & COPEN) != 0 && o->node != nil && o->node != o->inst->root &&
		o->node->parent == nil && (o->node->kind == Ncopy || o->node->kind == Nfifo);
}

/* Brings a chan up to date with the tree, for operations other than I/O on an open chan. */
static void
refresh(Chan *c)
{
	Ovc *o;

	o = c->aux;
	if(removedopen(c))
		return;
	if(adopt(o) < 0)
		error(Enonexist);
	if(o->node != nil && (c->flag & COPEN) == 0)
		c->qid = o->node->qid;
}

/* A fresh, unopened lower chan for o's name, or nil. */
static Chan*
lowerfor(Ovc *o)
{
	if(o->lower == nil)
		return nil;
	if(!o->lopen)
		return cclone(o->lower);
	return lowerwalk(o->inst, o->path, npathelem(o->path));
}

/*
 * Permission to open a file or directory of this mode, by its owner bits:
 * the guest is the owner of everything in the tree, as devfs presents it.
 */
static void
ovperm(ulong mode, int omode)
{
	static int need[] = { 4, 2, 6, 1 };
	int t;

	t = need[omode&3];
	if(omode & OTRUNC)
		t |= 2;
	if(((mode>>6) & t) != t)
		error(Eperm);
}

/* Reports a change at path to the instance's tracker, if it has one. */
static void wcdrop(Inst*, char*, int);

static void
changed(Inst *in, char *path)
{
	wcdrop(in, path, 0);
	if(in->track != nil)
		h9_overlay_changed(in->track, path);
}

/*
 * The directory node for the first n names of path, making markers for
 * lower directories that have none yet.
 */
static Node*
markpath(Inst *in, char *path, int n)
{
	Node *cur, *ch;
	Chan *lc;
	Dir d;
	uchar buf[1024+4*Maxname];
	char strs[sizeof buf];
	char name[Maxname];
	int i;

	cur = in->root;
	for(i = 0; i < n; i++){
		pathelem(path, i, name);
		ch = findchild(cur, name);
		if(ch != nil){
			if(ch->kind == Nwhite || (ch->qid.type & QTDIR) == 0)
				error(Enonexist);
			cur = ch;
			continue;
		}
		if(cur->kind != Nmark)
			error(Enonexist);
		lc = lowerwalk(in, path, i+1);
		if(lc == nil)
			error(Enonexist);
		if(waserror()){
			cclose(lc);
			nexterror();
		}
		lowerstat(lc, &d, buf, sizeof buf, strs);
		if((d.qid.type & QTDIR) == 0)
			error(Enotdir);
		ch = newnode(in, Nmark, name);
		ch->qid = d.qid;
		ch->inlower = 1;
		if(waserror()){
			nodefree(in, ch);
			nexterror();
		}
		setdir(in, ch, &d);
		poperror();
		poperror();
		cclose(lc);
		ovlink(cur, ch);
		cur = ch;
	}
	return cur;
}

/*
 * Copies a lower-only file into memory, whole unless trunc, and points
 * the chan at the copy. Raises Efull (changing nothing) if memory runs out.
 */
static void
copyup(Chan *c, int trunc)
{
	Ovc *o;
	Inst *in;
	Node *dir, *n;
	Chan *volatile lc;
	Dir d;
	uchar buf[1024+4*Maxname];
	char strs[sizeof buf];
	char name[Maxname];
	uchar *volatile data;
	vlong off;
	long r;
	int ne;

	o = c->aux;
	in = o->inst;
	ne = npathelem(o->path);
	if(ne == 0 || o->lower == nil)
		error(Eperm);
	dir = markpath(in, o->path, ne-1);
	pathelem(o->path, ne-1, name);
	lowerstat(o->lower, &d, buf, sizeof buf, strs);
	n = newnode(in, Ncopy, name);
	n->inlower = 1;
	newqid(in, n, 0);
	lc = nil;
	data = nil;
	if(waserror()){
		if(lc != nil)
			cclose(lc);
		free(data);
		nodefree(in, n);
		nexterror();
	}
	setdir(in, n, &d);
	n->length = 0;
	if(!trunc){
		lc = lowerfor(o);
		if(lc == nil)
			error(Enonexist);
		lc = devtab[lc->type]->open(lc, OREAD);
		data = smalloc(Copybuf);
		for(off = 0; off < d.length; off += r){
			r = devtab[lc->type]->read(lc, data, Copybuf, off);
			if(r <= 0)
				break;
			blkwrite(in, n, data, r, off);
		}
		cclose(lc);
		lc = nil;
	}
	poperror();
	free(data);
	ovlink(dir, n);
	o->node = n;
	n->ref++;
	if((c->flag & COPEN) == 0)
		c->qid = n->qid;
	changed(in, o->path);
}

/* Packs the merged directory into the chan's snapshot. */
static void
snapshot(Chan *c)
{
	Ovc *o;
	Node *n, *ch;
	Chan *volatile lc;
	Dir d;
	uchar *volatile buf;
	uchar *p, *e;
	char *strs;
	long r, m, cap;
	vlong off;

	o = c->aux;
	n = o->node;
	free(o->dir);
	o->dir = nil;
	o->ndir = 0;
	cap = 0;
	buf = nil;
	lc = nil;
	if(waserror()){
		if(lc != nil)
			cclose(lc);
		free(buf);
		nexterror();
	}
	for(ch = n->child; ch != nil; ch = ch->next){
		if(ch->kind == Nwhite)
			continue;
		node2dir(c, ch, &d);
		m = sizeD2M(&d);
		if(o->ndir + m > cap){
			cap = (o->ndir + m) * 2 + 1024;
			o->dir = realloc(o->dir, cap);
			if(o->dir == nil)
				error(Enomem);
		}
		o->ndir += convD2M(&d, o->dir + o->ndir, m);
	}
	if(n->kind == Nmark && (lc = lowerfor(o)) != nil){
		lc = devtab[lc->type]->open(lc, OREAD);
		buf = smalloc(8192 + 8192);
		strs = (char*)buf + 8192;
		for(off = 0;; off += r){
			r = devtab[lc->type]->read(lc, buf, 8192, off);
			if(r <= 0)
				break;
			e = buf + r;
			for(p = buf; p + BIT16SZ <= e; p += m){
				m = BIT16SZ + GBIT16(p);
				if(p + m > e || convM2D(p, m, &d, strs) != m)
					break;
				if(findchild(n, d.name) != nil)
					continue;
				if(o->ndir + m > cap){
					cap = (o->ndir + m) * 2 + 1024;
					o->dir = realloc(o->dir, cap);
					if(o->dir == nil)
						error(Enomem);
				}
				memmove(o->dir + o->ndir, p, m);
				o->ndir += m;
			}
		}
		cclose(lc);
		lc = nil;
	}
	poperror();
	free(buf);
}

/* Whether the merged directory has any entries. */
static int
dirempty(Chan *c)
{
	Ovc *o;
	Node *ch;
	Chan *volatile lc;
	uchar *volatile buf;
	long r;
	int empty;

	o = c->aux;
	if(o->node != nil){
		for(ch = o->node->child; ch != nil; ch = ch->next)
			if(ch->kind != Nwhite)
				return 0;
		if(o->node->kind == Ncopy)
			return 1;
	}
	if(o->lower == nil)
		return 1;
	if(o->node != nil){
		snapshot(c);
		empty = o->ndir == 0;
		free(o->dir);
		o->dir = nil;
		o->ndir = 0;
		return empty;
	}
	lc = lowerfor(o);
	if(lc == nil)
		return 1;
	buf = nil;
	if(waserror()){
		cclose(lc);
		free(buf);
		nexterror();
	}
	lc = devtab[lc->type]->open(lc, OREAD);
	buf = smalloc(8192);
	r = devtab[lc->type]->read(lc, buf, 8192, 0);
	poperror();
	cclose(lc);
	free(buf);
	return r <= 0;
}

/*
 * Instances.
 */

static Inst*
instlookup(int id)
{
	int i;

	for(i = 0; i < Maxinst; i++)
		if(insts[i] != nil && insts[i]->id == id)
			return insts[i];
	return nil;
}

static void wcfree(Inst*);

static void
instfree(Inst *in)
{
	Pg *p, *np;
	int i;

	qlock(&in->ql);
	nodeunref(in, in->root);
	in->root = nil;
	for(p = in->pages; p != nil; p = np){
		np = p->next;
		pgfree(in, p);
	}
	in->pages = nil;
	qunlock(&in->ql);
	if(in->lower != nil)
		cclose(in->lower);
	wcfree(in);
	for(i = 0; i < in->nmem; i++){
		cclose(in->mem[i].root);
		free(in->mem[i].at);
	}
	free(in->mem);
	free(in);
}

static void
instdecref(Inst *in)
{
	int i, last;

	lock(&instlock);
	last = --in->ref == 0;
	if(last){
		for(i = 0; i < Maxinst; i++)
			if(insts[i] == in)
				insts[i] = nil;
		/* A named union's cow isn't counted in its ref: forget each other. */
		if(in->over != nil)
			in->over->cow = nil;
		if(in->cow != nil)
			in->cow->over = nil;
		in->over = in->cow = nil;
	}
	unlock(&instlock);
	if(last)
		instfree(in);
}

/*
 * Makes an instance over lower (nil: a tree in memory only) for the
 * calling thread's machine. Returns its number, or -1 with the error set.
 * The instance is freed when the last chan from its first attach is
 * closed, or by h9_overlay_drop if it's never attached.
 */
int
h9_overlay_new(Chan *lower)
{
	Inst *in;
	Node *r;
	Dir d;
	uchar buf[1024+4*Maxname];
	char strs[sizeof buf];
	int i;

	in = mallocz(sizeof(Inst), 1);
	if(in == nil){
		kstrcpy(up->errstr, Enomem, ERRMAX);
		return -1;
	}
	in->pool = h9_overlay_pool();
	in->ref = 1;
	in->pinned = 1;
	if(waserror()){
		instfree(in);
		return -1;
	}
	if(lower != nil){
		if((lower->qid.type & QTDIR) == 0)
			error(Enotdir);
		lowerstat(lower, &d, buf, sizeof buf, strs);
		in->lower = cclone(lower);
		r = newnode(in, Nmark, "");
		r->inlower = 1;
		r->qid = lower->qid;
		in->root = r;
		setdir(in, r, &d);
	}else{
		r = newnode(in, Ncopy, "");
		in->root = r;
		mkqid(&r->qid, Copybit, 0, QTDIR);
		r->mode = DMDIR|0777;
		r->atime = r->mtime = seconds();
	}
	lock(&instlock);
	for(i = 0; i < Maxinst; i++)
		if(insts[i] == nil)
			break;
	if(i == Maxinst){
		unlock(&instlock);
		error("too many overlays");
	}
	in->id = nextid++;
	insts[i] = in;
	unlock(&instlock);
	poperror();
	return in->id;
}

/*
 * For the namespace builder in Zig: an instance over the directory at
 * path (nil: none), with errors as the sys* wrappers report them.
 */
int
h9_overlay_newpath(char *path)
{
	Chan *c;
	char *p;
	int n;

	if(waserror()){
		p = up->syserrstr;
		up->syserrstr = up->errstr;
		up->errstr = p;
		return -1;
	}
	c = nil;
	if(path != nil)
		c = namec(path, Aaccess, 0, 0);
	n = h9_overlay_new(c);
	if(c != nil)
		cclose(c);
	if(n < 0)
		nexterror();
	poperror();
	return n;
}

/*
 * The lower chan for c's name, for ovreadlink and ovgetattr,
 * or nil if c isn't an overlay chan or its name is in memory: a link
 * copied up is a file now.
 */
Chan*
h9_overlay_lower(Chan *c)
{
	Ovc *o;

	if(devtab[c->type]->dc != 'O')
		return nil;
	if(isunion(c)){
		/* The member's chan that holds the name. */
		Unc *u = c->aux;
		if(u->n == 0)
			return nil;
		if(!u->lopen)
			return cclone(u->mc[0]);
		return nil;
	}
	o = c->aux;
	qlock(&o->inst->ql);
	if(waserror()){
		qunlock(&o->inst->ql);
		nexterror();
	}
	c = nil;
	if(adopt(o) == 0 && (o->node == nil || o->node->kind == Nmark))
		c = lowerfor(o);
	qunlock(&o->inst->ql);
	poperror();
	return c;
}

static Chan *ovcreate(Chan*, char*, int, ulong);
static void removelocked(Chan*);
static void unmknod(Chan*, char*, char*, ulong);
int h9_overlay_move(Chan*, Chan*, char*);

/* A Dir that a wstat leaves as it is, but for what's set in it. */
static void
ovnulldir(Dir *d)
{
	memset(d, ~0, sizeof(Dir));
	d->name = d->uid = d->gid = d->muid = "";
}

/*
 * Makes name in the directory c a symbolic link to target, for the
 * Linux ABI's symlinkat. c is an overlay chan, which this closes.
 */
void
h9_overlay_symlink(Chan *c, char *name, char *target)
{
	Ovc *o;
	Inst *in;
	Node *n;
	char *s;

	if(waserror()){
		cclose(c);
		nexterror();
	}
	if(strlen(target) >= 2048)
		error(Etoolong);
	if(isunion(c)){
		/* In the layer, or on the first member that takes creates. */
		unmknod(c, name, target, 0);
		poperror();
		cclose(c);
		return;
	}
	c = ovcreate(c, name, OREAD, 0666);
	poperror();
	o = c->aux;
	in = o->inst;
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		cclose(c);
		nexterror();
	}
	n = o->node;
	s = ovstrdup(in, target);
	if(s == nil){
		removelocked(c);
		error(Efull);
	}
	n->kind = Nlink;
	n->qid.type |= H9_QTSYMLINK;
	n->link = s;
	n->mode = 0777;
	n->length = strlen(target);
	qunlock(&in->ql);
	poperror();
	cclose(c);
}

/*
 * The target of the link c was walked through as its last name, into buf;
 * its length, or -1 if c isn't an overlay chan on a link of its own (a
 * lower name's link is devfs's, through h9_overlay_lower).
 */
int
h9_overlay_readlink(Chan *c, char *buf, int nbuf)
{
	Ovc *o;
	Node *l;
	int n;

	if(devtab[c->type]->dc != 'O' || nbuf <= 0 || isunion(c))
		return -1;
	o = c->aux;
	qlock(&o->inst->ql);
	l = o->lnk;
	if(l == nil && o->node != nil && o->node->kind == Nlink)
		l = o->node;
	n = -1;
	if(l != nil && l->parent != nil){
		n = strlen(l->link);
		if(n > nbuf-1)
			n = nbuf-1;
		memmove(buf, l->link, n);
		buf[n] = 0;
	}
	qunlock(&o->inst->ql);
	return n;
}

/*
 * Makes name in the directory c a FIFO, for the Linux ABI's
 * mknodat. c is an overlay chan, which this closes.
 */
void
h9_overlay_mkfifo(Chan *c, char *name, ulong perm)
{
	Ovc *o;
	Inst *in;

	if(waserror()){
		cclose(c);
		nexterror();
	}
	if(isunion(c)){
		unmknod(c, name, nil, perm & 0777);
		poperror();
		cclose(c);
		return;
	}
	c = ovcreate(c, name, OREAD, perm & 0777);
	poperror();
	o = c->aux;
	in = o->inst;
	qlock(&in->ql);
	o->node->kind = Nfifo;
	qunlock(&in->ql);
	cclose(c);
}

/*
 * Whether the overlay chan c is a FIFO's: a FIFO node in memory, or a
 * host FIFO in the lower tree.
 */
int
h9_overlay_isfifo(Chan *c)
{
	Ovc *o;
	Chan *l;
	int r;

	if(devtab[c->type]->dc != 'O')
		return 0;
	if(isunion(c)){
		/* The member's file that holds the name. */
		Unc *u = c->aux;
		if(u->n == 0 || u->mc[0] == nil)
			return 0;
		return h9_fs_chanisfifo(u->mc[0]);
	}
	o = c->aux;
	qlock(&o->inst->ql);
	l = nil;
	if(o->node != nil)
		r = o->node->kind == Nfifo;
	else{
		r = 0;
		l = o->lower;
	}
	qunlock(&o->inst->ql);
	if(l != nil)
		r = h9_fs_isfifo(l);
	return r;
}

/* Frees an instance that was made but never attached. */
void
h9_overlay_drop(int id)
{
	Inst *in;

	lock(&instlock);
	in = instlookup(id);
	if(in == nil || !in->pinned || in->pool != h9_overlay_pool()){
		unlock(&instlock);
		return;
	}
	in->pinned = 0;
	unlock(&instlock);
	instdecref(in);
}

/*
 * Gives an instance of the calling thread's machine a tracker (nil: none)
 * for h9_overlay_changed. Changes before this aren't reported.
 */
void
h9_overlay_track(int id, void *track)
{
	Inst *in;

	lock(&instlock);
	in = instlookup(id);
	if(in != nil && in->pool == h9_overlay_pool())
		in->track = track;
	unlock(&instlock);
}

/*
 * For findmount (chan.c): a directory an instance shows from its lower
 * tree, or a marker for one, has the lower qid, so a mount on that lower
 * directory, made before the instance, shows through it as well. Returns 1
 * and the lower device's type and dev for (type, dev, qid) on an
 * instance with a lower tree, unless qid is a copy's own.
 */
int
h9_overlay_lowerdev(int type, int dev, Qid qid, int *ltype, int *ldev)
{
	static int ovtype = -2;
	Inst *in;
	int r;

	if(ovtype == -2)
		ovtype = devno('O');
	if(type != ovtype || (qid.type & QTDIR) == 0 || (qid.path & Copybit) != 0)
		return 0;
	r = 0;
	lock(&instlock);
	in = instlookup(dev);
	if(in != nil && in->lower != nil){
		*ltype = in->lower->type;
		*ldev = in->lower->dev;
		r = 1;
	}
	unlock(&instlock);
	return r;
}

static int ovname(char*);

/*
 * Unions (design/epoch-0/mounts.md, "Union instances").
 *
 * A union instance has no tree in memory: it has an ordered list of
 * members, each a chan on another device's directory, rooted at the
 * union's top or at a path below it (a member rooted at "etc" is walked
 * only for etc and the paths under it). A walk walks each member that
 * has the current directory to the same name, in order, top first. The
 * first member that has the name decides what it is: a file is that
 * member's file, and a directory is merged over every member with a
 * directory by that name, at every depth. Walks are device walks, so a
 * member is its own tree, not the mounts on it.
 *
 * Writes, removes and wstats go to the member that holds the name (the
 * first), and creates go to the first member marked create that has the
 * directory, or fail with "mounted directory forbids creation". A
 * copy-on-write instance over a union (bind -c '#O' over it) keeps all
 * of them in memory instead.
 *
 * Qids: each (device, dev, qid path) a member shows gets the union's own
 * qid path from a table, so names from different members never share
 * one, and the same file reached twice keeps one. The table and
 * directory snapshots come from the machine's pages, as an overlay's
 * data does.
 *
 * Named unions: "#Oroot" and "#Olinux" (any name of letters) are found
 * by name in the attaching machine; a cow instance over a named union,
 * made by h9_overlay_cowname, is what attaching the name gives from then
 * on, so the name stands for the whole stack.
 */

static Qid
unrootqid(void)
{
	Qid q;

	mkqid(&q, 0, 0, QTDIR);
	return q;
}

/* The table's entry for a member chan, made if it's missing. Under in->ql. */
static Qmap*
qmapof(Inst *in, Chan *mc)
{
	Qmap *m;
	ulong h;

	h = (mc->qid.path ^ (mc->qid.path>>17) ^ (mc->type<<7) ^ mc->dev) % Qbuckets;
	for(m = in->qtab[h]; m != nil; m = m->next)
		if(m->type == mc->type && m->dev == mc->dev && m->path == mc->qid.path)
			return m;
	m = ovmalloc(in, sizeof(Qmap));
	if(m == nil)
		error(Efull);
	m->type = mc->type;
	m->dev = mc->dev;
	m->path = mc->qid.path;
	m->qpath = ++in->qidgen;
	m->next = in->qtab[h];
	in->qtab[h] = m;
	return m;
}

/* The union's qid for a member chan's. Under in->ql. */
static Qid
unqid(Inst *in, Chan *mc)
{
	Qid q;

	q = mc->qid;
	q.path = qmapof(in, mc)->qpath;
	return q;
}

/*
 * The union qid path of below, a directory below the up layer, which
 * upwalk is about to make in the layer.
 */
static uvlong
upqpath(Inst *in, Chan *below)
{
	uvlong qp;

	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	qp = qmapof(in, below)->qpath;
	poperror();
	qunlock(&in->ql);
	return qp;
}

/*
 * Gives made, the up layer's copy of a directory below it, the union
 * qid path qp the directory had, so the directory keeps its identity
 * once the layer has it, as overlayfs keeps a directory's inode on copy
 * up: an fd opened on it before (a Linux dirfd, which h9_linux_dotfd
 * checks against a fresh walk), and stat's inode, see the same one.
 */
static void
upkeepqid(Inst *in, Chan *made, uvlong qp)
{
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	qmapof(in, made)->qpath = qp;
	poperror();
	qunlock(&in->ql);
}

static Unc*
uncnew(Inst *in, char *path)
{
	Unc *u;

	u = mallocz(sizeof(Unc), 1);
	if(u == nil)
		error(Enomem);
	u->path = strdup(path);
	if(u->path == nil){
		free(u);
		error(Enomem);
	}
	u->inst = in;
	return u;
}

static void
unclear(Unc *u)
{
	int i;

	for(i = 0; i < u->n; i++)
		if(u->mc[i] != nil)
			cclose(u->mc[i]);
	u->n = 0;
}

static void
undirfree(Unc *u)
{
	if(u->dir != nil)
		h9_overlay_free(u->inst->pool, u->dir, u->dircap);
	u->dir = nil;
	u->ndir = 0;
	u->dircap = 0;
}

static void
uncfree(Unc *u)
{
	Inst *in;

	if(u == nil)
		return;
	in = u->inst;
	unclear(u);
	undirfree(u);
	free(u->path);
	free(u);
	instdecref(in);
}

static void
unadd(Unc *u, Chan *c, Member *m)
{
	if(u->n >= Maxmembers){
		cclose(c);
		return;
	}
	u->mc[u->n] = c;
	u->mid[u->n] = m->id;
	u->mcreate[u->n] = m->create;
	u->n++;
}

/* The index of member id in the instance, or -1 once it's gone. Under in->ql. */
static int
unmemidx(Inst *in, int id)
{
	int i;

	for(i = 0; i < in->nmem; i++)
		if(in->mem[i].id == id)
			return i;
	return -1;
}

/* Puts u at the union's top: each member rooted there. */
static void
untop(Unc *u)
{
	Inst *in;
	int i;

	in = u->inst;
	unclear(u);
	qlock(&in->ql);
	for(i = 0; i < in->nmem; i++)
		if(in->mem[i].at[0] == '\0' && !(u->noup && in->mem[i].isup))
			unadd(u, cclone(in->mem[i].root), &in->mem[i]);
	qunlock(&in->ql);
}

/*
 * Whiteouts (design/epoch-0/upper-layers.md): in a union, a member's
 * .wh.NAME hides NAME in the members below it, and a directory holding
 * .wh..wh..opq isn't merged with the directories below it, as in an OCI
 * image layer. Neither shows in a directory read. A walk asks for the
 * whiteout only when a member misses a name, and only above the bottom.
 */
static char Whprefix[] = ".wh.";
static char Whopaque[] = ".wh..wh..opq";

static int
iswhname(char *name)
{
	return strncmp(name, Whprefix, 4) == 0;
}

/* Whether the member directory dir has a whiteout for name. */
static int
haswh(Chan *dir, char *name)
{
	char wh[Maxname], err[ERRMAX];
	Chan *w;

	if(strlen(name) + 4 >= Maxname)
		return 0;
	snprint(wh, sizeof wh, "%s%s", Whprefix, name);
	kstrcpy(err, up->errstr, ERRMAX);
	w = lowerwalk1(dir, wh);
	kstrcpy(up->errstr, err, ERRMAX);
	if(w == nil)
		return 0;
	cclose(w);
	return 1;
}

/* Whether the member directory dir is opaque. */
static int
isopaque(Chan *dir)
{
	char err[ERRMAX];
	Chan *w;

	kstrcpy(err, up->errstr, ERRMAX);
	w = lowerwalk1(dir, Whopaque);
	kstrcpy(up->errstr, err, ERRMAX);
	if(w == nil)
		return 0;
	cclose(w);
	return 1;
}

/*
 * The walk cache. A step of a union walk (unstep) asks each member for
 * the name, and for whiteouts and opaque markers, which is a host stat
 * or a 9P walk per member for every name of every walk. A stack with an
 * up layer keeps what its steps found, keyed by the new path and by
 * what decides the answer: the members the step started from, whether
 * the walk leaves the layer out, whether it's a Linux process's walk,
 * and the calling machine's access rules. An entry holds the members'
 * chans, cloned for each use, or that the name doesn't exist.
 *
 * Changes through the instance drop what they change: changed() drops
 * the path, and a change that moves or removes a directory, or the
 * members themselves, drops everything. An entry is kept for at most a
 * second, so a change made on the host to a tree in the stack is seen
 * within that. A step that ran while its path was dropped doesn't keep
 * what it found (the drop log).
 */
enum
{
	Wcbuckets	= 1024,	/* a power of 2 */
	Wcmax	= 8192,		/* entries; more drops everything */
	Wclog	= 64,		/* drops remembered, for steps in flight */
};

#define Wcttl	1000000000LL	/* ns */

struct Wce
{
	Wce	*next;
	char	*path;
	int	noup;
	int	lx;
	void	*plan;
	int	nkey;
	int	*kmid;		/* the member ids the step started from */
	int	ng;		/* 0: the name doesn't exist */
	Chan	**mc;
	int	*mid;
	int	*mcreate;
	vlong	born;
};

struct Wcache
{
	Wce	*tab[Wcbuckets];
	int	n;
	ulong	seq;		/* counts drops */
	char	*log[Wclog];	/* the path of drop seq%Wclog; nil for everything */
};

static ulong
wchash(char *s)
{
	ulong h;

	h = 2166136261UL;
	while(*s != '\0')
		h = (h ^ (uchar)*s++) * 16777619UL;
	return h & (Wcbuckets-1);
}

/* Whether in keeps a walk cache: a stack with an up layer. */
static int
wcon(Inst *in)
{
	int on;

	qlock(&in->ql);
	on = in->mode == Union && in->nmem > 0 && in->mem[0].isup;
	qunlock(&in->ql);
	return on;
}

/* Unlinks e onto *dead, for wcfreelist outside wcl. */
static void
wcunlink(Wcache *wc, Wce **l, Wce **dead)
{
	Wce *e;

	e = *l;
	*l = e->next;
	e->next = *dead;
	*dead = e;
	wc->n--;
}

static void
wcfreelist(Wce *e)
{
	Wce *next;
	int i;

	for(; e != nil; e = next){
		next = e->next;
		for(i = 0; i < e->ng; i++)
			cclose(e->mc[i]);
		free(e->mc);
		free(e->mid);
		free(e->mcreate);
		free(e->kmid);
		free(e->path);
		free(e);
	}
}

static void
wclogadd(Wcache *wc, char *path)
{
	char **l;

	wc->seq++;
	l = &wc->log[wc->seq % Wclog];
	free(*l);
	*l = path != nil ? strdup(path) : nil;
}

/* Everything, under wcl. */
static Wce*
wcclear(Wcache *wc)
{
	Wce *dead;
	int i;

	dead = nil;
	for(i = 0; i < Wcbuckets; i++)
		while(wc->tab[i] != nil)
			wcunlink(wc, &wc->tab[i], &dead);
	return dead;
}

/*
 * Drops what the cache has for path, or with all everything: a change
 * at path, or one that moves or removes a directory.
 */
static void
wcdrop(Inst *in, char *path, int all)
{
	Wcache *wc;
	Wce **l, *dead;

	dead = nil;
	qlock(&in->wcl);
	wc = in->wc;
	if(wc == nil){
		qunlock(&in->wcl);
		return;
	}
	if(all || path == nil){
		dead = wcclear(wc);
		wclogadd(wc, nil);
	}else{
		for(l = &wc->tab[wchash(path)]; *l != nil;)
			if(strcmp((*l)->path, path) == 0)
				wcunlink(wc, l, &dead);
			else
				l = &(*l)->next;
		wclogadd(wc, path);
	}
	qunlock(&in->wcl);
	wcfreelist(dead);
}

static void
wcfree(Inst *in)
{
	Wcache *wc;
	Wce *dead;
	int i;

	qlock(&in->wcl);
	wc = in->wc;
	in->wc = nil;
	qunlock(&in->wcl);
	if(wc == nil)
		return;
	dead = wcclear(wc);
	for(i = 0; i < Wclog; i++)
		free(wc->log[i]);
	free(wc);
	wcfreelist(dead);
}

static int
wcmatch(Wce *e, Unc *u, char *np, int lx, void *plan)
{
	int i;

	if(e->noup != u->noup || e->lx != lx || e->plan != plan || e->nkey != u->n)
		return 0;
	for(i = 0; i < u->n; i++)
		if(e->kmid[i] != u->mid[i])
			return 0;
	return strcmp(e->path, np) == 0;
}

/*
 * Looks up u's step to np. Returns 1 with the members' chans cloned
 * into got, gid, gcr and *ng, -1 if the name doesn't exist, and 0 if
 * the cache has nothing for it. Also returns the drop count, for
 * wcput.
 */
static int
wcget(Inst *in, Unc *u, char *np, Chan **got, int *gid, int *gcr, int *ng, ulong *seq)
{
	Wcache *wc;
	Wce *e, **l, *dead;
	vlong now;
	int volatile i;
	int r, lx;
	void *plan;

	lx = h9_fs_linkwalk();
	plan = h9_plan_get();
	now = h9_clock_mono();
	dead = nil;
	r = 0;
	qlock(&in->wcl);
	if(in->wc == nil){
		in->wc = mallocz(sizeof(Wcache), 1);
		if(in->wc == nil){
			qunlock(&in->wcl);
			*seq = 0;
			return 0;
		}
	}
	wc = in->wc;
	*seq = wc->seq;
	for(l = &wc->tab[wchash(np)]; (e = *l) != nil; l = &e->next){
		if(!wcmatch(e, u, np, lx, plan))
			continue;
		if(now - e->born > Wcttl){
			wcunlink(wc, l, &dead);
			break;
		}
		if(e->ng == 0){
			r = -1;
			break;
		}
		i = 0;
		if(waserror()){
			while(--i >= 0)
				cclose(got[i]);
			qunlock(&in->wcl);
			wcfreelist(dead);
			nexterror();
		}
		for(i = 0; i < e->ng; i++){
			got[i] = cclone(e->mc[i]);
			gid[i] = e->mid[i];
			gcr[i] = e->mcreate[i];
		}
		poperror();
		*ng = e->ng;
		r = 1;
		break;
	}
	qunlock(&in->wcl);
	wcfreelist(dead);
	return r;
}

/*
 * Keeps u's step to np, found from the members in kmid (nkey of them)
 * since drop count seq: ng members (none if the name doesn't exist),
 * unless np was dropped meanwhile.
 */
static void
wcput(Inst *in, int noup, int *kmid, int nkey, char *np, ulong seq, vlong born, Chan **got, int *gid, int *gcr, int ng)
{
	Wcache *wc;
	Wce *e, *dead;
	ulong s;
	int volatile i;

	e = mallocz(sizeof(Wce), 1);
	if(e == nil)
		return;
	e->path = strdup(np);
	e->kmid = malloc((nkey > 0 ? nkey : 1)*sizeof(int));
	e->mc = malloc((ng > 0 ? ng : 1)*sizeof(Chan*));
	e->mid = malloc((ng > 0 ? ng : 1)*sizeof(int));
	e->mcreate = malloc((ng > 0 ? ng : 1)*sizeof(int));
	if(e->path == nil || e->kmid == nil || e->mc == nil || e->mid == nil || e->mcreate == nil){
		wcfreelist(e);
		return;
	}
	e->noup = noup;
	e->lx = h9_fs_linkwalk();
	e->plan = h9_plan_get();
	e->nkey = nkey;
	memmove(e->kmid, kmid, nkey*sizeof(int));
	e->born = born;
	i = 0;
	if(waserror()){
		e->ng = i;
		wcfreelist(e);
		return;
	}
	for(i = 0; i < ng; i++){
		e->mc[i] = cclone(got[i]);
		e->mid[i] = gid[i];
		e->mcreate[i] = gcr[i];
	}
	poperror();
	e->ng = ng;
	dead = nil;
	qlock(&in->wcl);
	wc = in->wc;
	if(wc == nil || wc->seq - seq >= Wclog){
		qunlock(&in->wcl);
		wcfreelist(e);
		return;
	}
	for(s = seq+1; s != wc->seq+1; s++)
		if(wc->log[s % Wclog] == nil || strcmp(wc->log[s % Wclog], np) == 0){
			qunlock(&in->wcl);
			wcfreelist(e);
			return;
		}
	if(wc->n >= Wcmax)
		dead = wcclear(wc);
	e->next = wc->tab[wchash(np)];
	wc->tab[wchash(np)] = e;
	wc->n++;
	qunlock(&in->wcl);
	wcfreelist(dead);
}

/*
 * The up member's chan for path, if a step the cache keeps found the
 * name there (upwalk's shortcut); nil otherwise.
 */
static Chan*
wcup(Inst *in, char *path, int upmid)
{
	Wcache *wc;
	Wce *e;
	Chan *volatile c;
	vlong now;
	int lx;
	void *plan;

	lx = h9_fs_linkwalk();
	plan = h9_plan_get();
	now = h9_clock_mono();
	c = nil;
	qlock(&in->wcl);
	wc = in->wc;
	if(wc != nil)
		for(e = wc->tab[wchash(path)]; e != nil; e = e->next)
			if(e->ng > 0 && e->mid[0] == upmid && e->lx == lx && e->plan == plan &&
			   now - e->born <= Wcttl && strcmp(e->path, path) == 0){
				if(!waserror()){
					c = cclone(e->mc[0]);
					poperror();
				}
				break;
			}
	qunlock(&in->wcl);
	return c;
}

static int unstep(Unc*, Chan*, char*);
static void unfresh(Unc*);

/* Re-resolves u from the top along path, for "..". */
static void
unreroot(Unc *u, Chan *nc, char *path)
{
	char buf[Maxname];
	char *volatile p;
	int i, n;

	/*
	 * path is often u->path itself (uncreate, unremove), which is freed
	 * below, so walk a copy of it.
	 */
	p = strdup(path);
	if(p == nil)
		error(Enomem);
	if(waserror()){
		free(p);
		nexterror();
	}
	untop(u);
	free(u->path);
	u->path = strdup("");
	if(u->path == nil)
		error(Enomem);
	nc->qid = unrootqid();
	n = npathelem(p);
	for(i = 0; i < n; i++){
		pathelem(p, i, buf);
		if(!unstep(u, nc, buf))
			error(Enonexist);
	}
	poperror();
	free(p);
}

/*
 * Walks u by one name; returns 0 (with the error set) if it isn't there.
 * Members are taken in the instance's order: those that have u's
 * directory, and those rooted at the new name.
 */
static int
unstep(Unc *u, Chan *nc, char *name)
{
	Inst *in;
	Chan *have[Maxmembers], *c;
	int hid[Maxmembers], hcr[Maxmembers], hroot[Maxmembers], nh, i, j, k, decided;
	ulong gen;
	Chan *got[Maxmembers];
	int gid[Maxmembers], gcr[Maxmembers], ng;
	char *np, *dir, *s, why[ERRMAX];
	int kmid[Maxmembers], nkey, wc;
	ulong wseq;
	vlong born;

	if(strcmp(name, ".") == 0)
		return 1;
	if(strcmp(name, "..") == 0){
		if(u->path[0] == '\0')
			return 1;
		dir = strdup(u->path);
		if(dir == nil)
			error(Enomem);
		s = strrchr(dir, '/');
		if(s != nil)
			*s = '\0';
		else
			dir[0] = '\0';
		if(waserror()){
			free(dir);
			nexterror();
		}
		unreroot(u, nc, dir);
		poperror();
		free(dir);
		return 1;
	}
	if((nc->qid.type & QTDIR) == 0){
		kstrcpy(up->errstr, Enotdir, ERRMAX);
		return 0;
	}
	in = u->inst;
	/* Before unfresh, so a directory the layer makes meanwhile is looked for again. */
	qlock(&in->ql);
	gen = in->upgen;
	qunlock(&in->ql);
	unfresh(u);
	np = pathjoin(u->path, name);

	/* The walk cache: what an earlier step from the same members found. */
	wc = wcon(in);
	nkey = 0;
	wseq = 0;
	born = 0;
	ng = 0;
	if(wc){
		born = h9_clock_mono();
		switch(wcget(in, u, np, got, gid, gcr, &ng, &wseq)){
		case -1:
			free(np);
			kstrcpy(up->errstr, Enonexist, ERRMAX);
			return 0;
		case 1:
			goto found;
		}
		nkey = u->n;
		memmove(kmid, u->mid, nkey*sizeof(int));
	}

	/*
	 * In member order: u's chans (at the top, every member rooted there,
	 * so members added since u was made are seen), and fresh roots of
	 * members rooted at np, which aren't walked.
	 */
	nh = 0;
	qlock(&in->ql);
	for(i = 0; i < in->nmem && nh < Maxmembers; i++){
		if(u->noup && in->mem[i].isup)
			continue;
		c = nil;
		hroot[nh] = 0;
		for(j = 0; j < u->n; j++)
			if(u->mid[j] == in->mem[i].id)
				break;
		if(j < u->n)
			c = cclone(u->mc[j]);
		else if(u->path[0] == '\0' && in->mem[i].at[0] == '\0')
			c = cclone(in->mem[i].root);
		else if(strcmp(in->mem[i].at, np) == 0){
			c = cclone(in->mem[i].root);
			hroot[nh] = 1;
		}
		if(c == nil)
			continue;
		have[nh] = c;
		hid[nh] = in->mem[i].id;
		hcr[nh] = in->mem[i].create;
		nh++;
	}
	qunlock(&in->ql);

	ng = 0;
	decided = 0;
	why[0] = '\0';
	for(k = 0; k < nh; k++){
		c = have[k];
		have[k] = nil;
		/* A member rooted at np is its own root, not walked. */
		if(!hroot[k]){
			Chan *w;
			up->errstr[0] = '\0';
			w = lowerwalk1(c, name);
			if(w == nil){
				/* The first member's reason, such as a link loop. */
				if(why[0] == '\0')
					utfecpy(why, why+sizeof why, up->errstr);
				/* A whiteout hides the name in the members below. */
				if(k < nh-1 && haswh(c, name)){
					cclose(c);
					if(!decided)
						strecpy(why, why+sizeof why, Enonexist);
					break;
				}
				cclose(c);
				continue;
			}
			cclose(c);
			c = w;
		}
		if(!decided){
			decided = 1;
			got[ng] = c; gid[ng] = hid[k]; gcr[ng] = hcr[k]; ng++;
			if((c->qid.type & QTDIR) == 0)
				break;
			/* An opaque directory isn't merged with those below it. */
			if(k < nh-1 && isopaque(c))
				break;
			continue;
		}
		if((c->qid.type & QTDIR) == 0){
			cclose(c);	/* hidden by a directory above it */
			continue;
		}
		got[ng] = c; gid[ng] = hid[k]; gcr[ng] = hcr[k]; ng++;
		if(k < nh-1 && isopaque(c))
			break;
	}
	for(; k < nh; k++)
		if(have[k] != nil)
			cclose(have[k]);
	if(ng == 0){
		if(wc && (why[0] == '\0' || strcmp(why, Enonexist) == 0))
			wcput(in, u->noup, kmid, nkey, np, wseq, born, got, gid, gcr, 0);
		free(np);
		kstrcpy(up->errstr, why[0] != '\0' ? why : Enonexist, ERRMAX);
		return 0;
	}
	if(wc)
		wcput(in, u->noup, kmid, nkey, np, wseq, born, got, gid, gcr, ng);
found:
	unclear(u);
	for(i = 0; i < ng; i++){
		u->mc[i] = got[i];
		u->mid[i] = gid[i];
		u->mcreate[i] = gcr[i];
	}
	u->n = ng;
	u->upseen = gen;
	free(u->path);
	u->path = np;
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	nc->qid = unqid(in, u->mc[0]);
	poperror();
	qunlock(&in->ql);
	return 1;
}

static Walkqid*
unwalk(Chan *c, Chan *nc, char **name, int nname)
{
	Walkqid *wq;
	Unc *u, *volatile nu;
	Inst *in;
	int i;

	u = c->aux;
	in = u->inst;
	wq = smalloc(sizeof(Walkqid)+(nname > 0 ? nname-1 : 0)*sizeof(Qid));
	nc = devclone(c);
	nc->type = 0;
	nc->aux = nil;
	nu = nil;
	lock(&instlock);
	in->ref++;
	unlock(&instlock);
	if(waserror()){
		/* A member's error, such as a link loop, is the walk's. */
		if(nu != nil)
			uncfree(nu);
		else
			instdecref(in);
		cclose(nc);
		free(wq);
		nexterror();
	}
	nu = uncnew(in, u->path);
	for(i = 0; i < u->n; i++){
		nu->mc[i] = cclone(u->mc[i]);
		nu->mid[i] = u->mid[i];
		nu->mcreate[i] = u->mcreate[i];
		nu->n = i+1;
	}
	nu->noup = u->noup;
	nu->upseen = u->upseen;
	if(nname == 0)
		unfresh(nu);
	for(i = 0; i < nname; i++){
		if(!unstep(nu, nc, name[i]))
			break;
		wq->qid[i] = nc->qid;
		/* A Linux process's walk stops at a member's link (ovwalk). */
		if(nc->qid.type & H9_QTSYMLINK){
			i++;
			break;
		}
	}
	wq->nqid = i;
	poperror();
	if(i < nname){
		uncfree(nu);
		cclose(nc);
		if(i == 0){
			free(wq);
			return nil;
		}
		wq->clone = nil;
		return wq;
	}
	nc->aux = nu;
	nc->type = c->type;
	wq->clone = nc;
	return wq;
}

static int
unstat(Chan *c, uchar *db, int n)
{
	Unc *u;
	Inst *in;
	Dir d;
	uchar buf[1024+4*Maxname];
	char strs[sizeof buf], *s;
	int r;

	u = c->aux;
	in = u->inst;
	s = strrchr(u->path, '/');
	s = s != nil ? s+1 : u->path;
	if(u->path[0] == '\0' && (c->flag & COPEN) == 0)
		untop(u);
	if(u->n == 0){
		/* The top of a union with no members there: an empty directory. */
		memset(&d, 0, sizeof d);
		d.name = "/";
		d.uid = d.gid = d.muid = eve;
		d.qid = unrootqid();
		d.mode = DMDIR|0555;
		d.atime = d.mtime = seconds();
	}else{
		lowerstat(u->mc[0], &d, buf, sizeof buf, strs);
		qlock(&in->ql);
		if(waserror()){
			qunlock(&in->ql);
			nexterror();
		}
		d.qid = u->path[0] == '\0' ? unrootqid() : unqid(in, u->mc[0]);
		poperror();
		qunlock(&in->ql);
		if(u->path[0] == '\0')
			d.name = "/";
		else
			d.name = s;
		if(d.qid.type & QTDIR)
			d.length = 0;
	}
	r = convD2M(&d, db, n);
	if(r == 0)
		error(Eshortstat);
	return r;
}

/* Appends m bytes at p to u's snapshot. */
static void
undirput(Unc *u, uchar *p, long m)
{
	uchar *nb;
	long cap;

	if(u->ndir + m > u->dircap){
		cap = (u->ndir + m) * 2 + 8192;
		cap = (cap + Pgsize-1) & ~(Pgsize-1);
		nb = h9_overlay_alloc(u->inst->pool, cap);
		if(nb == nil)
			error(Efull);
		if(u->dir != nil){
			memmove(nb, u->dir, u->ndir);
			h9_overlay_free(u->inst->pool, u->dir, u->dircap);
		}
		u->dir = nb;
		u->dircap = cap;
	}
	memmove(u->dir + u->ndir, p, m);
	u->ndir += m;
}

/* Whether the snapshot has an entry by name. */
static int
undirhas(Unc *u, char *name, ulong *htab, int hsize)
{
	ulong h;
	int i;
	Dir d;
	char strs[4*Maxname+16];
	uchar *p;

	h = namehash(name);
	for(i = 0; i < hsize; i++){
		ulong off = htab[(h + i) % hsize];
		if(off == 0)
			return 0;
		p = u->dir + off - 1;
		if(convM2D(p, BIT16SZ + GBIT16(p), &d, strs) > 0 && strcmp(d.name, name) == 0)
			return 1;
	}
	return 0;
}

/* A set of names, for the names a member's whiteouts hide below it. */
typedef struct Hide Hide;
struct Hide
{
	char	**tab;
	int	size;
	int	n;
};

static int
hidehas(Hide *h, char *name)
{
	int k;

	if(h->size == 0)
		return 0;
	for(k = namehash(name) % h->size; h->tab[k] != nil; k = (k+1) % h->size)
		if(strcmp(h->tab[k], name) == 0)
			return 1;
	return 0;
}

static void
hideput(Hide *h, char *name)
{
	char **ot;
	int i, k, os;

	if(hidehas(h, name))
		return;
	if((h->n+1)*2 > h->size){
		ot = h->tab;
		os = h->size;
		h->size = os ? os*2 : 64;
		h->tab = mallocz(h->size*sizeof(char*), 1);
		if(h->tab == nil){
			h->tab = ot;
			h->size = os;
			error(Enomem);
		}
		for(i = 0; i < os; i++)
			if(ot[i] != nil){
				for(k = namehash(ot[i]) % h->size; h->tab[k] != nil; k = (k+1) % h->size)
					;
				h->tab[k] = ot[i];
			}
		free(ot);
	}
	for(k = namehash(name) % h->size; h->tab[k] != nil; k = (k+1) % h->size)
		;
	h->tab[k] = strdup(name);
	if(h->tab[k] == nil)
		error(Enomem);
	h->n++;
}

static void
hidefree(Hide *h)
{
	int i;

	for(i = 0; i < h->size; i++)
		free(h->tab[i]);
	free(h->tab);
	h->tab = nil;
	h->size = h->n = 0;
}

/*
 * Packs the merged directory into u's snapshot: each name once, the
 * first member's entry, leaving out whiteouts, the names they hide in
 * the members below them, and the members below an opaque directory.
 * With probe, stores nothing, and returns 1 at the first name it would
 * list: whether the merged directory has any.
 */
static int
unlist(Unc *u, int probe)
{
	Inst *in;
	Chan *volatile lc;
	Dir d;
	uchar *volatile buf;
	ulong *volatile htab;
	uchar *p, *e;
	char *strs;
	long r, m;
	vlong off;
	int i, k, hsize, nent, opaque, found;
	Hide hide, pend;

	in = u->inst;
	if(!probe)
		undirfree(u);
	lc = nil;
	buf = nil;
	htab = nil;
	hsize = 0;
	nent = 0;
	found = 0;
	memset(&hide, 0, sizeof hide);
	memset(&pend, 0, sizeof pend);
	if(waserror()){
		if(lc != nil)
			cclose(lc);
		free(buf);
		free(htab);
		hidefree(&hide);
		hidefree(&pend);
		nexterror();
	}
	buf = smalloc(8192 + 8192);
	strs = (char*)buf + 8192;
	for(i = 0; i < u->n && !found; i++){
		opaque = 0;
		lc = cclone(u->mc[i]);
		lc = devtab[lc->type]->open(lc, OREAD);
		for(off = 0; !found; off += r){
			r = devtab[lc->type]->read(lc, buf, 8192, off);
			if(r <= 0)
				break;
			e = buf + r;
			for(p = buf; p + BIT16SZ <= e; p += m){
				m = BIT16SZ + GBIT16(p);
				if(p + m > e || convM2D(p, m, &d, strs) != m)
					break;
				if(iswhname(d.name)){
					if(strcmp(d.name, Whopaque) == 0)
						opaque = 1;
					else if(i < u->n-1)
						hideput(&pend, d.name+4);
					continue;
				}
				if(hidehas(&hide, d.name))
					continue;
				if(probe){
					found = 1;
					break;
				}
				if(nent*2 >= hsize){
					/* Rebuild the name table, twice as big. */
					ulong *nt;
					uchar *q;
					long o2;
					int ns;

					ns = hsize ? hsize*2 : 256;
					nt = mallocz(ns*sizeof(ulong), 1);
					if(nt == nil)
						error(Enomem);
					for(o2 = 0; o2 + BIT16SZ <= u->ndir; o2 += BIT16SZ + GBIT16(u->dir+o2)){
						Dir d2;
						char s2[4*Maxname+16];
						q = u->dir + o2;
						if(convM2D(q, BIT16SZ + GBIT16(q), &d2, s2) <= 0)
							continue;
						for(k = namehash(d2.name) % ns; nt[k] != 0; k = (k+1) % ns)
							;
						nt[k] = o2 + 1;
					}
					free(htab);
					htab = nt;
					hsize = ns;
				}
				if(undirhas(u, d.name, htab, hsize))
					continue;
				qlock(&in->ql);
				if(waserror()){
					qunlock(&in->ql);
					nexterror();
				}
				{
					/* The entry's qid, as a walk to it gives it: the member chan's device. */
					Chan tmp;
					memset(&tmp, 0, sizeof tmp);
					tmp.type = lc->type;
					tmp.dev = lc->dev;
					tmp.qid = d.qid;
					d.qid = unqid(in, &tmp);
				}
				poperror();
				qunlock(&in->ql);
				{
					uchar ent[1024+4*Maxname];
					long em;
					em = convD2M(&d, ent, sizeof ent);
					if(em <= BIT16SZ)
						continue;
					for(k = namehash(d.name) % hsize; htab[k] != 0; k = (k+1) % hsize)
						;
					htab[k] = u->ndir + 1;
					undirput(u, ent, em);
					nent++;
				}
			}
		}
		cclose(lc);
		lc = nil;
		/* This member's whiteouts apply to the members below it, not to itself. */
		for(k = 0; k < pend.size; k++)
			if(pend.tab[k] != nil)
				hideput(&hide, pend.tab[k]);
		hidefree(&pend);
		if(opaque)
			break;
	}
	poperror();
	free(buf);
	free(htab);
	hidefree(&hide);
	hidefree(&pend);
	return found;
}

static void
unsnapshot(Chan *c)
{
	unlist(c->aux, 0);
}

/*
 * Up layers (design/epoch-0/upper-layers.md). A union's up member, always its
 * first, is a writable tree over the others, as overlayfs's upperdir is:
 * a file from below is copied into it on its first change, a removed
 * name below gets a whiteout in it, and a directory made again over a
 * whiteout is opaque, so the tree is an OCI image layer, unpacked. Its
 * changes are made through its own device, so a host directory, an #O
 * tree in memory, or a 9P server keeps them. A member rooted below the
 * top takes the changes under its path only.
 *
 * upql serializes the layer's changes, so two chans copying one file up
 * don't both make it. It's held across device calls; in->ql isn't.
 */

/* The up member's id, if in has one and path is under it; -1 otherwise. */
static int
upid(Inst *in, char *path)
{
	Member *m;
	int n, id;

	id = -1;
	qlock(&in->ql);
	if(in->nmem > 0 && in->mem[0].isup){
		m = &in->mem[0];
		n = strlen(m->at);
		if(n == 0 || (strncmp(path, m->at, n) == 0 && (path[n] == '\0' || path[n] == '/')))
			id = m->id;
	}
	qunlock(&in->ql);
	return id;
}

/* Whether u's name is from below the layer, under an up member. */
static int
upbelow(Unc *u)
{
	int id;

	id = upid(u->inst, u->path);
	return id >= 0 && u->n > 0 && u->mid[0] != id;
}

/* The first n names of path, allocated. */
static char*
pathprefix(char *path, int n)
{
	char *p, *e;

	e = path;
	while(n-- > 0 && *e != '\0'){
		e = strchr(e, '/');
		if(e == nil){
			e = path + strlen(path);
			break;
		}
		if(n > 0)
			e++;
	}
	p = malloc(e - path + 1);
	if(p == nil)
		error(Enomem);
	memmove(p, path, e - path);
	p[e - path] = '\0';
	return p;
}

/*
 * A fresh walk of in from its top along path, without the up member if
 * noup: what's below the layer. nil if there's nothing there. The Unc
 * holds a ref on in.
 */
static Unc*
unlookup(Inst *in, char *path, int noup)
{
	Unc *volatile u;
	Chan tmp;
	char buf[Maxname];
	int i, n;

	lock(&instlock);
	in->ref++;
	unlock(&instlock);
	u = nil;
	if(waserror()){
		if(u != nil)
			uncfree(u);
		else
			instdecref(in);
		nexterror();
	}
	u = uncnew(in, "");
	u->noup = noup;
	untop(u);
	memset(&tmp, 0, sizeof tmp);
	tmp.qid = unrootqid();
	n = npathelem(path);
	for(i = 0; i < n; i++){
		pathelem(path, i, buf);
		if(!unstep(u, &tmp, buf) || u->n == 0){
			poperror();
			uncfree(u);
			return nil;
		}
	}
	poperror();
	if(u->n == 0){
		uncfree(u);
		return nil;
	}
	return u;
}

/* Whether path exists below the layer, and if so whether it's a directory. */
static int
upexists(Inst *in, char *path, int noup, int *isdir)
{
	Unc *t;

	t = unlookup(in, path, noup);
	if(t == nil)
		return 0;
	if(isdir != nil)
		*isdir = (t->mc[0]->qid.type & QTDIR) != 0;
	uncfree(t);
	return 1;
}

/* Notes a directory made in the up member's tree (unfresh). */
static void
upmade(Inst *in)
{
	qlock(&in->ql);
	in->upgen++;
	qunlock(&in->ql);
}

static Chan* upwalk(Inst*, char*, int);

/*
 * A directory named while the up layer didn't have it, such as a
 * process's working directory, has only the members below the layer.
 * Once the layer has made directories since u's members were found,
 * look for u's in it again, so that walks, reads, and creates from u
 * see what's changed there, as they would from a fresh walk.
 */
static void
unfresh(Unc *u)
{
	Inst *in;
	Chan *volatile c;
	ulong gen;
	int i, id, cr;

	in = u->inst;
	if(u->noup || u->n == 0 || u->dir != nil || (u->mc[0]->qid.type & QTDIR) == 0)
		return;
	qlock(&in->ql);
	gen = in->upgen;
	qunlock(&in->ql);
	if(u->upseen == gen)
		return;
	u->upseen = gen;
	if(!upbelow(u))
		return;
	c = upwalk(in, u->path, 0);
	if(c == nil)
		return;
	if((c->qid.type & QTDIR) == 0){
		cclose(c);
		return;
	}
	qlock(&in->ql);
	id = in->mem[0].id;
	cr = in->mem[0].create;
	qunlock(&in->ql);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	if(isopaque(c)){
		for(i = 0; i < u->n; i++)
			cclose(u->mc[i]);
		u->n = 0;
	}else if(u->n == Maxmembers){
		cclose(u->mc[--u->n]);
	}
	poperror();
	for(i = u->n; i > 0; i--){
		u->mc[i] = u->mc[i-1];
		u->mid[i] = u->mid[i-1];
		u->mcreate[i] = u->mcreate[i-1];
	}
	u->mc[0] = c;
	u->mid[0] = id;
	u->mcreate[0] = cr;
	u->n++;
}

/*
 * Walks the up member to path, a union path under it. With make, a
 * directory missing from the layer is made there, with the mode of the
 * one below it; without, a missing name is nil.
 */
static Chan*
upwalk(Inst *in, char *path, int make)
{
	Chan *volatile c, *volatile nc;
	Unc *volatile t;
	char *volatile pre;
	char buf[Maxname];
	Dir d;
	uchar sbuf[1024+4*Maxname];
	char strs[sizeof sbuf];
	int i, n, nat, upmid;
	uvlong qp;

	qlock(&in->ql);
	if(in->nmem == 0 || !in->mem[0].isup){
		qunlock(&in->ql);
		return nil;
	}
	c = cclone(in->mem[0].root);
	nat = npathelem(in->mem[0].at);
	upmid = in->mem[0].id;
	qunlock(&in->ql);
	if(path[0] != '\0' && (nc = wcup(in, path, upmid)) != nil){
		cclose(c);
		return nc;
	}
	t = nil;
	nc = nil;
	pre = nil;
	if(waserror()){
		cclose(c);
		if(nc != nil)
			cclose(nc);
		if(t != nil)
			uncfree(t);
		free(pre);
		nexterror();
	}
	n = npathelem(path);
	for(i = nat; i < n; i++){
		pathelem(path, i, buf);
		nc = lowerwalk1(c, buf);
		if(nc == nil){
			if(!make){
				poperror();
				cclose(c);
				return nil;
			}
			pre = pathprefix(path, i+1);
			t = unlookup(in, pre, 0);
			if(t == nil)
				error(Enonexist);
			lowerstat(t->mc[0], &d, sbuf, sizeof sbuf, strs);
			if((d.qid.type & QTDIR) == 0)
				error(Enotdir);
			qp = upqpath(in, t->mc[0]);
			uncfree(t);
			t = nil;
			nc = cclone(c);
			nc = devtab[nc->type]->create(nc, buf, OREAD, DMDIR|(d.mode & 0777));
			cclose(nc);
			upmade(in);
			/* The directory has the layer among its members now. */
			wcdrop(in, pre, 0);
			free(pre);
			pre = nil;
			nc = lowerwalk1(c, buf);
			if(nc == nil)
				error(Enonexist);
			upkeepqid(in, nc, qp);
		}
		cclose(c);
		c = nc;
		nc = nil;
	}
	poperror();
	return c;
}

/*
 * Makes name in the directory dir, on any device that has them, a
 * symbolic link, by its symlink operation (design/file-interface.md).
 */
static void
mklink(Chan *dir, char *name, char *target)
{
	devsymlink(dir, name, target);
}

/* As mklink, a FIFO. */
static void
mkfifo1(Chan *dir, char *name, ulong perm)
{
	Chan *volatile nc;

	switch(devtab[dir->type]->dc){
	case 'U':
		h9_fs_mkfifo(dir, name, perm);
		break;
	case 'O':
		h9_overlay_mkfifo(cclone(dir), name, perm);
		break;
	case 'M':
		/* A 9P2000.L server's makes a create with H9_DMFIFO a Tmknod. */
		nc = cclone(dir);
		if(waserror()){
			cclose(nc);
			nexterror();
		}
		nc = devtab[nc->type]->create(nc, name, OREAD, (perm & 0777)|H9_DMFIFO);
		poperror();
		cclose(nc);
		break;
	default:
		error(Eperm);
	}
}

/* Makes the empty file name in dir, for a whiteout or an opaque marker. */
static void
mkmark(Chan *dir, char *name)
{
	Chan *volatile nc;

	nc = cclone(dir);
	if(waserror()){
		cclose(nc);
		nexterror();
	}
	nc = devtab[nc->type]->create(nc, name, OREAD, 0444);
	poperror();
	cclose(nc);
}

/* Removes name from dir, if it's there. */
static void
rmname(Chan *dir, char *name)
{
	Chan *volatile c;

	c = lowerwalk1(dir, name);
	if(c == nil)
		return;
	if(waserror()){
		c->type = 0;
		cclose(c);
		nexterror();
	}
	devtab[c->type]->remove(c);
	c->type = 0;
	cclose(c);
	poperror();
}

/* Makes the whiteout for name in the layer directory dir. */
static void
mkwh(Chan *dir, char *name)
{
	char wh[Maxname];

	if(strlen(name) + 4 >= Maxname)
		error(Etoolong);
	snprint(wh, sizeof wh, "%s%s", Whprefix, name);
	mkmark(dir, wh);
}

/* Removes the whiteout for name from dir; whether there was one. */
static int
rmwh(Chan *dir, char *name)
{
	char wh[Maxname];

	if(!haswh(dir, name))
		return 0;
	snprint(wh, sizeof wh, "%s%s", Whprefix, name);
	rmname(dir, wh);
	return 1;
}

/* Removes the whiteouts and opaque marker in the layer directory dir. */
static void
rmmarks(Chan *dir)
{
	Chan *volatile lc;
	uchar *volatile buf;
	char **volatile names;
	volatile int nn;
	Dir d;
	char *strs;
	uchar *p, *e;
	long r, m;
	vlong off;
	int i, cap;

	lc = nil;
	buf = nil;
	names = nil;
	nn = 0;
	cap = 0;
	if(waserror()){
		if(lc != nil)
			cclose(lc);
		free(buf);
		for(i = 0; i < nn; i++)
			free(names[i]);
		free(names);
		nexterror();
	}
	buf = smalloc(8192 + 8192);
	strs = (char*)buf + 8192;
	lc = cclone(dir);
	lc = devtab[lc->type]->open(lc, OREAD);
	for(off = 0;; off += r){
		r = devtab[lc->type]->read(lc, buf, 8192, off);
		if(r <= 0)
			break;
		e = buf + r;
		for(p = buf; p + BIT16SZ <= e; p += m){
			m = BIT16SZ + GBIT16(p);
			if(p + m > e || convM2D(p, m, &d, strs) != m)
				break;
			if(!iswhname(d.name))
				continue;
			if(nn == cap){
				char **nb;
				cap = cap ? cap*2 : 16;
				nb = realloc(names, cap*sizeof(char*));
				if(nb == nil)
					error(Enomem);
				names = nb;
			}
			names[nn] = strdup(d.name);
			if(names[nn] == nil)
				error(Enomem);
			nn++;
		}
	}
	cclose(lc);
	lc = nil;
	for(i = 0; i < nn; i++)
		rmname(dir, names[i]);
	poperror();
	free(buf);
	for(i = 0; i < nn; i++)
		free(names[i]);
	free(names);
}

/* Points u at the layer's chan c for its name. */
static void
upset(Unc *u, Chan *c, int id)
{
	unclear(u);
	u->mc[0] = c;
	u->mid[0] = id;
	u->mcreate[0] = 1;
	u->n = 1;
	u->lopen = 0;
}

/*
 * Copies u's file from below into the layer, whole unless trunc, with
 * its parent directories, and points the chan at the copy. A link is
 * made again as a link, and a FIFO as a FIFO. Under upql.
 */
static void
upcopy(Chan *c, int trunc)
{
	Unc *u;
	Inst *in;
	Chan *volatile pd, *volatile lc, *volatile nc;
	Unc *volatile t;
	char *volatile pcopy;
	char *dir, *name, *s;
	uchar *volatile data;
	Dir d, nd;
	uchar sbuf[1024+4*Maxname];
	char strs[sizeof sbuf];
	uchar wbuf[256];
	vlong off;
	long r;
	int id, wasopen, n;

	u = c->aux;
	in = u->inst;
	id = upid(in, u->path);
	if(id < 0)
		error(Eperm);
	pcopy = strdup(u->path);
	if(pcopy == nil)
		error(Enomem);
	s = strrchr(pcopy, '/');
	if(s != nil){
		*s = '\0';
		dir = pcopy;
		name = s+1;
	}else{
		dir = "";
		name = pcopy;
	}
	pd = lc = nc = nil;
	t = nil;
	data = nil;
	if(waserror()){
		if(pd != nil)
			cclose(pd);
		if(lc != nil)
			cclose(lc);
		if(nc != nil)
			cclose(nc);
		if(t != nil)
			uncfree(t);
		free(data);
		free(pcopy);
		nexterror();
	}
	pd = upwalk(in, dir, 1);
	if(pd == nil)
		error(Eperm);
	/* Another chan may have copied it up already. */
	nc = lowerwalk1(pd, name);
	if(nc == nil){
		t = unlookup(in, u->path, 1);
		if(t == nil)
			error(Enonexist);
		lc = cclone(t->mc[0]);
		uncfree(t);
		t = nil;
		lowerstat(lc, &d, sbuf, sizeof sbuf, strs);
		if(d.qid.type & QTDIR)
			error(Eisdir);
		if((d.qid.type & H9_QTSYMLINK) || (d.mode & H9_DMSYMLINK)){
			char tgt[2048];
			n = devreadlink(lc, tgt, sizeof tgt);
			if(n < 0)
				error(Eperm);
			mklink(pd, name, tgt);
		}else if(d.mode & H9_DMFIFO)
			mkfifo1(pd, name, d.mode & 0777);
		else{
			nc = cclone(pd);
			nc = devtab[nc->type]->create(nc, name, OWRITE, d.mode & 0777);
			if(!trunc){
				lc = devtab[lc->type]->open(lc, OREAD);
				data = smalloc(Copybuf);
				for(off = 0; off < d.length; off += r){
					r = devtab[lc->type]->read(lc, data, Copybuf, off);
					if(r <= 0)
						break;
					devtab[nc->type]->write(nc, data, r, off);
				}
			}
			cclose(nc);
			nc = nil;
			/* The mode and times, as the create may have masked the mode. */
			nc = lowerwalk1(pd, name);
			if(nc != nil && !waserror()){
				ovnulldir(&nd);
				nd.mode = d.mode & ~DMDIR;
				nd.mtime = d.mtime;
				n = convD2M(&nd, wbuf, sizeof wbuf);
				devtab[nc->type]->wstat(nc, wbuf, n);
				poperror();
			}
			if(nc != nil)
				cclose(nc);
			nc = nil;
		}
		cclose(lc);
		lc = nil;
		nc = lowerwalk1(pd, name);
		if(nc == nil)
			error(Enonexist);
	}
	cclose(pd);
	pd = nil;
	wasopen = u->lopen;
	if(wasopen){
		/* An open chan goes on reading and writing, now the copy. */
		nc = devtab[nc->type]->open(nc, c->mode);
	}
	upset(u, nc, id);
	u->lopen = wasopen;
	nc = nil;
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	if(!wasopen)
		c->qid = unqid(in, u->mc[0]);
	poperror();
	qunlock(&in->ql);
	poperror();
	free(data);
	free(pcopy);
	changed(in, u->path);
}

static Chan*
unopen(Chan *c, int omode)
{
	Unc *u;
	Inst *in;
	int mode;

	u = c->aux;
	in = u->inst;
	mode = openmode(omode);
	if(c->qid.type & QTDIR){
		if(mode != OREAD || (omode & OTRUNC))
			error(Eisdir);
		if(u->path[0] == '\0')
			untop(u);
		else
			unfresh(u);
		unsnapshot(c);
	}else{
		if(u->n == 0)
			error(Enonexist);
		/* A file from below is copied into an up layer to be written. */
		if(((mode != OREAD && mode != OEXEC) || (omode & OTRUNC)) && upbelow(u)){
			qlock(&in->upql);
			if(waserror()){
				qunlock(&in->upql);
				nexterror();
			}
			upcopy(c, (omode & OTRUNC) != 0);
			poperror();
			qunlock(&in->upql);
		}
		u->mc[0] = devtab[u->mc[0]->type]->open(u->mc[0], omode & ~(ORCLOSE|OCEXEC));
		u->lopen = 1;
		qlock(&in->ql);
		if(waserror()){
			qunlock(&in->ql);
			nexterror();
		}
		c->qid = unqid(in, u->mc[0]);
		poperror();
		qunlock(&in->ql);
	}
	if(omode & ORCLOSE)
		c->flag |= CRCLOSE;
	c->mode = mode;
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static long
unread(Chan *c, void *a, long n, vlong off)
{
	Unc *u;
	long m, sz;

	u = c->aux;
	if(u->lopen)
		return devtab[u->mc[0]->type]->read(u->mc[0], a, n, off);
	if((c->qid.type & QTDIR) == 0)
		error(Eperm);
	if(off == 0 || u->dir == nil)
		unsnapshot(c);
	for(m = 0; off + m + BIT16SZ <= u->ndir; m += sz){
		sz = BIT16SZ + GBIT16(u->dir + off + m);
		if(m + sz > n)
			break;
	}
	if(m > 0)
		memmove(a, u->dir + off, m);
	return m;
}

static long
unwrite(Chan *c, void *a, long n, vlong off)
{
	Unc *u;

	u = c->aux;
	if(c->qid.type & QTDIR)
		error(Eisdir);
	if(!u->lopen)
		error(Eperm);
	return devtab[u->mc[0]->type]->write(u->mc[0], a, n, off);
}

/* Splits path into its directory (allocated) and last name (in path). */
static char*
pathsplit(char *path, char **name)
{
	char *s;

	s = strrchr(path, '/');
	if(s == nil){
		*name = path;
		return pathprefix(path, 0);
	}
	*name = s+1;
	return pathprefix(path, npathelem(path)-1);
}

/*
 * Makes name in u's directory in the layer, for uncreate: its parent
 * directories are copied up, a whiteout for it is removed, and a
 * directory made over one is opaque. Returns the new chan, as the
 * device's create left it.
 */
static Chan*
upcreate(Chan *c, char *name, char *np, int omode, ulong perm)
{
	Unc *u;
	Inst *in;
	Chan *volatile pd, *volatile nc, *volatile d;
	int isdir, waswh;

	u = c->aux;
	in = u->inst;
	if(iswhname(name))
		error(Eperm);
	qlock(&in->upql);
	pd = nc = d = nil;
	if(waserror()){
		if(pd != nil)
			cclose(pd);
		if(nc != nil)
			cclose(nc);
		if(d != nil)
			cclose(d);
		qunlock(&in->upql);
		nexterror();
	}
	if(upexists(in, np, 0, &isdir))
		if(isdir || (perm & DMDIR) || (omode & OEXCL))
			error(Eexist);
	pd = upwalk(in, u->path, 1);
	if(pd == nil)
		error(Eperm);
	waswh = rmwh(pd, name);
	nc = cclone(pd);
	nc = devtab[nc->type]->create(nc, name, omode, perm);
	if((perm & DMDIR) && waswh){
		d = lowerwalk1(pd, name);
		if(d != nil)
			mkmark(d, Whopaque);
	}
	/* After the opaque marker, so that unfresh never sees the directory without it. */
	if(perm & DMDIR)
		upmade(in);
	poperror();
	if(d != nil)
		cclose(d);
	cclose(pd);
	qunlock(&in->upql);
	changed(in, np);
	return nc;
}

/*
 * Removes u's name under the layer: from the layer if it's there, with
 * a whiteout in its place if the name exists below.
 */
static void
upremove(Unc *u)
{
	Inst *in;
	Unc *volatile t;
	Chan *volatile lc, *volatile pd;
	char *volatile dir;
	char *name;
	int id, isdir, inlayer, below;

	in = u->inst;
	id = upid(in, u->path);
	qlock(&in->upql);
	t = nil;
	lc = pd = nil;
	dir = nil;
	if(waserror()){
		if(t != nil)
			uncfree(t);
		if(lc != nil)
			cclose(lc);
		if(pd != nil)
			cclose(pd);
		free(dir);
		qunlock(&in->upql);
		nexterror();
	}
	t = unlookup(in, u->path, 0);
	if(t == nil)
		error(Enonexist);
	isdir = (t->mc[0]->qid.type & QTDIR) != 0;
	if(isdir && unlist(t, 1))
		error(Enotempty);
	inlayer = t->mid[0] == id;
	uncfree(t);
	t = nil;
	below = upexists(in, u->path, 1, nil);
	dir = pathsplit(u->path, &name);
	if(inlayer){
		lc = upwalk(in, u->path, 0);
		if(lc == nil)
			error(Enonexist);
		if(isdir){
			rmmarks(lc);
			wcdrop(in, nil, 1);
		}
		devtab[lc->type]->remove(lc);
		lc->type = 0;
		cclose(lc);
		lc = nil;
	}
	if(below){
		pd = upwalk(in, dir, 1);
		if(pd == nil)
			error(Eperm);
		mkwh(pd, name);
		cclose(pd);
		pd = nil;
	}
	poperror();
	changed(in, u->path);
	free(dir);
	qunlock(&in->upql);
}

/*
 * Makes name in the union directory c a link to target, or with target
 * nil a FIFO: in the layer when it's under one, and otherwise in the
 * first member that takes creates.
 */
static void
unmknod(Chan *c, char *name, char *target, ulong perm)
{
	Unc *u;
	Inst *in;
	Chan *volatile pd;
	char *volatile np;
	int i;

	u = c->aux;
	in = u->inst;
	if(!ovname(name))
		error(strlen(name) >= Maxname ? Etoolong : Ebadchar);
	np = pathjoin(u->path, name);
	pd = nil;
	if(waserror()){
		free(np);
		if(pd != nil)
			cclose(pd);
		nexterror();
	}
	if(upid(in, np) < 0){
		if(u->path[0] == '\0')
			untop(u);
		for(i = 0; i < u->n; i++)
			if(u->mcreate[i])
				break;
		if(i == u->n)
			error(Enocreate);
		if(target != nil)
			mklink(u->mc[i], name, target);
		else
			mkfifo1(u->mc[i], name, perm);
		wcdrop(in, np, 0);
	}else{
		if(iswhname(name))
			error(Eperm);
		qlock(&in->upql);
		if(waserror()){
			qunlock(&in->upql);
			nexterror();
		}
		if(upexists(in, np, 0, nil))
			error(Eexist);
		pd = upwalk(in, u->path, 1);
		if(pd == nil)
			error(Eperm);
		rmwh(pd, name);
		if(target != nil)
			mklink(pd, name, target);
		else
			mkfifo1(pd, name, perm);
		poperror();
		qunlock(&in->upql);
		changed(in, np);
	}
	poperror();
	if(pd != nil)
		cclose(pd);
	free(np);
}

static char Exdev[] = "cross-device link";	/* Linux's EXDEV (src/dotl/attr.zig) */

/*
 * Moves c's name to name in the directory dc, both union chans, for
 * h9_overlay_move: within a layer, with the layer's own rename. A file
 * from below is copied up first, and its old name whited out. Returns
 * 1 if it can't (a directory from below, or a device that can't rename
 * across directories), and 0 once moved.
 */
static int
unmove(Chan *c, Chan *dc, char *name)
{
	Unc *u, *ud;
	Inst *in;
	Unc *volatile t;
	Chan *volatile oc, *volatile pd, *volatile od, *volatile d;
	char *volatile np, *volatile odir;
	char *oname;
	int id, isdir, tdir, inlayer, waswh, belowold, belownew, r;
	uchar wbuf[Maxname+64];
	Dir nd;

	u = c->aux;
	ud = dc->aux;
	in = u->inst;
	if(ud->inst != in)
		return 1;
	if(!ovname(name))
		error(strlen(name) >= Maxname ? Etoolong : Ebadchar);
	np = pathjoin(ud->path, name);
	id = upid(in, u->path);
	if(id < 0 || upid(in, np) < 0){
		free(np);
		return 1;
	}
	t = nil;
	oc = pd = od = d = nil;
	odir = nil;
	qlock(&in->upql);
	if(waserror()){
		if(t != nil)
			uncfree(t);
		if(oc != nil)
			cclose(oc);
		if(pd != nil)
			cclose(pd);
		if(od != nil)
			cclose(od);
		if(d != nil)
			cclose(d);
		free(np);
		free(odir);
		qunlock(&in->upql);
		nexterror();
	}
	if(iswhname(name))
		error(Eperm);
	if(u->path[0] == '\0')
		error(Eperm);
	if(strcmp(np, u->path) == 0){
		poperror();
		free(np);
		qunlock(&in->upql);
		return 0;
	}
	t = unlookup(in, u->path, 0);
	if(t == nil)
		error(Enonexist);
	isdir = (t->mc[0]->qid.type & QTDIR) != 0;
	inlayer = t->mid[0] == id;
	uncfree(t);
	t = nil;
	belowold = upexists(in, u->path, 1, nil);
	if(isdir && belowold){
		/* overlayfs without redirect_dir: mv copies instead. */
		poperror();
		free(np);
		qunlock(&in->upql);
		return 1;
	}
	if(isdir && strncmp(np, u->path, strlen(u->path)) == 0 && np[strlen(u->path)] == '/')
		error(Ebadarg);	/* into itself: EINVAL */
	belownew = upexists(in, np, 1, nil);
	if(upexists(in, np, 0, &tdir) && tdir){
		t = unlookup(in, np, 0);
		if(t != nil && unlist(t, 1))
			error(Enotempty);
		if(t != nil && t->mid[0] == id){
			/* An empty directory in the layer: its markers would keep the host's rename from replacing it. */
			d = upwalk(in, np, 0);
			if(d != nil){
				rmmarks(d);
				devtab[d->type]->remove(d);
				d->type = 0;
				cclose(d);
				d = nil;
			}
		}
		if(t != nil)
			uncfree(t);
		t = nil;
	}
	if(!inlayer)
		upcopy(c, 0);
	odir = pathsplit(u->path, &oname);
	oc = upwalk(in, u->path, 0);
	pd = upwalk(in, ud->path, 1);
	if(oc == nil || pd == nil)
		error(Enonexist);
	waswh = rmwh(pd, name);
	/* The layer's own rename, where its device has one (design/file-interface.md). */
	r = devrename(oc, pd, name);
	if(r != 0 && strcmp(odir, ud->path) == 0){
		/* In one directory, any device renames with a wstat. */
		ovnulldir(&nd);
		nd.name = name;
		devtab[oc->type]->wstat(oc, wbuf, convD2M(&nd, wbuf, sizeof wbuf));
		r = 0;
	}
	if(r != 0){
		if(waswh)
			mkwh(pd, name);
	}else{
		if(belowold){
			od = upwalk(in, odir, 1);
			if(od != nil)
				mkwh(od, oname);
		}
		if(isdir && (waswh || belownew)){
			d = lowerwalk1(pd, name);
			if(d != nil)
				mkmark(d, Whopaque);
		}
		wcdrop(in, nil, 1);
		changed(in, u->path);
		changed(in, np);
	}
	poperror();
	if(oc != nil)
		cclose(oc);
	if(pd != nil)
		cclose(pd);
	if(od != nil)
		cclose(od);
	if(d != nil)
		cclose(d);
	free(np);
	free(odir);
	qunlock(&in->upql);
	return r != 0;
}

static Chan*
uncreate(Chan *c, char *name, int omode, ulong perm)
{
	Unc *u;
	Inst *in;
	Chan *volatile nc;
	char *np;
	int i, id, cr;

	u = c->aux;
	in = u->inst;
	if((c->qid.type & QTDIR) == 0)
		error(Enotdir);
	if(!ovname(name))
		error(strlen(name) >= Maxname ? Etoolong : Ebadchar);
	if(u->path[0] == '\0')
		untop(u);
	else
		unfresh(u);
	np = pathjoin(u->path, name);
	if((id = upid(in, np)) >= 0){
		if(waserror()){
			free(np);
			nexterror();
		}
		nc = upcreate(c, name, np, omode & ~OCEXEC, perm);
		poperror();
		cr = 1;
	}else{
		for(i = 0; i < u->n; i++)
			if(u->mcreate[i])
				break;
		if(i == u->n){
			free(np);
			error(Enocreate);
		}
		nc = cclone(u->mc[i]);
		if(waserror()){
			cclose(nc);
			free(np);
			nexterror();
		}
		nc = devtab[nc->type]->create(nc, name, omode & ~OCEXEC, perm);
		poperror();
		wcdrop(in, np, 0);
		id = u->mid[i];
		cr = u->mcreate[i];
	}
	upset(u, nc, id);
	u->mcreate[0] = cr;
	free(u->path);
	u->path = np;
	u->lopen = (nc->qid.type & QTDIR) == 0;
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	c->qid = unqid(in, nc);
	poperror();
	qunlock(&in->ql);
	if(!u->lopen){
		/* A directory: readable as the new member directory, through a snapshot. */
		cclose(u->mc[0]);
		u->mc[0] = nil;
		u->n = 0;
		unreroot(u, c, np);
	}
	if(omode & ORCLOSE)
		c->flag |= CRCLOSE;
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
unremove(Chan *c)
{
	Unc *u;
	Chan *mc;
	int isdir;

	u = c->aux;
	if(waserror()){
		c->aux = nil;
		uncfree(u);
		nexterror();
	}
	if(u->path[0] == '\0' || u->n == 0)
		error(Eperm);
	if(upid(u->inst, u->path) >= 0){
		unclear(u);
		u->lopen = 0;
		upremove(u);
		poperror();
		c->aux = nil;
		uncfree(u);
		return;
	}
	mc = u->mc[0];
	u->mc[0] = nil;
	if(u->lopen){
		/* An open chan can't be removed by devfs and the like: a fresh one can. */
		cclose(mc);
		mc = nil;
		unreroot(u, c, u->path);
		mc = u->mc[0];
		u->mc[0] = nil;
	}
	isdir = (mc->qid.type & QTDIR) != 0;
	devtab[mc->type]->remove(mc);
	wcdrop(u->inst, u->path, isdir);
	poperror();
	c->aux = nil;
	uncfree(u);
}

static void
unclose(Chan *c)
{
	Unc *u;
	Chan *mc;

	u = c->aux;
	if(u == nil)
		return;
	if((c->flag & (COPEN|CRCLOSE)) == (COPEN|CRCLOSE) && u->n > 0 && !waserror()){
		if(upid(u->inst, u->path) >= 0){
			unclear(u);
			u->lopen = 0;
			upremove(u);
		}else{
			if(u->lopen){
				cclose(u->mc[0]);
				u->mc[0] = nil;
				u->lopen = 0;
				unreroot(u, c, u->path);
			}
			mc = u->mc[0];
			u->mc[0] = nil;
			devtab[mc->type]->remove(mc);
			wcdrop(u->inst, u->path, 1);
		}
		poperror();
	}
	c->aux = nil;
	uncfree(u);
}

/*
 * A wstat under the layer: a file from below is copied up, and a
 * directory made in the layer, before it's changed there. A rename
 * whites out the old name if it exists below, and a directory from
 * below can't be renamed.
 */
static int
upwstat(Chan *c, uchar *db, int n)
{
	Unc *u;
	Inst *in;
	Chan *volatile pd, *volatile d;
	char *volatile dir, *volatile np;
	char *name, *strs;
	Dir dd;
	int isdir, chname, change, waswh, belowold, r;

	u = c->aux;
	in = u->inst;
	strs = smalloc(n);
	pd = d = nil;
	dir = np = nil;
	qlock(&in->upql);
	if(waserror()){
		if(pd != nil)
			cclose(pd);
		if(d != nil)
			cclose(d);
		free(dir);
		free(np);
		free(strs);
		qunlock(&in->upql);
		nexterror();
	}
	if(convM2D(db, n, &dd, strs) != n)
		error(Ebadstat);
	dir = pathsplit(u->path, &name);
	isdir = (u->mc[0]->qid.type & QTDIR) != 0;
	chname = dd.name[0] != '\0' && strcmp(dd.name, name) != 0;
	change = chname || dd.mode != (ulong)~0 || dd.mtime != (ulong)~0 || dd.length != ~0LL ||
		dd.uid[0] != '\0' || dd.gid[0] != '\0';
	if(chname && iswhname(dd.name))
		error(Eperm);
	belowold = upexists(in, u->path, 1, nil);
	if(chname && isdir && belowold)
		error(Exdev);
	if(change && upbelow(u)){
		if(isdir){
			d = upwalk(in, u->path, 1);
			cclose(d);
			d = nil;
			unreroot(u, c, u->path);
			changed(in, u->path);
		}else
			upcopy(c, dd.length == 0);
	}
	waswh = 0;
	if(chname){
		np = pathjoin(dir, dd.name);
		pd = upwalk(in, dir, 1);
		if(pd == nil)
			error(Enonexist);
		waswh = rmwh(pd, dd.name);
		if(waserror()){
			if(waswh)
				mkwh(pd, dd.name);
			nexterror();
		}
		r = devtab[u->mc[0]->type]->wstat(u->mc[0], db, n);
		poperror();
		if(belowold)
			mkwh(pd, name);
		if(isdir && waswh){
			d = lowerwalk1(pd, dd.name);
			if(d != nil)
				mkmark(d, Whopaque);
		}
		wcdrop(in, nil, 1);
		changed(in, u->path);
		changed(in, np);
		free(u->path);
		u->path = np;
		np = nil;
	}else
		r = devtab[u->mc[0]->type]->wstat(u->mc[0], db, n);
	poperror();
	if(pd != nil)
		cclose(pd);
	if(d != nil)
		cclose(d);
	free(dir);
	free(strs);
	qunlock(&in->upql);
	return r;
}

static int
unwstat(Chan *c, uchar *db, int n)
{
	Unc *u;
	int r;

	u = c->aux;
	if(u->n == 0 || u->path[0] == '\0')
		error(Eperm);
	if(upid(u->inst, u->path) >= 0)
		return upwstat(c, db, n);
	r = devtab[u->mc[0]->type]->wstat(u->mc[0], db, n);
	/* A rename moves what's under it too. */
	wcdrop(u->inst, u->path, (u->mc[0]->qid.type & QTDIR) != 0);
	return r;
}

/* A union chan at the top of in. */
static Chan*
unattach(Inst *in, char *spec)
{
	Chan *c;
	Unc *u;

	c = devattach('O', spec);
	c->dev = in->id;
	c->qid = unrootqid();
	if(waserror()){
		cclose(c);
		nexterror();
	}
	u = uncnew(in, "");
	c->aux = u;
	untop(u);
	poperror();
	return c;
}

/* Makes a union instance for the calling thread's machine, unattached (pinned). */
static Inst*
unnew(char *name)
{
	Inst *in;
	int i;

	in = mallocz(sizeof(Inst), 1);
	if(in == nil)
		error(Enomem);
	in->mode = Union;
	in->pool = h9_overlay_pool();
	in->ref = 1;
	in->pinned = 1;
	if(name != nil)
		strecpy(in->name, in->name+sizeof in->name, name);
	in->mem = mallocz(Maxmembers*sizeof(Member), 1);
	if(in->mem == nil){
		free(in);
		error(Enomem);
	}
	in->qtab = ovmalloc(in, Qbuckets*sizeof(Qmap*));
	if(in->qtab == nil){
		instfree(in);
		error(Efull);
	}
	lock(&instlock);
	for(i = 0; i < Maxinst; i++)
		if(insts[i] == nil)
			break;
	if(i == Maxinst){
		unlock(&instlock);
		instfree(in);
		error("too many overlays");
	}
	in->id = nextid++;
	insts[i] = in;
	unlock(&instlock);
	return in;
}

/* The named union of the calling thread's machine, or nil. Under instlock. */
static Inst*
unnamed(char *name)
{
	int i;
	void *pool;

	pool = h9_overlay_pool();
	for(i = 0; i < Maxinst; i++)
		if(insts[i] != nil && insts[i]->mode == Union && insts[i]->pool == pool &&
		   strcmp(insts[i]->name, name) == 0)
			return insts[i];
	return nil;
}

static int
unvalidname(char *s)
{
	int n;

	for(n = 0; s[n] != '\0'; n++)
		if(!(s[n] >= 'a' && s[n] <= 'z'))
			return 0;
	return n > 0 && n < 16;
}

/*
 * Adds the directory c as a member of in, rooted at at, on top unless
 * after. An up member goes on top whatever after says, and others go
 * below it; a union has at most one.
 */
static void
unaddmember(Inst *in, Chan *c, char *at, int after, int create, int isup)
{
	Member *m;
	char *a;
	int top;

	if((c->qid.type & QTDIR) == 0)
		error(Enotdir);
	a = strdup(at);
	if(a == nil)
		error(Enomem);
	qlock(&in->ql);
	if(in->nmem >= Maxmembers){
		qunlock(&in->ql);
		free(a);
		error("too many union members");
	}
	top = in->nmem > 0 && in->mem[0].isup;
	if(isup && top){
		qunlock(&in->ql);
		free(a);
		error("a union has one up member");
	}
	if(after && !isup)
		m = &in->mem[in->nmem];
	else{
		memmove(&in->mem[top+1], &in->mem[top], (in->nmem-top)*sizeof(Member));
		m = &in->mem[top];
	}
	m->id = ++in->memgen;
	m->root = cclone(c);
	m->at = a;
	m->create = create || isup;
	m->isup = isup;
	in->nmem++;
	qunlock(&in->ql);
	wcdrop(in, nil, 1);
}

/* Removes the member whose root is the same file as c; 0 if none is. */
static int
undelmember(Inst *in, Chan *c)
{
	int i;
	Chan *r;
	char *a;

	qlock(&in->ql);
	for(i = 0; i < in->nmem; i++){
		r = in->mem[i].root;
		if(r->type == c->type && r->dev == c->dev && r->qid.path == c->qid.path)
			break;
	}
	if(i == in->nmem){
		qunlock(&in->ql);
		return 0;
	}
	r = in->mem[i].root;
	a = in->mem[i].at;
	memmove(&in->mem[i], &in->mem[i+1], (in->nmem-i-1)*sizeof(Member));
	in->nmem--;
	qunlock(&in->ql);
	wcdrop(in, nil, 1);
	cclose(r);
	free(a);
	return 1;
}

enum
{
	Uafter	= 1,	/* match h9_overlay_union's flags in src/kern.zig */
	Ucreate	= 2,
	Uup	= 4,	/* the union's up layer (design/epoch-0/upper-layers.md) */
};

static void
unerrswap(void)
{
	char *p;

	p = up->syserrstr;
	up->syserrstr = up->errstr;
	up->errstr = p;
}

/*
 * For the namespace builder in Zig: adds the directory at path (in the
 * caller's namespace) as a member of a union, rooted at at ("" for its
 * top). spec names the union: a name ("root", made if it doesn't exist),
 * an instance number, or "" for a new unnamed one. flags are Uafter (the
 * bottom, not the top) and Ucreate. Returns the instance's number, or -1
 * with the error as the sys* wrappers report it. A union made here is
 * pinned until it's attached, h9_overlay_unpin drops a named one, or
 * h9_overlay_drop an unnamed one.
 */
/* Adds the directory c to the union spec names; see h9_overlay_union. */
static int
unionchan(char *spec, Chan *c, char *at, int flags)
{
	Inst *volatile in;
	char *e;
	long id;

	in = nil;
	if(waserror()){
		unerrswap();
		return -1;
	}
	while(*at == '/')
		at++;
	if(spec[0] == '\0')
		in = unnew(nil);
	else if(unvalidname(spec)){
		lock(&instlock);
		in = unnamed(spec);
		unlock(&instlock);
		if(in == nil)
			in = unnew(spec);
	}else{
		id = strtol(spec, &e, 10);
		if(*e != '\0' || id < 0)
			error(Ebadarg);
		lock(&instlock);
		in = instlookup(id);
		if(in != nil && (in->mode != Union || in->pool != h9_overlay_pool()))
			in = nil;
		unlock(&instlock);
		if(in == nil)
			error(Enonexist);
	}
	unaddmember(in, c, at, flags & Uafter, flags & Ucreate, (flags & Uup) != 0);
	poperror();
	return in->id;
}

int
h9_overlay_union(char *spec, char *path, char *at, int flags)
{
	Chan *c;
	int id;

	if(waserror()){
		unerrswap();
		return -1;
	}
	c = namec(path, Aaccess, 0, 0);
	poperror();
	id = unionchan(spec, c, at, flags);
	cclose(c);
	return id;
}

/*
 * As h9_overlay_union, with the member a 9P connection: the server on fd
 * (in the caller's fd table) attached with aname, as mount(2) would. fd
 * is left open.
 */
int
h9_overlay_unionmount(char *spec, int fd, char *aname, char *at, int flags)
{
	Chan *volatile bc, *volatile c;
	int id;

	bc = nil;
	c = nil;
	if(waserror()){
		if(bc != nil)
			cclose(bc);
		if(c != nil)
			cclose(c);
		unerrswap();
		return -1;
	}
	bc = fdtochan(fd, ORDWR, 0, 1);
	c = mntattach(bc, nil, aname, 0);
	cclose(bc);
	bc = nil;
	poperror();
	/* Through a path, as h9_overlay_union takes one: the chan's own. */
	id = unionchan(spec, c, at, flags);
	cclose(c);
	return id;
}

/* The unnamed union c is the top of, or nil. */
static Inst*
nsinst(Chan *c)
{
	Unc *u;

	if(devtab[c->type]->dc != 'O' || !isunion(c))
		return nil;
	u = c->aux;
	if(u->path[0] != '\0' || u->inst->name[0] != '\0')
		return nil;
	return u->inst;
}

/*
 * in's members as bind -r lines onto old, in the order that makes them
 * again: old's own member first (a union itself if bind -r made one over
 * another, printed in turn), then those above it with -b and those
 * below it with -a.
 */
static char*
nsunion1(Inst *in, char *old, char *p, char *e, int depth)
{
	Member *m;
	Inst *sub;
	int i, j;

	qlock(&in->ql);
	j = in->nmem;
	for(i = in->nmem-1; i >= 0; i--)
		if(strcmp(chanpath(in->mem[i].root), old) == 0){
			j = i;
			break;
		}
	if(j < in->nmem && depth < 8 && (sub = nsinst(in->mem[j].root)) != nil && sub != in)
		p = nsunion1(sub, old, p, e, depth+1);
	for(i = j-1; i >= 0 && p < e; i--){
		m = &in->mem[i];
		if(m->at[0] != '\0')
			continue;
		if(m->isup)
			p = seprint(p, e, "bind -u %q %q\n", chanpath(m->root), old);
		else
			p = seprint(p, e, m->create ? "bind -rbc %q %q\n" : "bind -rb %q %q\n", chanpath(m->root), old);
	}
	for(i = j+1; i < in->nmem && p < e; i++){
		m = &in->mem[i];
		if(m->at[0] == '\0')
			p = seprint(p, e, m->create ? "bind -rac %q %q\n" : "bind -ra %q %q\n", chanpath(m->root), old);
	}
	qunlock(&in->ql);
	return p;
}

/*
 * For devproc's ns: if c is the top of an unnamed union bound at old,
 * prints it as the bind -r lines that make it again and returns their
 * length; otherwise -1. A member rooted below the top can't be written
 * as a line and is left out.
 */
int
h9_overlay_nsunion(Chan *c, char *old, char *buf, int nbuf)
{
	Inst *in;

	if((in = nsinst(c)) == nil)
		return -1;
	return nsunion1(in, old, buf, buf+nbuf, 0) - buf;
}

/*
 * The number of the union whose top path is (in the caller's namespace),
 * or -1: for bind -r onto a union already there.
 */
int
h9_overlay_unionof(char *path)
{
	Chan *c;
	Unc *u;
	int id;

	if(waserror()){
		unerrswap();
		return -1;
	}
	c = namec(path, Aaccess, 0, 0);
	id = -1;
	if(devtab[c->type]->dc == 'O' && isunion(c)){
		u = c->aux;
		if(u->path[0] == '\0')
			id = u->inst->id;
	}
	cclose(c);
	poperror();
	return id;
}

/*
 * Gives the named union name a copy-on-write instance over it, which
 * attaching the name gives from then on. Returns the cow instance's
 * number, or -1 with the error set.
 */
int
h9_overlay_cowname(char *name)
{
	Inst *u, *cw;
	Chan *volatile c;
	char spec[32];
	int id;

	c = nil;
	if(waserror()){
		if(c != nil)
			cclose(c);
		unerrswap();
		return -1;
	}
	if(!unvalidname(name))
		error(Ebadarg);
	lock(&instlock);
	u = unnamed(name);
	unlock(&instlock);
	if(u == nil){
		u = unnew(name);
		USED(u);
	}
	snprint(spec, sizeof spec, "#O%s", name);
	c = namec(spec, Aaccess, 0, 0);
	id = h9_overlay_new(c);
	if(id < 0)
		nexterror();
	cclose(c);
	c = nil;
	lock(&instlock);
	cw = instlookup(id);
	u = unnamed(name);
	if(cw != nil && u != nil){
		if(u->cow != nil)
			u->cow->over = nil;
		u->cow = cw;
		cw->over = u;
	}
	unlock(&instlock);
	poperror();
	return id;
}

/* Drops the pinned ref of a named union and its cow that were never attached. */
void
h9_overlay_unpin(char *name)
{
	Inst *u, *cw;
	int du, dc;

	lock(&instlock);
	u = unnamed(name);
	du = dc = 0;
	cw = nil;
	if(u != nil){
		cw = u->cow;
		if(cw != nil && cw->pinned){
			cw->pinned = 0;
			dc = 1;
		}
		if(u->pinned){
			u->pinned = 0;
			du = 1;
		}
	}
	unlock(&instlock);
	if(dc)
		instdecref(cw);
	if(du)
		instdecref(u);
}

/*
 * The device.
 */


/*
 * The control tree (design/epoch-0/mounts.md, "Union instances"): a bare #O
 * attach is a directory with one file, clone. Opening clone makes an
 * unnamed union owned by the opener's machine, unattached; reading it
 * gives the union's number, and writes to it take
 *
 *	add [-a|-b] [-c] PATH	PATH's directory as a member, on top (-b,
 *				the default) or at the bottom (-a); -c takes creates
 *	upper PATH		PATH's directory as the union's up layer, on top
 *				(design/epoch-0/upper-layers.md)
 *	del PATH		removes the member that is PATH's directory
 *	cow			a copy-on-write instance over the union, which
 *				attaching the union's number gives from then on
 *
 * with PATH resolved in the writer's namespace, so a member is a tree the
 * writer could already walk. Binding #ON attaches it; closing clone
 * before that lets it go. Its chans have dev Ctldev, and aux nil, or a
 * Ctl once clone is open.
 */
#define Ctldev	((ulong)~0)	/* ulong is 32 bits here */

enum
{
	Qctldir	= 0,
	Qclone,
};

typedef struct Ctl Ctl;
struct Ctl
{
	int	id;	/* the union clone made */
	int	cow;	/* its cow instance, or -1 */
};

static Dirtab ctltab[] = {
	".",		{Qctldir, 0, QTDIR},	0,	DMDIR|0555,
	"clone",	{Qclone},		0,	0666,
};

static int
isctl(Chan *c)
{
	return c->dev == Ctldev;
}

static Chan*
ctlattach(void)
{
	Chan *c;

	c = devattach('O', "");
	c->dev = Ctldev;
	mkqid(&c->qid, Qctldir, 0, QTDIR);
	c->aux = nil;
	return c;
}

static Walkqid*
ctlwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, ctltab, nelem(ctltab), devgen);
}

static int
ctlstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, ctltab, nelem(ctltab), devgen);
}

static Chan*
ctlopen(Chan *c, int omode)
{
	Ctl *k;
	Inst *in;

	if(c->qid.path != Qclone)
		return devopen(c, omode, ctltab, nelem(ctltab), devgen);
	k = smalloc(sizeof(Ctl));
	k->cow = -1;
	if(waserror()){
		free(k);
		nexterror();
	}
	in = unnew(nil);
	k->id = in->id;
	poperror();
	c = devopen(c, omode, ctltab, nelem(ctltab), devgen);
	c->aux = k;
	return c;
}

static void
ctlclose(Chan *c)
{
	Ctl *k;

	k = c->aux;
	if(k == nil)
		return;
	c->aux = nil;
	/* Never attached: they go now. The cow holds the union until it goes. */
	if(k->cow >= 0)
		h9_overlay_drop(k->cow);
	h9_overlay_drop(k->id);
	free(k);
}

static long
ctlread(Chan *c, void *a, long n, vlong off)
{
	Ctl *k;
	char buf[16];

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, ctltab, nelem(ctltab), devgen);
	k = c->aux;
	if(k == nil)
		error(Ebadusefd);
	snprint(buf, sizeof buf, "%d\n", k->id);
	return readstr(off, a, n, buf);
}

/* The union clone made, with a reference; Enonexist if it's gone. */
static Inst*
ctlinst(Ctl *k)
{
	Inst *in;

	lock(&instlock);
	in = instlookup(k->id);
	if(in == nil || in->mode != Union || in->pool != h9_overlay_pool()){
		unlock(&instlock);
		error(Enonexist);
	}
	in->ref++;
	unlock(&instlock);
	return in;
}

static long
ctlwrite(Chan *c, void *a, long n, vlong)
{
	Ctl *k;
	Cmdbuf *cb;
	Inst *volatile in;
	Inst *un, *cw;
	Chan *volatile mc;
	char ebuf[ERRMAX];
	char *path;
	int i, after, create, id;

	if(c->qid.type & QTDIR)
		error(Eisdir);
	k = c->aux;
	if(k == nil)
		error(Ebadusefd);
	cb = parsecmd(a, n);
	in = nil;
	mc = nil;
	if(waserror()){
		if(mc != nil)
			cclose(mc);
		if(in != nil)
			instdecref(in);
		free(cb);
		nexterror();
	}
	if(cb->nf < 1)
		error(Ebadctl);
	if(strcmp(cb->f[0], "upper") == 0){
		if(cb->nf != 2)
			error(Ebadctl);
		in = ctlinst(k);
		mc = namec(cb->f[1], Aaccess, 0, 0);
		unaddmember(in, mc, "", 0, 1, 1);
	}else if(strcmp(cb->f[0], "add") == 0){
		after = 0;
		create = 0;
		for(i = 1; i < cb->nf-1; i++){
			if(strcmp(cb->f[i], "-a") == 0)
				after = 1;
			else if(strcmp(cb->f[i], "-b") == 0)
				after = 0;
			else if(strcmp(cb->f[i], "-c") == 0)
				create = 1;
			else if(strcmp(cb->f[i], "-ac") == 0 || strcmp(cb->f[i], "-ca") == 0)
				after = create = 1;
			else if(strcmp(cb->f[i], "-bc") == 0 || strcmp(cb->f[i], "-cb") == 0)
				create = 1;
			else
				error(Ebadctl);
		}
		if(cb->nf < 2)
			error(Ebadctl);
		path = cb->f[cb->nf-1];
		in = ctlinst(k);
		mc = namec(path, Aaccess, 0, 0);
		unaddmember(in, mc, "", after, create, 0);
	}else if(strcmp(cb->f[0], "del") == 0){
		if(cb->nf != 2)
			error(Ebadctl);
		in = ctlinst(k);
		mc = namec(cb->f[1], Aaccess, 0, 0);
		if(!undelmember(in, mc))
			error("not a member");
	}else if(strcmp(cb->f[0], "cow") == 0){
		if(cb->nf != 1 || k->cow >= 0)
			error(Ebadctl);
		/* As h9_overlay_cowname does for a named union. */
		un = ctlinst(k);
		in = un;
		mc = unattach(un, "");
		in = nil;	/* mc holds the reference now */
		id = h9_overlay_new(mc);
		if(id < 0){
			strecpy(ebuf, ebuf+sizeof ebuf, up->errstr);
			error(ebuf);
		}
		lock(&instlock);
		cw = instlookup(id);
		if(cw != nil){
			un->cow = cw;
			cw->over = un;
		}
		unlock(&instlock);
		k->cow = id;
	}else
		error(Ebadctl);
	poperror();
	if(mc != nil)
		cclose(mc);
	if(in != nil)
		instdecref(in);
	free(cb);
	return n;
}

static Chan*
ovattach(char *spec)
{
	Inst *in;
	Chan *c;
	char *e;
	long id;

	if(spec == nil || *spec == '\0')
		return ctlattach();
	if(unvalidname(spec)){
		/* A named union, made empty on first use; or the cow over it. */
		lock(&instlock);
		in = unnamed(spec);
		unlock(&instlock);
		if(in == nil)
			unnew(spec);
		lock(&instlock);
		in = unnamed(spec);
		if(in != nil && in->cow != nil)
			in = in->cow;
	}else{
		id = strtol(spec, &e, 10);
		if(*e != '\0' || id < 0)
			error(Ebadarg);
		lock(&instlock);
		in = instlookup(id);
		/* A union clone gave a cow: the number stands for both. */
		if(in != nil && in->mode == Union && in->name[0] == '\0' && in->cow != nil)
			in = in->cow;
	}
	if(in == nil || in->pool != h9_overlay_pool()){
		unlock(&instlock);
		error(Enonexist);
	}
	if(in->pinned)
		in->pinned = 0;
	else
		in->ref++;
	unlock(&instlock);
	if(waserror()){
		instdecref(in);
		nexterror();
	}
	if(in->mode == Union){
		c = unattach(in, spec);
		poperror();
		return c;
	}
	c = devattach('O', spec);
	c->dev = in->id;
	c->qid = in->root->qid;
	if(waserror()){
		cclose(c);
		nexterror();
	}
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	c->aux = ovcnew(in, in->root, in->lower != nil ? cclone(in->lower) : nil, "");
	poperror();
	qunlock(&in->ql);
	poperror();
	poperror();
	return c;
}

/* Re-resolves o from the instance root along path, for "..". */
static int ovstep(Ovc*, Chan*, char*, int);

static void
ovreroot(Ovc *o, Chan *nc, char *path)
{
	Inst *in;
	char buf[Maxname], *p;
	int i, n;

	in = o->inst;
	if(o->lower != nil)
		cclose(o->lower);
	o->lower = nil;
	nodeunref(in, o->node);
	o->node = in->root;
	in->root->ref++;
	if(in->lower != nil)
		o->lower = cclone(in->lower);
	p = o->path;
	o->path = strdup("");
	nc->qid = in->root->qid;
	if(o->path == nil){
		free(p);
		error(Enomem);
	}
	n = npathelem(path);
	for(i = 0; i < n; i++){
		pathelem(path, i, buf);
		if(!ovstep(o, nc, buf, 0)){
			free(p);
			error(Enonexist);
		}
	}
	free(p);
}

/* Forgets the link a walk's last name followed. */
static void
droplink(Ovc *o)
{
	nodeunref(o->inst, o->lnk);
	o->lnk = nil;
	free(o->lpath);
	o->lpath = nil;
}

/*
 * o is at an Nlink: walks it to the link's target. last says this was
 * the walk's last name: then the chan keeps the link beside the target,
 * or stays on the link if the target is missing.
 */
static void
follow(Ovc *o, Chan *nc, int last)
{
	Node *l;
	char *lpath, *tp, *s;
	int n;

	l = o->node;
	if(++o->nlinks > Maxlinks)
		error("too many symbolic links");
	lpath = strdup(o->path);
	if(lpath == nil)
		error(Enomem);
	if(l->link[0] == '/'){
		for(s = l->link; *s == '/'; s++)
			;
		tp = strdup(s);
	}else{
		s = strrchr(lpath, '/');
		n = s != nil ? s - lpath : 0;
		tp = malloc(n + 1 + strlen(l->link) + 1);
		if(tp != nil){
			if(n > 0)
				sprint(tp, "%.*s/%s", n, lpath, l->link);
			else
				strcpy(tp, l->link);
		}
	}
	if(tp == nil){
		free(lpath);
		error(Enomem);
	}
	/* Empty names (a//b, a trailing /) are dropped. */
	for(s = tp; (s = strstr(s, "//")) != nil; )
		memmove(s, s+1, strlen(s));
	n = strlen(tp);
	if(n > 0 && tp[n-1] == '/')
		tp[n-1] = '\0';
	l->ref++;
	if(waserror()){
		free(tp);
		if(!last){
			nodeunref(o->inst, l);
			free(lpath);
			nexterror();
		}
		/* A dangling link, walked to as itself. */
		if(o->lower != nil)
			cclose(o->lower);
		o->lower = nil;
		nodeunref(o->inst, o->node);
		o->node = l;
		free(o->path);
		o->path = lpath;
		nc->qid = l->qid;
		return;
	}
	ovreroot(o, nc, tp);
	poperror();
	free(tp);
	if(last){
		o->lnk = l;
		o->lpath = lpath;
	}else{
		nodeunref(o->inst, l);
		free(lpath);
	}
}

/* Puts a chan that followed a link back on the link itself, for remove and rename. */
static void
onlink(Ovc *o)
{
	if(o->lnk == nil)
		return;
	if(o->lower != nil)
		cclose(o->lower);
	o->lower = nil;
	nodeunref(o->inst, o->node);
	o->node = o->lnk;
	o->lnk = nil;
	free(o->path);
	o->path = o->lpath;
	o->lpath = nil;
}

/*
 * Walks o (and nc's qid) by one name; returns 0 if it isn't there. A link
 * is followed; last says the name is the walk's last (see follow).
 */
static int
ovstep(Ovc *o, Chan *nc, char *name, int last)
{
	Node *ch, *nn;
	Chan *nl;
	char *np, *dir, *s;

	if(strcmp(name, ".") == 0)
		return 1;
	droplink(o);
	if(strcmp(name, "..") == 0){
		if(o->path[0] == '\0')
			return 1;
		dir = strdup(o->path);
		if(dir == nil)
			error(Enomem);
		s = strrchr(dir, '/');
		if(s != nil)
			*s = '\0';
		else
			dir[0] = '\0';
		if(waserror()){
			free(dir);
			nexterror();
		}
		ovreroot(o, nc, dir);
		poperror();
		free(dir);
		return 1;
	}
	if((nc->qid.type & QTDIR) == 0){
		kstrcpy(up->errstr, Enotdir, ERRMAX);
		return 0;
	}
	/* The directory may have changed in memory since this chan reached it. */
	if(adopt(o) < 0){
		kstrcpy(up->errstr, Enonexist, ERRMAX);
		return 0;
	}
	ch = o->node != nil ? findchild(o->node, name) : nil;
	nn = nil;
	nl = nil;
	if(ch != nil){
		if(ch->kind == Nwhite){
			kstrcpy(up->errstr, Enonexist, ERRMAX);
			return 0;
		}
		nn = ch;
		if(ch->kind == Nmark && o->lower != nil){
			nl = lowerwalk1(o->lower, name);
			if(nl == nil)
				return 0;
		}
	}else{
		if((o->node != nil && o->node->kind == Ncopy) || o->lower == nil){
			kstrcpy(up->errstr, Enonexist, ERRMAX);
			return 0;
		}
		nl = lowerwalk1(o->lower, name);
		if(nl == nil)
			return 0;
	}
	np = pathjoin(o->path, name);
	free(o->path);
	o->path = np;
	if(o->lower != nil)
		cclose(o->lower);
	o->lower = nl;
	if(nn != nil)
		nn->ref++;
	nodeunref(o->inst, o->node);
	o->node = nn;
	nc->qid = nn != nil ? nn->qid : nl->qid;
	/* A Linux process's walk stops at the link (ovwalk). */
	if(nn != nil && nn->kind == Nlink && !h9_fs_linkwalk()){
		if(waserror())
			return 0;	/* the error is in up->errstr */
		follow(o, nc, last);
		poperror();
	}
	return 1;
}

static Walkqid*
ovwalk(Chan *c, Chan *nc, char **name, int nname)
{
	Walkqid *wq;
	Ovc *o, *volatile no;
	Inst *in;
	int i;
	if(isctl(c))
		return ctlwalk(c, nc, name, nname);
	if(isunion(c))
		return unwalk(c, nc, name, nname);

	if(nc != nil)
		panic("ovwalk: nc != nil");
	o = c->aux;
	in = o->inst;
	wq = smalloc(sizeof(Walkqid)+(nname > 0 ? nname-1 : 0)*sizeof(Qid));
	nc = devclone(c);
	nc->type = 0;	/* our close mustn't see it until it's done */
	nc->aux = nil;
	no = nil;
	lock(&instlock);
	in->ref++;
	unlock(&instlock);
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		if(no != nil)
			ovcfree(no);
		else
			instdecref(in);
		cclose(nc);
		free(wq);
		return nil;
	}
	no = ovcnew(in, o->node, nil, o->path);
	if(o->lower != nil)
		no->lower = cclone(o->lower);
	if(o->lnk != nil){
		no->lpath = strdup(o->lpath);
		if(no->lpath == nil)
			error(Enomem);
		no->lnk = o->lnk;
		no->lnk->ref++;
	}
	for(i = 0; i < nname; i++){
		no->nlinks = 0;
		if(!ovstep(no, nc, name[i], i == nname-1))
			break;
		wq->qid[i] = nc->qid;
		/* A Linux process's walk stops at a link, its own or the lower tree's. */
		if(nc->qid.type & H9_QTSYMLINK){
			i++;
			break;
		}
	}
	wq->nqid = i;
	qunlock(&in->ql);
	poperror();
	if(i < nname){
		ovcfree(no);
		cclose(nc);
		if(i == 0){
			free(wq);
			return nil;
		}
		wq->clone = nil;
		return wq;
	}
	nc->aux = no;
	nc->type = c->type;
	wq->clone = nc;
	return wq;
}

static int
ovstat(Chan *c, uchar *db, int n)
{
	Ovc *o;
	Inst *in;
	Dir d;
	int r;
	if(isctl(c))
		return ctlstat(c, db, n);
	if(isunion(c))
		return unstat(c, db, n);

	o = c->aux;
	in = o->inst;
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	if(!o->lopen)
		refresh(c);
	if(o->node != nil && !o->lopen){
		node2dir(c, o->node, &d);
		r = convD2M(&d, db, n);
		if(r == 0)
			error(Eshortstat);
	}else
		r = devtab[o->lower->type]->stat(o->lower, db, n);
	qunlock(&in->ql);
	poperror();
	return r;
}

static int
iswrite(int omode)
{
	int m;

	m = omode & 3;
	return m == OWRITE || m == ORDWR || (omode & OTRUNC) != 0;
}

static Chan*
ovopen(Chan *c, int omode)
{
	Ovc *o;
	Inst *in;
	Node *n;
	Dir d;
	uchar buf[1024+4*Maxname];
	char strs[sizeof buf];
	int mode;
	if(isctl(c))
		return ctlopen(c, omode);
	if(isunion(c))
		return unopen(c, omode);

	o = c->aux;
	in = o->inst;
	mode = openmode(omode);
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	refresh(c);
	if(o->node != nil && o->node->kind == Nlink)
		error(h9_fs_linkwalk() ? H9_ELOOP : Enonexist);	/* a link not followed, or whose target is missing */
	/* Exclusive use, as 9front's file servers do: one open at a time. */
	if(o->node != nil && (o->node->mode & DMEXCL) && o->node->excl)
		error(Elocked);
	if(c->qid.type & QTDIR){
		if(mode != OREAD || (omode & OTRUNC))
			error(Eisdir);
		if(o->node == nil){
			o->lower = devtab[o->lower->type]->open(o->lower, OREAD);
			o->lopen = 1;
		}
	}else if(o->node == nil && h9_fs_isfifo(o->lower)){
		/*
		 * A host FIFO isn't copied up for a write: it has no data, and
		 * a Linux open of it joins a pipe instead (src/kern/fifo.c).
		 */
		o->lower = devtab[o->lower->type]->open(o->lower, OREAD);
		o->lopen = 1;
	}else if(!iswrite(omode)){
		if(o->node != nil)
			ovperm(o->node->mode, omode);
		else{
			o->lower = devtab[o->lower->type]->open(o->lower, omode & ~(OTRUNC|ORCLOSE|OCEXEC));
			o->lopen = 1;
		}
	}else{
		if(o->node == nil){
			lowerstat(o->lower, &d, buf, sizeof buf, strs);
			ovperm(d.mode, omode);
			copyup(c, omode & OTRUNC);
		}else
			ovperm(o->node->mode, omode);
		n = o->node;
		if((omode & OTRUNC) && n->length > 0){
			n->length = 0;
			trimblocks(in, n, 0);
		}
		if(omode & OTRUNC){
			n->qid.vers++;
			n->mtime = seconds();
		}
		c->qid = n->qid;
	}
	if(o->node != nil && (o->node->mode & DMEXCL) && (c->qid.type & QTDIR) == 0){
		o->node->excl = 1;
		o->excl = 1;
	}
	if(omode & ORCLOSE)
		c->flag |= CRCLOSE;
	c->mode = mode;
	c->flag |= COPEN;
	c->offset = 0;
	qunlock(&in->ql);
	poperror();
	return c;
}

static int
ovname(char *name)
{
	if(name[0] == '\0' || strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
		return 0;
	if(strchr(name, '/') != nil)
		return 0;
	return strlen(name) < Maxname;
}

static Chan*
ovcreate(Chan *c, char *name, int omode, ulong perm)
{
	Ovc *o;
	Inst *in;
	Node *dir, *ch;
	char *volatile np;
	int fresh;
	if(isctl(c))
		error(Eperm);
	if(isunion(c))
		return uncreate(c, name, omode, perm);

	o = c->aux;
	in = o->inst;
	if((c->qid.type & QTDIR) == 0)
		error(Enotdir);
	if(!ovname(name))
		error(strlen(name) >= Maxname ? Etoolong : Ebadchar);
	if((perm & DMDIR) && openmode(omode) != OREAD)
		error(Eperm);
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	refresh(c);
	if(o->node == nil){
		dir = markpath(in, o->path, npathelem(o->path));
		dir->ref++;
		o->node = dir;
	}
	dir = o->node;
	ovperm(dir->mode, OWRITE);
	ch = findchild(dir, name);
	if(ch != nil && ch->kind != Nwhite)
		error(Eexist);
	if(ch == nil && dir->kind == Nmark && o->lower != nil){
		Chan *lc = lowerwalk1(o->lower, name);
		if(lc != nil){
			cclose(lc);
			error(Eexist);
		}
	}
	fresh = ch == nil;
	np = pathjoin(o->path, name);
	if(waserror()){
		free(np);
		nexterror();
	}
	if(fresh){
		ch = newnode(in, Ncopy, name);
		if(waserror()){
			nodefree(in, ch);
			nexterror();
		}
		setstrs(in, ch, ovuser(), ovuser(), ovuser());
		poperror();
	}else{
		/* Over a whiteout: the name exists below, hidden by the copy. */
		setstrs(in, ch, ovuser(), ovuser(), ovuser());
		ch->kind = Ncopy;
		ch->inlower = 1;
	}
	newqid(in, ch, perm & DMDIR);
	if(perm & DMDIR)
		ch->mode = (perm & ~0777) | (perm & dir->mode & 0777);
	else
		ch->mode = (perm & ~0666) | (perm & dir->mode & 0666);
	ch->atime = ch->mtime = seconds();
	ch->length = 0;
	if(fresh)
		ovlink(dir, ch);
	poperror();
	free(o->path);
	o->path = np;
	if(o->lower != nil)
		cclose(o->lower);
	o->lower = nil;
	ch->ref++;
	nodeunref(in, o->node);
	o->node = ch;
	c->qid = ch->qid;
	changed(in, o->path);
	if((ch->mode & DMEXCL) && (perm & DMDIR) == 0){
		ch->excl = 1;
		o->excl = 1;
	}
	if(omode & ORCLOSE)
		c->flag |= CRCLOSE;
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	qunlock(&in->ql);
	poperror();
	return c;
}

/* Removes the chan's name from the tree. Called with the instance locked. */
static void
removelocked(Chan *c)
{
	Ovc *o;
	Inst *in;
	Node *n, *dir, *w;
	char name[Maxname];
	int ne;

	o = c->aux;
	in = o->inst;
	onlink(o);
	refresh(c);
	if(o->node == in->root)
		error(Eperm);
	n = o->node;
	if(n != nil){
		if((n->qid.type & QTDIR) && !dirempty(c))
			error(Enotempty);
		dir = n->parent;
		ovperm(dir->mode, OWRITE);
		w = nil;
		if(n->inlower)
			w = newnode(in, Nwhite, n->name);
		ovunlink(in, n);
		if(w != nil){
			w->inlower = 1;
			ovlink(dir, w);
		}
		changed(in, o->path);
		return;
	}
	if((c->qid.type & QTDIR) && !dirempty(c))
		error(Enotempty);
	ne = npathelem(o->path);
	dir = markpath(in, o->path, ne-1);
	ovperm(dir->mode, OWRITE);
	pathelem(o->path, ne-1, name);
	w = newnode(in, Nwhite, name);
	w->inlower = 1;
	ovlink(dir, w);
	changed(in, o->path);
}

static void
ovremove(Chan *c)
{
	Ovc *o;
	Inst *in;
	if(isctl(c))
		error(Eperm);
	if(isunion(c)){
		unremove(c);
		return;
	}

	o = c->aux;
	in = o->inst;
	/* sysremove doesn't close the chan through us afterwards. */
	if(waserror()){
		c->aux = nil;
		ovcfree(o);
		nexterror();
	}
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	removelocked(c);
	qunlock(&in->ql);
	poperror();
	poperror();
	c->aux = nil;
	ovcfree(o);
}

static void
ovclose(Chan *c)
{
	Ovc *o;
	Inst *in;

	if(isctl(c)){
		ctlclose(c);
		return;
	}
	o = c->aux;
	if(o == nil)
		return;
	if(isunion(c)){
		unclose(c);
		return;
	}
	in = o->inst;
	if((c->flag & (COPEN|CRCLOSE)) == (COPEN|CRCLOSE)){
		qlock(&in->ql);
		if(!waserror()){
			removelocked(c);
			poperror();
		}
		qunlock(&in->ql);
	}
	c->aux = nil;
	ovcfree(o);
}

static long
ovread(Chan *c, void *a, long n, vlong off)
{
	Ovc *o;
	Inst *in;
	long m, sz;
	if(isctl(c))
		return ctlread(c, a, n, off);
	if(isunion(c))
		return unread(c, a, n, off);

	o = c->aux;
	in = o->inst;
	if(o->lopen)
		return devtab[o->lower->type]->read(o->lower, a, n, off);
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	if(c->qid.type & QTDIR){
		if(off == 0 || o->dir == nil)
			snapshot(c);
		/* Whole entries only, from off. */
		for(m = 0; off + m + BIT16SZ <= o->ndir; m += sz){
			sz = BIT16SZ + GBIT16(o->dir + off + m);
			if(m + sz > n)
				break;
		}
		if(m > 0)
			memmove(a, o->dir + off, m);
	}else{
		m = blkread(in, o->node, a, n, off);
		o->node->atime = seconds();
	}
	qunlock(&in->ql);
	poperror();
	return m;
}

static long
ovwrite(Chan *c, void *a, long n, vlong off)
{
	Ovc *o;
	Inst *in;
	Node *nd;
	if(isctl(c))
		return ctlwrite(c, a, n, off);
	if(isunion(c))
		return unwrite(c, a, n, off);

	o = c->aux;
	in = o->inst;
	if(c->qid.type & QTDIR)
		error(Eisdir);
	if(o->lopen || o->node == nil)
		error(Eperm);
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	nd = o->node;
	if(nd->kind == Nfifo)
		error(Eperm);
	if(nd->mode & DMAPPEND)
		off = nd->length;
	if(strcmp(nd->muid, ovuser()) != 0)
		setstrs(in, nd, nd->uid, nd->gid, ovuser());
	blkwrite(in, nd, a, n, off);
	nd->qid.vers++;
	nd->mtime = seconds();
	qunlock(&in->ql);
	poperror();
	return n;
}

/* Renames n within its directory. */
static void
ovrename(Chan *c, Node *n, char *name)
{
	Ovc *o;
	Inst *in;
	Node *dir, *ex, *w;
	Chan *dl, *lc;
	char *nm, *np, *s;
	int ne;

	o = c->aux;
	in = o->inst;
	if(!ovname(name))
		error(strlen(name) >= Maxname ? Etoolong : Ebadchar);
	dir = n->parent;
	if(dir == nil)
		error(Eperm);
	ovperm(dir->mode, OWRITE);
	ex = findchild(dir, name);
	if(ex == n)
		return;
	if(ex != nil && ex->kind != Nwhite)
		error(Eexist);
	if(ex == nil && dir->kind == Nmark){
		ne = npathelem(o->path);
		dl = lowerwalk(in, o->path, ne-1);
		if(dl != nil){
			lc = lowerwalk1(dl, name);
			cclose(dl);
			if(lc != nil){
				cclose(lc);
				error(Eexist);
			}
		}
	}
	nm = ovstrdup(in, name);
	if(nm == nil)
		error(Efull);
	w = nil;
	if(n->inlower){
		w = newnode(in, Nwhite, n->name);
		w->inlower = 1;
	}
	/* The path for this chan; others holding n keep theirs, unused while they hold n. */
	s = strrchr(o->path, '/');
	ne = s != nil ? s - o->path + 1 : 0;
	np = malloc(ne + strlen(name) + 1);
	if(np == nil){
		ovstrfree(in, nm);
		if(w != nil)
			nodefree(in, w);
		error(Enomem);
	}
	memmove(np, o->path, ne);
	strcpy(np + ne, name);
	free(o->path);
	o->path = np;
	n->ref++;
	ovunlink(in, n);
	ovstrfree(in, n->name);
	n->name = nm;
	n->inlower = 0;
	if(ex != nil){
		/* Over a whiteout: the copy now hides the lower file of that name. */
		n->inlower = 1;
		ovunlink(in, ex);
	}
	ovlink(dir, n);
	if(w != nil)
		ovlink(dir, w);
}

/*
 * Moves c's name into the directory dc as name, the overlay's rename
 * (design/file-interface.md), for the Linux ABI's renameat, as
 * ovrename does within one directory for a wstat. Both are overlay
 * chans; returns 1 if they're in different instances, or c is a
 * directory still in the lower tree (Linux's overlayfs refuses that
 * with EXDEV too, and mv copies), and 0 once moved. A file or link
 * named name in dc is replaced, as rename(2) replaces it, and so is an
 * empty directory in memory; a directory beneath c can't be the
 * target. Zig's cache, for one, makes each entry in tmp/ and renames
 * it into place.
 */
int
h9_overlay_move(Chan *c, Chan *dc, char *name)
{
	Ovc *o, *od;
	Inst *in;
	Node *n, *odir, *dir, *ex, *d, *w;
	Chan *dl, *lc;
	char *nm, *np, *oldpath;
	int isdir, lowerex;

	if(isunion(c) || isunion(dc)){
		if(!isunion(c) || !isunion(dc))
			return 1;
		return unmove(c, dc, name);
	}
	o = c->aux;
	od = dc->aux;
	in = o->inst;
	if(od->inst != in)
		return 1;
	if(!ovname(name))
		error(strlen(name) >= Maxname ? Etoolong : Ebadchar);
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	onlink(o);
	refresh(c);
	refresh(dc);
	if(o->node == in->root)
		error(Eperm);
	isdir = (c->qid.type & QTDIR) != 0;
	if(isdir && (o->node == nil || o->node->kind == Nmark)){
		qunlock(&in->ql);
		poperror();
		return 1;
	}
	if((dc->qid.type & QTDIR) == 0)
		error(Enotdir);
	if(o->node == nil)
		copyup(c, 0);
	n = o->node;
	odir = n->parent;
	if(odir == nil)
		error(Enonexist);
	ovperm(odir->mode, OWRITE);
	dir = od->node;
	if(dir == nil || dir->kind == Nwhite)
		dir = markpath(in, od->path, npathelem(od->path));
	if(dir->kind == Nlink || (dir->qid.type & QTDIR) == 0)
		error(Enotdir);
	ovperm(dir->mode, OWRITE);
	for(d = dir; d != nil; d = d->parent)
		if(d == n)
			error(Ebadarg);	/* into itself: EINVAL */
	ex = findchild(dir, name);
	if(ex == n){
		qunlock(&in->ql);
		poperror();
		return 0;
	}
	lowerex = 0;
	if(ex != nil && ex->kind != Nwhite){
		if((ex->qid.type & QTDIR) && (ex->kind != Ncopy || ex->nchild != 0))
			error(Enotempty);
		lowerex = ex->inlower;
	}else if(ex != nil)
		lowerex = 1;	/* a whiteout: the lower name stays hidden under n */
	else if(dir->kind == Nmark){
		dl = lowerwalk(in, od->path, npathelem(od->path));
		if(dl != nil){
			lc = lowerwalk1(dl, name);
			cclose(dl);
			if(lc != nil){
				lowerex = 1;
				if(lc->qid.type & QTDIR){
					cclose(lc);
					error(Enotempty);
				}
				cclose(lc);
			}
		}
	}
	w = nil;
	if(n->inlower){
		w = newnode(in, Nwhite, n->name);
		w->inlower = 1;
	}
	nm = ovstrdup(in, name);
	if(nm == nil){
		if(w != nil)
			nodefree(in, w);
		error(Efull);
	}
	np = malloc((od->path[0] != '\0' ? strlen(od->path) + 1 : 0) + strlen(name) + 1);
	if(np == nil){
		ovstrfree(in, nm);
		if(w != nil)
			nodefree(in, w);
		error(Enomem);
	}
	if(od->path[0] != '\0')
		sprint(np, "%s/%s", od->path, name);
	else
		strcpy(np, name);
	/* The path for this chan; others holding n keep theirs, unused while they hold n. */
	oldpath = o->path;
	o->path = np;
	n->ref++;
	ovunlink(in, n);
	if(w != nil)
		ovlink(odir, w);
	if(ex != nil)
		ovunlink(in, ex);
	ovstrfree(in, n->name);
	n->name = nm;
	n->inlower = lowerex;
	ovlink(dir, n);
	dir->mtime = odir->mtime = seconds();
	changed(in, oldpath);
	changed(in, o->path);
	free(oldpath);
	qunlock(&in->ql);
	poperror();
	return 0;
}

static int
ovwstat(Chan *c, uchar *db, int n)
{
	Ovc *o;
	Inst *in;
	Node *nd;
	Dir d;
	char *strs;
	int isdir, chname, chmode, chmtime, chlen, gone;
	if(isctl(c))
		error(Eperm);
	if(isunion(c))
		return unwstat(c, db, n);

	o = c->aux;
	in = o->inst;
	strs = smalloc(n);
	if(waserror()){
		free(strs);
		nexterror();
	}
	if(convM2D(db, n, &d, strs) != n)
		error(Ebadstat);
	qlock(&in->ql);
	if(waserror()){
		qunlock(&in->ql);
		nexterror();
	}
	/* A rename renames the link; other changes go to its target. */
	if(o->lnk != nil && d.name[0] != '\0' && strcmp(d.name, o->lnk->name) != 0){
		onlink(o);
		c->qid = o->node->qid;
	}
	refresh(c);
	gone = removedopen(c);
	isdir = (c->qid.type & QTDIR) != 0;
	nd = o->node;
	chname = d.name[0] != '\0' &&
		strcmp(d.name, nd != nil ? nd->name : strrchr(o->path, '/') ? strrchr(o->path, '/')+1 : o->path) != 0;
	chmode = d.mode != (ulong)~0;
	chmtime = d.mtime != (ulong)~0;
	chlen = d.length != ~0LL;
	if(chlen && isdir && d.length != 0)
		error(Eisdir);
	if(chmode && ((d.mode & DMDIR) != 0) != isdir)
		error(Eperm);
	if(chname && isdir && (nd == nil || nd->kind == Nmark))
		error(Eperm);	/* a lower directory can't be renamed */
	if(o->node == in->root && chname)
		error(Eperm);
	if(gone && chname)
		error(Enonexist);
	if(chname || chmode || chmtime || chlen){
		if(nd == nil){
			if(isdir){
				nd = markpath(in, o->path, npathelem(o->path));
				nd->ref++;
				o->node = nd;
			}else
				copyup(c, 0);
			nd = o->node;
		}
		if(chlen){
			if(d.length < 0 || d.length > Maxfile)
				error(Etoobig);
			if(d.length < nd->length)
				trimblocks(in, nd, d.length);
			nd->length = d.length;
			nd->qid.vers++;
		}
		if(!gone)
			changed(in, o->path);
		if(chname){
			ovrename(c, nd, d.name);
			changed(in, o->path);
		}
		if(chmode)
			nd->mode = (nd->mode & DMDIR) | (d.mode & ~DMDIR);
		if(chmtime)
			nd->mtime = d.mtime;
		if((c->flag & COPEN) == 0 || !o->lopen)
			c->qid = nd->qid;
	}
	qunlock(&in->ql);
	poperror();
	poperror();
	free(strs);
	return n;
}

/*
 * The target of the link c is: an overlay's own, or the lower tree's,
 * through its device, for a name that's below (design/file-interface.md).
 */
static int
ovreadlink(Chan *c, char *buf, int nbuf)
{
	Chan *volatile l;
	int n;

	if((n = h9_overlay_readlink(c, buf, nbuf)) >= 0)
		return n;
	l = h9_overlay_lower(c);
	if(l == nil)
		return -1;
	if(waserror()){
		cclose(l);
		nexterror();
	}
	n = devreadlink(l, buf, nbuf);
	poperror();
	cclose(l);
	return n;
}

static void
ovsymlink(Chan *c, char *name, char *target)
{
	h9_overlay_symlink(cclone(c), name, target);
}

/*
 * c's attributes: its stat's, with the lower tree's links, ids, device,
 * and nanoseconds for a name that's below, or a union's member's
 * (design/file-interface.md).
 */
static void
ovgetattr(Chan *c, uvlong mask, Attr *a)
{
	Chan *volatile l;
	uchar buf[STATFIXLEN+4*KNAMELEN];
	char strs[sizeof buf];
	Attr la;
	Dir d;
	int n;

	n = ovstat(c, buf, sizeof buf);
	if(convM2D(buf, n, &d, strs) == 0)
		error(Ebadstat);
	memset(a, 0, sizeof *a);
	a->valid = Amode|Aatime|Amtime|Aino|Asize;
	a->qid = d.qid;
	a->mode = d.mode;
	a->size = d.length;
	a->atime = d.atime;
	a->mtime = d.mtime;
	l = h9_overlay_lower(c);
	if(l == nil)
		return;
	if(waserror()){
		cclose(l);
		nexterror();
	}
	devgetattr(l, mask, &la);
	poperror();
	cclose(l);
	a->nlink = la.nlink;
	a->valid |= la.valid & (Anlink|Auid|Agid|Ardev|Ablocks);
	a->uid = la.uid;
	a->gid = la.gid;
	a->rdev = la.rdev;
	a->blocks = la.blocks;
	if((la.valid & Aatime) && la.atime == a->atime)
		a->atimens = la.atimens;
	if((la.valid & Amtime) && la.mtime == a->mtime)
		a->mtimens = la.mtimens;
	if(la.valid & Actime){
		a->valid |= Actime;
		a->ctime = la.ctime;
		a->ctimens = la.ctimens;
	}
}

static int
ovrename1(Chan *c, Chan *dc, char *name)
{
	if(isctl(c) || isctl(dc))
		error(Eperm);
	return h9_overlay_move(c, dc, name);
}

Dev overlaydevtab = {
	'O',
	"overlay",

	devreset,
	devinit,
	devshutdown,
	ovattach,
	ovwalk,
	ovstat,
	ovopen,
	ovcreate,
	ovclose,
	ovread,
	devbread,
	ovwrite,
	devbwrite,
	ovremove,
	ovwstat,
};

/*
 * The optional operations (design/file-interface.md, src/kern/devx.h).
 * A link is the switch's default, a copy: the tree in memory has one
 * name per node.
 */
Devx overlaydevx = {
	'O',
	ovreadlink,
	ovsymlink,
	nil,
	ovgetattr,
	nil,
	ovrename1,
};
