/*
 * akios_metal_test: the AkiosMetal bundle (IOGPU-based) driven by itself, beside the window server's plug-in:
 * its device made from the accelerator, a queue, and command buffers through IOGPU's submission and completion.
 *   A1. 1000 empty command buffers: completion handlers in commit order, all Completed
 *   A2. waitUntilCompleted on the last one
 *   A3. a command buffer that signals a shared event (kernel command 3): the value set
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <stdatomic.h>
#include <stdio.h>

int
main(int argc, char **argv)
{
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
		printf("all steps passed\n");
	}
	return 0;
}
