/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * akinit: process 1 of AkIOS, the image's /sbin/launchd, until Apple's launchd takes over.
 *
 * The kernel starts it from the RAM disk (rd=md0, out/akios.apfs). It runs the boot plan /etc/akios/boot.plan that
 * `ak userland` wrote (plan.h has the format, akinit.h the steps): mount the iPhone's system volume from the flash and
 * put our parts over it, make it the root (this image goes to its /private/preboot, and /akita is bound back), mount
 * the data volumes, set what the kernel wants to know, and exec Apple's launchd. If the plan ends without that, the
 * phone restarts (never halts: a halt powers akita off).
 *
 *   akinit --check FILE    (not process 1) parse FILE and say what is wrong with it; status 0 when nothing is
 *   akinit FILE            (not process 1) run FILE: the host test does this against a fake system (test/)
 */
#include "akinit.h"

#define PLAN    "/etc/akios/boot.plan"

static const struct plan_op ops[] = {
#define AKINIT_ENTRY(name, lo, hi, fn) { name, lo, hi, fn },
	AKINIT_OPS(AKINIT_ENTRY)
	{ NULL, 0, 0, NULL },
};

static char plan[65536];

int
main(int argc, char **argv, char **envp)
{
	const char *file = PLAN;
	int check = 0, r;

	(void)envp;
	if (getpid() == 1) {
		int fd = open("/dev/console", O_RDWR, 0);

		dup2(fd, 0);
		dup2(fd, 1);
		dup2(fd, 2);
		if (fd > 2) {
			close(fd);
		}
	} else if (argc == 3 && strcmp(argv[1], "--check") == 0) {
		file = argv[2], check = 1;
	} else if (argc == 2) {
		file = argv[1];
	} else {
		printf("usage: akinit --check FILE | akinit FILE (process 1 runs %s)\n", PLAN);
		return 2;
	}

	if (!check) {
		printf("\n=== akinit: process %d, the plan %s ===\n", getpid(), file);
	}
	if (read_whole(file, plan, sizeof(plan)) < 0) {
		printf("akinit: %s: %s\n", file, strerror(errno));
		r = 1;
	} else {
		r = plan_run(plan, ops, check);
	}
	if (check) {
		printf("%s: %s\n", file, r == 0 ? "the plan is well formed" : "the plan has errors (above)");
		return r != 0;
	}
	printf("\n=== akinit: the plan ended without starting launchd (%d) ===\n", r);
	if (getpid() == 1) {
		op_reboot(0, NULL);         /* never a halt: that powers the phone off (see op_reboot) */
	}
	return 1;
}
