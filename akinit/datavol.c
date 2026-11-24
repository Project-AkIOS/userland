/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * The data volume's first contents (moved here from the old init).
 *
 * THE SYSTEM'S /private/var TEMPLATE. A restore puts the system volume's whole /private/var on a new data volume --
 * directories, files and links with their owners -- and iOS counts on its files (db/DarwinDirectory's users and
 * groups, MobileAsset's preinstalled assets, ...). Here the data volume is ours and is mounted OVER the system
 * volume's /private/var, so before it covers it, the volume is mounted once where nothing is (AT, an empty directory
 * of the system volume whose own volume comes later), every entry the template has and the volume lacks is copied
 * (never one it has), and it is unmounted again: "seedvar DEV AT".
 *
 * THE SYSTEM'S DELETABLE APPLICATIONS (Mail, Calendar, Maps ...): Apple's system volume keeps them in
 * /private/var/staged_system_apps and a restore puts that directory on the data volume, where installd installs them
 * from at the first start. They are copied once (the marker DONE says it is done) and MobileInstallation's and the
 * data migrator's notes of the last build go, so that installd does its first-start work again with the bundles
 * there: in seedvar from the system's directory, and in "stagedapps DIR DONE" from the working directory, which a
 * "chdir DIR staged-reachable" before the data volume was mounted left in the system volume's directory.
 */
#include "akinit.h"

static const char *const migration_records[] = {
	"/installd/Library/MobileInstallation/LastBuildInfo.plist",
	"/installd/Library/MobileInstallation/MigrationInfo.plist",
};

static void
forget_migration(const char *var)
{
	char path[256];

	for (unsigned i = 0; i < sizeof(migration_records) / sizeof(migration_records[0]); i++) {
		if (strlen(var) + strlen(migration_records[i]) < sizeof(path)) {
			strcpy(path, var);
			strcpy(path + strlen(path), migration_records[i]);
			unlink(path);
		}
	}
}

static void
mark(const char *path)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);

	if (fd >= 0) {
		close(fd);
	}
}

/* seedvar DEV AT */
int
op_seedvar(int argc, char **argv)
{
	const char *dev = argv[1], *at = argv[2];
	char staged[256], marker[256];
	struct stat st;
	unsigned files = 0, apps = 0;
	int err, ok;

	(void)argc;
	if ((err = mount_hfs(dev, at)) != 0) {
		return err;
	}
	ok = copy_missing_tree("/private/var", at, 0, &files, "staged_system_apps");
	printf("  the system's /private/var template: %u files the data volume did not have copied%s\n", files,
	    ok ? "" : " (some could not be)");
	if (path_join(staged, sizeof(staged), at, "staged_system_apps", NULL) &&
	    path_join(marker, sizeof(marker), at, "db/hakios-staged-apps", NULL) &&
	    stat("/private/var/staged_system_apps", &st) == 0 && lstat(marker, &st) != 0) {
		empty_tree(staged, 0);
		ok = copy_whole_tree("/private/var/staged_system_apps", staged, 0, &apps);
		sync();
		if (ok) {
			forget_migration(at);
			mark(marker);
		}
		printf("  the system's staged applications: %u files copied to the data volume%s\n", apps,
		    ok ? "; installd will install them" : " -- NOT ALL OF THEM (the copy stopped)");
	}
	sync();
	if (unmount(at, 0) != 0) {
		printf("  unmount %s: %s\n", at, strerror(errno));
	}
	return 0;
}

/* stagedapps DIR DONE (flags: var-kept, staged-reachable; boot-arg staged_again=1: once more) */
int
op_stagedapps(int argc, char **argv)
{
	const char *dir = argv[1], *done = argv[2];
	char migrate[256];
	struct stat st;
	unsigned files = 0;
	int ok;

	(void)argc;
	if (strlen(done) + 9 > sizeof(migrate)) {
		return EINVAL;
	}
	strcpy(migrate, done);
	strcpy(migrate + strlen(migrate), "-migrate");
	/* (a phone whose staged applications went back to "Waiting...") */
	if (bootarg("staged_again") != NULL) {
		unlink(done);
		unlink(migrate);
	}
	if (flag_is("var-kept") && flag_is("staged-reachable") && lstat(done, &st) != 0) {
		empty_tree(dir, 0);                     /* (a copy a restart cut short) */
		ok = copy_whole_tree(".", dir, 0, &files);
		sync();                                 /* half a gigabyte: on the flash before anything else is begun */
		if (ok) {
			forget_migration("/private/var");
			mark(done);
		}
		sync();
		printf("  the system's staged applications: %u files copied to the data volume%s\n", files,
		    ok ? "; installd will install them" : " -- NOT ALL OF THEM (the copy stopped)");
	}
	/* the copy alone did not do it: the data migrator says "Migration Needed? NO" once it has run for a build, so its
	 * record of the last system version goes too, once, and the next start migrates as after an update */
	if (flag_is("var-kept") && lstat(done, &st) == 0 && lstat(migrate, &st) != 0) {
		unlink("/private/var/mobile/Library/Preferences/com.apple.migration.plist");
		forget_migration("/private/var");
		mark(migrate);
		printf("  the data migrator's record of the last system version taken away: it migrates again\n");
	}
	chdir("/");
	return 0;
}
