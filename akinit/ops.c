/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * The plan's plain steps: mounts, the root switch, directories and files, and the hand-over to launchd. The bigger
 * jobs are in files of their own (datavol.c, skel.c, gestalt.c, bootlog.c, run.c, inject.c).
 */
#include "akinit.h"

/* the kernel's interfaces this file uses; renamed together with the kernel, later */
#define SYSCTL_SWITCH_ROOT      "kern.hakios_switch_root"
#define SYSCTL_SYNTHETIC        "kern.apfs_synthetic"

/* ---- what the plan runner asks ---- */

/* The value of boot-arg NAME on the kernel's command line ("" for a bare NAME), or NULL. */
const char *
bootarg(const char *name)
{
	static char args[1024], value[128];
	size_t len = sizeof(args) - 1, n = strlen(name);

	if (sysctlbyname("kern.bootargs", args, &len, NULL, 0) != 0) {
		return NULL;
	}
	args[len < sizeof(args) ? len : sizeof(args) - 1] = 0;
	for (char *p = args; *p;) {
		while (*p == ' ') {
			p++;
		}
		if (strncmp(p, name, n) == 0 && p[n] == '=') {
			size_t i = 0;

			for (p += n + 1; *p && *p != ' ' && i < sizeof(value) - 1; p++) {
				value[i++] = *p;
			}
			value[i] = 0;
			return value;
		}
		while (*p && *p != ' ') {
			p++;
		}
	}
	return NULL;
}

int
path_exists(const char *path)
{
	struct stat st;

	return stat(path, &st) == 0;
}

/* ---- steps ---- */

int
op_say(int argc, char **argv)
{
	printf("  ");
	for (int i = 1; i < argc; i++) {
		printf("%s%s", argv[i], i + 1 < argc ? " " : "");
	}
	printf("\n");
	return 0;
}

int
op_sysinfo(int argc, char **argv)
{
	char type[32] = "?", release[32] = "?", machine[32] = "?", version[256] = "?";
	unsigned long long memsize = 0;
	int ncpu = 0;
	size_t len;

	(void)argc, (void)argv;
	len = sizeof(type), sysctlbyname("kern.ostype", type, &len, NULL, 0);
	len = sizeof(release), sysctlbyname("kern.osrelease", release, &len, NULL, 0);
	len = sizeof(version), sysctlbyname("kern.version", version, &len, NULL, 0);
	len = sizeof(machine), sysctlbyname("hw.machine", machine, &len, NULL, 0);
	len = sizeof(memsize), sysctlbyname("hw.memsize", &memsize, &len, NULL, 0);
	len = sizeof(ncpu), sysctlbyname("hw.ncpu", &ncpu, &len, NULL, 0);
	printf("  %s %s %s, memory %llu MB, %d cpu\n  %s\n", type, release, machine, memsize >> 20, ncpu, version);
	return 0;
}

int
op_mount(int argc, char **argv)
{
	int flags = argc > 4 && strcmp(argv[4], "rw") == 0 ? 0 : MNT_RDONLY;

	if (argc > 4 && strcmp(argv[4], "rw") != 0 && strcmp(argv[4], "ro") != 0) {
		return EINVAL;
	}
	if (strcmp(argv[1], "ramfs") == 0) {
		flags = 0;
	}
	return mount(argv[1], argv[3], flags, strcmp(argv[2], "-") == 0 ? NULL : (void *)argv[2]) == 0 ? 0 : errno;
}

int
op_hfs(int argc, char **argv)
{
	int err = mount_hfs(argv[1], argv[2]);

	if (err == 0 && argc == 6) {
		chmod(argv[2], (int)parse_number(argv[3], 8));
		chown(argv[2], (int)parse_number(argv[4], 10), (int)parse_number(argv[5], 10));
	}
	return err;
}

int
op_bind(int argc, char **argv)
{
	(void)argc;
	return mount("bindfs", argv[2], MNT_RDONLY, (void *)argv[1]) == 0 ? 0 : errno;
}

int
op_union(int argc, char **argv)
{
	(void)argc;
	return mount("bindfs", argv[2], MNT_RDONLY | MNT_UNION, (void *)argv[1]) == 0 ? 0 : errno;
}

static int
synthetic(const char *path)
{
	return sysctlbyname(SYSCTL_SYNTHETIC, NULL, NULL, (void *)path, strlen(path)) == 0 ? 0 : errno;
}

int
op_synthetic(int argc, char **argv)
{
	(void)argc;
	return synthetic(argv[1]);
}

/*
 * Every entry of DIR whose name ends in SUFFIX gets another name in INTO, on the same volume (a synthetic
 * "INTO/NAME=DIR/NAME": not a mount, which whatever registers the system's applications passes over). The first
 * boot's applications (private/var/staged_system_apps) among the system's own in /Applications. Fails when there
 * is none, or not every one got its name.
 */
int
op_aliases(int argc, char **argv)
{
	static char buf[8192];
	char from[800], to[400];
	size_t ls = strlen(argv[3]);
	off_t pos = 0;
	ssize_t n;
	int fd, found = 0, made = 0;

	(void)argc;
	fd = open(argv[1], O_RDONLY | O_DIRECTORY, 0);
	while (fd >= 0 && (n = getdirentries(fd, buf, sizeof(buf), &pos)) > 0) {
		for (char *p = buf; p < buf + n;) {
			struct dirent *de = (struct dirent *)(void *)p;
			size_t len = de->d_namlen;

			if (de->d_reclen == 0) {
				break;
			}
			p += de->d_reclen;
			if (len <= ls || strncmp(de->d_name + len - ls, argv[3], ls) != 0 ||
			    strlen(argv[2]) + len + 2 > sizeof(to) || strlen(argv[2]) + strlen(argv[1]) + 2 * len + 4 > sizeof(from)) {
				continue;
			}
			found++;
			strcpy(to, argv[2]);
			strcpy(to + strlen(to), "/");
			memcpy(to + strlen(to), de->d_name, len + 1);
			strcpy(from, to);
			strcpy(from + strlen(from), "=");
			strcpy(from + strlen(from), argv[1]);
			strcpy(from + strlen(from), "/");
			memcpy(from + strlen(from), de->d_name, len + 1);
			made += synthetic(from) == 0;
		}
	}
	if (fd >= 0) {
		close(fd);
	}
	printf("  %d entries of %s, %d of them in %s\n", found, argv[1], made, argv[2]);
	return found > 0 && made == found ? 0 : ENOENT;
}

/* NEWROOT becomes the root, the old root goes to NEWROOT/OLDROOT-DEST (relative to the new root) */
int
op_switchroot(int argc, char **argv)
{
	char spec[256];

	(void)argc;
	if (strlen(argv[1]) + strlen(argv[2]) + 2 > sizeof(spec)) {
		return EINVAL;
	}
	strcpy(spec, argv[1]);
	strcpy(spec + strlen(spec), " ");
	strcpy(spec + strlen(spec), argv[2]);
	if (sysctlbyname(SYSCTL_SWITCH_ROOT, NULL, NULL, spec, strlen(spec)) != 0) {    /* (no 0: the kernel ends it) */
		return errno;
	}
	chdir("/");
	return 0;
}

int
op_chdir(int argc, char **argv)
{
	if (chdir(argv[1]) != 0) {
		return errno;
	}
	if (argc > 2) {
		flag_set(argv[2]);
	}
	return 0;
}

int
op_mkdir(int argc, char **argv)
{
	if (mkdir(argv[1], (int)parse_number(argv[2], 8)) != 0 && errno != EEXIST) {
		return errno;
	}
	if (argc == 5 && chown(argv[1], (int)parse_number(argv[3], 10), (int)parse_number(argv[4], 10)) != 0) {
		return errno;
	}
	return 0;
}

int
op_mkdirp(int argc, char **argv)
{
	(void)argc;
	make_path(argv[1], (int)parse_number(argv[2], 8));
	return path_exists(argv[1]) ? 0 : ENOENT;
}

int
op_chmod(int argc, char **argv)
{
	(void)argc;
	return chmod(argv[1], (int)parse_number(argv[2], 8)) == 0 ? 0 : errno;
}

int
op_chown(int argc, char **argv)
{
	(void)argc;
	return chown(argv[1], (int)parse_number(argv[2], 10), (int)parse_number(argv[3], 10)) == 0 ? 0 : errno;
}

int
op_empty(int argc, char **argv)
{
	(void)argc;
	empty_tree(argv[1], 0);
	return 0;
}

int
op_rm(int argc, char **argv)
{
	unsigned removed = 0;

	for (int i = 1; i < argc; i++) {
		remove_matching(argv[i], &removed);
	}
	printf("  %u removed\n", removed);
	return 0;
}

int
op_touch(int argc, char **argv)
{
	int fd = open(argv[1], O_WRONLY | O_CREAT, (int)parse_number(argv[2], 8)), ok;

	(void)argc;
	ok = fd >= 0 && chown(argv[1], (int)parse_number(argv[3], 10), (int)parse_number(argv[4], 10)) == 0;
	if (fd >= 0) {
		close(fd);
	}
	return ok ? 0 : errno;
}

int
op_sync(int argc, char **argv)
{
	(void)argc, (void)argv;
	sync();
	return 0;
}

int
op_flag(int argc, char **argv)
{
	(void)argc;
	flag_set(argv[1]);
	return 0;
}

/*
 * SRC copied to DST (through DST.new) when DST is missing or of another size. The AoC's firmware kept on the data
 * volume: the kernel's AoC driver reads it there when the image leaves it out.
 */
int
op_keepcopy(int argc, char **argv)
{
	char tmp[300];
	struct stat in, out;

	(void)argc;
	if (stat(argv[1], &in) != 0) {
		return errno;
	}
	if (stat(argv[2], &out) == 0 && out.st_size == in.st_size) {
		printf("  %s: the same size there already\n", argv[2]);
		return 0;
	}
	if (strlen(argv[2]) + 5 > sizeof(tmp)) {
		return EINVAL;
	}
	strcpy(tmp, argv[2]);
	for (char *p = tmp + strlen(tmp); p > tmp; p--) {
		if (*p == '/') {
			*p = 0;
			make_path(tmp, 0755);
			break;
		}
	}
	strcpy(tmp, argv[2]);
	strcpy(tmp + strlen(tmp), ".new");
	if (!copy_file(argv[1], tmp, 0644, 0, 0) || rename(tmp, argv[2]) != 0) {
		int err = errno;

		unlink(tmp);
		return err ? err : EINVAL;
	}
	printf("  %lld bytes copied\n", (long long)in.st_size);
	return 0;
}

/* ---- the hand-over ---- */

#define MAX_ENV 16
static char *env[MAX_ENV + 1];
static char env_text[MAX_ENV][160];
static int nenv;

int
op_env(int argc, char **argv)
{
	(void)argc;
	if (nenv == MAX_ENV || strlen(argv[1]) >= sizeof(env_text[0]) || strchr(argv[1], '=') == NULL) {
		return EINVAL;
	}
	strcpy(env_text[nenv], argv[1]);
	env[nenv] = env_text[nenv];
	nenv++;
	return 0;
}

int
op_stderr(int argc, char **argv)
{
	int fd = open(argv[1], O_WRONLY, 0);

	(void)argc;
	if (fd < 0) {
		return errno;
	}
	dup2(fd, 2);
	if (fd != 2) {
		close(fd);
	}
	return 0;
}

int
op_exec(int argc, char **argv)
{
	static char *args[PLAN_MAX_WORDS];

	for (int i = 1; i < argc; i++) {
		args[i - 1] = argv[i];
	}
	args[argc - 1] = NULL;
	printf("\n=== akinit: process 1 becomes %s ===\n", argv[1]);
	execve(argv[1], args, env);
	return errno;
}

/*
 * reboot [SECONDS]: restart the phone after SECONDS (default 10: the console can still be read over USB). A restart,
 * never a power-off: RAM is kept, so pstore (the boot's log) survives, and the phone comes back by itself -- into
 * Android, or into the bootloader with restart_fastboot=1. (A halt powers akita off; with the cable in, the bootloader
 * then goes into charging mode and needs a hand.)
 */
int
op_reboot(int argc, char **argv)
{
	unsigned int seconds = 10;
	const char *p;

	if (argc > 0) {
		for (seconds = 0, p = argv[0]; *p >= '0' && *p <= '9' && seconds < 3600; p++) {
			seconds = seconds * 10 + (unsigned int)(*p - '0');
		}
	}

	printf("akinit: restarting in %u s\n", seconds);
	sync();
	while (seconds-- > 0) {
		usleep(1000000);
	}
	reboot(RB_AUTOBOOT);
	return errno;
}

int
op_halt(int argc, char **argv)
{
	(void)argc, (void)argv;
	printf("akinit: halting\n");
	sync();
	reboot(RB_HALT);
	return errno;
}
