/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * akinit: AkIOS's process 1 until Apple's launchd takes over (main.c). What its plan's steps do is spread over one
 * file a job; this header joins them.
 */
#ifndef AKINIT_H
#define AKINIT_H

#include "mini.h"
#include "plan.h"

#ifndef EEXIST
#define EEXIST          17
#endif
#ifndef EINVAL
#define EINVAL          22
#endif
#ifndef ENOENT
#define ENOENT          2
#endif
#define WNOHANG         1
#define RB_AUTOBOOT     0x00
#define RB_HALT         0x08

/* fsutil.c: files and trees */
int     path_join(char *out, size_t size, const char *a, const char *b, const char *c);
int     contains(const char *hay, const char *needle);
long    parse_number(const char *text, int radix);
ssize_t read_whole(const char *path, char *buf, size_t size);
void    make_path(const char *path, int mode);
int     copy_file(const char *from, const char *to, int mode, int uid, int gid);
int     copy_whole_tree(const char *from, const char *to, int depth, unsigned *files);
int     copy_missing_tree(const char *from, const char *to, int depth, unsigned *files, const char *skip_top);
void    empty_tree(const char *path, int depth);
int     remove_matching(const char *pattern, unsigned *removed);
int     mount_hfs(const char *dev, const char *at);

/* the steps: OP(name, least words, most words (-1: any), function) */
#define AKINIT_OPS(OP) \
	OP("say",         0, -1, op_say)          /* say WORD...: a line on the console */ \
	OP("sysinfo",     0,  0, op_sysinfo)      /* the kernel, the machine, its memory */ \
	OP("mount",       3,  4, op_mount)        /* mount TYPE DEV DIR [ro|rw]: apfs, bindfs, ramfs (DEV "-") */ \
	OP("hfs",         2,  5, op_hfs)          /* hfs DEV DIR [MODE UID GID]: HFS Plus, then DIR's mode and owner */ \
	OP("bind",        2,  2, op_bind)         /* bind FROM TO: bindfs, read only */ \
	OP("union",       2,  2, op_union)        /* union FROM TO: bindfs over TO, what FROM lacks seen below */ \
	OP("synthetic",   1,  1, op_synthetic)    /* synthetic PATH: an empty directory the volume lacks */ \
	OP("aliases",     3,  3, op_aliases)      /* aliases DIR INTO SUFFIX: INTO/NAME, another name of DIR/NAME */ \
	OP("switchroot",  2,  2, op_switchroot)   /* switchroot NEWROOT OLDROOT-DEST */ \
	OP("chdir",       1,  2, op_chdir)        /* chdir DIR [FLAG]: FLAG set when it worked */ \
	OP("mkdir",       2,  4, op_mkdir)        /* mkdir PATH MODE [UID GID]: there already is fine */ \
	OP("mkdirp",      2,  2, op_mkdirp)       /* mkdirp PATH MODE */ \
	OP("chmod",       2,  2, op_chmod)        /* chmod PATH MODE */ \
	OP("chown",       3,  3, op_chown)        /* chown PATH UID GID */ \
	OP("empty",       1,  1, op_empty)        /* empty DIR: what is in it goes, DIR stays */ \
	OP("rm",          1, -1, op_rm)           /* rm PATTERN...: files ("*" in a name matches any part) */ \
	OP("touch",       4,  4, op_touch)        /* touch PATH MODE UID GID */ \
	OP("sync",        0,  0, op_sync) \
	OP("flag",        1,  1, op_flag)         /* flag NAME: for "if flag:NAME" */ \
	OP("keepcopy",    2,  2, op_keepcopy)     /* keepcopy SRC DST: copied when DST is missing or of another size */ \
	OP("seedvar",     2,  2, op_seedvar)      /* seedvar DEV AT: the system's /private/var template onto the volume */ \
	OP("stagedapps",  2,  2, op_stagedapps)   /* stagedapps DIR DONE: the staged applications onto the volume */ \
	OP("skel",        2,  2, op_skel)         /* skel FILE BASE: the data volume's skeleton list */ \
	OP("gestalt",     2,  2, op_gestalt)      /* gestalt NOTE CACHE: MobileGestalt's cache, gone when the tree changed */ \
	OP("bootlog",     3,  3, op_bootlog)      /* bootlog DIR SOURCE COUNT: the console kept on the data volume */ \
	OP("run",         1, -1, op_run)          /* run [timeout=S] [out=FILE] PROG ARG...: a program, waited for */ \
	OP("grep",        2, -1, op_grep)         /* grep FILE PATTERN...: its lines with a pattern ("a+b": both) */ \
	OP("inject",      1,  1, op_inject)       /* inject FILE: "LIBRARY NAME..." lines for kern.exec_inject */ \
	OP("inject-line", 2, -1, op_inject_line)  /* inject-line LIBRARY NAME...: one more */ \
	OP("inject-apply", 0, 0, op_inject_apply) /* hand them to the kernel */ \
	OP("vnodes",      1,  1, op_vnodes)       /* vnodes MAX: kern.maxvnodes from the memory, at most MAX */ \
	OP("stderr",      1,  1, op_stderr)       /* stderr PATH: standard error from now on (for what exec starts) */ \
	OP("env",         1,  1, op_env)          /* env NAME=VALUE: the environment exec gives */ \
	OP("exec",        1, -1, op_exec)         /* exec PROG ARG...: process 1 becomes PROG */ \
	OP("halt",        0,  0, op_halt)         /* halt: power off (akita: needs a hand to start again) */ \
	OP("reboot",      0,  1, op_reboot)       /* reboot [SECONDS]: restart after SECONDS (10), RAM and pstore kept */

#define AKINIT_DECLARE(name, lo, hi, fn) int fn(int argc, char **argv);
AKINIT_OPS(AKINIT_DECLARE)

#endif
