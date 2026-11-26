/*
 * AkiosMetalRender.m: render passes, render and parallel render encoders, render pipeline states -- the earlier
 * plug-in's render path (HakiosMetalCA.m: hm_read_render_pass, HakiosMetalRenderPipelineState,
 * HakiosMetalRenderCommandEncoder, HakiosMetalParallelRenderCommandEncoder), carried over to ARC and onto IOGPU's
 * IOGPUMetalRenderCommandEncoder / IOGPUMetalParallelRenderCommandEncoder (plan 1.8). Each draw is the core's
 * (hakios_metal_cb_draw3 / _draw_indexed / _clear) into the command buffer's core, built at commit like the rest.
 * Gone with the move: the shadow and turned framebuffers, mirrors, the frame statistics and samplers of the old file.
 */
#import "AkiosMetal.h"
#include <objc/message.h>
#include <pthread.h>
#include <sys/sysctl.h>

static void
akm_adopt(Class cls, Protocol *protocol, const char *name)
{
	(void)name;
	if (protocol != NULL && !class_conformsToProtocol(cls, protocol)) {
		class_addProtocol(cls, protocol);
	}
}





@interface AkiosMaliParallelRenderEncoder : IOGPUMetalParallelRenderCommandEncoder {
	__unsafe_unretained AkiosMaliCommandBuffer *_akCommandBuffer;   /* the base class retains it until -endEncoding */
	struct hakios_metal_render_pass _pass;
	AkiosMaliTexture *_colorTexture;
	MTLRenderPassDescriptor *_descriptor;       /* copied: its resolves are read at -endEncoding */
	NSMutableArray *_subs;                      /* NSValue (pointer) of each sub-encoder's hakios_metal_cb, in creation order */
	NSLock *_lock;
}
- (instancetype)initWithAkiosCommandBuffer:(AkiosMaliCommandBuffer *)commandBuffer pass:(const struct hakios_metal_render_pass *)pass
			       colorTexture:(AkiosMaliTexture *)texture descriptor:(MTLRenderPassDescriptor *)descriptor;
@end

@interface AkiosMaliRenderEncoder : IOGPUMetalRenderCommandEncoder {
	__unsafe_unretained AkiosMaliCommandBuffer *_akCommandBuffer;   /* the base class retains it until -endEncoding */
	hakios_metal_cb *_sub;                      /* a parallel encoder's sub-encoder: its own core command buffer, which
	                                             * the parallel encoder appends in creation order; NULL otherwise */
	AkiosMaliTexture *_colorTexture;          /* colour attachment 0, retained until the encoder goes */
	AkiosMaliTexture *_resolveFrom[8], *_resolveTo[8];   /* each colour attachment's samples and its resolveTexture, retained */
	unsigned _resolveLevel[8];
	BOOL _resolving[8];                         /* the store action resolves (2, 3, or Unknown with a resolveTexture): at -endEncoding */
	struct hakios_metal_render_pass _pass;      /* its hakios texture, load and store actions, clear colour */
	AkiosMaliRenderPipelineState *_pipeline;
	struct hakios_metal_viewport _viewport;
	struct hakios_metal_scissor _scissor;
	BOOL _hasViewport, _hasScissor;             /* unset: hakios-metal takes the whole attachment (NULL) */
	id _indirectArgs;                           /* the next draw is indirect: its words at _indirectOffset of this buffer */
	NSUInteger _indirectOffset;
	AkiosMaliBuffer *_vsBuffers[AKIOS_MAX_BUFFERS];
	AkiosMaliBuffer *_fsBuffers[AKIOS_MAX_BUFFERS];
	uint64_t _vsOffsets[AKIOS_MAX_BUFFERS], _fsOffsets[AKIOS_MAX_BUFFERS];
	unsigned _vsHighest, _fsHighest;            /* one past the highest index bound, per stage */
	AkiosMaliTexture *_fsTextures[AKIOS_MAX_TEXTURES];         /* the fragment stage's [[texture(n)]], retained */
	AkiosMaliSamplerState *_fsSamplers[AKIOS_MAX_SAMPLERS];    /* ... and [[sampler(n)]] */
	unsigned _fsHighestTexture, _fsHighestSampler;
	AkiosMaliTexture *_vsTextures[AKIOS_MAX_TEXTURES];         /* the vertex stage's, the same way */
	AkiosMaliSamplerState *_vsSamplers[AKIOS_MAX_SAMPLERS];
	unsigned _vsHighestTexture, _vsHighestSampler;
	NSMutableArray *_scratch;                   /* the buffers -setVertexBytes:/-setFragmentBytes: made */
	AkiosMaliBuffer *_arena;                  /* ... the one they are filling (one of _scratch's) */
	NSUInteger _arenaUsed, _arenaSize;
	MTLWinding _frontFacingWinding;             /* -setFrontFacingWinding:'s, also in _pass.winding for the draws */
	char _refused[160];                         /* a binding or state this encoder could not take: the next draw is failed by it */
	NSMutableIndexSet *_visibilityCounted;      /* the result words (offset / 8) a draw of this encoder has counted into */
}
- (instancetype)initWithAkiosCommandBuffer:(AkiosMaliCommandBuffer *)commandBuffer pass:(const struct hakios_metal_render_pass *)pass
			       colorTexture:(AkiosMaliTexture *)texture;
- (instancetype)initWithAkiosCommandBuffer:(AkiosMaliCommandBuffer *)commandBuffer pass:(const struct hakios_metal_render_pass *)pass
			       colorTexture:(AkiosMaliTexture *)texture sub:(hakios_metal_cb *)sub;
- (void)akTakeResolves:(MTLRenderPassDescriptor *)descriptor;
@end

/*
 * The pass descriptor, read in full and once: colour attachment 0 (texture, load action, store action, clear colour)
 * becomes hakios-metal's render pass, and everything else the descriptor can carry is either harmless here or refused by
 * name. Metal reads none of it on this road (IOGPUMetalRenderCommandEncoder's init drops the descriptor), and the one
 * place Metal does look is -[MTLRenderPassColorAttachmentDescriptorInternal setTexture:], which asserts conformance to
 * MTLTextureImplementation -- declared by AkiosMaliTexture at +load for exactly this. NO: *why says what, and the pass
 * is not begun.
 */
/* A colour attachment's store action as the core takes it, and its resolve. MultisampleResolve (2) and
 * StoreAndMultisampleResolve (3) both store the samples (the resolve reads them); Unknown (4) is a Store until
 * -setColorStoreAction: decides. The resolve itself is a copy of the samples into RESOLVE at the end of the pass
 * (-endEncoding, hakios_metal_cb_blit reading SAMPLES a pixel): a texture of one sample, the attachment's size. */
static BOOL
akm_store_of(MTLRenderPassColorAttachmentDescriptor *c, NSUInteger i, unsigned *store, char *why, size_t size)
{
	MTLStoreAction a = [c storeAction];
	id<MTLTexture> r = [c resolveTexture], t = [c texture];
	BOOL resolves = a == MTLStoreActionMultisampleResolve || a == MTLStoreActionStoreAndMultisampleResolve;

	if (r != nil || resolves) {
		if (r == nil || ![r isKindOfClass:[AkiosMaliTexture class]] || [r sampleCount] != 1 || [t sampleCount] < 2 ||
		    [c resolveSlice] != 0 || [c resolveDepthPlane] != 0 || [r width] != [t width] || [r height] != [t height]) {
			snprintf(why, size, "colour attachment %lu asks for a resolve (store action %lu) %s; a multisample attachment resolved into a "
				 "texture of this device of one sample, its size, one slice, is what is served", (unsigned long)i, (unsigned long)a,
				 r == nil ? "with no resolveTexture" : "of an attachment or into a texture that does not fit");
			return NO;
		}
	}
	/* (a resolve reads the samples from memory at -endEncoding: they are stored for it, MultisampleResolve too -- with
	 * DontCare the resolve read what the texture held before) */
	*store = resolves || a == MTLStoreActionUnknown ? (unsigned)MTLStoreActionStore : (unsigned)a;
	return YES;
}

static BOOL
akm_read_render_pass(MTLRenderPassDescriptor *d, struct hakios_metal_render_pass *pass, AkiosMaliTexture **texture, char *why, size_t size)
{
	MTLRenderPassColorAttachmentDescriptor *c0;
	id t0, depth, stencil;
	MTLClearColor clear;

	memset(pass, 0, sizeof(*pass));
	*texture = nil;
	if (d == nil || ![d isKindOfClass:[MTLRenderPassDescriptor class]]) {
		snprintf(why, size, "the pass descriptor is %s, not an MTLRenderPassDescriptor", d != nil ? class_getName(object_getClass(d)) : "nil");
		return NO;
	}
	c0 = [[d colorAttachments] objectAtIndexedSubscript:0];
	t0 = c0 != nil ? [c0 texture] : nil;   /* nil: a pass of depth alone, or one whose first target is a later index */
	/* the targets past 0, read as attachment 0 is (hakios-metal draws into the ones the function writes and clears the
	 * ones that ask for a Clear; the ones it does not write it leaves as they are) */
	for (NSUInteger i = 1; i < 8; i++) {
		MTLRenderPassColorAttachmentDescriptor *c = [[d colorAttachments] objectAtIndexedSubscript:i];
		id t = c != nil ? [c texture] : nil;

		if (t == nil) {
			continue;
		}
		if (![t isKindOfClass:[AkiosMaliTexture class]] || ([t usage] & MTLTextureUsageRenderTarget) == 0) {
			snprintf(why, size, "colour attachment %lu is a %s%s", (unsigned long)i, class_getName(object_getClass(t)),
				 [t isKindOfClass:[AkiosMaliTexture class]] ? " made without MTLTextureUsageRenderTarget" : ", not a texture of this device");
			return NO;
		}
		/* (a 2D array's layer or a cube's face is its slice, a 3D texture's plane its depth plane: hakios-metal draws
		 * into that one, and refuses one past the texture's) */
		{
			MTLClearColor cc = [c clearColor];
			struct hakios_metal_color_attachment *m = &pass->more[i - 1];
			unsigned store;

			if (!akm_store_of(c, i, &store, why, size)) {
				return NO;
			}
			m->texture = [(AkiosMaliTexture *)t akCore];
			m->level = (unsigned)[c level];
			m->slice = (unsigned)([t textureType] == MTLTextureType3D ? [c depthPlane] : [c slice]);
			m->load_action = (unsigned)[c loadAction];
			m->store_action = store;
			m->clear_color[0] = cc.red;
			m->clear_color[1] = cc.green;
			m->clear_color[2] = cc.blue;
			m->clear_color[3] = cc.alpha;
		}
	}
	if (t0 != nil && ![t0 isKindOfClass:[AkiosMaliTexture class]]) {
		snprintf(why, size, "the texture of colour attachment 0 is a %s, not a texture of this device", class_getName(object_getClass(t0)));
		return NO;
	}
	if (t0 != nil && ([t0 usage] & MTLTextureUsageRenderTarget) == 0) {
		snprintf(why, size, "the texture of colour attachment 0 was made with usage %#lx, without MTLTextureUsageRenderTarget (4); a "
			 "draw into it is refused", (unsigned long)[t0 usage]);
		return NO;
	}
	/* (colour attachment 0's slice or depth plane as the others', below) */
	if (t0 != nil && !akm_store_of(c0, 0, &pass->store_action, why, size)) {
		return NO;
	}
	if ([c0 storeAction] == MTLStoreActionCustomSampleDepthStore) {
		snprintf(why, size, "colour attachment 0 has store action CustomSampleDepthStore (5), a depth store action, on a colour attachment");
		return NO;
	}
	if ([c0 storeActionOptions] != MTLStoreActionOptionNone) {
		AK_ONCE("a colour attachment carries store action options %#lx (custom sample positions); one sample here, nothing to position\n",
			(unsigned long)[c0 storeActionOptions]);
	}
	depth = [[d depthAttachment] texture];
	stencil = [[d stencilAttachment] texture];
	if (stencil != nil && stencil != depth) {
		snprintf(why, size, "a stencil attachment (%s) that is not the depth attachment's texture; the stencil served is the S8 "
			 "plane of the one Depth32Float_Stencil8 texture both name", class_getName(object_getClass(stencil)));
		return NO;
	}
	if (depth != nil && ![depth isKindOfClass:[AkiosMaliTexture class]]) {
		snprintf(why, size, "the depth attachment is a %s, not a texture of this device", class_getName(object_getClass(depth)));
		return NO;
	}
	if ([d visibilityResultBuffer] != nil) {
		/* occlusion queries: each draw's -setVisibilityResultMode:offset: counts into it (hakios-metal's draw) */
		if (![[d visibilityResultBuffer] isKindOfClass:[AkiosMaliBuffer class]]) {
			snprintf(why, size, "the visibility result buffer is a %s, not a buffer of this device",
				 class_getName(object_getClass([d visibilityResultBuffer])));
			return NO;
		}
		pass->visibility = [(AkiosMaliBuffer *)[d visibilityResultBuffer] akCore];
	}
	/* layered rendering: the core's (hakios_metal.h, layers): 2 to 8 layers of one array or cube colour attachment */
	if ([d renderTargetArrayLength] > 8) {
		snprintf(why, size, "renderTargetArrayLength %lu (layered rendering); up to 8 layers are served", (unsigned long)[d renderTargetArrayLength]);
		return NO;
	}
	pass->layers = (unsigned)[d renderTargetArrayLength];
	if ([d defaultRasterSampleCount] > 1) {
		snprintf(why, size, "defaultRasterSampleCount %lu; one sample is served", (unsigned long)[d defaultRasterSampleCount]);
		return NO;
	}
	if ([d rasterizationRateMap] != nil) {
		snprintf(why, size, "a rasterization rate map is set (variable rate shading); not served");
		return NO;
	}
	if ([d imageblockSampleLength] != 0 || [d threadgroupMemoryLength] != 0 || [d tileWidth] != 0 || [d tileHeight] != 0) {
		AK_ONCE("a render pass asks for tile shading state (imageblock %lu bytes, threadgroup memory %lu, tile %lux%lu); this GPU has no "
			"tile memory and no tile pipeline can be made, so the numbers decide nothing\n", (unsigned long)[d imageblockSampleLength],
			(unsigned long)[d threadgroupMemoryLength], (unsigned long)[d tileWidth], (unsigned long)[d tileHeight]);
	}
	/* Unknown (4) is Metal's "decided later by -setColorStoreAction:"; until then it is a store, which is what sysmem does
	 * anyway: the RB writes the memory as it draws, there is no tile to store from */
	if (t0 == nil && depth == nil && pass->more[0].texture == NULL && pass->more[1].texture == NULL && pass->more[2].texture == NULL &&
	    pass->more[3].texture == NULL && pass->more[4].texture == NULL && pass->more[5].texture == NULL && pass->more[6].texture == NULL) {
		snprintf(why, size, "the pass has no attachment at all (no colour texture, no depth); nothing to draw into");
		return NO;
	}
	pass->color0 = t0 != nil ? [(AkiosMaliTexture *)t0 akCore] : NULL;
	pass->color0_level = (unsigned)[c0 level];   /* the core refuses a level past the texture's, with the numbers */
	pass->color0_slice = t0 != nil ? (unsigned)([t0 textureType] == MTLTextureType3D ? [c0 depthPlane] : [c0 slice]) : 0;
	/* (with no texture at 0 its actions say nothing; a Load spends no Clear on an attachment that is not there) */
	pass->load_action = t0 != nil ? (unsigned)[c0 loadAction] : (unsigned)MTLLoadActionLoad;
	/* (pass->store_action is akm_store_of's, read above with the resolve) */
	clear = [c0 clearColor];
	pass->clear_color[0] = clear.red;
	pass->clear_color[1] = clear.green;
	pass->clear_color[2] = clear.blue;
	pass->clear_color[3] = clear.alpha;
	if (depth != nil) {
		/* the depth attachment: Metal's actions passed through (Unknown, 4, is a store until -setDepthStoreAction: says
		 * otherwise, as for colour), the clear depth read only for a Clear; hakios-metal judges the format and size */
		MTLRenderPassDepthAttachmentDescriptor *da = [d depthAttachment];

		pass->depth = [(AkiosMaliTexture *)depth akCore];
		pass->depth_level = (unsigned)[da level];   /* the core refuses one past the texture's */
		pass->depth_slice = (unsigned)[da slice];   /* a depth 2D array's layer (a shadow cascade); the core refuses one past them */
		pass->depth_load_action = (unsigned)[da loadAction];
		pass->depth_store_action = [da storeAction] == MTLStoreActionUnknown ? (unsigned)MTLStoreActionStore : (unsigned)[da storeAction];
		pass->clear_depth = [da clearDepth];
	}
	if (stencil != nil) {
		MTLRenderPassStencilAttachmentDescriptor *sa = [d stencilAttachment];

		pass->stencil = [(AkiosMaliTexture *)stencil akCore];
		pass->stencil_load_action = (unsigned)[sa loadAction];
		pass->stencil_store_action = [sa storeAction] == MTLStoreActionUnknown ? (unsigned)MTLStoreActionStore : (unsigned)[sa storeAction];
		pass->clear_stencil = [sa clearStencil] & 0xff;
	}
	*texture = t0;
	return YES;
}

/* whether a pass still owes a Clear -- of any colour attachment or of the depth -- and its Clears spent (made Loads) once
 * a draw or the pass's own clear has recorded them: one fill per attachment and pass, however many draws follow */
static BOOL
akm_owes_clear(const struct hakios_metal_render_pass *pass)
{
	if (pass->load_action == (unsigned)MTLLoadActionClear || (pass->depth != NULL && pass->depth_load_action == (unsigned)MTLLoadActionClear) ||
	    (pass->stencil != NULL && pass->stencil_load_action == (unsigned)MTLLoadActionClear)) {
		return YES;
	}
	for (int i = 0; i < 7; i++) {
		if (pass->more[i].texture != NULL && pass->more[i].load_action == (unsigned)MTLLoadActionClear) {
			return YES;
		}
	}
	return NO;
}

static void
akm_spend_clears(struct hakios_metal_render_pass *pass)
{
	pass->load_action = (unsigned)MTLLoadActionLoad;
	pass->depth_load_action = (unsigned)MTLLoadActionLoad;
	pass->stencil_load_action = (unsigned)MTLLoadActionLoad;
	for (int i = 0; i < 7; i++) {
		pass->more[i].load_action = (unsigned)MTLLoadActionLoad;
	}
}

/* A surface drawn into through a copy of its rows (-akShadow:): the copy as the surface is now, for a Load, and
 * what the pass drew back into the surface once the command buffer is done -- as for a kernel's writes */

@implementation AkiosMaliRenderPipelineState

/* the base declares the public protocol itself; declared again so that a conformsToProtocol: is a static yes whatever
 * this Metal's adoption list says, as the sampler does */
+ (void)load
{
	akm_adopt(self, @protocol(MTLRenderPipelineState), "MTLRenderPipelineState");
}




- (instancetype)initWithAkiosDevice:(AkiosMaliDevice *)device program:(hakios_metal_program *)program
			  descriptor:(MTLRenderPipelineDescriptor *)descriptor
{
	/* the designated initialiser, given a descriptor -newRenderPipelineStateWithDescriptor:error: has already checked
	 * (non-nil, the right class, no tessellation-with-ICB): it keeps the label (copied) and the device, reads
	 * supportIndirectCommandBuffers, textureWriteRoundingMode and meshFunction (nil here), and answers <MTLRenderPipelineState> from them */
	self = [super initWithDevice:device pipelineStateDescriptor:descriptor];
	if (self == nil) {
		hakios_metal_program_free(program);
		return nil;
	}
	_akDevice = device;
	_program = program;
	_akUniqueIdentifier = akios_next_id();
	_specBinding = -1;          /* (none until akKeepFragment: an ivar's 0 named buffer 0 -- a background compile's
				     *  state asked to specialise with no bitcode and no bytes at every draw, 11-11) */
	return self;
}

- (void)dealloc
{
	for (id v in [_specialised objectEnumerator]) {
		if ([v isKindOfClass:[NSValue class]]) hakios_metal_program_free((hakios_metal_program *)[v pointerValue]);
	}
	if (_program != NULL) {
		hakios_metal_program_free(_program);   /* a draw in flight keeps its own reference */
	}
}

- (hakios_metal_program *)akProgram { return _program; }
- (void)akSetStandIn:(const char *)why { snprintf(_standIn, sizeof(_standIn), "%s", why != NULL && *why ? why : "refused"); }
- (const char *)akStandIn { return __atomic_load_n(&_standIn[0], __ATOMIC_ACQUIRE) != '\0' ? _standIn : NULL; }
- (void)akSetProgram:(hakios_metal_program *)program
{
	_program = program;
	__atomic_store_n(&_standIn[0], '\0', __ATOMIC_RELEASE);  /* (the program first: a draw that sees no stand-in sees it) */
}
- (hakios_metal_program *)akTakeProgram
{
	hakios_metal_program *p = _program;
	_program = NULL;
	return p;
}

/* THE BACKGROUND COMPILE'S KEPT FRAGMENT (11-11): CoreAnimation's generic pipelines (fixed_frag_lph_cpf) are the ones
 * compiled in the background (akm_deferred), and their stand-in never kept the fragment function -- so no uber shader
 * was ever specialised, and the widgets drew with the whole of it. After the program (a draw that sees the binding
 * sees the program too). */
- (void)akAdoptSpecialisationOf:(AkiosMaliRenderPipelineState *)real
{
	if (real == nil || real->_specBinding < 0 || real->_fsAir == nil || _fsAir != nil) return;
	_fsAir = real->_fsAir;
	memcpy(_fsConstants, real->_fsConstants, sizeof(_fsConstants));
	_fsConstantCount = real->_fsConstantCount;
	_specLength = real->_specLength;
	memcpy(_specMask, real->_specMask, sizeof(_specMask));
	_specMasked = real->_specMasked;
	_specialised = [[NSMutableDictionary alloc] init];
	__atomic_store_n(&_specBinding, real->_specBinding, __ATOMIC_RELEASE);
	[self akWarm];          /* (11-26: a deferred one's contents seen before; nothing for the rest) */
}

/* boot-arg metal_nospec: every draw with the pipeline's own program, no uber shader specialised */
static BOOL
akm_spec_off(void)
{
	static int off = -1;

	if (off < 0) {
		char args[1024] = {0};
		size_t size = sizeof(args) - 1;

		off = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_nospec") != NULL;
	}
	return off != 0;
}

/* An uber shader -- a fragment stage of thousands of instructions that reads a small constant buffer -- takes its path
 * through them by that buffer's bytes in every fragment: CoreAnimation's fixed_frag_lph_cpf is 15 000 instructions and
 * one of its draws took 9.6 ms over 1.2 million pixels with its textures' reads gone or not, when the path its
 * configuration takes is 16 to 48 instructions. Such a pipeline keeps its fragment function so that a program can be
 * compiled for each content of the buffer (hakios_metal_program_specialize). */
- (void)akKeepFragment:(NSData *)air constants:(const hakios_metal_constant *)constants count:(unsigned)count
{
	const unsigned words = hakios_metal_program_stage_words(_program, 1);
	/* (11-26) 0 words: the core did not compile the fragment stage whole (too big: iOS 27's generic fixed_frag_lph_cpf,
	 * VfxXgh + A3Xghfc / A2Xghfc, decided by its 52-byte config_buffer) -- only its specialisations draw, so they are
	 * asked for whatever metal_nospec says */
	const BOOL deferred = _program != NULL && words == 0;

	_specBinding = -1;
	if (!deferred && (akm_spec_off() || words < 4096)) return;
	for (unsigned i = 0; i < hakios_metal_program_resource_count(_program, 1); i++) {
		unsigned kind, index, size;

		if (hakios_metal_program_resource(_program, 1, i, &kind, &index, &size) == 0 && kind == HAKIOS_METAL_RESOURCE_CONSTANT_BUFFER &&
		    size != 0 && size <= 256 && (_specBinding < 0 || (unsigned)index < (unsigned)_specBinding)) {
			_specBinding = (int)index;
			_specLength = size;
		}
	}
	if (_specBinding < 0) return;
	_fsAir = air;
	_fsConstantCount = count < 64 ? count : 64;
	memcpy(_fsConstants, constants, _fsConstantCount * sizeof(*constants));
	_specMasked = deferred ? hakios_metal_program_control_mask(_program, (unsigned)_specBinding, _specMask) : 0;
	_specialised = [[NSMutableDictionary alloc] init];
	if (deferred) [self akWarm];
}

static dispatch_queue_t
akm_spec_queue(void)
{
	static dispatch_queue_t q;
	static dispatch_once_t once;

	dispatch_once(&once, ^{
		q = dispatch_queue_create("akios.metal.specialise", DISPATCH_QUEUE_SERIAL);
	});
	return q;
}

/* A specialisation's entry in _specialised: NSNull while it is asked for and not made, an NSValue (the program) once
 * made, the string @"failed" when it could not be made (not an NSNumber: that is an NSValue too). On akm_spec_queue only (one compile at a time, in the order asked). */
- (void)akSpecialiseKey:(NSData *)key why:(const char *)why
{
	@synchronized(self) {
		if (![[_specialised objectForKey:key] isKindOfClass:[NSNull class]]) return;   /* made, failed, or not asked */
	}
	struct timespec t0, t1;

	clock_gettime(CLOCK_MONOTONIC, &t0);
	hakios_metal_program *p = hakios_metal_program_specialize(_program, [_fsAir bytes], [_fsAir length], _fsConstants, _fsConstantCount,
								 (unsigned)_specBinding, [key bytes], [key length]);
	clock_gettime(CLOCK_MONOTONIC, &t1);
	const double ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
	static int said;
	if (p == NULL) {
		akios_say("specialise: %s for its buffer %d: %s; %s\n", hakios_metal_program_name(_program), _specBinding,
			 hakios_metal_error(), hakios_metal_program_stage_words(_program, 1) == 0 ? "its draws with these bytes are skipped" :
			 "its own program goes on");
	} else if (said < 24 || ms >= 100) {
		/* (11-26: every slow one said, past the first 24 too -- a compile, not the cache) */
		akios_say("specialise: %s for %u bytes of its buffer %d: %u instruction words, not %u, in %.0f ms (%s)\n", hakios_metal_program_name(_program),
			 (unsigned)[key length], _specBinding, hakios_metal_program_stage_words(p, 1), hakios_metal_program_stage_words(_program, 1), ms, why);
	}
	if (p == NULL || said++ < 24) {
		/* (11-11: the bytes, for tools/mesa/pan/mali_stage_host's BINDING:HEX) */
		char hex[2 * 256 + 1] = "";
		const uint8_t *kb = (const uint8_t *)[key bytes];
		for (unsigned i = 0; i < [key length] && i < 256; i++) {
			snprintf(hex + 2 * i, 3, "%02x", kb[i]);
		}
		akios_say("specialise: %s, buffer %d holds %s\n", [[(id)self label] UTF8String] ?: "?", _specBinding, hex);
	}
	@synchronized(self) {
		[_specialised setObject:(p != NULL ? (id)[NSValue valueWithPointer:p] : (id)@"failed") forKey:key];
	}
}

/* (11-26) THE CONTENTS SEEN BEFORE, LOADED AHEAD: a deferred pipeline (akKeepFragment) draws only with programs made for
 * its buffer's contents. The core keeps every content a program was made for beside its cache
 * (hakios_metal_program_seen_contents), and those programs are in that cache: they are asked for now, in the
 * background, so that a draw finds them made instead of waiting for the cache's read. */
- (void)akWarm
{
	enum { EACH = 256, MOST = 256 };

	if (_specBinding < 0 || _program == NULL || hakios_metal_program_stage_words(_program, 1) != 0) return;
	uint8_t *seen = malloc((size_t)EACH * MOST);
	unsigned lengths[MOST];
	if (seen == NULL) return;
	unsigned n = hakios_metal_program_seen_contents(_program, (unsigned)_specBinding, seen, EACH, lengths, MOST);
	NSMutableArray *keys = [NSMutableArray array];
	@synchronized(self) {
		for (unsigned i = 0; i < n; i++) {
			NSData *key = [NSData dataWithBytes:seen + (size_t)i * EACH length:lengths[i]];
			if ([_specialised objectForKey:key] == nil && [_specialised count] < 256) {
				[_specialised setObject:[NSNull null] forKey:key];
				[keys addObject:key];
			}
		}
	}
	free(seen);
	if ([keys count] == 0) return;
	dispatch_async(akm_spec_queue(), ^{
		struct timespec t0, t1;

		clock_gettime(CLOCK_MONOTONIC, &t0);
		for (NSData *key in keys) [self akSpecialiseKey:key why:"seen on an earlier boot"];
		clock_gettime(CLOCK_MONOTONIC, &t1);
		akios_say("specialise: %s: %lu contents of its buffer %d seen before, loaded ahead in %.0f ms\n", hakios_metal_program_name(_program),
			 (unsigned long)[keys count], _specBinding, (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
	});
}

/* the program for a draw whose fragment buffers are BUFFERS: the one compiled for what the deciding buffer holds, or
 * the pipeline's own while that one compiles (on a queue of its own: a compilation is 0.4 s on the host, and a frame
 * must not wait for it). 64 contents at most a pipeline; past them the pipeline's own.
 * (11-26) A DEFERRED PIPELINE (akKeepFragment: its own fragment stage was not compiled) has nothing of its own to draw
 * with, and a skipped draw is not drawn again -- CoreAnimation repaints only what changed, so Setup kept blank and
 * half-old regions. So its draw WAITS for its content's program: made on the same queue, this thread waiting for it
 * (0.4-1 s on the phone the first time a content is seen; from the cache, or loaded ahead by akWarm, after that).
 * NULL only when none can be made (said) or past 256 contents; a buffer shorter than the declared size is taken as
 * it is (the front end leaves a load past it a load). */
- (hakios_metal_program *)akProgramFor:(hakios_metal_buffer *const *)buffers offsets:(const uint64_t *)offsets count:(unsigned)count
{
	const BOOL deferred = _program != NULL && hakios_metal_program_stage_words(_program, 1) == 0;
	hakios_metal_program *own = deferred ? NULL : _program;

	if (__atomic_load_n(&_specBinding, __ATOMIC_ACQUIRE) < 0 || (unsigned)_specBinding >= count || buffers[_specBinding] == NULL ||
	    _program == NULL) return own;
	const uint8_t *bytes = (const uint8_t *)hakios_metal_buffer_contents(buffers[_specBinding]);
	const uint64_t length = hakios_metal_buffer_length(buffers[_specBinding]), at = offsets[_specBinding];
	uint64_t take = _specLength;
	if (bytes == NULL || at >= length) return own;
	if (length - at < take) {
		if (!deferred) return own;
		take = length - at;
	}
	NSData *key;
	if (_specMasked) {
		/* (11-26) only the bytes that decide its control flow tell its programs apart: the rest zero, as the core
		 * keys and folds them (its program reads them from the buffer) -- a float or a colour in it no longer
		 * makes a new program */
		uint8_t masked[256];
		for (uint64_t i = 0; i < take; i++) {
			masked[i] = i < 256 && (_specMask[i / 8] & (1u << (i % 8))) ? bytes[at + i] : 0;
		}
		key = [NSData dataWithBytes:masked length:(NSUInteger)take];
	} else {
		key = [NSData dataWithBytes:bytes + at length:(NSUInteger)take];
	}
	hakios_metal_program *found = own;
	BOOL start = NO, wait = NO, full = NO;

	@synchronized(self) {
		id have = [_specialised objectForKey:key];

		if ([have isKindOfClass:[NSValue class]]) {
			found = (hakios_metal_program *)[have pointerValue];
		} else if (have == nil && [_specialised count] < (deferred ? 256u : 64u)) {
			[_specialised setObject:[NSNull null] forKey:key];
			start = YES;
		} else if (have == nil) {
			full = deferred;
		}
		wait = deferred && (start || [have isKindOfClass:[NSNull class]]);
	}
	if (full) {
		static int told;
		if (told++ == 0) {
			akios_say("specialise: %s has 256 contents of its buffer %d made; draws with another are skipped\n",
				 hakios_metal_program_name(_program), _specBinding);
		}
	}
	if (wait) {
		/* behind what the queue has already (a compile asked for earlier, contents loaded ahead), then this one */
		dispatch_sync(akm_spec_queue(), ^{
			[self akSpecialiseKey:key why:"a draw waited for it"];
		});
		@synchronized(self) {
			id have = [_specialised objectForKey:key];
			found = [have isKindOfClass:[NSValue class]] ? (hakios_metal_program *)[have pointerValue] : NULL;
		}
	} else if (start) {
		dispatch_async(akm_spec_queue(), ^{
			[self akSpecialiseKey:key why:"in the background"];
		});
	}
	return found;
}

/* The base's uniqueIdentifier is a nil-stub and its gpuResourceID is the resourceIndex ivar (0): a pipeline would be
 * told apart from every other by nothing. Answered from the textures' counter, for the same reason (never 0, never an
 * address). Matters only to argument buffers and indirect command buffers, neither of which is here. */
- (uint64_t)uniqueIdentifier { return _akUniqueIdentifier; }

- (MTLResourceID)gpuResourceID
{
	MTLResourceID rid = { _akUniqueIdentifier };

	return rid;
}

@end

@implementation AkiosMaliRenderEncoder

/* The public protocol is defined only in the AGX bundle on this phone (as MTLComputeCommandEncoder is); the @protocol()
 * reference compiles it into this image, and the catch-all finds every member's encoding through it. */
+ (void)load
{
	akm_adopt(self, @protocol(MTLRenderCommandEncoder), "MTLRenderCommandEncoder");
}




- (instancetype)initWithAkiosCommandBuffer:(AkiosMaliCommandBuffer *)commandBuffer pass:(const struct hakios_metal_render_pass *)pass
			       colorTexture:(AkiosMaliTexture *)texture
{
	return [self initWithAkiosCommandBuffer:commandBuffer pass:pass colorTexture:texture sub:NULL];
}

/* where this encoder's work is recorded: the command buffer's, or a sub-encoder's own */
- (hakios_metal_cb *)akCb
{
	return _sub != NULL ? _sub : [_akCommandBuffer akCore];
}

- (instancetype)initWithAkiosCommandBuffer:(AkiosMaliCommandBuffer *)commandBuffer pass:(const struct hakios_metal_render_pass *)pass
			       colorTexture:(AkiosMaliTexture *)texture sub:(hakios_metal_cb *)sub
{
	/* (IOGPU's initialiser keeps nothing of the descriptor; it retains the buffer, -endEncoding gives it back) */
	self = [super initWithCommandBuffer:commandBuffer descriptor:nil];
	if (self == nil) {
		return nil;
	}
	_akCommandBuffer = commandBuffer;
	_sub = sub;
	_colorTexture = texture;
	_pass = *pass;
	_frontFacingWinding = MTLWindingClockwise;   /* Metal's default */
	return self;
}

- (void)akTakeResolves:(MTLRenderPassDescriptor *)descriptor
{
	for (NSUInteger i = 0; i < 8; i++) {
		MTLRenderPassColorAttachmentDescriptor *c = [[descriptor colorAttachments] objectAtIndexedSubscript:i];
		MTLStoreAction a = [c storeAction];

		if (c == nil || [c texture] == nil || [c resolveTexture] == nil) {
			continue;
		}
		_resolveFrom[i] = (AkiosMaliTexture *)[c texture];
		_resolveTo[i] = (AkiosMaliTexture *)[c resolveTexture];
		_resolveLevel[i] = (unsigned)[c resolveLevel];
		_resolving[i] = a == MTLStoreActionMultisampleResolve || a == MTLStoreActionStoreAndMultisampleResolve || a == MTLStoreActionUnknown;
	}
}

- (id)device { return [_akCommandBuffer device]; }

/* --- the pipeline --- */

- (void)setRenderPipelineState:(id)state
{
	if (state != nil && ![state isKindOfClass:[AkiosMaliRenderPipelineState class]]) {
		static int told;
		char what[160];
		snprintf(what, sizeof(what), "refused: a render pipeline state %p of class %s is not this device's:", (__bridge void *)state,
			 class_getName(object_getClass(state)));
		if (told++ < 4) akios_say("%s\n", what);
		snprintf(_refused, sizeof(_refused), "the render pipeline state is not this device's");
		return;
	}
	_pipeline = state;
}

/* --- viewport and scissor: stored, handed to the draw; unset means the whole attachment (znear 0, zfar 1) --- */

- (void)setViewport:(MTLViewport)viewport
{
	_viewport.x = viewport.originX;
	_viewport.y = viewport.originY;
	_viewport.width = viewport.width;
	_viewport.height = viewport.height;
	_viewport.znear = viewport.znear;
	_viewport.zfar = viewport.zfar;
	_hasViewport = YES;
}

- (void)setViewports:(const MTLViewport *)viewports count:(NSUInteger)count
{
	if (count != 1 || viewports == NULL) {
		akios_say("refused: %lu viewports; one viewport is served (no viewport arrays, no layer/viewport index output); the next draw is failed\n",
			 (unsigned long)count);
		snprintf(_refused, sizeof(_refused), "%lu viewports were set; one is served", (unsigned long)count);
		return;
	}
	[self setViewport:viewports[0]];
}

- (void)setScissorRect:(MTLScissorRect)rect
{
	_scissor.x = (unsigned)rect.x;
	_scissor.y = (unsigned)rect.y;
	_scissor.width = (unsigned)rect.width;
	_scissor.height = (unsigned)rect.height;
	_hasScissor = YES;
}

- (void)setScissorRects:(const MTLScissorRect *)rects count:(NSUInteger)count
{
	if (count != 1 || rects == NULL) {
		akios_say("refused: %lu scissor rectangles; one is served; the next draw is failed\n", (unsigned long)count);
		snprintf(_refused, sizeof(_refused), "%lu scissor rectangles were set; one is served", (unsigned long)count);
		return;
	}
	[self setScissorRect:rects[0]];
}

/* --- the buffer tables, one per stage, stored by index as the compute encoder stores its own --- */

/* a buffer of this device at INDEX of TABLE, or the reason it cannot be; nil unbinds */
- (void)akBind:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index stage:(const char *)stage
	     table:(__strong AkiosMaliBuffer **)table offsets:(uint64_t *)offsets highest:(unsigned *)highest
{
	if (index >= AKIOS_MAX_BUFFERS) {
		akios_say("refused: %s buffer index %lu is past Metal's table of %d\n", stage, (unsigned long)index, AKIOS_MAX_BUFFERS);
		snprintf(_refused, sizeof(_refused), "a %s buffer index past %d", stage, AKIOS_MAX_BUFFERS);
		return;
	}
	if (buffer != nil && ![buffer isKindOfClass:[AkiosMaliBuffer class]]) {
		akios_say("refused: the %s buffer at index %lu is a %s, not a buffer of this device\n", stage, (unsigned long)index,
			 class_getName(object_getClass(buffer)));
		snprintf(_refused, sizeof(_refused), "the %s buffer at index %lu is not this device's", stage, (unsigned long)index);
		return;
	}
	table[index] = buffer;
	offsets[index] = offset;
	if (buffer != nil && index + 1 > *highest) {
		*highest = (unsigned)index + 1;
	}
}

- (void)setVertexBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	[self akBind:buffer offset:offset atIndex:index stage:"vertex" table:_vsBuffers offsets:_vsOffsets highest:&_vsHighest];
}

- (void)setFragmentBuffer:(id)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	[self akBind:buffer offset:offset atIndex:index stage:"fragment" table:_fsBuffers offsets:_fsOffsets highest:&_fsHighest];
}

/* Metal's rule: this moves a buffer already bound at the index, so with nothing bound there is nothing to move */
- (void)setVertexBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	if (index < AKIOS_MAX_BUFFERS && _vsBuffers[index] != nil) {
		_vsOffsets[index] = offset;
	}
}

- (void)setFragmentBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index
{
	if (index < AKIOS_MAX_BUFFERS && _fsBuffers[index] != nil) {
		_fsOffsets[index] = offset;
	}
}

- (void)setVertexBuffers:(const id *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setVertexBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
	}
}

- (void)setFragmentBuffers:(const id *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setFragmentBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
	}
}

/* Metal's shorthand for small constant data: a buffer here, because that is what a stage's binding is. The scratch buffer
 * is the encoder's until -endEncoding; hakios-metal keeps it alive past that until the GPU is done with it.
 * ONE BUFFER FOR MANY OF THEM (11-13): each -set...Bytes: made a buffer of its own -- the kernel's driver asked for
 * memory, a mapping made, and all of it undone when the frame was drawn -- and WebKit's WebGL (ANGLE) sets a draw's
 * constants this way: the aquarium's 615 draws a frame made some 1200 buffers a frame, a fifth of its GPU process's
 * time in the kernel for them and a quarter in giving them back (metal_sample=1000). Now the bytes go one after
 * another into a 64 KiB buffer (each at a multiple of 64 bytes), bound at their offset; what is over 16 KiB still
 * gets its own. (11-15: by then seven tenths of that process's time were those kernel calls and the aquarium ran at
 * 14-18 frames a second; with this, 48.) */
#define AKM_ARENA_SIZE   65536u
#define AKM_ARENA_MOST   16384u
- (AkiosMaliBuffer *)akScratch:(const void *)bytes length:(NSUInteger)length stage:(const char *)stage index:(NSUInteger)index
			      offset:(NSUInteger *)offset
{
	AkiosMaliBuffer *buffer;

	*offset = 0;
	/* (ON since 11-15; metal_arena=0: a buffer for each, as before. Its first run, 11-13, left the window server
	 * spinning from Safari's launch on -- not seen again: the home screen, MetalTest and the aquarium ran with it,
	 * the window server at its idle 10 % afterwards) */
	static int shared = -1;

	if (shared < 0) {
		shared = akios_boot_arg("metal_arena=0") ? 0 : 1;
	}
	if (shared && bytes != NULL && length != 0 && length <= AKM_ARENA_MOST) {
		void *to;

		if (_arena == nil || _arenaUsed + length > _arenaSize) {
			_arena = [[self device] newBufferWithLength:AKM_ARENA_SIZE options:0];
			if (_arena != nil) {
				if (_scratch == nil) {
					_scratch = [[NSMutableArray alloc] init];
				}
				[_scratch addObject:_arena];
				       /* (the array's now, with the others) */
				_arenaUsed = 0;
				_arenaSize = AKM_ARENA_SIZE;
			}
		}
		if (_arena != nil && (to = [_arena contents]) != NULL) {
			memcpy((uint8_t *)to + _arenaUsed, bytes, length);
			*offset = _arenaUsed;
			_arenaUsed = (_arenaUsed + length + 63) & ~(NSUInteger)63;
			return _arena;
		}
	}
	buffer = [[self device] newBufferWithBytes:bytes length:length options:0];
	if (buffer == nil) {
		snprintf(_refused, sizeof(_refused), "no scratch buffer for %lu %s bytes at index %lu", (unsigned long)length, stage, (unsigned long)index);
		return nil;
	}
	if (_scratch == nil) {
		_scratch = [[NSMutableArray alloc] init];
	}
	[_scratch addObject:buffer];
	return buffer;
}

- (void)setVertexBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
	NSUInteger offset = 0;

	AkiosMaliBuffer *buffer = [self akScratch:bytes length:length stage:"vertex" index:index offset:&offset];

	if (buffer != nil) {
		[self setVertexBuffer:buffer offset:offset atIndex:index];
	}
}

- (void)setFragmentBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index
{
	NSUInteger offset = 0;

	AkiosMaliBuffer *buffer = [self akScratch:bytes length:length stage:"fragment" index:index offset:&offset];

	if (buffer != nil) {
		[self setFragmentBuffer:buffer offset:offset atIndex:index];
	}
}

/* --- textures and samplers in a render stage: the fragment stage's go to the draw calls (SB6_FS_TEX, the prefetch), the
 * vertex stage's to hakios_metal_cb_set_vertex_textures before each draw (SB6_VS_TEX); one path for both --- */
- (void)akSetTexture:(id)texture atIndex:(NSUInteger)index vertex:(BOOL)vertex
{
	const char *stage = vertex ? "vertex" : "fragment";
	if (index >= AKIOS_MAX_TEXTURES) {
		akios_say("refused: %s texture index %lu is past Metal's table of %d\n", stage, (unsigned long)index, AKIOS_MAX_TEXTURES);
		snprintf(_refused, sizeof(_refused), "a %s texture index past %d", stage, AKIOS_MAX_TEXTURES);
		return;
	}
	if (texture != nil && ![texture isKindOfClass:[AkiosMaliTexture class]]) {
		akios_say("refused: the %s texture at index %lu is a %s, not a texture of this device\n", stage, (unsigned long)index,
			 class_getName(object_getClass(texture)));
		snprintf(_refused, sizeof(_refused), "the %s texture at index %lu is not this device's", stage, (unsigned long)index);
		return;
	}
	__strong AkiosMaliTexture **table = vertex ? _vsTextures : _fsTextures;
	unsigned *highest = vertex ? &_vsHighestTexture : &_fsHighestTexture;
	table[index] = texture;
	if (texture != nil && index + 1 > *highest) {
		*highest = (unsigned)index + 1;
	}
}
- (void)akSetSampler:(id)sampler atIndex:(NSUInteger)index vertex:(BOOL)vertex
{
	const char *stage = vertex ? "vertex" : "fragment";
	if (index >= AKIOS_MAX_SAMPLERS) {
		akios_say("refused: %s sampler index %lu is past Metal's table of %d\n", stage, (unsigned long)index, AKIOS_MAX_SAMPLERS);
		snprintf(_refused, sizeof(_refused), "a %s sampler index past %d", stage, AKIOS_MAX_SAMPLERS);
		return;
	}
	if (sampler != nil && ![sampler isKindOfClass:[AkiosMaliSamplerState class]]) {
		akios_say("refused: the %s sampler at index %lu is a %s, not a sampler state of this device\n", stage, (unsigned long)index,
			 class_getName(object_getClass(sampler)));
		snprintf(_refused, sizeof(_refused), "the %s sampler at index %lu is not this device's", stage, (unsigned long)index);
		return;
	}
	__strong AkiosMaliSamplerState **table = vertex ? _vsSamplers : _fsSamplers;
	unsigned *highest = vertex ? &_vsHighestSampler : &_fsHighestSampler;
	table[index] = sampler;
	if (sampler != nil && index + 1 > *highest) {
		*highest = (unsigned)index + 1;
	}
}
- (void)setVertexTexture:(id)texture atIndex:(NSUInteger)index           { [self akSetTexture:texture atIndex:index vertex:YES]; }
- (void)setFragmentTexture:(id)texture atIndex:(NSUInteger)index         { [self akSetTexture:texture atIndex:index vertex:NO]; }
- (void)setVertexSamplerState:(id)sampler atIndex:(NSUInteger)index      { [self akSetSampler:sampler atIndex:index vertex:YES]; }
- (void)setFragmentSamplerState:(id)sampler atIndex:(NSUInteger)index    { [self akSetSampler:sampler atIndex:index vertex:NO]; }

- (void)setVertexSamplerState:(id)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index
{
	(void)lodMinClamp; (void)lodMaxClamp;
	[self setVertexSamplerState:sampler atIndex:index];
}

- (void)setFragmentSamplerState:(id)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index
{
	(void)lodMinClamp; (void)lodMaxClamp;
	[self setFragmentSamplerState:sampler atIndex:index];
}

- (void)setVertexTextures:(const id *)textures withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setVertexTexture:textures[i] atIndex:range.location + i];
	}
}

- (void)setFragmentTextures:(const id *)textures withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setFragmentTexture:textures[i] atIndex:range.location + i];
	}
}

- (void)setVertexSamplerStates:(const id *)samplers withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setVertexSamplerState:samplers[i] atIndex:range.location + i];
	}
}

- (void)setFragmentSamplerStates:(const id *)samplers withRange:(NSRange)range
{
	for (NSUInteger i = 0; i < range.length; i++) {
		[self setFragmentSamplerState:samplers[i] atIndex:range.location + i];
	}
}

- (void)setVertexSamplerStates:(const id *)samplers lodMinClamps:(const float *)lodMinClamps lodMaxClamps:(const float *)lodMaxClamps withRange:(NSRange)range
{
	(void)lodMinClamps; (void)lodMaxClamps;
	[self setVertexSamplerStates:samplers withRange:range];
}

- (void)setFragmentSamplerStates:(const id *)samplers lodMinClamps:(const float *)lodMinClamps lodMaxClamps:(const float *)lodMaxClamps withRange:(NSRange)range
{
	(void)lodMinClamps; (void)lodMaxClamps;
	[self setFragmentSamplerStates:samplers withRange:range];
}

/* The SPI that binds a texture and its sampler in one message (QuartzCore's image passes send it): the two public
 * setters, each with its own index, as the selector's words say */
- (void)setFragmentTexture:(id)texture atTextureIndex:(NSUInteger)textureIndex samplerState:(id)sampler atSamplerIndex:(NSUInteger)samplerIndex
{
	[self setFragmentTexture:texture atIndex:textureIndex];
	[self setFragmentSamplerState:sampler atIndex:samplerIndex];
}

- (void)setVertexTexture:(id)texture atTextureIndex:(NSUInteger)textureIndex samplerState:(id)sampler atSamplerIndex:(NSUInteger)samplerIndex
{
	[self setVertexTexture:texture atIndex:textureIndex];
	[self setVertexSamplerState:sampler atIndex:samplerIndex];
}

/* --- rasterizer state: what step one fixes, said once when asked to change --- */

/* Culling and the front face: the pass struct's CULL_MODE and WINDING, which every draw after reads (hakios-metal's
 * GRAS_SU_CNTL; which winding FRONT_CW is was measured on the phone, probe 9cu) */
- (void)setCullMode:(MTLCullMode)cullMode
{
	_pass.cull_mode = (unsigned)cullMode;
}

- (void)setFrontFacingWinding:(MTLWinding)winding
{
	_frontFacingWinding = winding;
	_pass.winding = (unsigned)winding;
}

- (void)setTriangleFillMode:(MTLTriangleFillMode)fillMode
{
	if (fillMode != MTLTriangleFillModeFill) {
		akios_say("refused: triangle fill mode %lu (1 lines); VPC/PC_POLYGON_MODE are fixed at triangles in step one; the next draw is failed\n",
			 (unsigned long)fillMode);
		snprintf(_refused, sizeof(_refused), "triangle fill mode %lu is not served", (unsigned long)fillMode);
	}
}

/* Clip is Metal's default and what GRAS_CL_CNTL has (near and far clip enabled); clamping is a bit nothing sets yet */
- (void)setDepthClipMode:(MTLDepthClipMode)mode
{
	if (mode != MTLDepthClipModeClip) {
		AK_ONCE("depth clip mode %lu (clamp) was set; step one clips, and without a depth attachment the difference is not visible\n",
			(unsigned long)mode);
	}
}

/* The depth test each later draw runs (nil: Metal's default, no test). A foreign object fails the next draw by name;
 * a test with no depth attachment is hakios-metal's refusal at the draw. */
- (void)setDepthStencilState:(id)state
{
	if (state == nil) {
		_pass.depth_state_set = 0;
		_pass.stencil_state_set = 0;
		return;
	}
	if (![state isKindOfClass:[AkiosMaliDepthStencilState class]]) {
		akios_say("refused: a depth/stencil state that is a %s, not one of this device's; the next draw is failed\n", class_getName(object_getClass(state)));
		snprintf(_refused, sizeof(_refused), "a depth/stencil state that is not this device's was bound");
		return;
	}
	_pass.depth_state_set = 1;
	_pass.depth_compare = [(AkiosMaliDepthStencilState *)state akDepthCompare];
	_pass.depth_write = [(AkiosMaliDepthStencilState *)state akDepthWrite] ? 1 : 0;
	/* Metal ignores the stencil half on a pass with no stencil attachment; so does this, rather than fail the draw */
	_pass.stencil_state_set = [(AkiosMaliDepthStencilState *)state akStencil] && _pass.stencil != NULL;
	_pass.stencil_front = *[(AkiosMaliDepthStencilState *)state akStencilFront];
	_pass.stencil_back = *[(AkiosMaliDepthStencilState *)state akStencilBack];
}

/* the blend colour is the encoder's state each later draw reads (the BlendColor / BlendAlpha factors) */
- (void)setBlendColorRed:(float)red green:(float)green blue:(float)blue alpha:(float)alpha
{
	_pass.blend_color[0] = red;
	_pass.blend_color[1] = green;
	_pass.blend_color[2] = blue;
	_pass.blend_color[3] = alpha;
}

/* inert given the fixed state, each said once: there is no depth and no stencil, so a depth bias or a stencil reference
 * changes nothing a draw here could show */

- (void)setDepthBias:(float)depthBias slopeScale:(float)slopeScale clamp:(float)clamp
{
	if (depthBias != 0.0f || slopeScale != 0.0f || clamp != 0.0f) {
		AK_ONCE("a depth bias (%g, slope %g, clamp %g) was set; there is no depth attachment, so it is not applied\n",
			(double)depthBias, (double)slopeScale, (double)clamp);
	}
}

/* the references each later draw compares against (Metal's are 32 bits; the plane is 8, and the test reads the low 8) */
- (void)setStencilReferenceValue:(uint32_t)value
{
	_pass.stencil_front_reference = value & 0xff;
	_pass.stencil_back_reference = value & 0xff;
}

- (void)setStencilFrontReferenceValue:(uint32_t)front backReferenceValue:(uint32_t)back
{
	_pass.stencil_front_reference = front & 0xff;
	_pass.stencil_back_reference = back & 0xff;
}

/* the draws after this count into the pass's visibility result buffer at OFFSET (hakios-metal checks the mode, the
 * buffer and the offset at each draw, and refuses by name) */
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset
{
	_pass.visibility_mode = (unsigned)mode;
	_pass.visibility_offset = offset;
}

- (void)setVertexAmplificationCount:(NSUInteger)count viewMappings:(const MTLVertexAmplificationViewMapping *)mappings
{
	(void)mappings;
	if (count > 1) {
		akios_say("refused: vertex amplification count %lu; profile 0 amplifies nothing; the next draw is failed\n", (unsigned long)count);
		snprintf(_refused, sizeof(_refused), "vertex amplification count %lu is not served", (unsigned long)count);
	}
}

/* --- store actions set during the pass (Metal allows them when the descriptor said Unknown) --- */

- (void)setColorStoreAction:(MTLStoreAction)action atIndex:(NSUInteger)index
{
	BOOL resolves = action == MTLStoreActionMultisampleResolve || action == MTLStoreActionStoreAndMultisampleResolve;
	unsigned store;

	if (index >= 8 || (index == 0 ? _pass.color0 == NULL : _pass.more[index - 1].texture == NULL)) {
		akios_say("refused: a store action for colour attachment %lu, which this pass does not have; the next draw is failed\n", (unsigned long)index);
		snprintf(_refused, sizeof(_refused), "a store action for colour attachment %lu, which the pass does not have", (unsigned long)index);
		return;
	}
	if ((action != MTLStoreActionStore && action != MTLStoreActionDontCare && action != MTLStoreActionUnknown && !resolves) ||
	    (resolves && _resolveTo[index] == nil)) {
		akios_say("refused: colour store action %lu at %lu%s; Store, DontCare and a resolve into the pass's resolveTexture are served; the next "
			 "draw is failed\n", (unsigned long)action, (unsigned long)index, resolves ? " with no resolveTexture" : "");
		snprintf(_refused, sizeof(_refused), "colour store action %lu at %lu is not served", (unsigned long)action, (unsigned long)index);
		return;
	}
	_resolving[index] = resolves;
	store = resolves || action == MTLStoreActionUnknown ? (unsigned)MTLStoreActionStore : (unsigned)action;   /* (stored for the resolve) */
	if (index == 0) {
		_pass.store_action = store;
	} else {
		_pass.more[index - 1].store_action = store;
	}
}

- (void)setDepthStoreAction:(MTLStoreAction)action
{
	if (_pass.depth == NULL) {
		AK_ONCE("a depth store action (%lu) was set on a pass with no depth attachment; nothing to store\n", (unsigned long)action);
		return;
	}
	_pass.depth_store_action = action == MTLStoreActionUnknown ? (unsigned)MTLStoreActionStore : (unsigned)action;
}

- (void)setStencilStoreAction:(MTLStoreAction)action
{
	if (_pass.stencil == NULL) {
		AK_ONCE("a stencil store action (%lu) was set on a pass with no stencil attachment; nothing to store\n", (unsigned long)action);
		return;
	}
	_pass.stencil_store_action = action == MTLStoreActionUnknown ? (unsigned)MTLStoreActionStore : (unsigned)action;
}

- (void)setColorStoreActionOptions:(MTLStoreActionOptions)options atIndex:(NSUInteger)index
{
	AK_ONCE("colour store action options %#lx at index %lu; one sample here, no custom sample positions to keep\n", (unsigned long)options, (unsigned long)index);
}

- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)options
{
	AK_ONCE("depth store action options %#lx on a pass with no depth attachment\n", (unsigned long)options);
}

- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)options
{
	AK_ONCE("stencil store action options %#lx on a pass with no stencil attachment\n", (unsigned long)options);
}

/* --- the draws --- */

/*
 * One whole pass of hakios-metal's per call (begin, the state, the draw, the flushes that put the colour in memory): the
 * C interface's shape, chosen over a pass object because the private tree measured 41 us of fixed cost per draw and
 * nothing here yet draws more than once per pass. In sysmem mode Load and DontCare are the same thing (the RB writes the
 * memory as it draws, there is no tile to load into). A Clear belongs to the pass, not to each draw: the first draw
 * carries it (hakios-metal fills the attachment with the 2D engine before that draw), and once it is recorded the
 * stored action becomes Load, so a second draw does not wipe the first; an encoder that ends with the Clear unspent
 * records it alone at -endEncoding. hakios-metal judges the rest -- the program against the attachment's format, the primitive,
 * a zero vertex count, an instance count other than 1, a viewport or scissor outside the target, the buffer tables (step
 * one: empty) -- and refuses by name; the command buffer then ends in error with that sentence, printed here as well.
 */
- (void)akDraw:(MTLPrimitiveType)primitive vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances
{
	[self akDraw:primitive vertexStart:start vertexCount:count instanceCount:instances indexBuffer:nil indexType:MTLIndexTypeUInt16
	     indexOffset:0 baseVertex:0 baseInstance:0];
}

/* the fragment constants each program was linked with, for the trace's lines (metal_trace, metal_skip) */
static NSMutableDictionary *akm_program_constants;

void
akm_note_constants(const void *program, NSString *constants)
{
	@synchronized ([NSMutableDictionary class]) {
		if (akm_program_constants == nil) akm_program_constants = [[NSMutableDictionary alloc] init];
		[akm_program_constants setObject:constants forKey:[NSValue valueWithPointer:program]];
	}
}

static NSString *
akm_constants_of(const void *program)
{
	@synchronized ([NSMutableDictionary class]) {
		NSString *c = [akm_program_constants objectForKey:[NSValue valueWithPointer:program]];
		return c != nil ? c : @"";
	}
}

/* boot-arg metal_trace=1: each kind of draw said once -- its program, its target and the textures it samples -- so that
 * a wrong picture can be traced to the pass that made it. Off by default: a boot draws thousands. */
BOOL
akm_tracing(void)
{
	static int on = -1;

	if (on < 0) {
		char args[1024] = "";
		size_t size = sizeof(args) - 1;

		on = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_trace=1") != NULL;
	}
	return on == 1;
}

/* boot-arg metal_skip=WORD (a diagnostic, beside metal_trace): a draw whose trace line holds WORD, its spaces written
 * as '_', is not drawn -- to find which kind of draw makes a part of the picture by taking it away */
static const char *
akm_skip_word(void)
{
	static char word[128];
	static int read;

	if (!read) {
		char args[1024] = "";
		size_t size = sizeof(args) - 1;
		const char *at;

		read = 1;
		if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && (at = strstr(args, "metal_skip=")) != NULL) {
			at += strlen("metal_skip=");
			for (size_t i = 0; i + 1 < sizeof(word) && at[i] != '\0' && at[i] != ' '; i++) {
				word[i] = at[i] == '_' ? ' ' : at[i];
			}
		}
	}
	return word[0] != '\0' ? word : NULL;
}

/* boot-arg metal_dump=cfg:NAME (a diagnostic): for draws whose program's name holds NAME, the first 128 bytes of each
 * fragment buffer, each content once (40 at most). An uber shader's loops run as many times as its configuration's bytes
 * say, so what one of its draws costs is in this buffer, not in its code */
static void
akm_dump_config(const char *program, hakios_metal_buffer *const *buffers, const uint64_t *offsets, unsigned count)
{
	static char name[64];
	static int state = -1;
	static NSMutableSet *seen;

	if (state < 0) {
		char args[1024] = {0};
		size_t size = sizeof(args) - 1;
		const char *at;

		state = 0;
		if (sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && (at = strstr(args, "metal_dump=cfg:")) != NULL) {
			at += strlen("metal_dump=cfg:");
			for (size_t i = 0; i + 1 < sizeof(name) && at[i] != '\0' && at[i] != ' '; i++) name[i] = at[i];
			state = name[0] != '\0';
			seen = [[NSMutableSet alloc] init];
		}
	}
	if (state != 1 || program == NULL || strstr(program, name) == NULL || [seen count] >= 40) return;
	for (unsigned i = 0; i < count; i++) {
		if (buffers[i] == NULL) continue;
		const uint8_t *bytes = (const uint8_t *)hakios_metal_buffer_contents(buffers[i]);
		const uint64_t length = hakios_metal_buffer_length(buffers[i]);
		if (bytes == NULL || offsets[i] >= length) continue;
		const uint64_t n = length - offsets[i] < 128 ? length - offsets[i] : 128;
		char hex[2 * 128 + 1];
		for (uint64_t k = 0; k < n; k++) snprintf(hex + 2 * k, 3, "%02x", bytes[offsets[i] + k]);
		NSString *key = [NSString stringWithFormat:@"%u:%s", i, hex];
		if ([seen containsObject:key]) continue;
		[seen addObject:key];
		akios_say("cfg: %s fragment buffer %u (%llu bytes from %llu): %s\n", program, i, (unsigned long long)(length - offsets[i]),
			 (unsigned long long)offsets[i], hex);
	}
}

/*
 * YES for a draw of luma_boost, unless boot-arg metal_luma_boost=1. A library that has its own (an iOS 17
 * QuartzCore's, CA_QC_METALLIB off a Mac: the colour already drawn, by framebuffer fetch, through a LUT) gets it
 * drawn as a full-screen pass at 1.5 ms a draw, 83% of the GPU's timed passes (logs/224205-run.log,
 * metal_fps=draws); its stand-in there, inplace_copy, stores through texture 3 as an image, which a draw cannot
 * (logs/225648-run.log: backboardd aborted). The picture as it is -- what inplace_copy stands for -- is the draw
 * left out.
 */
static BOOL
akm_luma_boost_left_out(const char *program)
{
	static int keep = -1;

	if (program == NULL || strstr(program, "+luma_boost_l") == NULL) {
		return NO;
	}
	if (keep < 0) {
		char args[1024] = "";
		size_t size = sizeof(args) - 1;

		keep = sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "metal_luma_boost=1") != NULL;
		AK_ONCE("luma_boost: %s (metal_luma_boost=1 draws it)\n", keep ? "drawn" : "left out, the picture as it is");
	}
	return !keep;
}

/* YES when the draw is to be left out (metal_skip); prints the kind once when tracing */
static BOOL
akm_trace_draw(const void *which, const char *program, const struct hakios_metal_render_pass *pass, hakios_metal_texture *const *textures, unsigned count,
	      unsigned primitive, unsigned blend)
{
	static NSMutableSet *seen;
	static unsigned printed;
	NSMutableString *line;
	const char *skip = akm_skip_word();
	BOOL skipped;

	if (!akm_tracing() && skip == NULL) {
		return NO;
	}
	line = [NSMutableString stringWithFormat:@"%s (%p fc%@) prim %u into %ux%u fmt %u load %u%s%s", program, which, akm_constants_of(which), primitive,
		pass->color0 != NULL ? hakios_metal_texture_width(pass->color0) : 0, pass->color0 != NULL ? hakios_metal_texture_height(pass->color0) : 0,
		pass->color0 != NULL ? hakios_metal_texture_format(pass->color0) : 0, pass->load_action,
		pass->color0 != NULL && hakios_metal_texture_iosurface(pass->color0) != 0 ? " (surface)" : "", blend ? " blend" : ""];
	for (unsigned i = 0; i < count; i++) {
		if (textures[i] == NULL) continue;
		[line appendFormat:@" t%u=%ux%u fmt %u%s", i, hakios_metal_texture_width(textures[i]), hakios_metal_texture_height(textures[i]),
			hakios_metal_texture_format(textures[i]), hakios_metal_texture_iosurface(textures[i]) != 0 ? " (surface)" : ""];
	}
	skipped = skip != NULL && strstr([line UTF8String], skip) != NULL;
	if (!akm_tracing() || printed >= 3000) {
		return skipped;
	}
	@synchronized ([NSMutableSet class]) {
		if (seen == nil) seen = [[NSMutableSet alloc] init];
		if ([seen containsObject:line]) return skipped;
		[seen addObject:line];
		printed++;
	}
	akios_say("trace: %s%s\n", [line UTF8String], skipped ? " (skipped)" : "");
	return skipped;
}

/* the draws in one: INDEX_BUFFER non-nil is an indexed draw (COUNT its indices, START unread) */
- (void)akDraw:(MTLPrimitiveType)primitive vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances
       indexBuffer:(id)indexBuffer indexType:(MTLIndexType)indexType indexOffset:(NSUInteger)indexOffset baseVertex:(NSInteger)baseVertex
      baseInstance:(NSUInteger)baseInstance
{
	[self akDrawOnce:primitive vertexStart:start vertexCount:count instanceCount:instances indexBuffer:indexBuffer indexType:indexType
	     indexOffset:indexOffset baseVertex:baseVertex baseInstance:baseInstance];
}

- (void)akDrawOnce:(MTLPrimitiveType)primitive vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances
	   indexBuffer:(id)indexBuffer indexType:(MTLIndexType)indexType indexOffset:(NSUInteger)indexOffset baseVertex:(NSInteger)baseVertex
	  baseInstance:(NSUInteger)baseInstance
{
	hakios_metal_cb *cb = [self akCb];
	int drawn;
	hakios_metal_buffer *vs[AKIOS_MAX_BUFFERS], *fs[AKIOS_MAX_BUFFERS];
	/* an indirect draw's buffer, taken here so that no return below leaves it for the next draw */
	id indirectArgs = _indirectArgs;
	NSUInteger indirectOffset = _indirectOffset;
	_indirectArgs = nil;
	hakios_metal_texture *fsTex[AKIOS_MAX_TEXTURES], *vsTex[AKIOS_MAX_TEXTURES];
	hakios_metal_sampler *fsSamp[AKIOS_MAX_SAMPLERS], *vsSamp[AKIOS_MAX_SAMPLERS];

	if (_pipeline == nil) {
		akios_say("refused: a draw with no render pipeline state; the command buffer is failed\n");
		hakios_metal_cb_refuse(cb, "a draw with no render pipeline state");
		return;
	}
	if ([_pipeline akStandIn] != NULL) {
		/* a pipeline that could not be built (said once, where it was asked for): skipped, quietly */
		hakios_metal_cb_refuse(cb, [_pipeline akStandIn]);
		return;
	}
	if (_refused[0] != '\0') {
		akios_say("refused: this draw, because %s; the command buffer is failed\n", _refused);
		hakios_metal_cb_refuse(cb, _refused);
		return;
	}
	/* what the draw names, kept by the command buffer until it has completed (the memory goes with the object) */
	[_akCommandBuffer akHold:_pipeline];
	[_akCommandBuffer akHold:indexBuffer];
	[_akCommandBuffer akHold:indirectArgs];
	for (unsigned i = 0; i < _vsHighest; i++) [_akCommandBuffer akHold:_vsBuffers[i]];
	for (unsigned i = 0; i < _fsHighest; i++) [_akCommandBuffer akHold:_fsBuffers[i]];
	for (unsigned i = 0; i < _fsHighestTexture; i++) [_akCommandBuffer akHold:_fsTextures[i]];
	for (unsigned i = 0; i < _vsHighestTexture; i++) [_akCommandBuffer akHold:_vsTextures[i]];
	for (unsigned i = 0; i < _vsHighest; i++) {
		vs[i] = _vsBuffers[i] != nil ? [_vsBuffers[i] akCore] : NULL;
	}
	for (unsigned i = 0; i < _fsHighest; i++) {
		fs[i] = _fsBuffers[i] != nil ? [_fsBuffers[i] akCore] : NULL;
	}
	for (unsigned i = 0; i < _fsHighestTexture; i++) {
		fsTex[i] = _fsTextures[i] != nil ? [_fsTextures[i] akCore] : NULL;
	}
	for (unsigned i = 0; i < _fsHighestSampler; i++) {
		fsSamp[i] = _fsSamplers[i] != nil ? [_fsSamplers[i] akCore] : NULL;
	}
	for (unsigned i = 0; i < _vsHighestTexture; i++) {
		vsTex[i] = _vsTextures[i] != nil ? [_vsTextures[i] akCore] : NULL;
	}
	for (unsigned i = 0; i < _vsHighestSampler; i++) {
		vsSamp[i] = _vsSamplers[i] != nil ? [_vsSamplers[i] akCore] : NULL;
	}
	hakios_metal_cb_set_vertex_textures(cb, vsTex, _vsHighestTexture, vsSamp, _vsHighestSampler);
	hakios_metal_program *program = [_pipeline akProgramFor:fs offsets:_fsOffsets count:_fsHighest];
	if (program == NULL) {
		/* (11-26) an uber shader drawn only by its specialisations (akProgramFor: waits for them), none to be had for
		 * this content (said there): skipped, quietly, as a stand-in's draws are */
		hakios_metal_cb_refuse(cb, "an uber shader with no program for this content of its buffer");
		return;
	}

	akm_dump_config(hakios_metal_program_name(program), fs, _fsOffsets, _fsHighest);
	if (akm_trace_draw([_pipeline akProgram], hakios_metal_program_name([_pipeline akProgram]), &_pass, fsTex, _fsHighestTexture, (unsigned)primitive, 0)) {
		return;
	}
	if (akm_luma_boost_left_out(hakios_metal_program_name([_pipeline akProgram]))) {
		return;
	}
	if (indexBuffer != nil && ![indexBuffer isKindOfClass:[AkiosMaliBuffer class]]) {
		akios_say("refused: an indexed draw from a %s, not a buffer of this device; the command buffer is failed\n", class_getName(object_getClass(indexBuffer)));
		hakios_metal_cb_refuse(cb, "an indexed draw from a buffer that is not this device's");
		return;
	}
	/* a word this encoder has not counted into yet starts from zero: Metal's result is the pass's count */
	if (_pass.visibility_mode != 0) {
		if (_visibilityCounted == nil) _visibilityCounted = [[NSMutableIndexSet alloc] init];
		_pass.visibility_reset = ![_visibilityCounted containsIndex:(NSUInteger)(_pass.visibility_offset / 8)];
	}
	if (indirectArgs != nil) {
		if (![indirectArgs isKindOfClass:[AkiosMaliBuffer class]]) {
			akios_say("refused: an indirect draw whose arguments are in a %s, not a buffer of this device; the command buffer is failed\n",
				 class_getName(object_getClass(indirectArgs)));
			hakios_metal_cb_refuse(cb, "an indirect draw's arguments in a buffer that is not this device's");
			return;
		}
		hakios_metal_cb_set_indirect(cb, [(AkiosMaliBuffer *)indirectArgs akCore], (uint64_t)indirectOffset);
	}
	if (indexBuffer != nil) {
		drawn = hakios_metal_cb_draw_indexed(cb, program, &_pass, _hasViewport ? &_viewport : NULL, _hasScissor ? &_scissor : NULL,
						     (unsigned)primitive, (unsigned)count, (unsigned)indexType, [(AkiosMaliBuffer *)indexBuffer akCore],
						     (uint64_t)indexOffset, (unsigned)instances, (int)baseVertex, (unsigned)baseInstance, vs, _vsOffsets, _vsHighest, fs,
						     _fsOffsets, _fsHighest, fsTex, _fsHighestTexture, fsSamp, _fsHighestSampler);
	} else {
		drawn = hakios_metal_cb_draw3(cb, program, &_pass, _hasViewport ? &_viewport : NULL, _hasScissor ? &_scissor : NULL,
					      (unsigned)primitive, (unsigned)start, (unsigned)count, (unsigned)instances, (unsigned)baseInstance,
					      vs, _vsOffsets, _vsHighest, fs, _fsOffsets, _fsHighest, fsTex, _fsHighestTexture, fsSamp, _fsHighestSampler);
	}
	if (drawn == 0 && _pass.visibility_mode != 0) {
		[_visibilityCounted addIndex:(NSUInteger)(_pass.visibility_offset / 8)];
	}
	if (drawn != 0) {
		akios_say("refused: a draw of %s, primitive %lu, %lu vertices from %lu, %lu instance(s), load %u store %u, %u vertex and %u fragment "
			 "buffer slots: %s\n", hakios_metal_program_name([_pipeline akProgram]), (unsigned long)primitive, (unsigned long)count,
			 (unsigned long)start, (unsigned long)instances, _pass.load_action, _pass.store_action, _vsHighest, _fsHighest, hakios_metal_error());
		hakios_metal_cb_refuse(cb, hakios_metal_error());
		return;
	}
	akm_spend_clears(&_pass);   /* the fills are recorded: the pass's later draws load what they left */
}

- (void)drawPrimitives:(MTLPrimitiveType)primitive vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
{
	[self akDraw:primitive vertexStart:start vertexCount:count instanceCount:1];
}

- (void)drawPrimitives:(MTLPrimitiveType)primitive vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances
{
	[self akDraw:primitive vertexStart:start vertexCount:count instanceCount:instances];
}

- (void)drawPrimitives:(MTLPrimitiveType)primitive vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances
	  baseInstance:(NSUInteger)baseInstance
{
	[self akDraw:primitive vertexStart:start vertexCount:count instanceCount:instances indexBuffer:nil indexType:MTLIndexTypeUInt16
	     indexOffset:0 baseVertex:0 baseInstance:baseInstance];
}

/* Indirect, patch and mesh draws: each is refused by name AND fails the command buffer at once, because a draw that
 * vanishes without a word is the worst outcome available (the compute encoder's indirect dispatch rule). Indirect ones
 * need a grid read by the GPU, patches the tessellation stages (HS/DS off here), mesh draws the object/mesh stages. */
- (void)akRefuseDraw:(SEL)sel what:(const char *)what
{
	akios_say("refused: -%s: %s\n", sel_getName(sel), what);
	hakios_metal_cb_refuse([self akCb], "a draw of a kind that is not served (indexed, indirect, patches or mesh)");
}

/* Indexed draws: hakios-metal's 7-word CP_DRAW_INDX_OFFSET with Metal's primitive restart; it refuses by name what it
 * does not serve (a negative base vertex, an offset that is not a multiple of the index size) */
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitive indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType
		  indexBuffer:(id)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset
{
	if (indexBuffer == nil) {
		akios_say("refused: an indexed draw with no index buffer; the command buffer is failed\n");
		hakios_metal_cb_refuse([self akCb], "an indexed draw with no index buffer");
		return;
	}
	[self akDraw:primitive vertexStart:0 vertexCount:indexCount instanceCount:1 indexBuffer:indexBuffer indexType:indexType
	     indexOffset:indexBufferOffset baseVertex:0 baseInstance:0];
}

- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitive indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType
		  indexBuffer:(id)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instances
{
	if (indexBuffer == nil) {
		akios_say("refused: an indexed draw with no index buffer; the command buffer is failed\n");
		hakios_metal_cb_refuse([self akCb], "an indexed draw with no index buffer");
		return;
	}
	[self akDraw:primitive vertexStart:0 vertexCount:indexCount instanceCount:instances indexBuffer:indexBuffer indexType:indexType
	     indexOffset:indexBufferOffset baseVertex:0 baseInstance:0];
}

- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitive indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType
		  indexBuffer:(id)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instances
		   baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance
{
	if (indexBuffer == nil) {
		akios_say("refused: an indexed draw with no index buffer; the command buffer is failed\n");
		hakios_metal_cb_refuse([self akCb], "an indexed draw with no index buffer");
		return;
	}
	[self akDraw:primitive vertexStart:0 vertexCount:indexCount instanceCount:instances indexBuffer:indexBuffer indexType:indexType
	     indexOffset:indexBufferOffset baseVertex:baseVertex baseInstance:baseInstance];
}

/* Indirect draws: the counts, starts and bases are read by the GPU as it runs the draw (CP_DRAW_INDIRECT_MULTI), so
 * the counts handed on here are placeholders the core does not read */
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitive indexType:(MTLIndexType)indexType indexBuffer:(id)indexBuffer
	    indexBufferOffset:(NSUInteger)indexBufferOffset indirectBuffer:(id)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset
{
	if (indexBuffer == nil || indirectBuffer == nil) {
		akios_say("refused: an indirect indexed draw with no %s; the command buffer is failed\n", indexBuffer == nil ? "index buffer" : "argument buffer");
		hakios_metal_cb_refuse([self akCb], "an indirect indexed draw with a buffer missing");
		return;
	}
	_indirectArgs = indirectBuffer;
	_indirectOffset = indirectBufferOffset;
	[self akDraw:primitive vertexStart:0 vertexCount:1 instanceCount:1 indexBuffer:indexBuffer indexType:indexType
	     indexOffset:indexBufferOffset baseVertex:0 baseInstance:0];
}

- (void)drawPrimitives:(MTLPrimitiveType)primitive indirectBuffer:(id)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset
{
	if (indirectBuffer == nil) {
		akios_say("refused: an indirect draw with no argument buffer; the command buffer is failed\n");
		hakios_metal_cb_refuse([self akCb], "an indirect draw with no argument buffer");
		return;
	}
	_indirectArgs = indirectBuffer;
	_indirectOffset = indirectBufferOffset;
	[self akDraw:primitive vertexStart:0 vertexCount:1 instanceCount:1 indexBuffer:nil indexType:MTLIndexTypeUInt16
	     indexOffset:0 baseVertex:0 baseInstance:0];
}

- (void)drawPatches:(NSUInteger)patches patchStart:(NSUInteger)patchStart patchCount:(NSUInteger)patchCount patchIndexBuffer:(id)patchIndexBuffer
     patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)baseInstance
{
	(void)patches; (void)patchStart; (void)patchCount; (void)patchIndexBuffer; (void)patchIndexBufferOffset; (void)instances; (void)baseInstance;
	[self akRefuseDraw:_cmd what:"has no tessellation stages (HS and DS are off); the command buffer is failed"];
}

- (void)drawPatches:(NSUInteger)patches patchIndexBuffer:(id)patchIndexBuffer patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset
     indirectBuffer:(id)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset
{
	(void)patches; (void)patchIndexBuffer; (void)patchIndexBufferOffset; (void)indirectBuffer; (void)indirectBufferOffset;
	[self akRefuseDraw:_cmd what:"has no tessellation stages (HS and DS are off); the command buffer is failed"];
}

- (void)drawIndexedPatches:(NSUInteger)patches patchStart:(NSUInteger)patchStart patchCount:(NSUInteger)patchCount patchIndexBuffer:(id)patchIndexBuffer
    patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset controlPointIndexBuffer:(id)controlPointIndexBuffer
 controlPointIndexBufferOffset:(NSUInteger)controlPointIndexBufferOffset instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)baseInstance
{
	(void)patches; (void)patchStart; (void)patchCount; (void)patchIndexBuffer; (void)patchIndexBufferOffset; (void)controlPointIndexBuffer;
	(void)controlPointIndexBufferOffset; (void)instances; (void)baseInstance;
	[self akRefuseDraw:_cmd what:"has no tessellation stages (HS and DS are off); the command buffer is failed"];
}

- (void)drawIndexedPatches:(NSUInteger)patches patchIndexBuffer:(id)patchIndexBuffer patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset
   controlPointIndexBuffer:(id)controlPointIndexBuffer controlPointIndexBufferOffset:(NSUInteger)controlPointIndexBufferOffset
	    indirectBuffer:(id)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset
{
	(void)patches; (void)patchIndexBuffer; (void)patchIndexBufferOffset; (void)controlPointIndexBuffer; (void)controlPointIndexBufferOffset;
	(void)indirectBuffer; (void)indirectBufferOffset;
	[self akRefuseDraw:_cmd what:"has no tessellation stages (HS and DS are off); the command buffer is failed"];
}

/* the mesh draws are REAL in _MTLCommandEncoder (they re-send themselves), so they are overridden rather than left to
 * reach code written for Apple's mesh encoder */
- (void)drawMeshThreadgroups:(MTLSize)groups threadsPerObjectThreadgroup:(MTLSize)objectThreads threadsPerMeshThreadgroup:(MTLSize)meshThreads
{
	(void)groups; (void)objectThreads; (void)meshThreads;
	[self akRefuseDraw:_cmd what:"has no mesh or object stages; the command buffer is failed"];
}

- (void)drawMeshThreads:(MTLSize)threads threadsPerObjectThreadgroup:(MTLSize)objectThreads threadsPerMeshThreadgroup:(MTLSize)meshThreads
{
	(void)threads; (void)objectThreads; (void)meshThreads;
	[self akRefuseDraw:_cmd what:"has no mesh or object stages; the command buffer is failed"];
}

- (void)drawMeshThreadgroupsWithIndirectBuffer:(id)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset
		   threadsPerObjectThreadgroup:(MTLSize)objectThreads threadsPerMeshThreadgroup:(MTLSize)meshThreads
{
	(void)indirectBuffer; (void)indirectBufferOffset; (void)objectThreads; (void)meshThreads;
	[self akRefuseDraw:_cmd what:"has no mesh or object stages; the command buffer is failed"];
}

- (void)executeCommandsInBuffer:(id)icb withRange:(NSRange)range
{
	(void)icb; (void)range;
	[self akRefuseDraw:_cmd what:"has no indirect command buffers (the GPU reads no draw arguments here); the command buffer is failed"];
}

- (void)executeCommandsInBuffer:(id)icb indirectBuffer:(id)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset
{
	(void)icb; (void)indirectBuffer; (void)indirectBufferOffset;
	[self akRefuseDraw:_cmd what:"has no indirect command buffers (the GPU reads no draw arguments here); the command buffer is failed"];
}

/*
 * Served by construction, as in the compute encoder: each draw here is a whole pass whose tail flushes the CCU and the
 * caches (PC_CCU_FLUSH_COLOR_TS, CACHE_FLUSH_TS) and whose head invalidates them, one queue runs its command buffers
 * in commit order, and every allocation is resident for its whole life. A barrier, a fence or a residency request asks
 * for an ordering that is already the only one there is.
 */
- (void)updateFence:(id)fence afterStages:(MTLRenderStages)stages  { (void)fence; (void)stages; }
- (void)waitForFence:(id)fence beforeStages:(MTLRenderStages)stages { (void)fence; (void)stages; }
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before
{
	(void)scope; (void)after; (void)before;
}
- (void)memoryBarrierWithResources:(const id *)resources count:(NSUInteger)count afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before
{
	(void)resources; (void)count; (void)after; (void)before;
}
/* (resources reached through argument buffers: kept, and listed with their usage, MTLResourceUsageRead 1 / Write 2 being
 * the list's bits) */
- (void)useResource:(id)resource usage:(MTLResourceUsage)usage
{
	[_akCommandBuffer akHold:resource usage:(unsigned)usage & 3u];
}
- (void)useResource:(id)resource usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages
{
	(void)stages;
	[_akCommandBuffer akHold:resource usage:(unsigned)usage & 3u];
}
- (void)useResources:(const id *)resources count:(NSUInteger)count usage:(MTLResourceUsage)usage
{
	for (NSUInteger i = 0; i < count; i++) {
		[_akCommandBuffer akHold:resources[i] usage:(unsigned)usage & 3u];
	}
}
- (void)useResources:(const id *)resources count:(NSUInteger)count usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages
{
	(void)stages;
	for (NSUInteger i = 0; i < count; i++) {
		[_akCommandBuffer akHold:resources[i] usage:(unsigned)usage & 3u];
	}
}
- (void)useHeap:(id)heap { (void)heap; }
- (void)useHeap:(id)heap stages:(MTLRenderStages)stages { (void)heap; (void)stages; }
- (void)useHeaps:(const id *)heaps count:(NSUInteger)count { (void)heaps; (void)count; }
- (void)useHeaps:(const id *)heaps count:(NSUInteger)count stages:(MTLRenderStages)stages { (void)heaps; (void)count; (void)stages; }

/* abstract in _MTLCommandEncoder (inheriting it aborts); a packing hint the compiler decides for itself here */
- (void)setThreadgroupPackingDisabled:(BOOL)disabled { (void)disabled; }

/* The tile an Apple GPU's imageblock covers, which the protocol lets a client read at any time. This GPU draws straight
 * into memory and has no tile here; the honest number is 0, and a READER is not a binding -- left to the catch-all it
 * would fail the next draw, which only a dropped input deserves -- so both are answered here, with a line once. */
- (NSUInteger)tileWidth
{
	AK_ONCE("a render encoder's tile width or height was asked for; this GPU draws in sysmem with no tile memory, and 0 is answered\n");
	return 0;
}

- (NSUInteger)tileHeight
{
	AK_ONCE("a render encoder's tile width or height was asked for; this GPU draws in sysmem with no tile memory, and 0 is answered\n");
	return 0;
}

/* tile shading (setTileBytes:, dispatchThreadsPerTile:, setThreadgroupMemoryLength:offset:atIndex:), function tables,
 * tessellation factor buffers, counter sampling and the object/mesh setters are declared by <MTLRenderCommandEncoder>
 * and refused through -forwardInvocation: (or Metal's own abstract bodies) above, by name */

/* Tile shading, tessellation and the depth test's bounds are not served: refused by name, and the draws that follow
 * fail by it (the earlier plug-in refused them through its forwarding) */
- (void)akRefuseState:(const char *)what
{
	akios_say("refused: %s on a render encoder (not served)\n", what);
	if (_refused[0] == '\0') {
		snprintf(_refused, sizeof(_refused), "%s (not served)", what);
	}
}
- (void)dispatchThreadsPerTile:(MTLSize)threads { (void)threads; [self akRefuseState:"a tile dispatch"]; }
- (void)setTileBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { (void)b; (void)o; (void)i; [self akRefuseState:"a tile buffer"]; }
- (void)setTileBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { (void)o; (void)i; [self akRefuseState:"a tile buffer"]; }
- (void)setTileBuffers:(const id<MTLBuffer> __unsafe_unretained *)b offsets:(const NSUInteger *)o withRange:(NSRange)r
{
	(void)b; (void)o; (void)r;
	[self akRefuseState:"tile buffers"];
}
- (void)setTileBytes:(const void *)b length:(NSUInteger)l atIndex:(NSUInteger)i { (void)b; (void)l; (void)i; [self akRefuseState:"tile bytes"]; }
- (void)setTileTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { (void)t; (void)i; [self akRefuseState:"a tile texture"]; }
- (void)setTileTextures:(const id<MTLTexture> __unsafe_unretained *)t withRange:(NSRange)r { (void)t; (void)r; [self akRefuseState:"tile textures"]; }
- (void)setTileSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { (void)s; (void)i; [self akRefuseState:"a tile sampler"]; }
- (void)setTileSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)a lodMaxClamp:(float)b atIndex:(NSUInteger)i
{
	(void)s; (void)a; (void)b; (void)i;
	[self akRefuseState:"a tile sampler"];
}
- (void)setTileSamplerStates:(const id<MTLSamplerState> __unsafe_unretained *)s withRange:(NSRange)r { (void)s; (void)r; [self akRefuseState:"tile samplers"]; }
- (void)setTileSamplerStates:(const id<MTLSamplerState> __unsafe_unretained *)s lodMinClamps:(const float *)a lodMaxClamps:(const float *)b
    withRange:(NSRange)r
{
	(void)s; (void)a; (void)b; (void)r;
	[self akRefuseState:"tile samplers"];
}
- (void)setThreadgroupMemoryLength:(NSUInteger)l offset:(NSUInteger)o atIndex:(NSUInteger)i
{
	(void)l; (void)o; (void)i;
	[self akRefuseState:"tile threadgroup memory"];
}
- (void)setTessellationFactorBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o instanceStride:(NSUInteger)s
{
	(void)b; (void)o; (void)s;
	[self akRefuseState:"a tessellation factor buffer"];
}
- (void)setTessellationFactorScale:(float)scale { (void)scale; [self akRefuseState:"a tessellation factor scale"]; }
- (void)setDepthTestMinBound:(float)minBound maxBound:(float)maxBound
{
	(void)minBound; (void)maxBound;
	[self akRefuseState:"depth test bounds"];
}

- (void)endEncoding
{
	/* a Clear no draw spent: the pass still owes it (a pass that only clears is how many clients wipe a drawable) */
	/* (not on a command buffer a refused draw already failed -- it holds an error before commit: its first sentence is the one that matters) */
	if (akm_owes_clear(&_pass) && hakios_metal_cb_error([self akCb])[0] == '\0' &&
	    hakios_metal_cb_clear([self akCb], &_pass) != 0) {
		akios_say("refused: a pass that only clears: %s\n", hakios_metal_error());
		hakios_metal_cb_refuse([self akCb], hakios_metal_error());
	}
	akm_spend_clears(&_pass);
	/* the resolves, after the pass: each multisample attachment's samples into its resolveTexture, pixel for pixel (the
	 * blit closes the pass first, so it reads what the draws wrote) */
	for (unsigned i = 0; i < 8; i++) {
		if (!_resolving[i] || hakios_metal_cb_error([self akCb])[0] != '\0') {
			continue;
		}
		if (hakios_metal_cb_blit([self akCb], [_resolveFrom[i] akCore], 0, 0, 0, (unsigned)[_resolveFrom[i] width],
					 (unsigned)[_resolveFrom[i] height], [_resolveTo[i] akCore], _resolveLevel[i], 0, 0,
					 (unsigned)[_resolveFrom[i] width], (unsigned)[_resolveFrom[i] height], 0) != 0) {
			akios_say("refused: the resolve of colour attachment %u: %s\n", i, hakios_metal_error());
			hakios_metal_cb_refuse([self akCb], hakios_metal_error());
		}
	}
	/* the bindings were handed to hakios-metal at each draw, which holds them until the GPU is done */
	_scratch = nil;
	_arena = nil;                   /* (it was one of them) */
	_arenaUsed = _arenaSize = 0;
	[super endEncoding];   /* MUST: the base class retains the command buffer and this is what releases it */
}

@end

@implementation AkiosMaliParallelRenderEncoder

+ (void)load
{
	akm_adopt(self, @protocol(MTLParallelRenderCommandEncoder), "MTLParallelRenderCommandEncoder");
}



- (instancetype)initWithAkiosCommandBuffer:(AkiosMaliCommandBuffer *)commandBuffer pass:(const struct hakios_metal_render_pass *)pass
			       colorTexture:(AkiosMaliTexture *)texture descriptor:(MTLRenderPassDescriptor *)descriptor
{
	self = [super initWithCommandBuffer:commandBuffer renderPassDescriptor:descriptor];   /* retains the buffer until -endEncoding */
	if (self == nil) {
		return nil;
	}
	_akCommandBuffer = commandBuffer;
	_pass = *pass;
	_colorTexture = texture;
	_descriptor = [descriptor copy];
	_subs = [[NSMutableArray alloc] init];
	_lock = [[NSLock alloc] init];
	return self;
}

- (void)dealloc
{
	for (NSValue *v in _subs) hakios_metal_cb_free((hakios_metal_cb *)[v pointerValue]);
}

- (id)device { return [_akCommandBuffer device]; }

/* a sub-encoder: the pass as the descriptor gave it for the first, loading what came before for the rest; storing
 * always, since the next one (or the resolve) reads it */
- (id)renderCommandEncoder
{
	struct hakios_metal_render_pass pass = _pass;
	hakios_metal_cb *sub = hakios_metal_cb_new_external([(AkiosMaliDevice *)[_akCommandBuffer device] akCore]);
	if (sub != NULL) {
		hakios_metal_cb_skip_refused(sub, !akios_strict());
	}

	[_lock lock];
	const BOOL first = [_subs count] == 0;
	[_subs addObject:[NSValue valueWithPointer:sub]];
	[_lock unlock];
	if (!first) {
		pass.load_action = MTLLoadActionLoad;
		pass.depth_load_action = MTLLoadActionLoad;
		pass.stencil_load_action = MTLLoadActionLoad;
		for (unsigned i = 0; i < 7; i++) pass.more[i].load_action = MTLLoadActionLoad;
	}
	pass.store_action = MTLStoreActionStore;
	pass.depth_store_action = MTLStoreActionStore;
	pass.stencil_store_action = MTLStoreActionStore;
	for (unsigned i = 0; i < 7; i++) pass.more[i].store_action = MTLStoreActionStore;
	return [[AkiosMaliRenderEncoder alloc] initWithAkiosCommandBuffer:_akCommandBuffer pass:&pass colorTexture:_colorTexture
										  sub:sub];
}

/* (one queue runs everything in order, caches flushed between jobs: a barrier between queue stages orders nothing more) */
- (void)barrierAfterQueueStages:(MTLStages)after beforeStages:(MTLStages)before { (void)after; (void)before; }

/* every sub-encoder stores (above); a resolve asked for here is read from the descriptor's store action at the end */
- (void)setColorStoreAction:(MTLStoreAction)action atIndex:(NSUInteger)index
{
	if (index < 8) [[[_descriptor colorAttachments] objectAtIndexedSubscript:index] setStoreAction:action];
}
- (void)setColorStoreActionOptions:(MTLStoreActionOptions)options atIndex:(NSUInteger)index { (void)options; (void)index; }
- (void)setDepthStoreAction:(MTLStoreAction)action { (void)action; }
- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)options { (void)options; }
- (void)setStencilStoreAction:(MTLStoreAction)action { (void)action; }
- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)options { (void)options; }

- (void)endEncoding
{
	hakios_metal_cb *cb = [_akCommandBuffer akCore];

	[_lock lock];
	for (NSValue *v in _subs) {
		hakios_metal_cb *sub = (hakios_metal_cb *)[v pointerValue];

		if (hakios_metal_cb_append(cb, sub) != 0) {
			akios_say("refused: a parallel render pass's sub-encoder: %s\n", hakios_metal_error());
		}
		hakios_metal_cb_free(sub);
	}
	const BOOL none = [_subs count] == 0;
	[_subs removeAllObjects];
	[_lock unlock];
	/* no sub-encoder at all: the pass's own Clear is still owed */
	if (none && akm_owes_clear(&_pass) && hakios_metal_cb_error(cb)[0] == '\0' && hakios_metal_cb_clear(cb, &_pass) != 0) {
		akios_say("refused: a parallel pass that only clears: %s\n", hakios_metal_error());
		hakios_metal_cb_refuse(cb, hakios_metal_error());
	}
	/* the resolves, once, over everything the sub-encoders drew */
	for (NSUInteger i = 0; i < 8; i++) {
		MTLRenderPassColorAttachmentDescriptor *c = [[_descriptor colorAttachments] objectAtIndexedSubscript:i];
		const MTLStoreAction a = [c storeAction];
		AkiosMaliTexture *from = (AkiosMaliTexture *)[c texture], *to = (AkiosMaliTexture *)[c resolveTexture];

		if (from == nil || to == nil || hakios_metal_cb_error(cb)[0] != '\0' ||
		    !(a == MTLStoreActionMultisampleResolve || a == MTLStoreActionStoreAndMultisampleResolve || a == MTLStoreActionUnknown)) {
			continue;
		}
		if (hakios_metal_cb_blit(cb, [from akCore], 0, 0, 0, (unsigned)[from width], (unsigned)[from height], [to akCore],
					 (unsigned)[c resolveLevel], 0, 0, (unsigned)[from width], (unsigned)[from height], 0) != 0) {
			akios_say("refused: the resolve of colour attachment %lu: %s\n", (unsigned long)i, hakios_metal_error());
			hakios_metal_cb_refuse(cb, hakios_metal_error());
		}
	}
	[super endEncoding];   /* MUST: the base class retains the command buffer and this is what releases it */
}

@end

/* ============================================================================================================
 * The command buffer's render encoders
 * ============================================================================================================ */

@implementation AkiosMaliCommandBuffer (Render)

/* every texture and buffer the pass names, kept by the command buffer until it has completed */
- (void)akHoldPass:(MTLRenderPassDescriptor *)descriptor
{
	for (NSUInteger i = 0; i < 8; i++) {
		MTLRenderPassColorAttachmentDescriptor *c = descriptor.colorAttachments[i];

		/* (written by the pass; read too when loaded) */
		[self akHold:c.texture usage:AKIOS_USE_WRITE | (c.loadAction == MTLLoadActionLoad ? AKIOS_USE_READ : 0)];
		[self akHold:c.resolveTexture usage:AKIOS_USE_WRITE];
	}
	[self akHold:descriptor.depthAttachment.texture usage:AKIOS_USE_WRITE | AKIOS_USE_READ];
	[self akHold:descriptor.stencilAttachment.texture usage:AKIOS_USE_WRITE | AKIOS_USE_READ];
	[self akHold:descriptor.visibilityResultBuffer usage:AKIOS_USE_WRITE];
}

/* A pass that cannot be served fails the command buffer and gives no encoder: the caller's draws go to nil, and the
 * command buffer's error says why */
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor
{
	struct hakios_metal_render_pass pass;
	AkiosMaliTexture *texture = nil;
	char why[256];

	if ([self akCore] == NULL) {
		akios_say("refused: a render encoder on a device without the Mali core\n");
		return nil;
	}
	if (!akm_read_render_pass(descriptor, &pass, &texture, why, sizeof(why))) {
		akios_say("refused: a render pass: %s; the command buffer is failed and no encoder is returned\n", why);
		hakios_metal_cb_refuse([self akCore], why);
		return nil;
	}
	[self akHoldPass:descriptor];
	AkiosMaliRenderEncoder *encoder = [[AkiosMaliRenderEncoder alloc] initWithAkiosCommandBuffer:self pass:&pass colorTexture:texture];
	[encoder akTakeResolves:descriptor];
	return (id<MTLRenderCommandEncoder>)encoder;
}

- (id<MTLParallelRenderCommandEncoder>)parallelRenderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor
{
	struct hakios_metal_render_pass pass;
	AkiosMaliTexture *texture = nil;
	char why[256];

	if ([self akCore] == NULL) {
		akios_say("refused: a parallel render encoder on a device without the Mali core\n");
		return nil;
	}
	if (!akm_read_render_pass(descriptor, &pass, &texture, why, sizeof(why))) {
		akios_say("refused: a parallel render pass: %s; the command buffer is failed and no encoder is returned\n", why);
		hakios_metal_cb_refuse([self akCore], why);
		return nil;
	}
	[self akHoldPass:descriptor];
	return (id<MTLParallelRenderCommandEncoder>)[[AkiosMaliParallelRenderEncoder alloc] initWithAkiosCommandBuffer:self pass:&pass
	    colorTexture:texture descriptor:descriptor];
}

@end
