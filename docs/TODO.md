# FloraOS TODO

The current, live list of explicitly-open gaps — not a wishlist. Every entry
here is cross-referenced from the code/docs that would otherwise silently gloss
over the gap (this project's own "TODO over silence" rule, see
ARCHITECTURE.md). Deliberate, permanent design choices (e.g. no WM/DE bundled
in the base image, app isolation under `~/apps/`) are *not* listed here — this
file is only for things that could reasonably be finished later.

- **No UEFI support in `florainstall`** (`tools/florainstall`) — BIOS/MBR
  only. No dosfstools/ESP handling; would need a FAT32 ESP partition and
  `grub-install --target=x86_64-efi` inside the target chroot. See
  ARCHITECTURE.md's florainstall entry.
- **No VT-switching** (`tools/floraseat`) — single-seat, non-VT-bound.
  Fine today (FloraOS only ever has one login session at a time); a real
  gap once a second concurrent graphical session needs to exist. See
  MANIFEST.md's floraseat row and the tool's own file header.
- **No real GPU-accelerated driver** — the kernel only ships a generic
  simpledrm/sysfb KMS driver, not i915/amdgpu/nouveau. Add the one your
  hardware needs once this actually blocks someone (see README.md's
  GUI-readiness note).
- **Persistent syslog daemon** — not scripted, no concrete logging
  requirement has shown up yet. See ARCHITECTURE.md/MANIFEST.md.
- **`loadkeys` (kbd) shells out to `gzip`** to decompress `.gz`-compressed
  keymaps/fonts, falling back to its own internal decompression when
  that's missing (FloraOS doesn't ship gzip) — cosmetic stderr noise only,
  the keymap still loads. Not worth a fourth package for this alone. See
  ARCHITECTURE.md/MANIFEST.md's kbd row.
- **`fau backup`'s `restore` rename sequence isn't atomic** — a crash
  partway through `mv @ -> @pre-restore-*`, flip read-only off, `mv
  @snapshots/<name> -> @` is a real, documented risk, not a bug to silently
  fix by adding complexity this project hasn't decided is worth it yet. See
  ARCHITECTURE.md's fau-backup section.

See ARCHITECTURE.md for the full design-decision history (including
everything above that's already DONE, and the reasoning behind each).
