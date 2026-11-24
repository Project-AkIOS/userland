/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * The host test's libmini: the same declarations as libmini/mini.h, every system call renamed to its fake_ twin in
 * test/fake.c, which prints what the program asked the kernel for instead of doing it (and answers from a made-up
 * world). Code built against this header runs on the PC exactly as it would run on the phone, up to the kernel.
 */
#ifndef AKINIT_TEST_MINI_H
#define AKINIT_TEST_MINI_H

#define errno           fake_errno
#define environ         fake_environ
#define mini_syscall    fake_mini_syscall
#define fork            fake_fork
#define pipe            fake_pipe
#define _exit           fake__exit
#define read            fake_read
#define write           fake_write
#define open            fake_open
#define close           fake_close
#define lseek           fake_lseek
#define dup2            fake_dup2
#define chdir           fake_chdir
#define getpid          fake_getpid
#define getppid         fake_getppid
#define getuid          fake_getuid
#define wait4           fake_wait4
#define execve          fake_execve
#define stat            fake_stat
#define lstat           fake_lstat
#define fstat           fake_fstat
#define readlink        fake_readlink
#define getdirentries   fake_getdirentries
#define mmap            fake_mmap
#define munmap          fake_munmap
#define gettimeofday    fake_gettimeofday
#define usleep          fake_usleep
#define sysctlbyname    fake_sysctlbyname
#define reboot          fake_reboot
#define mount           fake_mount
#define unmount         fake_unmount
#define mkdir           fake_mkdir
#define rmdir           fake_rmdir
#define unlink          fake_unlink
#define rename          fake_rename
#define link            fake_link
#define symlink         fake_symlink
#define chmod           fake_chmod
#define chown           fake_chown
#define lchown          fake_lchown
#define chflags         fake_chflags
#define utimes          fake_utimes
#define listxattr       fake_listxattr
#define getxattr        fake_getxattr
#define setxattr        fake_setxattr
#define ftruncate       fake_ftruncate
#define fsync           fake_fsync
#define sync            fake_sync
#define pread           fake_pread
#define pwrite          fake_pwrite
#define socket          fake_socket
#define bind            fake_bind
#define strlen          fake_strlen
#define strcmp          fake_strcmp
#define strncmp         fake_strncmp
#define strcpy          fake_strcpy
#define strchr          fake_strchr
#define memcpy          fake_memcpy
#define memset          fake_memset
#define memcmp          fake_memcmp
#define strerror        fake_strerror
#define printf          fake_printf
#define dprintf         fake_dprintf
#define vdprintf        fake_vdprintf
#define puts            fake_puts
#define main            fake_main

/* (the struct is renamed too: the program and fake.c must agree on libmini's layout, not the PC's) */
#define stat            fake_stat
#define timeval         fake_timeval
#define timespec        fake_timespec
#define dirent          fake_dirent

#include "../libmini/mini.h"

#endif
