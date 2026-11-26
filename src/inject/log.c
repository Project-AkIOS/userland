/*
 * libakios.log.dylib: a stock Darwin daemon's os_log lines on its stderr (the console), for finding out why it does
 * what it does where nothing reads the system log. Inserted into the jobs named with it in INJECT (userland/build.sh;
 * off by default: INJECT_LOG="wifid" adds it for a run). Every log level is answered "enabled", each call's format
 * and arguments (strings, numbers, objects by their description) are printed once per distinct line (digits apart),
 * at most 60000 lines. Only calls made from the program itself and from the libraries whose path has one of the
 * words of the environment variable HAKIOS_LOG_FROM (default: every image) are printed.
 *
 * A diagnostic: nothing of the daemon's behaviour is changed but the cost of making the lines.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <os/log.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

static bool
wanted_image(void *dso)
{
	static const void *yes[24], *no[96];
	static int n_yes, n_no;
	const char *words = getenv("HAKIOS_LOG_FROM");
	Dl_info where = { 0 };
	bool want = true;

	for (int i = 0; i < n_yes; i++) {
		if (yes[i] == dso) {
			return true;
		}
	}
	for (int i = 0; i < n_no; i++) {
		if (no[i] == dso) {
			return false;
		}
	}
	if (words != NULL && words[0] != 0) {
		char copy[256], *word, *save = NULL;

		want = false;
		if (dladdr(dso, &where) != 0 && where.dli_fname != NULL) {
			snprintf(copy, sizeof(copy), "%s", words);
			for (word = strtok_r(copy, " ,", &save); word != NULL; word = strtok_r(NULL, " ,", &save)) {
				want |= strstr(where.dli_fname, word) != NULL;
			}
		}
	}
	if (want && n_yes < 24) {
		yes[n_yes++] = dso;
	} else if (!want && n_no < 96) {
		no[n_no++] = dso;
	}
	return want;
}

#define SEEN_SLOTS      131072          /* a power of two above twice the 60000 lines kept */

static void
said(void *dso, os_log_type_t type, const char *format, const uint8_t *buf, uint32_t size)
{
	static uint64_t seen[SEEN_SLOTS];        /* (60000 lines, 11-21: lsd filled 6000 before it got to the applications) */
	static int count;
	static int busy;
	char line[1700];
	int at;
	uint64_t hash = 1469598103934665603ULL;
	struct timespec now;

	if (format == NULL || count >= 60000 || busy || !wanted_image(dso)) {
		return;
	}
	busy = 1;       /* (a description below may log itself) */
	at = snprintf(line, sizeof(line), "(%d) %.200s", (int)type, format);
	/* the buffer: summary, count, then {descriptor, size, bytes} for each argument */
	if (buf != NULL && size >= 2) {
		uint32_t off = 2;

		for (int i = 0; i < buf[1] && off + 2 <= size && at < (int)sizeof(line) - 80; i++) {
			uint8_t kind = buf[off] >> 4, length = buf[off + 1];

			if (off + 2 + length > size) {
				break;
			}
			if (kind == 2 && length == 8) {
				const char *text = NULL;

				memcpy(&text, buf + off + 2, 8);
				at += snprintf(line + at, sizeof(line) - (size_t)at, " | %.1200s", text ? text : "(null)");
			} else if (kind == 4 && length == 8) {
				CFTypeRef object = NULL;

				memcpy(&object, buf + off + 2, 8);
				if (object == NULL) {
					at += snprintf(line + at, sizeof(line) - (size_t)at, " | (nil)");
				} else {
					CFStringRef description = CFCopyDescription(object);
					char text[220] = "?";

					if (description != NULL) {
						CFStringGetCString(description, text, sizeof(text), kCFStringEncodingUTF8);
						CFRelease(description);
					}
					for (char *c = text; *c != 0; c++) {
						if (*c == '\n') {
							*c = ' ';
						}
					}
					at += snprintf(line + at, sizeof(line) - (size_t)at, " | %s", text);
				}
			} else if (kind == 0 && length == 4) {
				int32_t v;

				memcpy(&v, buf + off + 2, 4);
				at += snprintf(line + at, sizeof(line) - (size_t)at, " | %d", v);
			} else if (kind == 0 && length == 8) {
				long long v;

				memcpy(&v, buf + off + 2, 8);
				at += snprintf(line + at, sizeof(line) - (size_t)at, " | %lld", v);
			}
			off += 2u + length;
		}
	}
	for (const char *c = line; *c != 0; c++) {
		if (*c < '0' || *c > '9') {
			hash = (hash ^ (uint8_t)*c) * 1099511628211ULL;
		}
	}
	/* (an open-addressing set of the lines' hashes: a linear search of 60000 for every line cost too much, 11-21) */
	hash |= 1;                      /* (0 marks an empty slot) */
	for (uint32_t slot = (uint32_t)(hash >> 32) & (SEEN_SLOTS - 1);; slot = (slot + 1) & (SEEN_SLOTS - 1)) {
		if (seen[slot] == hash) {
			busy = 0;
			return;
		}
		if (seen[slot] == 0) {
			seen[slot] = hash;
			break;
		}
	}
	count++;
	clock_gettime(CLOCK_MONOTONIC, &now);
	fprintf(stderr, "hakios: log: %s[%d] @%ld.%01ld %s\n", getprogname(), getpid(), (long)now.tv_sec, now.tv_nsec / 100000000, line);
	busy = 0;
}

extern void _os_log_impl(void *, os_log_t, os_log_type_t, const char *, uint8_t *, uint32_t);
extern void _os_log_error_impl(void *, os_log_t, os_log_type_t, const char *, uint8_t *, uint32_t);
extern void _os_log_fault_impl(void *, os_log_t, os_log_type_t, const char *, uint8_t *, uint32_t);
extern void _os_log_debug_impl(void *, os_log_t, os_log_type_t, const char *, uint8_t *, uint32_t);

#define LOG_WATCHED(name)                                                                                              \
	static void watched##name(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf,       \
	    uint32_t size)                                                                                             \
	{                                                                                                              \
		static struct log_wrapper w;                                                                           \
		static bool read;                                                                                      \
		void *caller = __builtin_ptrauth_strip(__builtin_return_address(0), 0);                                \
                                                                                                                       \
		if (!read) {                                                                                           \
			w = log_wrapper_of((const void *)name);                                                        \
			read = true;                                                                                   \
		}                                                                                                      \
		said(dso, type, format, buf, size);                                                                    \
		if (w.internal != NULL) {                                                                              \
			w.internal(dso, log, type, format, buf, size, caller, w.w7);                                   \
		} else {                                                                                               \
			name(dso, log, type, format, buf, size);                                                       \
		}                                                                                                      \
	}                                                                                                              \
	__attribute__((used)) static struct {                                                                          \
		const void *ours, *theirs;                                                                             \
	} interpose##name __attribute__((section("__DATA,__interpose"))) = { (const void *)watched##name,              \
		                                                             (const void *)name };

/*
 * "Enabled" for every level -- but never for a disabled log (OS_LOG_DISABLED is NULL: a "yes" there sent programs into
 * _os_log_impl with no log, a fault at NULL + 0x3d inside it -- powerd, WirelessRadioManagerd, assistantd, findmydeviced,
 * 11-21), and with log_all only what the system itself says (os_log_type_enabled from this image is the real one).
 */
static bool log_all_on(void);

/*
 * boot-arg log_levels=NAME,NAME (AkIOS 11-22): every level (debug, info) on for these programs even with log_all=1,
 * which leaves the levels as they are for everybody else -- coreservicesd's file-ID tree says why it drops a volume
 * only at debug level.
 */
#include <sys/sysctl.h>
static bool
levels_wanted_here(void)
{
	static int known = -1;

	if (known < 0) {
		char args[1024] = "";
		size_t size = sizeof(args) - 1;
		const char *at, *name = getprogname();
		size_t n = strlen(name);

		known = 0;
		if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && (at = strstr(args, "log_levels=")) != NULL) {
			for (at += 11; *at && *at != ' ';) {
				if (strncmp(at, name, n) == 0 && (at[n] == ',' || at[n] == ' ' || at[n] == 0)) {
					known = 1;
					break;
				}
				while (*at && *at != ',' && *at != ' ') {
					at++;
				}
				if (*at == ',') {
					at++;
				}
			}
		}
	}
	return known == 1;
}

static bool
every_level(os_log_t log, os_log_type_t type)
{
	if (log == NULL) {
		return false;
	}
	if (log_all_on() && !levels_wanted_here()) {
		return os_log_type_enabled(log, type);
	}
	return true;
}

__attribute__((used)) static struct {
	const void *ours, *theirs;
} interpose_enabled __attribute__((section("__DATA,__interpose"))) = { (const void *)every_level, (const void *)os_log_type_enabled };

/*
 * The calls made from inside the shared cache (a daemon's frameworks: most of wifid's lines) are bound when the cache
 * is built and pass the interposing above by: for them the logging function itself is entered through a jump written
 * over its first four instructions (a private copy of the page), which are kept in a trampoline that goes on into it;
 * and "is this level enabled" is answered yes for everybody the same way.
 */
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <sys/mman.h>

typedef void (*log_impl)(void *, os_log_t, os_log_type_t, const char *, uint8_t *, uint32_t);
static log_impl impl_trampoline;

static bool
jump_written(uintptr_t at, void *to)
{
	uintptr_t target = (uintptr_t)__builtin_ptrauth_strip(to, 0);
	uint32_t code[4];
	vm_address_t page = at & ~(vm_address_t)(vm_page_size - 1);

	code[0] = 0x58000050;           /* ldr x16, #8 */
	code[1] = 0xd61f0200;           /* br x16 */
	memcpy(&code[2], &target, 8);
	if (vm_protect(mach_task_self(), page, 2 * vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
		return false;
	}
	memcpy((void *)at, code, sizeof(code));
	vm_protect(mach_task_self(), page, 2 * vm_page_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
	sys_icache_invalidate((void *)at, sizeof(code));
	return true;
}

/*
 * iOS 27's _os_log_impl (and _os_log_debug/error/fault_impl) are wrappers: "mov x6, x30; xpaci x6; mov w7, #N;
 * bl INTERNAL" -- the CALLER's address goes to the logger, which finds the calling image (and its format strings)
 * from it. Called from here, through a trampoline or after interposing, that address was ours: the wrong image, and
 * powerd, WirelessRadioManagerd, assistantd and findmydeviced crashed inside os_log at 0x3d (11-21). So each wrapper is
 * read once for its INTERNAL and N, and called the way the wrapper would, with the real caller (16.5's took none).
 */
typedef void (*log_internal)(void *, os_log_t, os_log_type_t, const char *, uint8_t *, uint32_t, void *, uint32_t);

struct log_wrapper {
	log_internal internal;
	uint32_t     w7;
};

static struct log_wrapper
log_wrapper_of(const void *fn)
{
	struct log_wrapper w = { NULL, 0 };
	const uint32_t *code = (const uint32_t *)__builtin_ptrauth_strip(fn, 0);
	bool x6_is_lr = false;

	for (int i = 0; code != NULL && i < 12; i++) {
		uint32_t op = code[i];

		if (op == 0xaa1e03e6) {                         /* mov x6, x30 */
			x6_is_lr = true;
		} else if ((op & 0xffe0001f) == 0x52800007) {   /* movz w7, #imm16 */
			w.w7 = (op >> 5) & 0xffff;
		} else if ((op & 0xfc000000) == 0x94000000) {   /* bl INTERNAL */
			int32_t imm = (int32_t)(op << 6) >> 6;

			if (x6_is_lr) {
				w.internal = (log_internal)__builtin_ptrauth_sign_unauthenticated(
				    (void *)((uintptr_t)&code[i] + (intptr_t)imm * 4), 0, 0);
			}
			break;
		}
	}
	return w;
}

static struct log_wrapper impl_wrapper;

static void
impl_hooked(void *dso, os_log_t log, os_log_type_t type, const char *format, uint8_t *buf, uint32_t size)
{
	void *caller = __builtin_ptrauth_strip(__builtin_return_address(0), 0);

	said(dso, type, format, buf, size);
	if (impl_wrapper.internal != NULL) {
		impl_wrapper.internal(dso, log, type, format, buf, size, caller, impl_wrapper.w7);
	} else {
		impl_trampoline(dso, log, type, format, buf, size);
	}
}

/*
 * An application's standard error goes nowhere (/dev/null, or nothing): there it is pointed at the console, as
 * libhakios.app.dylib does for the applications it is in -- the App Store's lines were lost so (11-20). A daemon's,
 * which mkjobs.py points at the console already, or a file, is left as it is.
 */
#include <sys/stat.h>

/*
 * The whole system logged at once (init's boot-arg log_all=1, 11-21): every program has this library (the kernel's
 * "*"), and the console could not hold them all -- each writes its own file instead, in a directory init makes and
 * AFC reaches (afcclient over usbmux: Media/hakios-log/NAME-PID.log), its standard error with it.
 */
#define LOG_ALL_DIR     "/private/var/mobile/Media/hakios-log"

static bool
log_all_on(void)
{
	static int known = -1;
	struct stat st;

	if (known < 0) {
		known = stat(LOG_ALL_DIR, &st) == 0 && S_ISDIR(st.st_mode);
	}
	return known == 1;
}

static bool
stderr_to_file(void)
{
	struct stat st;
	char path[256];
	int fd;

	if (stat(LOG_ALL_DIR, &st) != 0 || !S_ISDIR(st.st_mode)) {
		return false;
	}
	snprintf(path, sizeof(path), LOG_ALL_DIR "/%s-%d.log", getprogname(), getpid());
	fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd < 0) {
		return false;
	}
	dup2(fd, 2);
	if (fd != 2) {
		close(fd);
	}
	setvbuf(stderr, NULL, _IONBF, 0);
	return true;
}

static void
stderr_to_console(void)
{
	struct stat st;

	if (stderr_to_file()) {
		return;
	}
	if (fstat(2, &st) != 0 || (S_ISCHR(st.st_mode) && !isatty(2))) {
		int fd = open("/dev/console", O_WRONLY);

		if (fd >= 0) {
			dup2(fd, 2);
			if (fd != 2) {
				close(fd);
			}
		}
	}
}

/*
 * Every thread's stack at two moments (11-21: SpringBoard on iOS 27 falls silent 17 s in and never draws -- where does
 * it wait?). HAKIOS_LOG_STACKS="25 60" (the default; "0" none): seconds after the start. Each thread is suspended only
 * while its frames are read (the frame-pointer chain, PAC bits stripped), and let go before anything is printed or
 * dladdr is called, so a lock it holds cannot stop this. A frame is "image+offset (nearest exported name+distance)";
 * tools/dsc-exports.py names the cache's code from the image's offset.
 */
#include <mach/mach.h>
#include <pthread.h>

#define STACK_DEPTH     28
#define STACK_THREADS   96

static void
say_frame(char *line, size_t size, int *at, uint64_t a)
{
	Dl_info where = { 0 };

	if (a == 0 || *at >= (int)size - 80) {
		return;
	}
	if (dladdr((void *)a, &where) != 0 && where.dli_fname != NULL) {
		const char *base = strrchr(where.dli_fname, '/');

		*at += snprintf(line + *at, size - (size_t)*at, " %s+%#lx", base ? base + 1 : where.dli_fname,
		    (unsigned long)(a - (uint64_t)where.dli_fbase));
		if (where.dli_sname != NULL) {
			*at += snprintf(line + *at, size - (size_t)*at, "(%.60s+%#lx)", where.dli_sname,
			    (unsigned long)(a - (uint64_t)where.dli_saddr));
		}
	} else {
		*at += snprintf(line + *at, size - (size_t)*at, " %#llx", (unsigned long long)a);
	}
}

static void
dump_stacks(long when)
{
	static uint64_t frames[STACK_THREADS][STACK_DEPTH];
	static int depth[STACK_THREADS];
	static thread_t ids[STACK_THREADS];
	thread_act_array_t threads;
	mach_msg_type_number_t n = 0;
	thread_t me = mach_thread_self();
	int count = 0;

	if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS) {
		return;
	}
	for (mach_msg_type_number_t i = 0; i < n && count < STACK_THREADS; i++) {
		arm_thread_state64_t st;
		mach_msg_type_number_t c = ARM_THREAD_STATE64_COUNT;
		int d = 0;

		if (threads[i] == me || thread_suspend(threads[i]) != KERN_SUCCESS) {
			continue;
		}
		if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&st, &c) == KERN_SUCCESS) {
			uint64_t fp = arm_thread_state64_get_fp(st);

			frames[count][d++] = (uint64_t)__builtin_ptrauth_strip((void *)arm_thread_state64_get_pc(st), 0);
			frames[count][d++] = (uint64_t)__builtin_ptrauth_strip((void *)arm_thread_state64_get_lr(st), 0);
			while (d < STACK_DEPTH && fp != 0 && (fp & 7) == 0) {
				uint64_t next = ((uint64_t *)fp)[0], ret = ((uint64_t *)fp)[1];

				ret = (uint64_t)__builtin_ptrauth_strip((void *)ret, 0);
				if (ret == 0) {
					break;
				}
				frames[count][d++] = ret;
				if (next <= fp) {
					break;
				}
				fp = next;
			}
		}
		thread_resume(threads[i]);
		depth[count] = d;
		ids[count++] = threads[i];
	}
	for (int t = 0; t < count; t++) {
		char line[3000], name[64] = "";
		pthread_t pt = pthread_from_mach_thread_np(ids[t]);
		int at;

		if (pt != NULL) {
			pthread_getname_np(pt, name, sizeof(name));
		}
		at = snprintf(line, sizeof(line), "hakios: stack: %s[%d] @%ld thread %d '%s':", getprogname(), getpid(), when, t, name);
		for (int k = 0; k < depth[t]; k++) {
			say_frame(line, sizeof(line), &at, frames[t][k]);
		}
		fprintf(stderr, "%s\n", line);
	}
	for (mach_msg_type_number_t i = 0; i < n; i++) {
		mach_port_deallocate(mach_task_self(), threads[i]);
	}
	vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof(thread_t));
	mach_port_deallocate(mach_task_self(), me);
}

static void *
stacks_later(void *arg)
{
	char when[64];
	const char *env = getenv("HAKIOS_LOG_STACKS");
	char *word, *save = NULL;
	long slept = 0;

	(void)arg;
	snprintf(when, sizeof(when), "%s", env != NULL ? env : "25 60");
	pthread_setname_np("hakios.stacks");
	for (word = strtok_r(when, " ,", &save); word != NULL; word = strtok_r(NULL, " ,", &save)) {
		long at = strtol(word, NULL, 10);

		if (at <= slept) {
			continue;
		}
		sleep((unsigned)(at - slept));
		slept = at;
		dump_stacks(at);
	}
	return NULL;
}

/*
 * A fatal signal's stack (11-21: backboardd on iOS 27 aborts itself a second after making its framebuffer surface):
 * frames as image+offset, then the signal again with the default action, so the crash goes on as it would have.
 */
#include <execinfo.h>
#include <signal.h>

static void
fatal_signal(int sig, siginfo_t *info, void *context)
{
	void *frames[48];
	int n = backtrace(frames, 48);
	char line[4000];
	int at = snprintf(line, sizeof(line), "hakios: fatal: %s[%d] signal %d (address %p):", getprogname(), getpid(), sig,
	    info ? info->si_addr : NULL);

	(void)context;
	for (int i = 0; i < n; i++) {
		say_frame(line, sizeof(line), &at, (uint64_t)__builtin_ptrauth_strip(frames[i], 0));
	}
	fprintf(stderr, "%s\n", line);
	/* (11-26) which GPU code the process had: the loaded images naming Metal, IOGPU or our /akita -- backboardd's first
	 * instance aborted in CoreAnimation without a line of its Metal plug-in's, and whether the plug-in was in it at all
	 * was the question */
	at = snprintf(line, sizeof(line), "hakios: fatal: %s[%d] images:", getprogname(), getpid());
	for (uint32_t i = 0, count = _dyld_image_count(); i < count && at < (int)sizeof(line) - 200; i++) {
		const char *name = _dyld_get_image_name(i);

		if (name != NULL && (strstr(name, "Metal") != NULL || strstr(name, "IOGPU") != NULL || strstr(name, "/akita/") != NULL ||
		    strstr(name, "AGX") != NULL)) {
			at += snprintf(line + at, sizeof(line) - (size_t)at, " %s", name);
		}
	}
	fprintf(stderr, "%s\n", line);
	signal(sig, SIG_DFL);
	raise(sig);
}

__attribute__((constructor)) static void
start_stacks(void)
{
	struct sigaction sa;

	/* (not with log_all, 11-21: installd's signal then went to this handler in a page it could not execute, and it spun
	 * there until SIGBUS -- uexc=1 gives the crashes' registers and frames instead) */
	if (log_all_on()) {
		goto stacks;
	}
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = fatal_signal;
	sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
	sigaction(SIGABRT, &sa, NULL);
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGILL, &sa, NULL);
	sigaction(SIGTRAP, &sa, NULL);
stacks:
	;
	pthread_t t;

	if (getenv("HAKIOS_LOG_STACKS") == NULL || strcmp(getenv("HAKIOS_LOG_STACKS"), "0") != 0) {
		if (pthread_create(&t, NULL, stacks_later, NULL) == 0) {
			pthread_detach(t);
		}
	}
}

__attribute__((constructor)) static void
hook_the_cache(void)
{
	stderr_to_console();
	uintptr_t impl = (uintptr_t)__builtin_ptrauth_strip(dlsym(RTLD_DEFAULT, "_os_log_impl"), 0);
	uintptr_t enabled = (uintptr_t)__builtin_ptrauth_strip(dlsym(RTLD_DEFAULT, "os_log_type_enabled"), 0);
	/*
	 * (11-21) os_log_type_enabled is interposed by this library (every_level), and dlsym then answers with OUR function:
	 * the jump below was written over a page of this library, which lost its code signature -- the next call into that
	 * page ("Data/Stack execution not permitted ... protections were read-write") killed backboardd, installd and others
	 * with SIGBUS. Never write into our own image.
	 */
	{
		Dl_info mine = { 0 }, there = { 0 };

		if (enabled != 0 && dladdr((void *)every_level, &mine) != 0 && dladdr((void *)enabled, &there) != 0 &&
		    mine.dli_fbase == there.dli_fbase) {
			/* (11-22) the real one: the next definition after this library's (RTLD_NEXT), which interposing does not answer for */
			uintptr_t real = (uintptr_t)__builtin_ptrauth_strip(dlsym(RTLD_NEXT, "os_log_type_enabled"), 0);

			enabled = (real != 0 && dladdr((void *)real, &there) != 0 && mine.dli_fbase != there.dli_fbase) ? real : 0;
		}
	}
	uint32_t first[4], *trampoline;
	uintptr_t back;

	if (getenv("HAKIOS_LOG_NO_HOOK") != NULL || impl == 0) {
		return;
	}
	memcpy(first, (void *)impl, sizeof(first));
	for (int i = 0; i < 4; i++) {           /* (nothing there may depend on where it runs) */
		uint32_t w = first[i];

		if ((w & 0x1f000000) == 0x10000000 || (w & 0x7c000000) == 0x14000000 || (w & 0xff000010) == 0x54000000 ||
		    (w & 0x7e000000) == 0x34000000 || (w & 0x7e000000) == 0x36000000 || (w & 0x3b000000) == 0x18000000) {
			fprintf(stderr, "hakios: log: %s: _os_log_impl begins %08x %08x %08x %08x: not hooked\n", getprogname(), first[0], first[1],
			    first[2], first[3]);
			return;
		}
	}
	impl_wrapper = log_wrapper_of((const void *)impl);
	/*
	 * The trampoline (the function's first instructions copied into memory of ours made executable) only when the
	 * wrapper could not be read: iOS 27 does not let every program execute such memory -- installd died of it,
	 * "Data/Stack execution not permitted ... protections were read-write", and LaunchServices waited for it (11-21).
	 */
	if (impl_wrapper.internal == NULL) {
		trampoline = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
		if (trampoline == MAP_FAILED) {
			return;
		}
		memcpy(trampoline, first, sizeof(first));
		trampoline[4] = 0x58000050;
		trampoline[5] = 0xd61f0200;
		back = impl + 16;
		memcpy(&trampoline[6], &back, 8);
		if (mprotect(trampoline, 0x4000, PROT_READ | PROT_EXEC) != 0) {
			return;
		}
		sys_icache_invalidate(trampoline, 32);
		impl_trampoline = (log_impl)__builtin_ptrauth_sign_unauthenticated((void *)trampoline, 0, 0);
	}
	if (!jump_written(impl, (void *)impl_hooked)) {
		return;
	}
	/*
	 * "Is this level enabled" answered yes for the cache's own callers too (their debug and info lines): the jump is
	 * written over the function only where four instructions of it are there to write over -- a plain branch at its
	 * start is followed once, a return within the first four leaves it alone (HAKIOS_LOG_ALL_LEVELS=0 too).
	 */
	/* (not with log_all: every program's debug and info lines on made powerd, WirelessRadioManagerd and assistantd crash
	 * inside os_log -- paths nobody runs with those levels off, 11-21 -- and the point is the system as it is) */
	struct stat logall;
	bool all = stat(LOG_ALL_DIR, &logall) == 0;

	if (enabled != 0 && getenv("HAKIOS_LOG_DEFAULT_LEVELS") == NULL && (!all || levels_wanted_here())) {
		uint32_t w[4];
		bool fits = true;

		memcpy(w, (void *)enabled, sizeof(w));
		if ((w[0] & 0xfc000000) == 0x14000000) {        /* b somewhere: there */
			int32_t offset = (int32_t)(w[0] << 6) >> 6;

			enabled += (intptr_t)offset * 4;
			memcpy(w, (void *)enabled, sizeof(w));
		}
		for (int i = 0; i < 4; i++) {
			fits &= w[i] != 0xd65f03c0 && w[i] != 0xd65f0fff && w[i] != 0xd65f0bff && (w[i] & 0xfc000000) != 0x14000000;
		}
		fprintf(stderr, "hakios: log: %s: os_log_type_enabled begins %08x %08x %08x %08x: %s\n", getprogname(), w[0], w[1], w[2], w[3],
		    fits ? "answered yes for everybody" : "left alone");
		if (fits) {
			(void)jump_written(enabled, (void *)every_level);
		}
	}
	fprintf(stderr, "hakios: log: %s[%d]: the logging function hooked in the shared cache\n", getprogname(), getpid());
}

/* (_os_log_impl is not interposed as well: dlsym would then answer with our own function, and the jump was written
 * over that -- wifid died of it, 11-19; the hook above sees every caller anyway) */
LOG_WATCHED(_os_log_error_impl)
LOG_WATCHED(_os_log_fault_impl)
LOG_WATCHED(_os_log_debug_impl)

/*
 * AkIOS (11-22): which URL property LaunchServices does not get. iOS 27's lsd fails to make the bookmark of every
 * framework that declares an extension point -- -[FSNode getResourceValue:forKey:options:error:] answers -10813
 * (FSUtils.mm:832, CFURLCopyResourcePropertyForKey giving nothing and no error) -- and the apps it registers never reach
 * SpringBoard. In lsd only, a second after it starts: the method wrapped, and every (key, error) it fails with said once
 * with the file's path, up to 200 of them. A diagnostic, not a fix.
 */
#include <objc/runtime.h>
#include <objc/message.h>
#include <dispatch/dispatch.h>

typedef bool (*fsnode_get_fn)(id, SEL, id *, CFStringRef, unsigned long, CFErrorRef *);
static fsnode_get_fn fsnode_get_orig;
static unsigned fsnode_said;
static uint64_t fsnode_seen[200];

static bool
fsnode_get_traced(id self, SEL cmd, id *value, CFStringRef key, unsigned long options, CFErrorRef *error)
{
	bool ok = fsnode_get_orig(self, cmd, value, key, options, error);
	char k[128] = "?", path[1024] = "?", e[256] = "";
	uint64_t h = 1469598103934665603ULL;
	CFURLRef url;

	if (ok || fsnode_said >= 200) {
		return ok;
	}
	if (key != NULL) {
		CFStringGetCString(key, k, sizeof(k), kCFStringEncodingUTF8);
	}
	if (error != NULL && *error != NULL) {
		CFStringRef d = CFErrorCopyDescription(*error);

		snprintf(e, sizeof(e), " error %ld", (long)CFErrorGetCode(*error));
		if (d != NULL) {
			size_t n = strlen(e);

			CFStringGetCString(d, e + n, (CFIndex)(sizeof(e) - n), kCFStringEncodingUTF8);
			CFRelease(d);
		}
	}
	for (const char *c = k; *c; c++) {
		h = (h ^ (uint8_t)*c) * 1099511628211ULL;
	}
	h ^= error != NULL && *error != NULL ? (uint64_t)CFErrorGetCode(*error) : 0;
	for (unsigned i = 0; i < fsnode_said; i++) {
		if (fsnode_seen[i] == h) {
			return ok;
		}
	}
	fsnode_seen[fsnode_said++] = h;
	url = ((CFURLRef (*)(id, SEL))objc_msgSend)(self, sel_registerName("URL"));
	if (url != NULL) {
		CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof(path));
	}
	fprintf(stderr, "hakios: fsnode: %s[%d] getResourceValue %s (options %#lx) of %s: NO%s\n", getprogname(), getpid(),
	    k, options, path, e);
	return ok;
}

__attribute__((constructor)) static void
fsnode_trace_start(void)
{
	if (strcmp(getprogname(), "lsd") != 0) {
		return;
	}
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{
		Class cls = objc_getClass("FSNode");
		Method m = cls != NULL ? class_getInstanceMethod(cls, sel_registerName("getResourceValue:forKey:options:error:")) : NULL;

		if (m == NULL) {
			fprintf(stderr, "hakios: fsnode: %s: no -[FSNode getResourceValue:forKey:options:error:]\n", getprogname());
			return;
		}
		fsnode_get_orig = (fsnode_get_fn)method_setImplementation(m, (IMP)fsnode_get_traced);
		fprintf(stderr, "hakios: fsnode: %s[%d]: -[FSNode getResourceValue:forKey:options:error:] traced\n", getprogname(), getpid());
	});
}
