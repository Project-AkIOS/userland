/*
 * libakios.bluetoothd.dylib: code of ours inside BlueTool (userland.toml's inject), for Bluetooth on a phone whose controller
 * the kernel switches on and loads itself (xnu's bsd/dev/hakios.akita_bt.c with bt=2, hakios.bthost.c,
 * iokit/Kernel/AppleBluetoothModule.cpp).
 *
 * STOPGAP (11-26): BlueTool cannot run here unmodified -- it picks its firmware and boot script from a table built into
 * it by HW model and chip, and the table has no BCM4383 (BCM4350/4355 UART and BCM4377/4378/4387/4388 PCIe only); its
 * override scripts are honoured only on Vendor and Internal installs. So it is answered for. The better stand-in, when
 * there is time: a com.apple.BlueTool responder of its own that asks AppleBluetoothModule's user client for the
 * controller's state instead of an injection into Apple's binary (research of 11-26, 4.3).
 *
 * iOS's bluetoothd asks BlueTool, over the service com.apple.BlueTool, to "boot" and "init" the controller: on an
 * iPhone BlueTool loads Broadcom's firmware for that iPhone's chip over a serial port and sets it up from the device
 * tree. Here there is no such port and nothing left to load, and BlueTool would time out. Inside the real process the
 * service is ours instead and answers each request as done -- result 0, manufacturer 15 (Broadcom), a firmware name.
 * (Upstream's way on its MediaTek phone: branch mtk, src/inject.c's bluetool_serves.) Each request is said on the
 * console, as it came, so that what bluetoothd asks is seen.
 */
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* (libxpc's, declared here: the SDK this is built with has no xpc/xpc.h) */
typedef void *xpc_object_t;
typedef void *xpc_connection_t;
extern const struct _xpc_type_s _xpc_type_connection, _xpc_type_dictionary;
extern xpc_connection_t xpc_connection_create_mach_service(const char *name, dispatch_queue_t targetq, uint64_t flags);
extern void xpc_connection_set_event_handler(xpc_connection_t connection, void (^handler)(xpc_object_t object));
extern void xpc_connection_resume(xpc_connection_t connection);
extern void xpc_connection_send_message(xpc_connection_t connection, xpc_object_t message);
extern const struct _xpc_type_s *xpc_get_type(xpc_object_t object);
extern xpc_object_t xpc_dictionary_create_reply(xpc_object_t original);
extern void xpc_dictionary_set_int64(xpc_object_t xdict, const char *key, int64_t value);
extern void xpc_dictionary_set_string(xpc_object_t xdict, const char *key, const char *string);
extern char *xpc_copy_description(xpc_object_t object);
extern void xpc_release(xpc_object_t object);

static void
say(const char *line)
{
	int fd = open("/dev/console", O_WRONLY);

	if (fd >= 0) {
		(void)write(fd, line, strlen(line));
		close(fd);
	}
}

__attribute__((constructor))
static void
bluetool_serves(void)
{
	const char *name = getprogname();

	if (name == NULL || strcmp(name, "BlueTool") != 0) {
		return;
	}
	xpc_connection_t listener = xpc_connection_create_mach_service("com.apple.BlueTool", NULL, 1 /* a listener */);

	say("hakios: BlueTool: com.apple.BlueTool is ours (the kernel has the controller on, its firmware loaded)\n");
	xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
		if (xpc_get_type(peer) != &_xpc_type_connection) {
			return;
		}
		xpc_connection_set_event_handler((xpc_connection_t)peer, ^(xpc_object_t message) {
			if (xpc_get_type(message) != &_xpc_type_dictionary) {
				return;
			}
			char *text = xpc_copy_description(message), line[600];

			snprintf(line, sizeof(line), "hakios: BlueTool: asked %s\n", text != NULL ? text : "(?)");
			say(line);
			free(text);
			xpc_object_t reply = xpc_dictionary_create_reply(message);

			if (reply != NULL) {
				xpc_dictionary_set_int64(reply, "result", 0);
				xpc_dictionary_set_int64(reply, "manufacturer", 15);
				xpc_dictionary_set_string(reply, "firmware", "BCM4383A3");
				xpc_dictionary_set_string(reply, "output", "");
				xpc_connection_send_message((xpc_connection_t)peer, reply);
				xpc_release(reply);
			}
		});
		xpc_connection_resume((xpc_connection_t)peer);
	});
	xpc_connection_resume(listener);
	dispatch_main();
}

/*
 * (11-26) The wait inside bluetoothd that was here (wait_for_transport: up to two minutes until the kernel control
 * com.apple.uart.sk.bluetooth existed) is gone: the kernel publishes the control as soon as BSD is up and holds an early
 * connection until the controller answers (hakios.bthost.c, skel_wait_for_controller). bluetoothd runs as it is.
 */
