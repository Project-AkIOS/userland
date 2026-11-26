/*
 * libakios.springboard.dylib: a BRING-UP AID inside SpringBoard, off unless the boot line says skip_setup=1.
 *
 * SpringBoard shows the setup assistant when it finds the phone "bricked": -[SBLockdownManager _setupActivationState]
 * asks MobileActivation and keeps the answer at +8 of the manager (2 activated, 1 not, 3 unknown; iOS 27.2.1, checked
 * 11-26). This phone cannot be activated (the activation chain wants a Secure Enclave), so with skip_setup=1 the
 * answer is "activated", and -[SBSetupManager _setSetupRequiredReason:] is told 0 (no setup needed). After that the
 * named semaphore purplebuddy.sentinel is made again: BYSetupAssistantNeedsToRun() answers NO only while it exists
 * (ForceNoBuddy counts on Apple's internal builds alone), and SpringBoard removes it by its own finding.
 * For home-screen testing while Setup itself is worked on; to be retired with Setup fixed (tester 11-26).
 */
#include <errno.h>
#include <fcntl.h>
#include <objc/runtime.h>
#include <semaphore.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static void
say(const char *format, ...)
{
	char line[256];
	va_list ap;
	int fd;

	va_start(ap, format);
	vsnprintf(line, sizeof(line), format, ap);
	va_end(ap);
	if ((fd = open("/dev/console", O_WRONLY)) >= 0) {
		(void)write(fd, line, strlen(line));
		close(fd);
	}
}

static int
boot_flag(const char *name)
{
	char args[1024], *at;
	size_t size = sizeof(args) - 1, n = strlen(name);

	if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) != 0) {
		return 0;
	}
	args[size] = '\0';
	for (at = args; (at = strstr(at, name)) != NULL; at += n) {
		if ((at == args || at[-1] == ' ') && at[n] == '=') {
			return at[n + 1] == '1';
		}
	}
	return 0;
}

static void
no_buddy(void)
{
	static int said;
	sem_t *sentinel = sem_open("purplebuddy.sentinel", O_CREAT, 0644, 0);

	if (sentinel != SEM_FAILED) {
		sem_close(sentinel);
	}
	if (!said++ || sentinel == SEM_FAILED) {
		say("akios: SpringBoard: setup assistant skipped (skip_setup=1): purplebuddy.sentinel %s\n",
		    sentinel != SEM_FAILED ? "made" : strerror(errno));
	}
}

#define LOCKDOWN_STATE(manager)         (*(int *)((char *)(manager) + 8))
#define LOCKDOWN_ACTIVATED              2

static void
setup_activation_state(id self, __unused SEL selector)
{
	LOCKDOWN_STATE(self) = LOCKDOWN_ACTIVATED;
}

static void (*original_set_setup_required_reason)(id, SEL, long);

static void
set_setup_required_reason(id self, SEL selector, long reason)
{
	if (reason != 0) {
		say("akios: SpringBoard wanted the setup assistant (reason %ld): skipped (skip_setup=1)\n", reason);
	}
	original_set_setup_required_reason(self, selector, 0);
	no_buddy();
}

static IMP
replace(const char *class_name, const char *selector, IMP replacement)
{
	Class cls = objc_getClass(class_name);
	Method method = cls != NULL ? class_getInstanceMethod(cls, sel_registerName(selector)) : NULL;

	if (method == NULL) {
		say("akios: SpringBoard: no -[%s %s]: setup not skipped there\n", class_name, selector);
		return NULL;
	}
	return method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void
start(void)
{
	if (!boot_flag("skip_setup")) {
		return;
	}
	replace("SBLockdownManager", "_setupActivationState", (IMP)setup_activation_state);
	original_set_setup_required_reason = (void (*)(id, SEL, long))replace("SBSetupManager", "_setSetupRequiredReason:",
	    (IMP)set_setup_required_reason);
	no_buddy();
}
