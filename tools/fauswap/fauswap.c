/* fauswap -- atomically exchanges two paths via renameat2(RENAME_EXCHANGE).
   See fauswap.md. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE (1 << 1)
#endif

int main(int argc, char **argv) {
	if (argc != 3) {
		fprintf(stderr, "usage: fauswap <path1> <path2>\n");
		return 2;
	}
	if (renameat2(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_EXCHANGE) != 0) {
		fprintf(stderr, "fauswap: renameat2(%s, %s) failed: %s\n", argv[1], argv[2], strerror(errno));
		return 1;
	}
	return 0;
}
