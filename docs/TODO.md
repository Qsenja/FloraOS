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

See ARCHITECTURE.md for the full design-decision history (including
everything above that's already DONE, and the reasoning behind each).
