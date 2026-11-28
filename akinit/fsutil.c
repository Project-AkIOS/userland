/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * Files and trees for akinit's steps: copies with modes and owners, emptying a directory, removing what matches a
 * pattern, HFS Plus mounts. (Most of it moved here from the old init.)
 */
#include "akinit.h"

/* A + "/" + B (+ "/" + C) into OUT, or 0 when it does not fit */
int
path_join(char *out, size_t size, const char *a, const char *b, const char *c)
{
	size_t la = strlen(a), lb = strlen(b), lc = c ? strlen(c) : 0;

	if (la + lb + lc + 3 > size) {
		return 0;
	}
	memcpy(out, a, la);
	out[la] = '/';
	memcpy(out + la + 1, b, lb + 1);
	if (c != NULL) {
		out[la + 1 + lb] = '/';
		memcpy(out + la + 2 + lb, c, lc + 1);
	}
	return 1;
}

/* NEEDLE in HAY (libmini has no strstr) */
int
contains(const char *hay, const char *needle)
{
	size_t n = strlen(needle);

	for (; *hay != 0; hay++) {
		if (strncmp(hay, needle, n) == 0) {
			return 1;
		}
	}
	return 0;
}

long
parse_number(const char *text, int radix)
{
	long value = 0;

	for (; *text >= '0' && *text < '0' + radix; text++) {
		value = value * radix + (*text - '0');
	}
	return value;
}

/*
 * A file read whole into BUF (SIZE - 1 bytes at most, then a 0), loudly when it does not fit: a silently cut list
 * once cost directories, insertions and jobs that simply were not there. The length, or -1 without such a file.
 */
ssize_t
read_whole(const char *path, char *buf, size_t size)
{
	int fd = open(path, O_RDONLY, 0);
	size_t got = 0;
	ssize_t n;
	char over;

	if (fd < 0) {
		return -1;
	}
	while (got < size - 1 && (n = read(fd, buf + got, size - 1 - got)) > 0) {
		got += (size_t)n;
	}
	if (got == size - 1 && read(fd, &over, 1) > 0) {
		printf("akinit: %s does not fit in %zu bytes: the rest of it is not used\n", path, size - 1);
	}
	close(fd);
	buf[got] = 0;
	return (ssize_t)got;
}

/* mkdir -p, the new directories root's with MODE */
void
make_path(const char *path, int mode)
{
	char p[256];
	size_t n = strlen(path);

	if (n >= sizeof(p)) {
		return;
	}
	memcpy(p, path, n + 1);
	for (size_t i = 1; i <= n; i++) {
		if (p[i] == '/' || p[i] == 0) {
			char c = p[i];

			p[i] = 0;
			mkdir(p, mode);
			p[i] = c;
		}
	}
}

int
copy_file(const char *from, const char *to, int mode, int uid, int gid)
{
	static char buf[4096];
	int in = open(from, O_RDONLY, 0), out, ok = 0;
	ssize_t n;

	if (in < 0) {
		return 0;
	}
	out = open(to, O_WRONLY | O_CREAT | O_TRUNC, mode);
	if (out >= 0) {
		ok = 1;
		while ((n = read(in, buf, sizeof(buf))) > 0) {
			ok = ok && write(out, buf, (size_t)n) == n;
		}
		close(out);
		ok = ok && n == 0 && chmod(to, mode) == 0 && chown(to, uid, gid) == 0;
	}
	close(in);
	return ok;
}

/* A tree copied, with its modes, owners and links (FROM may be relative to the working directory). */
int
copy_whole_tree(const char *from, const char *to, int depth, unsigned *files)
{
	char buf[4096], a[1100], b[1100];
	struct stat st;
	off_t position = 0;
	ssize_t n;
	int fd, ok = 1;

	if (depth > 40 || lstat(from, &st) != 0) {
		return 0;
	}
	if ((st.st_mode & S_IFMT) == S_IFLNK) {
		n = readlink(from, buf, sizeof(buf) - 1);
		if (n <= 0) {
			return 0;
		}
		buf[n] = 0;
		unlink(to);
		ok = symlink(buf, to) == 0;
		lchown(to, (int)st.st_uid, (int)st.st_gid);
		return ok;
	}
	if ((st.st_mode & S_IFMT) != S_IFDIR) {
		/* a megabyte a write: 4 KB at a time took the 400 MB of the staged applications over ten minutes */
		static char big[1 << 20];
		int in = open(from, O_RDONLY, 0), out;

		(*files)++;
		if (in < 0) {
			return 0;
		}
		out = open(to, O_WRONLY | O_CREAT | O_TRUNC, (int)(st.st_mode & 07777));
		if (out >= 0) {
			while ((n = read(in, big, sizeof(big))) > 0) {
				ok = ok && write(out, big, (size_t)n) == n;
			}
			close(out);
			ok = ok && n == 0 && chmod(to, (int)(st.st_mode & 07777)) == 0 && chown(to, (int)st.st_uid, (int)st.st_gid) == 0;
		} else {
			ok = 0;
		}
		close(in);
		return ok;
	}
	if (mkdir(to, (int)(st.st_mode & 07777)) != 0 && errno != EEXIST) {
		return 0;
	}
	fd = open(from, O_RDONLY | O_DIRECTORY, 0);
	if (fd < 0) {
		return 0;
	}
	while (ok && (n = getdirentries(fd, buf, sizeof(buf), &position)) > 0) {
		for (ssize_t at = 0; ok && at < n; at += ((struct dirent *)(buf + at))->d_reclen) {
			const char *name = ((struct dirent *)(buf + at))->d_name;

			if (((struct dirent *)(buf + at))->d_reclen == 0) {
				break;
			}
			if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
				continue;
			}
			if (!path_join(a, sizeof(a), from, name, NULL) || !path_join(b, sizeof(b), to, name, NULL)) {
				ok = 0;
				break;
			}
			ok = copy_whole_tree(a, b, depth + 1, files);
		}
	}
	close(fd);
	chmod(to, (int)(st.st_mode & 07777));
	chown(to, (int)st.st_uid, (int)st.st_gid);
	return ok;
}

/*
 * Every entry of FROM that TO lacks, copied (never one TO has); SKIP_TOP, a name at the top, left out. The system's
 * /private/var template onto the data volume (datavol.c).
 */
int
copy_missing_tree(const char *from, const char *to, int depth, unsigned *files, const char *skip_top)
{
	char buf[4096], a[1100], b[1100];
	struct stat st, there;
	off_t position = 0;
	ssize_t n;
	int fd, ok = 1;

	if (depth > 40 || lstat(from, &st) != 0) {
		return 0;
	}
	if ((st.st_mode & S_IFMT) != S_IFDIR) {
		if (lstat(to, &there) == 0) {
			return 1;
		}
		return copy_whole_tree(from, to, depth, files);
	}
	if (lstat(to, &there) != 0) {
		if (mkdir(to, (int)(st.st_mode & 07777)) != 0) {
			return 0;
		}
		chmod(to, (int)(st.st_mode & 07777));
		chown(to, (int)st.st_uid, (int)st.st_gid);
	}
	fd = open(from, O_RDONLY | O_DIRECTORY, 0);
	if (fd < 0) {
		return 0;
	}
	while ((n = getdirentries(fd, buf, sizeof(buf), &position)) > 0) {
		for (ssize_t at = 0; at < n; at += ((struct dirent *)(buf + at))->d_reclen) {
			const char *name = ((struct dirent *)(buf + at))->d_name;

			if (((struct dirent *)(buf + at))->d_reclen == 0) {
				break;
			}
			if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0 ||
			    (depth == 0 && skip_top != NULL && strcmp(name, skip_top) == 0) ||
			    !path_join(a, sizeof(a), from, name, NULL) || !path_join(b, sizeof(b), to, name, NULL)) {
				continue;
			}
			ok &= copy_missing_tree(a, b, depth + 1, files, skip_top);
		}
	}
	close(fd);
	return ok;
}

/* What is under PATH, gone; PATH itself stays */
void
empty_tree(const char *path, int depth)
{
	char buf[4096], child[1100];
	off_t position = 0;
	ssize_t n;
	struct stat st;
	int fd = open(path, O_RDONLY | O_DIRECTORY, 0), passes = 0;

	if (fd < 0 || depth > 32) {
		if (fd >= 0) {
			close(fd);
		}
		return;
	}
	/* what is removed moves the rest, so the directory is read again from its start until it is empty (or stuck) */
	while (passes++ < 64 && (n = getdirentries(fd, buf, sizeof(buf), &position)) > 0) {
		for (ssize_t at = 0; at < n; at += ((struct dirent *)(buf + at))->d_reclen) {
			const char *name = ((struct dirent *)(buf + at))->d_name;

			if (((struct dirent *)(buf + at))->d_reclen == 0) {
				break;
			}
			if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0 || !path_join(child, sizeof(child), path, name, NULL)) {
				continue;
			}
			if (lstat(child, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR) {
				empty_tree(child, depth + 1);
				rmdir(child);
			} else {
				unlink(child);
			}
		}
		position = 0;
		lseek(fd, 0, 0);
	}
	close(fd);
}

/* NAME against PAT, where "*" matches any run of characters; a name with a leading dot only by a pattern with one */
static int
match(const char *pat, const char *name)
{
	if (*name == '.' && *pat != '.') {
		return 0;
	}
	for (;;) {
		if (*pat == '*') {
			pat++;
			if (*pat == 0) {
				return 1;
			}
			for (; *name; name++) {
				if (match(pat, name)) {
					return 1;
				}
			}
			return 0;
		}
		if (*pat != *name) {
			return 0;
		}
		if (*pat == 0) {
			return 1;
		}
		pat++, name++;
	}
}

/*
 * unlink() every file PATTERN names; "*" may stand in any component. Without one, the file itself (no matter
 * whether it is there). The count removed is added to REMOVED; 0 is returned (what is not there is not an error).
 */
int
remove_matching(const char *pattern, unsigned *removed)
{
	char dir[1100], rest[1100], comp[256], buf[4096], path[1100];
	const char *star = strchr(pattern, '*'), *slash, *next;
	size_t dlen;
	off_t position = 0;
	ssize_t n;
	int fd;

	if (star == NULL) {
		if (unlink(pattern) == 0) {
			(*removed)++;
			printf("  %s removed\n", pattern);
		}
		return 0;
	}
	/* the directory before the component with the star, the component, and what follows it */
	for (slash = star; slash > pattern && *slash != '/'; slash--) {
	}
	dlen = (size_t)(slash - pattern);
	next = strchr(star, '/');
	if (dlen >= sizeof(dir) || (size_t)((next ? next : star + strlen(star)) - slash - 1) >= sizeof(comp)) {
		return 0;
	}
	memcpy(dir, pattern, dlen);
	dir[dlen] = 0;
	memcpy(comp, slash + 1, (size_t)((next ? next : star + strlen(star)) - slash - 1));
	comp[(next ? next : star + strlen(star)) - slash - 1] = 0;
	strcpy(rest, next ? next : "");
	fd = open(dlen ? dir : "/", O_RDONLY | O_DIRECTORY, 0);
	while (fd >= 0 && (n = getdirentries(fd, buf, sizeof(buf), &position)) > 0) {
		for (ssize_t at = 0; at < n; at += ((struct dirent *)(buf + at))->d_reclen) {
			const char *name = ((struct dirent *)(buf + at))->d_name;

			if (((struct dirent *)(buf + at))->d_reclen == 0) {
				break;
			}
			if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0 || !match(comp, name) ||
			    strlen(dir) + strlen(name) + strlen(rest) + 2 > sizeof(path)) {
				continue;
			}
			strcpy(path, dir);
			strcpy(path + strlen(path), "/");
			strcpy(path + strlen(path), name);
			strcpy(path + strlen(path), rest);
			remove_matching(path, removed);
		}
	}
	if (fd >= 0) {
		close(fd);
	}
	return 0;
}

/* HFS Plus from DEV (a path in /dev) on AT; 0 or an errno */
int
mount_hfs(const char *dev, const char *at)
{
	/* struct hfs_mount_args (bsd/hfs/hfs_mount.h) */
	struct {
		const char *fspec;
		uint32_t uid, gid;
		uint16_t mask, pad;
		uint32_t encoding;
		int tz[2];
		int flags, journal_tbuffer_size, journal_flags, journal_disable;
	} args;

	memset(&args, 0, sizeof(args));
	/*
	 * (11-28) An APFS data volume (iOS 27's installd installs only onto APFS: "Expected install path ... APFS
	 * formatted volume; got hfs"): the container's superblock says "NXSB" at byte 32 of the first block -- then
	 * Apple's APFS mounts it, read-write; anything else is taken for HFS Plus as before.
	 */
	{
		char block[64];
		int fd = open(dev, O_RDONLY, 0);
		ssize_t n = fd >= 0 ? read(fd, block, sizeof(block)) : -1;

		if (fd >= 0) {
			close(fd);
		}
		if (n == (ssize_t)sizeof(block) && memcmp(block + 32, "NXSB", 4) == 0) {
			int r = mount("apfs", at, 0, (void *)dev) == 0 ? 0 : errno;

			printf("  %s: an APFS container: mounted read-write on %s: %s\n", dev, at, r == 0 ? "ok" : strerror(r));
			return r;
		}
	}
	args.fspec = dev;
	return mount("hfs", at, 0, &args) == 0 ? 0 : errno;
}
