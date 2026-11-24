/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * "skel FILE BASE": the data volume's skeleton (moved here from the old init). FILE has one entry a line, its fields
 * separated by tabs, as the IPSW's template list has them (ak userland adds ours):
 *
 *   d MODE UID GID PATH            a directory (on a kept volume, one that is there already is fine)
 *   l TARGET PATH                  a symbolic link
 *   f MODE UID GID PATH SOURCE     a file of ours, SOURCE under BASE; on a kept volume only if PATH is not there yet --
 *                                  what the system made of it since is what counts
 *   x PATH                         a file an older image put there and this one does not: removed
 *
 * The first directory that cannot be made ends it; when none failed, the flag skel-done is set. The step fails when
 * one did, or fewer than 50 directories were made.
 */
#include "akinit.h"

static int
split_tabs(char *line, char **fields, int max)
{
	int n = 0;

	while (n < max) {
		fields[n++] = line;
		line = strchr(line, '\t');
		if (line == NULL) {
			break;
		}
		*line++ = 0;
	}
	return n;
}

int
op_skel(int argc, char **argv)
{
	static char list[16384];
	char source[512];
	struct stat st;
	int ok = 1, made = 0, files = 0, kept = flag_is("var-kept");

	(void)argc;
	if (read_whole(argv[1], list, sizeof(list)) < 0) {
		return errno;
	}
	for (char *line = list; ok && *line;) {
		char *end = strchr(line, '\n'), *f[6];
		int count;

		if (end) {
			*end = 0;
		}
		count = split_tabs(line, f, 6);
		if (count == 5 && f[0][0] == 'd') {
			int mode = (int)parse_number(f[1], 8);

			ok = (mkdir(f[4], mode) == 0 || (kept && errno == EEXIST)) && chmod(f[4], mode) == 0 &&
			    chown(f[4], (int)parse_number(f[2], 10), (int)parse_number(f[3], 10)) == 0;
			if (!ok) {
				printf("  %s: %s\n", f[4], strerror(errno));
			}
			made++;
		} else if (count == 3 && f[0][0] == 'l') {
			symlink(f[1], f[2]);
		} else if (count == 2 && f[0][0] == 'x') {
			if (unlink(f[1]) == 0) {
				printf("  %s: retired, removed\n", f[1]);
			}
		} else if (count == 6 && f[0][0] == 'f') {
			if (kept && lstat(f[4], &st) == 0) {
				files++;
			} else if (strlen(argv[2]) + strlen(f[5]) >= sizeof(source)) {
				printf("  %s: the source's path is too long\n", f[4]);
			} else {
				strcpy(source, argv[2]);
				strcpy(source + strlen(source), f[5]);
				if (!copy_file(source, f[4], (int)parse_number(f[1], 8), (int)parse_number(f[2], 10),
				    (int)parse_number(f[3], 10))) {
					printf("  %s: %s\n", f[4], strerror(errno));
				}
			}
			files++;
		}
		if (!end) {
			break;
		}
		line = end + 1;
	}
	printf("  %d directories, %d files\n", made, files);
	if (ok) {
		flag_set("skel-done");      /* (the old init's markers needed only this, not the count) */
	}
	return ok && made > 50 ? 0 : (errno ? errno : EINVAL);
}
