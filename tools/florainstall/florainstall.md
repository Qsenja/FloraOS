# florainstall — implementation notes

Design rationale and gotchas mined from `florainstall.c`'s own comments —
the "why" and the real bugs found running it, not a restatement of what the
code does. See [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) for the
project-level design history and [docs/MANIFEST.md](../../docs/MANIFEST.md)
for the package-level reasoning.

## What "installing" means here

The live ISO boots its entire rootfs unpacked as an initramfs — the running
system's `/` already *is* the fully-built OS. There's no separate installer
payload to unpack; florainstall's real job is: partition a real disk, format
it, `rsync` the live `/` onto it, then make it bootable and give it a real
login. `florauser`, `fau`, `grub`, and `btrfs-progs` do the actual work —
florainstall itself never touches a plaintext password or hand-rolls a
dependency closure.

## Partition scheme: MBR, not GPT

Classic MBR (dos label), one bootable Linux (`0x83`) partition spanning the
disk — deliberately **not** GPT + "BIOS boot partition", which needs a
specific partition-type GUID this project has no primary source available
to verify from inside this build (the same "don't guess" standard applied
elsewhere, e.g. linux-lts.sh's Kconfig symbols were checked directly against
kernel.org). `grub-install --target=i386-pc`'s classic embedding gap between
the MBR and the first partition (sfdisk's default 1MiB alignment already
leaves this) has been the standard BIOS-GRUB2 install method for decades —
no dedicated partition required. UEFI is not supported yet (no dosfstools/
ESP handling) — a real, disclosed gap, not a silent omission (see
[docs/TODO.md](../../docs/TODO.md)).

`BLKRRPART`'s ioctl number (`0x125f`) is hand-computed (`_IO(0x12, 95)`)
rather than pulled from `<linux/fs.h>`, which on some libc/kernel-header
pairings redefines macros `<sys/mount.h>` (needed for `mount(2)`/`MS_BIND`)
already provides.

## btrfs, not ext4

FloraOS ships no btrfs-progs in the base image (same as it ships no GRUB) —
fetched at install time via `fau`'s alpm fallback, but **onto the live
system itself**, not the target: `mkfs.btrfs` has to run before the target
disk has anything mounted on it at all, unlike `grub-install`, which
genuinely needs to run inside a chroot into the target.

## The `@` subvolume (not the bare top-level)

After `mkfs.btrfs`, the target is mounted bare once just to `btrfs subvolume
create TARGET_MNT/@`, then unmounted and remounted with `-o subvol=@` for
the real install (rsync, kernel copy, chroot steps). `@snapshots` is *not*
created here — `fau backup` creates it lazily, as a sibling of `@`, the
first time it's needed. This layout is what makes `fau backup`'s read-only
snapshots + GRUB boot-into-a-snapshot restore possible at all — you can't
snapshot the top-level subvolume itself. See
[docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md)'s fau-backup section for
the full design and the real bugs a QEMU boot test caught here (`root=UUID=`
panicking without an initramfs, `findmnt`'s `[/@]` suffix, `grub-reboot`
needing `grubenv` support `floragrub-cfg` didn't have at first).

## `/boot/grub/grub.cfg` is generated, not hand-written

Delegated to **floragrub-cfg** (`tools/floragrub-cfg`) so the menuentry
format is shared with `fau backup`'s own regeneration after a
snapshot/remove/restore, instead of duplicated across this file's C and
fau's bash.

## Kernel image staging (a real build-pipeline gap)

`build-iso.sh`'s own initramfs-packing step deliberately excludes `./boot`
from the live image (GRUB reads `boot/vmlinuz-floraos` directly off the
ISO's own `boot/` directory; embedding it a second time inside the
initramfs it boots from would be redundant). That means the *running* live
system had no `/boot/vmlinuz-floraos` anywhere in it for florainstall to
copy from at all — fixed with one extra staging line in `build-rootfs.sh`
that copies the kernel to `/usr/lib/floraos/vmlinuz-floraos` (a path that
isn't under `./boot`, so it survives into the live initramfs) purely for
this tool's own use.

## Speculative background prefetch

`do_install()`'s two slowest steps (fetching `btrfs-progs` and `grub` via
fau's alpm fallback) are entirely network-bound and don't depend on
anything the user picks in the menu. Both get kicked off in the background
the moment the TUI opens, overlapping that network time with however long
the user spends on the disk/hostname/user screens instead of it sitting on
the critical path after "Begin installation".

- `grub` can't bootstrap into the real target yet (no disk chosen/
  partitioned/mounted at this point), so it prefetches into a throwaway
  `FAU_ROOT` instead — the merge result there is never used. What actually
  matters is that `fau`'s own `alpm_fetch_job` persists every
  freshly-downloaded archive into `/var/cache/pacman/pkg` (a fixed path
  independent of `FAU_ROOT`) — the real, later
  `FAU_ROOT=<target> fau bootstrap grub` call just finds everything already
  cached and skips the network entirely.
- `btrfs-progs` needs no throwaway root: its real `FAU_ROOT` (the live `/`)
  is already what the prefetch targets.
- The prefetch child redirects its own stdout/stderr to `/dev/null` — it
  runs unattended for however long the user stays in the menu, and must not
  fight the TUI for the terminal or splatter its own progress bar over
  ncurses' screen.
- `reap_prefetch()` (waited on right before the real bootstrap of the same
  package) exists so two concurrent `fau bootstrap` invocations never race
  against the same `FAU_ROOT`'s state (`fau` keeps no locking of its own).
  Its exit status is ignored — prefetching is purely a speed optimization,
  never a correctness dependency: if it failed (e.g. network wasn't up yet
  when the TUI opened), the real call right after still does its own fetch
  and `die()`s on failure exactly as if no prefetch had ever been attempted.

## Disk enumeration reads `/sys/block` directly

Same "read the real kernel-provided data, don't rely on a wrapper"
convention `florauser` uses (`/etc/passwd` directly, not `getpwnam()`) —
not `lsblk` output. `loop*`/`sr*`/`ram*` are filtered out
(`is_whole_disk`); an empty drive (e.g. no media in a card reader, `size`
== 0) is skipped too.

- `BLKRRPART` re-read is called explicitly even though `sfdisk` already
  does this itself on a clean write — cheap insurance, confirmed necessary
  in practice on some kernel/udev timing (the new partition's device node
  can otherwise still be missing by the time the next step opens it).

## The ESC-cancels-text-entry bug

`prompt_text()`'s character loop is hand-rolled rather than
`mvwgetnstr()`, which has no notion of "cancel" at all — despite the
"ESC=cancel" hint printed in the UI, ESC used to just get handed to
`mvwgetnstr()` as a plain data byte, and because the window has
`keypad(TRUE)` set (needed for backspace), ncurses would first hold it for
the `ESCDELAY` timeout (~1s) waiting to see if it was the start of a
function-key sequence, then insert byte `0x1b` into the buffer instead of
cancelling. Reading input a key at a time here lets ESC actually abort
immediately, the same way `run_choice_menu()`'s own loop already handled
it.

## `confirm_destructive()`

Requires the disk's bare name (e.g. `sda`, not `/dev/sda`) typed back
via `mvwgetnstr` before anything is touched — a real safety gate, not
decorative: `do_install()` is a one-shot, no-going-back pipeline once
called.

## Not `florauser`'s problem

Account setup (root password, one optional extra user) execs the real
`florauser` inside the same chroot with the terminal inherited, so its
interactive, termios-masked password prompt runs directly against the
target's own `/etc/shadow` — florainstall never handles a plaintext
password itself.

## Verification

Boot-tested end-to-end for real in QEMU/KVM by
`scripts/test-install.sh` — install, boot the installed disk, `fau backup`,
`grub-reboot` into it, `fau backup-restore`, reboot again — not just
compiled. See that script and docs/ARCHITECTURE.md's fau-backup section for
what it actually found and fixed.
