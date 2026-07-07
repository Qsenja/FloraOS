/* floraseat -- FloraOS's own seat-management daemon, written from scratch
 * instead of building seatd (which means adding meson+ninja to the build
 * host -- FloraOS deliberately avoids cmake/meson everywhere else, see
 * mbedtls's recipe/ARCHITECTURE.md). Same "small, auditable, purpose-built
 * instead of vendoring" reasoning as fau's alpm fallback and floralogin.
 *
 * Not a from-scratch *protocol*, though: it speaks the real seatd wire
 * protocol (verified against upstream kennylevinsen/seatd's
 * include/protocol.h, seatd/client.c, seatd/seat.c, common/drm.c,
 * common/evdev.c, common/hidraw.c -- fetched and read directly, not
 * reconstructed from memory) so that libseat -- which FloraOS does NOT
 * build itself, it arrives precompiled inside wlroots/mesa/sway/mango via
 * fau's alpm (Arch/Artix repo) fallback -- talks to this unmodified. Same
 * idea as fau's own alpm fallback reading pacman's *data formats* without
 * vendoring pacman's code: here we implement seatd's *wire protocol*
 * without vendoring seatd's C source tree.
 *
 * Scope, deliberately smaller than real seatd:
 *   - One seat ("seat0"), VT-bound (see the "VT-bound seat" section below)
 *     -- real seatd only ever creates one seat too (see its own server.c:
 *     "TODO: create more seats"), so this isn't a cut corner relative to
 *     upstream.
 *   - Device allowlist: /dev/dri/ prefix, /dev/input/event prefix,
 *     /dev/hidraw prefix only,
 *     matching real seatd's path_is_drm/path_is_evdev/path_is_hidraw
 *     (common/drm.c, common/evdev.c, common/hidraw.c upstream) --
 *     wscons (BSD console) skipped, not relevant on Linux. Path is
 *     realpath(3)-canonicalized *before* the prefix check, same as
 *     upstream, specifically so a symlink or ../ can't be used to open
 *     something outside the allowlist through a name that merely starts
 *     with an allowed prefix.
 *   - Access control is socket-permission-based, same model as real
 *     seatd: /run/seatd.sock is created 0660 root:seat. Only root logs in
 *     today, so this is trivially satisfied; the moment FloraOS gets a
 *     second, non-root login, `usermod -aG seat <user>` (once user
 *     management exists -- no useradd/usermod yet either, see
 *     ARCHITECTURE.md's own TODO list) is the entire migration path. No
 *     uid check inside the daemon itself, matching upstream.
 *   - I/O model: poll(2) over plain blocking sockets rather than porting
 *     seatd's own non-blocking ring-buffer connection layer. Every message
 *     in this protocol is well under 300 bytes on a local AF_UNIX
 *     SOCK_STREAM socket -- once poll(2) says a socket is readable, a
 *     blocking read of the few bytes needed for one message does not
 *     block in practice. Documented simplification, not a hidden one.
 *
 * Wire protocol reference (opcodes, struct layouts) is the public
 * interface real seatd/libseat use to talk to each other, not seatd's
 * implementation -- reproduced here (not copy-pasted from seatd's own
 * protocol.h, though the layout must match it exactly byte-for-byte or
 * nothing fetched via `fau install` can ever draw a pixel).
 *
 * VT-bound seat: a client's session number IS the VT number it opened the
 * seat on (queried via VT_GETSTATE on /dev/tty0 at CLIENT_OPEN_SEAT time),
 * not an arbitrary counter -- this is real seatd's own VT-bound convention
 * (verified directly against upstream's common/terminal.c and seatd/seat.c,
 * fetched and read, not reconstructed from memory), not invented here.
 * Activating a client puts its VT into VT_SETMODE(VT_PROCESS) with
 * relsig=SIGUSR1/acqsig=SIGUSR2, keyboard raw-passthrough (KDSKBMODE
 * K_OFF), and KD_GRAPHICS -- the kernel then notifies this process instead
 * of switching immediately whenever anything (a physical Ctrl+Alt+Fn, or
 * this daemon's own CLIENT_SWITCH_SESSION handling of a libseat client's
 * request) tries to change the active VT. SIGUSR1 (release) disables the
 * outgoing client (revoke its devices, ST_PENDING_DISABLE, wait for its
 * CLIENT_DISABLE_SEAT ack, same as any other disable) and acks the release
 * (VT_RELDISP, 1) so the kernel proceeds with the actual switch; SIGUSR2
 * (acquire), delivered once the switch completes, acks the acquire
 * (VT_RELDISP, VT_ACKACQ) and activates whichever client (if any) claims
 * the newly-current VT. CLIENT_SWITCH_SESSION itself does not touch any
 * client state directly any more -- it only issues ioctl(VT_ACTIVATE,
 * <target>) and lets the release/acquire signals drive the actual handoff,
 * the same "one single mechanism, not two racing ones" reasoning upstream's
 * own seat_set_next_session comment gives for this. Both signals are
 * delivered via signalfd(2) (blocked from normal delivery, read as another
 * pollable fd in the same poll(2) loop as client sockets) rather than a
 * classic async signal handler, so there's no async-signal-safety
 * tightrope to walk -- SIGTERM/SIGINT stay on the simpler classic-handler
 * path (see on_term below), since nothing here needs them to interrupt a
 * blocking read the way EINTR from poll(2) already handles.
 *
 * Deliberately simpler than upstream in one place: seat_add_client
 * upstream refuses to add *any* new client while *any* client anywhere on
 * the seat is active and not already mid-disable, regardless of which VT
 * either one is on. This file only refuses a new client that targets the
 * exact same VT another still-live client already claims -- the one real
 * conflict (two clients fighting over one VT) -- since blocking unrelated
 * VTs from ever adding a session while a different VT is merely active
 * elsewhere doesn't match this project's own multi-VT use case. Documented
 * simplification, not a hidden one, same standard as this file's other
 * disclosed simplifications.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#include <linux/input.h>   /* EVIOCREVOKE */
#include <linux/hidraw.h>  /* HIDIOCREVOKE, guarded below */
#include <linux/kd.h>      /* KDSKBMODE, KDSETMODE */
#include <linux/vt.h>      /* VT_GETSTATE, VT_SETMODE, VT_ACTIVATE, VT_RELDISP */

#define SEATD_SOCK_PATH "/run/seatd.sock"
#define SEAT_NAME "seat0"
#define MAX_CLIENTS 32
#define MAX_PATH_LEN 256
#define MAX_SEAT_LEN 64
#define MAX_SEAT_DEVICES 128

/* --- wire protocol: must match kennylevinsen/seatd's include/protocol.h
 * exactly (opcode numbers and struct layouts are the actual ABI). --- */
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

struct proto_header {
	uint16_t opcode;
	uint16_t size;
};
struct proto_client_open_device {
	uint16_t path_len; /* NUL-terminated path follows, path_len bytes */
};
struct proto_client_close_device {
	int device_id;
};
struct proto_client_switch_session {
	int session;
};
struct proto_server_seat_opened {
	uint16_t seat_name_len; /* NUL-terminated name follows */
};
struct proto_server_device_opened {
	int device_id; /* one fd follows via SCM_RIGHTS */
};
struct proto_server_error {
	int error_code;
};

/* --- daemon state --- */

enum device_type { DEV_DRM, DEV_EVDEV, DEV_HIDRAW };

struct device {
	struct device *next;
	/* PATH_MAX, not MAX_PATH_LEN: realpath(3) can expand a symlink to
	 * something longer than the client's original (<=MAX_PATH_LEN)
	 * request path, same reason real seatd's own seat_device.path is a
	 * heap strdup() of a PATH_MAX-sized sanitized_path rather than
	 * reusing the wire protocol's path length cap. */
	char path[PATH_MAX];
	int fd;
	int device_id;
	int refcount;
	enum device_type type;
	bool active; /* false while deactivated (session switched away) */
};

enum client_state { ST_NEW, ST_ACTIVE, ST_PENDING_DISABLE, ST_DISABLED, ST_CLOSED };

struct client {
	bool used;
	int fd;
	pid_t pid;
	uid_t uid;
	gid_t gid;
	int session; /* -1 until open_seat, then a small positive int */
	enum client_state state;
	struct device *devices;
};

static struct client clients[MAX_CLIENTS];
static struct client *active_client; /* NULL if no client currently enabled */
/* The currently-active VT (a client's session number, once it has one, IS
 * this -- see this file's header comment). -1 during the narrow window
 * between a release ack and the matching acquire signal, mirroring real
 * seatd's own seat->cur_vt sentinel for "mid-switch, unknown". */
static int g_cur_vt = -1;
static volatile sig_atomic_t running = 1;

static void log_msg(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "[floraseat] ");
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
}

static void on_term(int sig) {
	(void)sig;
	running = 0;
}

/* --- device allowlist, matching real seatd's path_is_drm/evdev/hidraw --- */

static bool has_prefix(const char *s, const char *prefix) {
	return strncmp(s, prefix, strlen(prefix)) == 0;
}

static bool classify_device(const char *canon_path, enum device_type *type) {
	if (has_prefix(canon_path, "/dev/dri/")) {
		*type = DEV_DRM;
		return true;
	}
	if (has_prefix(canon_path, "/dev/input/event")) {
		*type = DEV_EVDEV;
		return true;
	}
	if (has_prefix(canon_path, "/dev/hidraw")) {
		*type = DEV_HIDRAW;
		return true;
	}
	return false;
}

/* DRM_IOCTL_SET_MASTER/DROP_MASTER: from libdrm, avoiding a build dependency
 * on libdrm's headers just for two ioctl numbers (same reasoning as real
 * seatd's own common/drm.c, which hardcodes these instead of including
 * libdrm at all). */
#define DRM_IOCTL_BASE 'd'
#define DRM_IO(nr) _IO(DRM_IOCTL_BASE, nr)
#define DRM_IOCTL_SET_MASTER DRM_IO(0x1e)
#define DRM_IOCTL_DROP_MASTER DRM_IO(0x1f)

static void device_activate(struct device *d) {
	if (d->active) return;
	switch (d->type) {
	case DEV_DRM:
		if (ioctl(d->fd, DRM_IOCTL_SET_MASTER, 0) == -1)
			log_msg("warn: could not set drm master on %s: %s", d->path, strerror(errno));
		break;
	case DEV_EVDEV:
	case DEV_HIDRAW:
		/* Nothing to re-enable on evdev/hidraw -- once revoked, the
		 * client must reopen (matches upstream: EVIOCREVOKE is
		 * one-shot per fd, see seat_activate_device in real seat.c
		 * returning EINVAL for these types). */
		break;
	}
	d->active = true;
}

static void device_deactivate(struct device *d) {
	if (!d->active) return;
	switch (d->type) {
	case DEV_DRM:
		if (ioctl(d->fd, DRM_IOCTL_DROP_MASTER, 0) == -1)
			log_msg("warn: could not drop drm master on %s: %s", d->path, strerror(errno));
		break;
	case DEV_EVDEV:
#ifdef EVIOCREVOKE
		if (ioctl(d->fd, EVIOCREVOKE, NULL) == -1)
			log_msg("warn: could not revoke evdev %s: %s", d->path, strerror(errno));
#endif
		break;
	case DEV_HIDRAW:
#ifdef HIDIOCREVOKE
		if (ioctl(d->fd, HIDIOCREVOKE, NULL) == -1)
			log_msg("warn: could not revoke hidraw %s: %s", d->path, strerror(errno));
#endif
		break;
	}
	d->active = false;
}

/* --- VT-bound seat support: ioctl(2)/tty mechanics, verified directly
 * against kennylevinsen/seatd's own common/terminal.c and seatd/seat.c
 * (fetched and read, not reconstructed from memory) -- real seatd's actual
 * implementation, folded into this file's single-TU style rather than
 * split across separate terminal.c/seat.c files. See this file's header
 * comment for the overall design. --- */

static int vt_tty_open(int vt) {
	char path[32];
	snprintf(path, sizeof path, "/dev/tty%d", vt);
	int fd = open(path, O_RDWR | O_NOCTTY);
	if (fd == -1) log_msg("warn: could not open %s: %s", path, strerror(errno));
	return fd;
}

/* VT_GETSTATE on /dev/tty0 (the "whichever VT is currently active" alias)
 * -- returns -1 on failure, never 0 (VT numbering starts at 1). */
static int vt_get_current(void) {
	int fd = open("/dev/tty0", O_RDWR | O_NOCTTY);
	if (fd == -1) { log_msg("warn: could not open /dev/tty0: %s", strerror(errno)); return -1; }
	struct vt_stat st;
	int rc = ioctl(fd, VT_GETSTATE, &st);
	close(fd);
	if (rc == -1) { log_msg("warn: VT_GETSTATE failed: %s", strerror(errno)); return -1; }
	return st.v_active;
}

/* Puts a VT into (or out of) process-switching mode: while enabled, the
 * kernel signals this process (SIGUSR1 to release, SIGUSR2 to acquire)
 * instead of switching immediately, stops the kernel's own text-console
 * rendering/echo on it (KD_GRAPHICS) and keyboard translation (KDSKBMODE
 * K_OFF, so a graphical client reads raw evdev via the device fds this
 * daemon already hands out, instead of the kernel's VT layer consuming
 * keypresses first). Idempotent -- safe to call again on an already-
 * (de)activated VT, which real seatd's own vt_open does on every
 * reactivation, not just the first. */
static void vt_configure(int vt, bool graphical) {
	int fd = vt_tty_open(vt);
	if (fd == -1) return;
	struct vt_mode mode = {
		.mode = graphical ? VT_PROCESS : VT_AUTO,
		.waitv = 0,
		.relsig = graphical ? SIGUSR1 : 0,
		.acqsig = graphical ? SIGUSR2 : 0,
		.frsig = 0,
	};
	if (ioctl(fd, VT_SETMODE, &mode) == -1)
		log_msg("warn: VT_SETMODE(%s) on vt%d failed: %s",
			graphical ? "VT_PROCESS" : "VT_AUTO", vt, strerror(errno));
	if (ioctl(fd, KDSKBMODE, graphical ? K_OFF : K_UNICODE) == -1)
		log_msg("warn: KDSKBMODE on vt%d failed: %s", vt, strerror(errno));
	if (ioctl(fd, KDSETMODE, graphical ? KD_GRAPHICS : KD_TEXT) == -1)
		log_msg("warn: KDSETMODE on vt%d failed: %s", vt, strerror(errno));
	close(fd);
}

/* Acks a pending VT_PROCESS release (releasing=true, VT_RELDISP 1 -- "go
 * ahead") or a just-completed acquire (releasing=false, VT_RELDISP
 * VT_ACKACQ). Required in both directions or the kernel leaves the VT
 * switch machinery wedged waiting for this process. */
static void vt_ack(int vt, bool releasing) {
	int fd = vt_tty_open(vt);
	if (fd == -1) return;
	if (ioctl(fd, VT_RELDISP, releasing ? 1 : VT_ACKACQ) == -1)
		log_msg("warn: VT_RELDISP ack (%s) on vt%d failed: %s",
			releasing ? "release" : "acquire", vt, strerror(errno));
	close(fd);
}

/* --- wire I/O helpers ---
 * See the file header: blocking read/write of a few hundred bytes right
 * after poll(2) reports readability, not a general nonblocking framer. */

static int write_all(int fd, const void *buf, size_t len) {
	const char *p = buf;
	size_t left = len;
	while (left > 0) {
		ssize_t n = write(fd, p, left);
		if (n == -1) {
			if (errno == EINTR) continue;
			return -1;
		}
		p += n;
		left -= (size_t)n;
	}
	return 0;
}

static int read_all(int fd, void *buf, size_t len) {
	char *p = buf;
	size_t left = len;
	while (left > 0) {
		ssize_t n = read(fd, p, left);
		if (n == 0) { errno = ECONNRESET; return -1; }
		if (n == -1) {
			if (errno == EINTR) continue;
			return -1;
		}
		p += n;
		left -= (size_t)n;
	}
	return 0;
}

static int send_msg(struct client *c, uint16_t opcode, const void *payload, uint16_t len) {
	struct proto_header hdr = { .opcode = opcode, .size = len };
	if (write_all(c->fd, &hdr, sizeof hdr) == -1) return -1;
	if (len > 0 && write_all(c->fd, payload, len) == -1) return -1;
	return 0;
}

static int send_msg2(struct client *c, uint16_t opcode, const void *p1, uint16_t l1,
		      const void *p2, uint16_t l2) {
	struct proto_header hdr = { .opcode = opcode, .size = (uint16_t)(l1 + l2) };
	if (write_all(c->fd, &hdr, sizeof hdr) == -1) return -1;
	if (l1 > 0 && write_all(c->fd, p1, l1) == -1) return -1;
	if (l2 > 0 && write_all(c->fd, p2, l2) == -1) return -1;
	return 0;
}

static int send_error(struct client *c, int errcode) {
	struct proto_server_error msg = { .error_code = errcode };
	return send_msg(c, SERVER_ERROR, &msg, sizeof msg);
}

/* Sends SERVER_DEVICE_OPENED plus one fd via SCM_RIGHTS in the same
 * sendmsg(2) -- real libseat expects the fd to arrive alongside this
 * specific message, not as a separate write. */
static int send_device_opened(struct client *c, int device_id, int fd) {
	struct proto_header hdr = { .opcode = SERVER_DEVICE_OPENED, .size = sizeof(int) };
	struct proto_server_device_opened body = { .device_id = device_id };

	char iobuf[sizeof hdr + sizeof body];
	memcpy(iobuf, &hdr, sizeof hdr);
	memcpy(iobuf + sizeof hdr, &body, sizeof body);

	union {
		char buf[CMSG_SPACE(sizeof(int))];
		struct cmsghdr align;
	} cmsgbuf;
	memset(&cmsgbuf, 0, sizeof cmsgbuf);

	struct iovec iov = { .iov_base = iobuf, .iov_len = sizeof iobuf };
	struct msghdr msg = {
		.msg_iov = &iov,
		.msg_iovlen = 1,
		.msg_control = cmsgbuf.buf,
		.msg_controllen = sizeof cmsgbuf.buf,
	};
	struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
	cmsg->cmsg_level = SOL_SOCKET;
	cmsg->cmsg_type = SCM_RIGHTS;
	cmsg->cmsg_len = CMSG_LEN(sizeof(int));
	memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));

	ssize_t n;
	do {
		n = sendmsg(c->fd, &msg, MSG_NOSIGNAL);
	} while (n == -1 && errno == EINTR);
	return n == -1 ? -1 : 0;
}

/* --- client/device bookkeeping --- */

static struct client *client_alloc(void) {
	for (int i = 0; i < MAX_CLIENTS; i++)
		if (!clients[i].used) return &clients[i];
	return NULL;
}

static void client_close_all_devices(struct client *c) {
	struct device *d = c->devices;
	while (d) {
		struct device *next = d->next;
		device_deactivate(d);
		close(d->fd);
		free(d);
		d = next;
	}
	c->devices = NULL;
}

/* Picks and enables the client claiming the currently-active VT, if the
 * seat is free and one is waiting -- matches real seat_activate's
 * vt_bound branch (this file's seat is always VT-bound, see the header
 * comment): a client whose session doesn't match g_cur_vt is on some
 * *other* VT and has nothing to do with what's on screen right now. */
static void seat_activate_next(void) {
	if (active_client != NULL) return;
	if (g_cur_vt == -1) return; /* mid-switch -- wait for the acquire signal */
	for (int i = 0; i < MAX_CLIENTS; i++) {
		struct client *c = &clients[i];
		if (c->used && c->session == g_cur_vt && (c->state == ST_NEW || c->state == ST_DISABLED)) {
			vt_configure(c->session, true);
			for (struct device *d = c->devices; d; d = d->next) device_activate(d);
			if (send_msg(c, SERVER_ENABLE_SEAT, NULL, 0) == -1) {
				log_msg("could not send enable_seat to session %d", c->session);
				continue;
			}
			c->state = ST_ACTIVE;
			active_client = c;
			log_msg("session %d activated on %s (vt%d)", c->session, SEAT_NAME, c->session);
			return;
		}
	}
}

/* Deactivates the currently active client's devices and asks it to
 * disable (ST_PENDING_DISABLE, SERVER_DISABLE_SEAT) without clearing
 * active_client -- that only happens once the client's own
 * CLIENT_DISABLE_SEAT ack arrives (handle_disable_seat below), same as
 * real seatd's seat_disable_client/seat_ack_disable_client split. Shared
 * by the VT release-signal handler (on_vt_release) below. */
static void disable_active_client(void) {
	struct client *c = active_client;
	for (struct device *d = c->devices; d; d = d->next) device_deactivate(d);
	c->state = ST_PENDING_DISABLE;
	send_msg(c, SERVER_DISABLE_SEAT, NULL, 0);
	log_msg("session %d disabling (vt switch)", c->session);
}

/* Shared teardown for both a full client disconnect (client_destroy) and
 * an explicit CLIENT_CLOSE_SEAT while the connection itself stays open --
 * real seatd's own handle_close_seat calls the identical seat_remove_client
 * for the same reason, so this isn't duplicated between the two callers.
 * Leaves c->fd/c->used untouched; callers decide what happens to the
 * connection itself. */
static void seat_remove_client(struct client *c) {
	int session = c->session;
	enum client_state prev_state = c->state;
	client_close_all_devices(c);
	bool was_active = (active_client == c);
	if (was_active) {
		active_client = NULL;
		seat_activate_next();
	}
	c->state = ST_CLOSED;
	c->session = -1;
	if (session == -1) return; /* never actually opened the seat */
	/* Matches real seatd's seat_remove_client exactly: only reset the VT
	 * to non-graphical if nothing is taking over it immediately -- either
	 * this was the active client and no waiting client claimed the VT
	 * right back, or it was a background client on that VT that's now
	 * genuinely gone (not just being ack'd through a normal disable,
	 * which never reaches this function at all). */
	if (was_active) {
		if (active_client == NULL) vt_configure(session, false);
	} else if (prev_state != ST_CLOSED) {
		vt_configure(session, false);
	}
}

static void client_destroy(struct client *c) {
	log_msg("session %d disconnected (pid %d)", c->session, c->pid);
	seat_remove_client(c);
	close(c->fd);
	memset(c, 0, sizeof *c);
	c->used = false;
}

/* --- protocol handlers, mirroring real seatd/client.c's opcode dispatch --- */

static void handle_open_seat(struct client *c) {
	if (c->session != -1) { send_error(c, EALREADY); return; }

	int vt = vt_get_current();
	if (vt == -1) { send_error(c, EIO); return; }
	/* Resyncs the shared g_cur_vt to this fresh query, matching real
	 * seatd's own seat_add_client (which calls seat_update_vt for exactly
	 * this reason). Needed for the first-ever client on a VT that was
	 * switched to *before* any client had put it in VT_PROCESS mode: the
	 * kernel switches such a VT with no signal to anyone (nobody was
	 * registered to receive one yet), so without this, g_cur_vt would be
	 * left stuck at -1 from the *previous* VT's release signal, and
	 * seat_activate_next below would refuse to activate this client at
	 * all. */
	g_cur_vt = vt;

	/* The one real conflict this file still guards against -- see the
	 * header comment for why this is narrower than upstream's own check. */
	for (int i = 0; i < MAX_CLIENTS; i++) {
		struct client *other = &clients[i];
		if (other != c && other->used && other->session == vt &&
		    (other->state == ST_ACTIVE || other->state == ST_PENDING_DISABLE)) {
			send_error(c, EBUSY);
			return;
		}
	}

	c->session = vt;
	c->state = ST_NEW;

	struct proto_server_seat_opened body = { .seat_name_len = (uint16_t)(strlen(SEAT_NAME) + 1) };
	if (send_msg2(c, SERVER_SEAT_OPENED, &body, sizeof body, SEAT_NAME, (uint16_t)(strlen(SEAT_NAME) + 1)) == -1) {
		log_msg("could not reply to open_seat for session %d", c->session);
		return;
	}
	log_msg("session %d (vt%d) opened %s (pid %d, uid %d)", c->session, vt, SEAT_NAME, c->pid, c->uid);
	seat_activate_next();
}

static void handle_close_seat(struct client *c) {
	if (c->session == -1) { send_error(c, EINVAL); return; }
	seat_remove_client(c);
	send_msg(c, SERVER_SEAT_CLOSED, NULL, 0);
}

static void handle_open_device(struct client *c, const char *path) {
	if (c->state != ST_ACTIVE) { send_error(c, EPERM); return; }

	char canon[PATH_MAX];
	if (realpath(path, canon) == NULL) { send_error(c, errno); return; }

	enum device_type type;
	if (!classify_device(canon, &type)) { send_error(c, ENOENT); return; }

	int count = 0, max_id = 0;
	for (struct device *d = c->devices; d; d = d->next) {
		if (strcmp(d->path, canon) == 0) {
			d->refcount++;
			send_device_opened(c, d->device_id, d->fd);
			return;
		}
		if (d->device_id > max_id) max_id = d->device_id;
		count++;
	}
	if (count >= MAX_SEAT_DEVICES) { send_error(c, EMFILE); return; }

	int fd = open(canon, O_RDWR | O_NOCTTY | O_NOFOLLOW | O_CLOEXEC);
	if (fd == -1) { send_error(c, errno); return; }

	struct device *d = calloc(1, sizeof *d);
	if (!d) { close(fd); send_error(c, ENOMEM); return; }
	snprintf(d->path, sizeof d->path, "%s", canon);
	d->fd = fd;
	d->device_id = max_id + 1;
	d->refcount = 1;
	d->type = type;
	d->next = c->devices;
	c->devices = d;

	device_activate(d);
	if (send_device_opened(c, d->device_id, d->fd) == -1)
		log_msg("could not send device fd for %s to session %d", canon, c->session);
}

static void handle_close_device(struct client *c, int device_id) {
	struct device **pp = &c->devices;
	while (*pp && (*pp)->device_id != device_id) pp = &(*pp)->next;
	if (!*pp) { send_error(c, EBADF); return; }

	struct device *d = *pp;
	if (--d->refcount > 0) {
		send_msg(c, SERVER_DEVICE_CLOSED, NULL, 0);
		return;
	}
	*pp = d->next;
	device_deactivate(d);
	close(d->fd);
	free(d);
	send_msg(c, SERVER_DEVICE_CLOSED, NULL, 0);
}

static void handle_disable_seat(struct client *c) {
	if (c->state != ST_PENDING_DISABLE) { send_error(c, EBUSY); return; }
	c->state = ST_DISABLED;
	if (active_client == c) {
		active_client = NULL;
		seat_activate_next();
	}
	send_msg(c, SERVER_SEAT_DISABLED, NULL, 0);
}

/* Requests a VT switch -- session numbers ARE VT numbers on this seat (see
 * the header comment), so this is just ioctl(VT_ACTIVATE, session). Does
 * NOT touch any client state directly: the actual disable/enable handoff
 * happens asynchronously via on_vt_release/on_vt_acquire below once the
 * kernel delivers the corresponding signals, matching upstream's own
 * reasoning for why (one single mechanism drives both a physical
 * Ctrl+Alt+Fn and this request, instead of two racing ones). */
static void handle_switch_session(struct client *c, int session) {
	if (c->state != ST_ACTIVE) { send_error(c, EPERM); return; }
	if (session == c->session) { send_msg(c, SERVER_SESSION_SWITCHED, NULL, 0); return; }
	if (session <= 0) { send_error(c, EINVAL); return; }
	if (g_cur_vt == -1) { send_error(c, EBUSY); return; } /* already mid-switch */

	int fd = vt_tty_open(g_cur_vt);
	if (fd == -1) { send_error(c, EIO); return; }
	/* Defensive re-arm, matching real seatd's own vt_switch -- harmless if
	 * already set, cheap insurance against this VT somehow having reverted
	 * to VT_AUTO behind our back. */
	struct vt_mode mode = { .mode = VT_PROCESS, .waitv = 0, .relsig = SIGUSR1, .acqsig = SIGUSR2, .frsig = 0 };
	ioctl(fd, VT_SETMODE, &mode);
	int rc = ioctl(fd, VT_ACTIVATE, session);
	int saved_errno = errno;
	close(fd);
	if (rc == -1) { send_error(c, saved_errno); return; }

	send_msg(c, SERVER_SESSION_SWITCHED, NULL, 0);
}

static void handle_ping(struct client *c) {
	send_msg(c, SERVER_PONG, NULL, 0);
}

/* --- VT release/acquire signal handlers -- see the header comment. Called
 * from main()'s poll loop once a signalfd read reports SIGUSR1/SIGUSR2,
 * never from an actual signal handler context, so ordinary (non-async-
 * signal-safe) calls like log_msg/open/close are fine here. --- */

/* The kernel wants to switch away from g_cur_vt -- disable whatever's
 * active there and ack, letting the switch proceed. Mirrors real seatd's
 * seat_vt_release. */
static void on_vt_release(void) {
	log_msg("vt%d releasing (switch requested)", g_cur_vt);
	if (active_client != NULL) disable_active_client();
	if (g_cur_vt != -1) vt_ack(g_cur_vt, true);
	g_cur_vt = -1;
}

/* The kernel just finished switching TO the new current VT -- ack, then
 * activate whatever claims it, if the outgoing client's disable ack has
 * already arrived (active_client == NULL); otherwise handle_disable_seat's
 * own trailing seat_activate_next() picks this up once it does. Mirrors
 * real seatd's seat_vt_activate. */
static void on_vt_acquire(void) {
	g_cur_vt = vt_get_current();
	log_msg("vt%d acquired", g_cur_vt);
	if (g_cur_vt != -1) vt_ack(g_cur_vt, false);
	if (active_client == NULL) seat_activate_next();
}

/* --- per-client connection handling --- */

static void handle_client_readable(struct client *c) {
	struct proto_header hdr;
	if (read_all(c->fd, &hdr, sizeof hdr) == -1) { client_destroy(c); return; }

	char body[MAX_PATH_LEN + sizeof(struct proto_client_open_device) + 16];
	if (hdr.size > sizeof body) { log_msg("oversized message (%u), dropping client", hdr.size); client_destroy(c); return; }
	if (hdr.size > 0 && read_all(c->fd, body, hdr.size) == -1) { client_destroy(c); return; }

	switch (hdr.opcode) {
	case CLIENT_OPEN_SEAT:
		handle_open_seat(c);
		break;
	case CLIENT_CLOSE_SEAT:
		handle_close_seat(c);
		break;
	case CLIENT_OPEN_DEVICE: {
		if (hdr.size < sizeof(struct proto_client_open_device)) { client_destroy(c); return; }
		struct proto_client_open_device msg;
		memcpy(&msg, body, sizeof msg);
		size_t pathlen = hdr.size - sizeof msg;
		if (msg.path_len != pathlen || pathlen == 0 || pathlen > MAX_PATH_LEN) { client_destroy(c); return; }
		char path[MAX_PATH_LEN];
		memcpy(path, body + sizeof msg, pathlen);
		if (path[pathlen - 1] != '\0') { client_destroy(c); return; }
		handle_open_device(c, path);
		break;
	}
	case CLIENT_CLOSE_DEVICE: {
		if (hdr.size != sizeof(struct proto_client_close_device)) { client_destroy(c); return; }
		struct proto_client_close_device msg;
		memcpy(&msg, body, sizeof msg);
		handle_close_device(c, msg.device_id);
		break;
	}
	case CLIENT_SWITCH_SESSION: {
		if (hdr.size != sizeof(struct proto_client_switch_session)) { client_destroy(c); return; }
		struct proto_client_switch_session msg;
		memcpy(&msg, body, sizeof msg);
		handle_switch_session(c, msg.session);
		break;
	}
	case CLIENT_DISABLE_SEAT:
		handle_disable_seat(c);
		break;
	case CLIENT_PING:
		handle_ping(c);
		break;
	default:
		log_msg("unknown opcode %u, dropping client", hdr.opcode);
		client_destroy(c);
		return;
	}
}

/* --- setup --- */

static int make_listen_socket(void) {
	unlink(SEATD_SOCK_PATH);

	int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd == -1) { perror("floraseat: socket"); exit(1); }

	struct sockaddr_un addr = { .sun_family = AF_UNIX };
	snprintf(addr.sun_path, sizeof addr.sun_path, "%s", SEATD_SOCK_PATH);
	if (bind(fd, (struct sockaddr *)&addr, sizeof addr) == -1) { perror("floraseat: bind"); exit(1); }
	if (listen(fd, 16) == -1) { perror("floraseat: listen"); exit(1); }

	/* seat group: only root logs in today, so this is a formality until
	 * FloraOS has real user management (see ARCHITECTURE.md's TODO
	 * list) -- but the socket perms are the entire access-control model
	 * here, same as real seatd, so set them correctly from day one
	 * rather than retrofitting later. */
	struct group *g = getgrnam("seat");
	if (chmod(SEATD_SOCK_PATH, 0660) == -1)
		log_msg("warn: could not chmod %s: %s", SEATD_SOCK_PATH, strerror(errno));
	if (g != NULL) {
		if (chown(SEATD_SOCK_PATH, 0, g->gr_gid) == -1)
			log_msg("warn: could not chown %s to group seat: %s", SEATD_SOCK_PATH, strerror(errno));
	} else {
		log_msg("warn: no 'seat' group in /etc/group -- socket stays root:root");
	}
	return fd;
}

/* SIGUSR1 (VT release)/SIGUSR2 (VT acquire) are read through this fd
 * (blocked from normal async delivery below) so the poll(2) loop handles
 * them as just another readable fd, alongside client sockets -- no
 * async-signal-safety constraints to worry about in on_vt_release/
 * on_vt_acquire, which call log_msg/open/close freely. SIGTERM/SIGINT stay
 * on the classic signal()+volatile-flag path (on_term) -- poll(2) already
 * returns EINTR for those, which the loop below handles. */
static int make_vt_signalfd(void) {
	sigset_t mask;
	sigemptyset(&mask);
	sigaddset(&mask, SIGUSR1);
	sigaddset(&mask, SIGUSR2);
	if (sigprocmask(SIG_BLOCK, &mask, NULL) == -1) {
		perror("floraseat: sigprocmask");
		exit(1);
	}
	int fd = signalfd(-1, &mask, SFD_CLOEXEC);
	if (fd == -1) { perror("floraseat: signalfd"); exit(1); }
	return fd;
}

int main(void) {
	signal(SIGPIPE, SIG_IGN);
	signal(SIGTERM, on_term);
	signal(SIGINT, on_term);

	for (int i = 0; i < MAX_CLIENTS; i++) clients[i].session = -1;

	int listen_fd = make_listen_socket();
	log_msg("listening on %s", SEATD_SOCK_PATH);

	int sigfd = make_vt_signalfd();
	g_cur_vt = vt_get_current();
	log_msg("VT-bound seat starting on vt%d", g_cur_vt);

	struct pollfd pfds[2 + MAX_CLIENTS];

	while (running) {
		int n = 0;
		pfds[n].fd = listen_fd;
		pfds[n].events = POLLIN;
		n++;
		pfds[n].fd = sigfd;
		pfds[n].events = POLLIN;
		n++;
		int client_idx[2 + MAX_CLIENTS];
		for (int i = 0; i < MAX_CLIENTS; i++) {
			if (!clients[i].used) continue;
			pfds[n].fd = clients[i].fd;
			pfds[n].events = POLLIN;
			client_idx[n] = i;
			n++;
		}

		int ready = poll(pfds, (nfds_t)n, -1);
		if (ready == -1) {
			if (errno == EINTR) continue;
			perror("floraseat: poll");
			break;
		}

		if (pfds[0].revents & POLLIN) {
			int cfd = accept4(listen_fd, NULL, NULL, SOCK_CLOEXEC);
			if (cfd == -1) {
				log_msg("accept failed: %s", strerror(errno));
			} else {
				struct client *c = client_alloc();
				if (!c) {
					log_msg("too many clients, rejecting");
					close(cfd);
				} else {
					struct ucred cred;
					socklen_t clen = sizeof cred;
					if (getsockopt(cfd, SOL_SOCKET, SO_PEERCRED, &cred, &clen) == 0) {
						c->pid = cred.pid;
						c->uid = cred.uid;
						c->gid = cred.gid;
					}
					c->used = true;
					c->fd = cfd;
					c->session = -1;
					c->state = ST_NEW;
					log_msg("client connected (pid %d, uid %d)", c->pid, c->uid);
				}
			}
		}

		if (pfds[1].revents & POLLIN) {
			struct signalfd_siginfo si;
			if (read(sigfd, &si, sizeof si) == sizeof si) {
				if (si.ssi_signo == SIGUSR1) on_vt_release();
				else if (si.ssi_signo == SIGUSR2) on_vt_acquire();
			}
		}

		for (int i = 2; i < n; i++) {
			if (pfds[i].revents & (POLLIN | POLLHUP | POLLERR)) {
				struct client *c = &clients[client_idx[i]];
				if (!c->used) continue;
				if (pfds[i].revents & (POLLHUP | POLLERR) && !(pfds[i].revents & POLLIN)) {
					client_destroy(c);
					continue;
				}
				handle_client_readable(c);
			}
		}
	}

	log_msg("shutting down");
	unlink(SEATD_SOCK_PATH);
	return 0;
}
