/*
 * AkiosMetalState.m: sampler states and compute pipeline states, as the earlier plug-in made them (HakiosMetalCA.m):
 * Metal's own base classes (no IOGPU layer, as in AGX), the core's sampler words and compiled kernels under them. A
 * pipeline's function is the AIR Metal's library hands out (-[_MTLFunction bitcodeData]), specialised by its function
 * constants, compiled here (AIR -> NIR -> Mesa's panfrost).
 */
#import "AkiosMetal.h"
#include <objc/message.h>

/* the number a sampler is told apart by while it lives: a counter from 1, never an address (UIKit keys caches on it) */
static uint64_t
akios_next_id(void)
{
	static uint64_t next;

	return __atomic_add_fetch(&next, 1, __ATOMIC_RELAXED);
}

@implementation AkiosMaliSamplerState {
	hakios_metal_sampler *_akCore;
	uint64_t _akUniqueIdentifier;   /* (-[_MTLSamplerState uniqueIdentifier] is a nil-stub; gpuResourceID is built on it) */
}

+ (void)load
{
	class_addProtocol(self, @protocol(MTLSamplerState));
}

- (instancetype)initWithAkiosDevice:(AkiosMaliDevice *)device sampler:(hakios_metal_sampler *)sampler
    descriptor:(MTLSamplerDescriptor *)descriptor
{
	self = [super initWithDevice:device samplerDescriptor:descriptor];
	if (self == nil) {
		hakios_metal_sampler_free(sampler);
		return nil;
	}
	_akCore = sampler;
	_akUniqueIdentifier = akios_next_id();
	return self;
}

- (void)dealloc
{
	hakios_metal_sampler_free(_akCore);   /* (a dispatch copied its words; nothing in flight points at it) */
}

- (hakios_metal_sampler *)akCore { return _akCore; }
- (uint64_t)uniqueIdentifier { return _akUniqueIdentifier; }

- (MTLResourceID)gpuResourceID
{
	MTLResourceID rid = { hakios_metal_sampler_resource_id(_akCore) };

	return rid;
}

@end

@implementation AkiosMaliComputePipelineState {
	__weak AkiosMaliDevice *_akDevice;
	hakios_metal_kernel *_akCore;
	NSString *_akLabel;
}

+ (void)load
{
	class_addProtocol(self, @protocol(MTLComputePipelineState));
}

- (instancetype)initWithAkiosDevice:(AkiosMaliDevice *)device kernel:(hakios_metal_kernel *)kernel descriptor:(id)descriptor
{
	self = [super initWithDevice:device pipelineStateDescriptor:descriptor];
	if (self == nil) {
		hakios_metal_kernel_free(kernel);
		return nil;
	}
	_akDevice = device;
	_akCore = kernel;
	_akLabel = [[descriptor label] copy];
	return self;
}

- (void)dealloc
{
	hakios_metal_kernel_free(_akCore);    /* (a dispatch in flight keeps its own reference) */
}

- (hakios_metal_kernel *)akCore { return _akCore; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return hakios_metal_kernel_max_threads(_akCore); }
- (NSUInteger)threadExecutionWidth { return hakios_metal_kernel_execution_width(_akCore); }
- (NSUInteger)staticThreadgroupMemoryLength { return hakios_metal_kernel_threadgroup_memory(_akCore); }
- (id)device { return _akDevice; }
- (NSString *)label { return _akLabel; }
- (BOOL)supportIndirectCommandBuffers { return NO; }

@end

/* ---- function constants (the earlier plug-in's reading of Metal's specialisation, unchanged) ---- */

static unsigned
akios_data_type_bytes(MTLDataType t)
{
	switch (t) {
	case MTLDataTypeBool: case MTLDataTypeChar: case MTLDataTypeUChar: return 1;
	case MTLDataTypeBool2: case MTLDataTypeChar2: case MTLDataTypeUChar2: case MTLDataTypeShort: case MTLDataTypeUShort: case MTLDataTypeHalf: return 2;
	case MTLDataTypeBool3: case MTLDataTypeChar3: case MTLDataTypeUChar3: return 3;
	case MTLDataTypeBool4: case MTLDataTypeChar4: case MTLDataTypeUChar4: case MTLDataTypeShort2: case MTLDataTypeUShort2: case MTLDataTypeHalf2:
	case MTLDataTypeInt: case MTLDataTypeUInt: case MTLDataTypeFloat: return 4;
	case MTLDataTypeShort3: case MTLDataTypeUShort3: case MTLDataTypeHalf3: return 6;
	case MTLDataTypeShort4: case MTLDataTypeUShort4: case MTLDataTypeHalf4: case MTLDataTypeInt2: case MTLDataTypeUInt2: case MTLDataTypeFloat2:
	case MTLDataTypeLong: case MTLDataTypeULong: return 8;
	default: return 0;
	}
}

/* -[_MTLFunctionInternal specializationAirScript]: a FlatBuffers buffer ("AIRC"), read as the earlier plug-in read it
 * off CoreAnimation's own functions (HakiosMetalCA.m: hm_script_constants); every offset checked against the size */
static unsigned
akios_script_constants(const uint8_t *b, size_t size, hakios_metal_constant *out, unsigned max)
{
#define FITS(o, n) ((uint64_t)(o) + (n) <= size)
	uint32_t root, sub, vec, n, count = 0;

	if (size < 8 || memcmp(b + 4, "AIRC", 4) != 0) {
		return 0;
	}
	uint64_t (^field)(uint64_t, unsigned) = ^uint64_t(uint64_t t, unsigned k) {
		int32_t so;
		uint64_t vt;
		uint16_t vlen, off;

		if (!FITS(t, 4)) return 0;
		memcpy(&so, b + t, 4);
		vt = t - (int64_t)so;
		if (!FITS(vt, 4)) return 0;
		memcpy(&vlen, b + vt, 2);
		if (4 + 2 * k + 2 > vlen || !FITS(vt + 4 + 2 * k, 2)) return 0;
		memcpy(&off, b + vt + 4 + 2 * k, 2);
		return off != 0 ? t + off : 0;
	};
	uint64_t (^follow)(uint64_t) = ^uint64_t(uint64_t p) {
		uint32_t o;

		if (p == 0 || !FITS(p, 4)) return 0;
		memcpy(&o, b + p, 4);
		return FITS(p + o, 1) ? p + o : 0;
	};
	memcpy(&root, b, 4);
	sub = (uint32_t)follow(field(root, 2));
	vec = sub != 0 ? (uint32_t)follow(field(sub, 2)) : 0;
	if (vec == 0 || !FITS(vec, 4)) {
		return 0;
	}
	memcpy(&n, b + vec, 4);
	for (uint32_t e = 0; e < n && count < max && FITS(vec + 4 + 4 * e, 4); e++) {
		uint64_t et = follow(vec + 4 + 4 * e), fi, ft, fv;
		uint16_t index = 0;
		unsigned bytes;

		if (et == 0) break;
		fi = field(et, 0);
		ft = field(et, 1);
		fv = follow(field(et, 2));
		if (ft == 0 || fv == 0) continue;
		if (fi != 0 && FITS(fi, 2)) memcpy(&index, b + fi, 2);
		bytes = akios_data_type_bytes((MTLDataType)b[ft]);
		if (bytes == 0 || !FITS(fv, bytes)) continue;
		out[count].index = index;
		out[count].bits = 0;
		memcpy(&out[count].bits, b + fv, bytes);
		count++;
	}
	return count;
#undef FITS
}

static unsigned
akios_function_constants(id function, hakios_metal_constant *out, unsigned max)
{
	SEL scriptSel = sel_getUid("specializationAirScript");
	SEL baseSel = sel_getUid("baseFunctionConstantValues"), valueSel = sel_getUid("constantValueWithFunctionConstant:");
	unsigned n = 0;

	if (function != nil && [function respondsToSelector:scriptSel]) {
		dispatch_data_t script = ((dispatch_data_t (*)(id, SEL))objc_msgSend)(function, scriptSel);

		if (script != nil) {
			const void *bytes = NULL;
			size_t size = 0;
			/* (the map owns BYTES: kept until the reading is done) */
			__attribute__((objc_precise_lifetime)) dispatch_data_t map = dispatch_data_create_map(script, &bytes, &size);

			n = akios_script_constants(bytes, size, out, max);
			return n;
		}
	}
	if (function == nil || ![function respondsToSelector:@selector(functionConstantsDictionary)] || ![function respondsToSelector:baseSel]) {
		return 0;
	}
	NSDictionary *declared = [function functionConstantsDictionary];
	id values = ((id (*)(id, SEL))objc_msgSend)(function, baseSel);
	if (declared.count == 0 || values == nil || ![values respondsToSelector:valueSel]) {
		return 0;
	}
	for (NSString *name in declared) {
		MTLFunctionConstant *c = declared[name];
		const void *v = ((const void *(*)(id, SEL, id))objc_msgSend)(values, valueSel, c);
		unsigned bytes = akios_data_type_bytes(c.type);

		if (v == NULL || bytes == 0 || n >= max) {
			continue;
		}
		out[n].index = (unsigned)c.index;
		out[n].bits = 0;
		memcpy(&out[n].bits, v, bytes);
		n++;
	}
	return n;
}

@implementation AkiosMaliDevice (States)

static id
akios_refuse(NSError **error, const char *what, NSString *why)
{
	akios_say("refused: %s: %s\n", what, why.UTF8String);
	if (error != NULL) {
		*error = [NSError errorWithDomain:@"AkiosMetal" code:1 userInfo:@{ NSLocalizedDescriptionKey: why }];
	}
	return nil;
}

- (id)akComputePipelineForFunction:(id)function descriptor:(id)descriptor error:(NSError **)error
{
	SEL bitcodeSel = sel_getUid("bitcodeData");

	if (error != NULL) {
		*error = nil;
	}
	if (function == nil) {
		return akios_refuse(error, "a compute pipeline", @"the descriptor names no compute function");
	}
	if (![function respondsToSelector:bitcodeSel]) {
		return akios_refuse(error, "a compute pipeline", @"the function does not answer bitcodeData, so its AIR cannot be read");
	}
	NSData *air = ((NSData *(*)(id, SEL))objc_msgSend)(function, bitcodeSel);
	if (air.length == 0) {
		return akios_refuse(error, "a compute pipeline", @"the function has no bitcode");
	}
	hakios_metal_constant constants[64];
	unsigned count = akios_function_constants(function, constants, 64);
	hakios_metal_kernel *kernel = hakios_metal_kernel_compile_bitcode_constants(air.bytes, air.length, constants, count);
	if (kernel == NULL) {
		return akios_refuse(error, "a compute pipeline", [NSString stringWithFormat:@"%@: %s", [function name], hakios_metal_error()]);
	}
	return [[AkiosMaliComputePipelineState alloc] initWithAkiosDevice:self kernel:kernel descriptor:descriptor];
}

/* the base class demands a descriptor: Apple's own form builds an MTLComputePipelineDescriptorInternal */
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function error:(NSError **)error
{
	Class internal = objc_getClass("MTLComputePipelineDescriptorInternal");
	MTLComputePipelineDescriptor *descriptor = internal != Nil ? [[internal alloc] init] : [[MTLComputePipelineDescriptor alloc] init];

	descriptor.computeFunction = function;
	return [self akComputePipelineForFunction:function descriptor:descriptor error:error];
}

- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function options:(MTLPipelineOption)options
    reflection:(MTLAutoreleasedComputePipelineReflection *)reflection error:(NSError **)error
{
	(void)options;
	if (reflection != NULL) {
		*reflection = nil;   /* (reflection comes out of Apple's compiler, which this device has not got) */
	}
	return [self newComputePipelineStateWithFunction:function error:error];
}

- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)function completionHandler:(MTLNewComputePipelineStateCompletionHandler)handler
{
	NSError *error = nil;
	id<MTLComputePipelineState> state = [self newComputePipelineStateWithFunction:function error:&error];

	if (handler != NULL) {
		handler(state, error);
	}
}

- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)function options:(MTLPipelineOption)options
    completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)handler
{
	NSError *error = nil;
	id<MTLComputePipelineState> state = [self newComputePipelineStateWithFunction:function error:&error];

	(void)options;
	if (handler != NULL) {
		handler(state, nil, error);
	}
}

- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)descriptor
    options:(MTLPipelineOption)options reflection:(MTLAutoreleasedComputePipelineReflection *)reflection error:(NSError **)error
{
	(void)options;
	if (reflection != NULL) {
		*reflection = nil;
	}
	return [self akComputePipelineForFunction:descriptor.computeFunction descriptor:descriptor error:error];
}

- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)descriptor error:(NSError **)error
{
	return [self akComputePipelineForFunction:descriptor.computeFunction descriptor:descriptor error:error];
}

- (void)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)descriptor options:(MTLPipelineOption)options
    completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)handler
{
	NSError *error = nil;
	id<MTLComputePipelineState> state = [self newComputePipelineStateWithDescriptor:descriptor options:options reflection:NULL
	    error:&error];

	if (handler != NULL) {
		handler(state, nil, error);
	}
}

/*
 * Samplers: the descriptor's fields checked against the ranges -[_MTLSamplerState initWithDevice:samplerDescriptor:]
 * asserts on (an invalid one handed to super kills the process), then the core's words; only then super.
 */
- (id<MTLSamplerState>)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)descriptor
{
	struct hakios_metal_sampler_desc desc;

	if ([self akCore] == NULL || descriptor == nil || ![descriptor isKindOfClass:[MTLSamplerDescriptor class]]) {
		akios_say("refused: a sampler state: %s\n", [self akCore] == NULL ? "no Mali core" : "not an MTLSamplerDescriptor");
		return nil;
	}
	memset(&desc, 0, sizeof(desc));
	desc.min_filter = (unsigned)descriptor.minFilter;
	desc.mag_filter = (unsigned)descriptor.magFilter;
	desc.mip_filter = (unsigned)descriptor.mipFilter;
	desc.s_address = (unsigned)descriptor.sAddressMode;
	desc.t_address = (unsigned)descriptor.tAddressMode;
	desc.r_address = (unsigned)descriptor.rAddressMode;
	desc.normalized_coordinates = descriptor.normalizedCoordinates ? 1 : 0;
	desc.lod_min_clamp = descriptor.lodMinClamp;
	desc.lod_max_clamp = descriptor.lodMaxClamp;
	desc.max_anisotropy = (unsigned)descriptor.maxAnisotropy;
	desc.compare_function = (unsigned)descriptor.compareFunction;
	desc.border_color = (unsigned)descriptor.borderColor;
	if (desc.min_filter >= 3 || desc.mag_filter >= 3 || desc.mip_filter >= 3 || desc.s_address >= 7 || desc.t_address >= 7 ||
	    desc.r_address >= 7 || desc.border_color >= 4 || desc.compare_function > 7) {
		akios_say("refused: a sampler state: a field outside Metal's enums (filters %u/%u/%u, address modes %u/%u/%u, border %u, "
		    "compare %u)\n", desc.min_filter, desc.mag_filter, desc.mip_filter, desc.s_address, desc.t_address, desc.r_address,
		    desc.border_color, desc.compare_function);
		return nil;
	}
	hakios_metal_sampler *sampler = hakios_metal_sampler_new([self akCore], &desc);
	if (sampler == NULL) {
		akios_say("refused: a sampler state: %s\n", hakios_metal_error());
		return nil;
	}
	return (id<MTLSamplerState>)[[AkiosMaliSamplerState alloc] initWithAkiosDevice:self sampler:sampler descriptor:descriptor];
}

@end
