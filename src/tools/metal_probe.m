/*
 * metal_probe: does Metal's device draw, through whatever transport its driver uses?
 *   1. a blit fill of a shared buffer, read back;
 *   2. a render pass that clears a 64x64 BGRA8 texture to red, read back;
 *   3. the same into an IOSurface-backed texture (the kind CoreAnimation draws into).
 * Each command buffer's status and error are printed; exit status = the first step that failed.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOSurface/IOSurfaceRef.h>
#include <stdio.h>

static int
clearAndCheck(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLTexture> tex, const char *what)
{
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = tex;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
	[enc endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	uint32_t px[4] = { 0 };
	[tex getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(10, 10, 4, 1) mipmapLevel:0];
	printf("%s: status %ld%s%s, pixel 0x%08x (0xffff0000 expected, BGRA red)\n", what, (long)cb.status,
	    cb.error ? ", error " : "", cb.error ? cb.error.localizedDescription.UTF8String : "", px[0]);
	return px[0] == 0xffff0000 ? 0 : 1;
}

int
main(void)
{
	@autoreleasepool {
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		printf("device: %s\n", dev ? dev.name.UTF8String : "(none)");
		if (dev == nil) {
			return 9;
		}
		id<MTLCommandQueue> q = [dev newCommandQueue];

		/* 1 */
		id<MTLBuffer> buf = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
		[blit fillBuffer:buf range:NSMakeRange(0, 4096) value:0x5a];
		[blit endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		const uint8_t *b = buf.contents;
		printf("1: blit fill: status %ld%s%s, bytes 0x%02x 0x%02x (0x5a expected)\n", (long)cb.status,
		    cb.error ? ", error " : "", cb.error ? cb.error.localizedDescription.UTF8String : "", b[0], b[4095]);
		if (b[0] != 0x5a || b[4095] != 0x5a) {
			return 1;
		}

		/* 2 */
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		    width:64 height:64 mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		td.storageMode = MTLStorageModeShared;
		if (clearAndCheck(dev, q, [dev newTextureWithDescriptor:td], "2: clear a texture") != 0) {
			return 2;
		}

		/* 3 */
		IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{
			(id)kIOSurfaceWidth: @64, (id)kIOSurfaceHeight: @64, (id)kIOSurfaceBytesPerElement: @4,
			(id)kIOSurfaceBytesPerRow: @(64 * 4), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
		id<MTLTexture> st = s ? [dev newTextureWithDescriptor:td iosurface:s plane:0] : nil;
		if (st == nil) {
			printf("3: no IOSurface texture\n");
			return 3;
		}
		if (clearAndCheck(dev, q, st, "3: clear an IOSurface texture") != 0) {
			return 3;
		}
		IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
		printf("3: the surface's own memory says 0x%08x\n", ((uint32_t *)IOSurfaceGetBaseAddress(s))[64 * 10 + 10]);
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
		CFRelease(s);
		printf("all steps passed\n");
	}
	return 0;
}
