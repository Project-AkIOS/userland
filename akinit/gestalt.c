/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * "gestalt NOTE CACHE" (moved here from the old init). MobileGestalt keeps its answers in a cache on the data
 * volume, and on a kept volume an answer stays what it was the first time it was asked: the loader's flash (torch=N)
 * came and the flashlight did not, a volume first started without the cameras kept "no camera" for good. What of the
 * device tree changes with the boot arguments is written down in NOTE ("torch", "camera"); when it is not what it
 * was, CACHE goes, and MobileGestalt asks the device tree again.
 */
#include "akinit.h"

int
op_gestalt(int argc, char **argv)
{
	const char *note = argv[1], *cache = argv[2];
	const char *torch = bootarg("torch"), *cam = bootarg("cam"), *camera = bootarg("camera");
	int has_torch = torch != NULL && torch[0] >= '1' && torch[0] <= '9';
	/* the loader's /arm-io/isp node comes with cam=5 or, on the Pixel 8a, camera=13 to 16 */
	int has_camera = (cam != NULL && strcmp(cam, "5") == 0) ||
	    (camera != NULL && (strcmp(camera, "13") == 0 || strcmp(camera, "14") == 0 || strcmp(camera, "15") == 0 ||
	    strcmp(camera, "16") == 0));
	const char *now = has_torch ? (has_camera ? "torch camera\n" : "torch\n") : (has_camera ? "- camera\n" : "-\n");
	char was[24] = "";
	int fd = open(note, O_RDONLY, 0);

	(void)argc;
	if (fd >= 0) {
		ssize_t n = read(fd, was, sizeof(was) - 1);

		was[n > 0 ? n : 0] = 0;
		close(fd);
	}
	if (strcmp(was, now) == 0) {
		return 0;
	}
	printf("  MobileGestalt's cache: the device tree's flash and cameras %s -> %s: %s\n", was[0] ? was : "(not noted)\n", now,
	    unlink(cache) == 0 ? "the cache removed" : strerror(errno));
	fd = open(note, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		return errno;
	}
	(void)write(fd, now, strlen(now));
	close(fd);
	return 0;
}
