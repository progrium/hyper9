/*
 * The Windows parts of glue.c, kept apart because <windows.h> clashes
 * with drawterm's draw.h.
 */
#include <windows.h>
#include "u.h"
#include "lib.h"

/* The host user, which is hostowner. */
char*
h9_hostuser(void)
{
	static char user[64];
	wchar_t w[64];
	DWORD n;

	n = nelem(w);
	if(!GetUserNameW(w, &n) || WideCharToMultiByte(CP_UTF8, 0, w, -1, user, sizeof user, nil, nil) == 0)
		return "none";
	return user;
}

/*
 * win32.c's WinMain calls drawterm's main, which dtos.h renames mymain.
 * h9 has its own entry point, so it's never called.
 */
int mymain(int argc, char **argv) { USED(argc); USED(argv); return 0; }

/*
 * The host side of tsleep's timer kproc (tsleep.c), as glue.c has it for
 * POSIX hosts: a lock, and a wait on a condition variable until a
 * deadline on the monotonic clock.
 */
static CRITICAL_SECTION tcs;
static CONDITION_VARIABLE tcond;

void
h9_tinit(void)
{
	InitializeCriticalSection(&tcs);
	InitializeConditionVariable(&tcond);
}

uvlong
h9_tnow(void)
{
	static LARGE_INTEGER freq;
	LARGE_INTEGER c;

	if(freq.QuadPart == 0)
		QueryPerformanceFrequency(&freq);
	QueryPerformanceCounter(&c);
	return (uvlong)(c.QuadPart / freq.QuadPart) * 1000000000ULL
		+ (uvlong)(c.QuadPart % freq.QuadPart) * 1000000000ULL / freq.QuadPart;
}

void
h9_tlock(void)
{
	EnterCriticalSection(&tcs);
}

void
h9_tunlock(void)
{
	LeaveCriticalSection(&tcs);
}

void
h9_tsignal(void)
{
	WakeConditionVariable(&tcond);
}

void
h9_twait(uvlong when)
{
	uvlong now, ms;

	if(when == 0){
		SleepConditionVariableCS(&tcond, &tcs, INFINITE);
		return;
	}
	now = h9_tnow();
	if(when <= now)
		return;
	/* Rounded up, so the kproc doesn't wake just before the deadline. */
	ms = (when - now + 999999) / 1000000;
	if(ms >= INFINITE)
		ms = INFINITE - 1;
	SleepConditionVariableCS(&tcond, &tcs, (DWORD)ms);
}
