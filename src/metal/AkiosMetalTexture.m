/*
 * AkiosMetalTexture.m: textures (plan 1.6, 2.2). The core plans the layout (every level, layer, sample, stencil plane
 * and the plane descriptors), IOGPUMetalTexture's initialiser makes the resource of that size and row pitch (kind 0,
 * AGX's call shape), and the core wraps the memory. Width, height, format, usage, storage ... are IOGPU's answers;
 * the bytes (replaceRegion / getBytes) go through the core's layout.
 */
#import "AkiosMetal.h"

static BOOL
akios_layered(unsigned type)
{
	return type == MTLTextureType1DArray || type == MTLTextureType2DArray || type == MTLTextureTypeCube ||
	    type == MTLTextureTypeCubeArray;
}

@implementation AkiosMaliTexture {
	hakios_metal_texture *_akCore;
	MTLTextureUsage _akUsage;       /* the usage it was made with (0: IOGPU's answer) */
}

/*
 * THE USAGE (11-26): IOGPUMetalTexture's IOSurface initialiser answers -usage 0 whatever the descriptor said (D1 on the
 * phone: a render target refused as "made with usage 0"), so the usage the texture was made with is kept here and
 * answered; the core's texture carries the same bits.
 */
- (void)akSetUsage:(MTLTextureUsage)usage
{
	_akUsage = usage;
}

- (MTLTextureUsage)usage
{
	return _akUsage != 0 ? _akUsage : [super usage];
}

/* -[MTLRenderPassColorAttachmentDescriptorInternal setTexture:] asserts conformance to MTLTextureImplementation */
+ (void)load
{
	akios_adopt(self, @protocol(MTLTexture));
	akios_adopt(self, objc_getProtocol("MTLTextureSPI"));
	akios_adopt(self, objc_getProtocol("MTLTextureImplementation"));
	akios_adopt(self, objc_getProtocol("MTLResourceSPI"));
}

- (void)akSetCore:(hakios_metal_texture *)core
{
	_akCore = core;
}

/* --- views (plan 1.6): IOGPU's view of the same resource, the core's view of the same memory --- */

- (id<MTLTexture>)akViewWithPixelFormat:(MTLPixelFormat)format type:(MTLTextureType)type levels:(NSRange)levels slices:(NSRange)slices
    swizzle:(const MTLTextureSwizzleChannels *)swizzle
{
	hakios_metal_texture *view = hakios_metal_texture_new_view(_akCore, (unsigned)format, (unsigned)type, (unsigned)levels.location,
	    (unsigned)levels.length, (unsigned)slices.location, (unsigned)slices.length);
	const BOOL turned = swizzle != NULL && !(swizzle->red == MTLTextureSwizzleRed && swizzle->green == MTLTextureSwizzleGreen &&
	    swizzle->blue == MTLTextureSwizzleBlue && swizzle->alpha == MTLTextureSwizzleAlpha);

	if (view != NULL && turned) {
		hakios_metal_texture *swizzled = hakios_metal_texture_new_swizzled(view, swizzle->red, swizzle->green, swizzle->blue,
		    swizzle->alpha);

		hakios_metal_texture_free(view);
		view = swizzled;
	}
	if (view == NULL) {
		akios_say("refused: a texture view of pixel format %lu, type %lu, levels %lu+%lu, slices %lu+%lu: %s\n", (unsigned long)format,
		    (unsigned long)type, (unsigned long)levels.location, (unsigned long)levels.length, (unsigned long)slices.location,
		    (unsigned long)slices.length, hakios_metal_error());
		return nil;
	}
	AkiosMaliTexture *made = swizzle != NULL ?
	    [[AkiosMaliTexture alloc] initWithTexture:self pixelFormat:format textureType:type levels:levels slices:slices swizzle:*swizzle] :
	    [[AkiosMaliTexture alloc] initWithTexture:self pixelFormat:format textureType:type levels:levels slices:slices];
	if (made == nil) {
		hakios_metal_texture_free(view);
		return nil;
	}
	[made akSetCore:view];
	[made akSetUsage:[self usage]];
	return (id<MTLTexture>)made;
}

- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format
{
	const NSUInteger slices = [self textureType] == MTLTextureType3D ? 1 : MAX(hakios_metal_texture_depth(_akCore), 1u);

	return [self akViewWithPixelFormat:format type:[self textureType] levels:NSMakeRange(0, [self mipmapLevelCount])
	    slices:NSMakeRange(0, akios_layered((unsigned)[self textureType]) ? slices : 1) swizzle:NULL];
}

- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type levels:(NSRange)levels
    slices:(NSRange)slices
{
	return [self akViewWithPixelFormat:format type:type levels:levels slices:slices swizzle:NULL];
}

- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type levels:(NSRange)levels
    slices:(NSRange)slices swizzle:(MTLTextureSwizzleChannels)swizzle
{
	return [self akViewWithPixelFormat:format type:type levels:levels slices:slices swizzle:&swizzle];
}

- (BOOL)akWrap:(hakios_metal_device *)core layout:(const struct hakios_metal_texture_layout *)layout
{
	uint64_t gpu = [self gpuAddress];
	uint64_t cpu = [self respondsToSelector:@selector(virtualAddress)] ? [self virtualAddress] : 0;

	/* (a system-memory resource is mapped into the task at its GPU address: akios_iogpu.cpp s_new_resource) */
	_akCore = hakios_metal_texture_wrap(core, layout, gpu, (void *)(uintptr_t)(cpu != 0 ? cpu : gpu));
	return _akCore != NULL;
}

- (hakios_metal_texture *)akCore
{
	return _akCore;
}

- (void)dealloc
{
	hakios_metal_texture_free(_akCore);   /* (a command buffer that uses it holds the wrapper until it has completed) */
}

/* what an argument buffer holds for the texture (the core's id, found again by a dispatch reading it) */
- (MTLResourceID)gpuResourceID
{
	MTLResourceID rid = { hakios_metal_texture_resource_id(_akCore) };

	return rid;
}

/* --- the bytes, through the core's layout (IOGPU's short forms forward to the vendor; both forms answered here) --- */

- (BOOL)akRegion:(MTLRegion)region level:(NSUInteger)level slice:(NSUInteger)slice bytes:(const void *)bytes what:(const char *)what
{
	const unsigned type = hakios_metal_texture_type(_akCore);

	if (_akCore == NULL || bytes == NULL || level >= hakios_metal_texture_levels(_akCore) ||
	    (slice != 0 && !(akios_layered(type) && slice < hakios_metal_texture_depth(_akCore)))) {
		akios_say("refused: %s of level %lu, slice %lu: not in this texture; nothing is copied\n", what, (unsigned long)level,
		    (unsigned long)slice);
		return NO;
	}
	if ((region.origin.z != 0 || region.size.depth != 1) && type != MTLTextureType3D) {
		akios_say("refused: %s of a region at z %lu with depth %lu of a texture that is not 3D; nothing is copied\n", what,
		    (unsigned long)region.origin.z, (unsigned long)region.size.depth);
		return NO;
	}
	return YES;
}

- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level withBytes:(const void *)bytes bytesPerRow:(NSUInteger)bytesPerRow
{
	[self replaceRegion:region mipmapLevel:level slice:0 withBytes:bytes bytesPerRow:bytesPerRow bytesPerImage:0];
}

- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)bytes
    bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage
{
	const unsigned type = hakios_metal_texture_type(_akCore);
	int r;

	if (![self akRegion:region level:level slice:slice bytes:bytes what:"replaceRegion"]) {
		return;
	}
	if (akios_layered(type) || type == MTLTextureType3D) {
		const BOOL planes = type == MTLTextureType3D;

		r = hakios_metal_texture_replace_3d(_akCore, (unsigned)level, (unsigned)region.origin.x, (unsigned)region.origin.y,
		    (unsigned)(planes ? region.origin.z : slice), (unsigned)region.size.width, (unsigned)region.size.height,
		    planes ? (unsigned)region.size.depth : 1, bytes, bytesPerRow, bytesPerImage);
	} else {
		r = hakios_metal_texture_replace_level(_akCore, (unsigned)level, (unsigned)region.origin.x, (unsigned)region.origin.y,
		    (unsigned)region.size.width, (unsigned)region.size.height, bytes, bytesPerRow);
	}
	if (r != 0) {
		akios_say("refused: replaceRegion of %lux%lu at (%lu, %lu): %s\n", (unsigned long)region.size.width,
		    (unsigned long)region.size.height, (unsigned long)region.origin.x, (unsigned long)region.origin.y, hakios_metal_error());
	}
}

- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bytesPerRow fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level
{
	[self getBytes:bytes bytesPerRow:bytesPerRow bytesPerImage:0 fromRegion:region mipmapLevel:level slice:0];
}

- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage fromRegion:(MTLRegion)region
    mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
{
	const unsigned type = hakios_metal_texture_type(_akCore);
	int r;

	if (![self akRegion:region level:level slice:slice bytes:bytes what:"getBytes"]) {
		return;
	}
	if (akios_layered(type) || type == MTLTextureType3D) {
		const BOOL planes = type == MTLTextureType3D;

		r = hakios_metal_texture_read_3d(_akCore, (unsigned)level, (unsigned)region.origin.x, (unsigned)region.origin.y,
		    (unsigned)(planes ? region.origin.z : slice), (unsigned)region.size.width, (unsigned)region.size.height,
		    planes ? (unsigned)region.size.depth : 1, bytes, bytesPerRow, bytesPerImage);
	} else {
		r = hakios_metal_texture_read_level(_akCore, (unsigned)level, (unsigned)region.origin.x, (unsigned)region.origin.y,
		    (unsigned)region.size.width, (unsigned)region.size.height, bytes, bytesPerRow);
	}
	if (r != 0) {
		akios_say("refused: getBytes of %lux%lu at (%lu, %lu): %s\n", (unsigned long)region.size.width,
		    (unsigned long)region.size.height, (unsigned long)region.origin.x, (unsigned long)region.origin.y, hakios_metal_error());
	}
}

@end

@implementation AkiosMaliDevice (Textures)

/*
 * A plain texture (not over an IOSurface, a buffer or a heap: step D). The descriptor is checked as the earlier plug-in
 * checked it, the core plans the layout, IOGPU makes the resource. Private and memoryless storage are given shared
 * memory (the core writes the plane descriptors with the CPU; the earlier plug-in did the same for every texture).
 */
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
{
	hakios_metal_device *core = [self akCore];
	struct hakios_metal_texture_layout layout;

	if (core == NULL || descriptor == nil || ![descriptor isKindOfClass:[MTLTextureDescriptor class]]) {
		akios_say("refused: a texture: %s\n", core == NULL ? "no Mali core on this device" : "no texture descriptor");
		return nil;
	}
	const MTLTextureType type = descriptor.textureType;
	if (type > MTLTextureType3D || descriptor.width > 0xffffffffUL || descriptor.height > 0xffffffffUL ||
	    (descriptor.sampleCount != 1) != (type == MTLTextureType2DMultisample) ||
	    (descriptor.depth != 1 && type != MTLTextureType3D)) {
		akios_say("refused: a texture of type %lu, %lux%lux%lu, %lu samples\n", (unsigned long)type, (unsigned long)descriptor.width,
		    (unsigned long)descriptor.height, (unsigned long)descriptor.depth, (unsigned long)descriptor.sampleCount);
		return nil;
	}
	MTLTextureUsage usage = descriptor.usage & ~(MTLTextureUsage)MTLTextureUsagePixelFormatView & (MTLTextureUsage)0xffff;
	if (usage == MTLTextureUsageUnknown) {
		/* (Metal's default lets a texture be used every way: read, written, drawn into -- a depth one an attachment) */
		usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
		if (descriptor.pixelFormat == MTLPixelFormatDepth32Float || descriptor.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
			usage = MTLTextureUsageRenderTarget;
		}
	}
	const BOOL faces = type == MTLTextureTypeCube || type == MTLTextureTypeCubeArray;
	const NSUInteger depth = type == MTLTextureType3D ? descriptor.depth : type == MTLTextureTypeCube ? 6 :
	    akios_layered((unsigned)type) ? descriptor.arrayLength * (faces ? 6 : 1) : 1;
	const NSUInteger height = faces ? descriptor.width : type == MTLTextureType1DArray || type == MTLTextureType1D ? 1 :
	    descriptor.height;
	if (hakios_metal_texture_plan(core, (unsigned)type, (unsigned)descriptor.pixelFormat, (unsigned)descriptor.width,
	    (unsigned)height, (unsigned)depth, (unsigned)descriptor.mipmapLevelCount, (unsigned)descriptor.sampleCount,
	    (unsigned)usage, &layout) != 0) {
		akios_say("refused: a texture of %lux%lu, pixel format %lu, type %lu: %s\n", (unsigned long)descriptor.width,
		    (unsigned long)descriptor.height, (unsigned long)descriptor.pixelFormat, (unsigned long)type, hakios_metal_error());
		return nil;
	}
	MTLTextureDescriptor *made = [descriptor copy];
	if (made.storageMode == MTLStorageModePrivate || made.storageMode == MTLStorageModeMemoryless) {
		made.storageMode = MTLStorageModeShared;
	}
	uint8_t args[AKIOS_RESOURCE_ARGS_SIZE] = { 0 };
	AkiosMaliTexture *texture = [[AkiosMaliTexture alloc] initWithDevice:self descriptor:made sysMemSize:(NSUInteger)layout.size
	    sysMemRowBytes:layout.row_bytes vidMemSize:0 vidMemRowBytes:0 args:args argsSize:sizeof(args)];
	if (texture == nil || [texture gpuAddress] == 0) {
		akios_say("refused: a texture of %lux%lu, pixel format %lu: IOGPU made no resource of %llu bytes\n",
		    (unsigned long)descriptor.width, (unsigned long)descriptor.height, (unsigned long)descriptor.pixelFormat,
		    (unsigned long long)layout.size);
		return nil;
	}
	if (![texture akWrap:core layout:&layout]) {
		akios_say("refused: a texture: %s\n", hakios_metal_error());
		return nil;
	}
	if (descriptor.storageMode == MTLStorageModeMemoryless) {
		hakios_metal_texture_set_memoryless([texture akCore], 1);
	}
	[texture akSetUsage:usage];
	return (id<MTLTexture>)texture;
}

/*
 * A texture over an IOSurface plane (plan 1.6, 2.2): IOGPU's resource of kind 0x82 (the kernel answers the plane's GPU
 * address), the core's texture over its rows -- the surface's own rows, which the Mali samples only from 64-byte
 * multiples (MiniIOSurface aligns them so by default); others, and the two-plane YCbCr formats, are refused by name for
 * now (the earlier plug-in's mirrors and shadow copies did not come along). The CPU paths (-replaceRegion:...) go
 * through this process's mapping of the surface.
 */
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane
{
	hakios_metal_device *core = [self akCore];

	if (core == NULL || descriptor == nil || surface == NULL) {
		akios_say("refused: a texture over an IOSurface: %s\n", core == NULL ? "no Mali core on this device" : "no descriptor or surface");
		return nil;
	}
	const size_t planes = IOSurfaceGetPlaneCount(surface);
	if ((planes == 0 && plane != 0) || (planes != 0 && plane >= planes) || descriptor.textureType != MTLTextureType2D ||
	    descriptor.pixelFormat >= 500) {
		akios_say("refused: a texture of type %lu, pixel format %lu over plane %lu of IOSurface %u (%zu planes): 2D, one plane of a "
		    "colour format is served\n", (unsigned long)descriptor.textureType, (unsigned long)descriptor.pixelFormat,
		    (unsigned long)plane, IOSurfaceGetID(surface), planes);
		return nil;
	}
	const size_t rows = planes != 0 ? IOSurfaceGetBytesPerRowOfPlane(surface, plane) : IOSurfaceGetBytesPerRow(surface);
	const size_t height = planes != 0 ? IOSurfaceGetHeightOfPlane(surface, plane) : IOSurfaceGetHeight(surface);
	void *cpu = planes != 0 ? IOSurfaceGetBaseAddressOfPlane(surface, plane) : IOSurfaceGetBaseAddress(surface);
	MTLTextureUsage usage = descriptor.usage & ~(MTLTextureUsage)MTLTextureUsagePixelFormatView & (MTLTextureUsage)0xffff;

	if (usage == MTLTextureUsageUnknown) {
		usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
	}
	uint8_t args[AKIOS_RESOURCE_ARGS_SIZE] = { 0 };
	AkiosMaliTexture *texture = [[AkiosMaliTexture alloc] initWithDevice:self descriptor:descriptor iosurface:surface plane:plane field:0
	    args:args argsSize:sizeof(args)];
	if (texture == nil || [texture gpuAddress] == 0) {
		akios_say("refused: a texture over IOSurface %u: IOGPU made no resource of it\n", IOSurfaceGetID(surface));
		return nil;
	}
	hakios_metal_texture *t = hakios_metal_texture_wrap_rows(core, (unsigned)descriptor.pixelFormat, (unsigned)descriptor.width,
	    (unsigned)descriptor.height, (unsigned)usage, [texture gpuAddress], cpu, (uint64_t)rows * height, (uint32_t)rows);
	if (t == NULL) {
		akios_say("refused: a texture over IOSurface %u plane %lu: %s\n", IOSurfaceGetID(surface), (unsigned long)plane, hakios_metal_error());
		return nil;
	}
	[texture akSetCore:t];
	[texture akSetUsage:usage];
	return (id<MTLTexture>)texture;
}

@end
