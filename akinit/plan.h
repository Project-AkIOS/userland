/*
 * SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 * akinit's boot plan: the file /etc/akios/boot.plan that `ak userland` writes, one step a line.
 *
 *   # a comment                         (blank lines too)
 *   section NAME [if COND]...           the steps up to "end" are one section; its conditions hold for all of them
 *   end
 *   [if COND]... [must] OP ARG...       one step: OP with its words; "must": when it fails, the rest of the section
 *                                       is left out (outside a section: the rest of the plan)
 *
 *   COND   bootarg:NAME          the kernel's command line has NAME=...
 *          bootarg:NAME=VALUE    ... with that value
 *          exists:PATH           PATH is there (stat)
 *          flag:NAME             an earlier "flag NAME" step ran
 *          !COND                 the opposite
 *
 * A word $NAME or ${NAME} is boot-arg NAME's value; a step whose boot-arg is not there is left out. Words are
 * separated by blanks; there is no quoting. The steps (OP) are listed in ops.h.
 */
#ifndef AKINIT_PLAN_H
#define AKINIT_PLAN_H

#define PLAN_MAX_WORDS  48

typedef int (*plan_fn)(int argc, char **argv);  /* 0, or an errno value */

struct plan_op {
	const char *name;
	int         min_args, max_args;     /* words after the step's name */
	plan_fn     fn;
};

/* what the runner asks of the system (ops.c on the phone, the host test's fake system there) */
const char *bootarg(const char *name);
int         path_exists(const char *path);

/* flags: set by the step "flag", and by modules (flag_set) */
int         flag_is(const char *name);
void        flag_set(const char *name);

/*
 * Run (or with check != 0 only parse and check) the plan TEXT, which is changed in place. The number of lines that
 * are not right (unknown step, wrong number of words, a bad condition, sections that do not close); when running,
 * also -1 if a "must" outside a section failed.
 */
int         plan_run(char *text, const struct plan_op *ops, int check);

#endif
