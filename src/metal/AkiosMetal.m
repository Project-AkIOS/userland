/*
 * AkiosMetal: Metal's plug-in for the Mali-G715, built the way Apple's AGXMetal is -- its classes are subclasses of
 * IOGPU.framework's IOGPUMetal* classes, which talk to the kernel's IOGPU (akios_iogpu.cpp) for memory, queues,
 * submission, completion and events. What is ours is the Mali's command generation, the compiler and the formats.
 *
 * Step A of the plan (ref/iogpu-research/phase6-plan.md): the device, its queues and command buffers; an empty
 * command buffer goes through IOGPU's own submission and completion. Encoders, buffers and textures follow.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOKit/IOKitLib.h>
#include <objc/runtime.h>

/* ---- IOGPU.framework's classes (no public headers): what is called or overridden here ---- */

@interface IOGPUMetalDevice : NSObject
- (instancetype)initWithAcceleratorPort:(io_service_t)port;
@end

@interface IOGPUMetalCommandQueue : NSObject
- (instancetype)initWithDevice:(id)device descriptor:(MTLCommandQueueDescriptor *)descriptor;
@end

@interface IOGPUMetalCommandBuffer : NSObject
- (instancetype)initWithQueue:(id)queue retainedReferences:(BOOL)retained;
- (void)fillCommandBufferArgs:(void *)args commandQueue:(id)queue;
@end

/* ---- the classes ---- */

@interface AkiosMaliDevice : IOGPUMetalDevice
@end

@interface AkiosMaliCommandQueue : IOGPUMetalCommandQueue
@end

@interface AkiosMaliCommandBuffer : IOGPUMetalCommandBuffer
@end

/* the tail of a command buffer's arguments that is ours (after IOGPU's 0x30 bytes): what the GPU runs */
struct akios_cb_tail {
	uint64_t stream;                /* the Mali command stream's GPU address (0: no GPU work) */
	uint32_t length;                /* its length in bytes */
	uint32_t flags;
};
#define AKIOS_CB_ARGS_SIZE      (0x30 + sizeof(struct akios_cb_tail))

@implementation AkiosMaliDevice

+ (void)load
{
	/* IOGPUMetalDevice asserts that its device conforms to MTLDeviceSPI (a vendor's class declares it) */
	Protocol *spi = objc_getProtocol("MTLDeviceSPI");

	if (spi != NULL) {
		class_addProtocol(self, spi);
	}
}

- (instancetype)initWithAcceleratorPort:(io_service_t)port
{
	return [super initWithAcceleratorPort:port];
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

@end

@implementation AkiosMaliCommandQueue

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

@implementation AkiosMaliCommandBuffer {
	struct akios_cb_tail _tail;     /* filled by commit once encoders build a stream (step C) */
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

@end
