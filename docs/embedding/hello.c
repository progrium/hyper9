/*
 * libh9 from C (docs/embedding.md, "From C and other languages"): runs
 * an a.out from the host in a fresh machine, with the console on this
 * process's stdout and stderr, and prints how it ended.
 *
 *	zig build libh9-example
 *	zig-out/bin/libh9-hello zig-out/fixtures/hello-amd64 [h9 flags...]
 */
#include <stdio.h>
#include <stdlib.h>
#include <h9.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#define OUT ((h9_fd)GetStdHandle(STD_OUTPUT_HANDLE))
#define ERR ((h9_fd)GetStdHandle(STD_ERROR_HANDLE))
#else
#define OUT 1
#define ERR 2
#endif

int
main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: libh9-hello AOUT [h9 flags...]\n");
		return 2;
	}
#ifdef _WIN32
	/*
	 * The guest writes the console's handles directly, so keep stdio
	 * from turning this program's own \n into \r\n around it.
	 */
	_setmode(_fileno(stdout), _O_BINARY);
	_setmode(_fileno(stderr), _O_BINARY);
#endif
	FILE *f = fopen(argv[1], "rb");
	if (f == NULL) {
		perror(argv[1]);
		return 1;
	}
	static char prog[1 << 20];
	size_t n = fread(prog, 1, sizeof prog, f);
	fclose(f);

	char msg[512];
	h9_machine *m = h9_machine_new((const char *const *)argv + 2, argc - 2, msg, sizeof msg);
	if (m == NULL) {
		fprintf(stderr, "h9_machine_new: %s\n", msg);
		return 1;
	}
	printf("libh9 %s, engine %s, arch %s\n", h9_version(), h9_machine_engine(m), h9_machine_arch(m));
	fflush(stdout);

	const char *args[] = {"hello"};
	int r = h9_machine_run(m, args, 1, prog, n, H9_NOFD, OUT, ERR, msg, sizeof msg);
	switch (r) {
	case H9_EXITED:
		printf("exited \"%s\"\n", msg);
		break;
	case H9_KILLED:
		printf("killed: %s\n", msg);
		break;
	default:
		fprintf(stderr, "h9_machine_run: %s\n", msg);
	}
	h9_machine_free(m);
	return r == H9_EXITED && msg[0] == 0 ? 0 : 1;
}
