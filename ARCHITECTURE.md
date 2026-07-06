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

## Package manager: fau (custom, from scratch)

Two explicit constraints ruled out the obvious options:
- Mirroring an existing binary repo (Arch/Artix) would make FloraOS
  "based on" another distro, which was explicitly rejected.
- Forking pacman would mean vendoring a third party's codebase into the
  project, which was also explicitly rejected.

So FloraOS ships **fau**, a small package manager written from scratch
(`tools/fau/`):
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
- TODO: `fau backup` — a full-root snapshot (not just `system.json` + app
  configs, which `fau export`/`fau import` already cover) that's restorable
  from the GRUB boot menu. Originally deliberately not attempted at all:
  FloraOS had no persistent disk install (ran entirely from RAM, see
  `scripts/build-iso.sh`'s own header comment), no multi-entry GRUB support,
  and no early-userspace step reading `/proc/cmdline` for a custom parameter
  before sysvinit starts. The first of those three is now partially
  addressed -- **florainstall** (`tools/florainstall`, see below) gives
  FloraOS a real persistent disk install to snapshot in the first place --
  but the other two still aren't: florainstall's own `grub.cfg` is one
  hardcoded menuentry per install (same single-entry convention
  build-iso.sh's ISO build already uses), not a general multi-entry
  generator, and there is still no boot-time hook that could apply a
  snapshot before sysvinit starts. Bigger than a `tools/fau/fau` change on
  its own, and not worth guessing at unverified boot-time plumbing.
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
    vendoring pacman. Single seat0, non-VT-bound; device access is an
    allowlist (`/dev/dri/`, `/dev/input/event`, `/dev/hidraw` prefixes only,
    checked *after* `realpath(3)` canonicalization) gated by the socket's
    own permissions (`/run/seatd.sock`, 0660 root:seat), same access-control
    model as real seatd. Protocol correctness verified with a hand-written
    test client exercising open_seat/enable_seat/disallowed-path
    rejection/ping-pong end-to-end against the actual compiled binary (not
    just read-through) -- see the daemon's own file header for the full
    scope writeup and what's deliberately smaller than upstream.
  - **linux-lts** (`scripts/recipes/linux-lts.sh`): now enables
    `CONFIG_SYSFB_SIMPLEFB`+`CONFIG_DRM_SIMPLEDRM` (generic
    firmware-framebuffer-based KMS, works on essentially any x86_64 machine
    and under QEMU with zero hardware-specific driver code -- enough for a
    software-rendered/llvmpipe Wayland session) plus
    `CONFIG_INPUT_EVDEV`/`CONFIG_USB_HID`/`CONFIG_HID_GENERIC`/
    `CONFIG_USB_XHCI_HCD` as **built-in** (not modules) via `scripts/config`
    + `olddefconfig` after `defconfig`, since there's no kmod to autoload a
    module in the first place (see eudev's `--disable-kmod` above). NOT
    independently build-verified in this project's own sandbox this round --
    a full kernel compile wasn't practical there; option names are correct
    to the best of available knowledge for the pinned 6.18.38 tree, but
    treat this the same as any other unverified change (check the real
    `.config`/dmesg on an actual `./floraiso build`).
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
    **no VT-switching** (floraseat is non-VT-bound -- fine for one login
    session at a time, a real gap once a second concurrent graphical
    session exists); **no real GPU acceleration driver** (i915/amdgpu/
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
  `./boot`) purely for florainstall's own use. Still explicitly NOT done:
  **no UEFI support** (no dosfstools/ESP handling -- BIOS/MBR only, same
  scope-disclosure standard as this file's other gaps); **not
  independently boot-tested end-to-end** (no spare disk/hardware or a QEMU
  disk-boot harness available in this sandbox -- see florainstall.c's own
  header comment for exactly what to re-check, in particular that this
  kernel actually builds `CONFIG_BTRFS_FS=y` rather than `=m` -- now
  explicitly enabled in scripts/recipes/linux-lts.sh, since btrfs isn't on
  by default in x86_64 defconfig the way ext4 is, but not verified by an
  actual kernel build here -- since the installed system has no initramfs
  to load a module from before root is mounted); **`fau backup`'s own
  GRUB-multi-entry-menu prerequisite
  below is still unmet** -- florainstall writes one hardcoded menuentry per
  install, the same single-entry convention build-iso.sh's own ISO build
  already uses, not a general multi-entry `grub.cfg` generator.
- DONE: `sysctl` (procps-ng), `hostname` (Debian's standalone package, not
  inetutils -- see docs/MANIFEST.md), and `loadkeys`/`dumpkeys` (kbd) are now
  built and shipped; their openrc sysinit services run successfully instead
  of failing non-fatally. procps-ng required patching out its po/po-man
  gettext subdirs before autoreconf -- this build host's gettext is
  gettext-tiny (reports itself as version "1.0"), which lacks the
  po-directories hook real GNU gettext's autopoint provides, and NLS/
  translations aren't wanted here anyway. kbd is built with
  vlock/zlib/bzip2/lzma/xkb explicitly off (PAM and libs FloraOS doesn't
  ship; same auto-detected-optional-lib class of issue as iproute2's
  libtirpc).
- TODO: `loadkeys`/kbd shells out to `gzip` to decompress `.gz`-compressed
  keymaps/fonts and falls back to its own internal decompression when that's
  missing -- FloraOS doesn't ship gzip. Cosmetic only (stderr noise, the
  keymap still loads -- confirmed via `./floraiso test`'s boot log), not
  worth a fourth package for right now.
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
