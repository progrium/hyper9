/*
 * Host commands (#C) end with their machine.
 *
 * drawterm's devcmd starts a host process with oscmd from cmdproc, a
 * kproc, and kills it only when the last fd on its conversation closes.
 * A guest process reading a conversation's data or stderr waits in a
 * host read() that a note can't interrupt, so a stopped machine could
 * leave it stuck, holding the fds, and the host command running after
 * h9 exits (oscmd's setsid puts it outside h9's process group).
 *
 * So posix.c and win32.c are built with their oscmd, oscmdkill and
 * oscmdfree renamed to h9_dt_*, and these wrappers keep a list of the
 * running commands with the machine that started each. When a machine
 * stops (h9_hostcmd_machend: from Machine when it stops its processes,
 * and from proc.c when its last process is released), every command it
 * started is killed, with its process group on POSIX hosts, so the
 * stuck reads see end of file. A command started after that is killed
 * at once.
 */

#ifndef WINDOWS
#include <sys/types.h>
#include <signal.h>
#endif

#include "u.h"
#include "lib.h"
#include "dat.h"
#include "fns.h"
#include "error.h"

#include "hproc.h"

#undef kill

extern void*	h9_dt_oscmd(char**, int, char*, Chan**);
extern int	h9_dt_oscmdkill(void*);
extern void	h9_dt_oscmdfree(void*);

typedef struct Hcmd Hcmd;
struct Hcmd
{
	Hcmd	*next;
	void	*c;		/* oscmd's handle: a pid, or a Windows process handle */
	Hmach	*m;		/* a reference */
	int	killed;
};

static Lock cmdlk;
static Hcmd *cmds;

static void
hardkill(Hcmd *h)
{
	if(h->killed)
		return;
	h->killed = 1;
#ifdef WINDOWS
	h9_dt_oscmdkill(h->c);
#else
	{
		int pid = (int)(uintptr)h->c;

		/* oscmd's child called setsid, so it leads its own group. */
		kill(-pid, SIGKILL);
		kill(pid, SIGKILL);
	}
#endif
}

/*
 * devcmd's oscmd, on cmdproc. The kproc shares the Fgrp of the process
 * that wrote exec, which is blocked until the command starts, so the
 * Fgrp names the machine.
 */
void*
oscmd(char **argv, int nice, char *dir, Chan **fd)
{
	Hcmd *h;
	Hmach *m;
	void *c;

	m = h9_fgrpmach(up->fgrp);
	if(m == nil)
		error("host commands need a machine");
	if(waserror()){
		h9_kern_putmach(m);
		nexterror();
	}
	c = h9_dt_oscmd(argv, nice, dir, fd);
	poperror();
	if(c == nil){
		h9_kern_putmach(m);
		return nil;
	}
	h = mallocz(sizeof *h, 1);
	if(h == nil){
		h9_dt_oscmdkill(c);
		h9_kern_putmach(m);
		return c;
	}
	h->c = c;
	h->m = m;
	lock(&cmdlk);
	h->next = cmds;
	cmds = h;
	if(m->cmdsend)
		hardkill(h);
	unlock(&cmdlk);
	return c;
}

int
oscmdkill(void *c)
{
	return h9_dt_oscmdkill(c);
}

/* After oscmdwait has reaped the command. */
void
oscmdfree(void *c)
{
	Hcmd **l, *h;

	h = nil;
	lock(&cmdlk);
	for(l = &cmds; *l != nil; l = &(*l)->next)
		if((*l)->c == c){
			h = *l;
			*l = h->next;
			break;
		}
	unlock(&cmdlk);
	if(h != nil){
		h9_kern_putmach(h->m);
		free(h);
	}
	h9_dt_oscmdfree(c);
}

/* Kills every host command machine m started, and any it starts later. */
void
h9_hostcmd_machend(void *v)
{
	Hmach *m;
	Hcmd *h;

	m = v;
	if(m == nil)
		return;
	lock(&cmdlk);
	m->cmdsend = 1;
	for(h = cmds; h != nil; h = h->next)
		if(h->m == m)
			hardkill(h);
	unlock(&cmdlk);
}
