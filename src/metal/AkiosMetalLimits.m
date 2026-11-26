/*
 * AkiosMetalLimits.m: what the device answers about itself that neither IOGPUMetalDevice nor _MTLDevice does -- the
 * earlier plug-in's answers (HakiosMetalCA.m, HakiosMetalDevice), measured there on the phone. What IOGPUMetalDevice
 * answers itself is left to it: maxBufferLength, registryID, hasUnifiedMemory, currentAllocatedSize,
 * recommendedMaxWorkingSetSize. The rest of the limits (threadgroup memory, argument buffer and read-write texture tiers,
 * supportsFamily: ...) are _MTLDevice's own, from its table for -featureProfile, as they were on the earlier device.
 */
#import "AkiosMetal.h"
#include <sys/sysctl.h>

/* The one struct Metal reads out of a device by raw pointer (MTLDeviceSPI's -targetDeviceInfo: r^{MTLTargetDeviceArch=QI*}):
 * +0x10 is formatted into "<pipelinelib>/pipelines.%s" and must be a C string; +0x08 goes into a cache version */
struct MTLTargetDeviceArch {
	uint64_t target;
	uint32_t version;
	char *name;
};

_Static_assert(sizeof(struct MTLTargetDeviceArch) == 24 && __builtin_offsetof(struct MTLTargetDeviceArch, version) == 8 &&
    __builtin_offsetof(struct MTLTargetDeviceArch, name) == 16, "Metal reads the name at +0x10 and the version at +0x8");

@implementation AkiosMaliDevice (Limits)

/*
 * The profile -[_MTLDevice initLimits] switches on (measured with the earlier plug-in: 0, 1 and 4 to 9 fill the limits
 * table; 2, 3 and 10 to 12 abort inside Apple). 1 claims Apple1, Apple2 and Common1, the least MPS takes (with 0
 * SpringBoard died in MPSDevice::GetMPSDevice). WebKit's processes get 4 (Apple3: WebGL through Metal). Boot-arg
 * metal_profile=N: another one, for a test.
 */
- (NSUInteger)featureProfile
{
	static long profile = -1;

	if (profile < 0) {
		char args[1024] = { 0 };
		size_t size = sizeof(args) - 1;
		const char *at;
		long chosen = strncmp(getprogname(), "com.apple.WebKit", 16) == 0 ? 4 : 1;

		if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && (at = strstr(args, "metal_profile=")) != NULL) {
			long n = strtol(at + strlen("metal_profile="), NULL, 10);

			if (n == 0 || n == 1 || (n >= 4 && n <= 9)) {
				chosen = n;
			}
		}
		profile = chosen;
	}
	return (NSUInteger)profile;
}

/* (a 2D multisample texture is made of 4 samples, 2 served as 4: the core's) */
- (BOOL)supportsTextureSampleCount:(NSUInteger)sampleCount
{
	return sampleCount == 1 || sampleCount == 2 || sampleCount == 4;
}

- (BOOL)supportsSampleCount:(NSUInteger)sampleCount
{
	return [self supportsTextureSampleCount:sampleCount];
}

/* (IOGPU answers this too; vertex amplification is not served: profile 0's own count, 1) */
- (BOOL)supportsVertexAmplificationCount:(NSUInteger)count
{
	return count <= 1;
}

/* no render target is drawn rotated here */
- (BOOL)supportsRenderTargetTextureRotation
{
	return NO;
}

/* a kernel's threadgroup: up to 1024 threads (fewer for a kernel with many registers: its pipeline's
 * maxTotalThreadsPerThreadgroup says so) */
- (MTLSize)maxThreadsPerThreadgroup
{
	return MTLSizeMake(1024, 1024, 1024);
}

/* the Mali samples linear rows only from 64-byte multiples (plan 1.2: CoreAnimation sizes IOSurfaces by it) */
- (NSUInteger)minimumLinearTextureAlignmentForPixelFormat:(MTLPixelFormat)format
{
	(void)format;
	return 64;
}

/* _MTLDevice's own answer is a NULL its caller dereferences: a real struct, named after the GPU (Metal then looks for a
 * pipelines.Mali-G715 library, finds none, and carries on) */
- (const struct MTLTargetDeviceArch *)targetDeviceInfo
{
	static char name[] = "Mali-G715";
	static struct MTLTargetDeviceArch target = { 0, 0, name };

	return &target;
}

/*
 * +[MTLLoader sliceIDForDevice:...] (iOS 27) picks a binary archive's slice by this and asserts when there is none: an
 * architecture of no Apple GPU (CPU type 0x7f000048) matches no slice, and the shaders are compiled from their AIR.
 */
- (id)targetDeviceArchitecture
{
	static id architecture;
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		Class cls = objc_getClass("MTLTargetDeviceArchitecture");

		if (cls != Nil) {
			architecture = [[cls alloc] init];
			@try {
				[architecture setValue:@(0x7f000048u) forKey:@"cpuType"];
				[architecture setValue:@(0) forKey:@"subType"];
				[architecture setValue:@(0) forKey:@"version"];
				[architecture setValue:@(0) forKey:@"driverVersion"];
			} @catch (NSException *e) {
				akios_say("targetDeviceArchitecture: %s\n", e.reason.UTF8String);
			}
		}
	});
	return architecture;
}

@end
