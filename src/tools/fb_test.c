/*
 * fb_test: the framebuffer's user client (IOMobileFramebufferUserClient) tried selector by selector, the way iOS calls
 * it -- Apple's argument shapes (iOS 27.2.1's 101-entry table) -- and each answer checked against what the selector
 * means. What it changes (gamma table, a matrix, the colour remap mode, flags) it reads first and sets back. It never
 * turns the panel off and never swaps.
 *
 * usage: fb_test [-v]      one line per check: PASS / FAIL, the selector's name, what came back; a count at the end
 */
#include <IOKit/IOKitLib.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define kIOReturnUnsupported    0xe00002c7
#define kIOReturnBadArgument    0xe00002c2

static io_connect_t fb;
static int passed, failed, verbose;

static kern_return_t
call(uint32_t sel, const uint64_t *in, uint32_t nin, const void *sin, size_t sinsize, uint64_t *out, uint32_t *nout,
    void *sout, size_t *soutsize)
{
	return IOConnectCallMethod(fb, sel, in, nin, sin, sinsize, out, nout, sout, soutsize);
}

static void
check(bool ok, uint32_t sel, const char *name, const char *fmt, ...)
{
	char what[200] = "";
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(what, sizeof(what), fmt, ap);
	va_end(ap);
	if (ok) {
		passed++;
	} else {
		failed++;
	}
	if (!ok || verbose) {
		printf("%s %3u %-34s %s\n", ok ? "PASS" : "FAIL", sel, name, what);
	}
}

/* a selector that takes NIN scalars (zeros) and answers NOUT scalars: expect EXPECT */
static void
scalars(uint32_t sel, const char *name, uint32_t nin, uint32_t nout, kern_return_t expect)
{
	uint64_t in[4] = { 0 }, out[4] = { 0 };
	uint32_t n = nout;
	kern_return_t kr = call(sel, in, nin, NULL, 0, out, &n, NULL, NULL);

	check(kr == expect, sel, name, "-> %#x (want %#x) out %u [%#llx %#llx]", kr, expect, n, out[0], out[1]);
}

int
main(int argc, char **argv)
{
	verbose = argc > 1 && !strcmp(argv[1], "-v");
	io_service_t svc = IOServiceGetMatchingService(0, IOServiceMatching("IOMobileFramebuffer"));

	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &fb) != KERN_SUCCESS) {
		printf("fb_test: no IOMobileFramebuffer to open\n");
		return 1;
	}

	uint64_t in[4], out[4];
	uint32_t n;
	kern_return_t kr;

	/* ---- queries ---- */
	n = 2;
	kr = call(8, NULL, 0, NULL, 0, out, &n, NULL, NULL);
	check(kr == 0 && n == 2 && out[0] > 0 && out[1] > 0, 8, "get_display_size", "-> %#x %llux%llu", kr, out[0], out[1]);
	uint64_t width = out[0], height = out[1];
	n = 1;
	kr = call(7, NULL, 0, NULL, 0, out, &n, NULL, NULL);
	check(kr == 0 && n == 1, 7, "get_framebuffer_id", "-> %#x %llu", kr, out[0]);
	n = 1;
	kr = call(18, NULL, 0, NULL, 0, out, &n, NULL, NULL);
	check(kr == 0 && out[0] == 1, 18, "is_main_display", "-> %#x %llu (want 1)", kr, out[0]);
	n = 1;
	kr = call(25, NULL, 0, NULL, 0, out, &n, NULL, NULL);
	check(kr == 0 && out[0] == 0, 25, "get_digital_out_state", "-> %#x %llu (want 0: none)", kr, out[0]);
	n = 1;
	kr = call(28, NULL, 0, NULL, 0, out, &n, NULL, NULL);
	check(kr == 0 && out[0] > 100 && out[0] < 1000, 28, "get_dot_pitch", "-> %#x %llu ppi", kr, out[0]);
	uint64_t ppi = out[0];
	n = 1;
	kr = call(90, NULL, 0, NULL, 0, out, &n, NULL, NULL);
	{
		float f;
		uint32_t bits = (uint32_t) out[0];

		memcpy(&f, &bits, 4);
		check(kr == 0 && (uint64_t) (f + 0.5f) == ppi, 90, "get_dot_pitch_float", "-> %#x %g (want %llu)", kr, f, ppi);
	}
	{
		float area[2] = { 0, 0 };
		size_t sz = sizeof(area);

		kr = call(29, NULL, 0, NULL, 0, NULL, NULL, area, &sz);
		check(kr == 0 && sz == 8 && area[0] > 30 && area[0] < 120 && area[1] > area[0], 29, "get_display_area",
		    "-> %#x %.1f x %.1f mm (%llux%llu)", kr, area[0], area[1], width, height);
	}
	n = 1;
	kr = call(77, NULL, 0, NULL, 0, out, &n, NULL, NULL);
	check(kr == 0 && out[0] != 0, 77, "get_current_absolute_time", "-> %#x %llu", kr, out[0]);
	n = 1;
	kr = call(91, NULL, 0, NULL, 0, out, &n, NULL, NULL);
	check(kr == 0, 91, "swap_get_current", "-> %#x swap %llu", kr, out[0]);
	n = 1;
	kr = call(83, (uint64_t[]){ 0 }, 1, NULL, 0, out, &n, NULL, NULL);
	check(kr == 0, 83, "displayed_fb_surface", "-> %#x surface %llu", kr, out[0]);
	uint64_t shown = out[0];
	n = 1;
	kr = call(49, (uint64_t[]){ shown }, 1, NULL, 0, out, &n, NULL, NULL);
	check(kr == 0 && (shown == 0 || out[0] == 0), 49, "surface_is_replaceable", "-> %#x %llu for the surface shown (%llu)",
	    kr, out[0], shown);
	n = 1;
	kr = call(49, (uint64_t[]){ shown + 1000 }, 1, NULL, 0, out, &n, NULL, NULL);
	check(kr == 0 && out[0] == 1, 49, "surface_is_replaceable", "-> %#x %llu for another surface", kr, out[0]);
	scalars(80, "get_link_quality", 0, 1, 0);
	scalars(98, "get_lpr_frame_timestamp", 0, 1, 0);
	scalars(82, "get_protection_options", 0, 1, 0);
	{
		uint8_t buf[64] = { 0 };
		size_t sz = sizeof(buf);

		n = 2;
		kr = call(74, (uint64_t[]){ 0 }, 1, NULL, 0, out, &n, buf, &sz);
		check(kr == 0, 74, "supported_frame_info", "-> %#x count %llu, first \"%.32s\"", kr, out[0], buf);
		uint8_t hd[16], mc[20];
		size_t s1 = sizeof(hd), s2 = sizeof(mc);

		kr = call(24, NULL, 0, NULL, 0, NULL, NULL, hd, &s1);
		check(kr == 0, 24, "get_HDCP_downstream_state", "-> %#x (none)", kr);
		kr = call(42, NULL, 0, NULL, 0, NULL, NULL, mc, &s2);
		check(kr == 0, 42, "getExternalMirroringCapability", "-> %#x (none)", kr);
		uint8_t blk[44];
		size_t s3 = sizeof(blk);

		kr = call(79, (uint64_t[]){ 0x41, 0 }, 2, NULL, 0, NULL, NULL, blk, &s3);
		check(kr == 0, 79, "get_block(0x41)", "-> %#x", kr);
		n = 1;
		kr = call(96, (uint64_t[]){ 0x41 }, 1, NULL, 0, out, &n, NULL, NULL);
		check(kr == 0 && out[0] == 44, 96, "get_block_size(0x41)", "-> %#x %llu (want 44)", kr, out[0]);
	}

	/* ---- colour: read, change, read back, restore ---- */
	{
		static uint32_t saved[3][257], test[3][257], back[3][257];
		size_t sz = sizeof(saved);

		kr = call(27, NULL, 0, NULL, 0, NULL, NULL, saved, &sz);
		check(kr == 0 && sz == 3084 && saved[0][256] > 0, 27, "get_gamma_table", "-> %#x, red ends at %u", kr, saved[0][256]);
		memcpy(test, saved, sizeof(test));
		test[1][128] ^= 1;
		kr = call(17, NULL, 0, test, sizeof(test), NULL, NULL, NULL, NULL);
		check(kr == 0, 17, "set_gamma_table", "-> %#x", kr);
		sz = sizeof(back);
		kr = call(27, NULL, 0, NULL, 0, NULL, NULL, back, &sz);
		check(kr == 0 && !memcmp(back, test, sizeof(back)), 27, "get_gamma_table", "-> %#x, the table just set back: %s", kr,
		    !memcmp(back, test, sizeof(back)) ? "same" : "DIFFERENT");
		kr = call(17, NULL, 0, saved, sizeof(saved), NULL, NULL, NULL, NULL);
		check(kr == 0, 17, "set_gamma_table", "-> %#x (restored)", kr);
	}
	{
		uint64_t m[9], cur[9], got[9];
		size_t sz = sizeof(m);

		kr = call(54, (uint64_t[]){ 15 }, 1, NULL, 0, NULL, NULL, m, &sz);
		check(kr == (kern_return_t) kIOReturnUnsupported, 54, "get_matrix(15, never set)", "-> %#x (want unsupported)", kr);
		sz = sizeof(cur);
		kern_return_t had = call(54, (uint64_t[]){ 9 }, 1, NULL, 0, NULL, NULL, cur, &sz);
		check(had == 0 || had == (kern_return_t) kIOReturnUnsupported, 54, "get_matrix(9)", "-> %#x", had);
		for (int i = 0; i < 9; i++) {
			m[i] = (i % 4 == 0) ? 0x100000000ULL : 0;
		}
		kr = call(55, (uint64_t[]){ 15 }, 1, m, sizeof(m), NULL, NULL, NULL, NULL);
		check(kr == 0, 55, "set_matrix(15)", "-> %#x", kr);
		sz = sizeof(got);
		kr = call(54, (uint64_t[]){ 15 }, 1, NULL, 0, NULL, NULL, got, &sz);
		check(kr == 0 && !memcmp(got, m, sizeof(m)), 54, "get_matrix(15)", "-> %#x, %s", kr,
		    !memcmp(got, m, sizeof(m)) ? "same" : "DIFFERENT");
		if (had == 0) {         /* the panel's live matrix (location 9) set again last, as it was */
			kr = call(55, (uint64_t[]){ 9 }, 1, cur, sizeof(cur), NULL, NULL, NULL, NULL);
			check(kr == 0, 55, "set_matrix(9)", "-> %#x (restored)", kr);
		}
		kr = call(55, (uint64_t[]){ 99 }, 1, m, sizeof(m), NULL, NULL, NULL, NULL);
		check(kr == (kern_return_t) kIOReturnBadArgument, 55, "set_matrix(99)", "-> %#x (want bad argument)", kr);
	}
	{
		n = 1;
		kr = call(57, NULL, 0, NULL, 0, out, &n, NULL, NULL);
		uint64_t mode = out[0];

		check(kr == 0, 57, "get_color_remap_mode", "-> %#x %llu", kr, mode);
		kr = call(51, (uint64_t[]){ 2 }, 1, NULL, 0, NULL, NULL, NULL, NULL);
		n = 1;
		call(57, NULL, 0, NULL, 0, out, &n, NULL, NULL);
		check(kr == 0 && out[0] == 2, 51, "set_color_remap_mode(2)", "-> %#x, read back %llu", kr, out[0]);
		kr = call(51, (uint64_t[]){ mode }, 1, NULL, 0, NULL, NULL, NULL, NULL);
		check(kr == 0, 51, "set_color_remap_mode", "-> %#x (restored %llu)", kr, mode);
	}
	{
		n = 1;
		kr = call(14, (uint64_t[]){ 0x10, 0x10 }, 2, NULL, 0, out, &n, NULL, NULL);
		uint64_t before = out[0];

		n = 1;
		kr = call(14, (uint64_t[]){ 0x10, before & 0x10 }, 2, NULL, 0, out, &n, NULL, NULL);
		check(kr == 0 && (out[0] & 0x10), 14, "set_flags", "-> %#x, the bit just set reads back (%#llx)", kr, out[0]);
	}
	scalars(50, "set_brightness_correction", 2, 0, 0);

	/* ---- notifications: every type iOS enables (off: callback 0) ---- */
	{
		static const uint32_t types[] = { 0, 1, 3, 4, 5, 6, 9, 11 };

		for (unsigned i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
			in[0] = 0;
			in[1] = 0;
			in[2] = types[i];
			in[3] = 0;
			kr = call(72, in, 4, NULL, 0, NULL, NULL, NULL, NULL);
			check(kr == 0, 72, "set_notify (off)", "type %u -> %#x", types[i], kr);
		}
	}

	/* ---- what a phone's panel has not: unsupported; Apple's reserved entries and past the table: errors ---- */
	scalars(10, "set_tvout_mode", 1, 0, kIOReturnUnsupported);
	scalars(23, "set_digital_out_mode", 2, 0, kIOReturnUnsupported);
	scalars(41, "enableInternalToExternalMirroring", 1, 0, kIOReturnUnsupported);
	scalars(47, "hdcp_send_request", 4, 0, kIOReturnUnsupported);
	scalars(93, "start_task", 1, 0, kIOReturnUnsupported);
	scalars(1, "reserved", 0, 0, kIOReturnUnsupported);
	scalars(60, "(empty)", 0, 0, kIOReturnUnsupported);
	scalars(101, "(past the table)", 0, 0, kIOReturnBadArgument);

	printf("fb_test: %d passed, %d failed\n", passed, failed);
	IOServiceClose(fb);
	return failed != 0;
}
