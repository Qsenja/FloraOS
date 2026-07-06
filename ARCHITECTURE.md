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
- **The pacman-backed fallback needs pacman on whatever machine runs `fau`**:
  it shells out to the local `pacman`/`/var/lib/pacman/sync` and this build
  host's mirrorlist. FloraOS itself doesn't ship pacman (shipping it would
  mean vendoring Arch/Artix's package manager, the thing explicitly ruled
  out at the start), so this fallback works when building the ISO on a
  pacman-based host (as here), but *not* from inside an already-booted
  FloraOS system -- there, `fau install`/`app-install` only have whatever
  `FAU_REPO_DIR` you point them at.
  - **Found and fixed a real integrity bug in this fallback**: the scratch
    pacman db it resolves against has a deliberately *empty* local-package
    state (so `pacman -Sp` resolves the requested package's FULL upstream
    closure, not just what's missing) -- but for something like
    `fau install fastfetch`, that closure also includes `glibc`,
    `filesystem`, `tzdata`, etc: packages FloraOS already built from its own
    pinned source. Left unguarded, those got merged into `FAU_ROOT` too,
    which **silently replaced FloraOS's own compiled `libc.so.6` with
    Arch's official binary** on every single rootfs build -- caught by
    comparing sha256 before/after a real build, not by inspection. Fixed in
    three parts, all in `tools/fau/fau`'s `install_one_pacman`: (1) skip any
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
    skipping the whole `filesystem` package by name in `install_one_pacman`
    -- unlike `glibc` (skipped because FloraOS already provides it),
    `filesystem` is skipped because *nothing* in it is ever wanted here,
    regardless of what FloraOS itself provides.
- **Reproducibility is native, not bolted on**: every install/remove updates
  `/var/lib/fau/system.json`, an exact manifest of installed package names
  and pinned versions. `fau export` dumps it (e.g. for backup or copying to
  another machine); `fau apply system.json` installs the exact package set
  from that manifest onto a fresh root. This gives declarative,
  versioned reproducibility — not Nix-style content-addressed/bit-identical
  builds, which was explicitly scoped out as too large for a lean,
  auditable, purpose-built tool.

## App isolation: per-app directories under ~/apps/

The base OS (kernel, glibc, coreutils, bash, util-linux, sysvinit, openrc,
etc.) uses the standard FHS layout described above — it has to, since it's
needed to boot and run the system before any user or home directory exists.

User-facing software installed later is different: `fau app-install <name>`
puts everything for that app under `~/apps/<name>/` (files, plus its own
`config/`, `cache/`, `data/`, `logs/` subdirectories) instead of merging it
into `/usr` and `/etc`. A generated wrapper script in `~/apps/.bin/` sets
`HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME`/`XDG_DATA_HOME`/`XDG_STATE_HOME` to
point inside that directory before exec'ing the real binary, so an app like
Firefox ends up with everything — binary, config, cache, logs — contained in
one place, and `fau app-remove firefox` deletes exactly that one directory
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
- TODO: no GUI/display server (X11 or Wayland) -- `fau app-install`'s
  pacman-backed fallback (see tools/fau/fau) can fetch GUI apps' files, but
  they have nowhere to draw pixels without this. Separate, larger project.
  kitty specifically was left out of the default ISO build for this reason:
  its dependency closure (Python3 + Mesa + X11/Wayland) is ~773MB with
  nothing to run it on yet -- `fau app-install kitty` works today if you
  want the files anyway, it's just not baked in by default.
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
