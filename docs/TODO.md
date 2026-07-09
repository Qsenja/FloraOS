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
  from `PATH` rather than assumed. `rsync` itself was also missed from
  this count entirely (present in `etc/fau/source-built-packages`, not
  listed in either the converted or blocked set below) — it has no
  build-host-only concept in its recipe, same trivial shape as the 23
  above, just previously overlooked when this list was written. 6
  remain (or remained — see corrections below) blocked:
    - **`openrc`**: ~~depends on `glibc`'s installed version for a
      source patch~~ — **corrected**: the patch (`libeinfo.c`'s
      `strlcat` guard, `sed`'d to `#if defined(__GLIBC__) &&
      !__GLIBC_PREREQ(2, 38)`) is evaluated by the *compiler* against
      whatever glibc headers are present at build time. It needs no
      `system_get_version glibc` check at all and never depended on
      `glibc`'s own conversion — same shape as every other converted
      recipe (`gcc,make`).
    - **`eudev`**/**`curl`**: their build-host recipes reference
      `$STAGE_DIR/kmod/files/...`/`$STAGE_DIR/mbedtls/files/...` (another
      package's *staged build output*, a build-host-only concept that
      doesn't exist on a live system). Confirmed by inspecting a real
      built rootfs: `kmod.pc` is present at the real `/usr/lib/pkgconfig`,
      and `mbedtls`'s headers/libs are at the real `/usr/include`/`usr`
      — both translate directly to pointing there instead of `$STAGE_DIR`.
      `pkg-config`/`pkgconf` itself is confirmed *not* part of the merged
      system (build tool only), so `eudev`'s recipe needs it added to
      `PKG_BUILD_DEPS` alongside `gcc,make`.
    - **`sysvinit`**: its `sulogin` binary is deliberately rebuilt a
      *second* time, inline in `build-rootfs.sh` itself (not even in
      `scripts/recipes/sysvinit.sh`), against the fully-merged rootfs's
      own `libxcrypt`. Folds cleanly into `recipe_build` itself now that
      `libxcrypt` is a real, installed system recipe.
    - **`glibc`**: needs a raw kernel headers directory
      (`$LINUX_HEADERS_DIR`, produced only by `linux-lts`'s own
      `headers_install` step, never merged into the real rootfs).
      **Checked, not assumed**: inspected a real built rootfs's
      `/usr/include` directly — `linux/` and `asm/` are *not* present.
      The "live `/usr/include` already has them" theory from an earlier
      pass was wrong. Real fix: the recipe fetches the same kernel
      source tarball `linux-lts.fis` uses, runs `headers_install` into a
      throwaway dir itself, and points `--with-headers` there — self
      contained, no dependency on `linux-lts` having been converted or
      installed first. This is the package every other rebuild links
      against, so it gets a real verification pass, not just a build
      that completes.
    - **`linux-lts`** (the kernel): **the "zero rollback story" claim
      above was also wrong.** `floragrub-cfg` writes one GRUB entry per
      btrfs subvolume, each pointing at *that subvolume's own*
      `/boot/vmlinuz-floraos` — and `fau update`'s unconditional
      pre-update `fau backup` snapshot already gets its own GRUB entry
      via `backup_regen_grub` before any rebuild happens. A frozen
      snapshot's kernel is untouched by whatever happens to the live
      `@`'s kernel afterward, so picking that GRUB entry after a bad
      kernel rebuild already recovers the old, working kernel — the same
      model openSUSE's snapper+grub-btrfs uses, more automatic than
      Debian/Fedora's "keep old kernel packages" approach. What's
      actually still missing: (1) never verified end to end with a real
      boot; (2) `fau bootstrap-build`'s generic merge has no post-merge
      hook, and the kernel is the first package that needs one (`depmod`
      must run against the *merged* module tree, not the sandbox's
      staged output); (3) recovery is manual (pick the fallback entry at
      the GRUB menu), not auto-detected — true of mainstream distros too,
      not a FloraOS-specific gap, but worth being honest about.

See ARCHITECTURE.md for the full design-decision history (including
everything above that's already DONE, and the reasoning behind each).
