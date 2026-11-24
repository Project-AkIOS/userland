/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * The boot plan's parser and runner (plan.h has the format). Only string work here: what a step does is in the
 * table it is given, so the same file runs on the phone and in the host test.
 */
#include "mini.h"
#include "plan.h"

#define MAX_FLAGS       32

static char flags[MAX_FLAGS][32];
static int nflags;

int
flag_is(const char *name)
{
	for (int i = 0; i < nflags; i++) {
		if (strcmp(flags[i], name) == 0) {
			return 1;
		}
	}
	return 0;
}

void
flag_set(const char *name)
{
	if (flag_is(name) || nflags == MAX_FLAGS || strlen(name) >= sizeof(flags[0])) {
		return;
	}
	strcpy(flags[nflags++], name);
}

/* split LINE into words at blanks; returns the count (more than PLAN_MAX_WORDS: -1) */
static int
split(char *line, char **words)
{
	int n = 0;

	for (char *p = line; *p;) {
		while (*p == ' ' || *p == '\t' || *p == '\r') {
			*p++ = 0;
		}
		if (*p == 0) {
			break;
		}
		if (n == PLAN_MAX_WORDS) {
			return -1;
		}
		words[n++] = p;
		while (*p && *p != ' ' && *p != '\t' && *p != '\r') {
			p++;
		}
	}
	return n;
}

static int
starts(const char *s, const char *prefix)
{
	return strncmp(s, prefix, strlen(prefix)) == 0;
}

/* 1 true, 0 false, -1 not a condition */
static int
condition(const char *c, int check)
{
	int neg = 0, r;

	if (*c == '!') {
		neg = 1;
		c++;
	}
	if (starts(c, "bootarg:") && c[8] != 0) {
		const char *name = c + 8, *eq = strchr(name, '=');
		char key[64];
		const char *v;
		size_t n = eq ? (size_t)(eq - name) : strlen(name);

		if (n == 0 || n >= sizeof(key)) {
			return -1;
		}
		if (check) {
			return 1;
		}
		memcpy(key, name, n);
		key[n] = 0;
		v = bootarg(key);
		r = v != NULL && (eq == NULL || strcmp(v, eq + 1) == 0);
	} else if (starts(c, "exists:") && c[7] == '/') {
		r = check ? 1 : path_exists(c + 7);
	} else if (starts(c, "flag:") && c[5] != 0) {
		r = check ? 1 : flag_is(c + 5);
	} else {
		return -1;
	}
	return neg ? !r : r;
}

/*
 * The words of a step with $NAME and ${NAME} replaced by boot-arg values, into BUF. 0, or the name of the first
 * boot-arg that is not there (copied into MISSING), or -1 when it does not fit.
 */
static int
expand(int argc, char **argv, char **out, char *buf, size_t size, char *missing, size_t msize)
{
	size_t at = 0;

	for (int i = 0; i < argc; i++) {
		out[i] = buf + at;
		for (const char *p = argv[i]; *p;) {
			if (*p == '$' && (p[1] == '{' || (p[1] >= 'a' && p[1] <= 'z') || (p[1] >= 'A' && p[1] <= 'Z') || p[1] == '_')) {
				char name[64];
				size_t n = 0;
				int brace = p[1] == '{';
				const char *v;

				p += brace ? 2 : 1;
				while (*p && n < sizeof(name) - 1 && ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
				    (*p >= '0' && *p <= '9') || *p == '_')) {
					name[n++] = *p++;
				}
				name[n] = 0;
				if (brace) {
					if (*p != '}') {
						return -1;
					}
					p++;
				}
				v = bootarg(name);
				if (v == NULL) {
					if (strlen(name) < msize) {
						strcpy(missing, name);
					}
					return 1;
				}
				if (at + strlen(v) >= size) {
					return -1;
				}
				strcpy(buf + at, v);
				at += strlen(v);
			} else {
				if (at + 1 >= size) {
					return -1;
				}
				buf[at++] = *p++;
			}
		}
		if (at + 1 >= size) {
			return -1;
		}
		buf[at++] = 0;
	}
	return 0;
}

static void
show(const char *tag, int argc, char **argv)
{
	printf("[%s]", tag);
	for (int i = 0; i < argc; i++) {
		printf(" %s", argv[i]);
	}
}

int
plan_run(char *text, const struct plan_op *ops, int check)
{
	static char buf[4096];
	char *words[PLAN_MAX_WORDS], *expanded[PLAN_MAX_WORDS];
	char section[64] = "";
	int lineno = 0, errors = 0, in_section = 0, skipping = 0;

	for (char *line = text; line != NULL && *line;) {
		char *end = strchr(line, '\n');
		int n, w = 0, active = 1, must = 0, bad = 0;
		const struct plan_op *op = NULL;

		if (end) {
			*end = 0;
		}
		lineno++;
		n = *line == '#' ? 0 : split(line, words);
		line = end ? end + 1 : NULL;
		if (n == 0) {
			continue;
		}
		if (n < 0) {
			printf("akinit: plan line %d: more than %d words\n", lineno, PLAN_MAX_WORDS);
			errors++;
			continue;
		}

		if (strcmp(words[0], "section") == 0 || strcmp(words[0], "end") == 0) {
			int opening = words[0][0] == 's';

			if (opening != !in_section || (opening && (n < 2 || strlen(words[1]) >= sizeof(section))) ||
			    (!opening && n != 1)) {
				printf("akinit: plan line %d: %s out of place\n", lineno, words[0]);
				errors++;
				continue;
			}
			if (!opening) {
				in_section = 0;
				skipping = 0;
				continue;
			}
			in_section = 1;
			strcpy(section, words[1]);
			for (w = 2; w < n; w += 2) {
				int c = strcmp(words[w], "if") == 0 && w + 1 < n ? condition(words[w + 1], check) : -1;

				if (c < 0) {
					printf("akinit: plan line %d: a section takes \"if COND\" only\n", lineno);
					errors++;
					break;
				}
				active = active && c;
			}
			skipping = !active;
			if (!check) {
				printf("\n-- %s%s --\n", section, active ? "" : " (its conditions do not hold: left out)");
			}
			continue;
		}

		/* if COND ... must OP ARG ... */
		while (w + 1 < n && strcmp(words[w], "if") == 0) {
			int c = condition(words[w + 1], check);

			if (c < 0) {
				printf("akinit: plan line %d: bad condition %s\n", lineno, words[w + 1]);
				bad = 1;
			}
			active = active && c > 0;
			w += 2;
		}
		if (w < n && strcmp(words[w], "must") == 0) {
			must = 1;
			w++;
		}
		if (w < n) {
			for (op = ops; op->name != NULL && strcmp(op->name, words[w]) != 0; op++) {
			}
			if (op->name == NULL) {
				printf("akinit: plan line %d: no step %s\n", lineno, words[w]);
				op = NULL;
				bad = 1;
			} else if (n - w - 1 < op->min_args || (op->max_args >= 0 && n - w - 1 > op->max_args)) {
				printf("akinit: plan line %d: %s takes %d to %d words, not %d\n", lineno, op->name, op->min_args,
				    op->max_args, n - w - 1);
				bad = 1;
			}
		} else {
			printf("akinit: plan line %d: no step after the conditions\n", lineno);
			bad = 1;
		}
		if (bad) {
			errors++;
			continue;
		}
		if (check || skipping || !active) {
			continue;
		}

		{
			char missing[64] = "";
			int argc = n - w, r = expand(argc, words + w, expanded, buf, sizeof(buf), missing, sizeof(missing));

			if (r != 0) {
				show("skip", argc, words + w);
				printf(r > 0 ? " (no boot-arg %s)\n" : " (too long)\n", missing);
				continue;
			}
			r = op->fn(argc, expanded);
			show(r == 0 ? " ok " : "FAIL", argc, expanded);
			if (r != 0) {
				printf(": %s", strerror(r));
			}
			printf("\n");
			if (r != 0 && must) {
				if (!in_section) {
					printf("akinit: a step the plan needs failed: the rest of the plan is left out\n");
					return -1;
				}
				printf("akinit: the rest of section %s is left out\n", section);
				skipping = 1;
			}
		}
	}
	if (in_section) {
		printf("akinit: plan: section %s has no end\n", section);
		errors++;
	}
	return errors;
}
