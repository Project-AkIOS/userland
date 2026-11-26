/*
 * akios_metal_test: the AkiosMetal bundle (IOGPU-based) driven by itself, beside the window server's plug-in:
 * its device made from the accelerator, a queue, and command buffers through IOGPU's submission and completion.
 *   A1. 1000 empty command buffers: completion handlers in commit order, all Completed
 *   A2. waitUntilCompleted on the last one
 *   A3. a command buffer that signals a shared event (kernel command 3): the value set
 *   B1-B4. buffers: contents and GPU address, 10000 made and freed, no-copy with its deallocator, private
 *   C1. blit fills and copies of odd lengths at odd offsets (the byte and the word shaders), edges untouched
 *   C2. compute: fill_id from a .metallib (hakios-metal's tools/kernels, tools/mesa/pan/mk-metallib.py) over
 *       dispatchThreadgroups (4 x 64, c in a buffer) and dispatchThreads (1000, c by setBytes:)
 *   C3. textures: tex_fill writes one, tex_copy copies one, tex_sample_gid samples one, read back with getBytes;
 *       a buffer -> texture -> buffer blit round trip at an offset that is not 64-byte aligned (the staging path)
 *   C4. 40 command buffers, each filling its own slot: completed in commit order, every slot right
 *   C5. a fill at an address nothing maps (HAKIOS_MALI_FAULT_TEST while it is encoded): the command buffer ends
 *       in error, and C6 the next one completes (the device and the queue keep working)
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

#include "metal_kernels_lib.h"   /* (hakios-base userland/src: fill_id, tg_arg, pvt_fill, tex_fill, tex_copy, tex_sample_gid) */

static const char *
cb_error(id<MTLCommandBuffer> cb)
{
	return cb.error != nil ? cb.error.localizedDescription.UTF8String : "no error";
}

int
main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IONBF, 0);   /* (every line as it happens: a crash must not take the log with it) */
	@autoreleasepool {
		const char *path = argc > 1 ? argv[1] : "/akita/lib/AkiosMetal.bundle/AkiosMetal";
		if (dlopen(path, RTLD_NOW) == NULL) {
			printf("bundle: %s\n", dlerror());
			return 1;
		}
		io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAcceleratorES"));
		Class cls = NSClassFromString(@"AkiosMaliDevice");
		id<MTLDevice> dev = cls ? ((id (*)(id, SEL, io_service_t))objc_msgSend)([cls alloc],
		    @selector(initWithAcceleratorPort:), service) : nil;
		printf("device: %s (%s)\n", dev ? dev.name.UTF8String : "nil", dev ? object_getClassName(dev) : "-");
		if (dev == nil) {
			return 1;
		}
		id<MTLCommandQueue> q = [dev newCommandQueue];
		printf("queue: %s\n", q ? object_getClassName(q) : "nil");
		if (q == nil) {
			return 2;
		}

		/* A1, A2 */
		__block atomic_int next = 0, bad = 0;
		id<MTLCommandBuffer> last = nil;
		NSDate *t0 = [NSDate date];
		for (int i = 0; i < 1000; i++) {
			id<MTLCommandBuffer> cb = [q commandBuffer];
			int mine = i;
			[cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
				if (atomic_fetch_add(&next, 1) != mine || done.status != MTLCommandBufferStatusCompleted) {
					atomic_fetch_add(&bad, 1);
				}
			}];
			[cb commit];
			last = cb;
		}
		[last waitUntilCompleted];
		usleep(100000);
		printf("A1/A2: %d of 1000 completed in order, %d out of order or failed, %.1f ms, last status %ld\n",
		    atomic_load(&next), atomic_load(&bad), -[t0 timeIntervalSinceNow] * 1000, (long)last.status);
		if (atomic_load(&next) != 1000 || atomic_load(&bad) != 0) {
			return 3;
		}

		/* A3 */
		id<MTLSharedEvent> ev = [dev newSharedEvent];
		id<MTLCommandBuffer> cb = [q commandBuffer];
		[cb encodeSignalEvent:ev value:42];
		[cb commit];
		[cb waitUntilCompleted];
		printf("A3: shared event %s, signaled %llu (42 expected), status %ld\n", ev ? object_getClassName(ev) : "nil",
		    ev.signaledValue, (long)cb.status);
		if (ev.signaledValue != 42) {
			return 4;
		}
		/* B1: contents and GPU address */
		id<MTLBuffer> b = [dev newBufferWithLength:100000 options:MTLResourceStorageModeShared];
		uint8_t *bytes = b.contents;
		int zero = 1;
		for (int i = 0; bytes && i < 100000; i++) {
			zero &= bytes[i] == 0;
		}
		if (bytes) {
			memset(bytes, 0x77, 100000);
		}
		printf("B1: buffer %s, length %lu, contents %p (zeroed %d), gpuAddress 0x%llx, read back 0x%02x\n",
		    b ? object_getClassName(b) : "nil", (unsigned long)b.length, bytes, zero, b.gpuAddress, bytes ? bytes[99999] : 0);
		if (b == nil || bytes == NULL || !zero || b.gpuAddress == 0 || bytes[99999] != 0x77) {
			return 5;
		}
		/* B2: many made and freed: the allocated size comes back */
		uint64_t before = dev.currentAllocatedSize;
		for (int i = 0; i < 10000; i++) {
			@autoreleasepool {
				id<MTLBuffer> t = [dev newBufferWithLength:4096 + (i % 7) * 4096 options:0];
				if (t == nil) {
					printf("B2: buffer %d not made\n", i);
					return 6;
				}
			}
		}
		printf("B2: 10000 buffers made and freed; allocated size %llu before, %llu after\n", before, dev.currentAllocatedSize);
		/* B3: no-copy, its deallocator */
		__block int deallocated = 0;
		void *mine = NULL;
		posix_memalign(&mine, 16384, 32768);
		@autoreleasepool {
			id<MTLBuffer> n = [dev newBufferWithBytesNoCopy:mine length:32768 options:0
			    deallocator:^(void *p, NSUInteger l) { deallocated = 1; free(p); }];
			printf("B3: no-copy buffer %s, contents %s the pointer, gpuAddress 0x%llx\n", n ? "made" : "nil",
			    n.contents == mine ? "is" : "is NOT", n.gpuAddress);
			if (n == nil || n.contents != mine) {
				return 7;
			}
		}
		usleep(50000);
		printf("B3: deallocator ran: %d\n", deallocated);
		/* B4: private */
		id<MTLBuffer> pv = [dev newBufferWithLength:65536 options:MTLResourceStorageModePrivate];
		printf("B4: private buffer %s, gpuAddress 0x%llx\n", pv ? "made" : "nil", pv.gpuAddress);
		if (pv == nil || pv.gpuAddress == 0) {
			return 8;
		}

		/* C1: fills and copies of odd lengths at odd offsets, and word-sized ones */
		{
			const NSUInteger N = 100003;
			id<MTLBuffer> a = [dev newBufferWithLength:N options:MTLResourceStorageModeShared];
			id<MTLBuffer> c = [dev newBufferWithLength:N options:MTLResourceStorageModeShared];
			uint8_t *pa = a.contents, *pc = c.contents, *want = malloc(N);
			for (NSUInteger i = 0; i < N; i++) {
				pa[i] = (uint8_t)(i * 7 + 3);
			}
			memset(pc, 0xee, N);
			memset(want, 0xee, N);
			id<MTLCommandBuffer> cb1 = [q commandBuffer];
			id<MTLBlitCommandEncoder> be = [cb1 blitCommandEncoder];
			if (be == nil) {
				printf("C1: no blit encoder (%s)\n", cb1 ? object_getClassName(cb1) : "no command buffer");
				return 9;
			}
			[be fillBuffer:c range:NSMakeRange(7, 1001) value:0x5a];
			memset(want + 7, 0x5a, 1001);
			[be copyFromBuffer:a sourceOffset:13 toBuffer:c destinationOffset:2003 size:50001];
			memcpy(want + 2003, pa + 13, 50001);
			[be fillBuffer:c range:NSMakeRange(60000, 4096) value:0xc3];
			memset(want + 60000, 0xc3, 4096);
			[be copyFromBuffer:a sourceOffset:8192 toBuffer:c destinationOffset:65536 size:16384];
			memcpy(want + 65536, pa + 8192, 16384);
			[be copyFromBuffer:a sourceOffset:N - 3 toBuffer:c destinationOffset:N - 3 size:3];
			memcpy(want + N - 3, pa + N - 3, 3);
			[be endEncoding];
			[cb1 commit];
			[cb1 waitUntilCompleted];
			NSUInteger wrong = 0, first = N;
			for (NSUInteger i = 0; i < N; i++) {
				if (pc[i] != want[i]) {
					wrong++;
					if (first == N) first = i;
				}
			}
			printf("C1: blits: status %ld (%s), %lu of %lu bytes wrong (first at %ld: 0x%02x, 0x%02x expected)\n", (long)cb1.status,
			    cb_error(cb1), (unsigned long)wrong, (unsigned long)N, first == N ? -1L : (long)first, first == N ? 0 : pc[first],
			    first == N ? 0 : want[first]);
			free(want);
			if (cb1.status != MTLCommandBufferStatusCompleted || wrong != 0) {
				return 10;
			}
		}

		/* C2: compute */
		NSError *error = nil;
		dispatch_data_t data = dispatch_data_create(metal_kernels_lib, sizeof(metal_kernels_lib), NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
		id<MTLLibrary> library = [dev newLibraryWithData:data error:&error];
		id<MTLFunction> fn = [library newFunctionWithName:@"fill_id"];
		id<MTLComputePipelineState> fill = fn ? [dev newComputePipelineStateWithFunction:fn error:&error] : nil;
		printf("C2: library %s, fill_id %s, pipeline %s%s%s\n", library ? "made" : "nil", fn ? "found" : "nil",
		    fill ? object_getClassName(fill) : "nil", error ? ": " : "", error ? error.localizedDescription.UTF8String : "");
		if (fill == nil) {
			return 11;
		}
		{
			id<MTLBuffer> ka = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
			id<MTLBuffer> kb = [dev newBufferWithLength:8192 options:MTLResourceStorageModeShared];
			id<MTLBuffer> kc = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
			memset(ka.contents, 0xee, 4096);
			memset(kb.contents, 0xee, 8192);
			*(uint32_t *)kc.contents = 0x1234;
			uint32_t c2 = 0xabcd;
			id<MTLCommandBuffer> cb2 = [q commandBuffer];
			id<MTLComputeCommandEncoder> ce = [cb2 computeCommandEncoder];
			[ce setComputePipelineState:fill];
			[ce setBuffer:ka offset:0 atIndex:0];
			[ce setBuffer:kc offset:0 atIndex:1];
			[ce dispatchThreadgroups:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
			[ce setBuffer:kb offset:0 atIndex:0];
			[ce setBytes:&c2 length:sizeof(c2) atIndex:1];
			[ce dispatchThreads:MTLSizeMake(1000, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
			[ce endEncoding];
			[cb2 commit];
			[cb2 waitUntilCompleted];
			const uint32_t *wa = ka.contents, *wb = kb.contents;
			unsigned ra = 0, rb = 0, past = 1;
			for (uint32_t i = 0; i < 256; i++) ra += wa[i] == i * 0x9E3779B1u + 0x1234u;
			for (uint32_t i = 0; i < 1000; i++) rb += wb[i] == i * 0x9E3779B1u + 0xabcdu;
			for (unsigned i = 256; i < 1024; i++) past = past && wa[i] == 0xeeeeeeeeu;
			for (unsigned i = 1000; i < 2048; i++) past = past && wb[i] == 0xeeeeeeeeu;
			printf("C2: compute: status %ld (%s), dispatchThreadgroups %u of 256, dispatchThreads %u of 1000, past the grids %s\n",
			    (long)cb2.status, cb_error(cb2), ra, rb, past ? "untouched" : "CHANGED");
			if (cb2.status != MTLCommandBufferStatusCompleted || ra != 256 || rb != 1000 || !past) {
				return 12;
			}
		}

		/* C3: textures written, copied and sampled by kernels; a blit round trip through a texture */
		{
			const unsigned W = 16;
			id<MTLFunction> ff = [library newFunctionWithName:@"tex_fill"], cf = [library newFunctionWithName:@"tex_copy"],
			    sf = [library newFunctionWithName:@"tex_sample_gid"];
			id<MTLComputePipelineState> fp = ff ? [dev newComputePipelineStateWithFunction:ff error:&error] : nil;
			id<MTLComputePipelineState> cp = cf ? [dev newComputePipelineStateWithFunction:cf error:&error] : nil;
			id<MTLComputePipelineState> sp = sf ? [dev newComputePipelineStateWithFunction:sf error:&error] : nil;
			MTLTextureDescriptor *u32 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:W
			    height:W mipmapped:NO];
			u32.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
			MTLTextureDescriptor *u8 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W
			    height:W mipmapped:NO];
			u8.usage = MTLTextureUsageShaderRead;
			id<MTLTexture> filled = [dev newTextureWithDescriptor:u32], src = [dev newTextureWithDescriptor:u32],
			    copied = [dev newTextureWithDescriptor:u32], sampled = [dev newTextureWithDescriptor:u8];
			id<MTLSamplerState> nearest = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
			id<MTLBuffer> samples = [dev newBufferWithLength:W * W * 16 options:MTLResourceStorageModeShared];
			printf("C3: pipelines %s %s %s, textures %s (gpuAddress 0x%llx, %lux%lu, rows %lu), sampler %s%s%s\n",
			    fp ? "made" : "nil", cp ? "made" : "nil", sp ? "made" : "nil", filled ? object_getClassName(filled) : "nil",
			    filled ? [(id)filled gpuAddress] : 0, (unsigned long)filled.width, (unsigned long)filled.height,
			    (unsigned long)filled.bufferBytesPerRow, nearest ? object_getClassName(nearest) : "nil", error ? ": " : "",
			    error ? error.localizedDescription.UTF8String : "");
			if (fp == nil || cp == nil || sp == nil || filled == nil || src == nil || copied == nil || sampled == nil || nearest == nil) {
				return 13;
			}
			uint32_t in[W * W * 4], zero[W * W * 4], back[W * W * 4];
			uint8_t px[W * W * 4];
			memset(zero, 0, sizeof(zero));
			for (uint32_t y = 0; y < W; y++) {
				for (uint32_t x = 0; x < W; x++) {
					uint32_t *t = &in[(y * W + x) * 4];
					uint8_t *p = &px[(y * W + x) * 4];

					t[0] = x + 16 * y, t[1] = 0x100 + x, t[2] = 0x200 + y, t[3] = 0x300;
					p[0] = (uint8_t)(x * 16), p[1] = (uint8_t)(y * 16), p[2] = (uint8_t)(x + y), p[3] = 255;
				}
			}
			MTLRegion all = MTLRegionMake2D(0, 0, W, W);
			[src replaceRegion:all mipmapLevel:0 withBytes:in bytesPerRow:W * 16];
			[filled replaceRegion:all mipmapLevel:0 withBytes:zero bytesPerRow:W * 16];
			[copied replaceRegion:all mipmapLevel:0 withBytes:zero bytesPerRow:W * 16];
			[sampled replaceRegion:all mipmapLevel:0 withBytes:px bytesPerRow:W * 4];
			memset(samples.contents, 0, W * W * 16);
			uint32_t c3 = 0x1234;
			id<MTLCommandBuffer> cb3 = [q commandBuffer];
			id<MTLComputeCommandEncoder> e3 = [cb3 computeCommandEncoder];
			[e3 setComputePipelineState:fp];
			[e3 setTexture:filled atIndex:0];
			[e3 setBytes:&c3 length:sizeof(c3) atIndex:0];
			[e3 dispatchThreads:MTLSizeMake(W, W, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
			[e3 setComputePipelineState:cp];
			[e3 setTexture:copied atIndex:0];
			[e3 setTexture:src atIndex:1];
			[e3 dispatchThreadgroups:MTLSizeMake(2, 2, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
			[e3 setComputePipelineState:sp];
			[e3 setTexture:sampled atIndex:0];
			[e3 setSamplerState:nearest atIndex:0];
			[e3 setBuffer:samples offset:0 atIndex:0];
			[e3 dispatchThreads:MTLSizeMake(W, W, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
			[e3 endEncoding];
			[cb3 commit];
			[cb3 waitUntilCompleted];
			unsigned fillright = 0, copyright = 0, sampleright = 0;
			[filled getBytes:back bytesPerRow:W * 16 fromRegion:all mipmapLevel:0];
			for (uint32_t y = 0; y < W; y++) {
				for (uint32_t x = 0; x < W; x++) {
					const uint32_t *t = &back[(y * W + x) * 4];

					fillright += t[0] == (y * W + x) * 0x9E3779B1u + 0x1234u && t[1] == x && t[2] == y && t[3] == 0xdead;
				}
			}
			uint32_t first[4] = { back[0], back[1], back[2], back[3] };
			[copied getBytes:back bytesPerRow:W * 16 fromRegion:all mipmapLevel:0];
			for (unsigned i = 0; i < W * W; i++) copyright += memcmp(&back[i * 4], &in[i * 4], 16) == 0;
			const float *f = samples.contents;
			for (unsigned i = 0; i < W * W; i++) {
				int ok = 1;

				for (int ch = 0; ch < 4; ch++) {
					float d = f[i * 4 + ch] - px[i * 4 + ch] / 255.0f;
					ok = ok && d < 0.002f && d > -0.002f;
				}
				sampleright += ok;
			}
			printf("C3: textures: written %u of 256 (texel 0: %#x %u %u %#x), copied %u of 256, sampled %u of 256; status %ld (%s)\n",
			    fillright, first[0], first[1], first[2], first[3], copyright, sampleright, (long)cb3.status, cb_error(cb3));
			if (cb3.status != MTLCommandBufferStatusCompleted || fillright != 256 || copyright != 256 || sampleright != 256) {
				return 14;
			}
			/* a buffer's rows (from an offset of 20 bytes, 132 bytes apart: staged) into a 32 x 16 R32Uint texture at
			 * (0, 0), and the texture back into another buffer at offset 64, rows 128 bytes apart (no staging) */
			const unsigned TW = 32, TH = 16;
			MTLTextureDescriptor *r32 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:TW
			    height:TH mipmapped:NO];
			r32.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
			id<MTLTexture> rt = [dev newTextureWithDescriptor:r32];
			id<MTLBuffer> up = [dev newBufferWithLength:20 + 132 * TH options:MTLResourceStorageModeShared];
			id<MTLBuffer> down = [dev newBufferWithLength:64 + 128 * TH + 64 options:MTLResourceStorageModeShared];
			for (unsigned y = 0; y < TH; y++) {
				for (unsigned x = 0; x < TW; x++) {
					uint32_t v = 0x10000 * y + x + 1;

					memcpy((uint8_t *)up.contents + 20 + 132 * y + 4 * x, &v, 4);
				}
			}
			memset(down.contents, 0xee, down.length);
			id<MTLCommandBuffer> cb3b = [q commandBuffer];
			id<MTLBlitCommandEncoder> b3 = [cb3b blitCommandEncoder];
			[b3 copyFromBuffer:up sourceOffset:20 sourceBytesPerRow:132 sourceBytesPerImage:0 sourceSize:MTLSizeMake(TW, TH, 1)
			    toTexture:rt destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
			[b3 copyFromTexture:rt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(TW, TH, 1)
			    toBuffer:down destinationOffset:64 destinationBytesPerRow:128 destinationBytesPerImage:0];
			[b3 endEncoding];
			[cb3b commit];
			[cb3b waitUntilCompleted];
			unsigned rtright = 0;
			for (unsigned y = 0; y < TH; y++) {
				for (unsigned x = 0; x < TW; x++) {
					uint32_t v;

					memcpy(&v, (uint8_t *)down.contents + 64 + 128 * y + 4 * x, 4);
					rtright += v == 0x10000 * y + x + 1;
				}
			}
			int edges = ((uint8_t *)down.contents)[63] == 0xee && ((uint8_t *)down.contents)[64 + 128 * TH] == 0xee;
			printf("C3: buffer -> texture -> buffer: %u of %u texels right, edges %s; status %ld (%s)\n", rtright, TW * TH,
			    edges ? "untouched" : "CHANGED", (long)cb3b.status, cb_error(cb3b));
			if (rt == nil || cb3b.status != MTLCommandBufferStatusCompleted || rtright != TW * TH || !edges) {
				return 15;
			}
		}

		/* C4: 40 command buffers in order, each filling its own 4 KiB slot with its number */
		{
			id<MTLBuffer> slots = [dev newBufferWithLength:40 * 4096 options:MTLResourceStorageModeShared];
			__block atomic_int seen = 0, misordered = 0;
			id<MTLCommandBuffer> lastc = nil;
			memset(slots.contents, 0, 40 * 4096);
			for (int i = 0; i < 40; i++) {
				id<MTLCommandBuffer> cb = [q commandBuffer];
				id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
				[e fillBuffer:slots range:NSMakeRange(4096 * (NSUInteger)i, 4096) value:(uint8_t)(i + 1)];
				[e endEncoding];
				int mine = i;
				[cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
					if (atomic_fetch_add(&seen, 1) != mine || done.status != MTLCommandBufferStatusCompleted) {
						atomic_fetch_add(&misordered, 1);
					}
				}];
				[cb commit];
				lastc = cb;
			}
			[lastc waitUntilCompleted];
			usleep(100000);
			unsigned right = 0;
			for (int i = 0; i < 40; i++) {
				const uint8_t *p = (const uint8_t *)slots.contents + 4096 * i;
				int ok = 1;

				for (int k = 0; k < 4096; k++) ok = ok && p[k] == (uint8_t)(i + 1);
				right += ok;
			}
			printf("C4: 40 command buffers: %d completed, %d out of order or failed, %u of 40 slots right\n", atomic_load(&seen),
			    atomic_load(&misordered), right);
			if (atomic_load(&seen) != 40 || atomic_load(&misordered) != 0 || right != 40) {
				return 16;
			}
		}

		/* C5: a GPU page fault in one command buffer; C6: the next one runs */
		{
			id<MTLBuffer> t = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
			id<MTLCommandBuffer> bad = [q commandBuffer];
			id<MTLBlitCommandEncoder> e = [bad blitCommandEncoder];
			setenv("HAKIOS_MALI_FAULT_TEST", "1", 1);   /* (the core's fill aims at 0x1000 while this is set) */
			[e fillBuffer:t range:NSMakeRange(0, 4096) value:0x11];
			unsetenv("HAKIOS_MALI_FAULT_TEST");
			[e endEncoding];
			[bad commit];
			[bad waitUntilCompleted];
			printf("C5: a fill at an unmapped address: status %ld (%d expected), error: %s\n", (long)bad.status,
			    (int)MTLCommandBufferStatusError, cb_error(bad));
			if (bad.status != MTLCommandBufferStatusError || bad.error == nil) {
				return 17;
			}
			memset(t.contents, 0, 4096);
			id<MTLCommandBuffer> good = [q commandBuffer];
			e = [good blitCommandEncoder];
			[e fillBuffer:t range:NSMakeRange(0, 4096) value:0x22];
			[e endEncoding];
			[good commit];
			[good waitUntilCompleted];
			int filledok = 1;
			for (int k = 0; k < 4096; k++) filledok = filledok && ((uint8_t *)t.contents)[k] == 0x22;
			printf("C6: the next command buffer: status %ld (%s), filled %s\n", (long)good.status, cb_error(good),
			    filledok ? "right" : "WRONG");
			if (good.status != MTLCommandBufferStatusCompleted || !filledok) {
				return 18;
			}
		}
		printf("all steps passed\n");
	}
	return 0;
}
