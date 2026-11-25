/*
 * Namespace copying, shared by h9 machines (proc.c's rfork) and the
 * namespace kernel (devns.c, design/epoch-0/namespace-kernel.md): 9front's
 * pgrpcpy (port/pgrp.c) at the pinned release.
 */

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"

/*
 * 9front's pgrpcpy: copies the mount table of from into to when flag has
 * RFNAMEG, and always the device mask.
 */
void
pgrpcpy(Pgrp *to, Pgrp *from, int flag)
{
	Mount *n, *m, **link;
	Mhead *f, **l, *mh;
	int i;

	wlock(&to->ns);
	wlock(&from->ns);	/* must wlock to protect from->mntorder->norder */
	if(waserror()){
		wunlock(&from->ns);
		wunlock(&to->ns);
		nexterror();
	}

	memmove(to->devmask, from->devmask, sizeof from->devmask);

	if((flag & RFNAMEG) == 0)
		goto Done;

	for(i = 0; i < MNTHASH; i++){
		l = &to->mnthash[i];
		for(f = from->mnthash[i]; f != nil; f = f->hash){
			rlock(&f->lock);
			if(waserror()){
				runlock(&f->lock);
				nexterror();
			}
			mh = newmhead(f->from);
			*l = mh;
			l = &mh->hash;
			link = &mh->mount;
			for(m = f->mount; m != nil; m = m->next){
				n = newmount(m->to, m->mflag, m->spec);
				n->umh = mh;
				*link = n;
				link = &n->next;
				m->norder = n;	/* for the mntorder loop below */
			}
			runlock(&f->lock);
			poperror();
		}
	}
	/* add mounts in original mntorder */
	for(m = from->mntorder; m != nil; m = m->order){
		n = m->norder;
		m->norder = nil;
		pgrpinsert(to, n);
	}
Done:
	wunlock(&from->ns);
	wunlock(&to->ns);
	poperror();
}
