# floragrub-cfg — implementation notes

Design rationale mined from `floragrub-cfg`'s own comments. See
[docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md)'s fau-backup section for
the full design history and [../fau/fau.md](../fau/fau.md) for how `fau
backup` calls this.

## Why it exists

Generates `/boot/grub/grub.cfg`: one menuentry for the live `@` subvolume,
plus one per `fau backup` snapshot found under `@snapshots`. Shared
between `florainstall` (initial install) and `fau
backup`/`backup-remove`/`backup-restore` (regenerating after a snapshot is
added, removed, or promoted), so the menuentry format and the
subvolume-path logic live in exactly one place instead of being duplicated
across `florainstall.c`'s C and `fau`'s bash.

Bash, not compiled — same "portable script that must ship in the running
OS" reasoning as `fau` itself.

## Two real bugs a QEMU boot test caught (not guessable from reading the code)

- **Kernel/root paths must be prefixed with the subvolume name**
  (`/@/boot/...`, `/@snapshots/<name>/boot/...`), not left as bare
  `/boot/...`. This is the standard convention real distros' `grub-mkconfig`
  emits for a btrfs root that lives in a named subvolume: GRUB's own
  absolute-path file lookups on btrfs resolve against the filesystem's
  top-level (subvolid 5) by default — `rootflags=subvol=` only tells the
  *kernel* which subvolume to mount as `/` after handoff, it does nothing
  for GRUB's own file reads before that. Confirmed working end-to-end by
  an actual QEMU disk boot (`scripts/test-install.sh`).
- **`root=` must be the device path** (e.g. `/dev/sda1`), not `UUID=`. With
  no initramfs, the kernel's own `root=UUID=` resolution for btrfs needs
  either an early userspace pass (udev/eudev populating
  `/dev/disk/by-uuid/`, which can't run before its own root is mounted) or
  `btrfs device scan` (also userspace) to register the device by UUID —
  neither exists at this point in FloraOS's boot, so `root=UUID=` panics
  with "Cannot open root device" even though the exact same UUID string
  works fine for GRUB's own `search --fs-uuid` a moment earlier (a
  completely separate resolution path). The device path
  florainstall/`fau backup` already have in hand sidesteps this entirely —
  single-disk installs only, a real limitation (a different BIOS
  enumeration order across boots could change which device this is on
  real multi-disk hardware), documented in
  [docs/TODO.md](../../docs/TODO.md), not hidden. GRUB's own
  `search --fs-uuid --set=root` line is untouched — that half genuinely is
  UUID-based and robust; it was only the kernel's own `root=` that needed
  to change.

## `grub-reboot` needs `grubenv` support

`grub-reboot <title>` writes `next_entry` into `/boot/grub/grubenv` — a
hand-written `grub.cfg` with a hardcoded `set default=0` and no
`load_env`/`next_entry` handling silently ignores it, "set default=0" wins
every time regardless. `next_entry` is read, cleared, and saved back to
`grubenv` immediately (not left for a trailing `if boot_once` block), so
the override applies exactly once even if the chosen entry never finishes
booting. No `saved_entry`/`boot_once`/`menuentry_id_option` machinery
beyond that — this project doesn't support `grub-set-default`'s
persistent-default feature, only `grub-reboot`'s one-shot override.

## `/dev/shm`, not `mktemp -d`'s default

The transient `subvolid=5` mountpoint is created under `/dev/shm`, not
plain `mktemp -d`'s default under `/tmp` on the currently mounted root.
Found via an actual QEMU boot test: run from within a booted `fau backup`
snapshot (deliberately read-only), `/tmp` lives on that same read-only root
and `mktemp` died with "Read-only file system". `/dev/shm` is its own
tmpfs, mounted by devfs's own init script independent of whatever's
mounted as `/`.

## Snapshot ordering

Snapshots are listed newest-first (`ls -1t`) so the most recent backup is
the first alternative a user tabs to at the GRUB menu.
