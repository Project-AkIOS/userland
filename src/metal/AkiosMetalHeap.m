/*
 * AkiosMetalHeap.m: heaps, as the earlier plug-in made them (HakiosMetalCA.m, HakiosMetalHeap): a budget over the
 * device's own allocations -- each buffer or texture from a heap is an IOGPU resource of its own, counted against the
 * heap's size; placement (an offset) is refused by name.
 *
 * Not IOGPUMetalHeap (phase6-plan 1.7): its sub-resource initialisers' arguments are inferred, not traced (plan risk
 * 4.5: initWithHeap:resource:offset:length:..., the heap's _resource), and a wrong guess crashes the client. This is
 * the shape that ran on the phone; the IOGPU heap comes when those calls are read in AGX.
 */
#import "AkiosMetal.h"

@interface AkiosMaliHeap : NSObject <MTLHeap> {
	__weak id<MTLDevice> _device;
	NSString *_label;
	MTLHeapDescriptor *_descriptor;
	NSUInteger _used;
}
- (instancetype)initWithDevice:(id)device descriptor:(MTLHeapDescriptor *)descriptor;
@end

@implementation AkiosMaliHeap

/* MPS asks a heap Apple's SPI (-protectionOptions first): declared, and answered below */
+ (void)load
{
	Protocol *spi = objc_getProtocol("MTLHeapSPI");

	if (spi != NULL) {
		class_addProtocol(self, spi);
	}
}

- (instancetype)initWithDevice:(id)device descriptor:(MTLHeapDescriptor *)descriptor
{
	self = [super init];
	if (self != nil) {
		_device = device;
		_descriptor = [descriptor copy];
	}
	return self;
}
- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (MTLStorageMode)storageMode { return [_descriptor storageMode]; }
- (MTLCPUCacheMode)cpuCacheMode { return [_descriptor cpuCacheMode]; }
- (MTLHazardTrackingMode)hazardTrackingMode { return [_descriptor hazardTrackingMode]; }
- (MTLResourceOptions)resourceOptions { return [_descriptor resourceOptions]; }
- (MTLHeapType)type { return [_descriptor type]; }
- (NSUInteger)protectionOptions { return 0; }   /* no protected memory on this port, as a texture answers */
- (NSUInteger)size { return [_descriptor size]; }
- (NSUInteger)usedSize { return _used; }
- (NSUInteger)currentAllocatedSize { return [_descriptor size]; }
- (NSUInteger)maxAvailableSizeWithAlignment:(NSUInteger)alignment
{
	(void)alignment;
	return [_descriptor size] > _used ? [_descriptor size] - _used : 0;
}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { (void)state; return MTLPurgeableStateNonVolatile; }

/* a resource from the budget: the device's own allocation, refused (nil) when it would overrun the heap, as Metal's is */
- (id)akCounted:(id)resource
{
	NSUInteger size = resource != nil ? [(id<MTLResource>)resource allocatedSize] : 0;

	if (resource == nil) return nil;
	if (_used + size > [_descriptor size]) {
		return nil;
	}
	_used += size;
	return resource;
}
- (id)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	return [self akCounted:[_device newBufferWithLength:length options:options]];
}
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
{
	return [self akCounted:[_device newTextureWithDescriptor:descriptor]];
}
- (id)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options offset:(NSUInteger)offset
{
	(void)length; (void)options; (void)offset;
	akios_say("refused: a buffer at an offset of a heap: placement is not served (every resource is its own allocation); it returns nil\n");
	return nil;
}
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset
{
	(void)descriptor; (void)offset;
	akios_say("refused: a texture at an offset of a heap: placement is not served (every resource is its own allocation); it returns nil\n");
	return nil;
}
/* acceleration structures belong to ray tracing, which this GPU's path does not have (the device has none either) */
- (id)newAccelerationStructureWithSize:(NSUInteger)size { (void)size; return [self akNoRayTracing]; }
- (id)newAccelerationStructureWithDescriptor:(MTLAccelerationStructureDescriptor *)d { (void)d; return [self akNoRayTracing]; }
- (id)newAccelerationStructureWithSize:(NSUInteger)size offset:(NSUInteger)offset { (void)size; (void)offset; return [self akNoRayTracing]; }
- (id)newAccelerationStructureWithDescriptor:(MTLAccelerationStructureDescriptor *)d offset:(NSUInteger)offset
{
	(void)d; (void)offset;
	return [self akNoRayTracing];
}
- (id)akNoRayTracing
{
	akios_say("refused: an acceleration structure from a heap: no ray tracing on this GPU's path; it returns nil\n");
	return nil;
}
@end

@implementation AkiosMaliDevice (Heaps)

- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)descriptor
{
	MTLTextureUsage usage = [descriptor usage] & ~(MTLTextureUsage)MTLTextureUsagePixelFormatView;
	const MTLTextureType type = [descriptor textureType];
	const BOOL depth = [descriptor pixelFormat] == MTLPixelFormatDepth32Float || [descriptor pixelFormat] == MTLPixelFormatDepth32Float_Stencil8;
	const unsigned layers = type == MTLTextureType2DArray || type == MTLTextureType1DArray ? (unsigned)[descriptor arrayLength] :
				type == MTLTextureTypeCubeArray ? (unsigned)[descriptor arrayLength] * 6 : type == MTLTextureTypeCube ? 6 :
				type == MTLTextureType3D ? (unsigned)[descriptor depth] : 1;
	uint64_t bytes = 0;

	/* (the usage only decides what the plan accepts, not its bytes: Unknown is resolved as creation resolves it) */
	if (usage == MTLTextureUsageUnknown) {
		usage = depth || type == MTLTextureType2DMultisample ? MTLTextureUsageRenderTarget : MTLTextureUsageShaderRead;
	}
	if (type == MTLTextureType2DMultisample) {
		usage &= ~(MTLTextureUsage)MTLTextureUsageShaderWrite;
	}
	if (hakios_metal_texture_plan_bytes((unsigned)type, (unsigned)[descriptor pixelFormat], (unsigned)[descriptor width],
					    (unsigned)[descriptor height], layers, (unsigned)[descriptor mipmapLevelCount],
					    (unsigned)[descriptor sampleCount], (unsigned)usage, &bytes) != 0) {
		akios_say("refused: -heapTextureSizeAndAlignWithDescriptor: of %lux%lu, pixel format %lu, type %lu: %s; it answers 0 bytes\n",
			 (unsigned long)[descriptor width], (unsigned long)[descriptor height], (unsigned long)[descriptor pixelFormat],
			 (unsigned long)type, hakios_metal_error());
		return (MTLSizeAndAlign){ 0, 4096 };
	}
	return (MTLSizeAndAlign){ (NSUInteger)bytes, 4096 };
}

- (MTLSizeAndAlign)heapBufferSizeAndAlignWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	(void)options;
	return (MTLSizeAndAlign){ length, 256 };   /* a buffer's allocatedSize is its length */
}

- (id)newHeapWithDescriptor:(MTLHeapDescriptor *)descriptor
{
	if (descriptor == nil || [descriptor type] == MTLHeapTypePlacement) {
		akios_say("refused: a heap of type %ld: a placement heap puts resources at offsets of one allocation, and every resource "
			 "here is an allocation of its own; it returns nil\n", descriptor != nil ? (long)[descriptor type] : -1L);
		return nil;
	}
	return [[AkiosMaliHeap alloc] initWithDevice:self descriptor:descriptor];
}

@end
