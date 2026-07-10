# fauswap — implementation notes

See [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) for the project-level
design history and [../fau/fau.md](../fau/fau.md)'s `fau-backup` section for
how this is actually used.

## Why it exists

`fau backup-restore <name>` promotes a btrfs snapshot to be the new `@`
(root subvolume). Doing that with two plain `mv`s (`@` -> a stash name,
then `@snapshots/<name>` -> `@`) has a real crash window: if the process
dies between the two renames, `@` doesn't exist at all, and the default
GRUB entry (`subvol=@`) won't boot.

`renameat2(2)`'s `RENAME_EXCHANGE` flag swaps two existing paths in one
atomic VFS operation — the kernel either fully renames both or changes
nothing; there is no intermediate state where one of them is missing.
btrfs supports this natively (it's a generic VFS-level rename, not
btrfs-specific ioctl surgery). `fauswap <path1> <path2>` is a minimal,
from-scratch wrapper around exactly that syscall — same "small, auditable,
purpose-built tool" reasoning as `fauelf`.

## Why `fau-backup` still does 3 steps, not 1

A plain two-path exchange between `@` and `@snapshots/<name>` would work,
but it changes what `@snapshots/<name>` *means* afterward: the backup's
own name would end up holding the old, pre-restore root instead of the
snapshot content it was created from, which is confusing and silently
breaks re-restoring the same backup later. `fau-backup`'s
`_backup_restore_do` instead:

1. Renames `@snapshots/<name>` aside to a fresh, private name
   (`@restore-pending-<name>-<ts>`) — an ordinary rename, but it doesn't
   touch `@` at all, so `@` is provably safe throughout this step.
2. `fauswap`s `@` and that pending name — the one moment that has to be
   atomic, and now it only ever exchanges two names nothing else
   references yet.
3. Renames the pending name to its final, human-readable
   `@pre-restore-<name>-<ts>` — cosmetic only. `@` already holds the
   correct restored content by this point regardless of whether this step
   ever completes.

A crash during step 1 or step 3 leaves `@` completely untouched (step 1
hasn't touched it yet; step 3 already finished the only step that could).
A crash during step 2 is impossible to observe half-done — that's the
whole point of `RENAME_EXCHANGE`. `fau backup-repair` cleans up a leftover
`@restore-pending-*` name from an interrupted step 1/3 (see `fau-backup`'s
own comments for the exact recovery logic).

## Usage contract

`fauswap <path1> <path2>` — both paths must already exist. Exits 0 on
success, 1 with `strerror()` text on failure (e.g. `EXDEV` if the two
paths are somehow on different filesystems — btrfs subvolumes under the
same top-level mount never hit this), 2 on a bad argument count.
