/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * The kernel's settings for what launchd starts (moved here from the old init):
 *
 * "inject FILE", "inject-line LIBRARY NAME...", "inject-apply": the programs started with a library of ours inside
 * them. FILE has one "LIBRARY NAME NAME..." a line (ak userland writes it from userland.toml); the kernel takes them
 * separated by ";" in the sysctl kern.exec_inject, at most 4 KB (a longer list is refused whole).
 *
 * "vnodes MAX": the kernel is configured for a very small machine and stops at 1024 vnodes whatever the memory; a
 * system with an application open needs more. One for every 64 KB of memory and 1024, as the kernel's own rule gives
 * a bigger configuration, up to MAX.
 */
#include "akinit.h"

#define SYSCTL_INJECT   "kern.exec_inject"

static char conf[4096];
static size_t used;

static int
add(const char *text, size_t n)
{
	while (n > 0 && (text[n - 1] == '\n' || text[n - 1] == ' ')) {
		n--;
	}
	if (n == 0) {
		return 0;
	}
	if (used + n + 2 > sizeof(conf)) {
		printf("  the list would be over the kernel's %zu bytes\n", sizeof(conf));
		return EINVAL;
	}
	if (used > 0) {
		conf[used++] = ';';
	}
	for (size_t i = 0; i < n; i++) {
		conf[used++] = text[i] == '\n' ? ';' : text[i];
	}
	conf[used] = 0;
	return 0;
}

int
op_inject(int argc, char **argv)
{
	static char file[4096];
	ssize_t n = read_whole(argv[1], file, sizeof(file));

	(void)argc;
	return n < 0 ? errno : add(file, (size_t)n);
}

int
op_inject_line(int argc, char **argv)
{
	char line[1024];
	size_t at = 0;

	for (int i = 1; i < argc; i++) {
		size_t n = strlen(argv[i]);

		if (at + n + 2 > sizeof(line)) {
			return EINVAL;
		}
		memcpy(line + at, argv[i], n);
		at += n;
		line[at++] = i + 1 < argc ? ' ' : 0;
	}
	return add(line, at - 1);
}

int
op_inject_apply(int argc, char **argv)
{
	(void)argc, (void)argv;
	if (used == 0) {
		return 0;
	}
	if (sysctlbyname(SYSCTL_INJECT, NULL, NULL, conf, used + 1) != 0) {
		return errno;
	}
	printf("  library insertion: %s\n", conf);
	return 0;
}

int
op_vnodes(int argc, char **argv)
{
	unsigned long long memsize = 0, max = (unsigned long long)parse_number(argv[1], 10);
	size_t len = sizeof(memsize);
	int vnodes;

	(void)argc;
	if (sysctlbyname("hw.memsize", &memsize, &len, NULL, 0) != 0) {
		return errno;
	}
	vnodes = memsize / 65536 + 1024 > max ? (int)max : (int)(memsize / 65536) + 1024;
	if (sysctlbyname("kern.maxvnodes", NULL, NULL, &vnodes, sizeof(vnodes)) != 0) {
		return errno;
	}
	printf("  up to %d vnodes\n", vnodes);
	return 0;
}
