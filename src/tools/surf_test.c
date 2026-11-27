/*
 * surf_test: the IOSurface root user client (IOSurfaceRootUserClient) tried selector by selector, as iOS 27's
 * IOSurface.framework calls it (the 60-entry table), each answer checked against what Apple's IOSurface.kext does with
 * it. A surface is made through the framework, then looked up on a connection of this program's own; a shared event is
 * made there too. Transactions, data properties, attachments and the shared event's notification message are checked
 * end to end.
 *
 * usage: surf_test [-v]
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define kIOReturnUnsupported    0xe00002c7
#define kIOReturnBadArgument    0xe00002c2
#define kIOReturnOverrun        0xe00002e8

static io_connect_t root;
static int passed, failed, verbose;

static void
check(bool ok, uint32_t sel, const char *name, const char *fmt, ...)
{
	char what[200] = "";
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(what, sizeof(what), fmt, ap);
	va_end(ap);
	ok ? passed++ : failed++;
	if (!ok || verbose) {
		printf("%s %3u %-32s %s\n", ok ? "PASS" : "FAIL", sel, name, what);
	}
}

static kern_return_t
sc(uint32_t sel, const uint64_t *in, uint32_t nin, uint64_t *out, uint32_t nout)
{
	uint32_t n = nout;

	return IOConnectCallScalarMethod(root, sel, in, nin, out, out ? &n : NULL);
}

int
main(int argc, char **argv)
{
	verbose = argc > 1 && !strcmp(argv[1], "-v");

	/* a surface, made as an app makes one */
	int w = 64, h = 32, bpe = 4;
	CFNumberRef nw = CFNumberCreate(NULL, kCFNumberIntType, &w), nh = CFNumberCreate(NULL, kCFNumberIntType, &h),
	    nb = CFNumberCreate(NULL, kCFNumberIntType, &bpe);
	const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement };
	const void *vals[] = { nw, nh, nb };
	CFDictionaryRef props = CFDictionaryCreate(NULL, keys, vals, 3, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	IOSurfaceRef surf = IOSurfaceCreate(props);

	if (surf == NULL) {
		printf("surf_test: IOSurfaceCreate failed\n");
		return 1;
	}
	uint32_t sid = IOSurfaceGetID(surf);
	check(sid != 0, 0, "IOSurfaceCreate", "surface %u", sid);

	io_service_t svc = IOServiceGetMatchingService(0, IOServiceMatching("IOCoreSurfaceRoot"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &root) != KERN_SUCCESS) {
		printf("surf_test: no IOCoreSurfaceRoot to open\n");
		return 1;
	}

	uint64_t in[6], out[6];
	kern_return_t kr;
	static uint8_t big[4096];
	size_t sz;

	/* the surface on this connection: lookup */
	sz = sizeof(big);
	in[0] = sid;
	kr = IOConnectCallMethod(root, 4, in, 1, NULL, 0, NULL, NULL, big, &sz);
	check(kr == 0 && sz > 0, 4, "lookup_surface", "-> %#x, %zu bytes", kr, sz);

	/* lock / unlock as methods: { surface, options, 0 } */
	{
		uint32_t lk[3] = { sid, 0, 0 }, seed1 = 0, seed2 = 0;
		size_t s1 = sizeof(big), s2 = sizeof(seed2);

		kr = IOConnectCallMethod(root, 2, NULL, 0, lk, sizeof(lk), NULL, NULL, big, &s1);
		check(kr == 0, 2, "lock_surface", "-> %#x, %zu bytes", kr, s1);
		kr = IOConnectCallMethod(root, 3, NULL, 0, lk, sizeof(lk), NULL, NULL, &seed2, &s2);
		check(kr == 0 && s2 == 4, 3, "unlock_surface", "-> %#x, seed %u", kr, seed2);
		(void) seed1;
	}

	/* use counts */
	in[0] = sid; in[1] = 0;
	kr = sc(14, in, 2, NULL, 0);
	check(kr == 0, 14, "inc_sfc_use_count_for_category", "-> %#x", kr);
	kr = sc(16, in, 1, out, 1);
	check(kr == 0 && out[0] >= 1, 16, "get_surface_use_count", "-> %#x %llu", kr, out[0]);
	kr = sc(15, in, 2, NULL, 0);
	check(kr == 0, 15, "dec_sfc_use_count_for_category", "-> %#x", kr);

	/* YCbCr matrix, tiling */
	in[0] = sid; in[1] = 2;
	kr = sc(5, in, 2, NULL, 0);
	kr = sc(8, in, 1, out, 1);
	check(kr == 0 && out[0] == 2, 8, "get_ycbcrmatrix", "-> %#x %llu (set 2)", kr, out[0]);
	kr = sc(23, in, 1, out, 1);
	check(kr == 0 && out[0] == 0, 23, "is_tiled", "-> %#x %llu", kr, out[0]);
	kr = sc(25, in, 1, out, 1);
	check(kr == 0, 25, "get_tile_format", "-> %#x %llu", kr, out[0]);
	in[1] = 1;
	kr = sc(22, in, 2, NULL, 0);
	check(kr == (kern_return_t) kIOReturnUnsupported, 22, "set_tiled", "-> %#x (not a tileable surface)", kr);

	/* values through the framework (set_value / get_value / remove_value, iOS 27's 12-byte header): one removed, the
	 * other kept; all of them copied */
	{
		IOSurfaceSetValue(surf, CFSTR("akios.a"), CFSTR("one"));
		IOSurfaceSetValue(surf, CFSTR("akios.b"), CFSTR("two"));
		CFTypeRef a = IOSurfaceCopyValue(surf, CFSTR("akios.a"));
		bool aok = a != NULL && CFGetTypeID(a) == CFStringGetTypeID() && CFEqual(a, CFSTR("one"));

		check(aok, 10, "get_value(akios.a)", "%s", aok ? "\"one\"" : "WRONG");
		if (a) CFRelease(a);
		IOSurfaceRemoveValue(surf, CFSTR("akios.a"));
		CFTypeRef a2 = IOSurfaceCopyValue(surf, CFSTR("akios.a")), b = IOSurfaceCopyValue(surf, CFSTR("akios.b"));
		check(a2 == NULL && b != NULL && CFEqual(b, CFSTR("two")), 11, "remove_value(akios.a)",
		    "a %s, b %s", a2 ? "still there" : "gone", b ? "kept" : "GONE TOO");
		if (a2) CFRelease(a2);
		if (b) CFRelease(b);
		CFDictionaryRef all = IOSurfaceCopyAllValues(surf);
		check(all != NULL && CFGetTypeID(all) == CFDictionaryGetTypeID() && CFDictionaryContainsKey(all, CFSTR("akios.b")),
		    10, "get_value(all)", "%s", all ? "a dictionary with akios.b" : "NULL");
		if (all) CFRelease(all);
	}

	/* bulk attachments: through the framework, read back on this connection */
	{
		IOSurfaceSetValue(surf, CFSTR("IOSurfaceYCbCrMatrix"), CFSTR("ITU_R_709_2"));
		uint8_t att[0xa0];
		size_t s = sizeof(att);

		in[0] = sid;
		kr = IOConnectCallMethod(root, 28, in, 1, NULL, 0, NULL, NULL, att, &s);
		check(kr == 0 && s == 0xa0, 28, "get_bulk_attachments", "-> %#x, %zu bytes", kr, s);
		in[1] = ~0ULL;
		kr = sc(56, in, 2, NULL, 0);
		check(kr == 0, 56, "remove_bulk_attachments", "-> %#x", kr);
	}

	/* data properties: index 0-5, up to 1024 bytes */
	{
		const char data[] = "akios data property";
		char back[64] = "";
		size_t s = sizeof(back);

		in[0] = sid; in[1] = 3;
		kr = IOConnectCallMethod(root, 50, in, 2, data, sizeof(data), NULL, NULL, NULL, NULL);
		check(kr == 0, 50, "set_data_property(3)", "-> %#x", kr);
		uint32_t n = 1;
		kr = IOConnectCallMethod(root, 51, in, 2, NULL, 0, out, &n, back, &s);
		check(kr == 0 && out[0] == sizeof(data) && !strcmp(back, data), 51, "get_data_property(3)", "-> %#x, %llu bytes \"%s\"",
		    kr, out[0], back);
		s = 4;
		n = 1;
		kr = IOConnectCallMethod(root, 51, in, 2, NULL, 0, out, &n, back, &s);
		check(kr == (kern_return_t) kIOReturnOverrun, 51, "get_data_property, too small", "-> %#x (want overrun)", kr);
		in[1] = 6;
		kr = IOConnectCallMethod(root, 50, in, 2, data, sizeof(data), NULL, NULL, NULL, NULL);
		check(kr == (kern_return_t) kIOReturnBadArgument, 50, "set_data_property(6)", "-> %#x (want bad argument)", kr);
		kr = sc(52, in, 1, NULL, 0);
		in[1] = 3;
		n = 1;
		s = sizeof(back);
		kr = IOConnectCallMethod(root, 51, in, 2, NULL, 0, out, &n, back, &s);
		check(kr == 0 && out[0] == 0, 52, "clear_data_properties", "-> then size %llu", out[0]);
	}

	/* a shared event: create, signal, query, wait */
	uint64_t ev[2] = { 0, 0 };
	in[0] = 0;
	kr = sc(36, in, 1, ev, 2);
	check(kr == 0 && ev[0] != 0 && ev[1] != 0, 36, "create_shared_event", "-> %#x port %#llx at %#llx", kr, ev[0], ev[1]);
	volatile uint64_t *value = (volatile uint64_t *) (uintptr_t) ev[1];
	in[0] = ev[0]; in[1] = 5;
	kr = sc(37, in, 2, NULL, 0);
	check(kr == 0 && *value == 5, 37, "signal_shared_event", "-> %#x, the value reads %llu", kr, *value);
	in[0] = ev[0]; in[1] = 5; in[2] = 0;
	kr = sc(45, in, 3, NULL, 0);
	check(kr == 0, 45, "wait_shared_event(5, reached)", "-> %#x", kr);

	/* transactions: a write at 10 (not done), a read at 4 (done already: not kept) */
	in[0] = sid; in[1] = ev[0]; in[2] = 10; in[3] = 1;
	kr = sc(57, in, 4, NULL, 0);
	check(kr == 0, 57, "append_transaction(write, 10)", "-> %#x", kr);
	in[2] = 4; in[3] = 0;
	kr = sc(57, in, 4, NULL, 0);
	check(kr == 0, 57, "append_transaction(read, 4)", "-> %#x", kr);
	{
		struct { uint64_t event, value; uint8_t write, pad[7]; } tx[4];

		memset(tx, 0, sizeof(tx));
		in[0] = sid; in[1] = (uint64_t) (uintptr_t) tx; in[2] = 4; in[3] = 0; in[4] = 0;
		kr = sc(58, in, 5, out, 3);
		check(kr == 0 && out[0] == 1 && out[1] == 1 && tx[0].value == 10 && tx[0].write == 1, 58, "query_transaction_list",
		    "-> %#x copied %llu all %llu matching %llu; [0] value %llu write %u", kr, out[0], out[1], out[2], tx[0].value,
		    tx[0].write);
		in[3] = 2;
		kr = sc(58, in, 5, out, 3);
		check(kr == 0 && out[2] == 0, 58, "query_transaction_list(no writes)", "-> matching %llu", out[2]);
	}
	in[0] = ev[0]; in[1] = 10;
	sc(37, in, 2, NULL, 0);
	in[0] = sid;
	kr = sc(59, in, 1, NULL, 0);
	in[1] = 0; in[2] = 0; in[3] = 0; in[4] = 0;
	sc(58, in, 5, out, 3);
	check(kr == 0 && out[1] == 0, 59, "prune_transaction_list", "-> %#x, then %llu left (the event reached 10)", kr, out[1]);

	/* the shared event's notification: a port, a request at 20, a signal, the message */
	{
		mach_port_t port = MACH_PORT_NULL;
		uint64_t ref[8] = { 0 };

		mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
		ref[2] = 0x1234;        /* the refcon */
		kr = IOConnectCallAsyncScalarMethod(root, 40, port, ref, 3, NULL, 0, NULL, NULL);
		check(kr == 0, 40, "add_shared_event_notify_port", "-> %#x", kr);
		in[0] = ev[0]; in[1] = 0x1234; in[2] = 0xaa; in[3] = 0xbb; in[4] = 20;
		kr = sc(39, in, 5, NULL, 0);
		check(kr == 0, 39, "notify_shared_event(20)", "-> %#x", kr);
		in[0] = ev[0]; in[1] = 20;
		sc(37, in, 2, NULL, 0);
		struct {
			mach_msg_header_t h;
			uint8_t body[256];
		} msg;
		memset(&msg, 0, sizeof(msg));
		kr = mach_msg(&msg.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(msg), port, 1000, MACH_PORT_NULL);
		/* IOKit's async reply: header (24), notification header (size, type, 8 reference words: 72), result (4), the
		 * arguments (4 x 8) at 100, then padding */
		uint64_t args[4];

		memcpy(args, (uint8_t *) &msg + 100, sizeof(args));
		check(kr == 0 && args[0] == 0xbb && args[1] == 0xaa && args[2] == 20, 39, "the notification",
		    "-> %#x, %u bytes, args %#llx %#llx %llu", kr, msg.h.msgh_size, kr == 0 ? args[0] : 0, kr == 0 ? args[1] : 0,
		    kr == 0 ? args[2] : 0);
		in[0] = 0x1234;
		kr = sc(41, in, 1, NULL, 0);
		check(kr == 0, 41, "remove_shared_event_notify_port", "-> %#x", kr);
		kr = sc(41, in, 1, NULL, 0);
		check(kr == (kern_return_t) kIOReturnBadArgument, 41, "remove (again)", "-> %#x (want bad argument)", kr);
	}

	/* signal operation 0: at once (no device work here) */
	in[0] = sid; in[1] = 0; in[2] = ev[0]; in[3] = 30;
	kr = sc(42, in, 4, NULL, 0);
	check(kr == 0 && *value == 30, 42, "signal_shared_event_operation(0)", "-> %#x, value %llu", kr, *value);

	/* what is not here: Apple's answers without it */
	kr = sc(32, NULL, 0, out, 1);
	check(kr == (kern_return_t) 0xe00002bd, 32, "get_graphics_comm_page_address", "-> %#x (want no memory: none)", kr);
	in[0] = sid;
	kr = sc(46, in, 1, NULL, 0);
	check(kr == (kern_return_t) kIOReturnUnsupported, 46, "create_memory_pool", "-> %#x", kr);
	kr = sc(60, NULL, 0, NULL, 0);
	check(kr == (kern_return_t) kIOReturnBadArgument, 60, "(past the table)", "-> %#x", kr);

	in[0] = sid;
	kr = sc(1, in, 1, NULL, 0);
	check(kr == 0, 1, "release_surface", "-> %#x", kr);
	printf("surf_test: %d passed, %d failed\n", passed, failed);
	IOServiceClose(root);
	CFRelease(surf);
	return failed != 0;
}
