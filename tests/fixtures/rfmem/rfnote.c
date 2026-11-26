/*
 * For "an rfork child takes no note before its first instruction" in
 * tests/integration.zig. The parent posts a note to each RFMEM child as
 * soon as rfork returns. 9front's child enters user mode through
 * forkret, which doesn't deliver notes, so the child's handler runs only
 * after the child has run: by then it has marked its own copy of the
 * stack. A Go program keeps its g there, so a handler that ran before
 * the child's first instruction saw the parent's g and used the parent's
 * signal stack.
 */
#include <u.h>
#include <libc.h>

enum {
	Parent = 1,
	Child,
	N = 100,
};

int	*markp;
int	parentpid;
int	early;
int	got;

void
handler(void*, char *msg)
{
	if(strcmp(msg, "hello") != 0)
		noted(NDFLT);
	if(getpid() != parentpid){
		if(*markp != Child)
			early++;
		got = 1;
	}
	noted(NCONT);
}

void
main(void)
{
	int mark, i, pid;

	/* On the stack, so each process has its own copy at this address. */
	mark = Parent;
	markp = &mark;
	parentpid = getpid();
	notify(handler);
	for(i = 0; i < N; i++){
		got = 0;
		switch(pid = rfork(RFPROC|RFMEM)){
		case -1:
			sysfatal("rfork: %r");
		case 0:
			*markp = Child;
			while(!got)
				sleep(1);
			exits(nil);
		}
		postnote(PNPROC, pid, "hello");
		waitpid();
	}
	print("early %d of %d\n", early, N);
	exits(nil);
}
