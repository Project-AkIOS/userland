/*
 * AkiosMetal.h: what the plug-in's files share -- the declarations of IOGPU.framework's and Metal's private base classes
 * that are called or overridden (no public headers; types from the method encodings on the phone or from the callers in
 * IOGPU.framework/AGXMetalG14, ref/iogpu-research/phase6-plan.md), and our classes' interfaces.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOKit/IOKitLib.h>
#include <objc/runtime.h>
#include <stdbool.h>

#include "hakios-metal/hakios_metal.h"

/* ---- IOGPU.framework ---- */

extern io_connect_t IOGPUDeviceGetConnect(void *device);

@interface IOGPUMetalDevice : NSObject
- (instancetype)initWithAcceleratorPort:(io_service_t)port;
- (void *)deviceRef;
@end

@interface IOGPUMetalResource : NSObject
- (uint64_t)gpuAddress;
- (uint64_t)virtualAddress;
- (uint32_t)resourceID;
@end

@interface IOGPUMetalBuffer : IOGPUMetalResource
/* (types from the method's encoding on the phone: alignment and argsSize are 32-bit) */
- (instancetype)initWithDevice:(id)device pointer:(void *)pointer length:(NSUInteger)length alignment:(uint32_t)alignment
    options:(NSUInteger)options sysMemSize:(NSUInteger)sysMemSize gpuAddress:(uint64_t)gpuAddress args:(void *)args
    argsSize:(uint32_t)argsSize deallocator:(void (^)(void *pointer, NSUInteger length))deallocator;
- (void *)contents;
- (NSUInteger)length;
@end

@interface IOGPUMetalTexture : IOGPUMetalResource
/* (AGX's call shape, 24782c67c; every integer passed as 64 bits, which a 32-bit parameter reads as well) */
- (instancetype)initWithDevice:(id)device descriptor:(MTLTextureDescriptor *)descriptor sysMemSize:(NSUInteger)sysMemSize
    sysMemRowBytes:(NSUInteger)sysMemRowBytes vidMemSize:(NSUInteger)vidMemSize vidMemRowBytes:(NSUInteger)vidMemRowBytes
    args:(void *)args argsSize:(NSUInteger)argsSize;
@end

@interface IOGPUMetalCommandQueue : NSObject
- (instancetype)initWithDevice:(id)device descriptor:(MTLCommandQueueDescriptor *)descriptor;
- (id)device;
@end

@interface IOGPUMetalCommandBuffer : NSObject
- (instancetype)initWithQueue:(id)queue retainedReferences:(BOOL)retained;
- (void)fillCommandBufferArgs:(void *)args commandQueue:(id)queue;
- (void)commit;
- (void)commitEncoder;
/* the queue's completion (an IOGPU notification) hands the times as mach ticks and an NSError for a non-zero status
 * (x2, x3, x4: read at 20d2c9788 in IOGPU.framework) */
- (void)didCompleteWithStartTime:(uint64_t)start endTime:(uint64_t)end error:(NSError *)error;
- (id)device;
@end

@interface IOGPUMetalCommandEncoder : NSObject
- (instancetype)initWithCommandBuffer:(id)commandBuffer;
- (void)endEncoding;
@end

@interface IOGPUMetalBlitCommandEncoder : IOGPUMetalCommandEncoder
@end

@interface IOGPUMetalComputeCommandEncoder : IOGPUMetalCommandEncoder
@end

/* ---- Metal.framework's private bases (what Apple's own driver sends to super) ---- */

@interface _MTLComputePipelineState : NSObject
- (instancetype)initWithDevice:(id)device pipelineStateDescriptor:(id)descriptor;
@end

/* (its initialiser asserts on what it does not take: every field is checked before super is given the descriptor) */
@interface _MTLSamplerState : NSObject
- (instancetype)initWithDevice:(id)device samplerDescriptor:(id)descriptor;
@end

/* ---- ours ---- */

/* the tail of a command buffer's arguments that is ours (after IOGPU's 0x30 bytes): what the GPU runs */
struct akios_cb_tail {
	uint64_t stream;                /* the Mali command stream's GPU address (0: no GPU work) */
	uint32_t length;                /* its length in bytes */
	uint32_t flags;
};
#define AKIOS_CB_ARGS_SIZE              (0x30 + sizeof(struct akios_cb_tail))
#define AKIOS_RESOURCE_ARGS_SIZE        0x58

/* Metal's tables, as the earlier plug-in had them (31 buffers, 128 textures, 16 samplers a stage) */
#define AKIOS_MAX_BUFFERS       31
#define AKIOS_MAX_TEXTURES      128
#define AKIOS_MAX_SAMPLERS      16

void akios_say(const char *format, ...) __attribute__((format(printf, 1, 2)));

@interface AkiosMaliDevice : IOGPUMetalDevice
- (hakios_metal_device *)akCore;
@end

@interface AkiosMaliCommandQueue : IOGPUMetalCommandQueue
@end

@interface AkiosMaliBuffer : IOGPUMetalBuffer
- (hakios_metal_buffer *)akCore;
@end

@interface AkiosMaliTexture : IOGPUMetalTexture
- (hakios_metal_texture *)akCore;
- (BOOL)akWrap:(hakios_metal_device *)core layout:(const struct hakios_metal_texture_layout *)layout;
@end

@interface AkiosMaliCommandBuffer : IOGPUMetalCommandBuffer
- (hakios_metal_cb *)akCore;
/* OBJECT kept alive until the command buffer has completed (what its encoders bound) */
- (void)akHold:(id)object;
@end

@interface AkiosMaliBlitEncoder : IOGPUMetalBlitCommandEncoder
- (instancetype)initWithAkiosCommandBuffer:(AkiosMaliCommandBuffer *)commandBuffer;
@end

@interface AkiosMaliComputeEncoder : IOGPUMetalComputeCommandEncoder
- (instancetype)initWithAkiosCommandBuffer:(AkiosMaliCommandBuffer *)commandBuffer;
@end

@interface AkiosMaliSamplerState : _MTLSamplerState
- (instancetype)initWithAkiosDevice:(AkiosMaliDevice *)device sampler:(hakios_metal_sampler *)sampler
    descriptor:(MTLSamplerDescriptor *)descriptor;
- (hakios_metal_sampler *)akCore;
@end

@interface AkiosMaliComputePipelineState : _MTLComputePipelineState
- (instancetype)initWithAkiosDevice:(AkiosMaliDevice *)device kernel:(hakios_metal_kernel *)kernel descriptor:(id)descriptor;
- (hakios_metal_kernel *)akCore;
@end

/* the device's pipelines, samplers (AkiosMetalState.m) */
@interface AkiosMaliDevice (States)
- (id)akComputePipelineForFunction:(id)function descriptor:(id)descriptor error:(NSError **)error;
@end
