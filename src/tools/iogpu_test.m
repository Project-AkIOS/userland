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
#include <IOSurface/IOSurfaceRef.h>
#include <IOKit/IODataQueueClient.h>
#include <mach/mach.h>
#include <unistd.h>

/* (the SDK marks the trap calls unavailable on iOS; IOGPU.framework calls them all the same) */
extern kern_return_t akios_IOConnectTrap4(io_connect_t, uint32_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t)
    __asm__("_IOConnectTrap4");
#define IOConnectTrap4 akios_IOConnectTrap4

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

/* (11-28) step 9's submission: the work buffer's stream once, both notifications waited for; 0 when they came */
static int
submit_stream(io_connect_t c, uint64_t queue, uint32_t shm_seg, uint32_t shm_kcmd, uint64_t gva, IODataQueueMemory *nq,
    mach_port_t port, uint64_t token)
{
	uint8_t args[0x40] = { 0 };
	uint32_t status = 0xffffffff;
	kern_return_t kr;

	*(uint32_t *)(args + 0x00) = shm_seg;
	*(uint32_t *)(args + 0x04) = shm_kcmd;
	*(uint64_t *)(args + 0x10) = 0x5c4ed100 + token;
	*(uint64_t *)(args + 0x18) = 0xc0de0100 + token;
	*(uint64_t *)(args + 0x30) = gva;
	*(uint32_t *)(args + 0x38) = 24;
	kr = IOConnectTrap4(c, 0, (uintptr_t)queue, 0x40, (uintptr_t)args, (uintptr_t)&status);
	if (kr != KERN_SUCCESS) {
		printf("9:   submit: 0x%x\n", kr);
		return -1;
	}
	for (int got = 0; got < 2;) {
		uint8_t entry[0x28];
		uint32_t esize = sizeof(entry);

		if (!IODataQueueDataAvailable(nq)) {
			struct { mach_msg_header_t h; uint8_t pad[64]; } msg;
			kern_return_t mr = mach_msg(&msg.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(msg), port, 2000, MACH_PORT_NULL);
			if (mr != KERN_SUCCESS && !IODataQueueDataAvailable(nq)) {
				printf("9:   no notification within 2 s\n");
				return -1;
			}
			continue;
		}
		IODataQueueDequeue(nq, entry, &esize);
		got++;
	}
	return 0;
}

static uint64_t
purge(io_connect_t c, uint32_t id, uint64_t state, kern_return_t *kr)
{
	uint64_t in[2] = { id, state }, old = 0;
	uint32_t n = 1;

	*kr = IOConnectCallScalarMethod(c, 11, in, 2, &old, &n);
	return old;
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
		/* 5: resources through IOGPU.framework's C API (selector 8, trap 1), then an IOGPUMetalBuffer */
		{
			void *(*rcreate)(void *, void *, uint32_t) = dlsym(iogpu, "IOGPUResourceCreate");
			void *(*rbytes)(void *) = dlsym(iogpu, "IOGPUResourceGetDataBytes");
			uint64_t (*rgpu)(void *) = dlsym(iogpu, "IOGPUResourceGetGPUVirtualAddress");
			void *(*rshared)(void *) = dlsym(iogpu, "IOGPUResourceGetClientShared");
			void (*rrelease)(void *) = dlsym(iogpu, "IOGPUResourceRelease");
			void *gdev = create(service);
			static uint8_t mine[3 * 16384] __attribute__((aligned(16384)));
			IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
				(id)kIOSurfaceWidth: @256, (id)kIOSurfaceHeight: @64, (id)kIOSurfaceBytesPerElement: @4,
				(id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') });
			struct { const char *what; uint32_t kind; uint64_t a38, size; } k[] = {
				{ "system memory, 64 KiB", 0x00, 0, 0x10000 },
				{ "the client's memory, 20 KiB", 0x80, (uint64_t)(uintptr_t)mine + 0x100, 0x5000 },
				{ "an IOSurface 256x64", 0x82, surface ? IOSurfaceGetID(surface) : 0, 0 },
			};

			if (gdev == NULL || rcreate == NULL || rrelease == NULL) {
				printf("5: no device or no IOGPUResource functions\n");
				return 5;
			}
			for (unsigned i = 0; i < 3; i++) {
				uint8_t args[0x58] = { 0 };
				*(uint32_t *)(args + 0x00) = k[i].kind;
				*(uint32_t *)(args + 0x08) = 0x10001;
				*(uint16_t *)(args + 0x0c) = 1;
				args[0x10] = 1; args[0x11] = 1; args[0x13] = 1;
				*(uint32_t *)(args + 0x14) = 0x440;             /* zero-fill (and 0x400, always set) */
				*(uint64_t *)(args + 0x38) = k[i].a38;
				*(uint64_t *)(args + 0x40) = k[i].kind == 0x80 ? k[i].a38 : 0;
				*(uint64_t *)(args + 0x48) = k[i].size;
				void *res = rcreate(gdev, args, sizeof(args));
				printf("5: %s: %p", k[i].what, res);
				if (res == NULL) {
					printf("\n");
					return 5;
				}
				uint8_t *bytes = rbytes(res);
				printf(", GPU 0x%llx, CPU %p, events %p", rgpu(res), bytes, rshared(res));
				if (bytes != NULL && k[i].kind == 0) {
					bytes[0] = 0xa5;
					bytes[k[i].size - 1] = 0x5a;
					printf(", writable");
				}
				printf("\n");
				rrelease(res);
			}
			if (surface) {
				CFRelease(surface);
			}
			CFRelease(gdev);

			SEL init = sel_registerName("initWithDevice:pointer:length:alignment:options:sysMemSize:gpuAddress:args:argsSize:deallocator:");
			Method m = class_getInstanceMethod(objc_getClass("IOGPUMetalBuffer"), init);
			printf("5: IOGPUMetalBuffer init types %s\n", m ? method_getTypeEncoding(m) : "(none)");
			uint8_t bargs[0x58] = { 0 };
			id buffer = ((id (*)(id, SEL, id, void *, NSUInteger, NSUInteger, NSUInteger, NSUInteger, uint64_t, void *,
			    uint64_t, id))objc_msgSend)([objc_getClass("IOGPUMetalBuffer") alloc], init, dev, NULL, 4096, 16, 0, 4096, 0,
			    bargs, sizeof(bargs), nil);
			printf("5: IOGPUMetalBuffer: %s\n", buffer ? [[buffer description] UTF8String] : "nil");
			if (buffer == nil) {
				return 5;
			}
			uint8_t *contents = ((void *(*)(id, SEL))objc_msgSend)(buffer, sel_registerName("contents"));
			printf("5: contents %p, gpuAddress 0x%llx, length %lu\n", contents,
			    ((uint64_t (*)(id, SEL))objc_msgSend)(buffer, sel_registerName("gpuAddress")),
			    (unsigned long)((NSUInteger (*)(id, SEL))objc_msgSend)(buffer, sel_registerName("length")));
			if (contents) {
				memset(contents, 0x11, 4096);
			}
			buffer = nil;
		}
		/* 6: a command queue, its notification queue, and submissions by trap 0 (empty, then a stream the GPU runs) */
		{
			io_connect_t c = 0;
			uint8_t qin[0x408] = { 0 };
			uint64_t qout[2] = { 0 }, sc[2], one;
			struct { uint64_t va; uint32_t size, id; } shm[2];
			struct { uint64_t va; uint32_t id, pad; } nqo = { 0 };
			size_t size;
			mach_port_t port;

			strlcpy((char *)qin, "/akita/bin/iogpu_test", 0x400);
			if (IOServiceOpen(service, mach_task_self(), 1, &c) != KERN_SUCCESS) {
				return 6;
			}
			for (int i = 0; i < 2; i++) {
				sc[0] = 0x4000; sc[1] = (uint64_t)i;
				size = sizeof(shm[i]);
				kr = IOConnectCallMethod(c, 12, sc, 2, NULL, 0, NULL, NULL, &shm[i], &size);
				if (kr != KERN_SUCCESS) {
					printf("6: shmem: 0x%x\n", kr);
					return 6;
				}
			}
			size = sizeof(qout);
			kr = IOConnectCallStructMethod(c, 6, qin, sizeof(qin), qout, &size);
			printf("6: selector 6 (command queue): 0x%x, id %llu, trace id %llu\n", kr, qout[0], qout[1]);
			if (kr != KERN_SUCCESS || qout[0] == 0) {
				return 6;
			}
			sc[0] = 0x100; sc[1] = 0x28;
			size = sizeof(nqo);
			kr = IOConnectCallMethod(c, 14, sc, 2, NULL, 0, NULL, NULL, &nqo, &size);
			printf("6: selector 14 (notification queue): 0x%x, at 0x%llx, id %u\n", kr, nqo.va, nqo.id);
			if (kr != KERN_SUCCESS || nqo.id == 0) {
				return 6;
			}
			port = IODataQueueAllocateNotificationPort();
			kr = IOConnectSetNotificationPort(c, 0, port, nqo.id);
			printf("6: notification port: 0x%x\n", kr);
			sc[0] = qout[0]; sc[1] = nqo.id;
			kr = IOConnectCallScalarMethod(c, 24, sc, 2, NULL, NULL);
			printf("6: selector 24 (queue -> notifications): 0x%x\n", kr);
			if (kr != KERN_SUCCESS) {
				return 6;
			}
			IODataQueueMemory *nq = (IODataQueueMemory *)(uintptr_t)nqo.va;

			/* the GPU's work: a 64 KiB buffer; its first bytes are the stream, the word at 0x1000 its target */
			uint8_t rargs[0x58] = { 0 }, rout[0x58] = { 0 };
			*(uint32_t *)(rargs + 0x08) = 0x10001; *(uint16_t *)(rargs + 0x0c) = 1;
			rargs[0x10] = 1; rargs[0x11] = 1; rargs[0x13] = 1;
			*(uint32_t *)(rargs + 0x14) = 0x440;
			*(uint64_t *)(rargs + 0x48) = 0x10000;
			size = sizeof(rout);
			kr = IOConnectCallStructMethod(c, 8, rargs, sizeof(rargs), rout, &size);
			uint64_t gva = *(uint64_t *)rout;
			volatile uint64_t *cpu = (volatile uint64_t *)(uintptr_t)*(uint64_t *)(rout + 8);
			printf("6: the work's buffer: 0x%x, GPU 0x%llx, CPU %p\n", kr, gva, cpu);
			if (kr != KERN_SUCCESS || cpu == NULL) {
				return 6;
			}
			cpu[0] = 1ULL << 56 | 92ULL << 48 | ((gva + 0x1000) & 0xffffffffffffULL);   /* MOVE48 r92 <- target */
			cpu[1] = 2ULL << 56 | 94ULL << 48 | 0xcafe;                                  /* MOVE32 r94 <- 0xcafe */
			cpu[2] = 21ULL << 56 | 94ULL << 48 | 92ULL << 40 | 0x1ULL << 16;             /* STORE_MULTIPLE r94 -> [r92] */
			((volatile uint32_t *)cpu)[0x1000 / 4] = 0;

			for (int round = 0; round < 2; round++) {
				uint8_t args[0x40] = { 0 };
				uint32_t status = 0xffffffff;
				*(uint32_t *)(args + 0x00) = shm[1].id;
				*(uint32_t *)(args + 0x04) = shm[0].id;
				*(uint64_t *)(args + 0x10) = 0x5c4ed000 + round;
				*(uint64_t *)(args + 0x18) = 0xc0de0000 + round;
				if (round == 1) {
					*(uint64_t *)(args + 0x30) = gva;
					*(uint32_t *)(args + 0x38) = 24;
				}
				kr = IOConnectTrap4(c, 0, (uintptr_t)qout[0], round ? 0x40 : 0x30, (uintptr_t)args, (uintptr_t)&status);
				printf("6: %s submitted: 0x%x (status %u)\n", round ? "the stream" : "an empty buffer", kr, status);
				if (kr != KERN_SUCCESS) {
					return 6;
				}
				for (int got = 0; got < 2;) {
					uint8_t entry[0x28];
					uint32_t esize = sizeof(entry);

					if (!IODataQueueDataAvailable(nq)) {
						struct { mach_msg_header_t h; uint8_t pad[64]; } msg;
						kern_return_t mr = mach_msg(&msg.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(msg), port, 2000,
						    MACH_PORT_NULL);
						if (mr != KERN_SUCCESS && !IODataQueueDataAvailable(nq)) {
							printf("6: no notification within 2 s (0x%x)\n", mr);
							return 6;
						}
						continue;
					}
					IODataQueueDequeue(nq, entry, &esize);
					printf("6:   notification: token 0x%llx, %llu ns, status %u\n", *(uint64_t *)entry,
					    *(uint64_t *)(entry + 0x10) - *(uint64_t *)(entry + 8), *(uint32_t *)(entry + 0x18));
					got++;
				}
			}
			printf("6: the word the GPU stored: 0x%x (0xcafe expected)\n", ((volatile uint32_t *)cpu)[0x1000 / 4]);
			if (((volatile uint32_t *)cpu)[0x1000 / 4] != 0xcafe) {
				return 6;
			}

			/* 7: a shared event (IOSurface.framework), and a command buffer that waits for it and signals it */
			Class ec = objc_getClass("IOSurfaceSharedEvent");
			SEL einit = sel_registerName("initWithOptions:");
			if (ec == Nil || ![ec instancesRespondToSelector:einit]) {
				printf("7: no IOSurfaceSharedEvent -initWithOptions:\n");
				return 7;
			}
			id ev = ((id (*)(id, SEL, uint64_t))objc_msgSend)([ec alloc], einit, 0);
			printf("7: shared event: %s\n", ev ? "made" : "nil");
			if (ev == nil) {
				return 7;
			}
			uint64_t (*getv)(id, SEL) = (uint64_t (*)(id, SEL))objc_msgSend;
			void (*setv)(id, SEL, uint64_t) = (void (*)(id, SEL, uint64_t))objc_msgSend;
			BOOL (*waitv)(id, SEL, uint64_t, uint64_t) = (BOOL (*)(id, SEL, uint64_t, uint64_t))objc_msgSend;
			setv(ev, sel_registerName("setSignaledValue:"), 5);
			printf("7: set 5, reads %llu\n", getv(ev, sel_registerName("signaledValue")));
			printf("7: wait for 5: %d; wait for 6 (100 ms): %d (0 expected)\n",
			    waitv(ev, sel_registerName("waitUntilSignaledValue:timeoutMS:"), 5, 100),
			    waitv(ev, sel_registerName("waitUntilSignaledValue:timeoutMS:"), 6, 100));
			uint32_t eport = (uint32_t)((mach_port_t (*)(id, SEL))objc_msgSend)(ev, sel_registerName("eventPort"));
			printf("7: its port 0x%x\n", eport);

			/* the kernel commands: wait for 10, then (after the GPU) signal 20; the segment list names them */
			uint8_t *kc = (uint8_t *)(uintptr_t)shm[1].va, *sl = (uint8_t *)(uintptr_t)shm[0].va;
			uint32_t kcw[12] = { 4, 0x18, eport, 0xffffffff, 10, 0, 3, 0x18, eport, 0, 20, 0 };
			memcpy(kc, kcw, sizeof(kcw));
			uint32_t slw[6] = { 0, 0, 1, 0xc0000001, 0, 0x30 };
			memcpy(sl, slw, sizeof(slw));
			cpu[0] = 1ULL << 56 | 92ULL << 48 | ((gva + 0x1000) & 0xffffffffffffULL);
			cpu[1] = 2ULL << 56 | 94ULL << 48 | 0xbeef;
			((volatile uint32_t *)cpu)[0x1000 / 4] = 0;
			{
				uint8_t args[0x40] = { 0 };
				uint32_t status = 0;
				int got = 0;
				*(uint32_t *)(args + 0x00) = shm[1].id;
				*(uint32_t *)(args + 0x04) = shm[0].id;
				*(uint64_t *)(args + 0x10) = 0x5c4ed007;
				*(uint64_t *)(args + 0x18) = 0xc0de0007;
				*(uint64_t *)(args + 0x30) = gva;
				*(uint32_t *)(args + 0x38) = 24;
				kr = IOConnectTrap4(c, 0, (uintptr_t)qout[0], 0x40, (uintptr_t)args, (uintptr_t)&status);
				printf("7: waiting buffer submitted: 0x%x\n", kr);
				usleep(300000);
				while (IODataQueueDataAvailable(nq)) {
					uint8_t entry[0x28]; uint32_t esize = sizeof(entry);
					IODataQueueDequeue(nq, entry, &esize);
					printf("7:   before the signal: token 0x%llx\n", *(uint64_t *)entry);
					got++;
				}
				printf("7: after 300 ms the word is 0x%x (0 expected: held back)\n", ((volatile uint32_t *)cpu)[0x1000 / 4]);
				if (((volatile uint32_t *)cpu)[0x1000 / 4] != 0) {
					return 7;
				}
				setv(ev, sel_registerName("setSignaledValue:"), 10);
				while (got < 2) {
					uint8_t entry[0x28]; uint32_t esize = sizeof(entry);
					if (!IODataQueueDataAvailable(nq)) {
						struct { mach_msg_header_t h; uint8_t pad[64]; } msg;
						if (mach_msg(&msg.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(msg), port, 2000, MACH_PORT_NULL) !=
						    KERN_SUCCESS && !IODataQueueDataAvailable(nq)) {
							printf("7: no completion within 2 s of the signal\n");
							return 7;
						}
						continue;
					}
					IODataQueueDequeue(nq, entry, &esize);
					printf("7:   notification: token 0x%llx, status %u\n", *(uint64_t *)entry, *(uint32_t *)(entry + 0x18));
					got++;
				}
				printf("7: the word is 0x%x (0xbeef expected), the event %llu (20 expected)\n",
				    ((volatile uint32_t *)cpu)[0x1000 / 4], getv(ev, sel_registerName("signaledValue")));
				if (((volatile uint32_t *)cpu)[0x1000 / 4] != 0xbeef || getv(ev, sel_registerName("signaledValue")) != 20) {
					return 7;
				}
			}
			/* 8: the Mali's own selectors: a tiler heap (56) and its end (57) */
			{
				uint64_t hin[4] = { 2u << 20, 1, 64, 65535 }, hout[3] = { 0 };
				uint32_t n = 3;
				kr = IOConnectCallScalarMethod(c, 56, hin, 4, hout, &n);
				printf("8: tiler heap: 0x%x, handle %llu, context 0x%llx, first chunk 0x%llx\n", kr, hout[0], hout[1], hout[2]);
				if (kr != KERN_SUCCESS || hout[0] == 0) {
					return 8;
				}
				kr = IOConnectCallScalarMethod(c, 57, hout, 1, NULL, NULL);
				printf("8: tiler heap gone: 0x%x\n", kr);
				if (kr != KERN_SUCCESS) {
					return 8;
				}
			}
			/*
			 * 9 (11-28): purgeable memory for real, queue priority, app roles. The work buffer (kind 0): volatile, it
			 * leaves the GPU once this client is idle; non-volatile, it comes back and the GPU's stream still runs;
			 * emptied, the VM has taken its pages (the processor reads zeros) and the answer says "empty".
			 */
			{
				uint32_t rid = *(uint32_t *)(rout + 0x24);
				volatile uint32_t *word = (volatile uint32_t *)cpu + 0x1000 / 4;
				uint64_t old;
				int bad = 0;

				old = purge(c, rid, 3, &kr);
				printf("9: volatile: 0x%x, old state %llu (2 expected)\n", kr, old);
				bad |= kr != KERN_SUCCESS || old != 2;
				usleep(300 * 1000);
				printf("9: the word while volatile (evicted, not purged): 0x%x (0xbeef expected)\n", *word);
				bad |= *word != 0xbeef;
				old = purge(c, rid, 1, &kr);
				printf("9: keep (asks the state): 0x%x, state %llu (3 expected)\n", kr, old);
				bad |= kr != KERN_SUCCESS || old != 3;
				old = purge(c, rid, 2, &kr);
				printf("9: non-volatile: 0x%x, old state %llu (3 expected)\n", kr, old);
				bad |= kr != KERN_SUCCESS || old != 3;
				cpu[0] = 1ULL << 56 | 92ULL << 48 | ((gva + 0x1000) & 0xffffffffffffULL);   /* (step 7 left 0xbeef's) */
				cpu[1] = 2ULL << 56 | 94ULL << 48 | 0xcafe;
				cpu[2] = 21ULL << 56 | 94ULL << 48 | 92ULL << 40 | 0x1ULL << 16;
				*word = 0;
				bad |= submit_stream(c, qout[0], shm[1].id, shm[0].id, gva, nq, port, 1) != 0;
				printf("9: the GPU's word after coming back: 0x%x (0xcafe expected)\n", *word);
				bad |= *word != 0xcafe;

				old = purge(c, rid, 4, &kr);
				printf("9: empty: 0x%x, old state %llu (2 expected)\n", kr, old);
				bad |= kr != KERN_SUCCESS || old != 2;
				usleep(300 * 1000);
				printf("9: the stream's first word after emptying: 0x%llx (0 expected: the pages went back)\n", cpu[0]);
				bad |= cpu[0] != 0;
				old = purge(c, rid, 2, &kr);
				printf("9: non-volatile: 0x%x, old state %llu (4 expected: emptied)\n", kr, old);
				bad |= kr != KERN_SUCCESS || old != 4;
				cpu[0] = 1ULL << 56 | 92ULL << 48 | ((gva + 0x1000) & 0xffffffffffffULL);
				cpu[1] = 2ULL << 56 | 94ULL << 48 | 0xcafe;
				cpu[2] = 21ULL << 56 | 94ULL << 48 | 92ULL << 40 | 0x1ULL << 16;
				*word = 0;
				bad |= submit_stream(c, qout[0], shm[1].id, shm[0].id, gva, nq, port, 2) != 0;
				printf("9: the GPU's word after refilling: 0x%x (0xcafe expected)\n", *word);
				bad |= *word != 0xcafe;
				(void)purge(c, 99999, 3, &kr);
				printf("9: an unknown resource: 0x%x (0xe00002c2 expected)\n", kr);
				bad |= kr != (kern_return_t)0xe00002c2;

				/* priority (26) and QoS (27), app roles (33/34) */
				uint64_t qid = qout[0], prio = 0;
				uint32_t pb[3] = { 0, 0, 0 }, n = 1, qos;   /* (12 bytes: the dispatch table's size) */
				pb[0] = 0; pb[1] = 2;
				kr = IOConnectCallMethod(c, 26, &qid, 1, pb, sizeof(pb), &prio, &n, NULL, NULL);
				printf("9: priority high, background 2: 0x%x, taken %llu (0)\n", kr, prio);
				bad |= kr != KERN_SUCCESS || prio != 0;
				pb[0] = 5; n = 1;
				kr = IOConnectCallMethod(c, 26, &qid, 1, pb, sizeof(pb), &prio, &n, NULL, NULL);
				printf("9: priority real-time without the entitlement: 0x%x, taken %llu (0)\n", kr, prio);
				bad |= kr != KERN_SUCCESS || prio != 0;
				pb[0] = 3; n = 1;
				kr = IOConnectCallMethod(c, 26, &qid, 1, pb, sizeof(pb), &prio, &n, NULL, NULL);
				printf("9: priority 3: 0x%x (refused expected)\n", kr);
				bad |= kr == KERN_SUCCESS;
				pb[0] = 2; pb[1] = 2; n = 1;
				kr = IOConnectCallMethod(c, 26, &qid, 1, pb, sizeof(pb), &prio, &n, NULL, NULL);
				bad |= kr != KERN_SUCCESS;
				*word = 0;
				bad |= submit_stream(c, qout[0], shm[1].id, shm[0].id, gva, nq, port, 3) != 0;
				printf("9: low priority: 0x%x; the GPU's word 0x%x (0xcafe expected)\n", kr, *word);
				bad |= *word != 0xcafe;
				qos = 2;
				kr = IOConnectCallMethod(c, 27, &qid, 1, &qos, sizeof(qos), NULL, NULL, NULL, NULL);
				printf("9: QoS 2: 0x%x\n", kr);
				bad |= kr != KERN_SUCCESS;
				qos = 5;
				kr = IOConnectCallMethod(c, 27, &qid, 1, &qos, sizeof(qos), NULL, NULL, NULL, NULL);
				printf("9: QoS 5: 0x%x (refused expected)\n", kr);
				bad |= kr == KERN_SUCCESS;
				uint64_t rin[2] = { (uint64_t)getpid(), 7 }, role = 0;
				kr = IOConnectCallScalarMethod(c, 33, rin, 2, NULL, NULL);
				n = 1;
				kern_return_t kr2 = IOConnectCallScalarMethod(c, 34, rin, 1, &role, &n);
				printf("9: app role set 0x%x, read 0x%x: %llu (7 expected)\n", kr, kr2, role);
				bad |= kr != KERN_SUCCESS || kr2 != KERN_SUCCESS || role != 7;
				if (bad) {
					return 9;
				}
			}
			IOServiceClose(c);
		}
		IOObjectRelease(service);
		printf("all steps passed\n");
	}
	return 0;
}
