/*
 * iogpu_test: does the kernel's IOGPU answer as iOS's IOGPU.framework expects?
 *
 *   1. the accelerator service (IOAcceleratorES) and its Metal properties;
 *   2. IOServiceOpen type 1 and the first selectors by hand (0 config, 1 name, 2 event machine, 4 device info);
 *   3. IOGPUDeviceCreate from IOGPU.framework itself;
 *   4. -[IOGPUMetalDevice initWithAcceleratorPort:] with a subclass made here that adds nothing.
 *
 * Each step prints what it got; the first that fails ends the run (exit status = its number).
 */
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdio.h>

static void
dump(const char *what, const void *bytes, size_t size)
{
	const uint8_t *b = bytes;

	printf("  %s (%zu bytes):", what, size);
	for (size_t i = 0; i < size; i++) {
		if (i % 32 == 0) {
			printf("\n    %03zx:", i);
		}
		printf(" %02x", b[i]);
	}
	printf("\n");
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAcceleratorES"));
		io_connect_t connect = 0;
		kern_return_t kr;
		io_name_t name = "", cls = "";

		/* 1 */
		if (service == 0) {
			printf("1: no IOAcceleratorES\n");
			return 1;
		}
		IORegistryEntryGetName(service, name);
		IOObjectGetClass(service, cls);
		CFTypeRef plugin = IORegistryEntryCreateCFProperty(service, CFSTR("MetalPluginName"), NULL, 0);
		printf("1: accelerator \"%s\" (class %s), MetalPluginName %s\n", name, cls,
		    plugin ? [(__bridge NSString *)plugin UTF8String] : "(none)");
		if (plugin) {
			CFRelease(plugin);
		}

		/* 2 */
		kr = IOServiceOpen(service, mach_task_self(), 1, &connect);
		printf("2: IOServiceOpen type 1: 0x%x\n", kr);
		if (kr != KERN_SUCCESS) {
			return 2;
		}
		{
			static const struct { uint32_t sel; size_t out; const char *what; } q[] = {
				{ 0, 0x40, "config" }, { 1, 0x40, "name" }, { 2, 0x218, "event machine" }, { 4, 0x20, "device info" },
			};
			for (unsigned i = 0; i < sizeof(q) / sizeof(q[0]); i++) {
				uint8_t out[0x218] = { 0 };
				size_t size = q[i].out;

				kr = IOConnectCallStructMethod(connect, q[i].sel, NULL, 0, out, &size);
				printf("2: selector %u (%s): 0x%x\n", q[i].sel, q[i].what, kr);
				if (kr != KERN_SUCCESS) {
					return 2;
				}
				dump(q[i].what, out, q[i].sel == 2 ? 0x30 : size);
				if (q[i].sel == 2) {
					volatile uint32_t *stamps = (volatile uint32_t *)*(uint64_t *)out;
					printf("  stamp page at %p: first word 0x%x\n", stamps, stamps ? stamps[0] : 0);
				}
			}
		}
		/* 2b: object ids, shared memory and the mapping selector */
		{
			uint64_t ids[2] = { 0 }, in[2] = { 0x4000, 1 };
			struct { uint64_t va; uint32_t size, id; } shm = { 0 };
			size_t size = sizeof(ids);

			kr = IOConnectCallStructMethod(connect, 5, NULL, 0, ids, &size);
			printf("2: selector 5 (id group): 0x%x, 0x%llx..0x%llx\n", kr, ids[0], ids[1]);
			if (kr != KERN_SUCCESS || ids[0] == 0) {
				return 2;
			}
			size = sizeof(shm);
			kr = IOConnectCallMethod(connect, 12, in, 2, NULL, 0, NULL, NULL, &shm, &size);
			printf("2: selector 12 (shmem 16 KiB): 0x%x, at 0x%llx, %u bytes, id %u\n", kr, shm.va, shm.size, shm.id);
			if (kr != KERN_SUCCESS || shm.id == 0 || shm.va == 0) {
				return 2;
			}
			((volatile uint32_t *)shm.va)[shm.size / 4 - 1] = 0x12345678;   /* writable to the end */
			uint64_t id = shm.id;
			kr = IOConnectCallScalarMethod(connect, 13, &id, 1, NULL, NULL);
			printf("2: selector 13 (shmem gone): 0x%x\n", kr);
			kr = IOConnectCallScalarMethod(connect, 13, &id, 1, NULL, NULL);
			printf("2: selector 13 again: 0x%x (should be refused)\n", kr);
			kr = IOConnectCallScalarMethod(connect, 55, NULL, 0, NULL, NULL);
			printf("2: selector 55 (perform mapping): 0x%x (0xe00002eb expected)\n", kr);
		}
		IOServiceClose(connect);

		/* 3 */
		void *iogpu = dlopen("/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU", RTLD_NOW);
		void *(*create)(io_service_t) = iogpu ? dlsym(iogpu, "IOGPUDeviceCreate") : NULL;
		if (create == NULL) {
			printf("3: IOGPU.framework: %s\n", dlerror());
			return 3;
		}
		void *device = create(service);
		printf("3: IOGPUDeviceCreate: %p\n", device);
		if (device == NULL) {
			return 3;
		}
		CFRelease(device);

		/* 4 */
		Class base = objc_getClass("IOGPUMetalDevice");
		if (base == Nil) {
			printf("4: no IOGPUMetalDevice class\n");
			return 4;
		}
		Class sub = objc_allocateClassPair(base, "AkiosIOGPUTestDevice", 0);
		/* IOGPUMetalDevice.m:333 asserts that the device conforms to MTLDeviceSPI (a vendor's class declares it) */
		Protocol *spi = objc_getProtocol("MTLDeviceSPI");
		printf("4: protocol MTLDeviceSPI: %p\n", (__bridge void *)spi);
		if (spi == NULL) {
			return 4;
		}
		class_addProtocol(sub, spi);
		objc_registerClassPair(sub);
		id dev = ((id (*)(id, SEL, io_service_t))objc_msgSend)([sub alloc], sel_registerName("initWithAcceleratorPort:"),
		    service);
		printf("4: -[IOGPUMetalDevice initWithAcceleratorPort:]: %s\n", dev ? [[dev description] UTF8String] : "nil");
		if (dev == nil) {
			return 4;
		}
		printf("4: maxBufferLength %llu MiB, currentAllocatedSize %llu\n",
		    ((unsigned long long (*)(id, SEL))objc_msgSend)(dev, sel_registerName("maxBufferLength")) >> 20,
		    ((unsigned long long (*)(id, SEL))objc_msgSend)(dev, sel_registerName("currentAllocatedSize")));
		IOObjectRelease(service);
		printf("all steps passed\n");
	}
	return 0;
}
