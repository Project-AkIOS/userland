/*
 * AkiosMetal: Metal's plug-in for the Mali-G715, built the way Apple's AGXMetal is -- its classes are subclasses of
 * IOGPU.framework's IOGPUMetal* classes, which talk to the kernel's IOGPU (akios_iogpu.cpp) for memory, queues,
 * submission, completion and events. What is ours is the Mali's command generation, the compiler and the formats: the
 * Mali core (hakios-metal's src/mali, opened over IOGPU's own connection with hakios_metal_open_iogpu).
 *
 * The plan: ref/iogpu-research/phase6-plan.md. Here: step A (the device, its queues and command buffers through IOGPU's
 * submission and completion), step B (buffers are IOGPU's resources), step C (blit and compute encoders, plain textures:
 * a command buffer's core work is built into a Mali stream at -commit and named in the arguments' tail).
 *
 *   AkiosMetal.m           device, queue, buffer, command buffer
 *   AkiosMetalTexture.m    textures (the core's layout over IOGPU's texture resource)
 *   AkiosMetalEncoders.m   blit and compute encoders
 *   AkiosMetalState.m      samplers, compute pipelines
 *   AkiosMetalRender.m     render passes, render and parallel render encoders, render pipeline states
 *   AkiosMetalPipelines.m  render pipelines made, reflection, depth/stencil states, argument encoders
 *   AkiosMetalHeap.m       heaps
 *   AkiosMetalLimits.m     the device's answers about itself (feature profile, target architecture, limits)
 */
#import "AkiosMetal.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <fcntl.h>
#include <os/log.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

/*
 * A line of the plug-in's (11-26): one write to standard error, and -- where standard error is no terminal -- the same
 * line through os_log too. backboardd's first instance on the phone showed none of its plug-in's lines in the console
 * (its restarted one did, and libakios.log's os_log lines of the first one were there): the os_log copy goes the way
 * those went.
 */
/*
 * THE TRACE FILE (11-26): the same lines also go to a file of the process's own, each written at once and synced, so
 * that what a process said survives it even where its standard error and os_log reach no console (backboardd's first
 * instance): /private/var/tmp/akios-metal-NAME-PID.log, else /tmp/..., else the process's temporary directory. Its
 * first line is written when the bundle is loaded, so the file's being there says the plug-in was in that process.
 */
static int akm_trace_fd = -1;
static unsigned akm_devices;     /* devices made in this process (said at a fatal signal) */
static char akm_trace_path[256];

static void
akm_trace_open(void)
{
	char dir[200] = "";
	const char *dirs[3] = { "/private/var/tmp", "/tmp", NULL };

	if (confstr(_CS_DARWIN_USER_TEMP_DIR, dir, sizeof(dir)) > 0) {
		size_t n = strlen(dir);

		if (n > 0 && dir[n - 1] == '/') {
			dir[n - 1] = 0;
		}
		dirs[2] = dir;
	}
	for (int i = 0; i < 3 && akm_trace_fd < 0; i++) {
		if (dirs[i] == NULL || dirs[i][0] == 0) {
			continue;
		}
		snprintf(akm_trace_path, sizeof(akm_trace_path), "%s/akios-metal-%s-%d.log", dirs[i], getprogname(), getpid());
		akm_trace_fd = open(akm_trace_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
	}
	if (akm_trace_fd < 0) {
		akm_trace_path[0] = 0;
	}
}

static void
akm_trace(const char *line, size_t n)
{
	static unsigned retries;

	/* (not openable when the bundle was loaded: tried again with the next few lines) */
	if (akm_trace_fd < 0 && retries < 8) {
		retries++;
		akm_trace_open();
	}
	if (akm_trace_fd >= 0) {
		write(akm_trace_fd, line, n);
		fsync(akm_trace_fd);
	}
}

void
akios_say(const char *format, ...)
{
	char line[512];
	va_list ap;
	int at;

	at = snprintf(line, sizeof(line), "AkiosMetal: %s: ", getprogname());
	va_start(ap, format);
	vsnprintf(line + at, sizeof(line) - (size_t)at, format, ap);
	va_end(ap);
	write(2, line, strlen(line));
	akm_trace(line, strlen(line));
	if (!isatty(2)) {
		size_t n = strlen(line);

		if (n > 0 && line[n - 1] == '\n') {
			line[n - 1] = 0;
		}
		os_log_error(OS_LOG_DEFAULT, "%{public}s", line);
	}
}

/*
 * EVERY TEXTURE MADE (11-26): backboardd aborts in CoreAnimation's push_surface on the unlock ("found != slist->end ()"),
 * and what CoreAnimation made just before is the question. Each texture this plug-in makes or refuses -- plain, over an
 * IOSurface, over a buffer, a view -- is noted: kind, format, size, usage, storage, the IOSurface, the caller (image +
 * offset: the CoreAnimation function that asked). The first 60 of a process are said as they come (within its first
 * 3 minutes); the last 64 are kept in a ring and said when the process dies of SIGABRT, SIGSEGV or SIGBUS (the
 * handler there before is called after).
 */
struct akm_note {
	uint32_t ms;            /* since the process's first texture */
	const char *kind;
	uint32_t format, width, height, surface, plane;
	uint32_t usage, storage, made;
	void *caller, *texture;
};
#define AKM_RING 64
static struct akm_note akm_ring[AKM_RING];
static unsigned akm_ring_next;
static struct timespec akm_t0;
static struct sigaction akm_before[3];
static const int akm_signals[3] = { SIGABRT, SIGSEGV, SIGBUS };

static void
akm_where(void *caller, char *out, size_t size)
{
	Dl_info where;

	if (caller != NULL && dladdr(caller, &where) != 0 && where.dli_fname != NULL) {
		const char *base = strrchr(where.dli_fname, '/');

		snprintf(out, size, "%s+%#lx", base != NULL ? base + 1 : where.dli_fname,
		    (unsigned long)((uintptr_t)caller - (uintptr_t)where.dli_fbase));
	} else {
		snprintf(out, size, "%p", caller);
	}
}

static void
akm_note_line(const struct akm_note *n, char *out, size_t size)
{
	char where[96], surface[48] = "";

	akm_where(n->caller, where, sizeof(where));
	if (n->surface != 0) {
		snprintf(surface, sizeof(surface), ", IOSurface %u plane %u", n->surface, n->plane);
	}
	snprintf(out, size, "@%u.%03u %s %s: MTLPixelFormat %u, %ux%u, usage %#x, storage %u%s, from %s, texture %p", n->ms / 1000,
	    n->ms % 1000, n->made ? "made" : "REFUSED", n->kind, n->format, n->width, n->height, n->usage, n->storage, surface, where,
	    n->texture);
}

static void
akm_fatal(int signal_number, siginfo_t *info, void *context)
{
	static volatile int dumping;

	if (!dumping) {
		dumping = 1;
		const unsigned next = __atomic_load_n(&akm_ring_next, __ATOMIC_RELAXED);
		const unsigned count = next < AKM_RING ? next : AKM_RING;
		char line[400];
		int n = snprintf(line, sizeof(line), "AkiosMetal: %s: signal %d: %u device(s) made in this process; the last %u textures "
		    "made (of %u), oldest first:\n", getprogname(), signal_number, akm_devices, count, next);

		write(2, line, (size_t)n);
		akm_trace(line, (size_t)n);
		for (unsigned i = next - count; i != next; i++) {
			char body[320];

			akm_note_line(&akm_ring[i % AKM_RING], body, sizeof(body));
			n = snprintf(line, sizeof(line), "AkiosMetal: %s: texture %u %s\n", getprogname(), i, body);
			write(2, line, (size_t)n);
			akm_trace(line, (size_t)n);
		}
	}
	for (int i = 0; i < 3; i++) {
		if (akm_signals[i] != signal_number) {
			continue;
		}
		const struct sigaction *b = &akm_before[i];
		if ((b->sa_flags & SA_SIGINFO) && b->sa_sigaction != NULL) {
			b->sa_sigaction(signal_number, info, context);
			return;
		}
		if (b->sa_handler != SIG_DFL && b->sa_handler != SIG_IGN && b->sa_handler != NULL) {
			b->sa_handler(signal_number);
			return;
		}
	}
	signal(signal_number, SIG_DFL);
	raise(signal_number);
}

/* our handler outermost: put in when the bundle is loaded, and again whenever a texture is noted and somebody else's
 * handler has been put over it since (the one found is then the one called after ours) */
static void
akm_handlers_ensure(void)
{
	for (int i = 0; i < 3; i++) {
		struct sigaction now, action;

		if (sigaction(akm_signals[i], NULL, &now) != 0 || ((now.sa_flags & SA_SIGINFO) && now.sa_sigaction == akm_fatal)) {
			continue;
		}
		memset(&action, 0, sizeof(action));
		action.sa_sigaction = akm_fatal;
		action.sa_flags = SA_SIGINFO | SA_NODEFER;
		sigaction(akm_signals[i], &action, &akm_before[i]);
	}
}

static void
akm_notes_begin(void)
{
	clock_gettime(CLOCK_MONOTONIC, &akm_t0);
}

__attribute__((constructor)) static void
akm_loaded(void)
{
	char line[400];
	int n;

	akm_trace_open();
	akm_handlers_ensure();
	n = snprintf(line, sizeof(line), "AkiosMetal: %s: the bundle is loaded in process %d (uid %d); this trace: %s\n", getprogname(),
	    getpid(), getuid(), akm_trace_path[0] ? akm_trace_path : "none could be opened");
	write(2, line, (size_t)n);
	akm_trace(line, (size_t)n);
	os_log_error(OS_LOG_DEFAULT, "%{public}s", line);
	/* (and the console itself, where this process may write it) */
	int console = open("/dev/console", O_WRONLY | O_NOCTTY | O_CLOEXEC);
	if (console >= 0) {
		write(console, line, (size_t)n);
		close(console);
	}
}

void
akios_texture_note(const char *kind, id<MTLTexture> texture, MTLTextureDescriptor *descriptor, IOSurfaceRef surface,
    NSUInteger plane, void *caller)
{
	static pthread_once_t once = PTHREAD_ONCE_INIT;
	static unsigned said;
	struct timespec now;
	struct akm_note n;

	pthread_once(&once, akm_notes_begin);
	akm_handlers_ensure();
	clock_gettime(CLOCK_MONOTONIC, &now);
	memset(&n, 0, sizeof(n));
	n.ms = (uint32_t)((now.tv_sec - akm_t0.tv_sec) * 1000 + (now.tv_nsec - akm_t0.tv_nsec) / 1000000);
	n.kind = kind;
	n.made = texture != nil;
	if (descriptor != nil) {
		n.format = (uint32_t)descriptor.pixelFormat;
		n.width = (uint32_t)descriptor.width;
		n.height = (uint32_t)descriptor.height;
		n.usage = (uint32_t)descriptor.usage;
		n.storage = (uint32_t)descriptor.storageMode;
	} else if (texture != nil) {
		n.format = (uint32_t)texture.pixelFormat;
		n.width = (uint32_t)texture.width;
		n.height = (uint32_t)texture.height;
		n.usage = (uint32_t)texture.usage;
		n.storage = (uint32_t)texture.storageMode;
	}
	n.surface = surface != NULL ? IOSurfaceGetID(surface) : 0;
	n.plane = (uint32_t)plane;
	n.caller = caller;
	n.texture = (__bridge void *)texture;
	akm_ring[__atomic_fetch_add(&akm_ring_next, 1, __ATOMIC_RELAXED) % AKM_RING] = n;
	if (n.ms < 180000 && __atomic_fetch_add(&said, 1, __ATOMIC_RELAXED) < 60) {
		char body[320];

		akm_note_line(&n, body, sizeof(body));
		akios_say("texture %s\n", body);
	}
}

/* ---- the live memory (11-26) ---- */

struct akm_live { const void *owner; uint64_t va, size; uint32_t ms; char what[72]; };
struct akm_gone { uint64_t va, size; uint32_t made_ms, gone_ms; char what[72]; };
static struct akm_live *akm_lives;
static unsigned akm_live_count, akm_live_room;
static struct akm_gone akm_gones[256];
static unsigned akm_gone_next;
static os_unfair_lock akm_live_lock = OS_UNFAIR_LOCK_INIT;

static uint32_t
akm_now_ms(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return (uint32_t)(now.tv_sec * 1000 + now.tv_nsec / 1000000);
}

void
akios_live_add(const void *owner, uint64_t va, uint64_t size, const char *what)
{
	if (owner == NULL || va == 0 || size == 0) return;
	os_unfair_lock_lock(&akm_live_lock);
	if (akm_live_count == akm_live_room) {
		unsigned room = akm_live_room ? akm_live_room * 2 : 1024;
		struct akm_live *grown = realloc(akm_lives, room * sizeof(*grown));

		if (grown == NULL) {
			os_unfair_lock_unlock(&akm_live_lock);
			return;
		}
		akm_lives = grown;
		akm_live_room = room;
	}
	struct akm_live *e = &akm_lives[akm_live_count++];
	e->owner = owner;
	e->va = va;
	e->size = size;
	e->ms = akm_now_ms();
	snprintf(e->what, sizeof(e->what), "%s", what ? what : "?");
	os_unfair_lock_unlock(&akm_live_lock);
}

void
akios_live_remove(const void *owner)
{
	if (owner == NULL) return;
	os_unfair_lock_lock(&akm_live_lock);
	for (unsigned i = akm_live_count; i-- > 0;) {
		if (akm_lives[i].owner == owner) {
			struct akm_gone *g = &akm_gones[akm_gone_next++ % 256];

			g->va = akm_lives[i].va;
			g->size = akm_lives[i].size;
			g->made_ms = akm_lives[i].ms;
			g->gone_ms = akm_now_ms();
			memcpy(g->what, akm_lives[i].what, sizeof(g->what));
			akm_lives[i] = akm_lives[--akm_live_count];
		}
	}
	os_unfair_lock_unlock(&akm_live_lock);
}

BOOL
akios_live_check(uint64_t va, uint64_t size, char *why, size_t why_size)
{
	BOOL live = NO;

	os_unfair_lock_lock(&akm_live_lock);
	for (unsigned i = 0; i < akm_live_count && !live; i++) {
		live = akm_lives[i].va <= va && va + size <= akm_lives[i].va + akm_lives[i].size;
	}
	if (!live && why != NULL) {
		const uint32_t now = akm_now_ms();
		int at = snprintf(why, why_size, "GPU memory 0x%llx (+%llu) that no live resource of this process covers",
		    (unsigned long long)va, (unsigned long long)size);
		/* the latest resource gone that covered it, and what lives across it now */
		for (unsigned k = 0; k < 256 && at < (int)why_size; k++) {
			const struct akm_gone *g = &akm_gones[(akm_gone_next - 1 - k) % 256];

			if (g->size != 0 && g->va < va + size && va < g->va + g->size) {
				at += snprintf(why + at, why_size - (size_t)at, "; it was %s (0x%llx, %llu bytes), made %u ms and freed %u ms ago",
				    g->what, (unsigned long long)g->va, (unsigned long long)g->size, now - g->made_ms, now - g->gone_ms);
				break;
			}
		}
		for (unsigned i = 0; i < akm_live_count && at < (int)why_size; i++) {
			if (akm_lives[i].va < va + size && va < akm_lives[i].va + akm_lives[i].size) {
				at += snprintf(why + at, why_size - (size_t)at, "; overlapping it now: %s (0x%llx, %llu bytes)", akm_lives[i].what,
				    (unsigned long long)akm_lives[i].va, (unsigned long long)akm_lives[i].size);
				break;
			}
		}
	}
	os_unfair_lock_unlock(&akm_live_lock);
	return live;
}

BOOL
akios_boot_arg(const char *word)
{
	static char args[1024];
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		size_t size = sizeof(args) - 1;

		if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) != 0) {
			args[0] = '\0';
		}
	});
	return strstr(args, word) != NULL;
}

/*
 * A protocol declared by CLS (when this process has it and CLS does not already conform): the public Metal protocols
 * are defined only in the GPU vendor's bundle on this phone, so IOGPU's classes do not conform to them at run time, and
 * clients test it -- MPS's MPSCommandBufferImageCache refuses a command buffer that is not an MTLCommandBuffer, and
 * SpringBoard then read a field of the nil it got (11-26, CA::Display's link callback). The earlier plug-in declared
 * the same set (HakiosMetalCA.m: hm_adopt).
 */
void
akios_adopt(Class cls, Protocol *protocol)
{
	if (protocol != NULL && !class_conformsToProtocol(cls, protocol)) {
		class_addProtocol(cls, protocol);
	}
}

BOOL
akios_strict(void)
{
	const char *env = getenv("AKIOS_METAL_STRICT");

	return env != NULL ? strcmp(env, "1") == 0 : akios_boot_arg("metal_strict");
}

/* ---- the core's memory: IOGPU resources of this device (plan 2.1) ---- */

@interface AkiosMaliBuffer ()
- (void)akWrap:(hakios_metal_device *)core;
@end

@interface AkiosMaliDevice ()
- (id<MTLBuffer>)akiosBuffer:(void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options
    deallocator:(void (^)(void *, NSUInteger))deallocator wrap:(BOOL)wrap;
@end

/*
 * (11-26) A BUFFER OVER THE CALLER'S MEMORY THE KERNEL REFUSED (kind 0x80: "wiring it failed 0x2", KERN_INVALID_ADDRESS
 * -- the range is not all mapped): who asked (image + offset), and what the task's memory map has there, region by
 * region (start, end, protection, user tag, share mode) -- whether the range runs past an allocation, into a hole or a
 * guard page, or is memory already given back. Said 24 times.
 */
static __thread void *akm_nocopy_caller;

static void
akm_say_client_memory(void *pointer, NSUInteger length, void *caller)
{
	static unsigned said;
	char where[160] = "?", map[600] = "";
	Dl_info info;
	int at = 0;

	if (__atomic_fetch_add(&said, 1, __ATOMIC_RELAXED) >= 24) return;
	if (caller != NULL && dladdr(caller, &info) != 0 && info.dli_fname != NULL) {
		const char *base = strrchr(info.dli_fname, '/');
		snprintf(where, sizeof(where), "%s+0x%lx", base ? base + 1 : info.dli_fname,
		    (unsigned long)((uintptr_t)caller - (uintptr_t)info.dli_fbase));
	}
	vm_address_t addr = (vm_address_t)(uintptr_t)pointer & ~(vm_address_t)(vm_page_size - 1);
	const vm_address_t end = (vm_address_t)(uintptr_t)pointer + length;
	for (unsigned regions = 0; addr < end && regions < 6 && at < (int)sizeof(map) - 120; regions++) {
		vm_size_t size = 0;
		natural_t depth = 0;
		vm_region_submap_info_data_64_t r;
		mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
		vm_address_t found = addr;

		if (vm_region_recurse_64(mach_task_self(), &found, &size, &depth, (vm_region_recurse_info_64_t)&r, &count) != KERN_SUCCESS) {
			at += snprintf(map + at, sizeof(map) - (size_t)at, " [nothing mapped from 0x%llx on]", (unsigned long long)addr);
			break;
		}
		if (found > addr) {
			at += snprintf(map + at, sizeof(map) - (size_t)at, " [HOLE 0x%llx..0x%llx]", (unsigned long long)addr,
			    (unsigned long long)(found < end ? found : end));
			if (found >= end) break;
		}
		at += snprintf(map + at, sizeof(map) - (size_t)at, " [0x%llx..0x%llx prot %d/%d tag %u share %u%s]", (unsigned long long)found,
		    (unsigned long long)(found + size), r.protection, r.max_protection, r.user_tag, r.share_mode, r.is_submap ? " submap" : "");
		addr = found + size;
	}
	akios_say("refused: a buffer over the caller's memory %p + %lu (to %p) from %s: IOGPU made no resource of it; the map there:%s\n",
	    pointer, (unsigned long)length, (void *)((uint8_t *)pointer + length), where, map);
}

/* SIZE bytes for the core (its blit shaders, kernels' code, streams, spill space, staging): an internal buffer of this
 * device -- in IOGPU's connection, so in the address space the streams run in; the core holds it until it gives it back */
static int
akios_memory_alloc(void *context, uint64_t size, uint32_t flags, struct hakios_metal_memory *out)
{
	AkiosMaliDevice *device = (__bridge AkiosMaliDevice *)context;

	(void)flags;   /* (GPU read-only is a hint: the kernel maps every resource for reading and writing alike here) */
	@autoreleasepool {
		AkiosMaliBuffer *buffer = (AkiosMaliBuffer *)[device akiosBuffer:NULL length:(NSUInteger)size
		    options:MTLResourceStorageModeShared deallocator:nil wrap:NO];

		if (buffer == nil || [buffer gpuAddress] == 0 || [buffer contents] == NULL) {
			return -1;
		}
		out->gpu_va = [buffer gpuAddress];
		out->cpu = [buffer contents];
		out->resource_id = [buffer respondsToSelector:@selector(resourceID)] ? [buffer resourceID] : 0;
		out->cookie = (__bridge_retained void *)buffer;
	}
	return 0;
}

static void
akios_memory_free(void *context, void *cookie)
{
	(void)context;
	if (cookie != NULL) {
		id buffer = (__bridge_transfer id)cookie;   /* the last reference: IOGPU's resource goes (trap 1) */

		(void)buffer;
	}
}

@implementation AkiosMaliDevice {
	hakios_metal_device *_akCore;
}

+ (void)load
{
	/* IOGPUMetalDevice asserts that its device conforms to MTLDeviceSPI (a vendor's class declares it) */
	akios_adopt(self, objc_getProtocol("MTLDeviceSPI"));
	akios_adopt(self, @protocol(MTLDevice));
}

/*
 * IOGPU's device first (IOGPUDeviceCreate, the shared memory pools, the mapping thread), then the Mali core over ITS
 * connection: the kernel gives each connection its own GPU address space, so the core's memory and the plug-in's
 * resources must be the same connection's. A core that cannot be opened leaves a device that commits empty command
 * buffers and refuses encoders (said once).
 */
/*
 * THE ACCELERATOR (11-26). backboardd starts before the GPU driver: the display driver publishes a bare IOAcceleratorES
 * ('sgx') so that CoreAnimation finds an accelerator, and HakiosGPU (an IOGPU) comes ~3 s later and retires it. The
 * earlier plug-in served that stand-in with its own path; IOGPU's device cannot be made over it -- IOGPUDeviceCreate
 * fails, Metal answers no device, and CoreAnimation draws with its software renderer for the life of the process. That
 * renderer's CA::OGL::SWContext::create_surface_from_iosurface (-> create_surface_from_data) never calls
 * Context::track_surface, so the first asynchronous layer (the unlock's) aborts in push_surface: "found !=
 * slist->end ()" -- backboardd's first instance, 0 textures made through this plug-in, while the restarted one (made
 * after HakiosGPU) never aborts. So a device asked of an accelerator that is not an IOGPU is made over the IOGPU,
 * waited for up to 30 s.
 */
static io_service_t
akm_iogpu_for(io_service_t port)
{
	if (port != IO_OBJECT_NULL && IOObjectConformsTo(port, "IOGPU")) {
		return port;
	}
	io_name_t cls = "?";

	if (port != IO_OBJECT_NULL) {
		IOObjectGetClass(port, cls);
	}
	for (int waited = 0; waited <= 3000; waited++) {
		io_service_t gpu = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOGPU"));

		if (gpu != IO_OBJECT_NULL) {
			io_name_t gcls = "?";

			IOObjectGetClass(gpu, gcls);
			akios_say("asked for a device over the accelerator %s, not an IOGPU: made over %s instead (waited %d ms for it)\n",
			    cls, gcls, waited * 10);
			return gpu;             /* (its reference kept: the device's for its life) */
		}
		usleep(10000);
	}
	akios_say("asked for a device over the accelerator %s, not an IOGPU, and no IOGPU came in 30 s: no device\n", cls);
	return IO_OBJECT_NULL;
}

- (instancetype)initWithAcceleratorPort:(io_service_t)port
{
	port = akm_iogpu_for(port);
	if (port == IO_OBJECT_NULL) {
		return nil;
	}
	self = [super initWithAcceleratorPort:port];
	if (self == nil) {
		akios_say("IOGPU's device could not be made over the accelerator: no device\n");
		return nil;
	}
	__atomic_fetch_add(&akm_devices, 1, __ATOMIC_RELAXED);
	io_connect_t conn = IOGPUDeviceGetConnect([self deviceRef]);
	struct hakios_metal_memory_ops ops = {
		.context = (__bridge void *)self,      /* not retained: the device owns the core, and closes it in -dealloc */
		.alloc = akios_memory_alloc,
		.free = akios_memory_free,
	};

	_akCore = conn != 0 ? hakios_metal_open_iogpu(conn, &ops) : NULL;
	if (_akCore == NULL) {
		akios_say("the Mali core could not be opened over IOGPU's connection 0x%x: %s; no encoders on this device\n", conn,
		    conn != 0 ? hakios_metal_error() : "no connection");
	}
	{
		io_name_t cls = "?";

		IOObjectGetClass(port, cls);
		akios_say("a device made over the accelerator %s (connection 0x%x): the Mali core %s\n", cls, conn,
		    _akCore != NULL ? "opened" : "NOT opened");
	}
	akm_functions_encode_from_metadata();
	akm_library_stand_ins();
	return self;
}

- (void)dealloc
{
	hakios_metal_close(_akCore);
}

- (hakios_metal_device *)akCore
{
	return _akCore;
}

- (unsigned int)cmdBufArgsSize
{
	return AKIOS_CB_ARGS_SIZE;
}

- (NSString *)name
{
	return @"Mali-G715";
}

- (id<MTLCommandQueue>)newCommandQueueWithDescriptor:(MTLCommandQueueDescriptor *)descriptor
{
	return (id<MTLCommandQueue>)[[AkiosMaliCommandQueue alloc] initWithDevice:self descriptor:descriptor];
}

- (id<MTLCommandQueue>)newCommandQueue
{
	return [self newCommandQueueWithDescriptor:[MTLCommandQueueDescriptor new]];
}

- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)count
{
	MTLCommandQueueDescriptor *descriptor = [MTLCommandQueueDescriptor new];

	descriptor.maxCommandBufferCount = count;
	return [self newCommandQueueWithDescriptor:descriptor];
}

/*
 * Buffers: IOGPU's resources (selector 8), made by IOGPUMetalBuffer's initialiser with our (empty, for now) vendor tail
 * after its 0x58-byte header; contents, gpuAddress, purgeability, residency and freeing are IOGPU's. Private storage
 * keeps a processor mapping (0x20000, as AGX asks) while parts of the driver still write such memory themselves. Each
 * buffer of the application's is wrapped for the core (WRAP); the core's own internal ones are not.
 */
- (id<MTLBuffer>)akiosBuffer:(void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options
    deallocator:(void (^)(void *, NSUInteger))deallocator wrap:(BOOL)wrap
{
	uint8_t args[AKIOS_RESOURCE_ARGS_SIZE] = { 0 };
	NSUInteger sysMemSize = pointer != NULL ? length : round_page(length);

	if (length == 0) {
		return nil;
	}
	if ((options & MTLResourceStorageModeMask) == MTLResourceStorageModePrivate) {
		options |= 0x20000;
	}
	AkiosMaliBuffer *buffer = [[AkiosMaliBuffer alloc] initWithDevice:self pointer:pointer length:length alignment:256
	    options:options sysMemSize:sysMemSize gpuAddress:0 args:args argsSize:sizeof(args) deallocator:deallocator];
	if (buffer != nil && wrap && _akCore != NULL) {
		[buffer akWrap:_akCore];
	}
	if (buffer != nil && [buffer gpuAddress] != 0) {
		char what[72];

		snprintf(what, sizeof(what), "%s of %lu bytes%s", wrap ? "a buffer" : "the core's memory", (unsigned long)length,
		    pointer != NULL ? " over the caller's memory" : "");
		akios_live_add((__bridge void *)buffer, [buffer gpuAddress], pointer != NULL ? length : sysMemSize, what);
	} else if (pointer != NULL) {
		akm_say_client_memory(pointer, length, akm_nocopy_caller);
	}
	return (id<MTLBuffer>)buffer;
}

- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	return [self akiosBuffer:NULL length:length options:options deallocator:nil wrap:YES];
}

- (id<MTLBuffer>)newBufferWithBytes:(const void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options
{
	id<MTLBuffer> buffer = [self akiosBuffer:NULL length:length options:options deallocator:nil wrap:YES];

	if (buffer != nil && buffer.contents != NULL) {
		memcpy(buffer.contents, bytes, length);
	}
	return buffer;
}

- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options
    deallocator:(void (^)(void *, NSUInteger))deallocator
{
	akm_nocopy_caller = __builtin_return_address(0);   /* (said by akm_say_client_memory when the kernel refuses it) */
	id<MTLBuffer> buffer = [self akiosBuffer:pointer length:length options:options deallocator:deallocator wrap:YES];
	akm_nocopy_caller = NULL;
	return buffer;
}

@end

/* ---- buffers ---- */

@implementation AkiosMaliBuffer {
	hakios_metal_buffer *_akCore;   /* the core's wrapper over this memory (no memory of its own) */
}

+ (void)load
{
	akios_adopt(self, @protocol(MTLBuffer));
	akios_adopt(self, objc_getProtocol("MTLResourceSPI"));
}

- (void)akWrap:(hakios_metal_device *)core
{
	_akCore = hakios_metal_buffer_wrap(core, [self gpuAddress], [self contents], [self length],
	    [self respondsToSelector:@selector(resourceID)] ? [self resourceID] : 0);
}

- (hakios_metal_buffer *)akCore
{
	return _akCore;
}

- (void)dealloc
{
	/* (a command buffer that used it holds the wrapper, and this object, until it has completed) */
	akios_live_remove((__bridge void *)self);
	hakios_metal_buffer_free(_akCore);
}

@end

/* ---- queues ---- */

@implementation AkiosMaliCommandQueue

+ (void)load
{
	akios_adopt(self, @protocol(MTLCommandQueue));
}

/* neither IOGPU nor Metal makes the command buffers: the vendor's queue does (AGX: initWithQueue:retainedReferences:) */
- (id<MTLCommandBuffer>)commandBuffer
{
	return (id<MTLCommandBuffer>)[[AkiosMaliCommandBuffer alloc] initWithQueue:self retainedReferences:YES];
}

- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences
{
	return (id<MTLCommandBuffer>)[[AkiosMaliCommandBuffer alloc] initWithQueue:self retainedReferences:NO];
}

- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)descriptor
{
	return (id<MTLCommandBuffer>)[[AkiosMaliCommandBuffer alloc] initWithQueue:self
	    retainedReferences:descriptor.retainedReferences];
}

@end

/* ---- command buffers (plan 1.4, 2.3) ---- */

/*
 * THE RESOURCE LIST (phase 6 step F, its resource part; 11-26). IOGPU tells the kernel what a command buffer uses the way
 * AGX does: a segment in the command buffer's segment list (IOGPUMetalCommandBufferStorageBeginSegment/EndSegment, through
 * -beginSegment: / -endCurrentSegment), whose resource list (-ioGPUResourceList, storage + 0x90) gets each resource with
 * IOGPUResourceListAddResource(list, (char *)resource + IVAR(_res) + 0x20, usage) -- the info there: +8 the resident
 * size (low 56 bits), +0x10 the resource ID. The display needs it: with no write listed the kernel cannot hold a swap
 * until the GPU has drawn the surface (the Setup slide's torn black tiles).
 *
 * One segment a command buffer, opened and closed in -commit with every resource the encoders bound (its kernel command
 * range empty: the work stays the tail's one stream). Usage: bit 0 read, bit 1 write -- render attachments (colour,
 * resolve, depth, stencil) and blit destinations write; what a compute function is given read and write (no reflection
 * of what it writes); what draws bind read. The NoThreshold variant: the plain one leaves out a resource past the list's
 * byte budget, and a surface drawn into must never be left out.
 */
extern void IOGPUResourceListAddResourceNoThreshold(void *list, void *info, uint32_t usage);

@interface IOGPUMetalCommandBuffer (Segments)
- (void)getCurrentKernelCommandBufferPointer:(void **)current end:(void **)end;
- (void)beginSegment:(void *)kernelCommands;
- (void)endCurrentSegment;
- (void *)ioGPUResourceList;
@end

static ptrdiff_t
akm_res_offset(void)
{
	static ptrdiff_t offset = -1;

	if (offset < 0) {
		Ivar ivar = class_getInstanceVariable(objc_getClass("IOGPUMetalResource"), "_res");

		offset = ivar != NULL ? ivar_getOffset(ivar) : 0;
	}
	return offset;
}

@implementation AkiosMaliCommandBuffer {
	struct akios_cb_tail _tail;     /* the stream -commit built (0: no GPU work) */
	hakios_metal_cb *_akCore;       /* what the encoders recorded (NULL: the device has no core) */
	NSMutableArray *_akHeld;        /* what the encoders bound, alive until completion (retained or not: see -akHold:) */
	NSMapTable *_akUsage;           /* each IOGPU resource bound -> its usage bits (for the resource list) */
}

+ (void)load
{
	akios_adopt(self, @protocol(MTLCommandBuffer));
}

- (instancetype)initWithQueue:(id)queue retainedReferences:(BOOL)retained
{
	self = [super initWithQueue:queue retainedReferences:retained];
	if (self == nil) {
		return nil;
	}
	hakios_metal_device *core = [(AkiosMaliDevice *)[queue device] akCore];

	_akCore = core != NULL ? hakios_metal_cb_new_external(core) : NULL;
	if (_akCore != NULL) {
		/* (a refused piece of work left out, the rest run -- akios_strict) */
		hakios_metal_cb_skip_refused(_akCore, !akios_strict());
	}
	_akHeld = [NSMutableArray new];
	return self;
}

- (void)dealloc
{
	hakios_metal_cb_free(_akCore);
}

- (hakios_metal_cb *)akCore
{
	return _akCore;
}

/* Kept whatever retainedReferences says: the memory under a resource goes at its -dealloc (trap 1), and the kernel keeps
 * it only for work already SUBMITTED then -- a buffer released between encoding and commit would be gone under the GPU.
 * (Apple's way, a reference per resource taken by the kernel from the segment lists, is step F.) */
- (void)akHold:(id)object
{
	[self akHold:object usage:AKIOS_USE_READ];
}

- (void)akHold:(id)object usage:(unsigned)usage
{
	if (object != nil) {
		@synchronized (_akHeld) {
			[_akHeld addObject:object];
			if ([object isKindOfClass:[IOGPUMetalResource class]]) {
				if (_akUsage == nil) {
					_akUsage = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality |
					    NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsStrongMemory];
				}
				NSNumber *had = [_akUsage objectForKey:object];
				[_akUsage setObject:@(had.unsignedIntValue | usage) forKey:object];
			}
		}
	}
}

/* the segment of every resource bound (above): before IOGPU's commit, which sends the segment list with the command
 * buffer */
- (void)akListResources
{
	void *current = NULL, *end = NULL;
	const ptrdiff_t res = akm_res_offset();
	unsigned listed = 0, written = 0, skipped = 0;

	if (res <= 0) {
		AK_ONCE("refused: IOGPUMetalResource has no _res ivar here: no resource list is sent with command buffers\n");
		return;
	}
	[self getCurrentKernelCommandBufferPointer:&current end:&end];
	if (current == NULL) {
		AK_ONCE("refused: the command buffer has no kernel command buffer: no resource list is sent\n");
		return;
	}
	[self beginSegment:current];
	void *list = [self ioGPUResourceList];
	@synchronized (_akHeld) {
		for (id object in _akUsage) {
			const unsigned usage = [[_akUsage objectForKey:object] unsignedIntValue];
			uint8_t *info = (uint8_t *)(__bridge void *)object + res + 0x20;

			if (*(const uint32_t *)(info + 0x10) == 0) {    /* (no resource ID: not one of the kernel's) */
				skipped++;
				continue;
			}
			IOGPUResourceListAddResourceNoThreshold(list, info, usage);
			listed++;
			written += (usage & AKIOS_USE_WRITE) != 0;
		}
	}
	[self endCurrentSegment];
	static unsigned said;
	if (said < 4 && written != 0) {
		said++;
		akios_say("a command buffer's resource list: %u resources, %u written, %u without an ID left out (one segment)\n", listed,
		    written, skipped);
	}
}

- (void)fillCommandBufferArgs:(void *)args commandQueue:(id)queue
{
	[super fillCommandBufferArgs:args commandQueue:queue];
	memcpy((uint8_t *)args + 0x30, &_tail, sizeof(_tail));
}

/* IOGPU calls this before every event command and at commit: an open encoder's segment is closed here (step F) */
- (void)commitEncoder
{
}

/* The core's work built into a Mali stream (in the core's memory, IOGPU resources of this connection), named in the
 * tail, BEFORE IOGPU's commit: the submission may be batched with others' and calls -fillCommandBufferArgs: then. A
 * command buffer the core refused (a refused copy, dispatch ...) is committed empty and ends in error at completion. */
- (void)commit
{
	[self commitEncoder];
	if (!akios_boot_arg("metal_nolist")) {
		[self akListResources];
	}
	if (_akCore != NULL && !akios_boot_arg("metal_nolivecheck")) {
		/* (11-26) what the work names, still there? A use after free fails the command buffer here, said with what
		 * the memory was -- not a GPU fault that also takes the submissions after it */
		static uint64_t va[1024], size[1024];
		static os_unfair_lock checking = OS_UNFAIR_LOCK_INIT;
		char why[600];

		os_unfair_lock_lock(&checking);
		const unsigned n = hakios_metal_cb_ranges(_akCore, va, size, 1024);
		for (unsigned i = 0; i < n; i++) {
			if (!akios_live_check(va[i], size[i], why, sizeof(why))) {
				static unsigned said;
				const unsigned k = said++;
				if (k < 24 || (k & (k - 1)) == 0) {
					akios_say("refused: a command buffer (%s) whose work uses %s; the command buffer is failed, nothing of it "
					    "goes to the GPU (%u times)\n", [[(id<MTLCommandBuffer>)self label] UTF8String] ?: "no label", why, k + 1);
				}
				hakios_metal_cb_fail(_akCore, "its work uses GPU memory no live resource covers (a use after free)");
				break;
			}
		}
		os_unfair_lock_unlock(&checking);
	}
	if (_akCore != NULL) {
		uint64_t va = 0;
		uint32_t length = 0;

		if (hakios_metal_cb_build(_akCore, &va, &length) == 0) {
			_tail.stream = va;
			_tail.length = length;
		}
	}
	[super commit];
}

/* The core lets go first (kernels, textures, buffers it held, the stream back to its ring), with IOGPU's status: a
 * GPU fault or a refusal by the kernel is the command buffer's error; then IOGPU and Metal (status, error, handlers).
 * A command buffer the core had already failed ends in error with the core's reason. */
- (void)didCompleteWithStartTime:(uint64_t)start endTime:(uint64_t)end error:(NSError *)error
{
	if (_akCore != NULL) {
		uint32_t status = 0;

		if (error != nil) {
			/* (IOGPU's NSError: the kernel's status or Metal's code for it; a page fault either way when Metal's) */
			status = [error.domain isEqualToString:MTLCommandBufferErrorDomain] && error.code == MTLCommandBufferErrorPageFault ?
			    0xb : error.code != 0 ? (uint32_t)error.code : 1;
		}
		if (hakios_metal_cb_retire(_akCore, status) == HAKIOS_METAL_ERROR && error == nil) {
			const char *why = hakios_metal_cb_error(_akCore);

			error = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorInternal
			    userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AkiosMetal: %s", why ? why : "refused"] }];
		}
	}
	[super didCompleteWithStartTime:start endTime:end error:error];
	@synchronized (_akHeld) {
		[_akHeld removeAllObjects];
		[_akUsage removeAllObjects];
	}
}

/* the encoders: ours over IOGPU's bases (plan 1.8); none on a device without its core */
- (id<MTLBlitCommandEncoder>)blitCommandEncoder
{
	if (_akCore == NULL) {
		akios_say("refused: a blit encoder on a device without the Mali core\n");
		return nil;
	}
	return (id<MTLBlitCommandEncoder>)[[AkiosMaliBlitEncoder alloc] initWithAkiosCommandBuffer:self];
}

- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)descriptor
{
	(void)descriptor;   /* (its sample buffers: counters are not served) */
	return [self blitCommandEncoder];
}

- (id<MTLComputeCommandEncoder>)computeCommandEncoder
{
	if (_akCore == NULL) {
		akios_say("refused: a compute encoder on a device without the Mali core\n");
		return nil;
	}
	return (id<MTLComputeCommandEncoder>)[[AkiosMaliComputeEncoder alloc] initWithAkiosCommandBuffer:self];
}

/* sparse textures (the resource state encoder's work) are not served */
- (id<MTLResourceStateCommandEncoder>)resourceStateCommandEncoder
{
	AK_ONCE("refused: a resource state encoder (sparse textures are not served); it returns nil\n");
	return nil;
}

/* (concurrent dispatch is served as serial: stricter ordering than asked for) */
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)type
{
	(void)type;
	return [self computeCommandEncoder];
}

- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)descriptor
{
	(void)descriptor;
	return [self computeCommandEncoder];
}

@end
