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

- **`alpm_fetch`'s mirror-failover burns tens of seconds retrying mirrors
  that were never going to work** — observed on a real `fau install
  mangowm`: for a handful of specific packages (`libxfont2`,
  `xorg-server-common`, `xorg-xwayland`, `python` seen so far), *nearly
  every* mirror in Artix's full list failed in a row before one near the
  end finally succeeded, while every other package in the same closure
  resolved on the first or second try. Consistent per-package failure
  across most of the mirror list (not random/scattered) points at mirror
  sync lag — fau resolved a package version newer than most mirrors have
  synced yet, so each one 404s until it hits one of the few that's caught
  up. Each failed attempt still pays a real connection-setup cost (see
  ARCHITECTURE.md's QEMU-networking note: ~2s cold, since every mirror is a
  new host), so a handful of stale-everywhere packages can dominate total
  install time on a slow link even though `fau`'s own fetch logic (4-way
  parallel, see `lib/alpm.sh`) isn't the bottleneck. No fix decided yet —
  options worth weighing later: skip mirrors known to lag (needs a
  freshness signal fau doesn't currently have), reorder the mirror list by
  historically-most-reliable-first instead of whatever order it's in now,
  or just cap/shorten the failover attempts for a single package instead
  of working through the entire list every time.

See ARCHITECTURE.md for the full design-decision history (including
everything above that's already DONE, and the reasoning behind each).
