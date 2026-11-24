/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * The host test's system: libmini's calls (test/mini.h renames them to these) printed as "@ CALL ARGS" lines and
 * answered from a made-up world instead of a kernel. Built with the PC's C library; the program under test is not.
 *
 *   FAKE_BOOTARGS   the kernel's command line (sysctl kern.bootargs)
 *   FAKE_WORLD      a file of paths that exist, one a line ("/a/b/" a directory; a path's parents exist too)
 *   FAKE_MAP        PREFIX=DIR[:PREFIX=DIR...]: paths under PREFIX are DIR's real files, for reading
 *   FAKE_FAIL       CALL:PATH[,CALL:PATH...]: those calls fail (ENOENT), e.g. mount:/private/var
 *
 * Nothing on the PC is written. fork() returns as the parent (children are not run), wait4() says the child exited
 * with 0, a successful execve() ends the test (status 0), reboot() too (status 3).
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

/* libmini's layouts (libmini/mini.h) */
struct fake_timespec { long tv_sec; long tv_nsec; };
struct fake_timeval { long tv_sec; int tv_usec; };
struct fake_stat {
	int32_t st_dev; uint16_t st_mode; uint16_t st_nlink; uint64_t st_ino; uint32_t st_uid, st_gid; int32_t st_rdev;
	struct fake_timespec a, m, c, b; long long st_size; int64_t st_blocks; int32_t st_blksize; uint32_t st_flags, st_gen;
	int32_t st_lspare; int64_t st_qspare[2];
};
struct fake_dirent { uint64_t d_ino, d_seekoff; uint16_t d_reclen, d_namlen; uint8_t d_type; char d_name[1024]; };

#define M_O_WRONLY 1
#define M_O_RDWR 2
#define M_O_CREAT 0x200
#define M_O_DIRECTORY 0x100000
#define M_IFDIR 0040000
#define M_IFREG 0100000

int fake_errno;
char **fake_environ;
int fake_main(int argc, char **argv, char **envp);

static char *world[4096];
static int nworld;
static char *fail_list;

/* ---- the world ---- */

static void
load_world(void)
{
	const char *f = getenv("FAKE_WORLD");
	char line[1024];
	FILE *in;

	if (f == NULL || (in = fopen(f, "r")) == NULL) {
		return;
	}
	while (fgets(line, sizeof(line), in) && nworld < 4096) {
		line[strcspn(line, "\n")] = 0;
		if (line[0] == '/') {
			world[nworld++] = strdup(line);
		}
	}
	fclose(in);
}

/* 0 none, 1 file, 2 directory */
static int
in_world(const char *path)
{
	size_t n = strlen(path);

	if (strcmp(path, "/") == 0) {
		return 2;
	}
	while (n > 1 && path[n - 1] == '/') {
		n--;
	}
	for (int i = 0; i < nworld; i++) {
		size_t w = strlen(world[i]);

		if (strncmp(world[i], path, n) == 0) {
			if (w == n) {
				return 1;
			}
			if (world[i][n] == '/') {
				return 2;
			}
		}
	}
	return 0;
}

/* the PC's file for a mapped PATH, or NULL */
static const char *
mapped(const char *path)
{
	static char out[2048];
	const char *map = getenv("FAKE_MAP");
	size_t best = 0;

	out[0] = 0;
	while (map != NULL && *map) {
		const char *eq = strchr(map, '='), *end = strchr(map, ':');
		size_t pl, dl;

		if (eq == NULL) {
			break;
		}
		if (end == NULL) {
			end = map + strlen(map);
		}
		pl = (size_t)(eq - map);
		dl = (size_t)(end - eq - 1);
		if (pl > best && strncmp(path, map, pl) == 0 && (path[pl] == 0 || path[pl] == '/')) {
			best = pl;
			snprintf(out, sizeof(out), "%.*s%s", (int)dl, eq + 1, path + pl);
		}
		map = *end ? end + 1 : end;
	}
	return best ? out : NULL;
}

static int
fails(const char *call, const char *path)
{
	char key[1200];

	if (fail_list == NULL) {
		return 0;
	}
	snprintf(key, sizeof(key), ",%s:%s,", call, path);
	return strstr(fail_list, key) != NULL;
}

#define LOG(...) do { printf("@ " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

/* ---- descriptors ---- */

enum { FD_NONE, FD_REAL, FD_NULLREAD, FD_SINK, FD_DIR };
static struct {
	int kind, real;
	char path[1024];
	char **names;
	int nnames, pos;
} fds[256];

static int
new_fd(int kind)
{
	for (int i = 10; i < 256; i++) {
		if (fds[i].kind == FD_NONE) {
			memset(&fds[i], 0, sizeof(fds[i]));
			fds[i].kind = kind;
			return i;
		}
	}
	return -1;
}

static void
dir_add(int fd, const char *name)
{
	for (int i = 0; i < fds[fd].nnames; i++) {
		if (strcmp(fds[fd].names[i], name) == 0) {
			return;
		}
	}
	fds[fd].names = realloc(fds[fd].names, sizeof(char *) * (fds[fd].nnames + 1));
	fds[fd].names[fds[fd].nnames++] = strdup(name);
}

int
fake_open(const char *path, int flags, int mode)
{
	const char *real = mapped(path);
	int fd;

	if (flags & (M_O_WRONLY | M_O_RDWR | M_O_CREAT)) {
		if (strcmp(path, "/dev/console") == 0 || strcmp(path, "/dev/null") == 0) {
			return new_fd(FD_SINK);
		}
		if (fails("open", path)) {
			fake_errno = ENOENT;
			return -1;
		}
		LOG("open %s create mode %o", path, mode);
		return new_fd(FD_SINK);
	}
	if (fails("open", path)) {
		fake_errno = ENOENT;
		return -1;
	}
	if (flags & M_O_DIRECTORY) {
		struct stat st;

		if (real != NULL && stat(real, &st) == 0 && S_ISDIR(st.st_mode)) {
			DIR *d = opendir(real);
			struct dirent *e;

			fd = new_fd(FD_DIR);
			while (d != NULL && (e = readdir(d)) != NULL) {
				if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) {
					dir_add(fd, e->d_name);
				}
			}
			if (d) {
				closedir(d);
			}
			return fd;
		}
		if (in_world(path) != 2) {
			fake_errno = ENOENT;
			return -1;
		}
		fd = new_fd(FD_DIR);
		snprintf(fds[fd].path, sizeof(fds[fd].path), "%s", path);
		for (int i = 0; i < nworld; i++) {
			size_t n = strlen(path);

			if (strncmp(world[i], path, n) == 0 && world[i][n] == '/' && world[i][n + 1]) {
				char name[1024];

				snprintf(name, sizeof(name), "%s", world[i] + n + 1);
				name[strcspn(name, "/")] = 0;
				dir_add(fd, name);
			}
		}
		return fd;
	}
	if (real != NULL) {
		int r = open(real, O_RDONLY);

		if (r >= 0) {
			fd = new_fd(FD_REAL);
			fds[fd].real = r;
			return fd;
		}
	}
	if (in_world(path) == 1 || strncmp(path, "/dev/", 5) == 0) {
		return new_fd(FD_NULLREAD);
	}
	fake_errno = ENOENT;
	return -1;
}

long
fake_read(int fd, void *buf, unsigned long n)
{
	if (fd >= 0 && fd < 256 && fds[fd].kind == FD_REAL) {
		return read(fds[fd].real, buf, n);
	}
	return 0;
}

long
fake_write(int fd, const void *buf, unsigned long n)
{
	if (fd == 1 || fd == 2) {
		fwrite(buf, 1, n, stdout);
		fflush(stdout);
	}
	return (long)n;
}

int
fake_close(int fd)
{
	if (fd >= 10 && fd < 256) {
		if (fds[fd].kind == FD_REAL) {
			close(fds[fd].real);
		}
		for (int i = 0; i < fds[fd].nnames; i++) {
			free(fds[fd].names[i]);
		}
		free(fds[fd].names);
		fds[fd].kind = FD_NONE;
	}
	return 0;
}

long long
fake_lseek(int fd, long long off, int whence)
{
	if (fd >= 0 && fd < 256 && fds[fd].kind == FD_REAL) {
		return lseek(fds[fd].real, off, whence);
	}
	if (fd >= 0 && fd < 256 && fds[fd].kind == FD_DIR) {
		fds[fd].pos = 0;
	}
	return 0;
}

long
fake_getdirentries(int fd, void *buf, unsigned long size, long long *position)
{
	unsigned long at = 0;

	if (fd < 0 || fd >= 256 || fds[fd].kind != FD_DIR) {
		fake_errno = 9;
		return -1;
	}
	if (*position == 0) {
		fds[fd].pos = 0;
	}
	while (fds[fd].pos < fds[fd].nnames) {
		const char *name = fds[fd].names[fds[fd].pos];
		size_t len = strlen(name), rec = (offsetof(struct fake_dirent, d_name) + len + 1 + 7) & ~7UL;
		struct fake_dirent *d = (struct fake_dirent *)((char *)buf + at);
		char full[2048];

		if (at + rec > size) {
			break;
		}
		memset(d, 0, rec);
		d->d_reclen = (uint16_t)rec;
		d->d_namlen = (uint16_t)len;
		snprintf(full, sizeof(full), "%s/%s", fds[fd].path, name);
		d->d_type = in_world(full) == 2 ? 4 : 8;
		memcpy(d->d_name, name, len + 1);
		at += rec;
		fds[fd].pos++;
	}
	*position = fds[fd].pos;
	return (long)at;
}

static int
fill_stat(const char *path, struct fake_stat *st, int follow)
{
	const char *real = mapped(path);
	struct stat s;
	int w;

	memset(st, 0, sizeof(*st));
	if (fails("stat", path)) {
		fake_errno = ENOENT;
		return -1;
	}
	if (real != NULL && (follow ? stat(real, &s) : lstat(real, &s)) == 0) {
		st->st_mode = (uint16_t)s.st_mode;
		st->st_size = s.st_size;
		st->st_nlink = 1;
		return 0;
	}
	w = in_world(path);
	if (w == 0) {
		fake_errno = ENOENT;
		return -1;
	}
	st->st_mode = w == 2 ? M_IFDIR | 0755 : M_IFREG | 0644;
	st->st_nlink = 1;
	return 0;
}

int fake_stat(const char *path, struct fake_stat *st) { return fill_stat(path, st, 1); }
int fake_lstat(const char *path, struct fake_stat *st) { return fill_stat(path, st, 0); }

int
fake_fstat(int fd, struct fake_stat *st)
{
	struct stat s;

	memset(st, 0, sizeof(*st));
	if (fd >= 0 && fd < 256 && fds[fd].kind == FD_REAL && fstat(fds[fd].real, &s) == 0) {
		st->st_mode = (uint16_t)s.st_mode;
		st->st_size = s.st_size;
		return 0;
	}
	st->st_mode = M_IFREG | 0644;
	return 0;
}

/* ---- calls that change the system: printed ---- */

static int
logged(const char *call, const char *path)
{
	if (fails(call, path)) {
		fake_errno = ENOENT;
		return -1;
	}
	return 0;
}

int fake_mkdir(const char *p, int mode) { LOG("mkdir %s %o", p, mode); return logged("mkdir", p); }
int fake_rmdir(const char *p) { LOG("rmdir %s", p); return logged("rmdir", p); }
int fake_unlink(const char *p) { LOG("unlink %s", p); return in_world(p) == 1 ? logged("unlink", p) : (fake_errno = ENOENT, -1); }
int fake_rename(const char *a, const char *b) { LOG("rename %s %s", a, b); return logged("rename", a); }
int fake_link(const char *a, const char *b) { LOG("link %s %s", a, b); return 0; }
int fake_symlink(const char *a, const char *b) { LOG("symlink %s %s", a, b); return logged("symlink", b); }
int fake_chmod(const char *p, int mode) { LOG("chmod %s %o", p, mode); return logged("chmod", p); }
int fake_chown(const char *p, int u, int g) { LOG("chown %s %d %d", p, u, g); return logged("chown", p); }
int fake_lchown(const char *p, int u, int g) { LOG("lchown %s %d %d", p, u, g); return 0; }
int fake_chflags(const char *p, int f) { LOG("chflags %s %x", p, f); return 0; }
int fake_unmount(const char *p, int f) { LOG("unmount %s %d", p, f); return logged("unmount", p); }
void fake_sync(void) { LOG("sync"); }
int fake_fsync(int fd) { (void)fd; return 0; }

int
fake_chdir(const char *p)
{
	LOG("chdir %s", p);
	if (strcmp(p, ".") == 0 || in_world(p) == 2) {
		return logged("chdir", p);
	}
	fake_errno = ENOENT;
	return -1;
}

int
fake_mount(const char *type, const char *dir, int flags, void *data)
{
	const char *what = "-";

	if (data != NULL) {
		what = strcmp(type, "hfs") == 0 ? *(const char **)data : (const char *)data;
	}
	LOG("mount %s %s on %s %s%s", type, what, dir, flags & 1 ? "ro" : "rw", flags & 0x20 ? ",union" : "");
	return logged("mount", dir);
}

int
fake_sysctlbyname(const char *name, void *old, unsigned long *oldlen, const void *new, unsigned long newlen)
{
	if (new != NULL) {
		char text[4200];
		int printable = 1;
		unsigned long n = newlen;

		while (n > 0 && ((const char *)new)[n - 1] == 0) {
			n--;
		}
		for (unsigned long i = 0; i < n; i++) {
			printable = printable && ((const unsigned char *)new)[i] >= 32 && ((const unsigned char *)new)[i] < 127;
		}
		if (printable && n < sizeof(text)) {
			memcpy(text, new, n);
			text[n] = 0;
			LOG("sysctl %s = \"%s\"", name, text);
		} else if (newlen == 4) {
			LOG("sysctl %s = %d", name, *(const int *)new);
		} else {
			LOG("sysctl %s = (%lu bytes)", name, newlen);
		}
		return logged("sysctl", name);
	}
	if (old != NULL && oldlen != NULL) {
		const char *s = NULL;

		if (strcmp(name, "kern.bootargs") == 0) {
			s = getenv("FAKE_BOOTARGS") ? getenv("FAKE_BOOTARGS") : "";
		} else if (strcmp(name, "kern.ostype") == 0) {
			s = "Darwin";
		} else if (strcmp(name, "kern.osrelease") == 0) {
			s = "25.6.0";
		} else if (strcmp(name, "kern.version") == 0) {
			s = "(the host test)";
		} else if (strcmp(name, "hw.machine") == 0) {
			s = "iPhone14,4";
		} else if (strcmp(name, "hw.memsize") == 0 && *oldlen >= 8) {
			*(unsigned long long *)old = 8ULL << 30;
			*oldlen = 8;
			return 0;
		} else if ((strcmp(name, "hw.ncpu") == 0 || strcmp(name, "hw.pagesize") == 0) && *oldlen >= 4) {
			*(int *)old = strcmp(name, "hw.ncpu") == 0 ? 9 : 16384;
			*oldlen = 4;
			return 0;
		}
		if (s != NULL) {
			size_t n = strlen(s) + 1 < *oldlen ? strlen(s) + 1 : *oldlen;

			memcpy(old, s, n);
			*oldlen = n;
			return 0;
		}
	}
	fake_errno = ENOENT;
	return -1;
}

static int children = 100;

int fake_fork(void) { LOG("fork"); return children++; }
int fake_pipe(int f[2]) { f[0] = new_fd(FD_NULLREAD); f[1] = new_fd(FD_SINK); return 0; }

int
fake_wait4(int pid, int *status, int options, void *ru)
{
	(void)options, (void)ru;
	LOG("wait4 %d", pid);
	if (status) {
		*status = 0;
	}
	return pid;
}

int
fake_execve(const char *path, char *const argv[], char *const envp[])
{
	printf("@ execve %s", path);
	for (int i = 1; argv && argv[i]; i++) {
		printf(" %s", argv[i]);
	}
	for (int i = 0; envp && envp[i]; i++) {
		printf(" [%s]", envp[i]);
	}
	printf("\n");
	fflush(stdout);
	if (fails("execve", path)) {
		fake_errno = ENOENT;
		return -1;
	}
	exit(0);
}

int fake_reboot(int how) { LOG("reboot %d", how); exit(3); }
long fake_mini_syscall(long n, long a, long b, long c, long d, long e, long f)
{
	(void)c, (void)d, (void)e, (void)f;
	LOG("syscall %ld %ld %ld", n, a, b);
	return 0;
}
void fake__exit(int s) { LOG("_exit %d", s); exit(s); }
int fake_dup2(int a, int b) { (void)a; return b; }
int fake_getpid(void) { return getenv("FAKE_PID") ? atoi(getenv("FAKE_PID")) : 1; }
int fake_getppid(void) { return 0; }
int fake_getuid(void) { return 0; }
long fake_readlink(const char *p, char *b, unsigned long n) { (void)p, (void)b, (void)n; fake_errno = ENOENT; return -1; }
void *fake_mmap(void *a, unsigned long l, int p, int f, int fd, long long o) { (void)a, (void)l, (void)p, (void)f, (void)fd, (void)o; return (void *)-1; }
int fake_munmap(void *a, unsigned long l) { (void)a, (void)l; return 0; }
int fake_gettimeofday(struct fake_timeval *tv, void *tz) { struct timeval t; (void)tz; gettimeofday(&t, NULL); tv->tv_sec = t.tv_sec; tv->tv_usec = (int)t.tv_usec; return 0; }
int fake_usleep(unsigned us) { (void)us; return 0; }
int fake_utimes(const char *p, const struct fake_timeval t[2]) { (void)p, (void)t; return 0; }
long fake_listxattr(const char *p, char *n, unsigned long s, int o) { (void)p, (void)n, (void)s, (void)o; return 0; }
long fake_getxattr(const char *p, const char *n, void *v, unsigned long s, uint32_t pos, int o) { (void)p, (void)n, (void)v, (void)s, (void)pos, (void)o; return -1; }
int fake_setxattr(const char *p, const char *n, const void *v, unsigned long s, uint32_t pos, int o) { (void)p, (void)n, (void)v, (void)s, (void)pos, (void)o; return 0; }
int fake_ftruncate(int fd, long long l) { (void)fd, (void)l; return -1; }
long fake_pread(int fd, void *b, unsigned long n, long long o) { (void)fd, (void)b, (void)n, (void)o; return -1; }
long fake_pwrite(int fd, const void *b, unsigned long n, long long o) { (void)fd, (void)b, (void)n, (void)o; return -1; }
int fake_socket(int d, int t, int p) { (void)d, (void)t, (void)p; return -1; }
int fake_bind(int fd, const void *a, unsigned l) { (void)fd, (void)a, (void)l; return -1; }

/* ---- the C library part ---- */

unsigned long fake_strlen(const char *s) { return strlen(s); }
int fake_strcmp(const char *a, const char *b) { return strcmp(a, b); }
int fake_strncmp(const char *a, const char *b, unsigned long n) { return strncmp(a, b, n); }
char *fake_strcpy(char *d, const char *s) { return strcpy(d, s); }
char *fake_strchr(const char *s, int c) { return strchr(s, c); }
void *fake_memcpy(void *d, const void *s, unsigned long n) { return memmove(d, s, n); }
void *fake_memset(void *d, int c, unsigned long n) { return memset(d, c, n); }
int fake_memcmp(const void *a, const void *b, unsigned long n) { return memcmp(a, b, n); }
const char *fake_strerror(int e) { return strerror(e); }
int fake_vdprintf(int fd, const char *f, va_list ap) { (void)fd; int r = vprintf(f, ap); fflush(stdout); return r; }
int fake_dprintf(int fd, const char *f, ...) { va_list ap; va_start(ap, f); int r = fake_vdprintf(fd, f, ap); va_end(ap); return r; }
int fake_printf(const char *f, ...) { va_list ap; va_start(ap, f); int r = vprintf(f, ap); va_end(ap); fflush(stdout); return r; }
int fake_puts(const char *s) { return puts(s); }

int
main(int argc, char **argv, char **envp)
{
	char *f = getenv("FAKE_FAIL");

	if (f != NULL) {
		fail_list = malloc(strlen(f) + 3);
		sprintf(fail_list, ",%s,", f);
	}
	load_world();
	fake_environ = envp;
	return fake_main(argc, argv, envp);
}
