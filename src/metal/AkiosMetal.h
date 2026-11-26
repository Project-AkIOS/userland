/*
 * AkiosMetal.h: what the plug-in's files share -- the declarations of IOGPU.framework's and Metal's private base classes
 * that are called or overridden (no public headers; types from the method encodings on the phone or from the callers in
 * IOGPU.framework/AGXMetalG14, ref/iogpu-research/phase6-plan.md), and our classes' interfaces.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOKit/IOKitLib.h>
#include <IOSurface/IOSurfaceRef.h>
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
- (instancetype)initWithDevice:(id)device descriptor:(MTLTextureDescriptor *)descriptor iosurface:(IOSurfaceRef)surface
    plane:(NSUInteger)plane field:(NSUInteger)field args:(void *)args argsSize:(NSUInteger)argsSize;
- (instancetype)initWithTexture:(id)texture pixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type
    levels:(NSRange)levels slices:(NSRange)slices;
- (instancetype)initWithBuffer:(id)buffer descriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset
    bytesPerRow:(NSUInteger)bytesPerRow;
- (instancetype)initWithTexture:(id)texture pixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type
    levels:(NSRange)levels slices:(NSRange)slices swizzle:(MTLTextureSwizzleChannels)swizzle;
/* (IOGPU's answers, from the descriptor) */
- (NSUInteger)width;
- (NSUInteger)height;
- (NSUInteger)depth;
- (NSUInteger)sampleCount;
- (NSUInteger)arrayLength;
- (NSUInteger)mipmapLevelCount;
- (NSUInteger)bufferBytesPerRow;
- (MTLPixelFormat)pixelFormat;
- (MTLTextureType)textureType;
- (MTLTextureUsage)usage;
- (IOSurfaceRef)iosurface;
- (NSUInteger)iosurfacePlane;
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

@interface IOGPUMetalRenderCommandEncoder : IOGPUMetalCommandEncoder
/* (the base keeps nothing of the descriptor: 20d2e0a30) */
- (instancetype)initWithCommandBuffer:(id)commandBuffer descriptor:(MTLRenderPassDescriptor *)descriptor;
@end

@interface IOGPUMetalParallelRenderCommandEncoder : IOGPUMetalCommandEncoder
- (instancetype)initWithCommandBuffer:(id)commandBuffer renderPassDescriptor:(MTLRenderPassDescriptor *)descriptor;
@end

/* Metal's base of a render pipeline state (what AGX's sends to super; it asserts on a nil device or descriptor) */
@interface _MTLRenderPipelineState : NSObject
- (instancetype)initWithDevice:(id)device pipelineStateDescriptor:(id)descriptor;
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
/* once a process (a line about a refusal that would otherwise repeat every frame) */
#define AK_ONCE(...) do { static int ak_said_; if (!ak_said_) { ak_said_ = 1; akios_say(__VA_ARGS__); } } while (0)
/* a word in the boot-args (read once a process) */
BOOL akios_boot_arg(const char *word);
/* PROTOCOL declared by CLS at run time (the public Metal protocols are the GPU bundle's on this phone: see AkiosMetal.m) */
void akios_adopt(Class cls, Protocol *protocol);
/* a refused draw, dispatch or copy fails its command buffer (boot-arg metal_strict, or AKIOS_METAL_STRICT=1 in the
 * environment); otherwise it is left out and the rest runs, as Apple's driver runs a frame whatever is wrong in it */
BOOL akios_strict(void);
/* (AkiosMetalRender.m) the fragment constants a program was linked with, for the draw trace; whether it is on */
void akm_note_constants(const void *program, NSString *constants);
BOOL akm_tracing(void);
/* (AkiosMetalPipelines.m) -[_MTLFunction newArgumentEncoderWithBufferIndex:] answered from the function's AIR for this
 * device's functions (Metal's own needs its compiler's reflection, which this device has not got) */
void akm_functions_encode_from_metadata(void);
/* (AkiosMetalPipelines.m) CoreAnimation's functions the given library lacks or has unusable, answered by stand-ins */
void akm_library_stand_ins(void);
/* the number a texture, sampler or pipeline is told apart by while it lives: a counter from 1, never an address */
uint64_t akios_next_id(void);
/* a function's specialisation (MTLFunctionConstantValues) as the core takes it: at most MAX into OUT, the count */
unsigned akios_function_constants(id function, hakios_metal_constant *out, unsigned max);

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
- (void)akSetCore:(hakios_metal_texture *)core;
- (void)akSetUsage:(MTLTextureUsage)usage;
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

/* depth/stencil and render pipeline states (AkiosMetalPipelines.m, AkiosMetalRender.m) */
@interface AkiosMaliDepthStencilState : NSObject <MTLDepthStencilState> {
	__weak id<MTLDevice> _device;
	NSString *_label;
	unsigned _compare;
	BOOL _write;
	BOOL _stencil;
	struct hakios_metal_stencil_face _front, _back;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device descriptor:(MTLDepthStencilDescriptor *)descriptor;
- (unsigned)akDepthCompare;
- (BOOL)akDepthWrite;
- (BOOL)akStencil;
- (const struct hakios_metal_stencil_face *)akStencilFront;
- (const struct hakios_metal_stencil_face *)akStencilBack;
@end

@interface AkiosMaliRenderPipelineState : _MTLRenderPipelineState {
	AkiosMaliDevice *_akDevice;
	hakios_metal_program *_program;
	uint64_t _akUniqueIdentifier;   /* the base's uniqueIdentifier is a nil-stub; see the sampler */
	/* an uber shader's specialisations (akProgramFor:): its fragment bitcode and constants, the constant buffer
	 * whose bytes choose its path, and the programs compiled for each content seen (NSNull while one compiles) */
	NSData *_fsAir;
	hakios_metal_constant _fsConstants[64];
	unsigned _fsConstantCount;
	int _specBinding;
	unsigned _specLength;
	NSMutableDictionary *_specialised;
	char _standIn[256];                 /* not empty: a stand-in, no program -- why it could not be built (akm_stand_in) */
}
- (instancetype)initWithAkiosDevice:(AkiosMaliDevice *)device program:(hakios_metal_program *)program
			  descriptor:(MTLRenderPipelineDescriptor *)descriptor;
- (hakios_metal_program *)akProgram;
- (void)akSetStandIn:(const char *)why;
- (const char *)akStandIn;          /* NULL for a real pipeline */
- (void)akSetProgram:(hakios_metal_program *)program;      /* a background compile's result: no longer a stand-in */
- (hakios_metal_program *)akTakeProgram;                   /* its program, given up (the state then has none) */
- (void)akKeepFragment:(NSData *)air constants:(const hakios_metal_constant *)constants count:(unsigned)count;
- (hakios_metal_program *)akProgramFor:(hakios_metal_buffer *const *)buffers offsets:(const uint64_t *)offsets count:(unsigned)count;
- (void)akAdoptSpecialisationOf:(AkiosMaliRenderPipelineState *)real;   /* a background compile's kept fragment */
@end
