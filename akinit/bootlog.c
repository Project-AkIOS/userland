/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * "bootlog DIR SOURCE COUNT" (moved here from the old init): this boot's console log -- the kernel's lines,
 * launchd's and every daemon's that logs to the console -- kept on the data volume, where AFC reaches it. DIR/boot-1.log
 * is this boot, boot-2.log the one before, ... boot-COUNT.log; each start moves them one up. A child of akinit copies
 * SOURCE (the kernel's console device) into boot-1.log and syncs it every second, so a hard reset loses at most about
 * a second of it. It lives on beside launchd until the end.
 */
#include "akinit.h"

#define MAX_LOGS        9

static void
log_name(char *out, const char *dir, int i)
{
	strcpy(out, dir);
	strcpy(out + strlen(out), "/boot-");
	out[strlen(out) + 1] = 0;
	out[strlen(out)] = (char)('0' + i);
	strcpy(out + strlen(out), ".log");
}

int
op_bootlog(int argc, char **argv)
{
	const char *dir = argv[1], *source = argv[2];
	int count = (int)parse_number(argv[3], 10);
	char from[256], to[256];
	pid_t pid;

	(void)argc;
	if (count < 1 || count > MAX_LOGS || strlen(dir) + 12 > sizeof(from)) {
		return EINVAL;
	}
	make_path(dir, 0755);
	log_name(from, dir, count);
	unlink(from);
	for (int i = count - 1; i >= 1; i--) {
		log_name(from, dir, i);
		log_name(to, dir, i + 1);
		rename(from, to);
	}
	log_name(to, dir, 1);
	pid = fork();
	if (pid < 0) {
		return errno;
	}
	if (pid == 0) {
		char buf[4096];
		struct timeval last, now;
		int in = -1, out;
		ssize_t n;

		out = open(to, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		for (int tries = 0; in < 0 && tries < 50; tries++) {
			in = open(source, O_RDONLY, 0);
			if (in < 0) {
				usleep(100000);
			}
		}
		if (in < 0 || out < 0) {
			_exit(1);
		}
		gettimeofday(&last, NULL);
		for (;;) {
			n = read(in, buf, sizeof(buf));
			if (n > 0 && write(out, buf, (size_t)n) != n) {
				_exit(1);       /* the data volume full or gone */
			}
			gettimeofday(&now, NULL);
			if (now.tv_sec != last.tv_sec) {
				fsync(out);
				last = now;
			}
			if (n < 0) {
				usleep(200000);
			}
		}
	}
	printf("  %s (pid %d), the boot before as boot-2.log\n", to, (int)pid);
	return 0;
}
