# floraseat — implementation notes

Design rationale mined from `floraseat.c`'s own comments. See
[docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) for the project-level
design history and [docs/TODO.md](../../docs/TODO.md) for what's still
open.

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

- **One seat (`seat0`), VT-bound.** Real seatd only ever creates one seat
  too (its own `server.c` says `"TODO: create more seats"`), so this isn't a
  cut corner relative to upstream. See "VT-bound seat" below for how the
  VT-binding itself works.
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

## VT-bound seat

A client's session number **is** the VT number it opened the seat on —
queried via `VT_GETSTATE` on `/dev/tty0` at `CLIENT_OPEN_SEAT` time, not an
arbitrary counter. This is real seatd's own VT-bound convention (verified
directly against upstream's `common/terminal.c`/`seatd/seat.c`, fetched and
read, not reconstructed from memory), ported here rather than invented.

- **Activating** a client (`seat_activate_next`) puts its VT into
  `VT_SETMODE(VT_PROCESS)` with `relsig=SIGUSR1`/`acqsig=SIGUSR2`, keyboard
  raw-passthrough (`KDSKBMODE K_OFF` — so a graphical client reads raw
  evdev via the device fds this daemon already hands out, instead of the
  kernel's own VT layer consuming keypresses first), and `KD_GRAPHICS`.
  Idempotent, so it's safe to call on every reactivation, not just the
  first — matches upstream's own `vt_open`.
- **Both signals are delivered via `signalfd(2)`**, blocked from normal
  async delivery and read as just another pollable fd in the daemon's
  existing `poll(2)` loop — no async-signal-safety constraints to worry
  about in the handlers, which call `log_msg`/`open`/`close` freely.
  `SIGTERM`/`SIGINT` stay on the classic `signal()`+volatile-flag path
  (`on_term`), since `poll(2)` already returns `EINTR` for those.
- **`on_vt_release`** (SIGUSR1): disables whatever's active on the
  releasing VT (`disable_active_client`, shared with the ack-driven path
  below) and acks (`VT_RELDISP, 1`) so the kernel proceeds with the switch.
- **`on_vt_acquire`** (SIGUSR2), once the switch completes: acks
  (`VT_RELDISP, VT_ACKACQ`) and activates whichever client claims the
  newly-current VT, if the outgoing client's disable ack has already
  arrived; otherwise `handle_disable_seat`'s own trailing
  `seat_activate_next()` picks it up once it does (same ordering upstream
  handles the same way, since the kernel's VT switch and the graphical
  client's own IPC round-trip are two independent timings).
- **`CLIENT_SWITCH_SESSION`** no longer touches any client state directly
  — it only issues `ioctl(VT_ACTIVATE, <target>)` on the currently-active
  VT's tty and lets the release/acquire signals above drive the actual
  handoff. Matches upstream's own reasoning: one single mechanism handles
  both a physical Ctrl+Alt+Fn *and* this request, instead of two
  potentially-racing ones.
- **The specific edge case that needed a real fix, not just reasoning
  through it**: switching to a VT that has *never* had a floraseat client
  on it before produces no acquire signal at all — nobody was ever
  registered (`VT_SETMODE(VT_PROCESS)`) to receive one for that VT, so the
  kernel just switches directly. Found by exactly this failing a first
  real test run (a fresh second VT, switched to before any client had
  opened it): `g_cur_vt` was left stuck at `-1` from the *previous* VT's
  release, so `seat_activate_next` refused to activate anything at all,
  including a client that then tried to open the seat on the new VT. Fixed
  by having `handle_open_seat` resync `g_cur_vt` to its own fresh
  `VT_GETSTATE` query, the same thing upstream's `seat_add_client` does via
  `seat_update_vt` for the identical reason.
- **Deliberately simpler than upstream in one place**: real seatd's
  `seat_add_client` refuses *any* new client while *any* client anywhere on
  the seat is active and not already mid-disable, regardless of which VT
  either is on. `handle_open_seat` here only refuses a new client
  targeting the exact same VT another still-live client already claims —
  the one real conflict (two clients fighting over one VT) — since
  blocking unrelated VTs from ever adding a session while a different VT is
  merely active elsewhere doesn't fit this project's own multi-VT use
  case. A documented simplification, not a hidden one.

## Session switching

`handle_switch_session` above replaces what used to be a purely
software-only, ack-driven handoff between two already-open clients (no VT
ioctl at all) — see "VT-bound seat" above for what it does now.

## `struct device.path` is `PATH_MAX`, not the wire protocol's path cap

`realpath(3)` can expand a symlink to something longer than the client's
original (≤`MAX_PATH_LEN`) request path — same reason real seatd's own
`seat_device.path` is a heap `strdup()` of a `PATH_MAX`-sized sanitized
path rather than reusing the wire protocol's own length cap.

## Verification

Boot-tested end-to-end for real in QEMU/KVM, not just compiled:

- **Protocol basics** (open_seat/enable_seat/disallowed-path
  rejection/ping-pong) with a hand-written test client against the actual
  compiled binary — see docs/ARCHITECTURE.md's floraseat entry.
- **The VT-bound rewrite** with `vt-test-client.c` (this directory) — a
  small diagnostic that speaks just enough of the wire protocol to open a
  seat, open a device, and print every `SERVER_*` event it receives. Not
  staged into the rootfs by `build-rootfs.sh` (never ships in a real
  FloraOS image); build it statically and drop it into a running system to
  reproduce:
  ```
  gcc -O2 -static -o vt-test-client vt-test-client.c
  ```
  Run two instances (each redirected to its own log file) and switch
  between them for real with `chvt 1`/`chvt 2` — `/var/log/floraseat.log`
  and each instance's own log show the full release→disable-ack→acquire→
  re-enable sequence. This is exactly how the `g_cur_vt`-stuck-at-`-1` bug
  above was actually found, not predicted in advance. Not independently
  exercised: real DRM master handoff between two live GPU clients — a
  `-nographic` QEMU boot has no framebuffer for `simpledrm` to attach to,
  so `/dev/dri/card0` never appears at all (the test client's own
  device-open call gets `ENOENT`), leaving the seat-level protocol verified
  but the device-level master transfer itself unverified against a real
  DRM node.
