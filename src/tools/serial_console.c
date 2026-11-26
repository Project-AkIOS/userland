/*
 * AkIOS (11-22): serial_console -- a command line on the USB serial console (job com.hakios.serial, root).
 *
 * The kernel's /dev/hakios-serial is the phone's end of the host's /dev/ttyACM0 (the CDC-ACM function of the USB device,
 * drivers/usb/hakios.akita_serial.c); the kernel's console log goes out on the same port by itself. Here: a prompt,
 * minimal line editing (echo, backspace, ^U, ^C; CR, LF or CR LF end a line; escape sequences swallowed), the line split
 * into words as init's run_command does (blanks; '...' and "..." keep blanks inside a word), and the program run on a
 * pseudo-terminal whose other end is relayed to the port both ways until it exits; then its status.
 *
 * Built-ins: cd [DIR], reboot, exit / logout (just a new prompt), klog on|off (the kernel log on the port), help, and
 * sh: /var/jb/bin/sh -i on the port (when there is one), its own session with the pty as controlling terminal (^C, job
 * control). ^C while a program runs: SIGINT to its foreground process group (through the pty's line discipline, or by
 * kill() when it has no controlling terminal).
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

#define DEVICE                  "/dev/hakios-serial"
#define HAKIOS_SERIAL_KLOG      _IOW('h', 0x53, int)    /* the kernel's hakios.akita_serial.c has the same */
#define RB_AUTOBOOT             0       /* <sys/reboot.h>, which the iOS SDK leaves out */
#define JB_SH                   "/var/jb/bin/sh"
#define PATH_VALUE              "/akita/bin:/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/bin:/sbin:/usr/bin:/usr/sbin:/usr/libexec"

static int port = -1;

/* bytes to the host as they are */
static void
put_raw(const char *s, size_t n)
{
	while (n > 0) {
		ssize_t w = write(port, s, n);

		if (w < 0) {
			if (errno == EINTR) {
				continue;
			}
			return;
		}
		s += w;
		n -= (size_t)w;
	}
}

/* our own text, "\n" as CR LF */
static void
say(const char *fmt, ...)
{
	char buf[1024], out[2048];
	size_t n = 0;
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	for (const char *p = buf; *p && n < sizeof(out) - 2; p++) {
		if (*p == '\n') {
			out[n++] = '\r';
		}
		out[n++] = *p;
	}
	put_raw(out, n);
}

static void
prompt(void)
{
	char cwd[256];

	if (getcwd(cwd, sizeof(cwd)) == NULL) {
		strcpy(cwd, "?");
	}
	say("akios:%s# ", cwd);
}

static void
banner(void)
{
	say("\nAkIOS serial console (pid %d). Built-ins: cd, reboot, exit, klog on|off, sh, help.\n", getpid());
}

/* words: blanks between them; '...' or "..." keep blanks (the quotes themselves dropped) */
static int
split(char *line, char **argv, int max)
{
	int argc = 0;
	char *p = line, *o;

	while (*p && argc < max - 1) {
		while (*p == ' ' || *p == '\t') {
			p++;
		}
		if (!*p) {
			break;
		}
		argv[argc++] = o = p;
		while (*p && *p != ' ' && *p != '\t') {
			if (*p == '\'' || *p == '"') {
				char q = *p++;

				while (*p && *p != q) {
					*o++ = *p++;
				}
				if (*p) {
					p++;
				}
			} else {
				*o++ = *p++;
			}
		}
		if (*p) {
			p++;
		}
		*o = 0;
	}
	argv[argc] = NULL;
	return argc;
}

/*
 * One program on a pseudo-terminal (pipes when there is none), relayed to the port until it exits. Its own session,
 * the pty its controlling terminal: ^C goes to it as a terminal's would.
 */
static void
run(char **argv)
{
	struct winsize ws = { .ws_row = 24, .ws_col = 80 };
	int master = -1, slave = -1, out_pipe[2] = { -1, -1 }, in_pipe[2] = { -1, -1 }, status = 0;
	int to_child, from_child;
	bool use_pty, exited = false, eof = false, ctty;
	pid_t pid;

	use_pty = openpty(&master, &slave, NULL, NULL, &ws) == 0;
	if (!use_pty && (pipe(out_pipe) != 0 || pipe(in_pipe) != 0)) {
		say("serial_console: no pty and no pipe: %s\n", strerror(errno));
		return;
	}
	pid = fork();
	if (pid < 0) {
		say("serial_console: fork: %s\n", strerror(errno));
		goto done;
	}
	if (pid == 0) {
		int in = use_pty ? slave : in_pipe[0], out = use_pty ? slave : out_pipe[1];

		setsid();
		if (use_pty) {
			(void)ioctl(slave, TIOCSCTTY, 0);
		}
		dup2(in, 0);
		dup2(out, 1);
		dup2(out, 2);
		for (int fd = 3; fd < 256; fd++) {
			close(fd);
		}
		signal(SIGINT, SIG_DFL);
		signal(SIGPIPE, SIG_DFL);
		execvp(argv[0], argv);
		dprintf(2, "%s: %s\n", argv[0], strerror(errno));
		_exit(127);
	}
	if (use_pty) {
		close(slave);
		slave = -1;
		to_child = from_child = master;
	} else {
		close(out_pipe[1]);
		close(in_pipe[0]);
		out_pipe[1] = in_pipe[0] = -1;
		to_child = in_pipe[1];
		from_child = out_pipe[0];
	}
	ctty = false;
	while (!exited || !eof) {
		struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };
		fd_set rd;
		int nfds;

		if (!exited) {
			pid_t w = waitpid(pid, &status, WNOHANG);

			if (w == pid) {
				exited = true;
				tv.tv_usec = 50000;     /* what it left: a last look, briefly */
			}
		}
		if (!ctty && use_pty && tcgetpgrp(master) == pid) {
			ctty = true;
		}
		FD_ZERO(&rd);
		nfds = 0;
		if (!eof) {
			FD_SET(from_child, &rd);
			nfds = from_child + 1;
		}
		if (!exited) {
			FD_SET(port, &rd);
			if (port + 1 > nfds) {
				nfds = port + 1;
			}
		}
		int r = select(nfds, &rd, NULL, NULL, &tv);

		if (r < 0) {
			if (errno == EINTR) {
				continue;
			}
			break;
		}
		if (r == 0) {
			if (exited) {
				break;          /* (a grandchild may hold the pty: not waited for) */
			}
			continue;
		}
		if (!eof && FD_ISSET(from_child, &rd)) {
			char buf[4096];
			ssize_t n = read(from_child, buf, sizeof(buf));

			if (n <= 0) {
				eof = true;     /* (a pty's master reads EIO once every slave is closed) */
			} else if (use_pty) {
				put_raw(buf, (size_t)n);
			} else {
				/* pipes: no line discipline to make LF a CR LF */
				for (ssize_t i = 0; i < n; i++) {
					if (buf[i] == '\n') {
						put_raw("\r\n", 2);
					} else {
						put_raw(&buf[i], 1);
					}
				}
			}
		}
		if (!exited && FD_ISSET(port, &rd)) {
			char buf[512];
			ssize_t n = read(port, buf, sizeof(buf));

			for (ssize_t i = 0; i < n; i++) {
				if (buf[i] == 0x03 && !ctty) {
					kill(-pid, SIGINT);     /* no terminal to do it */
					kill(pid, SIGINT);
					say("^C\n");
					continue;
				}
				if (!use_pty) {
					if (buf[i] == '\r') {
						buf[i] = '\n';
					}
					put_raw(&buf[i], 1);    /* (no line discipline to echo) */
				}
				(void)write(to_child, &buf[i], 1);
			}
		}
	}
	if (!exited) {
		waitpid(pid, &status, 0);
	}
	if (WIFEXITED(status)) {
		say("\n[exit %d]\n", WEXITSTATUS(status));
	} else if (WIFSIGNALED(status)) {
		say("\n[signal %d%s]\n", WTERMSIG(status), WCOREDUMP(status) ? ", core" : "");
	}
done:
	for (int *fd = (int[]){ master, slave, out_pipe[0], out_pipe[1], in_pipe[0], in_pipe[1] }, i = 0; i < 6; i++) {
		if (fd[i] >= 0) {
			close(fd[i]);
		}
	}
}

/* built-ins for a system without its own ls and cat (11-26: a plug-in's trace file in /private/var/tmp, read over this
 * port): "ls [DIR]" names, sizes and kinds; "cat FILE..." the bytes, newlines sent as CR LF */
static void
builtin_ls(const char *dir)
{
	DIR *d = opendir(dir);
	struct dirent *e;

	if (d == NULL) {
		say("ls: %s: %s\n", dir, strerror(errno));
		return;
	}
	while ((e = readdir(d)) != NULL) {
		char path[1024];
		struct stat st;

		if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
			continue;
		}
		snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
		if (lstat(path, &st) != 0) {
			say("%s ?\n", e->d_name);
			continue;
		}
		say("%10lld %s%s\n", (long long)st.st_size, e->d_name, S_ISDIR(st.st_mode) ? "/" : S_ISLNK(st.st_mode) ? "@" : "");
	}
	closedir(d);
}

static void
builtin_cat(const char *path)
{
	char buf[512];
	ssize_t n;
	int fd = open(path, O_RDONLY);

	if (fd < 0) {
		say("cat: %s: %s\n", path, strerror(errno));
		return;
	}
	while ((n = read(fd, buf, sizeof(buf) - 1)) > 0) {
		buf[n] = 0;
		for (ssize_t i = 0; i < n; i++) {
			if (buf[i] == 0) buf[i] = '.';
		}
		say("%s", buf);
	}
	close(fd);
}

static void
command(char *line)
{
	char *argv[64];
	int argc = split(line, argv, 64);

	if (argc == 0) {
		return;
	}
	if (strcmp(argv[0], "cd") == 0) {
		const char *dir = argc > 1 ? argv[1] : "/var/root";

		if (chdir(dir) != 0) {
			say("cd: %s: %s\n", dir, strerror(errno));
		}
	} else if (strcmp(argv[0], "reboot") == 0) {
		say("rebooting\n");
		sync();
		reboot(RB_AUTOBOOT);
		say("reboot: %s\n", strerror(errno));
	} else if (strcmp(argv[0], "exit") == 0 || strcmp(argv[0], "logout") == 0) {
		banner();
	} else if (strcmp(argv[0], "klog") == 0 && argc > 1) {
		int on = strcmp(argv[1], "on") == 0;

		if (ioctl(port, HAKIOS_SERIAL_KLOG, &on) != 0) {
			say("klog: %s\n", strerror(errno));
		}
	} else if (strcmp(argv[0], "ls") == 0 && access("/bin/ls", X_OK) != 0) {
		builtin_ls(argc > 1 ? argv[1] : ".");
	} else if (strcmp(argv[0], "cat") == 0 && argc > 1 && access("/bin/cat", X_OK) != 0) {
		for (int i = 1; i < argc; i++) {
			builtin_cat(argv[i]);
		}
	} else if (strcmp(argv[0], "help") == 0) {
		say("cd [DIR]; reboot; exit; klog on|off (the kernel log on this port); sh (%s -i, when there is one);\n"
		    "ls [DIR], cat FILE... (built in where the system has none);\n"
		    "anything else: a program with its arguments ('...' and \"...\" quote), run on a pty; ^C interrupts it.\n",
		    JB_SH);
	} else if (strcmp(argv[0], "sh") == 0 && argc == 1) {
		char *sh_argv[] = { JB_SH, "-i", NULL };

		if (access(JB_SH, X_OK) != 0) {
			say("sh: no %s here\n", JB_SH);
			return;
		}
		run(sh_argv);
	} else {
		run(argv);
	}
}

int
main(void)
{
	char line[1024];
	size_t len = 0;
	int esc = 0;                    /* in an escape sequence: 1 after ESC, 2 after ESC [ */
	bool last_cr = false;

	signal(SIGPIPE, SIG_IGN);
	signal(SIGINT, SIG_IGN);
	setenv("PATH", PATH_VALUE, 1);
	setenv("HOME", "/var/root", 1);
	setenv("TERM", "vt100", 1);
	setenv("USER", "root", 1);
	setenv("SHELL", JB_SH, 1);
	(void)chdir("/var/root");
	/* the node comes a few seconds after the kernel starts USB, only with usbmux=1: waited for, quietly */
	for (unsigned tries = 0; (port = open(DEVICE, O_RDWR)) < 0; tries++) {
		if (tries == 0) {
			fprintf(stderr, "serial_console: %s: %s; waiting for it\n", DEVICE, strerror(errno));
		}
		sleep(tries < 30 ? 2 : 30);
	}
	banner();
	prompt();
	for (;;) {
		char buf[256];
		ssize_t n = read(port, buf, sizeof(buf));

		if (n < 0) {
			if (errno == EINTR || errno == EAGAIN) {
				continue;
			}
			sleep(1);
			continue;
		}
		for (ssize_t i = 0; i < n; i++) {
			unsigned char c = (unsigned char)buf[i];

			if (esc == 1) {
				esc = c == '[' || c == 'O' ? 2 : 0;
				continue;
			}
			if (esc == 2) {
				if (c >= 0x40 && c <= 0x7e) {
					esc = 0;
				}
				continue;
			}
			if (c == '\n' && last_cr) {
				last_cr = false;        /* CR LF: one end of line */
				continue;
			}
			last_cr = c == '\r';
			if (c == '\r' || c == '\n') {
				say("\n");
				line[len] = 0;
				command(line);
				len = 0;
				prompt();
			} else if (c == 0x7f || c == 0x08) {
				if (len > 0) {
					len--;
					put_raw("\b \b", 3);
				}
			} else if (c == 0x03) {
				say("^C\n");
				len = 0;
				prompt();
			} else if (c == 0x15) {
				while (len > 0) {
					len--;
					put_raw("\b \b", 3);
				}
			} else if (c == 0x1b) {
				esc = 1;
			} else if (c >= 0x20 && len < sizeof(line) - 1) {
				line[len++] = (char)c;
				put_raw((const char *)&c, 1);
			}
		}
	}
}
