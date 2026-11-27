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
	[self akLive];
}

/* (11-26) its memory among the live (akios_live_add): a view's is its parent's, kept alive by it */
- (void)akLive
{
	uint64_t va = 0, size = 0;
	char what[72];

	if (_akCore == NULL || !hakios_metal_texture_range(_akCore, &va, &size)) return;
	IOSurfaceRef surface = [self iosurface];
	int at = snprintf(what, sizeof(what), "a texture %lux%lu of format %lu%s", (unsigned long)[self width], (unsigned long)[self height],
	    (unsigned long)[self pixelFormat], [(id<MTLTexture>)self parentTexture] != nil ? " (a view)" : "");
	if (surface != NULL && at > 0 && at < (int)sizeof(what)) {
		snprintf(what + at, sizeof(what) - (size_t)at, " over IOSurface %u", IOSurfaceGetID(surface));
	}
	akios_live_add((__bridge void *)self, va, size, what);
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

	id<MTLTexture> view = [self akViewWithPixelFormat:format type:[self textureType] levels:NSMakeRange(0, [self mipmapLevelCount])
	    slices:NSMakeRange(0, akios_layered((unsigned)[self textureType]) ? slices : 1) swizzle:NULL];

	akios_texture_note("view", view, nil, [self iosurface], [self iosurfacePlane], __builtin_return_address(0));
	return view;
}

- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type levels:(NSRange)levels
    slices:(NSRange)slices
{
	id<MTLTexture> view = [self akViewWithPixelFormat:format type:type levels:levels slices:slices swizzle:NULL];

	akios_texture_note("view", view, nil, [self iosurface], [self iosurfacePlane], __builtin_return_address(0));
	return view;
}

- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type levels:(NSRange)levels
    slices:(NSRange)slices swizzle:(MTLTextureSwizzleChannels)swizzle
{
	id<MTLTexture> view = [self akViewWithPixelFormat:format type:type levels:levels slices:slices swizzle:&swizzle];

	akios_texture_note("view", view, nil, [self iosurface], [self iosurfacePlane], __builtin_return_address(0));
	return view;
}

- (BOOL)akWrap:(hakios_metal_device *)core layout:(const struct hakios_metal_texture_layout *)layout
{
	uint64_t gpu = [self gpuAddress];
	uint64_t cpu = [self respondsToSelector:@selector(virtualAddress)] ? [self virtualAddress] : 0;

	/* (a system-memory resource is mapped into the task at its GPU address: akios_iogpu.cpp s_new_resource) */
	_akCore = hakios_metal_texture_wrap(core, layout, gpu, (void *)(uintptr_t)(cpu != 0 ? cpu : gpu));
	[self akLive];
	return _akCore != NULL;
}

- (hakios_metal_texture *)akCore
{
	return _akCore;
}

- (void)dealloc
{
	akios_live_remove((__bridge void *)self);
	hakios_metal_texture_free(_akCore);   /* (a command buffer that uses it holds the wrapper until it has completed) */
}

/* (sparse textures are not served: no tail) */
- (NSUInteger)firstMipmapInTail { return [self mipmapLevelCount]; }
- (NSUInteger)tailSizeInBytes { return 0; }

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


/*
 * A texture layout (-newTextureLayoutWithDescriptor:isHeapOrBufferBacked:, 11-27): how this device wants a texture's
 * bytes in memory a client fills ahead of the texture. ImageIO's ASTCTwiddler asks for one to stage an asset catalogue's
 * ASTC image (icons) and reads its -size and -alignment; without the method SpringBoard died of an unrecognized selector
 * at its first icon and launchd rebooted the phone. The order is the plainest: the levels one after another, each in
 * rows of whole blocks (or pixels) packed tight, which -newTextureWithBytesNoCopy:... reads back the same way.
 * (As the earlier plug-in had it, HakiosMetalTextureLayout.)
 */
static void
akios_tight_level(NSUInteger width, NSUInteger height, NSUInteger levels, unsigned bw, unsigned bh, unsigned bytes,
    NSUInteger level, NSUInteger *offset, NSUInteger *rowBytes, NSUInteger *rows)
{
	NSUInteger at = 0;

	for (NSUInteger l = 0; l < levels; l++) {
		const NSUInteger w = MAX(width >> l, (NSUInteger)1), h = MAX(height >> l, (NSUInteger)1);
		const NSUInteger row = (w + bw - 1) / bw * bytes, down = (h + bh - 1) / bh;

		if (l == level) {
			*offset = at;
			*rowBytes = row;
			*rows = down;
			return;
		}
		at += row * down;
	}
	*offset = at;   /* (LEVEL past the last: the whole size) */
	*rowBytes = 0;
	*rows = 0;
}

@interface AkiosTextureLayout : NSObject {
	unsigned _blockW, _blockH, _bytes;
	NSUInteger _width, _height, _levels;
}
- (instancetype)initWithDescriptor:(MTLTextureDescriptor *)descriptor blockW:(unsigned)bw blockH:(unsigned)bh bytes:(unsigned)bytes;
@end

struct akios_watermark { uint64_t a, b; };

@implementation AkiosTextureLayout
- (instancetype)initWithDescriptor:(MTLTextureDescriptor *)descriptor blockW:(unsigned)bw blockH:(unsigned)bh bytes:(unsigned)bytes
{
	self = [super init];
	if (self != nil) {
		_blockW = bw;
		_blockH = bh;
		_bytes = bytes;
		_width = [descriptor width];
		_height = [descriptor height];
		_levels = MAX([descriptor mipmapLevelCount], (NSUInteger)1);
	}
	return self;
}

- (NSUInteger)size
{
	NSUInteger offset, row, rows;

	akios_tight_level(_width, _height, _levels, _blockW, _blockH, _bytes, _levels, &offset, &row, &rows);
	return offset;
}

- (NSUInteger)alignment { return 64; }
- (void)initializeTextureMemory:(void *)memory { (void)memory; }
- (void)finalizeTextureMemory:(void *)memory { (void)memory; }

/* this layout's name for staged bytes (16 bytes, which ImageIO keeps and compares) */
- (struct akios_watermark)watermark
{
	struct akios_watermark w;

	memcpy(&w, "akios-tight-v1\0\0", 16);
	return w;
}

- (BOOL)akRegion:(MTLRegion)r slice:(NSUInteger)slice level:(NSUInteger)level at:(NSUInteger *)at rowBytes:(NSUInteger *)rowBytes
	    rows:(NSUInteger *)rows pitch:(NSUInteger *)pitch
{
	NSUInteger offset, row, down;

	if (slice != 0 || level >= _levels || r.origin.z != 0 || r.size.depth != 1 || r.origin.x % _blockW != 0 ||
	    r.origin.y % _blockH != 0) {
		akios_say("refused: a texture layout's copy of %lux%lu at (%lu, %lu) of level %lu, slice %lu: one slice, depth 1, "
		    "whole blocks\n", (unsigned long)r.size.width, (unsigned long)r.size.height, (unsigned long)r.origin.x,
		    (unsigned long)r.origin.y, (unsigned long)level, (unsigned long)slice);
		return NO;
	}
	akios_tight_level(_width, _height, _levels, _blockW, _blockH, _bytes, level, &offset, &row, &down);
	*at = offset + r.origin.y / _blockH * row + r.origin.x / _blockW * _bytes;
	*rowBytes = (r.size.width + _blockW - 1) / _blockW * _bytes;
	*rows = (r.size.height + _blockH - 1) / _blockH;
	*pitch = row;
	return YES;
}

- (void)copyFromLinearBytes:(const void *)linear linearOffset:(NSUInteger)linearOffset linearBytesPerRow:(NSUInteger)linearBytesPerRow
    linearBytesPerImage:(NSUInteger)linearBytesPerImage toTextureMemory:(void *)memory textureSlice:(NSUInteger)slice
    textureLevel:(NSUInteger)level textureRegion:(MTLRegion)region
{
	NSUInteger at, rowBytes, rows, pitch;

	(void)linearBytesPerImage;
	if ([self akRegion:region slice:slice level:level at:&at rowBytes:&rowBytes rows:&rows pitch:&pitch]) {
		for (NSUInteger r = 0; r < rows; r++) {
			memcpy((uint8_t *)memory + at + r * pitch, (const uint8_t *)linear + linearOffset + r * linearBytesPerRow, rowBytes);
		}
	}
}

- (void)copyFromTextureMemory:(const void *)memory textureSlice:(NSUInteger)slice textureLevel:(NSUInteger)level
    textureRegion:(MTLRegion)region toLinearBytes:(void *)linear linearOffset:(NSUInteger)linearOffset
    linearBytesPerRow:(NSUInteger)linearBytesPerRow linearBytesPerImage:(NSUInteger)linearBytesPerImage
{
	NSUInteger at, rowBytes, rows, pitch;

	(void)linearBytesPerImage;
	if ([self akRegion:region slice:slice level:level at:&at rowBytes:&rowBytes rows:&rows pitch:&pitch]) {
		for (NSUInteger r = 0; r < rows; r++) {
			memcpy((uint8_t *)linear + linearOffset + r * linearBytesPerRow, (const uint8_t *)memory + at + r * pitch, rowBytes);
		}
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
	id<MTLTexture> texture = [self akNewTextureWithDescriptor:descriptor];

	akios_texture_note("plain", texture, descriptor, NULL, 0, __builtin_return_address(0));
	return texture;
}

- (id<MTLTexture>)akNewTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
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
 * What a process makes textures over (11-26): the first 24 IOSurface textures a process asks for, one line each -- the
 * surface, its fourcc, the format asked and served, size, rows, usage, storage. backboardd aborted in CoreAnimation's
 * push_surface right after making one (an asynchronous layer's surface, on the unlock); the line says which.
 */
static void
akm_surface_shape(IOSurfaceRef surface, NSUInteger plane, OSType fourcc, unsigned asked, unsigned served, NSUInteger width,
    NSUInteger height, size_t rows, MTLTextureUsage usage, MTLStorageMode storage)
{
	static unsigned said;

	if (__atomic_fetch_add(&said, 1, __ATOMIC_RELAXED) >= 24) {
		return;
	}
	char cc[5] = { (char)(fourcc >> 24), (char)(fourcc >> 16), (char)(fourcc >> 8), (char)fourcc, 0 };
	for (int i = 0; i < 4; i++) {
		if (cc[i] < 32 || cc[i] > 126) cc[i] = '?';
	}
	char as[32] = "";
	if (served != asked) {
		snprintf(as, sizeof(as), " (served as %u)", served);
	}
	akios_say("a texture over IOSurface %u plane %lu ('%s', %zux%zu, rows of %zu bytes): MTLPixelFormat %u%s, %lux%lu, "
	    "usage %#lx, storage %lu\n", IOSurfaceGetID(surface), (unsigned long)plane, cc, IOSurfaceGetWidth(surface),
	    IOSurfaceGetHeight(surface), rows, asked, as, (unsigned long)width, (unsigned long)height, (unsigned long)usage,
	    (unsigned long)storage);
}

- (id)newTextureLayoutWithDescriptor:(MTLTextureDescriptor *)descriptor isHeapOrBufferBacked:(BOOL)backed
{
	unsigned bw, bh, bytes;

	(void)backed;
	if (descriptor == nil || !hakios_metal_format_block((unsigned)[descriptor pixelFormat], &bw, &bh, &bytes) ||
	    ([descriptor textureType] != MTLTextureType2D && [descriptor textureType] != MTLTextureType1D) ||
	    [descriptor arrayLength] != 1 || [descriptor depth] != 1) {
		akios_say("refused: a texture layout for pixel format %lu, type %lu: a 1D or 2D texture of a format this device "
		    "serves\n", (unsigned long)[descriptor pixelFormat], (unsigned long)[descriptor textureType]);
		return nil;
	}
	return [[AkiosTextureLayout alloc] initWithDescriptor:descriptor blockW:bw blockH:bh bytes:bytes];
}

/*
 * A texture over the caller's bytes (11-27): copied into a texture of the GPU's own. Compressed or mipmapped: the bytes
 * are in -newTextureLayoutWithDescriptor:'s tight layout (ImageIO staged them so); else rows LENGTH / height bytes apart.
 * The bytes are copied, so the deallocator gets them back at once.
 */
- (id<MTLTexture>)newTextureWithBytesNoCopy:(void *)bytes length:(NSUInteger)length descriptor:(MTLTextureDescriptor *)descriptor
    deallocator:(void (^)(void *, NSUInteger))deallocator
{
	id<MTLTexture> texture = [self newTextureWithDescriptor:descriptor];
	const NSUInteger width = [descriptor width], height = [descriptor height];
	const NSUInteger levels = MAX([descriptor mipmapLevelCount], (NSUInteger)1);
	unsigned bw = 1, bh = 1, per = 0;

	if (texture == nil) {
		return nil;
	}
	if (bytes == NULL || !hakios_metal_format_block((unsigned)[descriptor pixelFormat], &bw, &bh, &per)) {
		akios_say("refused: a no-copy texture of pixel format %lu over %lu bytes\n", (unsigned long)[descriptor pixelFormat],
		    (unsigned long)length);
		return nil;
	}
	if (bw > 1 || bh > 1 || levels > 1) {
		NSUInteger offset, row, rows;

		akios_tight_level(width, height, levels, bw, bh, per, levels, &offset, &row, &rows);
		if (length < offset) {
			akios_say("refused: a no-copy texture of %lux%lu, %lu levels over %lu bytes: its layout takes %lu\n",
			    (unsigned long)width, (unsigned long)height, (unsigned long)levels, (unsigned long)length, (unsigned long)offset);
			return nil;
		}
		for (NSUInteger l = 0; l < levels; l++) {
			akios_tight_level(width, height, levels, bw, bh, per, l, &offset, &row, &rows);
			[texture replaceRegion:MTLRegionMake2D(0, 0, MAX(width >> l, (NSUInteger)1), MAX(height >> l, (NSUInteger)1))
			    mipmapLevel:l withBytes:(const uint8_t *)bytes + offset bytesPerRow:row];
		}
	} else {
		const NSUInteger pitch = height != 0 ? length / height : 0;

		if (pitch < width * per) {
			akios_say("refused: a no-copy texture of %lux%lu over %lu bytes: rows of %lu bytes do not hold the width\n",
			    (unsigned long)width, (unsigned long)height, (unsigned long)length, (unsigned long)pitch);
			return nil;
		}
		[texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:bytes bytesPerRow:pitch];
	}
	if (deallocator != nil) {
		deallocator(bytes, length);
	}
	return texture;
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
	id<MTLTexture> texture = [self akNewTextureWithDescriptor:descriptor iosurface:surface plane:plane];

	akios_texture_note("iosurface", texture, descriptor, surface, plane, __builtin_return_address(0));
	return texture;
}

- (id<MTLTexture>)akNewTextureWithDescriptor:(MTLTextureDescriptor *)descriptor iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane
{
	hakios_metal_device *core = [self akCore];

	if (core == NULL || descriptor == nil || surface == NULL) {
		akios_say("refused: a texture over an IOSurface: %s\n", core == NULL ? "no Mali core on this device" : "no descriptor or surface");
		return nil;
	}
	const size_t planes = IOSurfaceGetPlaneCount(surface);
	const BOOL xrOverBGRA = descriptor.pixelFormat >= 552 && descriptor.pixelFormat <= 555 && IOSurfaceGetPixelFormat(surface) == 'BGRA';
	if ((planes == 0 && plane != 0) || (planes != 0 && plane >= planes) || descriptor.textureType != MTLTextureType2D ||
	    (descriptor.pixelFormat >= 500 && !xrOverBGRA)) {
		akios_say("refused: a texture of type %lu, pixel format %lu over plane %lu of IOSurface %u (%zu planes): 2D, one plane of a "
		    "colour format is served\n", (unsigned long)descriptor.textureType, (unsigned long)descriptor.pixelFormat,
		    (unsigned long)plane, IOSurfaceGetID(surface), planes);
		return nil;
	}
	const size_t rows = planes != 0 ? IOSurfaceGetBytesPerRowOfPlane(surface, plane) : IOSurfaceGetBytesPerRow(surface);
	const size_t height = planes != 0 ? IOSurfaceGetHeightOfPlane(surface, plane) : IOSurfaceGetHeight(surface);
	void *cpu = planes != 0 ? IOSurfaceGetBaseAddressOfPlane(surface, plane) : IOSurfaceGetBaseAddress(surface);
	const OSType fourcc = IOSurfaceGetPixelFormat(surface);
	MTLTextureUsage usage = descriptor.usage & ~(MTLTextureUsage)MTLTextureUsagePixelFormatView & (MTLTextureUsage)0xffff;
	unsigned format = (unsigned)descriptor.pixelFormat;

	if (usage == MTLTextureUsageUnknown) {
		usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
	}
	/*
	 * The extended-range formats over a surface of 8-bit BGRA (as the earlier core did, 11-23): BGRA10_XR / BGR10_XR and
	 * their sRGB twins (552..555) asked of a 'BGRA' surface -- SpringBoard's lock-screen hello asks it of backboardd's
	 * capture -- read the surface as what it holds, BGRA8 (80 / 81). IOGPU's texture keeps the format asked.
	 */
	if (format >= 552 && format <= 555 && fourcc == 'BGRA') {
		format = (format & 1) ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm;
	}
	akm_surface_shape(surface, plane, fourcc, (unsigned)descriptor.pixelFormat, format, descriptor.width, descriptor.height,
	    rows, usage, descriptor.storageMode);
	uint8_t args[AKIOS_RESOURCE_ARGS_SIZE] = { 0 };
	AkiosMaliTexture *texture = [[AkiosMaliTexture alloc] initWithDevice:self descriptor:descriptor iosurface:surface plane:plane field:0
	    args:args argsSize:sizeof(args)];
	if (texture == nil || [texture gpuAddress] == 0) {
		akios_say("refused: a texture over IOSurface %u: IOGPU made no resource of it\n", IOSurfaceGetID(surface));
		return nil;
	}
	hakios_metal_texture *t = hakios_metal_texture_wrap_rows(core, format, (unsigned)descriptor.width,
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

/* -[MTLBuffer newTextureWithDescriptor:offset:bytesPerRow:]: IOGPU's texture over the buffer's resource, the core's over
 * the same rows (2D, one level; start and pitch 64-byte multiples, as the device's alignment queries say) */
@implementation AkiosMaliBuffer (Textures)

- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow
{
	id<MTLTexture> texture = [self akNewTextureWithDescriptor:descriptor offset:offset bytesPerRow:bytesPerRow];

	akios_texture_note("buffer", texture, descriptor, NULL, 0, __builtin_return_address(0));
	return texture;
}

- (id<MTLTexture>)akNewTextureWithDescriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow
{
	hakios_metal_buffer *core = [self akCore];

	if (core == NULL || descriptor == nil) {
		akios_say("refused: a texture over a buffer: %s\n", core == NULL ? "a buffer without the core's wrapper" : "no descriptor");
		return nil;
	}
	MTLTextureUsage usage = descriptor.usage & ~(MTLTextureUsage)MTLTextureUsagePixelFormatView & (MTLTextureUsage)0xffff;
	if (usage == MTLTextureUsageUnknown) {
		usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
	}
	hakios_metal_texture *t = hakios_metal_texture_new_buffer(core, (unsigned)descriptor.textureType, (unsigned)descriptor.pixelFormat,
	    (unsigned)descriptor.width, (unsigned)descriptor.height, (unsigned)usage, offset, bytesPerRow);
	if (t == NULL) {
		akios_say("refused: a texture of %lux%lu, pixel format %lu over a buffer at %lu, rows %lu: %s\n", (unsigned long)descriptor.width,
		    (unsigned long)descriptor.height, (unsigned long)descriptor.pixelFormat, (unsigned long)offset, (unsigned long)bytesPerRow,
		    hakios_metal_error());
		return nil;
	}
	AkiosMaliTexture *texture = [[AkiosMaliTexture alloc] initWithBuffer:self descriptor:descriptor offset:offset bytesPerRow:bytesPerRow];
	if (texture == nil) {
		hakios_metal_texture_free(t);
		return nil;
	}
	[texture akSetCore:t];
	[texture akSetUsage:usage];
	return (id<MTLTexture>)texture;
}

@end
