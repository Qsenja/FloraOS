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
- TODO: fau dependency resolution is single-level (no version constraint
  solving) until the package set grows enough to need it.
- TODO: real password-backed login. util-linux's login/su/runuser/chfn/chsh
  require PAM to build at all, and PAM isn't part of FloraOS -- shipping
  them linked against the build host's PAM would produce binaries FloraOS
  itself can't load. Disabled at build time; `/etc/inittab` spawns bash
  directly on tty1/ttyS0 instead of agetty+login. Needs either a
  from-scratch PAM (+ /etc/pam.d config) or a PAM-free login path before
  real authentication makes sense.
- TODO: no GUI/display server (X11 or Wayland) -- `fau app-install`'s
  pacman-backed fallback (see tools/fau/fau) can fetch GUI apps' files, but
  they have nowhere to draw pixels without this. Separate, larger project.
  kitty specifically was left out of the default ISO build for this reason:
  its dependency closure (Python3 + Mesa + X11/Wayland) is ~773MB with
  nothing to run it on yet -- `fau app-install kitty` works today if you
  want the files anyway, it's just not baked in by default.
- TODO: `sysctl`, `hostname`, and `loadkeys`/`keymaps` commands aren't part
  of any built package yet (sysctl is procps-ng; hostname is its own small
  package or part of inetutils; keymaps needs kbd). Their openrc sysinit
  services fail non-fatally (logged, boot continues) -- add these packages
  when their functionality is actually needed.
- TODO: `memusagestat` (glibc's memory-usage grapher) and `fsck.cramfs`/
  `mkfs.cramfs` (e2fsprogs' legacy cramfs support) auto-link against
  libgd and libz respectively, both absent from the base manifest. Left
  broken rather than adding two more packages for tools that aren't part
  of FloraOS's actual filesystem (ext4) or debugging workflow -- revisit if
  either is ever actually needed.
- TODO: bash lacks job control on the console (`cannot set terminal process
  group`) since /etc/inittab spawns it directly instead of through a real
  getty that opens/attaches the tty properly. Cosmetic for now; would need
  revisiting alongside the login/PAM TODO above if job control matters
  before then.
