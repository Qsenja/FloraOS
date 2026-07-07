/* vt-test-client -- a diagnostic seatd-protocol client for manually
 * verifying floraseat's VT-bound switching (see floraseat.c's own header
 * comment). NOT part of FloraOS itself: build-rootfs.sh does not compile
 * or stage this, so it never ships in a real rootfs/ISO. It exists purely
 * so a real VT switch (`chvt`, or a physical Ctrl+Alt+Fn) can be observed
 * end-to-end without an actual Wayland compositor available to exercise
 * the path -- see tools/floraseat/floraseat.md's "Verification" section
 * for exactly how this was used to boot-test the VT-bound rewrite in real
 * QEMU (chvt between two VTs, each running one instance of this).
 *
 * Speaks just enough of the real seatd wire protocol (opcodes/structs
 * copied from floraseat.c itself, which is verified against upstream
 * kennylevinsen/seatd) to open a seat, open a DRM device, and print every
 * SERVER_* event it receives.
 *
 * Build (statically, so it needs no rootfs headers/libs to run against a
 * built FloraOS image -- see floraseat.md for the full manual-test recipe):
 *   gcc -O2 -static -o vt-test-client vt-test-client.c
 *
 * Usage: vt-test-client <label> [drm-device-path]
 * Every log line is prefixed "TC[<label>]:" so two instances' logs (piped
 * to separate files, one per VT) stay easy to tell apart.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define SEATD_SOCK_PATH "/run/seatd.sock"

#define CLIENT_EVENT(op) (op)
#define SERVER_EVENT(op) ((op) + (1 << 15))
#define CLIENT_OPEN_SEAT      CLIENT_EVENT(1)
#define CLIENT_CLOSE_SEAT     CLIENT_EVENT(2)
#define CLIENT_OPEN_DEVICE    CLIENT_EVENT(3)
#define CLIENT_CLOSE_DEVICE   CLIENT_EVENT(4)
#define CLIENT_DISABLE_SEAT   CLIENT_EVENT(5)
#define CLIENT_SWITCH_SESSION CLIENT_EVENT(6)
#define CLIENT_PING           CLIENT_EVENT(7)
#define SERVER_SEAT_OPENED      SERVER_EVENT(1)
#define SERVER_SEAT_CLOSED      SERVER_EVENT(2)
#define SERVER_DEVICE_OPENED    SERVER_EVENT(3)
#define SERVER_DEVICE_CLOSED    SERVER_EVENT(4)
#define SERVER_DISABLE_SEAT     SERVER_EVENT(5)
#define SERVER_ENABLE_SEAT      SERVER_EVENT(6)
#define SERVER_PONG             SERVER_EVENT(7)
#define SERVER_SESSION_SWITCHED SERVER_EVENT(8)
#define SERVER_SEAT_DISABLED    SERVER_EVENT(9)
#define SERVER_ERROR            SERVER_EVENT(0x7FFF)

struct proto_header { uint16_t opcode; uint16_t size; };

static const char *label;
static int sock;

static void logmsg(const char *fmt, ...) {
	printf("TC[%s]: ", label);
	va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
	printf("\n");
	fflush(stdout);
}

static void send_msg(uint16_t opcode, const void *payload, uint16_t len) {
	struct proto_header hdr = { .opcode = opcode, .size = len };
	write(sock, &hdr, sizeof hdr);
	if (len > 0) write(sock, payload, len);
}

static void open_device(const char *path) {
	uint16_t plen = (uint16_t)(strlen(path) + 1);
	struct proto_header hdr = { .opcode = CLIENT_OPEN_DEVICE, .size = (uint16_t)(sizeof(uint16_t) + plen) };
	write(sock, &hdr, sizeof hdr);
	write(sock, &plen, sizeof plen);
	write(sock, path, plen);
}

int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr, "usage: %s <label> [drm-device-path]\n", argv[0]); return 1; }
	label = argv[1];
	const char *device = argc > 2 ? argv[2] : "/dev/dri/card0";
	setlinebuf(stdout);

	sock = socket(AF_UNIX, SOCK_STREAM, 0);
	if (sock == -1) { perror("socket"); return 1; }
	struct sockaddr_un addr = { .sun_family = AF_UNIX };
	snprintf(addr.sun_path, sizeof addr.sun_path, "%s", SEATD_SOCK_PATH);
	if (connect(sock, (struct sockaddr *)&addr, sizeof addr) == -1) { perror("connect"); return 1; }
	logmsg("connected to %s", SEATD_SOCK_PATH);

	send_msg(CLIENT_OPEN_SEAT, NULL, 0);

	int device_opened = 0;
	for (;;) {
		struct pollfd pfd = { .fd = sock, .events = POLLIN };
		int rc = poll(&pfd, 1, 30000);
		if (rc == 0) { logmsg("idle timeout, exiting"); break; }
		if (rc == -1) { logmsg("poll error: %s", strerror(errno)); break; }

		struct proto_header hdr;
		char cbuf[256];
		union { char buf[256]; struct cmsghdr align; } cmsgbuf;
		struct iovec iov = { .iov_base = &hdr, .iov_len = sizeof hdr };
		struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1,
			.msg_control = cmsgbuf.buf, .msg_controllen = sizeof cmsgbuf.buf };
		ssize_t n = recvmsg(sock, &msg, 0);
		if (n <= 0) { logmsg("connection closed"); break; }

		if (hdr.size > 0) read(sock, cbuf, hdr.size);

		switch (hdr.opcode) {
		case SERVER_SEAT_OPENED:
			logmsg("SEAT_OPENED (%.*s)", hdr.size, cbuf + sizeof(uint16_t));
			break;
		case SERVER_ENABLE_SEAT:
			logmsg("ENABLE_SEAT");
			if (!device_opened) { open_device(device); device_opened = 1; }
			break;
		case SERVER_DISABLE_SEAT:
			logmsg("DISABLE_SEAT -- acking");
			send_msg(CLIENT_DISABLE_SEAT, NULL, 0);
			break;
		case SERVER_SEAT_DISABLED:
			logmsg("SEAT_DISABLED (ack confirmed)");
			break;
		case SERVER_DEVICE_OPENED: {
			int fd = -1;
			struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
			if (cmsg && cmsg->cmsg_type == SCM_RIGHTS) memcpy(&fd, CMSG_DATA(cmsg), sizeof fd);
			logmsg("DEVICE_OPENED fd=%d", fd);
			break;
		}
		case SERVER_ERROR: {
			int code; memcpy(&code, cbuf, sizeof code);
			logmsg("ERROR errno=%d (%s)", code, strerror(code));
			break;
		}
		case SERVER_SESSION_SWITCHED:
			logmsg("SESSION_SWITCHED ack");
			break;
		default:
			logmsg("unhandled opcode 0x%x", hdr.opcode);
			break;
		}
	}
	return 0;
}
