/*
 * libh9: h9's machines behind a C ABI, for hosts that aren't written in
 * Zig (src/capi.zig; docs/embedding.md, "From C and other languages").
 * `zig build libh9` puts the shared library (libh9.so, libh9.dylib, or
 * h9.dll) and this header in zig-out/libh9.
 *
 * A machine is configured with the h9 command's own flags, as MANUAL.md
 * describes them: "--dir", "/path/to/root", "--net", "disable", and so
 * on. Unlike the command, the library never reads the environment, so
 * with no mount on / the root is the built-in one, never $H9ROOT.
 *
 * Every function is safe to call from any thread. One machine runs one
 * program at a time; run several machines for more.
 *
 * Not a stable ABI yet: H9_ABI_VERSION changes when it does.
 */
#ifndef H9_H
#define H9_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define H9_ABI_VERSION 1

typedef struct h9_machine h9_machine;

/* A host descriptor: a file descriptor, or a HANDLE on Windows. */
typedef intptr_t h9_fd;
#define H9_NOFD ((h9_fd)-1)

/* H9_ABI_VERSION as this library was built. */
int h9_abi_version(void);

/* h9's version, as `h9 --version` prints it. */
const char *h9_version(void);

/*
 * Makes a machine from h9 flags (flags[0..nflags], each a separate
 * argument, as in argv). Returns the machine, or NULL with the reason in
 * errbuf.
 */
h9_machine *h9_machine_new(const char *const *flags, size_t nflags,
	char *errbuf, size_t errcap);

/* Frees a machine. A machine left stuck by a timed-out run frees nothing. */
void h9_machine_free(h9_machine *m);

/* The engine the machine runs on: "hvf", "kvm", "whp", "hcpu", or "sud". */
const char *h9_machine_engine(h9_machine *m);

/* The architecture of the programs it runs: "arm64", "amd64", or "386". */
const char *h9_machine_arch(h9_machine *m);

/* What h9_machine_run returns, other than -1. */
enum {
	H9_EXITED = 0,	/* status is the exits string; "" is success */
	H9_KILLED = 1,	/* status is the note that killed it */
};

/*
 * Runs one program until its first process exits, with argv[0..argc] as
 * its arguments (argv[0] is the name it sees for itself). The program is
 * aout[0..aoutlen], the bytes of an a.out or ELF for the machine's
 * architecture, when aout isn't NULL; otherwise argv[0], looked up in the
 * machine's namespace as the h9 command does.
 *
 * in, out, and err are the console's host side for this run: H9_NOFD for
 * in reads end of file, and for out or err drops what's written. The run
 * duplicates nothing, so keep them open until it returns. A blocking in
 * is fine; the run still ends while the guest waits on it.
 *
 * Returns H9_EXITED or H9_KILLED with the message in status, or -1 if it
 * didn't run, with the reason in status. status is always NUL-terminated
 * when statuscap > 0.
 *
 * A run that times out (--timeout) while a process is in a host call that
 * can't be interrupted returns anyway, after a grace period, and leaves
 * the machine stuck: that process may still use argv, aout, and the
 * descriptors, and the machine can't run again (docs/embedding.md,
 * "Timeouts and stuck machines"). Keep them, or exit the process.
 */
int h9_machine_run(h9_machine *m, const char *const *argv, size_t argc,
	const void *aout, size_t aoutlen,
	h9_fd in, h9_fd out, h9_fd err,
	char *status, size_t statuscap);

/* Notes for a running machine, from any thread. Dropped when none runs. */
enum {
	H9_INTERRUPT = 0,	/* `interrupt` to the foreground (Ctrl-C) */
	H9_HANGUP = 1,		/* `hangup` to every process, teardown after 2 s */
	H9_STOP = 2,		/* tear the machine down now */
};
void h9_machine_signal(h9_machine *m, int sig);

#ifdef __cplusplus
}
#endif

#endif
