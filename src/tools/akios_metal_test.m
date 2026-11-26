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
 *   D1. a triangle (tri_color_vs/fs: red, green, blue corners) into a texture over an IOSurface, read with IOSurfaceLock:
 *       the top-left pixel blue, bottom-left red, bottom-right green, top-right the clear colour (orientation top-left)
 *   D2. the other half drawn by a pass that loads (the first half kept); then a pass that only clears (all white)
 *   D3. depth: a full-screen quad at z 0 against a depth cleared to 0 (Less: nothing drawn), then to 1 (all drawn)
 *   D4. 4x MSAA into a multisample texture, resolved into a plain one at the end of the pass
 *   D5. a heap: a texture from it written by a kernel, a buffer from it filled by a blit
 *   D6. a texture view with a swizzle (red and blue swapped) sampled by tex_sample_gid
 *   D7. CoreAnimation's std_vert1_lph + inplace_copy_lph from QuartzCore's default.metallib made a pipeline
 *   D8. what CoreAnimation does for an asynchronous layer's surface (CA::OGL::AsynchronousNode::retain_surface ->
 *       MetalContext::create_surface_from_iosurface, where backboardd aborted on the unlock): a full-screen 'RGhA'
 *       IOSurface (1080x2340, RGBA16Float) made a texture (usage read + render target, labelled), a memoryless
 *       RGBA16Float and a memoryless R32Float beside it; x19..x28 must come back from those calls as they went in
 *       (CoreAnimation keeps its context in x19 across them); a pass draws into the three (clear + triangle), the
 *       surface is read on the CPU and sampled by tex_sample_gid; then 8 rounds of new surfaces made, drawn and let
 *       go, with 2048 blocks of CoreAnimation's Surface size (0x140) on the heap checked untouched after them
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

#include <IOSurface/IOSurfaceRef.h>

#include "metal_kernels_lib.h"   /* (metal/ca-plugin: fill_id, tg_arg, pvt_fill, tex_fill, tex_copy, tex_sample_gid) */
#include "mali_draw_bc.h"        /* (... and tri_color_vs/fs's bitcode: hakios-metal tools/kernels/tri_color_*.ll) */

/* A .metallib of a vertex and a fragment function from their bitcode: the container hakios-metal's
 * tools/mesa/pan/mk-metallib.py writes (its layout only; nothing of Apple's), with each function's TYPE (0 vertex,
 * 1 fragment) */
static NSData *
render_library(void)
{
	const struct { const char *name; unsigned char type; const unsigned char *bc; unsigned len; } fn[2] = {
		{ "tri_color_vs", 0, tri_color_vs_bc, tri_color_vs_bc_len },
		{ "tri_color_fs", 1, tri_color_fs_bc, tri_color_fs_bc_len },
	};
	NSMutableData *entries = [NSMutableData data], *modules = [NSMutableData data];
	for (int i = 0; i < 2; i++) {
		NSMutableData *e = [NSMutableData data];
		void (^tag)(const char *, const void *, uint16_t) = ^(const char *t, const void *v, uint16_t n) {
			[e appendBytes:t length:4];
			[e appendBytes:&n length:2];
			[e appendBytes:v length:n];
		};
		const uint16_t vers[4] = { 2, 8, 4, 0 };
		const uint64_t offt[3] = { 0, 0, modules.length }, mdsz = fn[i].len;
		tag("NAME", fn[i].name, (uint16_t)(strlen(fn[i].name) + 1));
		tag("TYPE", &fn[i].type, 1);
		tag("VERS", vers, sizeof(vers));
		tag("OFFT", offt, sizeof(offt));
		tag("MDSZ", &mdsz, sizeof(mdsz));
		[e appendBytes:"ENDT" length:4];
		uint32_t len = (uint32_t)e.length + 4;
		[entries appendBytes:&len length:4];
		[entries appendData:e];
		[modules appendBytes:fn[i].bc length:fn[i].len];
	}
	uint8_t head[0x58] = { 'M', 'T', 'L', 'B' };
	const uint16_t v[2] = { 32769, 2 };
	const uint32_t count = 2;
	const uint64_t listAt = sizeof(head), listLen = 4 + entries.length, modulesAt = listAt + listLen;
	const uint64_t total = modulesAt + modules.length, listCount = listLen - 4, modulesLen = modules.length;
	memcpy(head + 4, v, 4);
	memcpy(head + 0x10, &total, 8);
	memcpy(head + 0x18, &listAt, 8);
	memcpy(head + 0x20, &listCount, 8);
	memcpy(head + 0x48, &modulesAt, 8);
	memcpy(head + 0x50, &modulesLen, 8);
	NSMutableData *lib = [NSMutableData dataWithBytes:head length:sizeof(head)];
	[lib appendBytes:&count length:4];
	[lib appendData:entries];
	[lib appendData:modules];
	return lib;
}

/* the dominant channel of a BGRA pixel: 'r', 'g', 'b', 'k' (dark), 'w' (white) or '?' */
static char
dominant(const uint8_t *p)
{
	const unsigned b = p[0], g = p[1], r = p[2];
	if (r > 200 && g > 200 && b > 200) return 'w';
	if (r < 40 && g < 40 && b < 40) return 'k';
	if (r > g + 60 && r > b + 60) return 'r';
	if (g > r + 60 && g > b + 60) return 'g';
	if (b > r + 60 && b > g + 60) return 'b';
	return '?';
}

static const char *
cb_error(id<MTLCommandBuffer> cb)
{
	return cb.error != nil ? cb.error.localizedDescription.UTF8String : "no error";
}

/*
 * D8's register check: FN(CTX) called with x19..x28 holding known values; the answer is a bit for each of them that came
 * back changed (bit 0 x19 .. bit 9 x28) and bit 10 when sp did not. The calling convention keeps x19..x28 for the
 * caller; a call that broke it would leave CoreAnimation's create_surface_from_iosurface with a stray context in x19 --
 * the surface tracked on the wrong object, then not found by push_surface, which is the assertion backboardd died on.
 */
extern unsigned long akt_preserved(void (*fn)(void *), void *ctx) __asm__("_akt_preserved");
#if __has_feature(ptrauth_calls)
#define AKT_CALL "	blraaz	x9\n"       /* (a C function pointer: signed with key IA, discriminator 0) */
#else
#define AKT_CALL "	blr	x9\n"
#endif
#define AKT_SET(r) "	mov	x" #r ", #0x" #r "\n	movk	x" #r ", #0xa5a5, lsl #48\n"
#define AKT_CMP(r, bit) "	mov	x11, #0x" #r "\n	movk	x11, #0xa5a5, lsl #48\n	cmp	x" #r ", x11\n	cset	x12, ne\n" \
	"	orr	x10, x10, x12, lsl #" #bit "\n"
__asm__(
	"	.text\n"
	"	.p2align 2\n"
	"	.private_extern _akt_preserved\n"
	"	.globl _akt_preserved\n"
	"_akt_preserved:\n"
	"	stp	x29, x30, [sp, #-96]!\n"
	"	mov	x29, sp\n"
	"	stp	x19, x20, [sp, #16]\n"
	"	stp	x21, x22, [sp, #32]\n"
	"	stp	x23, x24, [sp, #48]\n"
	"	stp	x25, x26, [sp, #64]\n"
	"	stp	x27, x28, [sp, #80]\n"
	"	mov	x9, x0\n"
	"	mov	x0, x1\n"
	AKT_SET(19) AKT_SET(20) AKT_SET(21) AKT_SET(22) AKT_SET(23) AKT_SET(24) AKT_SET(25) AKT_SET(26) AKT_SET(27) AKT_SET(28)
	AKT_CALL
	"	mov	x10, #0\n"
	AKT_CMP(19, 0) AKT_CMP(20, 1) AKT_CMP(21, 2) AKT_CMP(22, 3) AKT_CMP(23, 4) AKT_CMP(24, 5) AKT_CMP(25, 6) AKT_CMP(26, 7)
	AKT_CMP(27, 8) AKT_CMP(28, 9)
	"	mov	x11, sp\n"
	"	cmp	x11, x29\n"
	"	cset	x12, ne\n"
	"	orr	x10, x10, x12, lsl #10\n"
	"	mov	x0, x10\n"
	"	mov	sp, x29\n"
	"	ldp	x19, x20, [sp, #16]\n"
	"	ldp	x21, x22, [sp, #32]\n"
	"	ldp	x23, x24, [sp, #48]\n"
	"	ldp	x25, x26, [sp, #64]\n"
	"	ldp	x27, x28, [sp, #80]\n"
	"	ldp	x29, x30, [sp], #96\n"
	"	ret\n");

/* D8: CoreAnimation's calls for an asynchronous layer's surface, in its order (create_surface_from_iosurface, then
 * add_memoryless_textures and add_path_buffer_texture): the results retained into the context */
struct d8_make {
	__unsafe_unretained id<MTLDevice> dev;
	IOSurfaceRef surface;
	unsigned width, height;
	void *texture, *memoryless, *path;      /* (retained: CFBridgingRelease when done) */
};

static void
d8_make(void *p)
{
	struct d8_make *c = p;

	@autoreleasepool {
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:c->width
		    height:c->height mipmapped:NO];
		d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;     /* (CoreAnimation's 5) */
		id<MTLTexture> t = [c->dev newTextureWithDescriptor:d iosurface:c->surface plane:0];
		t.label = @"akios_metal_test.D8.async";
		id<MTLTexture> m = nil, r = nil;
		if (t != nil) {
			MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:t.width
			    height:t.height mipmapped:NO];
			md.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
			md.storageMode = MTLStorageModeMemoryless;
			m = [c->dev newTextureWithDescriptor:md];
			m.label = @"akios_metal_test.D8.memoryless";
			MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:t.width
			    height:t.height mipmapped:NO];
			rd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
			rd.storageMode = MTLStorageModeMemoryless;
			r = [c->dev newTextureWithDescriptor:rd];
			r.label = @"akios_metal_test.D8.path";
		}
		c->texture = t != nil ? (__bridge_retained void *)t : NULL;
		c->memoryless = m != nil ? (__bridge_retained void *)m : NULL;
		c->path = r != nil ? (__bridge_retained void *)r : NULL;
	}
}

/* D8's pass over what d8_make made: colour 0 the surface (cleared, the triangle drawn, stored), 1 and 2 the memoryless
 * ones (cleared, not stored), as CoreAnimation's passes have them */
struct d8_draw {
	__unsafe_unretained id<MTLCommandQueue> q;
	__unsafe_unretained id<MTLRenderPipelineState> pipeline;
	__unsafe_unretained id<MTLTexture> texture, memoryless, path;
	long status;
};

static void
d8_draw(void *p)
{
	struct d8_draw *c = p;

	@autoreleasepool {
		MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
		d.colorAttachments[0].texture = c->texture;
		d.colorAttachments[0].loadAction = MTLLoadActionClear;
		d.colorAttachments[0].storeAction = MTLStoreActionStore;
		d.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1);
		d.colorAttachments[1].texture = c->memoryless;
		d.colorAttachments[1].loadAction = MTLLoadActionClear;
		d.colorAttachments[1].storeAction = MTLStoreActionDontCare;
		d.colorAttachments[2].texture = c->path;
		d.colorAttachments[2].loadAction = MTLLoadActionClear;
		d.colorAttachments[2].storeAction = MTLStoreActionDontCare;
		id<MTLCommandBuffer> cb = [c->q commandBuffer];
		id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:d];
		[re setRenderPipelineState:c->pipeline];
		[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[re endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		c->status = re != nil ? (long)cb.status : -1;
	}
}

/* an 'RGhA' (RGBA16Float) IOSurface of W x H, as CoreAnimation's asynchronous layers have */
static IOSurfaceRef
d8_surface(unsigned w, unsigned h)
{
	NSDictionary *props = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @8,
	    (id)kIOSurfacePixelFormat: @((uint32_t)'RGhA') };
	return IOSurfaceCreate((__bridge CFDictionaryRef)props);
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

		/* ---- D: rendering ---- */
		const unsigned RW = 64, RH = 64;
		NSData *rlib = render_library();
		id<MTLLibrary> rl = [dev newLibraryWithData:dispatch_data_create(rlib.bytes, rlib.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT)
		    error:&error];
		id<MTLFunction> vsf = [rl newFunctionWithName:@"tri_color_vs"], fsf = [rl newFunctionWithName:@"tri_color_fs"];
		MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
		rpd.vertexFunction = vsf;
		rpd.fragmentFunction = fsf;
		rpd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		id<MTLRenderPipelineState> tri = vsf && fsf ? [dev newRenderPipelineStateWithDescriptor:rpd error:&error] : nil;
		printf("D0: render library %s, functions %s %s, pipeline %s%s%s\n", rl ? "made" : "nil", vsf ? "found" : "nil", fsf ? "found" : "nil",
		    tri ? object_getClassName(tri) : "nil", error ? ": " : "", error ? error.localizedDescription.UTF8String : "");
		if (tri == nil) {
			return 19;
		}
		NSDictionary *sprops = @{ (id)kIOSurfaceWidth: @(RW), (id)kIOSurfaceHeight: @(RH), (id)kIOSurfaceBytesPerElement: @4,
		    (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
		IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)sprops);
		MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:RW height:RH
		    mipmapped:NO];
		sd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		id<MTLTexture> st = surface ? [dev newTextureWithDescriptor:sd iosurface:surface plane:0] : nil;
		printf("D1: IOSurface %u (rows %zu), texture %s\n", surface ? IOSurfaceGetID(surface) : 0, surface ? IOSurfaceGetBytesPerRow(surface) : 0,
		    st ? object_getClassName(st) : "nil");
		if (st == nil) {
			return 20;
		}
		/* one pass: LOAD action, clear colour, the vertices FIRST .. FIRST + 2 (or none) */
		id<MTLCommandBuffer> (^pass)(id<MTLTexture>, MTLLoadAction, MTLClearColor, int) =
		    ^id<MTLCommandBuffer>(id<MTLTexture> target, MTLLoadAction load, MTLClearColor clear, int first) {
			MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
			d.colorAttachments[0].texture = target;
			d.colorAttachments[0].loadAction = load;
			d.colorAttachments[0].storeAction = MTLStoreActionStore;
			d.colorAttachments[0].clearColor = clear;
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:d];
			if (first >= 0) {
				[re setRenderPipelineState:tri];
				[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:(NSUInteger)first vertexCount:3];
			}
			[re endEncoding];
			[cb commit];
			[cb waitUntilCompleted];
			return cb;
		};
		char (^at)(unsigned, unsigned) = ^char(unsigned x, unsigned y) {
			IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
			const uint8_t *p = (const uint8_t *)IOSurfaceGetBaseAddress(surface) + IOSurfaceGetBytesPerRow(surface) * y + 4 * x;
			char c = dominant(p);
			IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
			return c;
		};
		id<MTLCommandBuffer> d1 = pass(st, MTLLoadActionClear, MTLClearColorMake(0, 0, 0, 1), 0);
		/* (pixel (x, y) is NDC (2 (x + 0.5) / W - 1, 1 - 2 (y + 0.5) / H); the triangle is x + y <= 0 there, so every probe is
		 * kept well off that diagonal: top-left (2, 12) -> (-0.92, 0.61), bottom-left (2, 61) -> (-0.92, -0.92), bottom-right
		 * (54, 61) -> (0.70, -0.92), top-right (61, 2) -> (0.92, 0.92), outside) */
		printf("D1: tri_color_vs's first triangle: (-1, -1) red, (1, -1) green, (-1, 1) blue; the second (1, -1) red, (1, 1) green, "
		    "(-1, 1) blue; z 0\n");
		char tl = at(2, 12), bl = at(2, RH - 3), br = at(RW - 10, RH - 3), tr = at(RW - 3, 2);
		printf("D1: triangle: status %ld (%s); top-left %c (b), bottom-left %c (r), bottom-right %c (g), top-right %c (k)\n",
		    (long)d1.status, cb_error(d1), tl, bl, br, tr);
		if (d1.status != MTLCommandBufferStatusCompleted || tl != 'b' || bl != 'r' || br != 'g' || tr != 'k') {
			return 21;
		}
		id<MTLCommandBuffer> d2 = pass(st, MTLLoadActionLoad, MTLClearColorMake(1, 1, 1, 1), 3);
		char tl2 = at(2, 12), tr2 = at(RW - 3, 2);
		id<MTLCommandBuffer> d2c = pass(st, MTLLoadActionClear, MTLClearColorMake(1, 1, 1, 1), -1);
		char w1 = at(2, 2), w2 = at(RW - 3, RH - 3);
		printf("D2: load: status %ld (%s), top-left %c (b: kept), top-right %c (g: drawn); clear only: status %ld, %c %c (w w)\n",
		    (long)d2.status, cb_error(d2), tl2, tr2, (long)d2c.status, w1, w2);
		if (d2.status != MTLCommandBufferStatusCompleted || tl2 != 'b' || tr2 != 'g' || d2c.status != MTLCommandBufferStatusCompleted ||
		    w1 != 'w' || w2 != 'w') {
			return 22;
		}

		/* D3: depth */
		{
			MTLRenderPipelineDescriptor *zd = [rpd copy];
			zd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
			id<MTLRenderPipelineState> zp = [dev newRenderPipelineStateWithDescriptor:zd error:&error];
			MTLTextureDescriptor *ztd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:RW
			    height:RH mipmapped:NO];
			ztd.usage = MTLTextureUsageRenderTarget;
			ztd.storageMode = MTLStorageModePrivate;
			id<MTLTexture> zt = [dev newTextureWithDescriptor:ztd];
			MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
			dsd.depthCompareFunction = MTLCompareFunctionLess;
			dsd.depthWriteEnabled = YES;
			id<MTLDepthStencilState> less = [dev newDepthStencilStateWithDescriptor:dsd];
			if (zp == nil || zt == nil || less == nil) {
				printf("D3: depth pipeline %s, texture %s, state %s (%s)\n", zp ? "made" : "nil", zt ? "made" : "nil", less ? "made" : "nil",
				    error ? error.localizedDescription.UTF8String : "");
				return 23;
			}
			char got[2];
			long status[2];
			for (int k = 0; k < 2; k++) {
				MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
				d.colorAttachments[0].texture = st;
				d.colorAttachments[0].loadAction = MTLLoadActionClear;
				d.colorAttachments[0].storeAction = MTLStoreActionStore;
				d.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
				d.depthAttachment.texture = zt;
				d.depthAttachment.loadAction = MTLLoadActionClear;
				d.depthAttachment.storeAction = MTLStoreActionDontCare;
				d.depthAttachment.clearDepth = k == 0 ? 0.0 : 1.0;
				id<MTLCommandBuffer> cb = [q commandBuffer];
				id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:d];
				[re setRenderPipelineState:zp];
				[re setDepthStencilState:less];
				[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
				[re endEncoding];
				[cb commit];
				[cb waitUntilCompleted];
				status[k] = (long)cb.status;
				got[k] = at(2, 12);
			}
			printf("D3: depth Less at z 0: cleared to 0 -> %c (k), cleared to 1 -> %c (b); status %ld %ld\n", got[0], got[1], status[0], status[1]);
			if (got[0] != 'k' || got[1] != 'b' || status[0] != MTLCommandBufferStatusCompleted || status[1] != MTLCommandBufferStatusCompleted) {
				return 23;
			}
		}

		/* D4: 4x MSAA and its resolve */
		{
			MTLRenderPipelineDescriptor *md = [rpd copy];
			md.rasterSampleCount = 4;
			id<MTLRenderPipelineState> mp = [dev newRenderPipelineStateWithDescriptor:md error:&error];
			MTLTextureDescriptor *msd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:RW height:RH
			    mipmapped:NO];
			msd.textureType = MTLTextureType2DMultisample;
			msd.sampleCount = 4;
			msd.usage = MTLTextureUsageRenderTarget;
			msd.storageMode = MTLStorageModePrivate;
			id<MTLTexture> ms = [dev newTextureWithDescriptor:msd];
			MTLTextureDescriptor *rsd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:RW height:RH
			    mipmapped:NO];
			rsd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
			id<MTLTexture> resolved = [dev newTextureWithDescriptor:rsd];
			if (mp == nil || ms == nil || resolved == nil) {
				printf("D4: MSAA pipeline %s, textures %s %s (%s)\n", mp ? "made" : "nil", ms ? "made" : "nil", resolved ? "made" : "nil",
				    error ? error.localizedDescription.UTF8String : "");
				return 24;
			}
			MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
			d.colorAttachments[0].texture = ms;
			d.colorAttachments[0].resolveTexture = resolved;
			d.colorAttachments[0].loadAction = MTLLoadActionClear;
			d.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
			d.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:d];
			[re setRenderPipelineState:mp];
			[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			[re endEncoding];
			[cb commit];
			[cb waitUntilCompleted];
			uint8_t px[4 * RW * RH];
			[resolved getBytes:px bytesPerRow:4 * RW fromRegion:MTLRegionMake2D(0, 0, RW, RH) mipmapLevel:0];
			/* (on the diagonal from top-left to bottom-right a pixel half covered: neither the clear nor a corner's colour alone) */
			const uint8_t *edge = px + 4 * (RW * 31 + 32);
			char rtl = dominant(px + 4 * (RW * 12 + 2)), rtr = dominant(px + 4 * (RW * 2 + RW - 3));
			printf("D4: MSAA resolve: status %ld (%s); top-left %c (b), top-right %c (k), on the edge BGRA %u %u %u %u\n", (long)cb.status,
			    cb_error(cb), rtl, rtr, edge[0], edge[1], edge[2], edge[3]);
			if (cb.status != MTLCommandBufferStatusCompleted || rtl != 'b' || rtr != 'k') {
				return 24;
			}
		}

		/* D5: a heap's texture written by a kernel, its buffer filled by a blit */
		{
			MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
			hd.size = 1 << 20;
			hd.storageMode = MTLStorageModeShared;
			id<MTLHeap> heap = [dev newHeapWithDescriptor:hd];
			MTLTextureDescriptor *htd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:16 height:16
			    mipmapped:NO];
			htd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
			htd.storageMode = MTLStorageModeShared;
			id<MTLTexture> ht = [heap newTextureWithDescriptor:htd];
			id<MTLBuffer> hb = [heap newBufferWithLength:4096 options:MTLResourceStorageModeShared];
			id<MTLComputePipelineState> fp = [dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"tex_fill"] error:&error];
			if (heap == nil || ht == nil || hb == nil || fp == nil) {
				printf("D5: heap %s, texture %s, buffer %s, pipeline %s\n", heap ? object_getClassName(heap) : "nil", ht ? "made" : "nil",
				    hb ? "made" : "nil", fp ? "made" : "nil");
				return 25;
			}
			uint32_t c5 = 0x55;
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
			[ce setComputePipelineState:fp];
			[ce setTexture:ht atIndex:0];
			[ce setBytes:&c5 length:4 atIndex:0];
			[ce dispatchThreads:MTLSizeMake(16, 16, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
			[ce endEncoding];
			id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
			[be fillBuffer:hb range:NSMakeRange(0, 4096) value:0x5e];
			[be endEncoding];
			[cb commit];
			[cb waitUntilCompleted];
			uint32_t back[16 * 16 * 4];
			[ht getBytes:back bytesPerRow:16 * 16 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
			unsigned right = 0, filled = 0;
			for (uint32_t i = 0; i < 256; i++) right += back[4 * i] == i * 0x9E3779B1u + 0x55u && back[4 * i + 3] == 0xdead;
			for (int k = 0; k < 4096; k++) filled += ((uint8_t *)hb.contents)[k] == 0x5e;
			printf("D5: heap: status %ld (%s), texture %u of 256 texels right, buffer %u of 4096 bytes filled, used %lu of %lu\n",
			    (long)cb.status, cb_error(cb), right, filled, (unsigned long)heap.usedSize, (unsigned long)heap.size);
			if (cb.status != MTLCommandBufferStatusCompleted || right != 256 || filled != 4096) {
				return 25;
			}
		}

		/* D6: a swizzled view (red <-> blue) of an RGBA8 texture, sampled */
		{
			MTLTextureDescriptor *u8 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16
			    mipmapped:NO];
			u8.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
			id<MTLTexture> base = [dev newTextureWithDescriptor:u8];
			uint8_t px[16 * 16 * 4];
			for (int i = 0; i < 256; i++) px[4 * i] = 200, px[4 * i + 1] = 100, px[4 * i + 2] = 50, px[4 * i + 3] = 255;
			[base replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 withBytes:px bytesPerRow:64];
			id<MTLTexture> view = [base newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D
			    levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)
			    swizzle:MTLTextureSwizzleChannelsMake(MTLTextureSwizzleBlue, MTLTextureSwizzleGreen, MTLTextureSwizzleRed, MTLTextureSwizzleAlpha)];
			id<MTLComputePipelineState> sp = [dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"tex_sample_gid"] error:&error];
			id<MTLSamplerState> nearest = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
			id<MTLBuffer> out = [dev newBufferWithLength:256 * 16 options:MTLResourceStorageModeShared];
			if (view == nil || sp == nil) {
				printf("D6: view %s, pipeline %s\n", view ? object_getClassName(view) : "nil", sp ? "made" : "nil");
				return 26;
			}
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
			[ce setComputePipelineState:sp];
			[ce setTexture:view atIndex:0];
			[ce setSamplerState:nearest atIndex:0];
			[ce setBuffer:out offset:0 atIndex:0];
			[ce dispatchThreads:MTLSizeMake(16, 16, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
			[ce endEncoding];
			[cb commit];
			[cb waitUntilCompleted];
			const float *f = out.contents;
			printf("D6: swizzled view: status %ld (%s), texel 0 reads %.3f %.3f %.3f %.3f (0.196 0.392 0.784 1 expected)\n", (long)cb.status,
			    cb_error(cb), f[0], f[1], f[2], f[3]);
			if (cb.status != MTLCommandBufferStatusCompleted || f[0] > 0.21f || f[0] < 0.18f || f[2] < 0.77f || f[2] > 0.80f) {
				return 26;
			}
		}

		/* D7: one of CoreAnimation's pipelines */
		{
			id<MTLLibrary> ca = [dev newLibraryWithURL:[NSURL fileURLWithPath:@"/akita/share/ca-share/QuartzCore-default.metallib"]
			    error:&error];
			MTLRenderPipelineDescriptor *cd = [MTLRenderPipelineDescriptor new];
			cd.label = @"akios_metal_test.inplace_copy";
			cd.vertexFunction = [ca newFunctionWithName:@"std_vert1_lph"];
			cd.fragmentFunction = [ca newFunctionWithName:@"inplace_copy_lph"];
			cd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
			NSDate *t0 = [NSDate date];
			id<MTLRenderPipelineState> cp = cd.vertexFunction && cd.fragmentFunction ? [dev newRenderPipelineStateWithDescriptor:cd
			    error:&error] : nil;
			printf("D7: QuartzCore's library %s, std_vert1_lph + inplace_copy_lph: pipeline %s in %.0f ms%s%s\n", ca ? "opened" : "nil",
			    cp ? object_getClassName(cp) : "nil", -[t0 timeIntervalSinceNow] * 1000, error && !cp ? ": " : "",
			    error && !cp ? error.localizedDescription.UTF8String : "");
			if (cp == nil) {
				return 27;
			}
		}

		/* D8: an asynchronous layer's surface, made, drawn and sampled the way CoreAnimation does */
		{
			const unsigned AW = 1080, AH = 2340;
			MTLRenderPipelineDescriptor *ad = [rpd copy];
			ad.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
			ad.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
			ad.colorAttachments[1].writeMask = MTLColorWriteMaskNone;
			ad.colorAttachments[2].pixelFormat = MTLPixelFormatR32Float;
			ad.colorAttachments[2].writeMask = MTLColorWriteMaskNone;
			id<MTLRenderPipelineState> ap = [dev newRenderPipelineStateWithDescriptor:ad error:&error];
			IOSurfaceRef as = d8_surface(AW, AH);
			printf("D8: pipeline (RGBA16Float + RGBA16Float + R32Float) %s%s%s; IOSurface %u 'RGhA' %zux%zu, rows of %zu bytes (%s)\n",
			    ap ? "made" : "nil", ap ? "" : ": ", ap ? "" : (error ? error.localizedDescription.UTF8String : "?"),
			    as ? IOSurfaceGetID(as) : 0, as ? IOSurfaceGetWidth(as) : 0, as ? IOSurfaceGetHeight(as) : 0,
			    as ? IOSurfaceGetBytesPerRow(as) : 0, as && IOSurfaceGetBytesPerRow(as) % 64 == 0 ? "64-byte multiple" : "NOT 64-byte");
			if (ap == nil || as == NULL) {
				return 28;
			}
			struct d8_make mk = { .dev = dev, .surface = as, .width = AW, .height = AH };
			const unsigned long kept = akt_preserved(d8_make, &mk);
			id<MTLTexture> at8 = (__bridge_transfer id)mk.texture, ml = (__bridge_transfer id)mk.memoryless,
			    pt = (__bridge_transfer id)mk.path;
			printf("D8: texture over the surface %s (MTLPixelFormat %lu, %lux%lu, usage %#lx), memoryless RGBA16Float %s, memoryless "
			    "R32Float %s; x19..x28 and sp across the calls: %s (mask %#lx)\n", at8 ? "made" : "nil", (unsigned long)at8.pixelFormat,
			    (unsigned long)at8.width, (unsigned long)at8.height, (unsigned long)at8.usage, ml ? "made" : "nil", pt ? "made" : "nil",
			    kept == 0 ? "kept" : "CHANGED", kept);
			if (at8 == nil || ml == nil || pt == nil || kept != 0) {
				return 28;
			}
			struct d8_draw dr = { .q = q, .pipeline = ap, .texture = at8, .memoryless = ml, .path = pt };
			const unsigned long keptDraw = akt_preserved(d8_draw, &dr);
			/* the surface on the CPU: near the top-left corner the triangle (blue the most), the top-right corner the clear
			 * colour (0.25 0.5 0.75 1) -- the first triangle (-1, -1) (1, -1) (-1, 1) covers the lower-left half, the
			 * bottom-right corner (its green vertex) with it */
			float tlc[4], brc[4];
			IOSurfaceLock(as, kIOSurfaceLockReadOnly, NULL);
			const uint8_t *base = IOSurfaceGetBaseAddress(as);
			const size_t arow = IOSurfaceGetBytesPerRow(as);
			const __fp16 *p0 = (const __fp16 *)(base + arow * (AH / 10) + 8 * (AW / 32));
			const __fp16 *p1 = (const __fp16 *)(base + arow * 2 + 8 * (AW - 3));
			for (int k = 0; k < 4; k++) {
				tlc[k] = (float)p0[k];
				brc[k] = (float)p1[k];
			}
			IOSurfaceUnlock(as, kIOSurfaceLockReadOnly, NULL);
			const BOOL cpuOk = tlc[2] > 0.7f && tlc[0] < 0.3f && tlc[1] < 0.3f && brc[0] > 0.2f && brc[0] < 0.3f && brc[1] > 0.45f &&
			    brc[1] < 0.55f && brc[2] > 0.7f && brc[2] < 0.8f && brc[3] > 0.95f;
			printf("D8: pass: status %ld; x19..x28 and sp across it: %s (mask %#lx); the surface read: near top-left %.3f %.3f %.3f %.3f "
			    "(blue the most), top-right %.3f %.3f %.3f %.3f (0.25 0.5 0.75 1) -- %s\n", dr.status, keptDraw == 0 ? "kept" : "CHANGED",
			    keptDraw, tlc[0], tlc[1], tlc[2], tlc[3], brc[0], brc[1], brc[2], brc[3], cpuOk ? "right" : "WRONG");
			if (dr.status != MTLCommandBufferStatusCompleted || keptDraw != 0 || !cpuOk) {
				return 28;
			}
			/* sampled: tex_sample_gid over a 16 x 16 grid -- texel 32 (column 0, row 2: NDC -0.94, 0.69, inside the
			 * triangle, blue the most; texel 0 sits on its edge) and texel 15 near the top-right (the clear colour) */
			id<MTLComputePipelineState> sp8 = [dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"tex_sample_gid"]
			    error:&error];
			id<MTLSamplerState> nearest8 = [dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
			id<MTLBuffer> out8 = [dev newBufferWithLength:256 * 16 options:MTLResourceStorageModeShared];
			if (sp8 == nil || out8 == nil) {
				printf("D8: tex_sample_gid %s, buffer %s\n", sp8 ? "made" : "nil", out8 ? "made" : "nil");
				return 28;
			}
			id<MTLCommandBuffer> scb = [q commandBuffer];
			id<MTLComputeCommandEncoder> sce = [scb computeCommandEncoder];
			[sce setComputePipelineState:sp8];
			[sce setTexture:at8 atIndex:0];
			[sce setSamplerState:nearest8 atIndex:0];
			[sce setBuffer:out8 offset:0 atIndex:0];
			[sce dispatchThreads:MTLSizeMake(16, 16, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
			[sce endEncoding];
			[scb commit];
			[scb waitUntilCompleted];
			const float *s8 = out8.contents;
			const float *c15 = s8 + 4 * 15;
			const float *c32 = s8 + 4 * 32;
			const BOOL sampledOk = c32[2] > 0.7f && c32[0] < 0.3f && c15[0] > 0.2f && c15[0] < 0.3f && c15[1] > 0.45f && c15[1] < 0.55f &&
			    c15[2] > 0.7f && c15[2] < 0.8f;
			printf("D8: sampled: status %ld (%s); texel 32 %.3f %.3f %.3f %.3f (blue the most), texel 15 %.3f %.3f %.3f %.3f "
			    "(0.25 0.5 0.75 1) -- %s\n", (long)scb.status, cb_error(scb), c32[0], c32[1], c32[2], c32[3], c15[0], c15[1], c15[2], c15[3],
			    sampledOk ? "right" : "WRONG");
			if (scb.status != MTLCommandBufferStatusCompleted || !sampledOk) {
				return 28;
			}
			at8 = ml = pt = nil;
			CFRelease(as);

			/* rounds: new surfaces made, drawn and let go (the unlock's transition makes and drops them so), beside heap blocks
			 * of CoreAnimation's Surface size that nothing of Metal's may touch */
			enum { BLOCKS = 2048, BLOCK = 0x140 };
			uint64_t **blocks = calloc(BLOCKS, sizeof(*blocks));
			for (unsigned i = 0; i < BLOCKS; i++) {
				blocks[i] = calloc(1, BLOCK);
				for (unsigned k = 0; k < BLOCK / 8; k++) blocks[i][k] = 0xc0ffee0000000000ull | (uint64_t)i << 16 | k;
			}
			unsigned roundsOk = 0, regsBad = 0;
			for (int round = 0; round < 8; round++) {
				IOSurfaceRef rs = d8_surface(AW, AH);
				struct d8_make rm = { .dev = dev, .surface = rs, .width = AW, .height = AH };
				regsBad += akt_preserved(d8_make, &rm) != 0;
				id<MTLTexture> rt = (__bridge_transfer id)rm.texture, rml = (__bridge_transfer id)rm.memoryless,
				    rpt = (__bridge_transfer id)rm.path;
				if (rt != nil && rml != nil && rpt != nil) {
					struct d8_draw rd = { .q = q, .pipeline = ap, .texture = rt, .memoryless = rml, .path = rpt };
					regsBad += akt_preserved(d8_draw, &rd) != 0;
					roundsOk += rd.status == MTLCommandBufferStatusCompleted;
				}
				rt = rml = rpt = nil;
				if (rs != NULL) CFRelease(rs);
			}
			/* (a last command buffer, waited for: whatever the rounds left to complete has) */
			id<MTLCommandBuffer> fence = [q commandBuffer];
			[fence commit];
			[fence waitUntilCompleted];
			unsigned touched = 0, firstBad = BLOCKS;
			for (unsigned i = 0; i < BLOCKS; i++) {
				for (unsigned k = 0; k < BLOCK / 8; k++) {
					if (blocks[i][k] != (0xc0ffee0000000000ull | (uint64_t)i << 16 | k)) {
						touched++;
						if (firstBad == BLOCKS) firstBad = i;
						break;
					}
				}
				free(blocks[i]);
			}
			free(blocks);
			printf("D8: 8 rounds of new surfaces: %u drawn, register checks failed %u; %u of %u heap blocks of 0x%x bytes touched\n",
			    roundsOk, regsBad, touched, (unsigned)BLOCKS, (unsigned)BLOCK);
			if (touched != 0) {
				printf("D8: something wrote into memory it does not own: heap block %u first\n", firstBad);
			}
			if (roundsOk != 8 || regsBad != 0 || touched != 0) {
				return 28;
			}
		}
		CFRelease(surface);
		printf("all steps passed\n");
	}
	return 0;
}
