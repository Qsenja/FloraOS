# FloraOS

A minimal, from-scratch Linux distribution. No systemd, no upstream binary
repo dependency (not Arch/Artix-based) — every package is compiled from its
pinned upstream source (see `config/versions.conf`). OpenRC + sysvinit for
init, GNU userland (bash/coreutils/util-linux), and `fau`, FloraOS's own
package manager, written from scratch rather than forked from an existing one.

What makes FloraOS different: user-installed apps via `fau install` live
entirely under `~/apps/<name>/` — binary, config, cache, logs, all in one
self-contained directory, never scattered across `/usr`, `/etc`, `/var/log`.
`fau remove firefox` deletes exactly that directory and nothing else. See
[ARCHITECTURE.md](ARCHITECTURE.md#app-isolation-per-app-directories-under-apps)
for how and why, and its real limits.

## Status: boots to a working shell, verified

`./floraiso test` passes: the kernel starts, and a *real, credential-checked*
login actually succeeds and reaches a shell (driven through QEMU's serial
console — the test types the login itself, it doesn't just watch for a
shell to appear on its own). Concretely, right now:

- **30 packages** in the base image, every one built from pinned upstream
  source on this machine (see [docs/MANIFEST.md](docs/MANIFEST.md) for the
  full list and a one-line reason for each) — kernel, glibc, sysvinit,
  OpenRC, ncurses, bash, coreutils, util-linux, e2fsprogs, iproute2, dhcpcd,
  plus grep/sed/gawk/findutils/tar/zstd/rsync/attr/acl/libmd (all of it
  needed for `fau` itself to actually work *inside* the running OS, not just
  during the build — see ARCHITECTURE.md for how that gap got found), plus
  procps-ng/hostname/kbd so OpenRC's sysctl/hostname/keymaps services
  actually run instead of failing non-fatally, plus libxcrypt for password
  verification, plus curl/mbedtls so `fau` can actually fetch anything after
  boot (see below), plus eudev (device nodes/hotplug for libinput and any
  Wayland compositor), plus fastfetch as a deliberate branding touch.
- **GUI-readiness**: the system-level prerequisites for a Wayland WM/DE now
  exist — eudev for device nodes, **floraseat**
  ([tools/floraseat](tools/floraseat)), FloraOS's own from-scratch daemon
  speaking the real seatd wire protocol (so precompiled wlroots/libseat
  fetched via `fau install <wm>` talks to it unmodified, without this
  project taking on meson/ninja just to build real seatd), a generic
  simpledrm/sysfb KMS driver built into the kernel, and `floralogin` now
  setting up `XDG_RUNTIME_DIR`. See ARCHITECTURE.md's GUI-readiness section
  for the full picture and what's still explicitly not done (VT-switching,
  real GPU-accelerated drivers, and the WM/DE itself — still purely opt-in
  via `fau install`, same as any other app).
- **`fau` can install real Arch/Artix packages with zero `pacman` involved**,
  including from inside an already-booted FloraOS system, not just at build
  time. It used to shell out to the real `pacman -Sp` for dependency
  resolution; now it reads the sync-db/mirrorlist formats itself and
  resolves PROVIDES (virtual packages) and version constraints
  (`glibc>=2.38-1`) natively — checked against real `pacman`/`vercmp` output
  (exact match resolving a real ~130-package closure, and ~300 real package
  version comparisons) before trusting it. Verified end-to-end in QEMU: a
  real DHCP lease, a real HTTPS fetch, then `fau install tree` succeeding
  from inside the booted OS with `pacman` genuinely absent.
- **Real password-backed login**, PAM-free. util-linux's own login requires
  PAM to build at all (no fallback exists upstream), so FloraOS ships
  **floralogin**, a small from-scratch login (`tools/floralogin`) that
  verifies `/etc/shadow` via crypt(3)/libxcrypt, run through a real `agetty`
  instead of spawning bash directly — which also fixed console job control
  as a side effect (agetty properly attaches the controlling tty; bash
  spawned directly never did). Root's password is intentionally empty
  (traditional Unix "no password required" — see `/etc/issue` at the login
  prompt) since this is a live, RAM-resident image with no `passwd` command
  yet to set a real one.
- **`fau` runs inside the booted OS**, not just as a build-time tool —
  verified directly with an unprivileged `unshare --user --map-root-user
  --mount chroot` into the built rootfs (no sudo needed): `fau
  bootstrap-list` correctly prints all 29 installed base packages, and
  ordinary commands like `ls` work.
- **ISO size: 164MB** (`floraos.iso`, hybrid BIOS+UEFI, boots and runs
  entirely from RAM as a live image). Grew from an earlier 135MB, mostly
  from fixing a real bug where FloraOS's own compiled glibc was being
  silently overwritten by Arch's smaller, pre-stripped binary (see
  ARCHITECTURE.md) — that extra size is FloraOS's own unstripped build
  correctly winning out, not new bloat — plus curl/mbedtls, added
  deliberately so `fau` can fetch packages after boot.
- **fastfetch** runs at login with a custom ASCII logo and a package count
  read from `fau`'s own list.

What's explicitly *not* done yet (all documented with reasoning in
[ARCHITECTURE.md](ARCHITECTURE.md)'s TODO section):

- **No WM/DE bundled in the base image** (still opt-in via `fau install`,
  same as any other app) — but the prerequisites now exist (eudev,
  floraseat, a built-in generic KMS driver; see above and ARCHITECTURE.md).
  `kitty` is still deliberately left out of the default ISO — its
  dependency closure is ~773MB of Python3/Mesa/X11/Wayland; `fau install
  kitty` works today if you want the files.
- **No VT-switching, no real GPU-accelerated driver** — floraseat is
  single-seat/non-VT-bound for now (fine for one login session at a time),
  and the kernel only ships a generic firmware-framebuffer KMS driver, not
  i915/amdgpu/nouveau (add the one your hardware needs once this actually
  blocks someone — see ARCHITECTURE.md).
- No persistent disk install — FloraOS currently only boots as a live,
  RAM-resident image.

## Quick start

```
./floraiso build   # builds the rootfs (if needed) and the ISO
./floraiso test    # boots the ISO in QEMU and checks it actually reaches a shell
```

Logging in yourself (e.g. `qemu-system-x86_64 -cdrom floraos.iso`): login as
`root` with an empty password (just press Enter) — see `/etc/issue` at the
prompt.

Zero configuration needed for a default build. To change the hostname, add
extra base packages, or rename the output ISO, edit `config/floraos.conf`
(that's the only config file this project uses).

## What each command does

- `./floraiso rootfs` — builds only `work/rootfs`, the base root filesystem
  (see [docs/MANIFEST.md](docs/MANIFEST.md) for the full package list and
  the justification of every single one). Nothing here touches your real
  system: everything downloads and builds under `work/` (gitignored).
- `./floraiso build` — runs the rootfs build if needed, then packs the whole
  rootfs as an initramfs and calls `grub-mkrescue` to produce a hybrid
  BIOS+UEFI bootable `floraos.iso` (name configurable, currently 164MB).
  FloraOS currently boots and runs entirely from RAM as a live image —
  persistent disk installs are a documented TODO, not yet scripted (see
  ARCHITECTURE.md).
- `./floraiso test` — boots that ISO in QEMU with a serial console, drives an
  actual login (root, empty password) through it, and checks the boot log
  for two markers: the kernel actually starting, and the login shell
  actually being reached. Exits non-zero (and prints why) if either is
  missing.

## Layout

```
config/floraos.conf     # the one config file: hostname, extra packages, kernel version, ISO name
config/versions.conf    # pinned source URL + sha256 for every base package
docs/MANIFEST.md        # every package in the base rootfs, one-line reason each
docs/FILESYSTEM_LAYOUT.md
ARCHITECTURE.md         # design decisions, why, and the current TODO list
assets/                 # fastfetch logo + config shipped into the rootfs
tools/fau/               # FloraOS's package manager
tools/floralogin/        # FloraOS's own PAM-free login (see ARCHITECTURE.md)
tools/floraseat/         # FloraOS's own seatd-protocol-compatible seat daemon
tools/florauser/         # FloraOS's own useradd/passwd/groupadd equivalent
tools/fauelf/            # FloraOS's own absolute-DT_NEEDED fixup tool
scripts/                # rootfs + ISO build scripts and per-package build recipes
work/                   # build output (gitignored) -- sources, staged builds, rootfs, fau repo
```

## fau, the package manager

```
fau install <pkg>          # user app -> isolated under ~/apps/<pkg>/
fau remove <pkg>           # deletes that app's directory and its PATH wrapper, nothing else
fau list                   # list installed apps and versions
```

`install` first checks FloraOS's own repo; until there's a curated catalog
of FloraOS-native apps, anything not found there falls back to fetching
straight from Arch/Artix's own repos — dependency-resolved (including
virtual/PROVIDES packages and version constraints) and sha256-verified,
merged into the same isolated app directory (no root, and nothing gets
installed onto your real system). This fallback doesn't shell out to
`pacman` at all (it reads the sync-db/mirrorlist formats itself), so it
works both when building the ISO here *and* from inside an already-booted
FloraOS system, which ships neither `pacman` nor its config — see
ARCHITECTURE.md for how that's verified. GUI apps will fetch fine but have
nowhere to render without a display server (not built yet, see
ARCHITECTURE.md).

There's also a build-time-only counterpart —
`bootstrap`/`bootstrap-remove`/`bootstrap-list`/`bootstrap-export`/`bootstrap-apply`
— that merges straight into FAU_ROOT (`/usr`, `/etc`, ...) instead of an
isolated app directory. It's how `scripts/build-rootfs.sh` constructs the
base rootfs itself (kernel, glibc, coreutils, etc.); not something an end
user needs after boot.

```
fau bootstrap-export system.json   # dump the exact base-system package set
fau bootstrap-apply system.json    # reproduce that exact package set on another machine
```

`fau export`/`fau import` are the user-facing counterpart: `fau export` bundles
a fresh `system.json` (base packages + installed apps + every config file
found under each app's own `~/apps/<name>/config/`) together with the actual
config file contents into one `.flora` archive — a tar+zstd archive (the same
format as fau's own `.fau.tar.zst` packages) rather than a `.zip`, since
FloraOS ships no zip/unzip and tar+zstd is already a base dependency. `fau
import` reads that archive back, (re)installing any app it lists that isn't
already present so there's somewhere for its config to land, then restores
every listed config file into place under `~/apps/<name>/config/`:

```
fau export [file]     # -> system.flora by default
fau import [file]     # <- system.flora by default
```

A `fau backup` command (a full-root snapshot, restorable from the GRUB boot
menu) is planned but not yet implemented — see ARCHITECTURE.md's TODO list for
why it needs more than just `fau` changes.

See `tools/fau/fau --help` for the full command list.
