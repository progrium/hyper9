/* A static Linux program: prints its arguments and environment, touches a
 * megabyte of heap and exits 3 (design/0018-linux-personality.md). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv, char **envp) {
	printf("hello from linux, argc=%d\n", argc);
	for (int i = 1; i < argc; i++) printf("arg %s\n", argv[i]);
	char *p = malloc(1 << 20);
	memset(p, 1, 1 << 20);
	free(p);
	for (int i = 0; envp[i]; i++)
		if (strncmp(envp[i], "H9_", 3) == 0) printf("env %s\n", envp[i]);
	return 3;
}
