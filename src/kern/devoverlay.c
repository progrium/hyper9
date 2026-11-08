/*
 * #O: copy-on-write overlays (design/0006-ephemeral-writes.md).
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
 *	Nlink	a symbolic link made by the Linux personality (h9_overlay_symlink),
 *		holding its target. A walk follows it, as devfs follows a contained
 *		tree's links: an absolute target from the instance root, a
 *		relative one from the link's directory. The chan keeps the link
 *		beside the target, so remove and rename act on the link, and
 *		h9_overlay_readlink reads it. A final link whose target is
 *		missing is walked to as itself, and opening it fails.
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
 * (design/0011-overlay.md). Writes to a file already in memory aren't
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

/* Implemented in Zig (src/kern.zig). They never raise kernel errors. */
extern void *h9_overlay_pool(void);
extern void *h9_overlay_alloc(void *pool, ulong n);
extern void h9_overlay_free(void *pool, void *p, ulong n);
extern void h9_overlay_changed(void *track, char *path);

enum
{
	Pgsize	= 4096,		/* vmm.page_size */
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

	Maxlinks	= 40,	/* links followed in one walk, as Linux allows */
};

#define Maxfile	((vlong)(Ndirect + Perpage*Perpage) * Pgsize)
#define Copybit	(1ULL<<63)

static char Efull[] = "file system full";
static char Enotempty[] = "directory not empty";

typedef struct Inst Inst;
typedef struct Node Node;
typedef struct Ovc Ovc;
typedef struct Pg Pg;
typedef struct Chunk Chunk;

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
	int	nlinks;		/* links followed in this walk */
};

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

/* Brings a chan up to date with the tree, for operations other than I/O on an open chan. */
static void
refresh(Chan *c)
{
	Ovc *o;

	o = c->aux;
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
static void
changed(Inst *in, char *path)
{
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

static void
instfree(Inst *in)
{
	Pg *p, *np;

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
	free(in);
}

static void
instdecref(Inst *in)
{
	int i, last;

	lock(&instlock);
	last = --in->ref == 0;
	if(last)
		for(i = 0; i < Maxinst; i++)
			if(insts[i] == in)
				insts[i] = nil;
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
 * The lower chan for c's name, for h9_fs_readlinkpath (src/kern/fscheck.c),
 * or nil if c isn't an overlay chan or its name is in memory: a link
 * copied up is a file now.
 */
Chan*
h9_overlay_lower(Chan *c)
{
	Ovc *o;

	if(devtab[c->type]->dc != 'O')
		return nil;
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

/*
 * Makes name in the directory c a symbolic link to target, for the
 * Linux personality's symlinkat. c is an overlay chan, which this closes.
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

	if(devtab[c->type]->dc != 'O' || nbuf <= 0)
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

/*
 * The device.
 */

static Chan*
ovattach(char *spec)
{
	Inst *in;
	Chan *c;
	char *e;
	long id;

	if(spec == nil || *spec == '\0')
		error(Ebadarg);
	id = strtol(spec, &e, 10);
	if(*e != '\0' || id < 0)
		error(Ebadarg);
	lock(&instlock);
	in = instlookup(id);
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
	c = devattach('O', spec);
	c->dev = id;
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
	if(nn != nil && nn->kind == Nlink){
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
		if(r <= BIT16SZ)
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
		error(Enonexist);	/* a link whose target is missing */
	if(c->qid.type & QTDIR){
		if(mode != OREAD || (omode & OTRUNC))
			error(Eisdir);
		if(o->node == nil){
			o->lower = devtab[o->lower->type]->open(o->lower, OREAD);
			o->lopen = 1;
		}
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

	o = c->aux;
	if(o == nil)
		return;
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
 * Moves c's name into the directory dc as name, for the Linux
 * personality's renameat across directories (h9_fs_renamepath in
 * src/kern/fscheck.c), as ovrename does within one. Both are overlay
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
	int isdir, chname, chmode, chmtime, chlen;

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
