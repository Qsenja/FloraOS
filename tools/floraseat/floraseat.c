/* floraseat -- FloraOS's own seat-management daemon, speaking the real seatd wire protocol. See floraseat.md. */
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

#include <linux/input.h>
#include <linux/hidraw.h>
#include <linux/kd.h>
#include <linux/vt.h>

#define SEATD_SOCK_PATH "/run/seatd.sock"
#define SEAT_NAME "seat0"
#define MAX_CLIENTS 32
#define MAX_PATH_LEN 256
#define MAX_SEAT_LEN 64
#define MAX_SEAT_DEVICES 128

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

enum device_type { DEV_DRM, DEV_EVDEV, DEV_HIDRAW };

struct device {
	struct device *next;
	char path[PATH_MAX]; /* PATH_MAX, not MAX_PATH_LEN -- see floraseat.md */
	int fd;
	int device_id;
	int refcount;
	enum device_type type;
	bool active;
};

enum client_state { ST_NEW, ST_ACTIVE, ST_PENDING_DISABLE, ST_DISABLED, ST_CLOSED };

struct client {
	bool used;
	int fd;
	pid_t pid;
	uid_t uid;
	gid_t gid;
	int session;
	enum client_state state;
	struct device *devices;
};

static struct client clients[MAX_CLIENTS];
static struct client *active_client;
static int g_cur_vt = -1; /* -1 means mid-switch, see floraseat.md */
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

static int vt_tty_open(int vt) {
	char path[32];
	snprintf(path, sizeof path, "/dev/tty%d", vt);
	int fd = open(path, O_RDWR | O_NOCTTY);
	if (fd == -1) log_msg("warn: could not open %s: %s", path, strerror(errno));
	return fd;
}

static int vt_get_current(void) {
	int fd = open("/dev/tty0", O_RDWR | O_NOCTTY);
	if (fd == -1) { log_msg("warn: could not open /dev/tty0: %s", strerror(errno)); return -1; }
	struct vt_stat st;
	int rc = ioctl(fd, VT_GETSTATE, &st);
	close(fd);
	if (rc == -1) { log_msg("warn: VT_GETSTATE failed: %s", strerror(errno)); return -1; }
	return st.v_active;
}

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

static void vt_ack(int vt, bool releasing) {
	int fd = vt_tty_open(vt);
	if (fd == -1) return;
	if (ioctl(fd, VT_RELDISP, releasing ? 1 : VT_ACKACQ) == -1)
		log_msg("warn: VT_RELDISP ack (%s) on vt%d failed: %s",
			releasing ? "release" : "acquire", vt, strerror(errno));
	close(fd);
}

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

static void seat_activate_next(void) {
	if (active_client != NULL) return;
	if (g_cur_vt == -1) return;
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

static void disable_active_client(void) {
	struct client *c = active_client;
	for (struct device *d = c->devices; d; d = d->next) device_deactivate(d);
	c->state = ST_PENDING_DISABLE;
	send_msg(c, SERVER_DISABLE_SEAT, NULL, 0);
	log_msg("session %d disabling (vt switch)", c->session);
}

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
	if (session == -1) return;
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

static void handle_open_seat(struct client *c) {
	if (c->session != -1) { send_error(c, EALREADY); return; }

	int vt = vt_get_current();
	if (vt == -1) { send_error(c, EIO); return; }
	g_cur_vt = vt;

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

static void handle_switch_session(struct client *c, int session) {
	if (c->state != ST_ACTIVE) { send_error(c, EPERM); return; }
	if (session == c->session) { send_msg(c, SERVER_SESSION_SWITCHED, NULL, 0); return; }
	if (session <= 0) { send_error(c, EINVAL); return; }
	if (g_cur_vt == -1) { send_error(c, EBUSY); return; }

	int fd = vt_tty_open(g_cur_vt);
	if (fd == -1) { send_error(c, EIO); return; }
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

static void on_vt_release(void) {
	log_msg("vt%d releasing (switch requested)", g_cur_vt);
	if (active_client != NULL) disable_active_client();
	if (g_cur_vt != -1) vt_ack(g_cur_vt, true);
	g_cur_vt = -1;
}

static void on_vt_acquire(void) {
	g_cur_vt = vt_get_current();
	log_msg("vt%d acquired", g_cur_vt);
	if (g_cur_vt != -1) vt_ack(g_cur_vt, false);
	if (active_client == NULL) seat_activate_next();
}

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

static int make_listen_socket(void) {
	unlink(SEATD_SOCK_PATH);

	int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd == -1) { perror("floraseat: socket"); exit(1); }

	struct sockaddr_un addr = { .sun_family = AF_UNIX };
	snprintf(addr.sun_path, sizeof addr.sun_path, "%s", SEATD_SOCK_PATH);
	if (bind(fd, (struct sockaddr *)&addr, sizeof addr) == -1) { perror("floraseat: bind"); exit(1); }
	if (listen(fd, 16) == -1) { perror("floraseat: listen"); exit(1); }

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
