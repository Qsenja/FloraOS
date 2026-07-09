# FloraOS TODO

The current, live list of explicitly-open gaps — not a wishlist. Every entry
here is cross-referenced from the code/docs that would otherwise silently gloss
over the gap (this project's own "TODO over silence" rule, see
ARCHITECTURE.md). Deliberate, permanent design choices (e.g. no WM/DE bundled
in the base image, app isolation under `~/apps/`) are *not* listed here — this
file is only for things that could reasonably be finished later.
  **More features for yay-to-fis** – rename it to be more general, add more features the translater so the person transforming the buildfile needs to look less and can trust more. rewrite in another language if that brings more features.
  give the .fis language special attributes so a dev can make their package better for floraos's system
- **No real GPU-accelerated driver** — the kernel only ships a generic
  simpledrm/sysfb KMS driver, not i915/amdgpu/nouveau. Add the one your
  hardware needs once this actually blocks someone (see README.md's
  GUI-readiness note).
- **Persistent syslog daemon** — not scripted, no concrete logging
  requirement has shown up yet. See ARCHITECTURE.md/MANIFEST.md.
- **`fau backup`'s `restore` rename sequence still isn't fully atomic** — a
  crash between the two renames (`mv @ -> @pre-restore-*` and
  `mv @snapshots/<name> -> @`) still leaves `@` briefly missing; the only
  real fix would be a `renameat2(RENAME_EXCHANGE)`-based swap, and no tool
  this project ships exposes that syscall (adding one — a small compiled
  helper, same class as `fauelf` — hasn't been decided as worth it yet for
  this alone). The window is now as narrow as it gets without that, and no
  longer an unrecoverable brick: `fau backup-repair <name>` completes an
  interrupted restore after booting the still-working "FloraOS (backup:
  <name>)" GRUB entry. See ARCHITECTURE.md's fau-backup section.
- **No Secure Boot support in `florainstall`'s new UEFI path** (see
  ARCHITECTURE.md) — no shim, no MOK enrollment, GRUB's own EFI binary is
  unsigned. Machines that enforce Secure Boot (most do by default) need it
  turned off in firmware setup to boot a FloraOS install. Fine today (no
  signed-boot requirement has shown up yet, same reasoning as the syslog
  daemon entry above); a real gap once that changes.
- **Single-user mode (runlevel `S1`) now wired up, one real bug still
  open** — `etc/runlevels/single/emergency-shell` (new, in
  `apply-skeleton.sh`) runs `sulogin` via a `start()` override; confirmed
  working end-to-end when invoked directly (`/etc/init.d/emergency-shell
  start` → real `sulogin` prompt → empty password → root maintenance
  shell). Building it surfaced a real, previously-unknown bug affecting
  *all four* of FloraOS's own custom services (`floraseat`, `dhcpcd`,
  `udevd`, `emergency-shell`): they used the shebang
  `#!/usr/bin/openrc-run`, but OpenRC's own dependency-cache generator
  (`sh/gendepends.sh`) does a literal string match against
  `#!/sbin/openrc-run` before sourcing a script for `depend()` info —
  `/sbin` resolving to the same binary via symlink doesn't matter, the
  comparison is textual. All four were silently absent from
  `/run/openrc/deptree` on every boot, so none of their `depend()`
  declarations (e.g. `floraseat`'s `need udevd`) were ever honored by
  OpenRC's scheduler — confirmed by inspecting the live cache, not
  guessed. Fixed by changing all four to the literal `#!/sbin/openrc-run`.
  Remaining open item: manually running `openrc single` from an
  already-booted multi-user shell (runlevel 3) showed inconsistent
  behavior tearing down `dhcpcd`/network/local mounts on the way in
  (sometimes finishing cleanly, sometimes taking much longer) before ever
  reaching `emergency-shell`'s start phase — this exercises a harder
  transition (3 → single) than the real intended path (booting straight
  into single-user from GRUB, where multi-user services were never
  started to begin with). Not yet tested via that real path; needs a
  kernel-cmdline-driven single-user boot test before calling the
  interactive-transition case solid.

- **`fau setkeyboard` done, `fau setlang` still open** — `fau setkeyboard
  <layout>` (new: `tools/fau/fau-locale`) is implemented and verified in a
  real boot: validates the layout exists under `/usr/share/keymaps/**`
  (the real shipped path — the note this replaced guessed
  `usr/share/kbd/keymaps`, which doesn't exist; corrected after checking
  the actual built rootfs, not assumed), applies it immediately via
  `loadkeys`, and persists it into `/etc/conf.d/keymaps` (read by OpenRC's
  `keymaps` init.d service on next boot). A bad layout name fails cleanly
  with a real error instead of a cryptic `loadkeys` message. No fetch
  needed: the 252 layout files (1.3M total) are already fully shipped,
  unstripped.
  `fau setlang` remains unimplemented — `usr/share/locale` (91 languages'
  gettext catalogs) and `usr/share/i18n` (localedef's source data for
  every locale) are stripped from the shipped ISO entirely (see fau.md's
  "Dead-weight strip" section) since `LANG` is hardcoded to
  `en_US.UTF-8` and nothing reads them today — so there's currently no way
  to get a different language back without rebuilding the ISO by hand. The
  natural fix reuses existing machinery: Arch's own `glibc` package
  (already fetchable via `alpm_resolve`/the alpm fallback
  `install_one_alpm` already uses) bundles the same
  `usr/share/i18n/{locales,charmaps}` source data — `fau setlang <locale>`
  would fetch it into a throwaway dir (same disposable-sandbox pattern as
  `fau build`), run `localedef` to generate just the requested locale into
  `usr/lib/locale`, and point `/etc/profile`'s `LANG` at it.

- **`fau update`'s rolling base-system rebuild now covers all 30
  `MANDATORY_ORDER` packages** — every one has a real
  `fau-recipes/system/*.fis` recipe (see `tools/fau/fau.md` for the full
  list). The last 7 (`rsync`, `openrc`, `eudev`, `curl`, `sysvinit`,
  `glibc`, `linux-lts`) needed real, not guessed, fixes for build-host-only
  assumptions in their original recipes — each spot-verified with an
  actual build, not assumed correct because it parses:
    - **`rsync`/`openrc`**: no build-host-only concept at all, same
      trivial shape as the first 23 converted. Real builds produce a
      working binary reporting the right version.
    - **`eudev`**: pointing `PKG_CONFIG_LIBDIR` at the real, installed
      `kmod` (confirmed present at `/usr/lib/pkgconfig` on a built
      system) instead of the build-host-only `$STAGE_DIR` works; a real
      build produces a working `udevadm`.
    - **`curl`**: `--with-mbedtls=/usr` (the real install path) instead
      of `$STAGE_DIR/mbedtls/files/usr`; a real build's `curl` correctly
      reports `mbedTLS/3.6.6` and fetches real HTTPS.
    - **`sysvinit`**: folds the second, correctly-linked `sulogin`
      rebuild (previously inline in `build-rootfs.sh`, against
      `libxcrypt`) directly into `recipe_build` — real build's `sulogin`
      links against the real `libcrypt.so.2`.
    - **`glibc`**: fetches its own kernel source independently and runs
      `headers_install` itself (a live system's own `/usr/include` has
      no `linux/`/`asm/` at all, checked directly, not assumed) — this is
      the package every other rebuild links against, so it got a full
      from-scratch real build, which caught and fixed a real bug:
      `--with-headers` needs `headers_install`'s own `include/` subdir,
      not its parent.
    - **`linux-lts`** (the kernel): the highest-risk package here, and
      the one where real testing caught the most. `floragrub-cfg` already
      writes one GRUB entry per btrfs subvolume, each pointing at that
      subvolume's own `/boot/vmlinuz-floraos`, and `fau update`'s
      unconditional pre-update snapshot gets its own entry before any
      rebuild happens — a frozen snapshot's kernel is untouched by
      whatever happens to the live `@` afterward, so picking that entry
      after a bad rebuild already recovers the old kernel (the same model
      openSUSE's snapper+grub-btrfs uses). `PKG_NEEDS_DISK=1` and
      `PKG_MANUAL_UPDATE=1` (see `tools/fau/fau.md`) mean it refuses on a
      live system and never runs during a bare `fau update` (a real
      kernel rebuild is tens of minutes even parallelized — too slow for
      an unattended everyday update); it only rebuilds when named
      explicitly (`fau update linux-lts`/`fau bootstrap-build linux-lts`).
      A real, deliberately-broken-kernel-and-recover QEMU test found and
      fixed three further real bugs along the way, none of them guessed:
      mbedTLS silently never offering RSA-PSS signature schemes during a
      TLS 1.2 handshake (a genuine upstream mbedTLS limitation, confirmed
      still present in mbedTLS's own development branch, not a
      FloraOS-specific regression — fixed with a source patch in
      `mbedtls.fis`/`mbedtls.sh`, verified against 7 real hosts including
      the one that first exposed it); kbuild's own host tools needing
      `linux/*.h` a live system doesn't have (fixed by pointing
      `HOSTCFLAGS` at the `linux-api-headers` package already
      sandbox-fetched as one of `gcc`'s own build deps, not a
      hand-reconstructed `headers_install` output — that has its own
      chicken-and-egg problem); and `bison` hardcoding both its own data
      directory and the `m4` binary's path to `/usr/...` (fixed via
      `BISON_PKGDATADIR`/`M4`, its own documented overrides).

See ARCHITECTURE.md for the full design-decision history (including
everything above that's already DONE, and the reasoning behind each).
