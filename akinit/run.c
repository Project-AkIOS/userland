/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * "run [timeout=S] [out=FILE] PROG ARG...": a program started and waited for -- at most S seconds, then killed, and
 * the boot goes on -- its output into FILE. "grep FILE PATTERN...": FILE's lines with one of the patterns in them
 * ("a+b": both a and b), on the console.
 *
 * iOS's usermanagerd boot task runs this way (the plan): launchd runs it before any daemon on an iPhone and skips it
 * on this boot (rd=md0); it writes the persona manifest and registers the personas with the kernel, which forgets
 * them at every start, and whoever asks for one before that fails (installd, then LaunchServices without the system's
 * applications, then SpringBoard's "Got nil for _systemAppInfo").
 */
#include "akinit.h"

#define SIGKILL 9

int
op_run(int argc, char **argv)
{
	static char *args[PLAN_MAX_WORDS];
	char *envp[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL };
	const char *out = NULL;
	long timeout = 0;
	int i = 1, status = 0, n = 0;
	pid_t pid;

	for (; i < argc; i++) {
		if (strncmp(argv[i], "timeout=", 8) == 0) {
			timeout = parse_number(argv[i] + 8, 10);
		} else if (strncmp(argv[i], "out=", 4) == 0) {
			out = argv[i] + 4;
		} else {
			break;
		}
	}
	if (i == argc) {
		return EINVAL;
	}
	for (; i < argc; i++) {
		args[n++] = argv[i];
	}
	args[n] = NULL;
	pid = fork();
	if (pid == 0) {
		if (out != NULL) {
			int fd = open(out, O_WRONLY | O_CREAT | O_TRUNC, 0644);

			if (fd >= 0) {
				dup2(fd, 1);
				dup2(fd, 2);
			}
		}
		execve(args[0], args, envp);
		_exit(127);
	}
	if (pid < 0) {
		return errno;
	}
	for (long t = 0; timeout == 0 || t < timeout * 10; t++) {     /* 100 ms a turn */
		if (wait4(pid, &status, timeout ? WNOHANG : 0, NULL) == pid) {
			printf("  %s: %s %d after about %ld ms\n", args[0], WIFEXITED(status) ? "exit status" : "killed by signal",
			    WIFEXITED(status) ? WEXITSTATUS(status) : WTERMSIG(status), t * 100);
			return WIFEXITED(status) && WEXITSTATUS(status) != 127 ? 0 : ENOENT;
		}
		usleep(100000);
	}
	mini_syscall(SYS_kill, pid, SIGKILL, 1, 0, 0, 0);
	wait4(pid, &status, 0, NULL);
	printf("  %s did not end in %ld s: killed (the boot goes on)\n", args[0], timeout);
	return 0;
}

/* LINE has PATTERN ("a+b": a and b) */
static int
has(const char *line, const char *pattern)
{
	char part[128];

	while (*pattern) {
		const char *plus = strchr(pattern, '+');
		size_t n = plus ? (size_t)(plus - pattern) : strlen(pattern);

		if (n >= sizeof(part)) {
			return 0;
		}
		memcpy(part, pattern, n);
		part[n] = 0;
		if (!contains(line, part)) {
			return 0;
		}
		pattern += n + (plus != NULL);
	}
	return 1;
}

int
op_grep(int argc, char **argv)
{
	static char text[65536];
	ssize_t n = read_whole(argv[1], text, sizeof(text));

	if (n < 0) {
		return errno;
	}
	for (char *line = text; line < text + n;) {
		char *end = line;

		while (end < text + n && *end != '\n') {
			end++;
		}
		*end = 0;
		for (int i = 2; i < argc; i++) {
			if (has(line, argv[i])) {
				printf("  %s\n", line);
				break;
			}
		}
		line = end + 1;
	}
	return 0;
}
