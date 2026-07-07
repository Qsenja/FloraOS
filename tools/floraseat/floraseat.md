# floraseat — implementation notes

Design rationale mined from `floraseat.c`'s own comments. See
[docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) for the project-level
design history and [docs/TODO.md](../../docs/TODO.md) for the still-open
VT-switching gap.

## Why from scratch, not real seatd

Building real seatd means adding meson+ninja to the build host — FloraOS
deliberately avoids cmake/meson everywhere else (same reasoning as
mbedtls's plain-Makefile pick over OpenSSL). Same "small, auditable,
purpose-built instead of vendoring" idea as `fau`'s alpm fallback and
`floralogin`.

**Not a from-scratch protocol, though.** floraseat speaks the real seatd
wire protocol — verified directly against upstream kennylevinsen/seatd's
`include/protocol.h`, `seatd/client.c`, `seatd/seat.c`, `common/drm.c`,
`common/evdev.c`, `common/hidraw.c` (fetched and read directly, not
reconstructed from memory), so that `libseat` — which FloraOS does **not**
build itself, it arrives precompiled inside wlroots/mesa/sway/mango via
`fau`'s alpm fallback — talks to this unmodified. Same idea as `fau`'s own
alpm fallback reading pacman's *data formats* without vendoring pacman's
code: here it's seatd's *wire protocol* without vendoring seatd's C source
tree. The opcode numbers and struct layouts in this file are the real ABI,
reproduced (not copy-pasted) here — the layout must match upstream exactly
byte-for-byte or nothing fetched via `fau install <wm>` can ever draw a
pixel.

## Scope, deliberately smaller than real seatd

- **One seat (`seat0`), non-VT-bound.** Real seatd only ever creates one
  seat too (its own `server.c` says `"TODO: create more seats"`), so this
  isn't a cut corner relative to upstream. Non-VT-bound means no VT
  switching — acceptable today (FloraOS has exactly one login session at a
  time), a real gap once a second concurrent graphical session exists. See
  [docs/TODO.md](../../docs/TODO.md).
- **Device allowlist**: `/dev/dri/` / `/dev/input/event` / `/dev/hidraw`
  prefixes only, matching real seatd's `path_is_drm`/`path_is_evdev`/
  `path_is_hidraw` (`wscons`, BSD console, skipped — not relevant on
  Linux). The path is `realpath(3)`-canonicalized *before* the prefix
  check, same as upstream, specifically so a symlink or `../` can't be
  used to open something outside the allowlist through a name that merely
  starts with an allowed prefix.
- **Access control is socket-permission-based**, same model as real
  seatd: `/run/seatd.sock` is `0660 root:seat`. Only root logs in today, so
  this is trivially satisfied — the moment FloraOS gets a second, non-root
  login, `usermod -aG seat <user>` (now real, via `florauser addtogroup`)
  is the entire migration path. No uid check inside the daemon itself,
  matching upstream. The socket perms are set correctly from day one
  rather than retrofitted later, since they're the *entire* access-control
  model here.
- **I/O model**: `poll(2)` over plain blocking sockets, not seatd's own
  non-blocking ring-buffer connection layer. Every message in this
  protocol is well under 300 bytes on a local `AF_UNIX SOCK_STREAM` socket
  — once `poll(2)` says a socket is readable, a blocking read of the few
  bytes needed for one message does not block in practice. A documented
  simplification, not a hidden one.

## Device revoke semantics

`device_activate`/`device_deactivate` mirror real seatd's per-type
behavior: DRM master is set/dropped via `DRM_IOCTL_SET_MASTER`/
`DROP_MASTER` (hardcoded ioctl numbers from libdrm, same reasoning as real
seatd's own `common/drm.c` — avoiding a build dependency on libdrm's
headers just for two ioctl numbers). evdev/hidraw have nothing to
re-enable once revoked — `EVIOCREVOKE`/`HIDIOCREVOKE` are one-shot per fd
(matches upstream: `seat_activate_device` in real `seat.c` returns
`EINVAL` for these types), the client must reopen instead.

## Session switching

`handle_switch_session` is ack-driven, matching upstream's handoff: the
current client is told to disable, and only once it acks via
`handle_disable_seat` does `seat_activate_next()` actually hand the seat to
the target client. No VT ioctl dance here — see the non-VT-bound scope
note above.

## `struct device.path` is `PATH_MAX`, not the wire protocol's path cap

`realpath(3)` can expand a symlink to something longer than the client's
original (≤`MAX_PATH_LEN`) request path — same reason real seatd's own
`seat_device.path` is a heap `strdup()` of a `PATH_MAX`-sized sanitized
path rather than reusing the wire protocol's own length cap.
