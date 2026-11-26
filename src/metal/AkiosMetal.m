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

#include <stdarg.h>
#include <stdio.h>
#include <sys/sysctl.h>

void
akios_say(const char *format, ...)
{
	char line[512];
	va_list ap;

	va_start(ap, format);
	vsnprintf(line, sizeof(line), format, ap);
	va_end(ap);
	fprintf(stderr, "AkiosMetal: %s: %s", getprogname(), line);
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
- (instancetype)initWithAcceleratorPort:(io_service_t)port
{
	self = [super initWithAcceleratorPort:port];
	if (self == nil) {
		return nil;
	}
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
	return [self akiosBuffer:pointer length:length options:options deallocator:deallocator wrap:YES];
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

@implementation AkiosMaliCommandBuffer {
	struct akios_cb_tail _tail;     /* the stream -commit built (0: no GPU work) */
	hakios_metal_cb *_akCore;       /* what the encoders recorded (NULL: the device has no core) */
	NSMutableArray *_akHeld;        /* what the encoders bound, alive until completion (retained or not: see -akHold:) */
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
	if (object != nil) {
		@synchronized (_akHeld) {
			[_akHeld addObject:object];
		}
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
