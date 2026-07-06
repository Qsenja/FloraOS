# FloraOS

A minimal, from-scratch Linux distribution. No systemd, no upstream binary
repo dependency (not Arch/Artix-based) — every package is compiled from its
pinned upstream source (see `config/versions.conf`). OpenRC + sysvinit for
init, GNU userland (bash/coreutils/util-linux), and `fau`, FloraOS's own
package manager, written from scratch rather than forked from an existing one.

What makes FloraOS different: user-installed apps via `fau app-install` live
entirely under `~/apps/<name>/` — binary, config, cache, logs, all in one
self-contained directory, never scattered across `/usr`, `/etc`, `/var/log`.
`fau app-remove firefox` deletes exactly that directory and nothing else. See
[ARCHITECTURE.md](ARCHITECTURE.md#app-isolation-per-app-directories-under-apps)
for how and why, and its real limits.

## Quick start

```
./floraiso build   # builds the rootfs (if needed) and the ISO
./floraiso test    # boots the ISO in QEMU and checks it actually reaches a shell
```

Zero configuration needed for a default build. To change the hostname, add
extra base packages, or rename the output ISO, edit `config/floraos.conf`
(that's the only config file this project uses).

## What each command does

- `./floraiso rootfs` — builds only `work/rootfs`, the base root filesystem
  (kernel, glibc, sysvinit, openrc, bash, coreutils, util-linux, e2fsprogs,
  iproute2, dhcpcd — see [docs/MANIFEST.md](docs/MANIFEST.md) for the
  justification of every single one). Nothing here touches your real system:
  everything downloads and builds under `work/` (gitignored).
- `./floraiso build` — runs the rootfs build if needed, then packs the whole
  rootfs as an initramfs and calls `grub-mkrescue` to produce a hybrid
  BIOS+UEFI bootable `floraos.iso` (name configurable). FloraOS currently
  boots and runs entirely from RAM as a live image — persistent disk installs
  are a documented TODO, not yet scripted (see ARCHITECTURE.md).
- `./floraiso test` — boots that ISO in QEMU with a serial console and checks
  the boot log for two markers: the kernel actually starting, and the login
  shell actually being reached. Exits non-zero (and prints why) if either is
  missing.

## Layout

```
config/floraos.conf     # the one config file: hostname, extra packages, kernel version, ISO name
config/versions.conf    # pinned source URL + sha256 for every base package
docs/MANIFEST.md        # every package in the base rootfs, one-line reason each
docs/FILESYSTEM_LAYOUT.md
ARCHITECTURE.md         # design decisions and why
tools/fau/              # FloraOS's package manager
scripts/                # rootfs + ISO build scripts and per-package build recipes
work/                   # build output (gitignored) -- sources, staged builds, rootfs, fau repo
```

## fau, the package manager

```
fau install <pkg>          # system package -> merged into FAU_ROOT (/usr, /etc, ...)
fau app-install <pkg>      # user app -> isolated under ~/apps/<pkg>/
fau app-remove <pkg>       # deletes that app's directory and its PATH wrapper, nothing else
fau export system.json     # dump the exact installed package set
fau apply system.json      # reproduce that exact package set on another machine
```

See `tools/fau/fau --help` for the full command list.
