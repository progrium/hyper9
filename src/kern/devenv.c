/*
 * #e: environment variables, one environment per Egrp. Ported from
 * 9front's port/devenv.c at the pinned release (NINEFRONT_REV), replacing
 * drawterm's, which has one machine-wide environment and imports the host
 * process's environment on first attach (DESIGN.md, env.scrub).
 *
 * drawterm's Proc has no egrp, and stays as it is, so a Proc's
 * group is kept on its h9 process record (src/kern/proc.c). drawterm's own Egrp
 * and Evalue types don't match 9front's, so this file uses its own (HEgrp,
 * HEvalue). #ec (the kernel configuration group) isn't supported.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

enum
{
	Maxenvsize = 1*1024*1024,
	Maxvalsize = Maxenvsize/2,

	DELTAENV = 32,
	ENVHASH = 64,
};

typedef struct HEgrp HEgrp;
typedef struct HEvalue HEvalue;

struct HEvalue
{
	char	*value;
	int	len;
	ulong	vers;
	uvlong	path;		/* qid.path: HEgrp.path << 32 | index (of HEgrp.ent[]) */
	int	size;		/* bytes allocated for value */
	HEvalue	*hash;
	char	name[];
};

struct HEgrp
{
	Ref	ref;
	RWLock	lk;
	HEvalue	**ent;
	int	nent;		/* number of slots in ent[] */
	int	low;		/* lowest free index in ent[] */
	int	alloc;		/* bytes allocated for env */
	ulong	path;		/* generator for qid path */
	ulong	vers;		/* of HEgrp */
	HEvalue	*hash[ENVHASH];	/* hashtable for name lookup */
};

#define PATH(p,i)	((uvlong)(p) << 32 | (i))
#define QID(qidpath)	((uint)(qidpath) & 0x7FFFFFFF)
#define ROUND(s, sz)	(((s)+((sz)-1))&~((sz)-1))

extern void *h9_upegrp(void);	/* proc.c */

static HEgrp*
upegrp(void)
{
	return h9_upegrp();
}

static void
hcloseegrp(HEgrp *eg)
{
	HEvalue *e;
	int i;

	if(eg == nil || decref(&eg->ref))
		return;
	for(i = 0; i < eg->nent; i++){
		e = eg->ent[i];
		if(e == nil)
			continue;
		free(e->value);
		free(e);
	}
	free(eg->ent);
	free(eg);
}

/*
 * Groups for proc.c, which keeps each process's on its record. They're
 * void* there, since HEgrp is private to this file.
 */

/* A new, empty environment. */
void*
h9_egrpnew(void)
{
	HEgrp *eg;

	eg = mallocz(sizeof(HEgrp), 1);
	if(eg == nil)
		error(Enomem);
	eg->ref.ref = 1;
	return eg;
}

void
h9_egrpincref(void *eg)
{
	incref(&((HEgrp*)eg)->ref);
}

void
h9_egrpclose(void *eg)
{
	hcloseegrp(eg);
}

static void*	envrealloc(HEgrp*, void*, int, int);
static HEvalue**	envhash(HEgrp*, char*);

/* A copy of an environment, for RFENVG: 9front's envcpy. */
void*
h9_egrpcopy(void *vfrom)
{
	HEgrp *to, *from;
	HEvalue *e, *ne, **h;
	int i, n;

	from = vfrom;
	to = h9_egrpnew();
	if(waserror()){
		hcloseegrp(to);
		nexterror();
	}
	rlock(&from->lk);
	if(waserror()){
		runlock(&from->lk);
		nexterror();
	}
	to->ent = envrealloc(to, nil, 0, ROUND(from->nent, DELTAENV) * sizeof(HEvalue*));
	for(i = 0; i < from->nent; i++){
		e = from->ent[i];
		if(e == nil)
			continue;
		h = envhash(to, e->name);
		n = strlen(e->name)+1;
		ne = envrealloc(to, nil, 0, sizeof(HEvalue)+n);
		memmove(ne->name, e->name, n);
		ne->value = nil;
		ne->len = 0;
		ne->size = 0;
		ne->vers = 0;
		ne->path = PATH(++to->path, to->nent);
		ne->hash = *h, *h = ne;
		to->ent[to->nent++] = ne;
		if(e->len > 0){
			ne->value = envrealloc(to, nil, 0, e->len);
			memmove(ne->value, e->value, e->len);
			ne->len = e->len;
			ne->size = e->len;
		}
	}
	to->low = to->nent;
	runlock(&from->lk);
	poperror();
	poperror();
	return to;
}

static HEvalue*
envindex(HEgrp *eg, uvlong qidpath)
{
	HEvalue *e;
	int i;

	i = QID(qidpath);
	if(i >= eg->nent)
		return nil;
	e = eg->ent[i];
	if(e != nil && e->path != qidpath)
		return nil;
	return e;
}

static HEvalue**
envhash(HEgrp *eg, char *name)
{
	uint c, h = 0;
	while((c = *name++) != 0)
		h = h*131 + c;
	return &eg->hash[h % ENVHASH];
}

static HEvalue*
lookupname(HEvalue *e, char *name)
{
	while(e != nil){
		if(strcmp(e->name, name) == 0)
			break;
		e = e->hash;
	}
	return e;
}

static HEgrp*
envgrp(Chan *c)
{
	if(c->aux == nil)
		return upegrp();
	return c->aux;
}

static int
envgen(Chan *c, char *name, Dirtab *_1, int _2, int s, Dir *dp)
{
	HEgrp *eg;
	HEvalue *e;
	Qid q;

	USED(_1);
	USED(_2);
	eg = envgrp(c);
	if(s == DEVDOTDOT){
		c->qid.vers = eg->vers;
		devdir(c, c->qid, "#e", 0, eve, 0775, dp);
		return 1;
	}
	rlock(&eg->lk);
	if((c->qid.type & QTDIR) == 0) {
		e = envindex(eg, c->qid.path);
		if(e == nil)
			goto Notfound;
	} else if(name != nil) {
		if(strlen(name) >= sizeof(up->genbuf))
			goto Notfound;
		e = lookupname(*envhash(eg, name), name);
		if(e == nil)
			goto Notfound;
	} else if(s < eg->nent) {
		e = eg->ent[s];
		if(e == nil) {
			runlock(&eg->lk);
			return 0;	/* deleted, try next */
		}
	} else {
Notfound:
		runlock(&eg->lk);
		return -1;
	}
	/* make sure name string continues to exist after we release lock */
	kstrcpy(up->genbuf, e->name, sizeof(up->genbuf));
	mkqid(&q, e->path, e->vers, QTFILE);
	devdir(c, q, up->genbuf, e->len, eve, 0666, dp);
	runlock(&eg->lk);
	return 1;
}

static Chan*
envattach(char *spec)
{
	Chan *c;

	if(spec != nil && *spec != '\0')
		error(Ebadarg);
	c = devattach('e', spec);
	c->aux = nil;
	return c;
}

static Walkqid*
envwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, envgen);
}

static int
envstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, envgen);
}

/*
 * Resizes an allocation charged to eg. 9front measures blocks with msize;
 * the host malloc can't, so callers pass the old size.
 */
static void*
envrealloc(HEgrp *eg, void *old, int oldsize, int newsize)
{
	void *new;

	if(newsize == 0){
		eg->alloc -= oldsize;
		free(old);
		return nil;
	}
	if(newsize < 0 || (eg->alloc + newsize) - oldsize > Maxenvsize)
		error(Enomem);
	new = realloc(old, newsize);
	if(new == nil)
		error(Enomem);
	eg->alloc += newsize - oldsize;
	return new;
}

static Chan*
envopen(Chan *c, int omode)
{
	HEgrp *eg;
	HEvalue *e;

	eg = envgrp(c);
	if(c->qid.type & QTDIR) {
		if(omode != OREAD)
			error(Eperm);
	}
	else {
		int trunc = omode & OTRUNC;
		if(trunc)
			wlock(&eg->lk);
		else
			rlock(&eg->lk);
		e = envindex(eg, c->qid.path);
		if(e == nil) {
			if(trunc)
				wunlock(&eg->lk);
			else
				runlock(&eg->lk);
			error(Enonexist);
		}
		if(trunc && e->len > 0) {
			e->value = envrealloc(eg, e->value, e->size, 0);	/* free */
			e->size = 0;
			e->len = 0;
			e->vers++;
		}
		c->qid.vers = e->vers;
		if(trunc)
			wunlock(&eg->lk);
		else
			runlock(&eg->lk);
	}
	c->mode = openmode(omode);
	incref(&eg->ref);
	c->aux = eg;
	c->offset = 0;
	c->flag |= COPEN;
	return c;
}

static Chan*
envcreate(Chan *c, char *name, int omode, ulong perm)
{
	HEgrp *eg;
	HEvalue *e, **h;
	int n, i;

	USED(perm);
	if(c->qid.type != QTDIR)
		error(Eperm);

	n = strlen(name)+1;
	if(n > sizeof(up->genbuf))
		error(Etoolong);

	omode = openmode(omode);
	eg = envgrp(c);
	wlock(&eg->lk);
	if(waserror()) {
		wunlock(&eg->lk);
		nexterror();
	}

	h = envhash(eg, name);
	if(lookupname(*h, name) != nil)
		error(Eexist);

	for(i = eg->low; i < eg->nent; i++)
		if(eg->ent[i] == nil)
			break;

	if(i >= eg->nent){
		if((eg->nent % DELTAENV) == 0)
			eg->ent = envrealloc(eg, eg->ent, eg->nent * sizeof(HEvalue*),
				(eg->nent+DELTAENV) * sizeof(HEvalue*));
		i = eg->nent++;
		eg->ent[i] = nil;
		eg->low = i;
	}

	e = envrealloc(eg, nil, 0, sizeof(HEvalue)+n);
	memmove(e->name, name, n);
	e->value = nil;
	e->len = 0;
	e->size = 0;
	e->vers = 0;
	e->path = PATH(++eg->path, i);
	e->hash = *h, *h = e;
	eg->ent[i] = e;
	eg->low = i+1;
	eg->vers++;
	mkqid(&c->qid, e->path, e->vers, QTFILE);
	wunlock(&eg->lk);
	poperror();
	incref(&eg->ref);
	c->aux = eg;
	c->offset = 0;
	c->mode = omode;
	c->flag |= COPEN;
	return c;
}

static void
envremove(Chan *c)
{
	HEgrp *eg;
	HEvalue *e, **h;
	int i;

	if(c->qid.type & QTDIR)
		error(Eperm);

	eg = envgrp(c);
	wlock(&eg->lk);
	e = envindex(eg, c->qid.path);
	if(e == nil){
		wunlock(&eg->lk);
		error(Enonexist);
	}
	for(h = envhash(eg, e->name); *h != nil; h = &(*h)->hash){
		if(*h == e){
			*h = e->hash;
			break;
		}
	}
	i = QID(c->qid.path);
	eg->ent[i] = nil;
	if(i < eg->low)
		eg->low = i;
	eg->vers++;

	/* free */
	envrealloc(eg, e->value, e->size, 0);
	envrealloc(eg, e, sizeof(HEvalue)+strlen(e->name)+1, 0);

	wunlock(&eg->lk);
}

static void
envclose(Chan *c)
{
	if(c->flag & COPEN){
		/*
		 * cclose can't fail, so errors from remove will be ignored.
		 * since permissions aren't checked,
		 * envremove can't not remove it if its there.
		 */
		if(c->flag & CRCLOSE && !waserror()){
			envremove(c);
			poperror();
		}
		hcloseegrp((HEgrp*)c->aux);
		c->aux = nil;
	}
}

static long
envread(Chan *c, void *a, long n, vlong off)
{
	HEgrp *eg;
	HEvalue *e;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, nil, 0, envgen);

	eg = envgrp(c);
	rlock(&eg->lk);
	if(waserror()){
		runlock(&eg->lk);
		nexterror();
	}
	e = envindex(eg, c->qid.path);
	if(e == nil)
		error(Enonexist);
	if(off >= e->len)
		n = 0;
	else if(off + n > e->len)
		n = e->len - off;
	if(n <= 0)
		n = 0;
	else
		memmove(a, e->value+off, n);
	runlock(&eg->lk);
	poperror();
	return n;
}

static long
envwrite(Chan *c, void *a, long n, vlong off)
{
	HEgrp *eg;
	HEvalue *e;
	int diff;

	eg = envgrp(c);
	wlock(&eg->lk);
	if(waserror()){
		wunlock(&eg->lk);
		nexterror();
	}
	e = envindex(eg, c->qid.path);
	if(e == nil)
		error(Enonexist);
	if(off > Maxvalsize || n > (Maxvalsize - off))
		error(Etoobig);
	diff = (off+n) - e->len;
	if(diff > 0){
		e->value = envrealloc(eg, e->value, e->size, e->len+diff);
		e->size = e->len+diff;
	} else
		diff = 0;
	memmove(e->value+off, a, n);
	if(off > e->len)
		memset(e->value+e->len, 0, off-e->len);
	e->len += diff;
	e->vers++;
	eg->vers++;
	wunlock(&eg->lk);
	poperror();
	return n;
}

Dev envdevtab = {
	'e',
	"env",

	devreset,
	devinit,
	devshutdown,
	envattach,
	envwalk,
	envstat,
	envopen,
	envcreate,
	envclose,
	envread,
	devbread,
	envwrite,
	devbwrite,
	envremove,
	devwstat,
};
