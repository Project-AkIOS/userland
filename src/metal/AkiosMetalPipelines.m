/*
 * AkiosMetalPipelines.m: render pipeline states made (the vertex and fragment functions' AIR compiled and linked by the
 * core, CoreAnimation's uber shaders specialised, the slow ones compiled in the background behind a stand-in),
 * pipeline reflection, depth/stencil states and argument encoders -- the earlier plug-in's (HakiosMetalCA.m),
 * carried over to ARC.
 */
#import "AkiosMetal.h"
#include <objc/message.h>
#include <sys/sysctl.h>
#include <time.h>
#include <mach/mach_time.h>


/*
 * CoreAnimation's shaders, chosen (hakios): this image is the iPhone X's, whose QuartzCore carries no default.metallib
 * of its functions -- only default.pipelinelib, a library of pipelines precompiled for Apple's GPU. Its "functions"
 * file holds every pipeline's functions all the same, as AIR: 451 single-function metallibs, the four uber shaders
 * (fixed_vert_lph_gen, fixed_vert_lph_spc, fixed_frag_lph_cpf, fixed_frag_lph_cph) each already specialised for one
 * set of CoreAnimation's constants, and pipelines.desc names them: its section 1 the label of each (in the order of the
 * functions file, "com.apple.coreanimation.frag.A2Xghfc"), its section 7 each pipeline's label with the labels of its
 * two functions. The window server is handed a default.metallib of one variant of each uber shader (ca_metallib=,
 * the kernel's inject.c); here, when a pipeline is made of one of them, the variant its label names is the one
 * compiled -- by the function's own label, or by the pipeline's (draw label -> vertex and fragment labels).
 */
#define AKM_CA_PIPELINELIB "/System/Library/Frameworks/QuartzCore.framework/default.pipelinelib"
static NSData *akm_ca_functions;                 /* the functions file, mapped */
static NSMutableDictionary *akm_ca_variants;     /* function label -> NSData of its module (the 0x0B17C0DE wrapper) */
static NSMutableDictionary *akm_ca_pipelines;    /* draw label -> @[vertex label, fragment label] */
static NSMutableDictionary *akm_ca_frag_vert;    /* fragment label -> the vertex label every pipeline of it has */

static NSData *
akm_ca_module(const uint8_t *lib, size_t size)
{
	uint64_t funcs, bc;
	uint32_t entry;

	/* the one function's bitcode: the bitcode section at +0x48 plus the function's OFFT, MDSZ long */
	if (size < 0x58 || memcmp(lib, "MTLB", 4) != 0) {
		return nil;
	}
	memcpy(&funcs, lib + 0x18, 8);
	memcpy(&bc, lib + 0x48, 8);
	if (funcs + 8 > size) {
		return nil;
	}
	memcpy(&entry, lib + funcs + 4, 4);
	for (uint64_t q = funcs + 8, end = funcs + 4 + entry, offt = ~0ull, mdsz = 0; q + 6 <= end && q + 6 <= size;) {
		uint16_t len;

		if (memcmp(lib + q, "ENDT", 4) == 0) {
			break;
		}
		memcpy(&len, lib + q + 4, 2);
		if (memcmp(lib + q, "OFFT", 4) == 0 && len == 24 && q + 6 + 24 <= size) {
			memcpy(&offt, lib + q + 6 + 16, 8);
		} else if (memcmp(lib + q, "MDSZ", 4) == 0 && len == 8 && q + 6 + 8 <= size) {
			memcpy(&mdsz, lib + q + 6, 8);
		}
		q += 6 + len;
		if ((offt != ~0ull && mdsz != 0) && bc + offt + mdsz <= size) {
			return [NSData dataWithBytes:lib + bc + offt length:(NSUInteger)mdsz];
		}
	}
	return nil;
}

static void
akm_ca_load(void)
{
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		NSData *desc = [NSData dataWithContentsOfFile:@AKM_CA_PIPELINELIB "/pipelines.desc"];
		const uint8_t *d = [desc bytes], *f;
		size_t dn = [desc length], fn, at = 0;
		uint32_t sections, off[16], n;
		NSMutableArray *labels = [NSMutableArray array];

		akm_ca_functions = [[NSData alloc] initWithContentsOfFile:@AKM_CA_PIPELINELIB "/functions"
								 options:NSDataReadingMappedIfSafe error:NULL];
		akm_ca_variants = [[NSMutableDictionary alloc] init];
		akm_ca_pipelines = [[NSMutableDictionary alloc] init];
		akm_ca_frag_vert = [[NSMutableDictionary alloc] init];
		if (desc == nil || akm_ca_functions == nil || dn < 8) {
			akios_say("CoreAnimation's pipeline library is not at " AKM_CA_PIPELINELIB ": no variants to choose from\n");
			return;
		}
		memcpy(&sections, d, 4);
		if (sections > 16 || 4 + 4 * sections > dn) {
			return;
		}
		memcpy(off, d + 4, 4 * sections);
		/* section 1: the functions' labels, in the order of the functions file */
		if (sections > 7 && off[1] + 4 <= dn) {
			memcpy(&n, d + off[1], 4);
			for (uint32_t i = 0; i < n && off[1] + 8 + 4 * i <= dn; i++) {
				uint32_t r;

				memcpy(&r, d + off[1] + 4 + 4 * i, 4);
				if (off[1] + r + 16 < dn) {
					const char *label = (const char *)d + off[1] + r + 16;

					[labels addObject:[NSString stringWithUTF8String:strnlen(label, dn - off[1] - r - 16) < 200 ? label : ""]];
				}
			}
		}
		/* the functions file: the metallibs one after the other, in that order */
		f = [akm_ca_functions bytes];
		fn = [akm_ca_functions length];
		for (NSUInteger i = 0; i < [labels count]; i++) {
			const uint8_t *m = at < fn ? memmem(f + at, fn - at, "MTLB", 4) : NULL;
			uint64_t total;
			NSData *module;

			if (m == NULL || (size_t)(m - f) + 0x18 > fn) {
				break;
			}
			memcpy(&total, m + 0x10, 8);
			if ((size_t)(m - f) + total > fn) {
				break;
			}
			if ((module = akm_ca_module(m, (size_t)total)) != nil) {
				akm_ca_variants[labels[i]] = module;
			}
			at = (size_t)(m - f) + (size_t)total;
		}
		/* section 7: each pipeline's label with its functions' (draw, vert, frag), as strings in its entry */
		if (sections > 8 && off[7] + 4 <= dn) {
			memcpy(&n, d + off[7], 4);
			for (uint32_t i = 0; i < n && off[7] + 8 + 4 * i <= dn; i++) {
				uint32_t r, next = i + 1 < n ? 0 : off[8] - off[7];
				NSString *draw = nil, *vert = nil, *frag = nil;

				memcpy(&r, d + off[7] + 4 + 4 * i, 4);
				if (i + 1 < n) {
					memcpy(&next, d + off[7] + 4 + 4 * (i + 1), 4);
				}
				for (uint32_t q = r; q + 24 < next && off[7] + q + 24 < dn; q++) {
					const char *s = (const char *)d + off[7] + q;

					if (strncmp(s, "com.apple.coreanimation.", 24) != 0) {
						continue;
					}
					NSString *label = [NSString stringWithUTF8String:s];
					if ([label hasPrefix:@"com.apple.coreanimation.draw."]) draw = label;
					else if ([label hasPrefix:@"com.apple.coreanimation.vert."]) vert = label;
					else if ([label hasPrefix:@"com.apple.coreanimation.frag."]) frag = label;
					q += (uint32_t)strlen(s);
				}
				if (draw != nil && vert != nil) {
					akm_ca_pipelines[draw] = frag != nil ? @[vert, frag] : @[vert];
					if (frag != nil) akm_ca_frag_vert[frag] = vert;
				}
			}
		}
		akios_say("CoreAnimation's shaders: %lu labelled variants of its uber shaders, %lu pipelines (" AKM_CA_PIPELINELIB ")\n",
			 (unsigned long)[akm_ca_variants count], (unsigned long)[akm_ca_pipelines count]);
	});
}

/*
 * The nearest variant to a fragment function the library does not have. CoreAnimation makes pipelines at run time that no
 * precompiled one is: TimgA2S1Xhf_Ixrg (an opaque image, for a compositing filter, the default wallpaper's head) or
 * TimgBdsoA2Xhfn_Isrc (darkenSourceOver, the status bar's legibility gradient). Compiled from the one variant the window server's
 * library holds, those drew something else altogether: the head nothing, the gradient solid white (4 November).
 * A label is T(what is sampled) B(the blend) A(the varyings) S(a second sampler) X(flags)_(the inputs): what is sampled, the blend
 * and the varyings must be the same, or it is another program. Then the fewest inputs changed, and a flag left out (a feature the
 * program did not ask for is not fed) before a flag added. What the letters mean is read from the labels, not from a document.
 */
/* Levenshtein's distance between two short strings (a label's inputs) */
static NSInteger
akm_edit_distance(NSString *a, NSString *b)
{
	const NSUInteger n = [a length], m = [b length];
	NSInteger row[64];

	if (m + 1 > 64) {
		return labs((long)n - (long)m) + 64;
	}
	for (NSUInteger j = 0; j <= m; j++) {
		row[j] = (NSInteger)j;
	}
	for (NSUInteger i = 1; i <= n; i++) {
		NSInteger diag = row[0];

		row[0] = (NSInteger)i;
		for (NSUInteger j = 1; j <= m; j++) {
			const NSInteger up = row[j];
			const NSInteger sub = diag + ([a characterAtIndex:i - 1] == [b characterAtIndex:j - 1] ? 0 : 1);

			row[j] = MIN(MIN(up + 1, row[j - 1] + 1), sub);
			diag = up;
		}
	}
	return row[m];
}

static NSString *
akm_ca_nearest(NSString *frag)
{
	static NSMutableDictionary *told;
	static NSRegularExpression *form;
	static NSString *const prefix = @"com.apple.coreanimation.frag.";
	NSString *best = nil;
	NSInteger bestCost = NSIntegerMax;

	if (![frag hasPrefix:prefix]) {
		return nil;
	}
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		form = [[NSRegularExpression alloc] initWithPattern:@"^(T[a-z0-9]{3})?(B[a-z]{3})?(D[a-z]{2})?(A[0-9])(S[0-9])?(L[a-z]{2})?X([a-z]*)((?:_[A-Za-z0-9]+)*)$"
							    options:0 error:NULL];
		told = [[NSMutableDictionary alloc] init];
	});
	NSString *(^part)(NSTextCheckingResult *, NSUInteger, NSString *) = ^NSString *(NSTextCheckingResult *m, NSUInteger i, NSString *of) {
		NSRange r = [m rangeAtIndex:i];

		return r.location == NSNotFound ? @"" : [of substringWithRange:r];
	};
	NSString *want = [frag substringFromIndex:[prefix length]];
	NSTextCheckingResult *w = [form firstMatchInString:want options:0 range:NSMakeRange(0, [want length])];

	if (w == nil) {
		return nil;
	}
	for (NSString *candidate in akm_ca_frag_vert) {
		if (![candidate hasPrefix:prefix] || akm_ca_variants[candidate] == nil) {
			continue;
		}
		NSString *have = [candidate substringFromIndex:[prefix length]];
		NSTextCheckingResult *h = [form firstMatchInString:have options:0 range:NSMakeRange(0, [have length])];
		BOOL same = h != nil;
		NSInteger cost = 0;

		for (NSUInteger i = 1; same && i <= 6; i++) {
			same = [part(w, i, want) isEqualToString:part(h, i, have)];
		}
		if (!same) {
			continue;
		}
		NSString *wantFlags = part(w, 7, want), *haveFlags = part(h, 7, have);
		NSArray *wantIn = [part(w, 8, want) componentsSeparatedByString:@"_"], *haveIn = [part(h, 8, have) componentsSeparatedByString:@"_"];

		if ([wantIn count] != [haveIn count]) {
			continue;
		}
		for (NSUInteger i = 0; i < [wantIn count]; i++) {
			/* (an input that does more than was asked for last: IsrcN3Oc3mtc4 is a colour matrix, not a plain sample;
			 * among other inputs the nearest by edit distance -- by length alone TcimA2S1Xhfn_IsrcN3Oc3mtc4 (the
			 * launch snapshot through a colour matrix) got IalpCcl, alpha times a constant colour, over Isrc: an
			 * opaque snapshot came out as the matrix's numbers taken for a colour, whole frames blue or cyan during an
			 * app launch, the tester's video of 11-09) */
			cost += [wantIn[i] isEqualToString:haveIn[i]] ? 0 : 100 + akm_edit_distance(wantIn[i], haveIn[i]);
		}
		for (NSUInteger i = 0; i < [wantFlags length]; i++) {
			cost += [haveFlags rangeOfString:[wantFlags substringWithRange:NSMakeRange(i, 1)]].location == NSNotFound ? 3 : 0;
		}
		for (NSUInteger i = 0; i < [haveFlags length]; i++) {
			cost += [wantFlags rangeOfString:[haveFlags substringWithRange:NSMakeRange(i, 1)]].location == NSNotFound ? 10 : 0;
		}
		if (cost < bestCost || (cost == bestCost && [candidate compare:best] == NSOrderedAscending)) {
			best = candidate;
			bestCost = cost;
		}
	}
	@synchronized (told) {
		if (told[frag] == nil) {
			told[frag] = @YES;
			akios_say("CoreAnimation's %s is not in the library: %s stands in for it\n", [want UTF8String],
				 best != nil ? [[best substringFromIndex:[prefix length]] UTF8String] : "nothing of the same kind");
		}
	}
	return best;
}

/* (weak: the Adreno build of hakios-metal has no such call) */
extern unsigned hakios_metal_bitcode_constant_count(const void *bitcode, size_t size) __attribute__((weak_import));

/* The module to compile for FUNCTION (of the pipeline labelled PIPELINE, vertex stage or not): its variant when
 * CoreAnimation's labels name one, else what the function itself has. */
static NSData *
akm_bitcode_for(id function, NSString *pipeline, BOOL vertex)
{
	static unsigned said;
	NSString *name = [function respondsToSelector:@selector(name)] ? [function name] : nil, *label = nil, *chosen = nil;
	NSData *own = ((NSData *(*)(id, SEL))objc_msgSend)(function, sel_getUid("bitcodeData")), *variant = nil;

	if (name != nil && [name hasPrefix:@"edr_scale_"]) {
		/* the stand-in at compile time too: the window server gets edr_scale by a road the library hooks do not see,
		 * and the later CoreAnimation's reads buffers iOS 16.5's never binds (see akm_stand_ins) */
		static NSData *copies[2];
		static dispatch_once_t once;
		const int lpf = [name hasSuffix:@"_lpf"];

		dispatch_once(&once, ^{
			id<MTLDevice> device = [function respondsToSelector:@selector(device)] ? [function device] : nil;

			if (device == nil) device = MTLCreateSystemDefaultDevice();   /* (the function's own answered nil) */
			NSError *e = nil;
			id lib = [device newLibraryWithURL:[NSURL fileURLWithPath:@"/akita/share/ca-share/QuartzCore-default.metallib"]
						     error:&e];
			akios_say("inplace_copy for edr_scale: device %s, library %s%s\n", device ? "yes" : "nil", lib ? "opened" : "not opened: ",
				 lib ? "" : [[e description] UTF8String]);
			for (int i = 0; i < 2 && lib != nil; i++) {
				id f = [lib newFunctionWithName:i ? @"inplace_copy_lpf" : @"inplace_copy_lph"];

				if (f != nil && [f respondsToSelector:sel_getUid("bitcodeData")]) {
					copies[i] = ((NSData *(*)(id, SEL))objc_msgSend)(f, sel_getUid("bitcodeData"));
				}
			}
		});
		static unsigned told;
		if (told++ < 3 || (told & (told - 1)) == 0) {
			akios_say("CoreAnimation's %s: %s (%u times)\n", [name UTF8String], copies[lpf] != nil ?
				 "compiled as inplace_copy, the source as it is" : "no inplace_copy to stand in, its own module", told);
		}
		if (copies[lpf] != nil) {
			return copies[lpf];
		}
		return own;
	}
	if (name == nil || ![name hasPrefix:@"fixed_"]) {
		return own;
	}
	/* THE GENERIC UBER SHADERS (the iPhone 11's 20F66 library, the same CoreAnimation: tools/ca-metallib.py keeps them
	 * as they are): Metal specialises the function with the pipeline's constants itself (fc_color_opcodes0 58,
	 * fc_color_inputs0 56, ...) and hands over a module of a few KB that IS that pipeline's shader -- for the pipelines
	 * the pipeline library names and for the ones CoreAnimation makes at run time alike. So it is compiled as it is:
	 * no variant, no nearest one (a nearest one drew whole frames blue or cyan at app launches, 11-09). Decided once,
	 * by whether the library's own fixed_frag_lph_cph declares function constants. Boot-arg ca_variants: the
	 * pipeline library's variants instead, as before. */
	static int generic = -1;
	static dispatch_once_t genericOnce;
	dispatch_once(&genericOnce, ^{
		char args[1024] = "", path[512] = "/akita/share/ca-share/QuartzCore-default.metallib";
		size_t size = sizeof(args) - 1;
		const char *at;

		generic = 0;
		if (akios_boot_arg("ca_variants") || hakios_metal_bitcode_constant_count == NULL) {
			return;
		}
		if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && (at = strstr(args, "ca_metallib=")) != NULL) {
			snprintf(path, sizeof(path), "%.*s", (int)strcspn(at + 12, " "), at + 12);
		}
		id<MTLDevice> device = [function respondsToSelector:@selector(device)] ? [function device] : nil;
		NSError *e = nil;
		id lib = device ? [device newLibraryWithURL:[NSURL fileURLWithPath:@(path)] error:&e] : nil;
		id f = [lib newFunctionWithName:@"fixed_frag_lph_cph"];
		NSData *air = f != nil && [f respondsToSelector:sel_getUid("bitcodeData")] ?
			((NSData *(*)(id, SEL))objc_msgSend)(f, sel_getUid("bitcodeData")) : nil;
		unsigned declared = air != nil ? hakios_metal_bitcode_constant_count([air bytes], [air length]) : 0;

		generic = declared > 0;
		akios_say("CoreAnimation's uber shaders in %s: %s (fixed_frag_lph_cph, %lu bytes of AIR, %u function constants)\n",
			 path, generic ? "GENERIC -- what Metal specialises per pipeline is compiled as it is, no variants" :
			 "already specialised -- the pipeline library's variants, the nearest for a pipeline it does not name",
			 (unsigned long)[air length], declared);
	});
	if (generic > 0) {
		return own;
	}
	akm_ca_load();
	if ([function respondsToSelector:@selector(label)]) {
		label = [function label];
	}
	if (label != nil && (variant = akm_ca_variants[label]) != nil) {
		chosen = label;
	} else if (pipeline != nil && akm_ca_pipelines[pipeline] != nil) {
		NSArray *pair = akm_ca_pipelines[pipeline];

		chosen = vertex ? pair[0] : ([pair count] > 1 ? pair[1] : nil);
		variant = chosen != nil ? akm_ca_variants[chosen] : nil;
	} else if (pipeline != nil && [pipeline hasPrefix:@"com.apple.coreanimation.draw."]) {
		/* a pipeline CoreAnimation makes at run time, which the library does not name: its fragment function is the
		 * spec after the first '_' (so in all 986 the library names) and its vertex one the one every pipeline of that
		 * fragment function has (one each, in all 444) -- picked apart, a pipeline got the wrong vertex variant and
		 * the link refused it ("reads varying slot 33, which the vertex stage does not write"), and CoreAnimation
		 * aborted the window server */
		NSString *spec = [pipeline substringFromIndex:[@"com.apple.coreanimation.draw." length]];
		NSRange under = [spec rangeOfString:@"_"];
		NSString *frag = under.location != NSNotFound ?
			[@"com.apple.coreanimation.frag." stringByAppendingString:[spec substringFromIndex:NSMaxRange(under)]] : nil;

		if (frag != nil && akm_ca_variants[frag] == nil) {
			frag = akm_ca_nearest(frag);
		}
		chosen = frag == nil ? nil : (vertex ? akm_ca_frag_vert[frag] : frag);
		variant = chosen != nil ? akm_ca_variants[chosen] : nil;
	}
	if (variant == nil || said++ < 40) {
		akios_say("CoreAnimation's %s (label %s, pipeline %s): %s%s\n", [name UTF8String], label ? [label UTF8String] : "none",
			 pipeline ? [pipeline UTF8String] : "none", variant ? "the variant " : "no variant: its own module",
			 variant ? [chosen UTF8String] : "");
	}
	return variant != nil ? variant : own;
}

/* The same choice for UniXNU's Metal on Vulkan (metal_m2v=1), whose functions are its own objects: by the function's name,
 * its label and the pipeline's (native_bridge_metal_variant_hook, NativeBridgeMetalFrontend.mm: variantFunction()). */

@interface AkiosMaliArgument : NSObject {
@public
	NSString *_name;
	MTLArgumentType _type;
	MTLArgumentAccess _access;
	NSUInteger _index, _size;
}
@end

@implementation AkiosMaliArgument
- (NSString *)name { return _name; }
- (MTLArgumentType)type { return _type; }
- (MTLBindingType)bindingType { return (MTLBindingType)_type; }
- (MTLArgumentAccess)access { return _access; }
- (NSUInteger)index { return _index; }
- (BOOL)isActive { return YES; }
- (BOOL)isUsed { return YES; }
- (BOOL)isArgument { return NO; }
- (NSUInteger)bufferAlignment { return _type == MTLArgumentTypeBuffer ? 16 : 0; }
- (NSUInteger)bufferDataSize { return _type == MTLArgumentTypeBuffer ? _size : 0; }
- (MTLDataType)bufferDataType { return _type == MTLArgumentTypeBuffer ? (_size ? MTLDataTypeStruct : MTLDataTypeNone) : MTLDataTypeNone; }
- (MTLStructType *)bufferStructType { return nil; }
- (MTLPointerType *)bufferPointerType { return nil; }
- (NSUInteger)threadgroupMemoryAlignment { return 0; }
- (NSUInteger)threadgroupMemoryDataSize { return 0; }
- (MTLTextureType)textureType { return MTLTextureType2D; }
- (MTLDataType)textureDataType { return MTLDataTypeFloat; }
- (BOOL)isDepthTexture { return NO; }
- (NSUInteger)arrayLength { return 1; }
- (NSString *)description { return [NSString stringWithFormat:@"<AkiosMaliArgument %@ type %lu index %lu size %lu>", _name,
					       (unsigned long)_type, (unsigned long)_index, (unsigned long)_size]; }
@end

@interface AkiosMaliRenderReflection : NSObject {
	NSArray *_vertex, *_fragment;
}
- (instancetype)initWithProgram:(hakios_metal_program *)program;
@end

@implementation AkiosMaliRenderReflection
static NSArray *
akm_arguments_of(hakios_metal_program *program, unsigned stage)
{
	NSMutableArray *args = [NSMutableArray array];
	unsigned n = program != NULL ? hakios_metal_program_resource_count(program, stage) : 0;

	for (unsigned i = 0; i < n; i++) {
		unsigned kind = 0, index = 0, size = 0, type_size = 0;
		const char *name = hakios_metal_program_resource_name(program, stage, i, &type_size);

		if (hakios_metal_program_resource(program, stage, i, &kind, &index, &size) != 0)
			continue;
		AkiosMaliArgument *a = [[AkiosMaliArgument alloc] init];
		a->_name = [[NSString alloc] initWithUTF8String:name != NULL && name[0] ? name : "unnamed"];
		a->_index = index;
		a->_size = type_size ? type_size : size;
		switch (kind) {
		case HAKIOS_METAL_RESOURCE_CONSTANT_BUFFER: a->_type = MTLArgumentTypeBuffer; a->_access = MTLArgumentAccessReadOnly; break;
		case HAKIOS_METAL_RESOURCE_DEVICE_BUFFER: a->_type = MTLArgumentTypeBuffer; a->_access = MTLArgumentAccessReadWrite; break;
		case HAKIOS_METAL_RESOURCE_THREADGROUP_BUFFER: a->_type = MTLArgumentTypeThreadgroupMemory; a->_access = MTLArgumentAccessReadWrite; break;
		case HAKIOS_METAL_RESOURCE_TEXTURE: a->_type = MTLArgumentTypeTexture; a->_access = MTLArgumentAccessReadOnly; break;
		case HAKIOS_METAL_RESOURCE_IMAGE: a->_type = MTLArgumentTypeTexture; a->_access = MTLArgumentAccessWriteOnly; break;
		default: a->_type = MTLArgumentTypeSampler; a->_access = MTLArgumentAccessReadOnly; break;
		}
		[args addObject:a];
	}
	return args;
}

- (instancetype)initWithProgram:(hakios_metal_program *)program
{
	if ((self = [super init]) != nil) {
		_vertex = akm_arguments_of(program, 0);
		_fragment = akm_arguments_of(program, 1);
	}
	return self;
}
- (NSArray *)vertexArguments { return _vertex; }
- (NSArray *)fragmentArguments { return _fragment; }
- (NSArray *)tileArguments { return @[]; }
- (NSArray *)vertexBindings { return _vertex; }
- (NSArray *)fragmentBindings { return _fragment; }
- (NSArray *)tileBindings { return @[]; }
- (NSArray *)objectBindings { return @[]; }
- (NSArray *)meshBindings { return @[]; }
@end


@interface AkiosMaliArgumentEncoder : NSObject {
	id<MTLDevice> _device;
	NSString *_label;
	NSUInteger _count;
	NSUInteger *_ids, *_offsets, *_lengths;   /* by position, sorted by id: the member's id, byte offset, array length */
	NSUInteger _length;
	id _buffer;
	NSUInteger _base;
	char _source[96];                         /* where the layout came from, for a refusal to say */
}
- (instancetype)initWithDevice:(id)device arguments:(NSArray *)arguments;
- (void)akSetSource:(const char *)source;
- (instancetype)initWithDevice:(id)device ids:(const unsigned *)ids offsets:(const unsigned *)offsets count:(NSUInteger)count;
@end

@implementation AkiosMaliArgumentEncoder


+ (void)load
{
	class_addProtocol(self, @protocol(MTLArgumentEncoder));
}

- (instancetype)initWithDevice:(id)device arguments:(NSArray *)arguments
{
	self = [super init];
	if (self == nil) return nil;
	NSArray *sorted = [arguments sortedArrayUsingComparator:^NSComparisonResult(MTLArgumentDescriptor *a, MTLArgumentDescriptor *b) {
		return [a index] < [b index] ? NSOrderedAscending : [a index] > [b index] ? NSOrderedDescending : NSOrderedSame;
	}];
	_device = device;
	_count = [sorted count];
	_ids = calloc(_count + 1, sizeof(NSUInteger));
	_offsets = calloc(_count + 1, sizeof(NSUInteger));
	_lengths = calloc(_count + 1, sizeof(NSUInteger));
	for (NSUInteger i = 0; i < _count; i++) {
		MTLArgumentDescriptor *d = sorted[i];
		_ids[i] = [d index];
		_offsets[i] = _length;
		_lengths[i] = [d arrayLength] != 0 ? [d arrayLength] : 1;
		_length += 8 * _lengths[i];
	}
	return self;
}

/* a function's set as its metadata lays it out (hakios_metal_argument_buffer_layout): each member at its own offset,
 * one element each -- the front end reads an array member as members of their own -- and the set eight bytes a member */
- (instancetype)initWithDevice:(id)device ids:(const unsigned *)ids offsets:(const unsigned *)offsets count:(NSUInteger)count
{
	self = [super init];
	if (self == nil) return nil;
	_device = device;
	_count = count;
	_ids = calloc(_count + 1, sizeof(NSUInteger));
	_offsets = calloc(_count + 1, sizeof(NSUInteger));
	_lengths = calloc(_count + 1, sizeof(NSUInteger));
	for (NSUInteger i = 0; i < _count; i++) {
		_ids[i] = ids[i];
		_offsets[i] = offsets[i];
		_lengths[i] = 1;
		_length = MAX(_length, (NSUInteger)offsets[i] + 8);
	}
	return self;
}

- (void)dealloc
{
	free(_ids);
	free(_offsets);
	free(_lengths);
}

- (id<MTLDevice>)device { return _device; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (void)akSetSource:(const char *)source { snprintf(_source, sizeof(_source), "%s", source); }
- (NSUInteger)encodedLength { return _length; }
- (NSUInteger)alignment { return 8; }

- (void)setArgumentBuffer:(id)buffer offset:(NSUInteger)offset
{
	_buffer = buffer;
	_base = offset;
}

- (void)setArgumentBuffer:(id)buffer startOffset:(NSUInteger)startOffset arrayElement:(NSUInteger)arrayElement
{
	[self setArgumentBuffer:buffer offset:startOffset + arrayElement * _length];
}

/* the eight bytes of member ID's element ELEMENT in the buffer set above, or NULL (said once) */
- (uint64_t *)akSlot:(NSUInteger)index element:(NSUInteger)element
{
	if (_buffer == nil) {
		AK_ONCE("an argument encoder was given a member before an argument buffer; nothing is written\n");
		return NULL;
	}
	for (NSUInteger i = 0; i < _count; i++) {
		if (index >= _ids[i] && index < _ids[i] + _lengths[i]) {
			const NSUInteger at = _base + _offsets[i] + 8 * (index - _ids[i] + element);
			if (at + 8 > [(id<MTLBuffer>)_buffer length]) return NULL;
			return (uint64_t *)((uint8_t *)[(id<MTLBuffer>)_buffer contents] + at);
		}
	}
	{
		/* which encoder: where its layout came from and the ids it has, so that a member missing from it is told from a
		 * member missing from the function's own set */
		char ids[160] = "";
		size_t n = 0;

		for (NSUInteger i = 0; i < _count && n < sizeof(ids); i++) {
			n += (size_t)snprintf(ids + n, sizeof(ids) - n, "%s%lu", i ? "," : "", (unsigned long)_ids[i]);
		}
		akios_say("refused: an argument encoder's member %lu, which its layout has not got (ids %s, from %s); nothing is written\n",
			 (unsigned long)index, ids, _source[0] ? _source : "a descriptor array");
	}
	return NULL;
}

- (void)setBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	uint64_t *w = [self akSlot:index element:0];
	if (w != NULL) *w = buffer != nil ? [(id<MTLBuffer>)buffer gpuAddress] + offset : 0;
}

- (void)setBuffers:(const id *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) [self setBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
}

- (void)setTexture:(id)texture atIndex:(NSUInteger)index
{
	uint64_t *w = [self akSlot:index element:0];
	if (w != NULL) *w = texture != nil ? [(id<MTLTexture>)texture gpuResourceID]._impl : 0;
}

- (void)setTextures:(const id *)textures withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) [self setTexture:textures[i] atIndex:range.location + i];
}

- (void)setSamplerState:(id)sampler atIndex:(NSUInteger)index
{
	uint64_t *w = [self akSlot:index element:0];
	if (w != NULL) *w = sampler != nil ? [(id<MTLSamplerState>)sampler gpuResourceID]._impl : 0;
}

- (void)setSamplerStates:(const id *)samplers withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) [self setSamplerState:samplers[i] atIndex:range.location + i];
}

- (void *)constantDataAtIndex:(NSUInteger)index
{
	akios_say("refused: -[MTLArgumentEncoder constantDataAtIndex:%lu]: inlined constant data has no place in the eight-bytes-a-member "
		 "layout; it returns NULL\n", (unsigned long)index);
	return NULL;
}

- (id)newArgumentEncoderForBufferAtIndex:(NSUInteger)index
{
	akios_say("refused: a nested argument encoder (member %lu): argument buffers inside argument buffers are not served; it returns nil\n",
		 (unsigned long)index);
	return nil;
}

/* argument buffer members of kinds the front end's layout has no slot for: said once, nothing written */
#define AKM_ARGENC_REFUSE(what) AK_ONCE("refused: an argument encoder's %s (not served); nothing is written\n", what)
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)s atIndex:(NSUInteger)i { (void)s; (void)i; AKM_ARGENC_REFUSE("render pipeline"); }
- (void)setRenderPipelineStates:(const id<MTLRenderPipelineState> __unsafe_unretained *)s withRange:(NSRange)r { (void)s; (void)r; AKM_ARGENC_REFUSE("render pipelines"); }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)s atIndex:(NSUInteger)i { (void)s; (void)i; AKM_ARGENC_REFUSE("compute pipeline"); }
- (void)setComputePipelineStates:(const id<MTLComputePipelineState> __unsafe_unretained *)s withRange:(NSRange)r { (void)s; (void)r; AKM_ARGENC_REFUSE("compute pipelines"); }
- (void)setDepthStencilState:(id<MTLDepthStencilState>)s atIndex:(NSUInteger)i { (void)s; (void)i; AKM_ARGENC_REFUSE("depth/stencil state"); }
- (void)setDepthStencilStates:(const id<MTLDepthStencilState> __unsafe_unretained *)s withRange:(NSRange)r { (void)s; (void)r; AKM_ARGENC_REFUSE("depth/stencil states"); }
- (void)setIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)b atIndex:(NSUInteger)i { (void)b; (void)i; AKM_ARGENC_REFUSE("indirect command buffer"); }
- (void)setIndirectCommandBuffers:(const id<MTLIndirectCommandBuffer> __unsafe_unretained *)b withRange:(NSRange)r { (void)b; (void)r; AKM_ARGENC_REFUSE("indirect command buffers"); }
- (void)setAccelerationStructure:(id<MTLAccelerationStructure>)a atIndex:(NSUInteger)i { (void)a; (void)i; AKM_ARGENC_REFUSE("acceleration structure"); }
- (void)setVisibleFunctionTable:(id<MTLVisibleFunctionTable>)t atIndex:(NSUInteger)i { (void)t; (void)i; AKM_ARGENC_REFUSE("visible function table"); }
- (void)setVisibleFunctionTables:(const id<MTLVisibleFunctionTable> __unsafe_unretained *)t withRange:(NSRange)r { (void)t; (void)r; AKM_ARGENC_REFUSE("visible function tables"); }
- (void)setIntersectionFunctionTable:(id<MTLIntersectionFunctionTable>)t atIndex:(NSUInteger)i { (void)t; (void)i; AKM_ARGENC_REFUSE("intersection function table"); }
- (void)setIntersectionFunctionTables:(const id<MTLIntersectionFunctionTable> __unsafe_unretained *)t withRange:(NSRange)r { (void)t; (void)r; AKM_ARGENC_REFUSE("intersection function tables"); }

@end

@implementation AkiosMaliDevice (RenderPipelines)

/* milliseconds since T0 (mach_absolute_time) */
static unsigned long long
akm_ms_since(uint64_t t0)
{
	static mach_timebase_info_data_t timebase;

	if (timebase.denom == 0) {
		mach_timebase_info(&timebase);
	}
	return (unsigned long long)((mach_absolute_time() - t0) * timebase.numer / timebase.denom / 1000000);
}

- (id)akRefuse:(NSError **)error what:(const char *)what why:(NSString *)why
{
	akios_say("refused: %s: %s\n", what, why.UTF8String);
	if (error != NULL) {
		*error = [NSError errorWithDomain:@"AkiosMetal" code:1 userInfo:@{ NSLocalizedDescriptionKey: why }];
	}
	return nil;
}


/* An argument encoder for buffer INDEX of FUNCTION, from what the function's AIR says the set holds; nil, said, when it has
 * no set there or the front end refused it. */
static id
akm_function_argument_encoder(id function, NSUInteger index)
{
	NSData *air = akm_bitcode_for(function, nil, NO);
	NSString *name = [(id<MTLFunction>)function name];
	unsigned *ids, *offsets;
	int n;

	n = air != nil ? hakios_metal_argument_buffer_layout([air bytes], [air length], (unsigned)index, NULL, NULL, 0) : -1;
	if (n <= 0) {
		akios_say("refused: an argument encoder for buffer %lu of %s: %s; it returns nil\n", (unsigned long)index,
			 name != nil ? [name UTF8String] : "a function", air != nil ? hakios_metal_error() : "no bitcodeData");
		return nil;
	}
	ids = calloc((size_t)n, sizeof(unsigned));
	offsets = calloc((size_t)n, sizeof(unsigned));
	{
		const int filled = hakios_metal_argument_buffer_layout([air bytes], [air length], (unsigned)index, ids, offsets, (unsigned)n);

		if (filled != n) {
			akios_say("refused: an argument encoder for buffer %lu of %s: its layout read %d members, then %d: %s; it returns nil\n",
				 (unsigned long)index, name != nil ? [name UTF8String] : "a function", n, filled, filled < 0 ? hakios_metal_error() : "");
			free(ids);
			free(offsets);
			return nil;
		}
	}
	id encoder = [[AkiosMaliArgumentEncoder alloc] initWithDevice:[(id<MTLFunction>)function device] ids:ids offsets:offsets
								     count:(NSUInteger)n];
	char source[96];

	snprintf(source, sizeof(source), "buffer %lu of %s", (unsigned long)index, name != nil ? [name UTF8String] : "a function");
	[encoder akSetSource:source];
	free(ids);
	free(offsets);
	return encoder;
}

/*
 * MTLFunction's -newArgumentEncoderWithBufferIndex: (and its reflection: form), for functions of this device. Metal's
 * own builds the encoder from the reflection Apple's GPU compiler writes beside a function; no function here has any,
 * so for every index it asserts "bufferIndex 0 does not identify an argument buffer" and aborts the process -- which
 * is how Resident Evil 4 ended, before its first frame. The class's two methods are wrapped once: a function whose
 * device is this one gets an encoder laid out by the metadata, any other the original's answer.
 */
void
akm_functions_encode_from_metadata(void)
{
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		Class c = objc_getClass("_MTLFunction");
		SEL plain = sel_getUid("newArgumentEncoderWithBufferIndex:");
		SEL reflected = sel_getUid("newArgumentEncoderWithBufferIndex:reflection:");
		Method m;

		if (c == Nil) {
			akios_say("no _MTLFunction class: argument encoders from functions stay Metal's own\n");
			return;
		}
		/* (both are of Metal's new family: the object goes back retained, +1. Raw pointers here, so that ARC neither
		 * retains what the original hands back nor autoreleases what is returned) */
		if ((m = class_getInstanceMethod(c, plain)) != NULL) {
			void *(*original)(id, SEL, NSUInteger) = (void *(*)(id, SEL, NSUInteger))method_getImplementation(m);
			method_setImplementation(m, imp_implementationWithBlock(^void *(id self, NSUInteger index) {
				if (![[(id<MTLFunction>)self device] isKindOfClass:[AkiosMaliDevice class]]) return original(self, plain, index);
				return (__bridge_retained void *)akm_function_argument_encoder(self, index);
			}));
		}
		if ((m = class_getInstanceMethod(c, reflected)) != NULL) {
			void *(*original)(id, SEL, NSUInteger, void **) = (void *(*)(id, SEL, NSUInteger, void **))method_getImplementation(m);
			method_setImplementation(m, imp_implementationWithBlock(^void *(id self, NSUInteger index, void **reflection) {
				if (![[(id<MTLFunction>)self device] isKindOfClass:[AkiosMaliDevice class]]) {
					return original(self, reflected, index, reflection);
				}
				if (reflection != NULL) *reflection = NULL;   /* no reflection here: the encoder is the whole answer */
				return (__bridge_retained void *)akm_function_argument_encoder(self, index);
			}));
		}
	});
}

#define AKIOS_MAX_VERTEX_ATTRIBUTES 31

/* A vertex descriptor that fetches nothing: nil, or one whose attributes are all MTLVertexFormatInvalid and whose layouts
 * all have stride 0 (what -[MTLVertexDescriptor init] gives). Metal hands the pipeline a copy of whatever the application
 * set, so "no vertex descriptor" arrives in either shape. Anything else names a vertex fetch ([[stage_in]] attributes
 * through VFD_DECODE/VFD_FETCH); the first such attribute is named, for the log line that says a pipeline fetches. */
static NSString *
akm_vertex_descriptor_fetch(MTLVertexDescriptor *vd)
{
	if (vd == nil) {
		return nil;
	}
	for (NSUInteger i = 0; i < AKIOS_MAX_VERTEX_ATTRIBUTES; i++) {
		MTLVertexAttributeDescriptor *a = [[vd attributes] objectAtIndexedSubscript:i];
		MTLVertexBufferLayoutDescriptor *l = [[vd layouts] objectAtIndexedSubscript:i];

		if (a != nil && [a format] != MTLVertexFormatInvalid) {
			return [NSString stringWithFormat:@"a vertex descriptor with attribute %lu (format %lu, offset %lu, buffer %lu)",
							  (unsigned long)i, (unsigned long)[a format], (unsigned long)[a offset], (unsigned long)[a bufferIndex]];
		}
		if (l != nil && [l stride] != 0) {
			return [NSString stringWithFormat:@"a vertex descriptor with layout %lu (stride %lu)", (unsigned long)i, (unsigned long)[l stride]];
		}
	}
	return nil;
}

/* The descriptor's attributes and layouts, Metal's numbers straight through (hakios_metal.h): every slot, described or
 * not, so that a pipeline state made from a reused descriptor carries no stale attribute. NO with the core's sentence. */
static BOOL
akm_set_vertex_descriptor(hakios_metal_program *program, MTLVertexDescriptor *vd)
{
	for (unsigned i = 0; i < AKIOS_MAX_VERTEX_ATTRIBUTES; i++) {
		MTLVertexAttributeDescriptor *a = vd != nil ? [[vd attributes] objectAtIndexedSubscript:i] : nil;
		MTLVertexBufferLayoutDescriptor *l = vd != nil ? [[vd layouts] objectAtIndexedSubscript:i] : nil;

		if (hakios_metal_program_set_vertex_attribute(program, i, a != nil ? (unsigned)[a format] : 0, a != nil ? (unsigned)[a offset] : 0,
							      a != nil ? (unsigned)[a bufferIndex] : 0) != 0 ||
		    hakios_metal_program_set_vertex_layout(program, i, l != nil ? (unsigned)[l stride] : 0,
							   l != nil ? (unsigned)[l stepFunction] : 1, l != nil ? (unsigned)[l stepRate] : 1) != 0) {
			return NO;
		}
	}
	return YES;
}

/*
 * Why a render pipeline descriptor cannot be served, or nil. Everything the base initialiser does not read is read here,
 * by name, BEFORE any compilation and before super is given the descriptor: the step-one contract (hakios_metal.h) is one
 * colour attachment of a served format, no depth, no stencil, one sample, no dual-source blend, and a vertex
 * plus a fragment function; a descriptor asking for more gets nil with the sentence that names the first thing it asked
 * for, rather than a pipeline that silently draws without it. Each check is one a client can trip on purpose (the test
 * program's blendingEnabled line is one of them).
 */
- (NSString *)akRenderPipelineWhy:(MTLRenderPipelineDescriptor *)d
{

	if (d == nil || ![d isKindOfClass:[MTLRenderPipelineDescriptor class]]) {
		return [NSString stringWithFormat:@"the descriptor is %s, not an MTLRenderPipelineDescriptor (Metal's own init would abort on it)",
						  d != nil ? class_getName(object_getClass(d)) : "nil"];
	}
	if ([d vertexFunction] == nil) {
		return @"the descriptor names no vertex function";
	}
	if ([[d vertexFunction] functionType] != MTLFunctionTypeVertex) {
		return [NSString stringWithFormat:@"the vertex function %@ is of type %lu, not a vertex function (1)", [[d vertexFunction] name],
						  (unsigned long)[[d vertexFunction] functionType]];
	}
	/* no fragment function is a depth-only pipeline: hakios-metal draws a built-in one that writes nothing */
	if ([d fragmentFunction] != nil && [[d fragmentFunction] functionType] != MTLFunctionTypeFragment) {
		return [NSString stringWithFormat:@"the fragment function %@ is of type %lu, not a fragment function (2)", [[d fragmentFunction] name],
						  (unsigned long)[[d fragmentFunction] functionType]];
	}
	/* colour attachment 0 may be Invalid: a pipeline drawing depth alone (a shadow map's), or one whose first target is a
	 * later index -- its [[color(0)]], if the function writes one, goes nowhere, as Metal discards it */
	/* Attachments past 0 are hakios-metal's to judge at the draw: one the fragment function writes ([[color(n)]]) is
	 * drawn into, its output's class against the attachment's format; one it does not write -- QuartzCore's
	 * downsample_4_frag_lph pass names a second target and writes colour 0 alone -- is left unwritten, as Metal leaves
	 * an output the function does not write. Their blends are handed over after the compile. */
	/* blending and the write mask are hakios-metal's (hakios_metal_program_set_blend after the compile), dual-source
	 * factors included: the draw takes a stage's [[color(0), index(1)]] as the second source */
	/* (11-24) Depth16Unorm too: hakios-metal's draw serves it (the Mali's D16, c_api_mali.cpp zsOf) -- the lock-screen
	 * poster (MercuryPoster's celosia shaders) draws with one, and its pipeline was refused here */
	if ([d depthAttachmentPixelFormat] != MTLPixelFormatInvalid && [d depthAttachmentPixelFormat] != MTLPixelFormatDepth32Float &&
	    [d depthAttachmentPixelFormat] != MTLPixelFormatDepth32Float_Stencil8 && [d depthAttachmentPixelFormat] != MTLPixelFormatDepth16Unorm) {
		return [NSString stringWithFormat:@"a depth attachment pixel format of %lu; Depth16Unorm (250), Depth32Float (252) and "
						  "Depth32Float_Stencil8 (260) are the depth formats served", (unsigned long)[d depthAttachmentPixelFormat]];
	}
	/* the stencil is the S8 plane of a Depth32Float_Stencil8 texture or a Stencil8 texture of its own (hakios-metal's
	 * zsOf takes both) */
	if ([d stencilAttachmentPixelFormat] != MTLPixelFormatInvalid && [d stencilAttachmentPixelFormat] != MTLPixelFormatDepth32Float_Stencil8 &&
	    [d stencilAttachmentPixelFormat] != MTLPixelFormatStencil8) {
		return [NSString stringWithFormat:@"a stencil attachment pixel format of %lu; Depth32Float_Stencil8 (260) is the stencil "
						  "format served", (unsigned long)[d stencilAttachmentPixelFormat]];
	}
	if ([d rasterSampleCount] != 1 && [d rasterSampleCount] != 2 && [d rasterSampleCount] != 4) {
		return [NSString stringWithFormat:@"rasterSampleCount %lu; 1, 2 and 4 samples are served", (unsigned long)[d rasterSampleCount]];
	}
	/* the vertex descriptor is not judged here: it is handed to hakios-metal after the compile (akm_set_vertex_descriptor),
	 * which knows which attributes the vertex function reads and refuses an unserved one at the draw, by name */
	if ([d isAlphaToCoverageEnabled] || [d isAlphaToOneEnabled]) {
		return @"alphaToCoverage or alphaToOne is enabled; neither is served (no MSAA, no blend state)";
	}
	if (![d isRasterizationEnabled]) {
		return @"rasterizationEnabled is NO; a pipeline that rasterizes nothing has nothing to draw here (no stream-out)";
	}
	if ([d inputPrimitiveTopology] != MTLPrimitiveTopologyClassUnspecified && [d inputPrimitiveTopology] != MTLPrimitiveTopologyClassTriangle) {
		return [NSString stringWithFormat:@"input primitive topology class %lu; triangles (3, or unspecified 0) are what step one draws",
						  (unsigned long)[d inputPrimitiveTopology]];
	}
	if ([d maxVertexAmplificationCount] > 1) {
		return [NSString stringWithFormat:@"maxVertexAmplificationCount %lu; profile 0 amplifies nothing (1)", (unsigned long)[d maxVertexAmplificationCount]];
	}
	if ([[[d vertexLinkedFunctions] functions] count] != 0 || [[[d vertexLinkedFunctions] binaryFunctions] count] != 0 ||
	    [[[d fragmentLinkedFunctions] functions] count] != 0 || [[[d fragmentLinkedFunctions] binaryFunctions] count] != 0) {
		return @"linked functions (dynamic linking, visible functions) are not served; each stage is one module compiled whole";
	}
	if ([[d vertexPreloadedLibraries] count] != 0 || [[d fragmentPreloadedLibraries] count] != 0) {
		return @"preloaded dynamic libraries are not served";
	}
	if ([d supportIndirectCommandBuffers]) {
		AK_ONCE("a render pipeline was asked to support indirect command buffers; the flag is kept by Metal's base class, and the "
			"encoder refuses -executeCommandsInBuffer: by name\n");
	}
	if ([[d binaryArchives] count] != 0) {
		AK_ONCE("a render pipeline descriptor carries %lu binary archives; none is consulted, the AIR is compiled here\n",
			(unsigned long)[[d binaryArchives] count]);
	}
	return nil;
}

/* What a function a pipeline is handed is made of, once per class: its class chain with each class's ivars, and the
 * public functionConstantsDictionary. Which of them carries the values a pipeline specialised the function with
 * (-[MTLLibrary newFunctionWithName:constantValues:error:]) is not known from the SDK, and the compiler here takes
 * every constant as unsupplied until it is: this is the reading that says where they are. */

/*
 * PIPELINES COMPILED IN THE BACKGROUND (boot-arg metal_defer=0: not): CoreAnimation builds its pipelines at start-up,
 * synchronously, and its first frame waits for all of them -- fixed_frag_lph_cpf, its uber shader for one effect, takes
 * some 15 s of the phone's processor for each of the pixel formats it is built for (the Pixel 8a, 11-08: no frame in
 * the first 80 s). Such a pipeline is answered at once with a stand-in (its draws skipped) and compiled on a thread of
 * low priority, by this same method with deferral off for that thread; its program is then moved into the stand-in,
 * which from then on draws.
 */
static __thread BOOL akm_no_defer;

static BOOL
akm_deferred(NSString *fragment)
{
	static int off = -1;

	if (off < 0) {
		char args[1024] = {0};
		size_t size = sizeof(args) - 1;
		off = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_defer=0") != NULL;
	}
	return !off && !akm_no_defer && fragment != nil && [fragment isEqualToString:@"fixed_frag_lph_cpf"];
}

static dispatch_queue_t
akm_compile_queue(void)
{
	static dispatch_queue_t q;
	static dispatch_once_t once;

	/* (USER_INITIATED since 11-11: what waits on it is on the screen -- CoreAnimation's generic pipelines, whose draws are
	 * skipped until they are in. At UTILITY a fresh boot's loads of them from the cache took 0.24-2.2 s each, growing as
	 * the boot got busier, from the RAM disk's seed as from the flash: the thread waited for the processors, not for
	 * the file) */
	dispatch_once(&once, ^{
		q = dispatch_queue_create("com.akios.metal.compile", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
		    QOS_CLASS_USER_INITIATED, 0));
	});
	return q;
}

/*
 * The one entry point every form below ends in. The order is: the descriptor's own rules (above), then the compiler
 * (hakios_metal_program_new_bitcode: AIR to NIR to ir3 for both stages, the link, the format against the fragment
 * output's class -- its refusals name the construct), then Metal's base initialiser with a descriptor already known to
 * pass its asserts. Nothing is asked of Metal's -compiler, which this device has not got.
 */
- (id)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor error:(NSError **)error
{
	SEL bitcode = sel_getUid("bitcodeData");
	NSString *why = [self akRenderPipelineWhy:descriptor];
	id vs, fs;
	NSData *vsAir, *fsAir;
	hakios_metal_program *program;
	unsigned format;

	if (why != nil) {
		return [self akRefuse:error what:"a render pipeline" why:why];
	}
	if (!hakios_metal_has_compiler()) {
		return [self akRefuse:error what:"a render pipeline" why:@"libhakios-metal was built without the compiler (make ios MESA=1)"];
	}
	vs = [descriptor vertexFunction];
	fs = [descriptor fragmentFunction];
	if (fs != nil && akm_deferred([fs name])) {
		AkiosMaliRenderPipelineState *later = [[AkiosMaliRenderPipelineState alloc] initWithAkiosDevice:self program:NULL
													  descriptor:descriptor];
		MTLRenderPipelineDescriptor *copy = [descriptor copy];
		NSString *name = [[NSString alloc] initWithFormat:@"%@ + %@", [vs name], [fs name]];

		if (later == nil) {
			return nil;
		}
		[later akSetStandIn:"compiling in the background"];
		dispatch_async(akm_compile_queue(), ^{
			NSError *e = nil;
			uint64_t t0 = mach_absolute_time();

			akm_no_defer = YES;
			AkiosMaliRenderPipelineState *real = [self newRenderPipelineStateWithDescriptor:copy error:&e];
			akm_no_defer = NO;
			if (real != nil && [real akStandIn] == NULL) {
				[later akSetProgram:[real akTakeProgram]];
				[later akAdoptSpecialisationOf:real];
				akios_say("compiled in the background: %s, in %llu ms\n", [name UTF8String], akm_ms_since(t0));
			} else {
				[later akSetStandIn:real != nil ? [real akStandIn] : "refused in the background"];
			}
		});
		return later;
	}
	if (![vs respondsToSelector:bitcode] || (fs != nil && ![fs respondsToSelector:bitcode])) {
		return [self akRefuse:error what:"a render pipeline"
				      why:@"a function does not answer bitcodeData, so its AIR cannot be read (not an _MTLFunction of this Metal?)"];
	}
	const uint64_t tBitcode = mach_absolute_time();
	vsAir = akm_bitcode_for(vs, [descriptor label], YES);
	fsAir = fs != nil ? akm_bitcode_for(fs, [descriptor label], NO) : nil;   /* nil: the built-in fragment function */
	const uint64_t tCore = mach_absolute_time();
	if (vsAir == nil || [vsAir length] == 0 || (fs != nil && (fsAir == nil || [fsAir length] == 0))) {
		return [self akRefuse:error what:"a render pipeline"
				      why:[NSString stringWithFormat:@"%@ or %@ has no bitcode", [vs name], [fs name]]];
	}
	format = (unsigned)[[[descriptor colorAttachments] objectAtIndexedSubscript:0] pixelFormat];
	{
		hakios_metal_constant vsConstants[64], fsConstants[64];
		unsigned vsCount = akios_function_constants(vs, vsConstants, 64), fsCount = akios_function_constants(fs, fsConstants, 64);

		program = hakios_metal_program_new_bitcode_constants([vsAir bytes], [vsAir length], vsConstants, vsCount, fsAir != nil ? [fsAir bytes] : NULL,
								     fsAir != nil ? [fsAir length] : 0,
								     fsConstants, fsCount, format);
		if (akm_ms_since(tBitcode) >= 300) {
			/* (a slow pipeline's time by step, 11-10: the uber pipelines took 1-3 s even with the core's cache found) */
			akios_say("pipeline %s + %s: %llu ms in all -- bitcode %llu, the core (compile or cache) %llu\n", [[vs name] UTF8String],
				 [[fs name] UTF8String], akm_ms_since(tBitcode), akm_ms_since(tBitcode) - akm_ms_since(tCore), akm_ms_since(tCore));
		}
		if (program != NULL) {
		}
		if (program == NULL) {
			/* the core's sentence, passed through: the stage and the construct it refused, or the format by name -- and the
			 * fragment function's constants, which decide what it is */
			NSMutableString *fc = [NSMutableString string];

			for (unsigned i = 0; i < fsCount; i++) {
				if (fsConstants[i].bits != 0) [fc appendFormat:@" %u=%llu", fsConstants[i].index, (unsigned long long)fsConstants[i].bits];
			}
			NSString *refusal = [NSString stringWithFormat:@"%@ + %@ for pixel format %u (fragment constants not 0:%@): %s", [vs name],
							       [fs name], format, fc, hakios_metal_error()];
			/*
			 * A STAND-IN, unless metal_strict: CoreAnimation ends its window server (OS_REASON_COREANIMATION, "Metal failed
			 * to build render pipeline") on the first pipeline it does not get, and launchd starts it again for the same
			 * end -- the Pixel 8a's backboardd did so every ten seconds. A state with no program instead, whose draws are
			 * refused one by one (and skipped, as every refused draw is outside metal_strict): what can be drawn is, and
			 * one boot names every pipeline that cannot.
			 */
			if (!akios_strict()) {
				AkiosMaliRenderPipelineState *standIn = [[AkiosMaliRenderPipelineState alloc] initWithAkiosDevice:self program:NULL
															    descriptor:descriptor];

				akios_say("refused: a render pipeline: %s -- a stand-in is given, its draws are skipped\n", [refusal UTF8String]);
				[standIn akSetStandIn:[refusal UTF8String]];
				return standIn;
			}
			return [self akRefuse:error what:"a render pipeline" why:refusal];
		}
	}
	hakios_metal_program_set_samples(program, (unsigned)[descriptor rasterSampleCount]);   /* 1, 2 or 4: judged above */
	if (!akm_set_vertex_descriptor(program, [descriptor vertexDescriptor])) {
		NSString *why2 = [NSString stringWithFormat:@"the vertex descriptor: %s", hakios_metal_error()];
		hakios_metal_program_free(program);
		return [self akRefuse:error what:"a render pipeline" why:why2];
	}
	{
		MTLRenderPipelineColorAttachmentDescriptor *c0 = [[descriptor colorAttachments] objectAtIndexedSubscript:0];

		hakios_metal_program_set_blend(program, [c0 isBlendingEnabled] ? 1 : 0, (unsigned)[c0 rgbBlendOperation], (unsigned)[c0 alphaBlendOperation],
					       (unsigned)[c0 sourceRGBBlendFactor], (unsigned)[c0 destinationRGBBlendFactor],
					       (unsigned)[c0 sourceAlphaBlendFactor], (unsigned)[c0 destinationAlphaBlendFactor], (unsigned)[c0 writeMask]);
		hakios_metal_program_set_attachment_format(program, 0, (unsigned)[c0 pixelFormat]);
		if (akios_boot_arg("metal_passsay=1") && strcmp(getprogname(), "backboardd") != 0) {
			akios_say("pipeline %p %s: blend %s ops %lu/%lu factors %lu %lu / %lu %lu, write mask %#lx, samples %lu, alpha to coverage %d, "
				 "depth format %lu stencil format %lu\n", (void *)program, hakios_metal_program_name(program),
				 [c0 isBlendingEnabled] ? "on" : "off", (unsigned long)[c0 rgbBlendOperation], (unsigned long)[c0 alphaBlendOperation],
				 (unsigned long)[c0 sourceRGBBlendFactor], (unsigned long)[c0 destinationRGBBlendFactor],
				 (unsigned long)[c0 sourceAlphaBlendFactor], (unsigned long)[c0 destinationAlphaBlendFactor],
				 (unsigned long)[c0 writeMask], (unsigned long)[descriptor rasterSampleCount], (int)[descriptor isAlphaToCoverageEnabled],
				 (unsigned long)[descriptor depthAttachmentPixelFormat], (unsigned long)[descriptor stencilAttachmentPixelFormat]);
		}
		for (unsigned i = 1; i < 8; i++) {
			MTLRenderPipelineColorAttachmentDescriptor *c = [[descriptor colorAttachments] objectAtIndexedSubscript:i];

			if (c == nil || [c pixelFormat] == MTLPixelFormatInvalid) {
				continue;
			}
			hakios_metal_program_set_blend_at(program, i, [c isBlendingEnabled] ? 1 : 0, (unsigned)[c rgbBlendOperation],
							  (unsigned)[c alphaBlendOperation], (unsigned)[c sourceRGBBlendFactor],
							  (unsigned)[c destinationRGBBlendFactor], (unsigned)[c sourceAlphaBlendFactor],
							  (unsigned)[c destinationAlphaBlendFactor], (unsigned)[c writeMask]);
			hakios_metal_program_set_attachment_format(program, i, (unsigned)[c pixelFormat]);
			if ([c pixelFormat] == MTLPixelFormatR32Float || [c pixelFormat] == MTLPixelFormatRG16Float ||
			    [c pixelFormat] == MTLPixelFormatR16Float) {
				static _Atomic unsigned akm_float_rt_said;
				if (akm_float_rt_said++ < 24)
				akios_say("a pipeline's (%s) colour attachment %u is MTLPixelFormat %lu: blending %s (operations %lu/%lu, factors %lu "
					"%lu / %lu %lu), write mask 0x%lx\n", [[descriptor label] UTF8String] ?: "no label", i, (unsigned long)[c pixelFormat],
					[c isBlendingEnabled] ? "on" : "off", (unsigned long)[c rgbBlendOperation],
					(unsigned long)[c alphaBlendOperation], (unsigned long)[c sourceRGBBlendFactor],
					(unsigned long)[c destinationRGBBlendFactor], (unsigned long)[c sourceAlphaBlendFactor],
					(unsigned long)[c destinationAlphaBlendFactor], (unsigned long)[c writeMask]);
			}
		}
	}
	if ([descriptor label] != nil) {
		hakios_metal_program_set_label(program, [[descriptor label] UTF8String]);  /* (diagnostics: metal_skipprog, metal_progsay) */
	}
	{
		NSString *fetches = akm_vertex_descriptor_fetch([descriptor vertexDescriptor]);

		if (fetches != nil) {
			akios_say("%s fetches through %s\n", hakios_metal_program_name(program), [fetches UTF8String]);
		}
		/* (metal_trace=1: the whole vertex descriptor, each kind once -- the aquarium's ground, 11-13) */
		MTLVertexDescriptor *vd = [descriptor vertexDescriptor];
		if (vd != nil) {
			char line[380];
			int at = 0;

			for (NSUInteger i = 0; i < 31 && at < (int)sizeof(line) - 40; i++) {
				MTLVertexAttributeDescriptor *a = [[vd attributes] objectAtIndexedSubscript:i];
				if (a != nil && [a format] != MTLVertexFormatInvalid) {
					at += snprintf(line + at, sizeof(line) - (size_t)at, " a%lu=f%lu@%lu/b%lu", (unsigned long)i, (unsigned long)[a format],
						       (unsigned long)[a offset], (unsigned long)[a bufferIndex]);
				}
			}
			for (NSUInteger i = 0; i < 31 && at < (int)sizeof(line) - 40; i++) {
				MTLVertexBufferLayoutDescriptor *l = [[vd layouts] objectAtIndexedSubscript:i];
				if (l != nil && [l stride] != 0) {
					at += snprintf(line + at, sizeof(line) - (size_t)at, " b%lu:stride %lu step %lu/%lu", (unsigned long)i,
						       (unsigned long)[l stride], (unsigned long)[l stepFunction], (unsigned long)[l stepRate]);
				}
			}
			line[at] = 0;
		}
	}
	{
		/* the fragment function's constants beside the line: one function (fixed_frag_lph_cph) is most of what
		 * CoreAnimation draws, and its constants are what tell one of its pipelines from another in a log */
		hakios_metal_constant fc[64];
		unsigned count = akios_function_constants([descriptor fragmentFunction], fc, 64);
		NSMutableString *set = [NSMutableString string];
		NSMutableString *zero = [NSMutableString string];

		for (unsigned i = 0; i < count; i++) {
			if (fc[i].bits != 0) [set appendFormat:@" %u=%llu", fc[i].index, (unsigned long long)fc[i].bits];
			else [zero appendFormat:@",%u", fc[i].index];
		}
		akm_note_constants(program, set);
		if (akm_tracing()) {
			/* the module this Metal hands over is the function already specialised (a few KB, not the library's
			 * 100), so its size and hash, not the library's, say which code a pipeline runs */
			NSData *air = akm_bitcode_for([descriptor fragmentFunction], [descriptor label], NO);
			uint32_t h = 2166136261u;
			const uint8_t *b = (const uint8_t *)[air bytes];

			for (NSUInteger i = 0; i < [air length]; i++) h = (h ^ b[i]) * 16777619u;
			akios_say("trace: %s (%p) defines %u constants; the zero ones%s; fragment bitcode %lu bytes, fnv %08x\n", hakios_metal_program_name(program),
				 (void *)program, count, [zero UTF8String], (unsigned long)[air length], h);
			/* boot-arg metal_dump=FNV (a diagnostic): that module's bytes into the log in hex, for the host's own
			 * front end and compiler to take apart. What it prints is the system's code: it stays in the log. */
			{
				char args[1024] = {0}, *at;
				size_t size = sizeof(args) - 1;

				if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && (at = strstr(args, "metal_dump=")) != NULL &&
				    (uint32_t)strtoul(at + 11, NULL, 16) == h) {
					for (NSUInteger o = 0; o < [air length]; o += 64) {
						char line[160];
						size_t n = 0;

						for (NSUInteger i = o; i < o + 64 && i < [air length]; i++) n += (size_t)snprintf(line + n, sizeof(line) - n, "%02x", b[i]);
						akios_say("dump %08x %06lx %s\n", h, (unsigned long)o, line);
					}
				}
			}
		}
		akios_say("linked %s (%p, pipeline %s) for pixel format %u: the vertex stage binds %u resources, the fragment stage %u; fragment constants not 0:%s\n",
			 hakios_metal_program_name(program), (void *)program, [descriptor label] ? [[descriptor label] UTF8String] : "none",
			 format, hakios_metal_program_resource_count(program, 0), hakios_metal_program_resource_count(program, 1), [set UTF8String]);
		if (akios_boot_arg("metal_fetchsay")) {
			/* (each stage's resources as the compile found them: kind, index, size) */
			for (unsigned stage = 0; stage < 2; stage++) {
				char line[700];
				int at = snprintf(line, sizeof(line), "resources of %s, %s stage:", hakios_metal_program_name(program), stage ? "fragment" : "vertex");
				for (unsigned r = 0; r < hakios_metal_program_resource_count(program, stage) && at < 660; r++) {
					unsigned kind = 0, index = 0, size = 0;
					if (hakios_metal_program_resource(program, stage, r, &kind, &index, &size) == 0) {
						at += snprintf(line + at, sizeof(line) - (size_t)at, " k%u[%u]:%u", kind, index, size);
					}
				}
				akios_say("%s\n", line);
			}
		}
	}
	{
		AkiosMaliRenderPipelineState *state = [[AkiosMaliRenderPipelineState alloc] initWithAkiosDevice:self program:program descriptor:descriptor];
		hakios_metal_constant fc[64];
		unsigned count = fs != nil ? akios_function_constants(fs, fc, 64) : 0;

		if (state != nil && fsAir != nil) [state akKeepFragment:fsAir constants:fc count:count];
		return state;
	}
}

/* reflection comes out of Metal's compiler, which this device has not got; nil, as for compute */
- (id)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options
				reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error
{
	(void)options;
	if (reflection != NULL) {
		*reflection = nil;
	}
	id state = [self newRenderPipelineStateWithDescriptor:descriptor error:error];
	if (reflection != NULL && state != nil && [state respondsToSelector:@selector(akProgram)]) {
		/* (11-20) made from the program's resources: Freeform asserts on a nil one (see AkiosMaliRenderReflection) */
		AkiosMaliRenderReflection *r = [[AkiosMaliRenderReflection alloc]
						  initWithProgram:((hakios_metal_program * (*)(id, SEL))objc_msgSend)(state, @selector(akProgram))];
		*reflection = (MTLAutoreleasedRenderPipelineReflection)r;
		AK_ONCE("a render pipeline's reflection asked for: made from the program's resources (names, kinds, indices, sizes; no "
			"struct members)\n");
	}
	return state;
}

/* The handler forms are answered synchronously, inside the call: Metal promises only that the handler runs, not when,
 * and the earlier plug-in measured the alternative -- a form left to the base class sends to a nil compiler, returns,
 * and the handler never runs; a client building its pipelines asynchronously then waits for ever, the one failure no
 * log shows. The state is released after the handler, which has retained it if it wants it. */
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor
			   completionHandler:(MTLNewRenderPipelineStateCompletionHandler)handler
{
	NSError *error = nil;
	id state = [self newRenderPipelineStateWithDescriptor:descriptor error:&error];

	if (handler != NULL) {
		handler(state, error);
	}
}

- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options
			   completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)handler
{
	NSError *error = nil;
	MTLAutoreleasedRenderPipelineReflection reflection = nil;
	id state = [self newRenderPipelineStateWithDescriptor:descriptor options:options reflection:&reflection error:&error];

	if (handler != NULL) {
		handler(state, reflection, error);
	}
}

/* The mesh and tile forms are _MTLDevice's own, and the mesh ones RE-ENTER the plain forms above on self with a render
 * descriptor derived from the mesh descriptor (the earlier plug-in read those four entry points): inherited, they would
 * hand a mesh pipeline to the vertex-plus-fragment builder and get something compiled rather than a refusal. Overridden
 * to refuse by name, every form, handlers called at once with the error. */
- (id)newRenderPipelineStateWithMeshDescriptor:(MTLMeshRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options
				    reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error
{
	(void)descriptor; (void)options;
	if (reflection != NULL) {
		*reflection = nil;
	}
	return [self akRefuse:error what:"a mesh render pipeline" why:@"mesh and object stages are not served; vertex + fragment pipelines are"];
}

- (id)newRenderPipelineStateWithMeshDescriptor:(MTLMeshRenderPipelineDescriptor *)descriptor error:(NSError **)error
{
	return [self newRenderPipelineStateWithMeshDescriptor:descriptor options:0 reflection:NULL error:error];
}

- (void)newRenderPipelineStateWithMeshDescriptor:(MTLMeshRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options
			       completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)handler
{
	NSError *error = nil;
	id state = [self newRenderPipelineStateWithMeshDescriptor:descriptor options:options reflection:NULL error:&error];

	if (handler != NULL) {
		handler(state, nil, error);
	}
}

- (void)newRenderPipelineStateWithMeshDescriptor:(MTLMeshRenderPipelineDescriptor *)descriptor
			       completionHandler:(MTLNewRenderPipelineStateCompletionHandler)handler
{
	NSError *error = nil;
	id state = [self newRenderPipelineStateWithMeshDescriptor:descriptor options:0 reflection:NULL error:&error];

	if (handler != NULL) {
		handler(state, error);
	}
}

- (id)newRenderPipelineStateWithTileDescriptor:(MTLTileRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options
				    reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error
{
	(void)descriptor; (void)options;
	if (reflection != NULL) {
		*reflection = nil;
	}
	return [self akRefuse:error what:"a tile render pipeline"
			      why:@"tile shaders and imageblocks are Apple-GPU tile memory; this GPU draws straight to memory (sysmem) and has none"];
}

- (id)newRenderPipelineStateWithTileDescriptor:(MTLTileRenderPipelineDescriptor *)descriptor error:(NSError **)error
{
	return [self newRenderPipelineStateWithTileDescriptor:descriptor options:0 reflection:NULL error:error];
}

- (void)newRenderPipelineStateWithTileDescriptor:(MTLTileRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options
			       completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)handler
{
	NSError *error = nil;
	id state = [self newRenderPipelineStateWithTileDescriptor:descriptor options:options reflection:NULL error:&error];

	if (handler != NULL) {
		handler(state, nil, error);
	}
}

- (void)newRenderPipelineStateWithTileDescriptor:(MTLTileRenderPipelineDescriptor *)descriptor
			       completionHandler:(MTLNewRenderPipelineStateCompletionHandler)handler
{
	NSError *error = nil;
	id state = [self newRenderPipelineStateWithTileDescriptor:descriptor options:0 reflection:NULL error:&error];

	if (handler != NULL) {
		handler(state, error);
	}
}


@end

@implementation AkiosMaliDepthStencilState

- (instancetype)initWithDevice:(id<MTLDevice>)device descriptor:(MTLDepthStencilDescriptor *)descriptor
{
	self = [super init];
	if (self == nil) {
		return nil;
	}
	_device = device;
	_label = [[descriptor label] copy];
	_compare = (unsigned)[descriptor depthCompareFunction];
	_write = [descriptor isDepthWriteEnabled];
	/* a face Metal leaves nil is its default, Always / Keep / Keep / Keep with all-ones masks; the test is on only when
	 * some face can change a pixel's fate or the stencil, so that a state with the default faces costs no stencil
	 * registers and binds on a pass with no stencil attachment as Metal lets it */
	{
		MTLStencilDescriptor *faces[2] = { [descriptor frontFaceStencil], [descriptor backFaceStencil] };
		struct hakios_metal_stencil_face *out[2] = { &_front, &_back };

		for (int i = 0; i < 2; i++) {
			MTLStencilDescriptor *f = faces[i];
			struct hakios_metal_stencil_face *o = out[i];

			o->compare = f != nil ? (unsigned)[f stencilCompareFunction] : (unsigned)MTLCompareFunctionAlways;
			o->stencil_fail = f != nil ? (unsigned)[f stencilFailureOperation] : (unsigned)MTLStencilOperationKeep;
			o->depth_fail = f != nil ? (unsigned)[f depthFailureOperation] : (unsigned)MTLStencilOperationKeep;
			o->pass = f != nil ? (unsigned)[f depthStencilPassOperation] : (unsigned)MTLStencilOperationKeep;
			o->read_mask = f != nil ? (unsigned)[f readMask] & 0xff : 0xff;
			o->write_mask = f != nil ? (unsigned)[f writeMask] & 0xff : 0xff;
			if (o->compare != (unsigned)MTLCompareFunctionAlways || o->stencil_fail != (unsigned)MTLStencilOperationKeep ||
			    o->depth_fail != (unsigned)MTLStencilOperationKeep || o->pass != (unsigned)MTLStencilOperationKeep) {
				_stencil = YES;
			}
		}
	}
	return self;
}


- (NSString *)label { return _label; }
- (id<MTLDevice>)device { return _device; }
- (MTLResourceID)gpuResourceID { MTLResourceID r = { 0 }; return r; }   /* argument buffers are not served */
- (unsigned)akDepthCompare { return _compare; }
- (BOOL)akDepthWrite { return _write; }
- (BOOL)akStencil { return _stencil; }
- (const struct hakios_metal_stencil_face *)akStencilFront { return &_front; }
- (const struct hakios_metal_stencil_face *)akStencilBack { return &_back; }

@end

@implementation AkiosMaliDevice (DepthStencilAndArguments)

- (id)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)descriptor
{
	if (descriptor == nil || ![descriptor isKindOfClass:[MTLDepthStencilDescriptor class]]) {
		akios_say("refused: a depth/stencil state with no MTLDepthStencilDescriptor\n");
		return nil;
	}
	return [[AkiosMaliDepthStencilState alloc] initWithDevice:(id<MTLDevice>)self descriptor:descriptor];
}

/* MTLArgumentDescriptor members, in the layout the front end reads back (AkiosMaliArgumentEncoder) */
- (id)newArgumentEncoderWithArguments:(NSArray *)arguments
{
	return [[AkiosMaliArgumentEncoder alloc] initWithDevice:self arguments:arguments];
}

/* What a heap has to hold a texture or a buffer made from it: the core's plan of the texture, the same one creation
 * allocates by, so a heap sized from these (MPS sizes its temporary-texture heaps so) has room for what it is then asked
 * to make; AkiosMaliHeap counts each resource's allocatedSize, which is the same number. 4 KiB alignment: every
 * layout here starts on a page. */


@end

/* ============================================================================================================
 * CoreAnimation's library stand-ins (the earlier plug-in's hm_library_stand_ins)
 * ============================================================================================================ */

/*
 * Functions CoreAnimation asks its library for that the library it is given (ca_metallib=, QuartzCore-default.metallib)
 * has not got under that name, or has in a form this CoreAnimation does not bind: each answered with the nearest
 * function it has. luma_boost (a picture's luminance raised) by inplace_copy, the picture as it is; edr_scale (always:
 * the library's reads buffers 5 and 7 and texture 9, which CoreAnimation binds for neither) by inplace_copy too. A
 * function the library has, and is not marked "always", is never touched; libraries of other devices are left alone.
 */
static const char *const akm_stand_ins[][3] = {
	/* asked for, given instead, "always" when the library's own is the wrong one (not just missing) */
	{ "luma_boost_lph", "inplace_copy_lph", "" },
	{ "luma_boost_lpf", "inplace_copy_lpf", "" },
	{ "edr_scale_lph", "inplace_copy_lph", "always" },
	{ "edr_scale_lpf", "inplace_copy_lpf", "always" },
};

/* (both selectors are of Metal's new family: their objects come back +1, handled as raw pointers so that ARC neither
 * retains nor autoreleases them) */
static void *(*akm_orig_fn_name)(id, SEL, NSString *);
static void *(*akm_orig_fn_constants)(id, SEL, NSString *, MTLFunctionConstantValues *, NSError *__autoreleasing *);

static NSString *
akm_stand_in(id library, NSString *name, BOOL found)
{
	if (name == nil || ![library respondsToSelector:@selector(device)] || ![[library device] isKindOfClass:[AkiosMaliDevice class]]) {
		return nil;
	}
	for (size_t i = 0; i < sizeof(akm_stand_ins) / sizeof(akm_stand_ins[0]); i++) {
		if (strcmp(name.UTF8String, akm_stand_ins[i][0]) == 0 && (!found || akm_stand_ins[i][2][0] != 0)) {
			return @(akm_stand_ins[i][1]);
		}
	}
	return nil;
}

static void *
akm_fn_name(id self, SEL sel, NSString *name)
{
	void *f = akm_orig_fn_name(self, sel, name);
	NSString *other = akm_stand_in(self, name, f != NULL);

	if (other != nil) {
		if (f != NULL) CFRelease(f);
		f = akm_orig_fn_name(self, sel, other);
		if (f != NULL) {
			AK_ONCE("the library has no usable %s: %s stands in for it\n", name.UTF8String, other.UTF8String);
		}
	}
	return f;
}

static void *
akm_fn_constants(id self, SEL sel, NSString *name, MTLFunctionConstantValues *values, NSError *__autoreleasing *error)
{
	void *f = akm_orig_fn_constants(self, sel, name, values, error);
	NSString *other = akm_stand_in(self, name, f != NULL);

	if (other != nil) {
		if (f != NULL) CFRelease(f);
		f = akm_orig_fn_constants(self, sel, other, values, error);
		if (f != NULL) {
			if (error != NULL) *error = nil;
			AK_ONCE("the library has no usable %s: %s stands in for it (with constants)\n", name.UTF8String, other.UTF8String);
		}
	}
	return f;
}

void
akm_library_stand_ins(void)
{
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		Class library = NSClassFromString(@"_MTLLibrary");
		Method a = library ? class_getInstanceMethod(library, @selector(newFunctionWithName:)) : NULL;
		Method b = library ? class_getInstanceMethod(library, @selector(newFunctionWithName:constantValues:error:)) : NULL;

		if (a != NULL) {
			akm_orig_fn_name = (void *(*)(id, SEL, NSString *))method_setImplementation(a, (IMP)akm_fn_name);
		}
		if (b != NULL) {
			akm_orig_fn_constants = (void *(*)(id, SEL, NSString *, MTLFunctionConstantValues *, NSError *__autoreleasing *))
			    method_setImplementation(b, (IMP)akm_fn_constants);
		}
	});
}
