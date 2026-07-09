# FloraOS Architecture

## Init system: OpenRC

No systemd anywhere in the dependency chain (hard constraint). OpenRC is a
small, dependency-based init that doesn't pull in its own ecosystem of
daemons, which fits a small auditable base.

## Base toolchain: GNU userland

bash, coreutils, util-linux — chosen over busybox because the target spec
requires "standard GNU userland" rather than a single-binary toolbox. Slightly
larger than busybox, but more conventional behavior and easier to audit
against upstream GNU behavior.

## libc: glibc

Paired with the GNU userland above. musl would be smaller and arguably more
auditable in isolation, but mixing musl with GNU coreutils/bash/util-linux is
less conventional and risks subtle compatibility gaps; glibc is the
straightforward pairing for a GNU userland.

## Kernel: linux-lts

Picked over "latest stable" because a from-scratch distro with a small
maintenance team benefits more from a long support window and fewer breaking
changes to track than from bleeding-edge features/hardware support.

## System manager: fau (custom, from scratch)

Two explicit constraints ruled out the obvious options:
- Mirroring an existing binary repo (Arch/Artix) would make FloraOS
  "based on" another distro, which was explicitly rejected.
- Forking pacman would mean vendoring a third party's codebase into the
  project, which was also explicitly rejected.

So FloraOS ships **fau**, a small system manager written from scratch
(`tools/fau/`). "System manager", not just "package manager": package
install/remove (below), `fau backup`'s full-root snapshot/restore (see its
own section further down), and `fau service-*`/`fau seat-*`/`fau user-*`'s
front ends over OpenRC/floraseat/florauser (see their own sections further
down) are what exist today, but the intent is for fau to keep growing into
managing the whole running system -- configuration, more of the daily
admin surface -- not stop here, with each new area getting its own
`fau-<name>` tool alongside the others (see the "split `fau` into a
dispatcher + `fau-*` tools" DONE entry below) rather than more logic piling
into one file. Package management specifically:
- Package format: a plain tarball (`.fau.tar.zst`) containing the payload
  under `files/` plus a `pkginfo` metadata file (name, version, one-line
  description, dependency list).
- Repo format: a directory of `.fau.tar.zst` packages plus a generated
  `repo.json` index (name -> version/filename/sha256).
- Install/remove: extracts payloads relative to a target root, records the
  package + version + file list, resolves dependencies listed in `pkginfo`.
- **The alpm (Arch/Artix repo) fallback never shells out to the `pacman`
  binary** -- it reads the sync-db/mirrorlist/desc formats directly (see
  further down for the full story of how that came to be and what it took
  to get there). FloraOS itself still doesn't ship pacman (shipping it
  would mean vendoring Arch/Artix's package manager, the thing explicitly
  ruled out at the start) -- it doesn't need to, since fau only ever reads
  pacman's *data formats*, never invokes the program.
  - **Found and fixed a real integrity bug in this fallback**: the scratch
    pacman db it resolves against has a deliberately *empty* local-package
    state (so `pacman -Sp` resolves the requested package's FULL upstream
    closure, not just what's missing) -- but for something like
    `fau bootstrap fastfetch`, that closure also includes `glibc`,
    `filesystem`, `tzdata`, etc: packages FloraOS already built from its own
    pinned source. Left unguarded, those got merged into `FAU_ROOT` too,
    which **silently replaced FloraOS's own compiled `libc.so.6` with
    Arch's official binary** on every single rootfs build -- caught by
    comparing sha256 before/after a real build, not by inspection. Fixed in
    three parts, all in `tools/fau/fau`'s `install_one_alpm`: (1) skip any
    resolved package fau's own `system.json` already has a version for
    (i.e. skip `glibc`, since FloraOS built it), (2) strip `etc/` from
    whatever *does* get merged -- Arch's `filesystem` package ships its own
    `/etc/artix-release`, `/etc/shells`, `/etc/securetty`, etc, which have
    no business anywhere near FloraOS's own skeleton (`apply-skeleton.sh` is
    the sole source of truth for `/etc`), (3) strip `usr/include` too --
    `linux-api-headers` is a pure build-time artifact that added 15MB of
    unused kernel headers to the shipped image for zero runtime benefit.
  - **A fourth leak found by actually booting the ISO interactively in
    QEMU, not just the automated marker check**: even with (2) and (3),
    Arch's `filesystem` package still contributed `/usr/lib/tmpfiles.d/
    artix.conf`, `/usr/lib/sysctl.d/10-artix.conf`, and `/usr/lib/
    sysusers.d/artix.conf` -- none of that is under `etc/` or
    `usr/include`, so it survived. Result: FloraOS was silently applying
    Artix's own sysctl tuning at every boot ("Applying /usr/lib/sysctl.d/
    10-artix.conf..."), and openrc's tmpfiles.setup was throwing chown/
    chgrp errors for `/etc/artix-release` and a dozen other files that
    artix.conf expected but FloraOS deliberately doesn't ship. Fixed by
    skipping the whole `filesystem` package by name in `install_one_alpm`
    -- unlike `glibc` (skipped because FloraOS already provides it),
    `filesystem` is skipped because *nothing* in it is ever wanted here,
    regardless of what FloraOS itself provides.
- **The alpm fallback no longer needs pacman at all.** It used to
  shell out to the real `pacman -Sp` binary for dependency resolution --
  everything else (sync db parsing, fetching, checksumming) was already
  fau's own code. Now `tools/fau/fau`'s `alpm_resolve`/`alpm_find_provider`
  read the sync db and mirrorlist formats directly and do the resolution
  themselves: PROVIDES (virtual packages, e.g. "sdl2" satisfied by
  "sdl2-compat") and version constraints (`glibc>=2.38-1`) both handled,
  verified by resolving cava (a real package with a ~130-package closure
  including several PROVIDES hops) and diffing the result against real
  pacman's own `-Sp` output: exact match, zero missing, zero extra, zero
  duplicates. Version comparison (`alpm_vercmp`/`_rpmvercmp`) reimplements
  pacman's own algorithm, checked against the real `vercmp` binary across
  ~300 real package versions plus hand-picked edge cases (epoch, pkgrel,
  git-describe-style `+r37+gHASH` suffixes) -- exact match on all of them;
  the only known divergences are contrived cases (a bare alpha suffix with
  no separator, tilde pre-release markers) that don't occur in real
  Arch/Artix version strings, an accepted simplification rather than every
  rpmvercmp edge case.
  - This is *why* it can now work from inside an already-booted FloraOS
    system, not just at build time: FloraOS ships a copy of the mirrorlist
    and repo list at `/etc/fau/pacman-mirrorlist`/`pacman-repos` (see
    build-rootfs.sh) since `/etc/pacman.d`/`/etc/pacman.conf` don't exist
    there, and the sync db itself gets fetched fresh via HTTP if this
    build host's own `/var/lib/pacman/sync` isn't available.
  - Two real bugs surfaced building this, both from the same root cause:
    bash's `read` silently collapses *consecutive* IFS-whitespace
    separators (tab counts as whitespace regardless of what IFS is set
    to), corrupting any parse the instant a middle field is empty -- found
    by tracing a resolution where a package with no depends/provides
    looked like it "depended on" its own filename. Fixed by switching this
    subsystem's internal field separator from tab to `\x1f` (verified
    directly that bash's read does NOT collapse it). Second: the "already
    resolved" dedup only tracked the originally-*requested* spec name, not
    the actual resolved package name -- a package reachable via multiple
    aliases (a soname/virtual reference in one place, its real name in
    another) got processed and printed once per alias, caught by the same
    cava-vs-real-pacman diff (matching unique-name count, but 48 duplicate
    lines).
  - Also: building the sync-db index by spawning a handful of `awk`
    processes per package (the first version) meant tens of thousands of
    forks for a large repo (~7300 packages in Artix's "world") and was
    slow enough to look hung. Rewritten as one `awk` invocation processing
    every extracted `desc` file in a single pass.
  - **New hard requirement this surfaced**: none of this is usable from
    inside the booted OS without an HTTP client, and FloraOS shipped none
    (confirmed by literally running `fau install` after boot: "curl:
    command not found"). Added `curl` + `mbedtls` (its TLS backend --
    mirrors are HTTPS-only; picked over OpenSSL for a plain-Makefile,
    no-cmake build and a smaller footprint, matching this project's
    existing bias) + a CA certificate bundle (curl's own maintained Mozilla
    root extract, `config/versions.conf`'s `ca-certificates` entry --
    that's a plain data file, not a compiled package, so it's fetched
    directly in build-rootfs.sh rather than going through the recipe
    pipeline, which assumes every pinned download is a tarball). curl is
    trimmed to exactly what fau's own fetches need: HTTP/HTTPS only (no
    FTP/telnet/gopher/mqtt/etc), no libpsl, no libidn2, no nghttp2 -- none
    of that is shipped or needed for fetching from a fixed set of mirror
    hostnames. Verified with a real end-to-end run inside actual QEMU: real
    DHCP lease, a real HTTPS request, then `fau install tree` succeeding
    from inside the booted OS with `pacman` and `/etc/pacman.conf`
    genuinely absent (not just build-time reasoning).
- **Reproducibility is native, not bolted on**: every bootstrap/bootstrap-remove
  updates `/var/lib/fau/system.json`, an exact manifest of installed
  package names and pinned versions. `fau bootstrap-export` dumps it (e.g.
  for backup or copying to another machine); `fau bootstrap-apply
  system.json` installs the exact package set from that manifest onto a
  fresh root. This gives declarative, versioned reproducibility — not
  Nix-style content-addressed/bit-identical builds, which was explicitly
  scoped out as too large for a lean, auditable, purpose-built tool.

## App isolation: per-app directories under ~/apps/

The base OS (kernel, glibc, coreutils, bash, util-linux, sysvinit, openrc,
etc.) uses the standard FHS layout described above — it has to, since it's
needed to boot and run the system before any user or home directory exists.

User-facing software installed later is different: `fau install <name>`
puts everything for that app under `~/apps/<name>/` (files, plus its own
`config/`, `cache/`, `data/`, `logs/` subdirectories) instead of merging it
into `/usr` and `/etc`. A generated wrapper script in `~/apps/.bin/` sets
`HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME`/`XDG_DATA_HOME`/`XDG_STATE_HOME` to
point inside that directory before exec'ing the real binary, so an app like
Firefox ends up with everything — binary, config, cache, logs — contained in
one place, and `fau remove firefox` deletes exactly that one directory
with nothing left behind elsewhere.

This is the same idea as GoboLinux's per-program filesystem, scoped to user
apps instead of the whole OS (see the earlier discussion on scope). The real
limit: it only works cleanly for apps that respect the XDG Base Directory
spec (most modern Linux software does, including Firefox) — an app that
hardcodes absolute paths won't cooperate with the wrapper's redirection.
That's a known limitation, not a bug, and isn't worth solving generically for
a small purpose-built tool.

## Bootloader: GRUB (BIOS + UEFI), via the build host's grub-mkrescue

A hybrid ISO needs both boot paths. Originally planned as syslinux (BIOS) +
GRUB (UEFI) built from source, but `grub-mkrescue` alone produces a hybrid
BIOS+UEFI bootable ISO in one step — it embeds GRUB's own i386-pc and
x86_64-efi boot images directly into the ISO's boot catalog. That runs before
FloraOS's kernel is even loaded, so GRUB here is build-host tooling (like
`gcc` or `xorriso`), not a FloraOS package. Dropped the from-source
syslinux+grub build entirely: no loss of functionality, and it removes a
build path that would've required compiling 16-bit real-mode boot code.

## Build pipeline: scripts/build-rootfs.sh, build-iso.sh, apply-skeleton.sh

Every package is compiled from pinned upstream source (`config/versions.conf`),
staged, packaged as a `.fau.tar.zst`, and installed via `fau bootstrap` --
nothing touches the real host system, everything lives under `work/`
(gitignored). `build_package`'s `already_built` check lets a retry after a
downstream failure skip already-packaged steps (kernel, glibc) instead of
redoing the whole pipeline; `rm work/repo` forces a full rebuild. `PKG_BIN` is
reset before every recipe specifically because `build_package` runs in one
long-lived loop over `BUILD_ORDER` -- without resetting it, a package after
one that set it (for `fau install`'s isolated-app path) would silently
inherit it.

`MANDATORY_ORDER` bakes in a handful of real ordering constraints, not just a
sensible default sequence: `mbedtls` before `curl` (curl.sh links against
mbedtls's staged files directly), `kmod` before `eudev` (eudev's configure
links against kmod's staged pkgconfig file). The tail of the list (attr, acl,
grep, sed, gawk, findutils, tar, zstd, rsync, procps-ng, hostname, kbd, gzip,
libxcrypt, mbedtls, curl, kmod, eudev) exists for one reason each: fau itself,
or one of OpenRC's sysinit services, or floralogin, needs it at runtime inside
the booted OS, even though the build host already has all of them and the
build would "work" without shipping them. See each package's own one-line
reason in `docs/MANIFEST.md`.

Several FloraOS-authored C tools (floralogin, fauelf, floraseat, florauser,
florainstall) are compiled directly in `build-rootfs.sh`'s `main()`, not
through the recipe/fau-package pipeline, since they're project source, not
fetched upstream tarballs. floralogin and florauser link against
`-I/-L "$ROOTFS_DIR"` (this rootfs's own just-built libxcrypt), not whatever
`crypt()` the build host provides -- linking against the host's copy would
bake in a mismatched libcrypt SONAME the shipped image doesn't actually
provide. `sulogin`/`consoles.c` are recompiled from a second, separate
extraction of the same sysvinit tarball for the same reason: sysvinit itself
builds at position 3 in `MANDATORY_ORDER`, well before libxcrypt exists
anywhere in the rootfs, so `scripts/recipes/sysvinit.sh` drops sulogin from
that early build and this later step relinks it correctly once libxcrypt is
actually staged.

The CA certificate bundle (`config/versions.conf`'s `ca-certificates` entry)
is fetched with the same `fetch_source` used for every pinned tarball, but
skips `extract_source` and the recipe pipeline entirely -- it's a single PEM
file, not a tarball, and `extract_source` assumes every pinned download is
one.

libgcc (`libgcc_s.so.1`, the C++ exception-handling runtime) stays
bootstrapped (merged into `FAU_ROOT`) rather than installed as an isolated
app like fastfetch below -- it's base-system infrastructure other C++
binaries can reasonably assume is already present, the same way Arch/Artix
itself assumes it (it isn't a declared dependency of fastfetch, which needs
it, for exactly that reason). fastfetch still finds `libgcc_s.so.1` fine
despite being isolated: the app wrapper's `LD_LIBRARY_PATH` (see
`app_wrapper_write` in `tools/fau/fau`) is additive, prepended in front of
the dynamic linker's default trusted search path (`ld.so.cache`) rather than
replacing it, so a genuinely base-system library doesn't need to be
duplicated into every isolated app's own directory just to be found.
`FAU_ROOT` is still set for that `fau install fastfetch` call even though
`install` never merges into it, because `FAU_CACHE_DIR` (the alpm
sync-db/index cache) derives from `FAU_ROOT`, defaulting to "/" otherwise --
which would try to write into the build host's own `/var/cache/fau`
(permission denied) instead of staying scoped under `work/`. Reusing the same
`ROOTFS_DIR` as the preceding libgcc bootstrap call also means the fastfetch
install reuses that call's already-fetched sync db instead of re-fetching it.

fastfetch is installed as an isolated app (`fau install fastfetch`) purely for
branding, landing under the build host's staging path
(`$ROOTFS_DIR/root/apps/fastfetch`) rather than the path it'll actually run
from once booted (`/root/apps/fastfetch`). `app_wrapper_write` bakes in
whatever `FAU_APPS_DIR` it was given verbatim, so the generated wrapper's
`exec` line pointed at a build-host-only path and login failed with "No such
file or directory" -- caught by an actual `./floraiso test` boot, not
inferred. Fixed by `sed`-stripping the `$ROOTFS_DIR` prefix back out of the
wrapper script after the install, since every path in it is `$ROOTFS_DIR` plus
the same suffix it'll have at `/` once booted.

`build-rootfs.sh` stages fau as one directory (`/usr/lib/fau/`) so every
`fau-*` tool keeps finding its siblings and `lib/*.sh` the same way it does in
the source tree (relative to its own `$BASH_SOURCE`) -- only `/usr/bin/fau`
itself is a symlink into it, the one entry point `PATH` needs.
`tools/fau/recipes/*.fis` (fau-build's own recipes, `FAU_RECIPES_DIR`) are a
separate thing entirely from this directory's own `scripts/recipes/*.sh`:
base-rootfs packages built once, here, on the build host, never touched by
fau at runtime, versus recipes fau-build compiles from source directly on an
already-booted live system, on demand. The distinct `.fis` ("fau install
script") extension exists purely so the two are never confused for each
other at a glance -- it's still plain bash, no special syntax.

fau's alpm (Arch/Artix repo) fallback needs to know which mirror and repos to
ask once running inside a booted FloraOS system, where `/etc/pacman.d` and
`/etc/pacman.conf` don't exist. `build-rootfs.sh` copies the build host's own
mirrorlist/repo list to `/etc/fau/pacman-mirrorlist`/`pacman-repos` if
present; if the build host has no pacman config at all, the build logs a
warning and skips both that step and the libgcc/fastfetch install, rather than
failing outright.

`build-iso.sh` packs the entire rootfs as the initramfs and the kernel execs
`/init` from it directly -- FloraOS boots and runs entirely from RAM. Packing
deliberately excludes everything under `./boot` (GRUB reads
`boot/vmlinuz-floraos` straight off the ISO's own `boot/` directory; embedding
the kernel a second time inside the initramfs it boots from would be
redundant) -- which is exactly why `build-rootfs.sh` stages a second copy of
the kernel at `/usr/lib/floraos/vmlinuz-floraos` purely for florainstall's own
use, since the running live system otherwise has no kernel image anywhere in
it to copy onto a real disk. The final `floraos.iso.sha256` records a
relative filename rather than the absolute build path, so
`sha256sum -c floraos.iso.sha256` still works from a different clone or a
standalone downloaded copy of the ISO, not just this exact build directory.

The initramfs pack used `gzip -9`; measured directly against a real 519MiB
built rootfs, that's 54s for a 183.2MiB image versus `gzip -6`'s 12.5s for
184.2MiB -- ~4x faster for 0.5% larger, so `build-iso.sh` uses `-6`. `gzip -1`
was also measured (3.6s, 200.0MiB) but the size cost there is no longer
negligible.

`build-iso.sh` used to only invoke `build-rootfs.sh` if `$ROOTFS_DIR` didn't
already exist -- a real bug, found by actually building and booting the
result: since `build_package`'s own `already_built` check already makes
re-running `build-rootfs.sh` cheap when packages haven't changed, that outer
guard served no purpose except silently shipping a stale rootfs whenever
`fau`/`floralogin`/`florauser`/etc. source changed without deleting
`work/rootfs` first (`./floraiso build` reported success and a correct-looking
ISO size, but it had just repacked hours-old binaries). Fixed by always
calling `build-rootfs.sh` unconditionally.

`apply-skeleton.sh` applies the `/etc` skeleton, identity files, and the
sysvinit/OpenRC glue on top of an already fau-bootstrapped rootfs (run after
`fau bootstrap`, before `ldconfig`). `/usr/bin/sh` is symlinked to bash
because every `#!/bin/sh` script (OpenRC's own init-early.sh/init.sh included)
otherwise fails to exec at all -- and the kernel reports the *script's* path
as "No such file or directory" when the real problem is the missing shebang
interpreter, which is easy to mistake for something else entirely. OpenRC's
own `etc/init.d/hostname` service ignores `/etc/hostname` and reads
`hostname=` from `etc/conf.d/hostname` instead (upstream defaults that to
"localhost"); without writing `conf.d/hostname` too, `floraos.conf`'s
`HOSTNAME=` silently never took effect and the booted system always came up
as "localhost".

**A real, unresolved scheduling gap found across several from-scratch
rebuilds**: a custom-authored `openrc-run` script for dhcpcd, symlinked into
`etc/runlevels/default/`, never actually gets scheduled by OpenRC's own
dependency resolution at boot -- confirmed with and without `provide net` in
its `depend()`, and with and without OpenRC's own legacy
`etc/init.d/network`/`etc/init.d/staticroute` (both of which also
`provide net`) present. `rc-status default` only ever showed
netmount+local; dhcpcd never appeared at all (not started, not crashed),
while running the exact same script by hand (`/etc/init.d/dhcpcd start`)
always worked immediately. Rather than chase further into OpenRC's
dependency-cache internals, both dhcpcd and, later, `udevd`/`floraseat` are
instead driven directly from `/etc/inittab` as `once`/`respawn` entries,
sidestepping the whole runlevel dependency resolution rather than solving it.
The two legacy scripts (`network`, `staticroute`) were removed from the boot
runlevel as dead weight (FloraOS relies entirely on dhcpcd, with no
`/etc/ifconfig.*`/`/etc/route.conf` files for them to act on) and ruled out,
not confirmed, as the actual cause -- removing both still left dhcpcd
unscheduled. dhcpcd and udevd's inittab entries redirect output to
`/dev/null`: sysvinit starts a `once` entry concurrently with the `respawn`
agetty entries below it rather than sequentially, so unredirected
ebegin/eend/dhcpcd-privsep-warning output otherwise races the login prompt on
the same console and visibly garbles both. This doesn't hide real failures --
dhcpcd's own lease errors etc. still exit non-zero and are visible via
`rc-service dhcpcd status`.

`depmod` (modules.dep/modules.alias for kmod/eudev) runs at build time, baked
into the image, rather than being left for boot: this image is RAM-resident
and rebuilt from scratch every time anyway, so there's no "the kernel changed
since last boot" case depmod would normally exist to handle. It needs the
kernel's own release string (`linux-lts.sh`'s `make kernelrelease` output,
written to `boot/kernelrelease`) explicitly, since depmod otherwise defaults
to `uname -r` of whatever machine runs it -- the build host's kernel, not
FloraOS's. Runs cross-root the same way `ldconfig -r` does just before it: a
plain userspace indexing tool over files, no actual module loading involved.

**libinput silently hangs forever on the virtual ACPI "Power Button" device
(`LNXPWRBN`)**, found running `mango` (a wlroots-based compositor) for real:
the compositor's own startup log (`mango -d`) runs cleanly all the way through
DRM backend init, EGL, GBM allocator, and even scenefx's renderer ("FX
RENDERER: Shaders Initialized Successfully"), then stops dead at
`[backend/libinput/backend.c] Starting libinput backend` -- no crash, no
further output, process stays alive indefinitely. `/proc/<pid>/stack` on the
live process showed it blocked in the kernel's `evdev_read`, and
`/proc/bus/input/devices` identified the specific device as `event0`, `N:
Name="Power Button"` -- not the real keyboard (`event1`) or mouse (`event2`).
`udevadm info -q property -n /dev/input/event0` confirmed udev tags it
`ID_INPUT_KEY=1` (correct, standard behavior -- it does have `KEY_POWER`, and
every machine, real or QEMU, exposes this exact device), so libinput picks it
up and tries to manage it like any other keyboard, but its own device-add
sync blocks forever on this specific device rather than returning. No
compositor ever needs raw power-button events through libinput anyway --
that's normally handled by a separate ACPI listener -- so the fix is to keep
libinput from ever touching it in the first place, via `LIBINPUT_IGNORE_DEVICE`
(confirmed via `strings` on the real alpm-fetched `libinput.so.10`, sitting
right next to `ID_INPUT_KEY`/`ID_INPUT_KEYBOARD` -- libinput's own documented
udev property for excluding a device outright), added as a local override
rule (`etc/udev/rules.d/71-libinput-ignore-power-button.rules`,
`scripts/apply-skeleton.sh`) scoped to `ATTRS{name}=="Power Button"` so only
that device is excluded.

**That fix turned out to be real but incomplete** -- proven by testing it for
real, not by inspection: `udevadm info` on a fresh boot confirmed
`LIBINPUT_IGNORE_DEVICE=1` was actually applied, yet `mango` still hung at
the exact same `Starting libinput backend` point. Re-running the same
`/proc/<pid>/stack`/`/proc/<pid>/fd` inspection on the new hang showed it
now blocked on `event1` -- the real keyboard -- instead of `event0`. The
Power Button wasn't special; it was just first in enumeration order. Every
evdev device floraseat hands out triggers the same block, one at a time.

**Actual root cause: `floraseat`'s own `handle_open_device()`
(`tools/floraseat/floraseat.c`) opened every device fd -- DRM, evdev,
hidraw alike -- without `O_NONBLOCK`.** libinput's own device-add sync does
a plain `read()` expecting an immediate `EAGAIN` once the kernel's event
backlog drains, not a genuine wait for the next event; without
`O_NONBLOCK` that `read()` blocks for real, on literally any device,
because a real event might never come (nobody's touched a freshly-added
device yet). Fixed by adding `O_NONBLOCK` to floraseat's single shared
`open()` call. This is also just the objectively correct flag for any fd
handed to an epoll-driven consumer (both libinput and wlroots' own DRM
backend read events this way), not a narrow libinput-specific workaround.
The `LIBINPUT_IGNORE_DEVICE` rule above stays regardless -- routing power
button events through libinput was never correct on its own merits, real
hardware included -- but it was never the actual fix for the hang.
Confirmed fixed on a real boot, not just in theory: `mango` rendered an
actual desktop for the first time this project has ever seen one.
Qsenja screams "IT WORKED OH MY GOD" because this was the moon-landing
moment for FloraOS's entire GUI effort -- from a black screen and a wall
of misdirection (EGL vendor paths, GBM backend paths, Xwayland/libinput
isolation gaps) down to one missing flag in one custom daemon.

**No message bus of any kind ran anywhere on FloraOS**, found running
`kitty` for real, after the fontconfig fix above got it past its earlier
crash: `[glfw error]: Failed to connect to DBUS session bus. DBUS error:
Unable to autolaunch a dbus-daemon without a $DISPLAY for X11`. That
"autolaunch" fallback (what libdbus tries whenever
`DBUS_SESSION_BUS_ADDRESS` isn't set) is genuinely an X11-only mechanism
-- it stores/reads the bus address via an X11 root window property -- so
it fails on the missing `$DISPLAY` even on a pure-Wayland session; the
real problem underneath is simply that no bus was running to connect to
in the first place. Fixed by installing `dbus` at the base-system level
(`build-rootfs.sh`, same `bootstrap` mechanism as `fontconfig`/
`ttf-dejavu` above -- a message bus is inherently a shared service, not
a per-app library) and starting `dbus-daemon` at boot as another inittab
`once` entry (`apply-skeleton.sh`, same pattern as `dhcpcd`/`udevd`) on
a fixed address rather than the usual per-session dynamic one, since
FloraOS only ever has one active session at a time. Started with
`--address=unix:path=/run/dbus/session_bus_socket` explicitly, not
`--session` alone: verified with `bwrap` that this needs no
`/etc/dbus-1` config file at all (which `install_one_alpm`'s own
`/etc`-strip would have dropped anyway, same as fontconfig) --
`--address` overrides the one thing `session.conf` would otherwise
supply, and a real client (`dbus-send`) connected and got a real reply
with zero config present. `DBUS_SESSION_BUS_ADDRESS` set in
`/etc/profile` alongside `LANG`/`PATH` so every login shell (and
anything spawned from it) can find the same fixed socket.

root's `/etc/shadow` entry ships with an intentionally empty password field
(traditional Unix for "no password required"), documented in `/etc/issue` so
a first-time user sees it before being asked for credentials -- appropriate
for this live, RAM-resident image, which has no persistent install yet and no
`passwd(1)` built to change it.

## Test harness: QEMU serial-console automation (scripts/lib/common.sh)

`scripts/test-iso.sh`, `test-install.sh`, and `test-install-uefi.sh` all drive
a real QEMU boot entirely over its serial console rather than watching
output passively, since floralogin gates the console and a plain read-only
`-serial file:` redirect can watch boot output but can't answer the login
prompt. `scripts/lib/common.sh` factors this into four functions
(`test-iso.sh` predates that factoring and still carries its own inline copy
of the same pattern -- see its own header comment):

- **`qemu_boot_serial`** starts QEMU in the background with a Unix-socket
  serial chardev (so it can be both written to and read from) and a
  Unix-socket monitor (so `qemu_quit` can shut it down cleanly later), then
  bridges the serial socket to a growing log file via `socat`. The fifo used
  to feed `socat` is opened read-write (`exec {QEMU_FD}<>"$QEMU_FIFO"`), not
  write-only: opening a fifo write-only blocks until some *other* process has
  it open for reading, but `socat` (the intended reader) only starts on the
  next line, so a plain write-only open here would deadlock the script
  against itself. `<>` is the standard trick to open a fifo without a peer
  present yet, and it also keeps the fifo held open for the whole session --
  a fifo's read end otherwise sees EOF the instant any single writer closes,
  which would end the `socat` session after the first thing sent. `socat`'s
  own address is given as `-` (stdio) rather than the fifo path directly:
  passing the fifo path as one of `socat`'s two endpoints makes it copy the
  socket's output back into that same fifo too, since a fifo is one shared
  queue, not two independent lanes -- confirmed by testing the construct in
  isolation before it went into the real script. Redirecting stdin from the
  fifo and stdout to the log file keeps the two directions properly
  separated. Each session is namespaced by a `<tag>` argument so sequential
  sessions in one script (install, then boot1, boot2, ...) don't collide;
  only one session may be open at a time per shell, since the session state
  is global, not stacked.
- **`qemu_wait_for`** polls the growing log file for a literal substring
  instead of guessing at timing with a `sleep`. This matters because
  whatever's on the other end of the line (agetty, a shell, florainstall's
  own log output) can flush a backlog before it's actually at the point the
  test cares about -- and, separately, agetty flushes whatever arrived on the
  line before it actually starts prompting, so sending input blindly right
  after QEMU starts (well before boot reaches the prompt) gets silently
  discarded rather than queued.
- **`qemu_send`** writes raw bytes with no implicit newline; callers pass
  `\r` themselves, matching what a real terminal sends on Enter (the tty line
  discipline's ICRNL then turns it into `\n` for whatever's reading on the
  other end).
- **`qemu_quit`** shuts QEMU down via its monitor's `quit` command rather
  than SIGTERM/SIGKILL, so a virtual disk's write-back cache flushes cleanly
  instead of racing a signal against in-flight writes -- this matters
  specifically because `test-install.sh`/`test-install-uefi.sh` reuse the
  same disk image across several `qemu_boot_serial` sessions.

`test-install.sh`'s `qemu_run` helper (waiting for a fresh shell prompt to
reappear, by counting occurrences of the PS1 marker) replaced an earlier
version that instead waited for a sentinel string embedded in the command
itself (e.g. `cat marker.txt; echo MARKER_DONE`, then waiting for
`MARKER_DONE`). That approach was unreliable: a pty echoes back whatever
bytes you send *immediately*, well before the shell even processes the
trailing Enter, so the wait could be satisfied by the echoed *input* rather
than the command's real output, racing ahead of it by an unpredictable
margin. This was intermittent, not deterministic -- it passed several runs
before failing three checks at once in a way that first looked like a real
regression. Counting fresh prompts sidesteps this entirely, since a new
prompt only ever appears after the previous command's own output has already
been flushed, and nothing about a command's own text can satisfy "a new
prompt line appeared". `qemu_run_ok` extends this to also confirm exit status
0 via a follow-up `echo "RC=$?"` -- safe from the same race, since the raw
bytes sent contain a literal, unexpanded `$?` that can never itself satisfy a
grep for `RC=0`.

`test-install.sh` and `test-install-uefi.sh` both write their pass/fail result
to a file (`$WORK_DIR/test-install-result.txt` /
`test-install-uefi-result.txt`) in addition to logging: nested backgrounding
across several sequential `qemu_boot_serial` sessions in one script has been
observed to truncate the script's own captured stdout partway through in
some invocation contexts (background-tool capture specifically), even though
every phase genuinely ran to completion. The result file and the per-phase
`$WORK_DIR/qemu-*-boot.log` transcripts are the authoritative record
regardless of what a live terminal/capture saw.

`test-install-uefi.sh` is a deliberate sibling to `test-install.sh`, not
folded into it: the two scripts only differ in partitioning and the
bootloader install/boot step itself (BIOS/SeaBIOS vs. OVMF/UEFI with a
`--removable` EFI fallback). `test-install.sh`'s later phases
(backup/grub-reboot/restore) are entirely platform-agnostic, so re-running
all of them under OVMF would just re-prove the same logic a second time.
`test-install-uefi.sh` searches a handful of real, common OVMF firmware
install paths across distros (Arch's edk2-ovmf, Debian/Ubuntu's ovmf,
Fedora's edk2-ovmf) rather than hardcoding one, and its second boot phase
uses a completely fresh `OVMF_VARS` template (no NVRAM entries at all) to
specifically confirm the `--removable` fallback path
(`EFI/BOOT/BOOTX64.EFI`) boots without depending on any NVRAM entry
`grub-install` might have registered -- the state a real firmware's NVRAM
would be in on a disk moved to different hardware.

`test-iso.sh` additionally boots with `-m 2048`, not 1024: this whole rootfs
is RAM-resident with no separate `/tmp` mount, and 1024 isn't enough headroom
for `fau install` of anything with a non-trivial alpm-fallback dependency
closure (an isolated app directory doesn't strip `etc/`/`usr/include` the way
the base system's own bootstrap path does) -- e.g. cmatrix's closure (full
unstripped glibc, locale files included) ran a real boot out of disk space
mid-copy at 1024 and completed cleanly at 2048. The ISO boot test itself only
checks boot+login, not a package install, but matching what a real
interactive session needs avoids the boot test passing while post-boot usage
silently doesn't fit.

## Not yet scripted (documented per the "TODO over silence" rule)

- TODO: persistent syslog daemon — no concrete logging requirement yet: skip
  for now, add when one shows up.
- DONE: `fau install <pkg>`'s alpm (Arch/Artix repo) fallback could silently
  produce a broken binary for any app whose real Arch/Artix package bakes an
  absolute path into a `DT_NEEDED` entry instead of a bare soname (found via
  `fau install neovim`: its lua51-lpeg dependency needs
  `/usr/lib/lua/5.1/lpeg.so`, a literal absolute path, not `liblpeg.so`).
  That's invisible for a system-root bootstrap merge (`FAU_ROOT` really is
  `/`, so the absolute path happens to resolve) but breaks an isolated
  app-install outright: the dynamic linker only consults
  `LD_LIBRARY_PATH`/RPATH for a *bare* soname, so an absolute `DT_NEEDED`
  bypasses the app wrapper's own `LD_LIBRARY_PATH` entirely and fails with
  "cannot open shared object file" even though the dependency is correctly
  bundled inside the app's own directory — reproduced directly in a real
  chroot of the built rootfs (`nvim -h` failing on exactly that path), not
  inferred from reading the code. Fixed with a new small from-scratch tool,
  **fauelf** (`tools/fauelf`, same "small, auditable, purpose-built instead
  of vendoring patchelf" philosophy as `fau`/floralogin themselves): rewrites
  any absolute `DT_NEEDED` string to its bare basename in place (always
  safe — strictly shorter, NUL-padded into the same slot, no relocation).
  Wired into `app_install_one_alpm` (tools/fau/fau), run over every
  extracted file before the merge into the app's own directory.
- DONE: `alpm_find_provider`'s PROVIDES fallback (tools/fau/fau) used to do
  a plain bash `while read` linear scan over a whole repo's index (thousands
  of packages) for every dependency spec that isn't found by exact name --
  which in practice is nearly every real Arch/Artix dependency, since those
  are mostly soname specs (`libc.so=6-64`) rather than the package's own
  name. Found resolving a large closure (`fau install neovim`, ~50+
  packages) taking noticeably long. Fixed the same way `alpm_repo_index`
  itself already solved the equivalent problem for exact-name lookups (one
  `awk`-processed index up front instead of spawning per-package processes,
  see this file's own fau section, "building the sync-db index" bullet):
  added `alpm_repo_provides_index`, a second index keyed by *provided*
  name (one row per provided-name/provider-package pair, built from the
  same cached by-name index in one more `awk` pass), so the PROVIDES
  fallback is now an `awk` lookup (returning only the handful of rows that
  actually provide the wanted name) followed by a bash loop over just
  those few rows, not the whole repo. Verified two ways: resolving
  neovim's real ~50+ package closure against the exact same warm sync-db
  cache, old code vs new, byte-identical output (`diff` clean) at 6.9s vs
  1.1s (~6x); and a fully cold-cache `fau install neovim` (no cached
  index/provides-index at all) still installs and runs correctly.
- DONE: `fau backup` — a full-root snapshot (not just `system.json` + app
  configs, which `fau export`/`fau import` already cover) that's restorable
  from the GRUB boot menu. This was blocked on three things: no persistent
  disk install, no multi-entry GRUB support, and no early-userspace step
  reading `/proc/cmdline` for a custom parameter before sysvinit starts.
  **florainstall** (`tools/florainstall`, see below) closed the first gap.
  The third turned out to be unnecessary, not just unaddressed: confirmed
  directly against this repo's own vendored kernel source
  (`work/build/linux-lts/fs/btrfs/super.c`) that `rootflags=subvol=` is
  resolved to a subvolume objectid entirely inside the kernel's own btrfs
  mount code, before sysvinit/inittab ever runs, and that a live mount stays
  pinned to that objectid (not to the path string) for its whole lifetime.
  So "restore" doesn't need a cmdline-parsing pre-init hook at all -- it just
  means "GRUB boots straight into a different subvolume", and renaming a
  subvolume out from under a currently-mounted-as-root system is safe (this
  is exactly how openSUSE's snapper/grub-btrfs rollback works in
  production), closing the second gap along with it.

  Concretely: florainstall now creates the target as an `@` subvolume (not
  the bare top-level) with fstab's `/` line reading `subvol=@,defaults`;
  `@snapshots` is a lazily-created sibling of `@`, holding one subvolume per
  backup. `/boot/grub/grub.cfg` is no longer hand-written by florainstall --
  it's generated by the new **floragrub-cfg** (`tools/floragrub-cfg`, a
  small bash tool, not compiled, staged into the rootfs the same way `fau`
  itself is), which writes the default `@` entry plus one
  `menuentry "FloraOS (backup: <name>)"` per subvolume under `@snapshots`
  (`rootflags=subvol=@snapshots/<name>`, kernel/root path prefixed with the
  subvolume name -- `/@/boot/...` / `/@snapshots/<name>/boot/...` -- since
  GRUB's own absolute-path file reads on btrfs resolve against the
  filesystem's top-level subvolume by default, same as real distros'
  grub-mkconfig output for a root-in-subvolume layout; not independently
  checked against GRUB's own source here since GRUB is fetched precompiled
  via alpm, not built from source in this repo). `tools/fau/fau` gained
  `backup <name>` (read-only snapshot + grub.cfg regen), `backup-list`,
  `backup-remove <name>`, and `backup-restore <name>` (promotes a snapshot
  to be the new `@`, renaming the current root aside as
  `@pre-restore-<name>-<timestamp>` rather than deleting it outright --
  reboot is required afterward to actually boot into the promotion, the
  running session stays on the old root until then). `restore`'s
  flip-read-only-off -> rename -> rename sequence is NOT atomic -- a crash
  between the two renames is a real, documented risk (surfaced in both the
  tool's own error messages and here), not silently glossed over. Since
  first written, this got two real improvements without solving the
  underlying problem (no tool this project ships exposes
  `renameat2(RENAME_EXCHANGE)`, the only way to swap two subvolume names in
  one syscall -- see docs/TODO.md):
  - The read-only-clearing `btrfs property set` now runs *before* either
    rename, not sandwiched between them. It's the one step that can fail
    for reasons unrelated to a hard crash (e.g. a transient ioctl error),
    and doing it first means that failure mode never touches `@` at all --
    only an actual crash landing inside the two-rename window itself is
    still a risk, which is as narrow as this gets without RENAME_EXCHANGE.
  - Realized that a crash in that window doesn't actually brick the
    system, just its *default* boot entry: `@snapshots/<name>` is
    untouched right up until the very last rename, so the GRUB menu's
    "FloraOS (backup: `<name>`)" entry still boots fine even when the
    default "FloraOS" entry (`subvol=@`) can't find `@` anymore. `fau
    backup-repair <name>`, run after booting that still-working entry,
    finishes the interrupted promotion (`_backup_repair_do` in
    `tools/fau/fau`): refuses outright if `@` already exists (nothing to
    repair, or the wrong command), dies with a clear "recover manually"
    message if `@snapshots/<name>` is *also* gone (a state repair doesn't
    know how to fix, since it can't tell what's actually the current
    state anymore, versus the state it does handle where the crash-time
    invariant is known: `@` missing, `@snapshots/<name>` still present),
    otherwise clears read-only and completes the rename. Takes `<name>`
    as an explicit argument rather than scanning for `@pre-restore-*-*`
    markers and guessing which one -- the caller already knows which
    backup they just booted into, so there's no ambiguity to resolve.
    Not yet exercised against a real induced crash in
    `scripts/test-install.sh` (that would mean killing QEMU mid-rename at
    the right instant, which the harness doesn't do yet) -- verified by
    reasoning through the exact state each `mv`/`btrfs property set` call
    leaves behind, and by running `backup-repair` by hand against a
    manually-reproduced "renamed @ aside, snapshot not yet promoted"
    state, not by an automated crash-injection test.

  Boot-tested end-to-end for real, in QEMU/KVM, via the new
  **scripts/test-install.sh** (not just compiled/shellchecked -- this
  sandbox does have `/dev/kvm`, contrary to what an earlier pass assumed):
  drives florainstall's ncurses TUI over the serial console (arrow keys,
  text entry, the destructive-confirm prompt) to install onto a scratch
  disk image, then reuses that disk across three more boots to check
  `/proc/cmdline` directly for `rootflags=subvol=@`, take a `fau backup`,
  `grub-reboot` into it once and confirm (again via `/proc/cmdline`) it's
  really running `@snapshots/<name>`, confirm a marker file written before
  the backup and overwritten after it still reads the *old* value inside
  the snapshot, `fau backup-restore` it from *within* that booted snapshot
  (the specific "rename the subvolume you're currently running on" case),
  then reboot again and confirm the promotion stuck. Four real bugs
  surfaced this way, none of them guessable from reading the code, all
  fixed:
  - `root=UUID=<fs-uuid>` panics at boot ("Cannot open root device") --
    resolving a *filesystem* UUID (not a GPT PARTUUID) to a device
    normally happens via `/dev/disk/by-uuid/`, populated by udev/eudev,
    which can't run before its own root is mounted, and there's no
    initramfs here to do it earlier either. GRUB's own `search --fs-uuid`
    a moment earlier is a *completely separate* resolution path and worked
    fine, which masked this until an actual kernel boot caught it.
    Fixed by having floragrub-cfg emit `root=<device-path>` (e.g.
    `/dev/sda1` -- florainstall/fau already have this in hand) instead,
    a real but honestly-documented limitation for multi-disk hardware
    whose BIOS might enumerate disks in a different order across boots.
  - `findmnt -n -o SOURCE /` prints `/dev/sda1[/@]` for a btrfs subvolume
    mount, not plain `/dev/sda1` -- `fau backup` died with "isn't a block
    device" on the very first real disk boot. Fixed with a `root_device()`
    helper (tools/fau/fau) that strips the bracketed suffix.
  - `mktemp -d`'s default location (under `/tmp` on the *currently mounted*
    root) breaks when run from within a deliberately read-only `fau
    backup` snapshot (`mktemp: ... Read-only file system`) -- surfaced
    running `fau backup-restore` from inside the booted snapshot, exactly
    the scenario that command exists for. Fixed by pointing both
    `fau`'s `backup_with_toplevel` and floragrub-cfg's own transient mount
    at `/dev/shm` instead, which devfs's own init script always mounts as
    its own tmpfs regardless of what's mounted as `/`.
  - `grub-reboot` silently had no effect at all -- it writes `next_entry`
    into `/boot/grub/grubenv`, but the hand-written grub.cfg never read
    `grubenv` back, so `set default=0` won -- unconditionally -- every
    time. Fixed by adding the standard (if minimal -- no `saved_entry`/
    `grub-set-default` support, this project doesn't offer that)
    `load_env`/`next_entry` boilerplate real grub-mkconfig output also
    relies on.

  scripts/test-install.sh itself needed one real fix along the way, worth
  recording since it'll bite anyone extending this style of test: waiting
  for a sentinel string that's *part of the command you're sending* (e.g.
  `cat marker.txt; echo MARKER_DONE`, then waiting for `MARKER_DONE`) is
  unreliable -- a pty echoes back whatever bytes you send immediately,
  well before the shell even processes the trailing Enter, so that wait
  can be satisfied by the echoed *input* rather than the command's real
  output, racing ahead of it by an unpredictable margin (intermittent,
  not deterministic -- it passed several runs before failing three checks
  at once in a way that first looked like a real regression). Fixed by
  waiting for the shell prompt itself to reappear (`qemu_run`, counting
  occurrences of the PS1 marker already used for login) instead of a
  custom sentinel, before checking real output separately.
- DONE: `depends=` entries can now carry an optional version constraint --
  `name`, `name>=1.2`, or `name==1.2` (comma-separated, as always). If an
  already-installed dependency doesn't satisfy it, fau reinstalls it from
  the repo and re-checks; if the repo's own version still doesn't satisfy
  it, fau dies with a clear message instead of silently proceeding with an
  unsatisfied dependency. Deliberately just these two operators, compared
  via `sort -V` (coreutils, already a base package) rather than a
  hand-rolled semver parser -- full range solving is still explicitly out
  of scope, this just closes the gap where an already-installed dependency
  could be too old for what actually needs it. No package in the current
  manifest uses a constraint yet; verified with synthetic test packages.
  Fixing this also surfaced a real, unrelated bug in the merge step itself:
  `install_one`'s `rsync -aK` (no `-c`/`--checksum`) uses rsync's default
  quick-check (same size + same mtime => skip), which silently kept OLD
  file content on an upgrade whenever two versions of a file matched in
  both -- reproduced directly (bumped a test package 1.0 -> 2.0 with
  same-size files; the "upgraded" file kept serving 1.0 content while
  system.json claimed 2.0). Fixed by adding `--checksum` to both of fau's
  `rsync -aK` merge calls.
- DONE: real password-backed login. util-linux's own login/su/runuser/
  chfn/chsh still require PAM to build at all (confirmed straight from
  configure.ac: `UL_REQUIRES_HAVE([login], [security_pam_appl_h], ...)`,
  with no non-PAM fallback path -- upstream fully committed to PAM years
  ago), and PAM still isn't part of FloraOS. Rather than adding PAM itself,
  FloraOS now ships **floralogin** (`tools/floralogin/floralogin.c`), a
  ~100-line from-scratch login written the same way `fau` was: small,
  auditable, purpose-built, no PAM. It verifies the typed password against
  `/etc/shadow` via `crypt(3)` -- which glibc itself dropped a few versions
  back, so **libxcrypt** (`scripts/recipes/libxcrypt.sh`, built with
  `--enable-obsolete-api=glibc` for the traditional ABI) is now a base
  package too, purely to give floralogin something to link against.
  `/etc/inittab` now runs `agetty --skip-login --login-program
  /usr/bin/floralogin` on tty1/ttyS0 (agetty itself never needed PAM) instead
  of spawning bash directly -- `--skip-login` matters: agetty's *default*
  behavior is to prompt for a username itself and exec the login program
  with it as an argument, but floralogin does its own full username+password
  prompt loop, so agetty needs to hand off before prompting at all, not
  after. Root's `/etc/shadow` entry keeps an empty password field
  (traditional Unix for "no password required"), which floralogin honors
  intentionally -- documented in `/etc/issue` (agetty prints it before the
  prompt) since this is a live, RAM-resident image with no `passwd` command
  built yet to set a real one. Verified end-to-end against the actual ISO,
  not just floralogin in isolation: drove a real login (and a rejected
  wrong-password attempt) through QEMU's serial console via a socket +
  named pipe (see `scripts/test-iso.sh`, which now does this on every
  `./floraiso test` run instead of just watching for the shell to appear on
  its own).
- DONE: restored **sulogin** (sysvinit's own emergency single-user-mode
  shell) -- `scripts/recipes/sysvinit.sh` used to drop it outright, with a
  comment blaming "no working password-backed login to check against yet."
  Stale the moment floralogin/libxcrypt landed (the DONE entry just above):
  sulogin.c itself was confirmed (by reading its actual source, not
  assumed) to need only `crypt(3)`/`shadow.h`, no PAM at all -- the real
  reason it stayed dropped was purely build *ordering* (sysvinit builds at
  position 3 in `MANDATORY_ORDER`, well before libxcrypt exists anywhere in
  this rootfs, so linking it there would bake in whatever libcrypt SONAME
  the *build host* happens to provide, the same class of bug floralogin's
  own `-I/-L$ROOTFS_DIR` linkage exists to avoid). Fixed the same way, not
  by reordering the whole sysvinit build: `build-rootfs.sh` now re-fetches
  the same pinned sysvinit tarball into a separate throwaway build dir
  right after libxcrypt is staged, and recompiles just `sulogin.c`+
  `consoles.c` correctly linked against it. Verified end-to-end in QEMU,
  not just compiled: set a real password via `florauser passwd root`, ran
  `/usr/bin/sulogin` directly, confirmed a wrong password is rejected
  ("Login incorrect.", re-prompts) and the correct one grants a real root
  shell -- also cross-checked with `getent shadow root` that the yescrypt
  hash `florauser` writes resolves correctly through NSS (`/etc/nsswitch.conf`
  already ships `shadow: files`), since sulogin's own `getrootpwent()`
  substitutes `getspnam()`'s real hash for `/etc/passwd`'s `"x"` placeholder
  and needs that path working. **Not wired into anything yet**, though: this
  is a real, disclosed gap found *while* verifying the above, not the thing
  being fixed -- `/etc/inittab`'s `l1:S1:wait:/usr/bin/openrc single` runlevel
  has no `etc/runlevels/single/` services defined (confirmed: the directory
  doesn't exist), so reaching single-user mode today doesn't invoke
  `sulogin` or anything else at all. See docs/TODO.md.
- PARTIAL (was: no GUI/display server at all): the three system-level
  primitives a Wayland WM/DE needs that `fau install <wm>`'s own alpm
  fallback can't provide by itself (it can fetch wlroots/mesa/sway/mango's
  *files* fine, but they had nowhere to draw pixels or manage input/seat
  access) are now in place:
  - **eudev** (`scripts/recipes/eudev.sh`): libinput/mesa/wlroots hard-require
    libudev at build and run time, no supported fallback exists upstream.
    Built `--disable-blkid --disable-selinux --disable-kmod` (all three
    degrade gracefully, none needed for device nodes/hotplug). The
    `--disable-kmod` choice means no module-autoload capability -- see the
    linux-lts point below for the other half of that tradeoff. Adds exactly
    one new build-host requirement (`gperf`), confirmed directly against the
    real eudev 3.2.14 tarball (every other configure check already passes
    with this project's existing build-host tooling).
  - **floraseat** (`tools/floraseat`): FloraOS's own seat-management daemon,
    written from scratch instead of building real seatd -- seatd is
    meson/ninja-only upstream, and this project deliberately avoids
    cmake/meson everywhere else (see mbedtls's own recipe). Speaks the real
    seatd wire protocol (verified directly against upstream
    kennylevinsen/seatd source -- protocol.h, client.c, seat.c, drm.c,
    evdev.c, hidraw.c -- not reconstructed from memory), so precompiled
    wlroots/libseat fetched via `fau install <wm>` talks to it unmodified.
    Same "reimplement the wire protocol/data format, not the codebase" idea
    as fau's own alpm fallback reading pacman's sync-db format without
    vendoring pacman. Single seat0, VT-bound (see the DONE entry just below
    for how that was added); device access is an allowlist (`/dev/dri/`,
    `/dev/input/event`, `/dev/hidraw` prefixes only, checked *after*
    `realpath(3)` canonicalization) gated by the socket's own permissions
    (`/run/seatd.sock`, 0660 root:seat), same access-control model as real
    seatd. Protocol correctness verified with a hand-written test client
    exercising open_seat/enable_seat/disallowed-path rejection/ping-pong
    end-to-end against the actual compiled binary (not just read-through)
    -- see the daemon's own file header for the full scope writeup and
    what's deliberately smaller than upstream.
  - DONE: **VT-switching in floraseat** (was: single-seat, non-VT-bound --
    fine for one login session, a real gap once a second concurrent
    graphical session needs to exist). Ported real seatd's actual VT-bound
    design (verified directly against upstream's `common/terminal.c` and
    `seatd/seat.c`, fetched and read, not reconstructed from memory) rather
    than inventing one: a client's session number now IS the VT number it
    opened the seat on (`VT_GETSTATE` on `/dev/tty0` at `CLIENT_OPEN_SEAT`
    time); activating a client puts its VT into `VT_SETMODE(VT_PROCESS)`
    with `relsig=SIGUSR1`/`acqsig=SIGUSR2`, keyboard raw-passthrough
    (`KDSKBMODE K_OFF`), and `KD_GRAPHICS`. Both signals are delivered via
    `signalfd(2)` as just another pollable fd in the daemon's existing
    `poll(2)` loop, not a classic async-signal handler -- release disables
    the outgoing client and acks (`VT_RELDISP, 1`) so the kernel proceeds;
    acquire, once the switch completes, acks (`VT_RELDISP, VT_ACKACQ`) and
    activates whichever client claims the newly-current VT.
    `CLIENT_SWITCH_SESSION` no longer touches client state directly -- it
    only issues `ioctl(VT_ACTIVATE, <target>)` and lets the release/acquire
    signals drive the actual handoff, the same "one mechanism, not two
    racing ones" reasoning upstream's own code gives for this. One
    deliberate, disclosed simplification relative to upstream: real
    seatd's `seat_add_client` refuses *any* new client while *any* client
    anywhere on the seat is active and not already mid-disable, regardless
    of which VT either is on; this project only refuses a new client
    targeting the exact same VT another still-live client already claims,
    since blocking unrelated VTs from adding a session while a different
    VT is merely active elsewhere doesn't fit this project's own
    multi-VT use case -- see floraseat.c's own header comment.
    `scripts/apply-skeleton.sh` now also starts a second getty on `tty2`
    (previously only `tty1` + the serial `ttyS0` test-automation line), so
    there's an actual second VT to switch to, and logs floraseat's own
    stderr to `/var/log/floraseat.log` instead of `/dev/null` (still no
    persistent syslog daemon, see docs/TODO.md, but a daemon's own log
    shouldn't need one to be readable at all). Boot-tested end-to-end for
    real in QEMU/KVM: **tools/floraseat/vt-test-client.c** (a small,
    permanently-checked-in but never rootfs-staged diagnostic -- speaks
    just enough of the wire protocol to open a seat and print every
    `SERVER_*` event) run as two separate instances, one per VT, with real
    `chvt` calls between them over the serial console -- confirmed the
    real release/disable/ack and acquire/re-enable sequence in
    `/var/log/floraseat.log`, including the specific edge case where a
    freshly-switched-to VT that no client has ever opened before produces
    no acquire signal at all (nobody was ever registered to receive one),
    which needed `handle_open_seat` to resync the shared current-VT state
    itself rather than trusting what the last signal had left it at --
    found by exactly this scenario failing the first test run, not
    predicted in advance. Not independently exercised: real DRM master
    handoff between two live GPU clients -- this sandbox's QEMU
    `-nographic` boot has no framebuffer for `simpledrm` to attach to, so
    `/dev/dri/card0` never appears at all (confirmed: the test client's own
    device-open call gets ENOENT), leaving the seat-level enable/disable
    protocol verified but the device-level master transfer itself
    unverified against a real DRM node.
  - **linux-lts** (`scripts/recipes/linux-lts.sh`): enables
    `CONFIG_SYSFB_SIMPLEFB`+`CONFIG_DRM_SIMPLEDRM` (generic
    firmware-framebuffer-based KMS, works on essentially any x86_64 machine
    and under QEMU with zero hardware-specific driver code -- enough for a
    software-rendered/llvmpipe Wayland session) plus
    `CONFIG_INPUT_EVDEV`/`CONFIG_USB_HID`/`CONFIG_HID_GENERIC`/
    `CONFIG_USB_XHCI_HCD` as **built-in** (not modules) via `scripts/config`
    + `olddefconfig` after `defconfig`, since there's no kmod to autoload a
    module in the first place (see eudev's `--disable-kmod` above).
  - DONE: **`/dev/dri/card0` now actually appears on a real boot** (was:
    the kernel config above was correct but had never produced a working
    DRM device end to end -- see the "Not independently exercised" note
    just above, and a real user hitting `dwm`/`mango` both failing with
    "cannot open display"/no-GPU errors). Root cause had nothing to do with
    the kernel config itself, which was already right: GRUB's own
    `grub.cfg` (`scripts/build-iso.sh`) never switched into a graphics mode
    before the `linux`/`initrd` handoff, so the kernel's `screen_info` never
    described a linear framebuffer for `CONFIG_SYSFB_SIMPLEFB`/`simpledrm`
    to wrap -- confirmed directly via `dmesg` in a real QEMU boot: the
    Bochs VGA PCI device was correctly enumerated and claimed by `vgaarb`
    as the boot VGA device, but nothing ever bound a framebuffer driver to
    it, and `/dev/dri` didn't exist. `gfxpayload=keep` alone doesn't fix
    this -- it only *preserves* whatever mode GRUB is already in, and GRUB
    defaults to its own text-mode `console` terminal, so there was nothing
    graphical for "keep" to preserve. Fixed by adding
    `insmod all_video`/`insmod gfxterm`/`set gfxmode=auto`/
    `set gfxpayload=keep`/`terminal_output gfxterm` to `grub.cfg` --
    `terminal_output gfxterm` is the part that actually makes GRUB switch
    itself into a graphics mode; `gfxpayload=keep` then carries that same
    mode into the kernel. Verified for real in a fresh QEMU boot (not just
    reasoned about): `/dev/dri/card0` now exists, and `dmesg` shows
    `[drm] Initialized simpledrm 1.0.0 for simple-framebuffer.0`. Not yet
    independently verified: an actual Wayland compositor (mango) drawing
    through this device from a real VT (tty1/tty2) -- this was tested via
    the serial console only (`-display none`, no way to see actual pixel
    output), and floraseat's own VT-bound seat handoff needs a real
    graphical VT session, not a serial one, to exercise.
  - **floralogin** (`tools/floralogin/floralogin.c`): now also creates
    `/run/user/<uid>` (0700, chowned) and exports `XDG_RUNTIME_DIR` before
    exec'ing the login shell -- every Wayland compositor hard-requires this
    at startup and nothing else sets it up yet (no logind/elogind, see
    fau's own package list).
  - **New group**: `/etc/group` now has a `seat:x:11:` entry
    (`scripts/apply-skeleton.sh`). Only root logs in today so this is a
    formality -- the day FloraOS gets real user management (`useradd`/
    `usermod` don't exist yet either, see below), `usermod -aG seat <user>`
    is the entire migration path for that user to reach the compositor's
    seat socket.
  - Still explicitly NOT done, on purpose rather than by oversight:
    **no real GPU acceleration driver** (i915/amdgpu/
    nouveau deliberately left out of linux-lts -- built-in would bloat
    vmlinuz with drivers most machines don't have, as modules they're
    useless without kmod -- add the one your hardware needs via
    EXTRA_PACKAGES-style kernel config once this actually blocks someone);
    **still no actual WM/DE in the base image** -- `fau install <wm>`
    (mango, sway, ...) stays purely opt-in, matching every other app;
    kitty is still left out of the default ISO build for the same
    ~773MB-dependency-closure reason as before, though it now has
    somewhere to actually draw once installed.
- PARTIAL (was: no persistent disk install at all): **florainstall**
  (`tools/florainstall`), a TUI installer run manually from the live shell
  (not wired into `/etc/inittab` -- same "boot to a shell, run the
  installer yourself" convention real live-installer images use, not just
  this project's own choice). ncurses/menu-driven -- the ncurses build
  already produces `libmenuw`/`libformw` alongside `libncursesw` (confirmed
  from ncurses.sh's own post-install symlink step, which explicitly
  symlinks `form`/`panel`/`menu` alongside `ncurses`/`tinfo`), so this adds
  no new package. What it actually does: partitions the target disk (MBR,
  one bootable Linux partition -- deliberately NOT GPT+"BIOS boot
  partition", which needs a partition-type GUID this project has no
  primary source available to verify, the same "don't guess" standard
  applied to the DRM Kconfig symbols above), formats btrfs, then `rsync`s
  the *live system's own already-running "/"* onto it -- there is no
  separate installer payload to unpack, since the booted image already is
  the fully-built OS (see scripts/build-iso.sh's own initramfs comment).
  btrfs-progs (mkfs.btrfs) isn't a base package either, same reasoning as
  grub just below -- fetched via fau's own alpm fallback too, except onto
  the *live* system itself (`fau bootstrap btrfs-progs`, FAU_ROOT left at
  its own default of "/"), since it has to run before the target disk has
  anything mounted on it at all. GRUB itself is still not built from
  source (this project already ruled that out for the ISO -- see the
  Bootloader section below); florainstall fetches the `grub` package via
  fau's own alpm fallback straight into the target disk's tree at install
  time instead, then runs `grub-install`
  inside a `chroot` into that target (its shared-library deps live under
  the target's own /usr/lib, not the live system's -- plain
  `--boot-directory` from outside a chroot isn't enough). Account setup
  (root password, one optional extra user) execs the real `florauser`
  inside that same chroot with the terminal inherited, so florauser's own
  interactive, termios-masked password prompt runs directly against the
  target's `/etc/shadow` -- florainstall never handles a plaintext
  password itself. One build-pipeline change needed to make this possible
  at all: build-iso.sh's own initramfs packing deliberately excludes
  everything under `./boot` from the live image (confirmed by reading that
  script directly), so the *running* live system had no
  `/boot/vmlinuz-floraos` anywhere in it for an installer to copy from --
  fixed with one extra staging line in build-rootfs.sh that copies the
  kernel to `/usr/lib/floraos/vmlinuz-floraos` (a path that isn't under
  `./boot`) purely for florainstall's own use. Now formats the target as an
  `@` subvolume (not the bare top-level) with a multi-entry `grub.cfg`
  generated by **floragrub-cfg** -- see the `fau backup` entry below for
  both, and for the real QEMU disk-boot harness (`scripts/test-install.sh`)
  that now actually boot-tests this end-to-end, including
  `CONFIG_BTRFS_FS=y` really being built in (confirmed by a real boot, not
  just read from the .config). UEFI support (was: BIOS/MBR only) is a
  separate DONE entry just below.
- DONE: **UEFI support in florainstall** (was: BIOS/MBR only, no
  dosfstools/ESP handling). Kept the same MBR disk label as the BIOS case
  rather than switching to GPT -- this project already ruled out GPT's own
  ESP partition-type GUID for lack of a primary source to verify it against
  (see the PARTIAL entry above), and it turns out MBR sidesteps UEFI too:
  the UEFI spec itself defines MBR partition-type byte 0xEF ("EFI System")
  as a valid way to mark an ESP with no GPT required, confirmed against a
  primary source this project actually can read on its own build host
  (`sfdisk --list-types`: "ef  EFI (FAT-12/16/32)"). Boot mode is detected
  once, at install-time, by checking whether the *live* system itself
  booted via UEFI (`/sys/firmware/efi` present) -- not a user-facing
  toggle, the same "you can only install what you booted" convention real
  installers use. BIOS-booted media installs exactly as before (unchanged
  single-partition scheme). UEFI-booted media instead gets a small
  (512MiB) FAT32 ESP (type 0xEF) as partition 1, then the Linux root
  partition. FAT32 needs `dosfstools` (`mkfs.fat`) -- not a base package
  any more than btrfs-progs is (see the PARTIAL entry above), fetched onto
  the live system the same way, right before formatting the ESP.
  `grub-install` runs with `--target=x86_64-efi --efi-directory=/boot/efi
  --removable`: `--removable` writes the fallback `EFI/BOOT/BOOTX64.EFI`
  path instead of registering an NVRAM boot entry, sidestepping
  `efibootmgr` entirely (confirmed against this build host's own
  `grub-install --help`: efibootmgr is listed as an *optional* dep of grub,
  needed only for the NVRAM path this project doesn't use) -- more robust
  than NVRAM registration anyway, since it works identically on real
  firmware and QEMU/OVMF without depending on a given firmware's NVRAM
  implementation being reliable. Arch's `grub` package (already fetched via
  fau's alpm fallback for the BIOS case) ships both the i386-pc and
  x86_64-efi platform directories in one package (confirmed on this build
  host: `pacman -Si grub` lists `Provides: grub-bios grub-efi-x86_64 ...`)
  -- no separate package or fetch needed for the UEFI target.
  `tools/floragrub-cfg` needed no changes at all: its generated `grub.cfg`
  is platform-agnostic (the same menuentry/search/insmod content is read by
  both the i386-pc and x86_64-efi GRUB binaries), the ESP itself is never
  referenced from it. Boot-tested end-to-end for real, the same standard as
  the BIOS path above, but against real QEMU+OVMF: install over OVMF, then
  a *second* boot with a completely fresh OVMF_VARS template (no NVRAM
  entries at all, the state a real firmware's NVRAM would be in on a disk
  moved to different hardware) specifically to confirm the `--removable`
  fallback path actually boots without depending on any NVRAM entry
  grub-install might have registered -- confirmed via `/proc/cmdline`
  (`root=/dev/sda2 rootflags=subvol=@`, the ESP correctly took `/dev/sda1`)
  and `/sys/firmware/efi` being present after that fresh-NVRAM boot. See
  **scripts/test-install-uefi.sh** (a sibling to scripts/test-install.sh,
  not folded into it -- the four BIOS-path phases past the install step
  itself, backup/grub-reboot/restore, are entirely platform-agnostic, so
  re-running all of them under OVMF would just re-prove the same logic a
  second time; this only re-checks the parts that actually differ:
  partitioning and the bootloader install/boot itself). Still explicitly
  NOT done: **no Secure Boot support** (no shim, no MOK enrollment, GRUB's
  own EFI binary is unsigned) -- see docs/TODO.md.
- DONE: `sysctl` (procps-ng), `hostname` (Debian's standalone package, not
  inetutils -- see MANIFEST.md), and `loadkeys`/`dumpkeys` (kbd) are now
  built and shipped; their openrc sysinit services run successfully instead
  of failing non-fatally. procps-ng required patching out its po/po-man
  gettext subdirs before autoreconf -- this build host's gettext is
  gettext-tiny (reports itself as version "1.0"), which lacks the
  po-directories hook real GNU gettext's autopoint provides, and NLS/
  translations aren't wanted here anyway. kbd is built with
  vlock/zlib/bzip2/lzma/xkb explicitly off (PAM and libs FloraOS doesn't
  ship; same auto-detected-optional-lib class of issue as iproute2's
  libtirpc).
- DONE: `loadkeys`/kbd shelled out to `gzip` to decompress `.gz`-compressed
  keymaps/fonts and fell back to its own internal decompression when that's
  missing -- cosmetic (stderr noise, the keymap still loaded -- confirmed via
  `./floraiso test`'s boot log), but easy enough to close outright. Added
  **gzip** (`scripts/recipes/gzip.sh`, `config/versions.conf`) as a base
  package: plain autotools build, no optional deps to turn off, verified with
  a real `./configure && make` on this build host before pinning the version.
- DONE: `memusagestat` (glibc's memory-usage grapher) and `fsck.cramfs`/
  `mkfs.cramfs` (e2fsprogs' legacy cramfs support) auto-linked against libgd
  and libz respectively, neither of which FloraOS ships -- both were broken
  ("cannot open shared object file") inside the running OS. Pruned at build
  time (see scripts/recipes/glibc.sh and e2fsprogs.sh) rather than adding
  two more packages for tools that aren't part of FloraOS's actual
  filesystem (ext4) or debugging workflow; `memusage` itself (the
  LD_PRELOAD-based profiler, as opposed to memusagestat's graph output)
  still works fine without memusagestat.
- DONE: `fau`'s `install_one`/`app_install_one` now detect a circular
  `depends=` (A -> B -> A) and die with a clear error instead of recursing
  until bash gives up. No package in the current manifest actually has a
  cycle -- this is a robustness fix for a typo'd `depends=` field, not a
  response to an observed failure.
- DONE: bash's job control (`cannot set terminal process group`) was a side
  effect of `/etc/inittab` spawning it directly instead of through a real
  getty. Fixed as part of the floralogin work above: agetty now opens and
  attaches tty1/ttyS0 properly (session leader + controlling terminal)
  before exec'ing floralogin, which execs the login shell -- confirmed
  gone from a real boot's transcript, not inferred from the inittab change
  alone.
- DONE: `fau service-*` -- the first step from "package manager" toward
  "system manager" beyond packages/backups (see this file's own intro to
  the fau section). A thin front end over OpenRC (`rc-update`/
  `rc-service`), not a reimplementation of service supervision or
  dependency ordering -- that's exactly the kind of high-blast-radius,
  PID-1-adjacent work a "write our own init system" idea was explicitly
  weighed against and rejected for. Static facts (does a service exist,
  which runlevel(s) is it enabled in) are read straight off the
  filesystem (`/etc/init.d`, `/etc/runlevels`), same "read the real data,
  don't parse a wrapper's own text output" convention florainstall
  (`/sys/block`) and florauser (`/etc/passwd`) already use, rather than
  scraping `rc-update show`. Genuinely dynamic runtime state (is a
  service actually running right now) is read from
  `/run/openrc/{started,failed,inactive}/<name>` -- confirmed against a
  real boot (`find /run/openrc -maxdepth 2` in a real QEMU session), not
  assumed from OpenRC's general reputation. `service-start`/`-stop`/
  `-restart` just exec the real `rc-service`. Found and fixed a real bug
  via that same real boot: `service_runlevels` (backing both
  `service-list` and `service-status`) returned nothing and killed the
  whole script under `set -e` for the overwhelmingly common case (a
  service enabled in any runlevel other than whichever sorts
  alphabetically last, or in none at all) -- a bash function's implicit
  return status is whatever its *last executed command* returned, and the
  loop's last iteration's `[ -e ... ] && basename` test is false unless
  the service happens to be enabled in that one particular runlevel.
  Fixed with an explicit `return 0` after the loop. See
  [tools/fau/fau.md](../tools/fau/fau.md) for the full writeup. Also added
  `fau help <topic>`/`fau --help <topic>` (e.g. `fau help service`, `fau
  help packagemanager`) so the top-level `fau help`/`fau --help` stays a
  short, scannable overview instead of dumping the entire, ever-growing
  command list every time -- verified against a real boot, including the
  unknown-topic error path.
- DONE: `fau seat-*` -- same "friendlier fau-native front end, don't
  reimplement the daemon" idea as `fau service-*` above, this time for
  `floraseat`'s new VT-bound switching (see that DONE entry). `seat-switch
  <n>` is a plain `chvt <n>` wrapper (kbd, already a base package),
  identical to a physical Ctrl+Alt+Fn -- not a seatd-protocol client
  itself, since floraseat already reacts to any VT switch via its own
  `VT_PROCESS` release/acquire signal handlers regardless of what
  triggered it. `seat-status` reads `/sys/class/tty/tty0/active` for the
  current VT (same "read the real kernel data" convention as `fau
  service-*`) and tails `/var/log/floraseat.log`. Verified in a real QEMU
  boot: `seat-switch 2`/`seat-switch 1` round-trip correctly (confirmed
  via `seat-status` before/after each), non-numeric input rejected with
  exit status 1. See [tools/fau/fau.md](../tools/fau/fau.md).
- DONE: `fau user-*` and `florauser rename` -- same "friendlier front end"
  idea as `fau service-*`/`fau seat-*` above, this time over `florauser`
  (`tools/florauser`): `user-add`/`user-passwd`/`user-rename`/
  `user-groupadd`/`user-addtogroup` each check only their own argument
  count and exec the real `florauser <cmd>`, no logic duplicated. Closes a
  real, user-facing gap along the way: `florauser` itself had no way to
  rename an account at all (only `add`/`passwd`/`groupadd`/`addtogroup`)
  -- `florauser rename <old> <new>` now renames the `/etc/passwd` entry
  (name + home directory, but only if the home follows `add`'s own
  `/home/<name>` layout -- a custom path is left untouched, disclosed via
  a printed note), the `/etc/shadow` entry (name only, hash and aging
  fields copied verbatim), the user-private group if one actually matches
  (same name *and* gid as the user, not just a same-named coincidence),
  and every group's member list (the literal username token
  `addtogroup` stores). Refuses to rename root outright -- too much else
  in this project hardcodes that name literally for renaming it to
  silently break elsewhere. Not a single atomic transaction (same
  disclosed limitation as the rest of florauser: no locking, no
  rollback), but ordered passwd -> shadow -> group so an interruption
  partway through leaves the user's own login identity consistent rather
  than the reverse. A real bug an actual test run caught, not just
  reasoned through: the first version's group-member-list rebuild could
  produce a literal `"bob,bob"` if the target group already listed a
  member named `<new>` alongside `<old>` (an unrelated real user, or the
  same rename re-run) -- fixed by deduplicating so each name appears at
  most once regardless of what the group already contained. Verified two
  ways: a standalone scratch-file harness (path macros redirected via
  `sed`, run under `fakeroot` to satisfy the `getuid()==0` check without
  touching this host's real files) covering the standard- and
  custom-home-layout cases, the duplicate-member case above, and every
  reject path (root, existing name, nonexistent user, invalid name); then
  a real QEMU boot -- `fau user-add alice seat`, `fau user-passwd alice`,
  `fau user-rename alice bob`, confirmed the renamed entries directly, and
  logged in as `bob` with `alice`'s original password, `id` still showing
  the `seat` group membership. See
  [tools/florauser/florauser.md](../tools/florauser/florauser.md) and
  [tools/fau/fau.md](../tools/fau/fau.md).
- DONE: split `fau` from one ~2200-line script into a thin dispatcher plus
  one real, independently-runnable tool per area -- `fau` itself now holds
  only the help text (`usage`/`usage_topic`) and a `dispatch()` case
  statement that `exec`s the right one; `fau-bootstrap`, `fau-install`,
  `fau-repo`, `fau-export`, `fau-backup`, `fau-service`, `fau-seat`, and
  `fau-user` each implement exactly the command group their name says, and
  `tools/fau/lib/{common,manifest,repo,alpm}.sh` hold the code genuinely
  shared between them (the biggest of the four, `lib/alpm.sh`, is the whole
  Arch/Artix dependency-resolution engine both `fau-bootstrap` and
  `fau-install` fall back to). Every `fau-*` tool is a real, standalone
  program -- `fau-backup backup-list` works identically to `fau
  backup-list`, no dispatcher involved -- matching the same "call the real
  tool, don't reimplement it" shape this project already applies to
  `fau service-*`/`fau seat-*`/`fau user-*` calling out to
  `rc-service`/`chvt`/`florauser`, just turned inward on fau's own
  historically-monolithic commands too. `fau-export`'s `import` now shells
  out to `fau-install` as a real subprocess instead of sourcing its
  `app_install_one` directly, for the same reason. `scripts/build-rootfs.sh`
  stages the whole `tools/fau/` tree into `$ROOTFS_DIR/usr/lib/fau/` and
  symlinks `usr/bin/fau` to `../lib/fau/fau` -- the one entry point that
  needs to be on `PATH`.
  - **A real bug the split caused, caught by an actual boot test**: each
    tool computes its own directory via `dirname "${BASH_SOURCE[0]}"` to
    find its sibling `fau-*`/`lib/*.sh` files -- but bash reports
    `BASH_SOURCE[0]` as the path *as invoked*, not a symlink's resolved
    target. Since `/usr/bin/fau` is a symlink, invoking it that way (which
    is exactly what happens whenever anything, `florainstall` included,
    execs plain `fau` off `PATH`) resolved to `/usr/bin`, not
    `/usr/lib/fau` where everything actually lives. First boot after the
    split failed immediately: `florainstall`'s "fetching btrfs-progs" step
    died with `/usr/bin/lib/common.sh: No such file or directory`. Fixed
    by resolving the symlink first: `dirname "$(readlink -f
    "${BASH_SOURCE[0]}")"`, applied identically to every `fau-*` tool (none
    of the others are symlinked today, but the fix is free).
  - Verified with a full from-scratch rootfs rebuild (`fau bootstrap`
    against all ~30 base packages plus the alpm fallback for
    libgcc/fastfetch, exercising `fau-bootstrap`/`lib/alpm.sh` completely)
    and the existing real-QEMU regression suites
    (`scripts/test-install.sh`, which drives `florainstall` -> `fau
    bootstrap`/`florauser` inside a live boot, is what actually caught the
    symlink bug above). See [tools/fau/fau.md](../tools/fau/fau.md)'s own
    "Architecture" section for the full file-by-file breakdown.
- DONE: `alpm_fetch`'s mirror-failover (`tools/fau/lib/alpm.sh`) burned tens
  of seconds retrying mirrors that were never going to work. Observed on a
  real `fau install mangowm`: for a handful of packages (`libxfont2`,
  `xorg-server-common`, `xorg-xwayland`, `python`), *nearly every* mirror in
  Artix's full list 404'd in a row before one near the end finally
  succeeded, while every other package resolved on the first or second try
  -- consistent per-package failure across most of the list, not
  random/scattered, pointing at mirror sync lag (fau resolved a version
  newer than most mirrors had synced yet). Each failed attempt still paid a
  real ~2s connection-setup cost (see this file's QEMU-networking note --
  every mirror is a new host), so a handful of stale-everywhere packages
  could dominate total install time on a slow link even though `fau`'s own
  4-way parallel fetch itself wasn't the bottleneck.

  Two options considered and rejected: capping/shortening the failover list
  (risks turning "slow" into "install fails" outright, since the one
  working mirror for a given package can be anywhere in the list, including
  near the end); and pre-checking mirror freshness before choosing one
  (needs a signal fau doesn't have -- a HEAD/version check per mirror per
  package costs as much round-trip time as just trying them, undoing the
  savings). Fixed instead by reordering, not filtering: `alpm_fetch` now
  stable-sorts each fetch's candidate mirror list by that host's *recorded*
  past-failure count (fewest first, ties broken by original mirrorlist
  order) before trying them serially, same as before. Every mirror is still
  tried, in the worst case, exactly as many as today -- this only changes
  the order, so a chronically-laggy mirror still gets used when it's
  genuinely the only one with a package. Failure counts persist to
  `$FAU_CACHE_DIR/mirror-fail-counts` (inside `FAU_ROOT`, alongside the
  existing alpm sync-db cache) and are written only on failure, never on
  success, so the by-far-common case (first or second mirror works) pays
  zero extra I/O. Written with no locking, deliberately -- concurrent writes
  from `alpm_parallel_fetch`'s own 4-way job pool can lose an update, but
  this is a soft ranking heuristic, not correctness-critical, and it
  self-heals over the next real failure.

  A real bug caught only by testing, not by inspection: the very first
  failure ever recorded was silently dropped. `awk` given a nonexistent
  input file exits before reaching its `END` block, so the first-ever call
  (before `$FAU_CACHE_DIR/mirror-fail-counts` exists) produced an empty
  temp file, and `mv` replaced nothing with nothing. Fixed by touching the
  stats file into existence first. Verified end-to-end against 4 local
  `python3 -m http.server` instances standing in for mirrors (3 returning
  404, 1 serving the real file, mirrorlist order deliberately putting the
  working one last) -- not against real Artix mirrors, which this sandbox
  has no network access to. First fetch: all 3 dead mirrors tried and
  logged as failed, in mirrorlist order, before the 4th succeeds, matching
  today's behavior exactly. Second fetch (different filename, same 4
  mirrors, stats now warm from the first): the working mirror sorts first
  and the fetch succeeds on the very first attempt, with zero failed
  attempts logged -- confirming the reorder actually eliminates the
  repeated-failure cost for every fetch after the first one to hit a given
  set of laggy mirrors, not just in theory.
