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

## Partition scheme: MBR, not GPT — for BIOS *and* UEFI

Classic MBR (dos label) always — deliberately **not** GPT + "ESP GUID",
which needs a specific partition-type GUID this project has no primary
source available to verify from inside this build (the same "don't guess"
standard applied elsewhere, e.g. linux-lts.sh's Kconfig symbols were checked
directly against kernel.org). This turns out to sidestep the GUID question
for UEFI too, not just BIOS: the UEFI spec itself defines MBR
partition-type byte `0xEF` ("EFI System") as a valid way to mark an ESP on
a legacy MBR disk, confirmed against a primary source this project *can*
read on its own build host (`sfdisk --list-types`: `"ef  EFI
(FAT-12/16/32)"`).

Boot mode is autodetected once, in `main()`, by checking whether the *live*
system itself booted via UEFI (`/sys/firmware/efi` present) — not a
user-facing toggle in the TUI. You can only install what you booted, the
same convention real installers use.

- **BIOS-booted live media**: unchanged since the original install support
  — one bootable Linux (`0x83`) partition spanning the disk.
  `grub-install --target=i386-pc`'s classic embedding gap between the MBR
  and the first partition (sfdisk's default 1MiB alignment already leaves
  this) has been the standard BIOS-GRUB2 install method for decades — no
  dedicated partition required.
- **UEFI-booted live media**: two partitions — a 512MiB FAT32 ESP (type
  `0xEF`, comfortably larger than any real kernel+GRUB EFI binary this
  project ships) first, then a Linux (`0x83`) root partition with the rest
  of the disk. FAT32 needs `dosfstools` (`mkfs.fat`) — fetched onto the
  live system the same way `btrfs-progs` is (see below), not a base
  package.

`BLKRRPART`'s ioctl number (`0x125f`) is hand-computed (`_IO(0x12, 95)`)
rather than pulled from `<linux/fs.h>`, which on some libc/kernel-header
pairings redefines macros `<sys/mount.h>` (needed for `mount(2)`/`MS_BIND`)
already provides.

## grub-install target: `i386-pc` vs `x86_64-efi --removable`

BIOS installs run `grub-install --target=i386-pc --boot-directory=/boot
<disk>`, unchanged. UEFI installs instead run `grub-install
--target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot
--removable` — no install-device argument, since `--efi-directory` alone
tells grub-install where the ESP is.

`--removable` writes the fallback `EFI/BOOT/BOOTX64.EFI` path (the one
every UEFI firmware probes when no NVRAM boot entry matches) instead of
registering an NVRAM boot entry via `efibootmgr` — confirmed against this
build host's own `grub-install --help`: `efibootmgr` is listed as an
*optional* dep of the `grub` package, needed only for the NVRAM path this
project deliberately doesn't use. More robust than NVRAM registration too:
it works identically on real firmware and QEMU/OVMF without depending on
any given firmware's NVRAM implementation being reliable, and survives the
disk being moved to different hardware (an NVRAM entry wouldn't).

Arch's `grub` package (already fetched via `fau`'s alpm fallback for the
BIOS case) ships both the `i386-pc` and `x86_64-efi` platform directories
in one package — confirmed on this build host (`pacman -Si grub` lists
`Provides: grub-bios grub-efi-x86_64 ...`) — so no separate package or
fetch is needed for the UEFI target.

`floragrub-cfg` needed **no changes at all** for this: its generated
`grub.cfg` is platform-agnostic (the same menuentry/search/insmod content
is read by both the `i386-pc` and `x86_64-efi` GRUB binaries), and the ESP
itself is never referenced from it.

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

`do_install()`'s slowest steps (fetching `btrfs-progs`, `grub`, and — on a
UEFI install — `dosfstools`, all via fau's alpm fallback) are entirely
network-bound and don't depend on anything the user picks in the menu. All
get kicked off in the background the moment the TUI opens, overlapping that
network time with however long the user spends on the disk/hostname/user
screens instead of it sitting on the critical path after "Begin
installation".

- `grub` can't bootstrap into the real target yet (no disk chosen/
  partitioned/mounted at this point), so it prefetches into a throwaway
  `FAU_ROOT` instead — the merge result there is never used. What actually
  matters is that `fau`'s own `alpm_fetch_job` persists every
  freshly-downloaded archive into `/var/cache/pacman/pkg` (a fixed path
  independent of `FAU_ROOT`) — the real, later
  `FAU_ROOT=<target> fau bootstrap grub` call just finds everything already
  cached and skips the network entirely.
- `btrfs-progs` and `dosfstools` need no throwaway root: their real
  `FAU_ROOT` (the live `/`) is already what the prefetch targets.
  `dosfstools` is only prefetched when `g_uefi` — a BIOS install never
  starts this fetch at all, since it never calls `mkfs.fat`.
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

Boot-tested end-to-end for real in QEMU/KVM, not just compiled:

- The BIOS path by `scripts/test-install.sh` — install, boot the installed
  disk, `fau backup`, `grub-reboot` into it, `fau backup-restore`, reboot
  again. See that script and docs/ARCHITECTURE.md's fau-backup section for
  what it actually found and fixed.
- The UEFI path by `scripts/test-install-uefi.sh` — install over QEMU+OVMF,
  then a *second* boot with a completely fresh `OVMF_VARS` template (no
  NVRAM boot entries at all, the state a real firmware's NVRAM would be in
  on a disk moved to different hardware) to specifically confirm the
  `--removable` fallback path (`EFI/BOOT/BOOTX64.EFI`) actually boots
  without depending on any NVRAM entry `grub-install` might have
  registered. Deliberately a sibling script, not folded into
  `scripts/test-install.sh`'s own phases: everything past the install step
  itself (backup/grub-reboot/restore) is platform-agnostic, so re-running
  all four phases under OVMF would just re-prove the same logic twice —
  this only re-checks the parts that actually differ (partitioning and the
  bootloader install/boot itself).
