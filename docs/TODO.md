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
`fau backup`'s `restore` is now atomic where it matters — a new tool,
`fauswap` (`tools/fauswap`, a minimal `renameat2(RENAME_EXCHANGE)`
wrapper, same class as `fauelf`), swaps `@` and the snapshot in one
kernel operation `@` can never be observed missing during. Verified for
real via `scripts/test-install.sh`'s existing backup/backup-restore
phases (unchanged test, now exercising the atomic path — real QEMU PASS).
See `fauswap.md` and `tools/fau/fau.md`'s `fau backup` section for the
3-step sequence (why it's not just one bare exchange) and how
`backup-repair` now recognizes the new interrupted-state shape.
- **No Secure Boot support in `florainstall`'s new UEFI path** (see
  ARCHITECTURE.md) — no shim, no MOK enrollment, GRUB's own EFI binary is
  unsigned. Machines that enforce Secure Boot (most do by default) need it
  turned off in firmware setup to boot a FloraOS install. Fine today (no
  signed-boot requirement has shown up yet, same reasoning as the syslog
  daemon entry above); a real gap once that changes.
**Single-user mode (runlevel `S1`) is done** — sysvinit's `l1:S1:wait:` entry
now runs `sulogin` directly, as its own inittab line
(`~~:S1:wait:/usr/bin/sulogin`), not as an OpenRC-managed service. Verified
end to end via the real intended path: a kernel-cmdline-driven single-user
boot (confirmed via `1`; sysvinit's own `init.c` recognizes `single`/`-s`/a
lone `0-9sS` character, though `single`/`S` alone curiously didn't trigger
it in this specific build while `1` reliably did — not fully root-caused,
noted here rather than left silent) reaches `sulogin`'s real prompt after
runlevel teardown, and an empty password drops into a genuine root
maintenance shell.

Two real bugs found getting here, neither guessed:

- **All three of FloraOS's own custom services** (`floraseat`, `dhcpcd`,
  `udevd` — a fourth, `emergency-shell`, existed briefly during
  development and is described below) used the shebang
  `#!/usr/bin/openrc-run`, but OpenRC's own dependency-cache generator
  (`sh/gendepends.sh`) does a literal string match against
  `#!/sbin/openrc-run` before sourcing a script for `depend()` info —
  `/sbin` resolving to the same binary via symlink doesn't matter, the
  comparison is textual. All were silently absent from
  `/run/openrc/deptree` on every boot, so none of their `depend()`
  declarations (e.g. `floraseat`'s `need udevd`) were ever honored by
  OpenRC's scheduler — confirmed by inspecting the live cache, not
  guessed. Fixed by changing all to the literal `#!/sbin/openrc-run`.
- **The actual, deeper bug: OpenRC's own `librc.c` hardcodes `"single"`
  as a runlevel that never contains services.**
  `rc_services_in_runlevel()` reads: `/* These special levels never
  contain any services */ if (strcmp(runlevel, RC_LEVEL_SINGLE) != 0) {
  ...scan the directory... }` — so an `etc/runlevels/single/<service>`
  symlink (the first approach tried here, `emergency-shell`, complete
  with a correct shebang and a `need localmount` guard against an
  earlier real hang where "Unmounting filesystems" never returned) is
  *never* started by `openrc single`, no matter what's in that
  directory — confirmed by reading OpenRC's source after chasing a real,
  reproducible no-op (teardown happened, nothing ever started, both
  interactively and via a real kernel-cmdline boot). This is a genuine
  upstream OpenRC design assumption (presumably: distros are expected to
  handle single-user via inittab directly, never through an OpenRC
  service), not something fixable from FloraOS's side of the fence.
  Fixed the same way `dhcpcd`/`udevd` already work around a different
  OpenRC scheduling gap: `sulogin` runs as its own direct inittab entry
  instead of an `openrc single`-managed service.

`fau setkeyboard`/`fau setlang` (locale/keymap switcher) are both done now,
verified in real boots — see `tools/fau/fau.md`'s `setkeyboard`/`setlang`
sections for the full story, including two real bugs `setlang` surfaced
along the way: `localedef` needing `I18NPATH` pointed at the fetch sandbox
(most real locale files `copy "i18n"` a shared file that doesn't exist on
a live system, since `usr/share/i18n` is deliberately stripped from the
ISO), and a `local`-scoped sandbox dir breaking its own `trap ... EXIT`
cleanup (same class of bug `fau-build`'s `cmd_build` had already found and
fixed — same fix applied here).

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
