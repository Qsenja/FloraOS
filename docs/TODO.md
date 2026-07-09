# FloraOS TODO

The current, live list of explicitly-open gaps — not a wishlist. Every entry
here is cross-referenced from the code/docs that would otherwise silently gloss
over the gap (this project's own "TODO over silence" rule, see
ARCHITECTURE.md). Deliberate, permanent design choices (e.g. no WM/DE bundled
in the base image, app isolation under `~/apps/`) are *not* listed here — this
file is only for things that could reasonably be finished later.

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
- **Single-user mode (runlevel `S1`) doesn't actually do anything** —
  `/etc/inittab`'s `l1:S1:wait:/usr/bin/openrc single` has no
  `etc/runlevels/single/` services defined, so reaching it today invokes
  neither an emergency shell nor a password prompt of any kind. `sulogin`
  (see ARCHITECTURE.md/MANIFEST.md's sysvinit entry) now exists, correctly
  linked and verified working end-to-end, specifically to be usable here —
  it just isn't wired in yet. Found while restoring `sulogin`, not the
  thing that restoration fixed.

- **`fau setlang`/`fau setkeyboard`** — no locale/keymap switcher exists
  yet. `usr/share/locale` (91 languages' gettext catalogs) and
  `usr/share/i18n` (localedef's source data for every locale) are now
  stripped from the shipped ISO entirely (see fau.md's "Dead-weight strip"
  section) since `LANG` is hardcoded to `en_US.UTF-8` and nothing reads
  them today — but that means there's currently no way to get a different
  language back without rebuilding the ISO by hand. The natural fix reuses
  existing machinery: Arch's own `glibc` package (already fetchable via
  `alpm_resolve`/the alpm fallback `install_one_alpm` already uses) bundles
  the same `usr/share/i18n/{locales,charmaps}` source data — `fau setlang
  <locale>` would fetch it into a throwaway dir (same disposable-sandbox
  pattern as `fau build`), run `localedef` to generate just the requested
  locale into `usr/lib/locale`, and point `/etc/profile`'s `LANG` at it.
  Keymaps are a separate, simpler case: `kbd`'s `usr/share/kbd/keymaps` is
  small (1.3M for every layout) and already fully shipped, unstripped, so
  `fau setkeyboard <layout>` needs no fetch at all — just validate the
  layout exists, call `loadkeys`, and persist the choice into whatever
  config OpenRC's `keymaps` init.d service reads. Not implemented yet.

- **`fau update`'s rolling base-system rebuild doesn't cover all 30
  `MANDATORY_ORDER` packages yet** — 23 now have real
  `fau-recipes/system/*.fis` recipes (`zstd`, `gzip`, `hostname`, `tar`,
  `libmd`, then `ncurses`, `bash`, `coreutils`, `util-linux`,
  `e2fsprogs`, `iproute2`, `dhcpcd`, `attr`, `acl`, `grep`, `sed`,
  `gawk`, `findutils`, `procps-ng`, `kbd`, `libxcrypt`, `mbedtls`,
  `kmod`; see `tools/fau/fau.md`). All 23 declare a real
  `PKG_BUILD_DEPS` (at minimum `gcc,make`; `procps-ng` additionally
  needs the full autotools chain for its own `autoreconf -fi` step) —
  an earlier version of the first five shipped without this and would
  have failed outright on a real FloraOS system (no compiler installed
  by default), caught by testing with `gcc`/`make` deliberately blocked
  from `PATH` rather than assumed. 6 remain genuinely blocked:
    - **`openrc`**: depends on `glibc`'s installed version for a source
      patch (`libeinfo.c`'s `strlcat` guard) — trivially convertible via
      `system_get_version glibc` once `glibc` itself is, not before.
    - **`eudev`**/**`curl`**: their build-host recipes reference
      `$STAGE_DIR/kmod/files/...`/`$STAGE_DIR/mbedtls/files/...` (another
      package's *staged build output*, a build-host-only concept that
      doesn't exist on a live system). On a live rebuild the real
      dependency is already installed at its normal system path
      (`/usr/lib/pkgconfig/...`, `/usr/include`), so these likely
      translate directly to pointing there instead — plausible, not yet
      verified with a real build.
    - **`sysvinit`**: its `sulogin` binary is deliberately rebuilt a
      *second* time, inline in `build-rootfs.sh` itself (not even in
      `scripts/recipes/sysvinit.sh`), against the fully-merged rootfs's
      own `libxcrypt`. Needs folding into a proper recipe (or a documented
      special case) before it can be `fau bootstrap-build`-able.
    - **`glibc`**: needs a raw kernel headers directory
      (`$LINUX_HEADERS_DIR`, produced only by `linux-lts`'s own
      `headers_install` step, never merged into the real rootfs) that
      doesn't exist as a standing artifact on a live system. Likely
      fixable — a live system's own already-installed `/usr/include` was
      itself populated by glibc's *first* build from those same headers,
      so pointing a rebuild's `--with-headers` at the live `/usr/include`
      directly may just work — but unverified, and this is the one
      package every other rebuild in this list links against, so it needs
      a real test before being trusted, not an assumption.
    - **`linux-lts`** (the kernel): not attempted at all. No
      multi-kernel-version GRUB fallback exists yet — `floragrub-cfg`
      only branches per-snapshot *subvolume* (`fau backup`'s own
      mechanism), never per kernel file/version, so a bad live kernel
      rebuild has zero rollback story today. A real fix needs that
      fallback mechanism (e.g. keeping the previous `vmlinuz-floraos`
      around with its own GRUB entry until the new one's confirmed to
      boot) built first, deliberately kept out of scope for now given how
      much worse a bad kernel push is than a bad `zstd` push.

See ARCHITECTURE.md for the full design-decision history (including
everything above that's already DONE, and the reasoning behind each).
