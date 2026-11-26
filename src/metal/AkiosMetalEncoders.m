/*
 * AkiosMetalEncoders.m: the blit and compute encoders (plan 1.8), over IOGPU's IOGPUMetalBlitCommandEncoder and
 * IOGPUMetalComputeCommandEncoder: their initialiser (_MTLCommandEncoder's: the command buffer retained until
 * -endEncoding) and the forwarding of the short copy forms are IOGPU's; the work is recorded into the command buffer's
 * core (hakios_metal_cb_copy / _fill / _blit / _dispatch*), as the earlier plug-in recorded it (HakiosMetalCA.m), and
 * everything bound is kept by the command buffer until it completes. No segments of their own yet (step F): the whole
 * command buffer is one stream, built at commit.
 */
#import "AkiosMetal.h"

static BOOL
akios_layered(unsigned type)
{
	return type == MTLTextureType1DArray || type == MTLTextureType2DArray || type == MTLTextureTypeCube ||
	    type == MTLTextureTypeCubeArray;
}

/* ============================================================================================================
 * Blit
 * ============================================================================================================ */

@implementation AkiosMaliBlitEncoder {
	__unsafe_unretained AkiosMaliCommandBuffer *_akCommandBuffer;   /* (the base retains it until -endEncoding) */
}

+ (void)load
{
	class_addProtocol(self, @protocol(MTLBlitCommandEncoder));
}

- (instancetype)initWithAkiosCommandBuffer:(AkiosMaliCommandBuffer *)commandBuffer
{
	self = [super initWithCommandBuffer:commandBuffer];
	if (self != nil) {
		_akCommandBuffer = commandBuffer;
	}
	return self;
}

- (id)device { return [_akCommandBuffer device]; }

/* a buffer of this device (kept by the command buffer), or a refusal by name that fails the command buffer */
- (hakios_metal_buffer *)akBuffer:(id)object what:(const char *)what
{
	hakios_metal_buffer *b = [object isKindOfClass:[AkiosMaliBuffer class]] ? [(AkiosMaliBuffer *)object akCore] : NULL;

	if (b == NULL) {
		char why[160];

		snprintf(why, sizeof(why), "a blit's %s buffer is %s, not a buffer of this device", what,
		    object != nil ? class_getName(object_getClass(object)) : "nil");
		akios_say("refused: %s\n", why);
		hakios_metal_cb_refuse([_akCommandBuffer akCore], why);
		return NULL;
	}
	[_akCommandBuffer akHold:object];
	return b;
}

- (hakios_metal_texture *)akTexture:(id)object what:(const char *)what
{
	hakios_metal_texture *t = [object isKindOfClass:[AkiosMaliTexture class]] ? [(AkiosMaliTexture *)object akCore] : NULL;

	if (t == NULL) {
		char why[160];

		snprintf(why, sizeof(why), "a texture copy's %s is %s, not a texture of this device", what,
		    object != nil ? class_getName(object_getClass(object)) : "nil");
		akios_say("refused: %s\n", why);
		hakios_metal_cb_refuse([_akCommandBuffer akCore], why);
		return NULL;
	}
	[_akCommandBuffer akHold:object];
	return t;
}

- (void)copyFromBuffer:(id<MTLBuffer>)source sourceOffset:(NSUInteger)sourceOffset toBuffer:(id<MTLBuffer>)destination
    destinationOffset:(NSUInteger)destinationOffset size:(NSUInteger)size
{
	hakios_metal_buffer *from = [self akBuffer:source what:"source"];
	hakios_metal_buffer *to = from != NULL ? [self akBuffer:destination what:"destination"] : NULL;

	if (to != NULL && hakios_metal_cb_copy([_akCommandBuffer akCore], from, sourceOffset, to, destinationOffset, size) != 0) {
		akios_say("refused: a copy of %lu bytes: %s\n", (unsigned long)size, hakios_metal_error());
		hakios_metal_cb_refuse([_akCommandBuffer akCore], hakios_metal_error());
	}
}

- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value
{
	hakios_metal_buffer *target = [self akBuffer:buffer what:"fill"];

	if (target != NULL && hakios_metal_cb_fill([_akCommandBuffer akCore], target, range.location, range.length, value) != 0) {
		akios_say("refused: a fill of %lu bytes: %s\n", (unsigned long)range.length, hakios_metal_error());
		hakios_metal_cb_refuse([_akCommandBuffer akCore], hakios_metal_error());
	}
}

/* (one queue runs its command buffers, and the core a command buffer's jobs, in order, caches flushed between jobs:
 * a fence within a queue orders nothing more -- plan 2.5; IOGPU's bases raise here) */
- (void)updateFence:(id<MTLFence>)fence { (void)fence; }
- (void)waitForFence:(id<MTLFence>)fence { (void)fence; }
- (void)synchronizeResource:(id<MTLResource>)resource { (void)resource; }
- (void)synchronizeTexture:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level
{
	(void)texture; (void)slice; (void)level;
}

/* texture copies: the core's (bytes between same-sized formats; a draw for bigger RGBA8/BGRA8 ones) */
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel
    sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture
    destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin
{
	hakios_metal_cb *cb = [_akCommandBuffer akCore];
	hakios_metal_texture *from = [self akTexture:sourceTexture what:"source"];
	hakios_metal_texture *to = from != NULL ? [self akTexture:destinationTexture what:"destination"] : NULL;
	int r;

	if (to == NULL) {
		return;
	}
	if (sourceOrigin.z != 0 || destinationOrigin.z != 0 || sourceSize.depth != 1 ||
	    (sourceSlice != 0 && !akios_layered(hakios_metal_texture_type(from))) ||
	    (destinationSlice != 0 && !akios_layered(hakios_metal_texture_type(to)))) {
		char why[160];

		snprintf(why, sizeof(why), "a texture copy of slice %lu into slice %lu, depth %lu at z %lu: one slice of depth 1 is served",
		    (unsigned long)sourceSlice, (unsigned long)destinationSlice, (unsigned long)sourceSize.depth, (unsigned long)sourceOrigin.z);
		akios_say("refused: %s\n", why);
		hakios_metal_cb_refuse(cb, why);
		return;
	}
	if (sourceSlice != 0 || destinationSlice != 0) {
		r = hakios_metal_cb_blit_layer(cb, from, (unsigned)sourceLevel, (unsigned)sourceSlice, (unsigned)sourceOrigin.x,
		    (unsigned)sourceOrigin.y, (unsigned)sourceSize.width, (unsigned)sourceSize.height, to, (unsigned)destinationLevel,
		    (unsigned)destinationSlice, (unsigned)destinationOrigin.x, (unsigned)destinationOrigin.y);
	} else {
		r = hakios_metal_cb_blit(cb, from, (unsigned)sourceLevel, (unsigned)sourceOrigin.x, (unsigned)sourceOrigin.y,
		    (unsigned)sourceSize.width, (unsigned)sourceSize.height, to, (unsigned)destinationLevel, (unsigned)destinationOrigin.x,
		    (unsigned)destinationOrigin.y, (unsigned)sourceSize.width, (unsigned)sourceSize.height, 0);
	}
	if (r != 0) {
		akios_say("refused: a texture copy: %s\n", hakios_metal_error());   /* (the command buffer ends in error) */
	}
}

- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel
    toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel
    sliceCount:(NSUInteger)sliceCount levelCount:(NSUInteger)levelCount
{
	for (NSUInteger slice = 0; slice < sliceCount; slice++) {
		for (NSUInteger l = 0; l < levelCount; l++) {
			NSUInteger w = sourceTexture.width >> (sourceLevel + l), h = sourceTexture.height >> (sourceLevel + l);

			[self copyFromTexture:sourceTexture sourceSlice:sourceSlice + slice sourceLevel:sourceLevel + l
			    sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w ? w : 1, h ? h : 1, 1) toTexture:destinationTexture
			    destinationSlice:destinationSlice + slice destinationLevel:destinationLevel + l destinationOrigin:MTLOriginMake(0, 0, 0)];
		}
	}
}

- (void)copyFromTexture:(id<MTLTexture>)sourceTexture toTexture:(id<MTLTexture>)destinationTexture
{
	NSUInteger levels = MIN(sourceTexture.mipmapLevelCount, destinationTexture.mipmapLevelCount);

	[self copyFromTexture:sourceTexture sourceSlice:0 sourceLevel:0 toTexture:destinationTexture destinationSlice:0
	    destinationLevel:0 sliceCount:1 levelCount:levels];
}

- (void)generateMipmapsForTexture:(id<MTLTexture>)texture
{
	hakios_metal_texture *t = [self akTexture:texture what:"texture"];

	if (t != NULL && hakios_metal_cb_generate_mipmaps([_akCommandBuffer akCore], t) != 0) {
		akios_say("refused: generateMipmaps: %s\n", hakios_metal_error());
	}
}

/* A buffer's rows as a texture of the other side's format over the same memory (the GPU takes rows only at a start and a
 * pitch that are multiples of 64 bytes: other rows go through a staging buffer, one GPU copy a row). The command buffer
 * holds what it names, so the handles go at once. (HakiosMetalCA.m: hm_rows_texture) */
- (hakios_metal_texture *)akRows:(hakios_metal_buffer *)buffer offset:(uint64_t)offset bytesPerRow:(uint64_t)bytesPerRow
    like:(hakios_metal_texture *)like size:(MTLSize)size staging:(hakios_metal_buffer **)staging pitch:(uint64_t *)pitch
{
	*staging = NULL;
	*pitch = bytesPerRow;
	if (offset % 64 != 0 || bytesPerRow % 64 != 0) {
		*pitch = (bytesPerRow + 63) & ~(uint64_t)63;
		*staging = hakios_metal_buffer_new([(AkiosMaliDevice *)[self device] akCore], *pitch * size.height);
		if (*staging == NULL) {
			return NULL;
		}
		offset = 0;
	}
	return hakios_metal_texture_new_buffer(*staging != NULL ? *staging : buffer, MTLTextureType2D, hakios_metal_texture_format(like),
	    (unsigned)size.width, (unsigned)size.height, 1 | 2 | 4, offset, *pitch);
}

- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset sourceBytesPerRow:(NSUInteger)sourceBytesPerRow
    sourceBytesPerImage:(NSUInteger)sourceBytesPerImage sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture
    destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin
    options:(MTLBlitOption)options
{
	if (options != MTLBlitOptionNone) {
		akios_say("refused: a buffer-to-texture copy with blit options %#lx\n", (unsigned long)options);
		hakios_metal_cb_refuse([_akCommandBuffer akCore], "a buffer-to-texture copy with blit options");
		return;
	}
	[self copyFromBuffer:sourceBuffer sourceOffset:sourceOffset sourceBytesPerRow:sourceBytesPerRow sourceBytesPerImage:sourceBytesPerImage
	    sourceSize:sourceSize toTexture:destinationTexture destinationSlice:destinationSlice destinationLevel:destinationLevel
	    destinationOrigin:destinationOrigin];
}

- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset sourceBytesPerRow:(NSUInteger)sourceBytesPerRow
    sourceBytesPerImage:(NSUInteger)sourceBytesPerImage sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture
    destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin
{
	hakios_metal_cb *cb = [_akCommandBuffer akCore];
	hakios_metal_buffer *from = [self akBuffer:sourceBuffer what:"source"];
	hakios_metal_texture *to = from != NULL ? [self akTexture:destinationTexture what:"destination"] : NULL;
	hakios_metal_buffer *staging = NULL;
	uint64_t pitch = 0;
	int failed = 0;

	if (to == NULL) {
		return;
	}
	if (sourceSize.width == 0 || sourceSize.height == 0 || sourceSize.depth == 0) {
		return;
	}
	const unsigned type = hakios_metal_texture_type(to), format = hakios_metal_texture_format(to);
	/* layers, 3D planes and block-compressed formats: copied by the processor out of the buffer's shared memory when
	 * the copy is encoded (the earlier plug-in's way: what an engine wrote into its staging buffer before encoding) */
	if (destinationSlice != 0 || destinationOrigin.z != 0 || sourceSize.depth != 1 || akios_layered(type) ||
	    type == MTLTextureType3D || (format >= 130 && format <= 236)) {
		const uint8_t *base = hakios_metal_buffer_contents(from);
		const BOOL planes = type == MTLTextureType3D;
		int r = base == NULL || (!planes && sourceSize.depth != 1) ? -1 :
		    (akios_layered(type) || planes) ?
		    hakios_metal_texture_replace_3d(to, (unsigned)destinationLevel, (unsigned)destinationOrigin.x, (unsigned)destinationOrigin.y,
			(unsigned)(planes ? destinationOrigin.z : destinationSlice), (unsigned)sourceSize.width, (unsigned)sourceSize.height,
			(unsigned)sourceSize.depth, base + sourceOffset, sourceBytesPerRow, sourceBytesPerImage) :
		    hakios_metal_texture_replace_level(to, (unsigned)destinationLevel, (unsigned)destinationOrigin.x,
			(unsigned)destinationOrigin.y, (unsigned)sourceSize.width, (unsigned)sourceSize.height, base + sourceOffset,
			sourceBytesPerRow);
		if (r != 0) {
			akios_say("refused: a buffer-to-texture copy of %lux%lux%lu: %s\n", (unsigned long)sourceSize.width,
			    (unsigned long)sourceSize.height, (unsigned long)sourceSize.depth, base == NULL ? "the buffer is mapped nowhere" :
			    hakios_metal_error());
			hakios_metal_cb_refuse(cb, "a buffer-to-texture copy the processor could not make");
		}
		return;
	}
	hakios_metal_texture *rows = [self akRows:from offset:sourceOffset bytesPerRow:sourceBytesPerRow like:to size:sourceSize
	    staging:&staging pitch:&pitch];
	if (rows == NULL) {
		akios_say("refused: a buffer-to-texture copy's rows: %s\n", hakios_metal_error());
		hakios_metal_cb_refuse(cb, "a buffer-to-texture copy's rows could not be made a texture");
		hakios_metal_buffer_free(staging);
		return;
	}
	if (staging != NULL) {
		uint64_t length = hakios_metal_buffer_length(from);

		for (NSUInteger y = 0; y < sourceSize.height && !failed; y++) {
			uint64_t at = sourceOffset + (uint64_t)y * sourceBytesPerRow;
			uint64_t n = at < length ? MIN((uint64_t)sourceBytesPerRow, length - at) : 0;

			failed = n != 0 && hakios_metal_cb_copy(cb, from, at, staging, (uint64_t)y * pitch, n) != 0;
		}
	}
	if (!failed) {
		failed = hakios_metal_cb_blit(cb, rows, 0, 0, 0, (unsigned)sourceSize.width, (unsigned)sourceSize.height, to,
		    (unsigned)destinationLevel, (unsigned)destinationOrigin.x, (unsigned)destinationOrigin.y, (unsigned)sourceSize.width,
		    (unsigned)sourceSize.height, 0) != 0;
	}
	if (failed) {
		akios_say("refused: a buffer-to-texture copy of %lux%lu: %s\n", (unsigned long)sourceSize.width,
		    (unsigned long)sourceSize.height, hakios_metal_error());
		hakios_metal_cb_refuse(cb, hakios_metal_error());
	}
	hakios_metal_texture_free(rows);
	hakios_metal_buffer_free(staging);
}

- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel
    sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toBuffer:(id<MTLBuffer>)destinationBuffer
    destinationOffset:(NSUInteger)destinationOffset destinationBytesPerRow:(NSUInteger)destinationBytesPerRow
    destinationBytesPerImage:(NSUInteger)destinationBytesPerImage options:(MTLBlitOption)options
{
	if (options != MTLBlitOptionNone) {
		akios_say("refused: a texture-to-buffer copy with blit options %#lx\n", (unsigned long)options);
		hakios_metal_cb_refuse([_akCommandBuffer akCore], "a texture-to-buffer copy with blit options");
		return;
	}
	[self copyFromTexture:sourceTexture sourceSlice:sourceSlice sourceLevel:sourceLevel sourceOrigin:sourceOrigin sourceSize:sourceSize
	    toBuffer:destinationBuffer destinationOffset:destinationOffset destinationBytesPerRow:destinationBytesPerRow
	    destinationBytesPerImage:destinationBytesPerImage];
}

- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel
    sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toBuffer:(id<MTLBuffer>)destinationBuffer
    destinationOffset:(NSUInteger)destinationOffset destinationBytesPerRow:(NSUInteger)destinationBytesPerRow
    destinationBytesPerImage:(NSUInteger)destinationBytesPerImage
{
	hakios_metal_cb *cb = [_akCommandBuffer akCore];
	hakios_metal_texture *from = [self akTexture:sourceTexture what:"source"];
	hakios_metal_buffer *to = from != NULL ? [self akBuffer:destinationBuffer what:"destination"] : NULL;
	hakios_metal_buffer *staging = NULL;
	uint64_t pitch = 0;
	int failed;

	(void)destinationBytesPerImage;
	if (to == NULL) {
		return;
	}
	if (sourceSlice != 0 || sourceOrigin.z != 0 || sourceSize.depth != 1 || sourceSize.width == 0 || sourceSize.height == 0) {
		char why[160];

		snprintf(why, sizeof(why), "a texture-to-buffer copy of %lux%lux%lu from slice %lu: one slice of depth 1 is served",
		    (unsigned long)sourceSize.width, (unsigned long)sourceSize.height, (unsigned long)sourceSize.depth, (unsigned long)sourceSlice);
		akios_say("refused: %s\n", why);
		hakios_metal_cb_refuse(cb, why);
		return;
	}
	hakios_metal_texture *rows = [self akRows:to offset:destinationOffset bytesPerRow:destinationBytesPerRow like:from
	    size:sourceSize staging:&staging pitch:&pitch];
	if (rows == NULL) {
		akios_say("refused: a texture-to-buffer copy's rows: %s\n", hakios_metal_error());
		hakios_metal_cb_refuse(cb, "a texture-to-buffer copy's rows could not be made a texture");
		hakios_metal_buffer_free(staging);
		return;
	}
	failed = hakios_metal_cb_blit(cb, from, (unsigned)sourceLevel, (unsigned)sourceOrigin.x, (unsigned)sourceOrigin.y,
	    (unsigned)sourceSize.width, (unsigned)sourceSize.height, rows, 0, 0, 0, (unsigned)sourceSize.width, (unsigned)sourceSize.height,
	    0) != 0;
	if (staging != NULL) {
		uint64_t length = hakios_metal_buffer_length(to);
		uint64_t rowBytes = (uint64_t)hakios_metal_texture_bytes_per_pixel(from) * sourceSize.width;

		for (NSUInteger y = 0; y < sourceSize.height && !failed; y++) {
			uint64_t at = destinationOffset + (uint64_t)y * destinationBytesPerRow;
			uint64_t n = at < length ? MIN(MIN(rowBytes, (uint64_t)destinationBytesPerRow), length - at) : 0;

			failed = n != 0 && hakios_metal_cb_copy(cb, staging, (uint64_t)y * pitch, to, at, n) != 0;
		}
	}
	if (failed) {
		akios_say("refused: a texture-to-buffer copy of %lux%lu: %s\n", (unsigned long)sourceSize.width,
		    (unsigned long)sourceSize.height, hakios_metal_error());
		hakios_metal_cb_refuse(cb, hakios_metal_error());
	}
	hakios_metal_texture_free(rows);
	hakios_metal_buffer_free(staging);
}

/* texture access counters belong to sparse textures, which are not served: nothing counted, nothing reset */
- (void)getTextureAccessCounters:(id<MTLTexture>)texture region:(MTLRegion)region mipLevel:(NSUInteger)mipLevel slice:(NSUInteger)slice
    resetCounters:(BOOL)reset countersBuffer:(id<MTLBuffer>)buffer countersBufferOffset:(NSUInteger)offset
{
	(void)texture; (void)region; (void)mipLevel; (void)slice; (void)reset; (void)buffer; (void)offset;
}
- (void)resetTextureAccessCounters:(id<MTLTexture>)texture region:(MTLRegion)region mipLevel:(NSUInteger)mipLevel slice:(NSUInteger)slice
{
	(void)texture; (void)region; (void)mipLevel; (void)slice;
}

- (void)endEncoding
{
	[super endEncoding];   /* (the base retained the command buffer in its initialiser and gives it back here) */
}

@end

/* ============================================================================================================
 * Compute
 * ============================================================================================================ */

@implementation AkiosMaliComputeEncoder {
	__unsafe_unretained AkiosMaliCommandBuffer *_akCommandBuffer;
	AkiosMaliComputePipelineState *_akPipeline;
	__strong id _akBuffers[AKIOS_MAX_BUFFERS];
	uint64_t _akOffsets[AKIOS_MAX_BUFFERS];
	unsigned _akHighest;                        /* one past the highest buffer index bound */
	__strong id _akTextures[AKIOS_MAX_TEXTURES];
	unsigned _akHighestTexture;
	__strong id _akSamplers[AKIOS_MAX_SAMPLERS];
	unsigned _akHighestSampler;
	NSUInteger _akThreadgroupLength;            /* setThreadgroupMemoryLength: at index 0 */
	char _akRefused[160];                       /* a binding this encoder could not take: its dispatches fail by it */
}

+ (void)load
{
	class_addProtocol(self, @protocol(MTLComputeCommandEncoder));
}

- (instancetype)initWithAkiosCommandBuffer:(AkiosMaliCommandBuffer *)commandBuffer
{
	self = [super initWithCommandBuffer:commandBuffer];
	if (self != nil) {
		_akCommandBuffer = commandBuffer;
	}
	return self;
}

- (id)device { return [_akCommandBuffer device]; }
- (MTLDispatchType)dispatchType { return MTLDispatchTypeSerial; }

- (void)akRefuse:(NSString *)why
{
	akios_say("refused: %s\n", why.UTF8String);
	if (_akRefused[0] == '\0') {
		snprintf(_akRefused, sizeof(_akRefused), "%s", why.UTF8String);
	}
}

- (void)setComputePipelineState:(id<MTLComputePipelineState>)state
{
	if (state != nil && ![(id)state isKindOfClass:[AkiosMaliComputePipelineState class]]) {
		[self akRefuse:@"a compute pipeline state that is not this device's"];
		return;
	}
	_akPipeline = (AkiosMaliComputePipelineState *)state;
}

- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	if (index >= AKIOS_MAX_BUFFERS || (buffer != nil && ![(id)buffer isKindOfClass:[AkiosMaliBuffer class]])) {
		[self akRefuse:[NSString stringWithFormat:@"the buffer at index %lu (%s)", (unsigned long)index,
		    index >= AKIOS_MAX_BUFFERS ? "past Metal's table" : "not this device's"]];
		return;
	}
	_akBuffers[index] = buffer;
	_akOffsets[index] = offset;
	if (buffer != nil && index + 1 > _akHighest) {
		_akHighest = (unsigned)index + 1;
	}
}

- (void)setBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	if (index < AKIOS_MAX_BUFFERS && _akBuffers[index] != nil) {
		_akOffsets[index] = offset;
	}
}

- (void)setBuffers:(const id<MTLBuffer> __unsafe_unretained *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
	}
}

/* small constant data: a buffer of this device (kept by the command buffer through the binding) */
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
	id<MTLBuffer> buffer = [[self device] newBufferWithBytes:bytes length:length options:MTLResourceStorageModeShared];

	if (buffer == nil) {
		[self akRefuse:[NSString stringWithFormat:@"no buffer for %lu bytes at index %lu", (unsigned long)length, (unsigned long)index]];
		return;
	}
	[self setBuffer:buffer offset:0 atIndex:index];
}

- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index
{
	if (index >= AKIOS_MAX_TEXTURES || (texture != nil && ![(id)texture isKindOfClass:[AkiosMaliTexture class]])) {
		[self akRefuse:[NSString stringWithFormat:@"the texture at index %lu (%s)", (unsigned long)index,
		    index >= AKIOS_MAX_TEXTURES ? "past Metal's table" : "not this device's"]];
		return;
	}
	_akTextures[index] = texture;
	if (texture != nil && index + 1 > _akHighestTexture) {
		_akHighestTexture = (unsigned)index + 1;
	}
}

- (void)setTextures:(const id<MTLTexture> __unsafe_unretained *)textures withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setTexture:textures[i] atIndex:range.location + i];
	}
}

- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index
{
	if (index >= AKIOS_MAX_SAMPLERS || (sampler != nil && ![(id)sampler isKindOfClass:[AkiosMaliSamplerState class]])) {
		[self akRefuse:[NSString stringWithFormat:@"the sampler at index %lu (%s)", (unsigned long)index,
		    index >= AKIOS_MAX_SAMPLERS ? "past Metal's table" : "not this device's"]];
		return;
	}
	_akSamplers[index] = sampler;
	if (sampler != nil && index + 1 > _akHighestSampler) {
		_akHighestSampler = (unsigned)index + 1;
	}
}

- (void)setSamplerStates:(const id<MTLSamplerState> __unsafe_unretained *)samplers withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setSamplerState:samplers[i] atIndex:range.location + i];
	}
}

/* (the clamps of a binding are not applied yet: the sampler is bound as it was made, as the earlier plug-in did) */
- (void)setSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index
{
	(void)lodMinClamp; (void)lodMaxClamp;
	[self setSamplerState:sampler atIndex:index];
}

- (void)setSamplerStates:(const id<MTLSamplerState> __unsafe_unretained *)samplers lodMinClamps:(const float *)lodMinClamps
    lodMaxClamps:(const float *)lodMaxClamps withRange:(NSRange)range
{
	(void)lodMinClamps; (void)lodMaxClamps;
	[self setSamplerStates:samplers withRange:range];
}

/* index 0 is the [[threadgroup(0)]] argument the front end places past the static arrays; another index is not served */
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index
{
	if (index == 0) {
		_akThreadgroupLength = length;
	} else if (length != 0) {
		[self akRefuse:[NSString stringWithFormat:@"%lu bytes of threadgroup memory at index %lu (index 0 alone is served)",
		    (unsigned long)length, (unsigned long)index]];
	}
}

/* GROUPS threadgroups, or (GRID) that many threads, or (ARGS) the counts read by the GPU from ARGS at OFFSET */
- (void)akDispatch:(MTLSize)size grid:(BOOL)grid indirect:(id<MTLBuffer>)args offset:(NSUInteger)offset threads:(MTLSize)threads
{
	hakios_metal_cb *cb = [_akCommandBuffer akCore];
	hakios_metal_buffer *buffers[AKIOS_MAX_BUFFERS];
	hakios_metal_texture *textures[AKIOS_MAX_TEXTURES];
	hakios_metal_sampler *samplers[AKIOS_MAX_SAMPLERS];
	const unsigned g[3] = { (unsigned)size.width, (unsigned)size.height, (unsigned)size.depth };
	const unsigned t[3] = { (unsigned)threads.width, (unsigned)threads.height, (unsigned)threads.depth };
	int r;

	if (_akPipeline == nil || _akRefused[0] != '\0') {
		const char *why = _akPipeline == nil ? "a dispatch with no pipeline state" : _akRefused;

		akios_say("refused: a dispatch: %s; the command buffer is failed\n", why);
		hakios_metal_cb_refuse(cb, why);
		return;
	}
	if (args != nil && ![(id)args isKindOfClass:[AkiosMaliBuffer class]]) {
		hakios_metal_cb_refuse(cb, "an indirect dispatch's argument buffer from another device");
		return;
	}
	[_akCommandBuffer akHold:_akPipeline];
	for (unsigned i = 0; i < _akHighest; i++) {
		buffers[i] = _akBuffers[i] != nil ? [(AkiosMaliBuffer *)_akBuffers[i] akCore] : NULL;
		[_akCommandBuffer akHold:_akBuffers[i]];
	}
	for (unsigned i = 0; i < _akHighestTexture; i++) {
		textures[i] = _akTextures[i] != nil ? [(AkiosMaliTexture *)_akTextures[i] akCore] : NULL;
		[_akCommandBuffer akHold:_akTextures[i]];
	}
	for (unsigned i = 0; i < _akHighestSampler; i++) {
		samplers[i] = _akSamplers[i] != nil ? [(AkiosMaliSamplerState *)_akSamplers[i] akCore] : NULL;
	}
	hakios_metal_cb_set_threadgroup_length(cb, (unsigned)_akThreadgroupLength);
	if (args != nil) {
		[_akCommandBuffer akHold:args];
		r = hakios_metal_cb_dispatch_indirect(cb, [_akPipeline akCore], [(AkiosMaliBuffer *)args akCore], (uint64_t)offset, t,
		    buffers, _akOffsets, _akHighest, textures, _akHighestTexture, samplers, _akHighestSampler);
	} else if (grid) {
		r = hakios_metal_cb_dispatch_threads2(cb, [_akPipeline akCore], g, t, buffers, _akOffsets, _akHighest, textures,
		    _akHighestTexture, samplers, _akHighestSampler);
	} else {
		r = hakios_metal_cb_dispatch2(cb, [_akPipeline akCore], g, t, buffers, _akOffsets, _akHighest, textures, _akHighestTexture,
		    samplers, _akHighestSampler);
	}
	if (r != 0) {
		akios_say("refused: a dispatch of %s over %ux%ux%u of %ux%ux%u: %s\n", hakios_metal_kernel_name([_akPipeline akCore]),
		    g[0], g[1], g[2], t[0], t[1], t[2], hakios_metal_error());
		hakios_metal_cb_refuse(cb, hakios_metal_error());
	}
}

- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)threads
{
	[self akDispatch:groups grid:NO indirect:nil offset:0 threads:threads];
}

/* (a grid that does not divide: the core runs whole threadgroups, its kernels return at once past the grid) */
- (void)dispatchThreads:(MTLSize)threads threadsPerThreadgroup:(MTLSize)size
{
	[self akDispatch:threads grid:YES indirect:nil offset:0 threads:size];
}

- (void)dispatchThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:(NSUInteger)offset
    threadsPerThreadgroup:(MTLSize)threads
{
	[self akDispatch:MTLSizeMake(0, 0, 0) grid:NO indirect:buffer offset:offset threads:threads];
}

/* served by construction: the core flushes the caches between jobs, a queue runs in order, everything is resident */
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope { (void)scope; }
- (void)memoryBarrierWithResources:(const id<MTLResource> __unsafe_unretained *)resources count:(NSUInteger)count
{
	(void)resources; (void)count;
}
- (void)updateFence:(id<MTLFence>)fence { (void)fence; }
- (void)waitForFence:(id<MTLFence>)fence { (void)fence; }
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage
{
	(void)usage;
	[_akCommandBuffer akHold:resource];
}
- (void)useResources:(const id<MTLResource> __unsafe_unretained *)resources count:(NSUInteger)count usage:(MTLResourceUsage)usage
{
	(void)usage;
	for (NSUInteger i = 0; i < count; i++) {
		[_akCommandBuffer akHold:resources[i]];
	}
}
- (void)useHeap:(id<MTLHeap>)heap { [_akCommandBuffer akHold:heap]; }
- (void)useHeaps:(const id<MTLHeap> __unsafe_unretained *)heaps count:(NSUInteger)count
{
	for (NSUInteger i = 0; i < count; i++) {
		[_akCommandBuffer akHold:heaps[i]];
	}
}
- (void)setThreadgroupPackingDisabled:(BOOL)disabled { (void)disabled; }

/* imageblocks and stage-in regions are not served: refused by name, and the dispatches that follow fail by it */
- (void)setImageblockWidth:(NSUInteger)width height:(NSUInteger)height
{
	[self akRefuse:[NSString stringWithFormat:@"an imageblock of %lux%lu (tile memory is not served)", (unsigned long)width,
	    (unsigned long)height]];
}
- (void)setStageInRegion:(MTLRegion)region
{
	(void)region;
	[self akRefuse:@"a stage-in region (not served)"];
}
- (void)setStageInRegionWithIndirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:(NSUInteger)offset
{
	(void)buffer; (void)offset;
	[self akRefuse:@"an indirect stage-in region (not served)"];
}

- (void)endEncoding
{
	for (unsigned i = 0; i < AKIOS_MAX_BUFFERS; i++) _akBuffers[i] = nil;
	for (unsigned i = 0; i < AKIOS_MAX_TEXTURES; i++) _akTextures[i] = nil;
	for (unsigned i = 0; i < AKIOS_MAX_SAMPLERS; i++) _akSamplers[i] = nil;
	_akPipeline = nil;
	[super endEncoding];   /* (the base retained the command buffer in its initialiser and gives it back here) */
}

@end
