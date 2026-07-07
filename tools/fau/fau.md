# fau — implementation notes

Design rationale and gotchas mined from `fau` and its sibling tools' own
comments — the "why" and the bugs found along the way, not a restatement of
what the code does (read the code for that). See
[docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) for the higher-level
design decisions; this file is the lower-level implementation detail that
didn't belong there.

## Architecture: one dispatcher, one tool per area, shared libraries

`fau` used to be a single ~2200-line script holding every command's own
implementation. It's now just the dispatcher: `usage()`/`usage_topic()` (the
help text) and a `dispatch()` case statement that `exec`s the real tool for
whatever command was given. It does not itself install a package, take a
backup, or touch a service.

```
tools/fau/fau            dispatcher: help text + dispatch table
tools/fau/fau-bootstrap   bootstrap/bootstrap-remove/-list/-export/-apply
tools/fau/fau-install     install/remove/list (isolated apps)
tools/fau/fau-repo        repo-add/repo-index
tools/fau/fau-export      export/import
tools/fau/fau-backup      backup/backup-list/-remove/-restore/-repair
tools/fau/fau-service     service-* (front end over OpenRC)
tools/fau/fau-seat        seat-* (front end over floraseat)
tools/fau/fau-user        user-* (front end over florauser)
tools/fau/lib/common.sh   die/log/env-var defaults/json_escape/pkginfo_field
tools/fau/lib/manifest.sh system.json/apps.json read-write, dep_parse/version_satisfies
tools/fau/lib/repo.sh     the local .fau.tar.zst repo (repo_json/repo_index/...)
tools/fau/lib/alpm.sh     the whole Arch/Artix fallback + dependency resolution engine
```

Every `fau-<name>` tool is a real, independently-runnable program — `fau-backup
backup-list` works exactly like `fau backup-list`, no dispatcher involved.
Each one computes its own `SELF_DIR` (from `$BASH_SOURCE`) and sources
exactly the `lib/*.sh` files it actually needs; `fau-service`/`fau-seat`/
`fau-user` need none of them (they only call `die`/`log` from
`lib/common.sh` and otherwise just exec the real `rc-service`/`chvt`/
`florauser`). `fau-export`'s `import` shells out to `fau-install` as a real
subprocess (`"$SELF_DIR/fau-install" install "$n"`) rather than sourcing its
`app_install_one` — same "call the tool, don't inline its logic" shape as
everything else here, and it means a failed install there is just a
nonzero exit status to check instead of a `die()` that has to be caught
with a subshell (which the single-file version needed).

**Staging** (`scripts/build-rootfs.sh`): the whole `tools/fau/` tree (every
`fau`/`fau-*` executable plus `lib/*.sh`, excluding this doc) is copied
verbatim into `$ROOTFS_DIR/usr/lib/fau/`, and `$ROOTFS_DIR/usr/bin/fau` is a
relative symlink to `../lib/fau/fau` — the one entry point that actually
needs to be on `PATH`. Every other tool is reachable by full path if
someone wants it (`/usr/lib/fau/fau-backup backup-list`), same as `git`'s
own `git-<command>` binaries technically being reachable outside `git`
itself.

**A real bug this restructuring caused, caught by an actual boot test, not
by inspection**: `SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
computes the directory holding `${BASH_SOURCE[0]}` -- but bash reports that
as the path *as invoked*, not a symlink's real target. Since
`/usr/bin/fau` is a symlink to `../lib/fau/fau`, running it via that
symlink (which is exactly what happens whenever anything, including
`florainstall`, execs plain `fau` and PATH resolves it) gave `SELF_DIR`
as `/usr/bin` -- not `/usr/lib/fau`, where `lib/common.sh` and every
sibling `fau-*` tool actually live. First real boot test after the split
failed immediately: `florainstall`'s "fetching btrfs-progs" step (which
execs `fau bootstrap` internally) died with `/usr/bin/lib/common.sh: No
such file or directory`. Fixed by resolving the symlink *before* taking
the directory: `dirname "$(readlink -f "${BASH_SOURCE[0]}")"`. Applied to
every `fau-*` tool identically, not just the dispatcher -- none of the
others are symlinked today, but the fix costs nothing when it isn't, and
there's no guarantee a future one won't be.

## Two install modes, one package format

`install`/`remove`/`list` (`fau-install`) merge into an isolated
`FAU_APPS_DIR/<name>/`; `bootstrap`/`bootstrap-remove`/`bootstrap-list`
(`fau-bootstrap`) merge straight into `FAU_ROOT` (build-time only, not for
end users — this is how `build-rootfs.sh` builds the base rootfs itself).
Both source `lib/alpm.sh` for their own alpm-fallback counterpart
(`app_install_one_alpm`/`install_one_alpm`), parameterized by target
directory, rather than sharing one combined function — the two install
paths' bookkeeping (apps.json + `FAU_APPS_BIN_DIR` wrappers vs. system.json
+ `FAU_FILES_DIR`) diverges enough that a single parameterized function
would need more branching than just having two.

## Manifests (`system.json` / `apps.json`) — `lib/manifest.sh`

Flat schema only: `{"packages":{"name":{"version":"x"}}}`, hand-rolled
grep/sed parsing (`json_get_version`, `json_set`, ...) — fine at this scale,
revisit if the schema ever grows past one level.

## Repo (`repo_add`/`repo_index`) — `lib/repo.sh`

- A repo directory holds **at most one archive per package name**.
  `repo_index` just globs every `*.fau.tar.zst`; without `repo_add` deleting
  the old archive on a version bump first, you get duplicate keys for the
  same name and which one `repo_lookup_file` resolves to depends on
  filesystem glob order, not on what was actually just added.

## Dependency version constraints — `lib/manifest.sh`

`depends=` entries may carry `name`, `name>=1.2`, or `name==1.2`
(comma-separated). Deliberately just these two operators, compared via
`sort -V`/a small rpmvercmp reimplementation — full range solving is out of
scope. `dep_parse`'s IFS handling: **`tr ','` then loop, not `local
IFS=','`** — IFS is function-scoped, not block-scoped, so a `local IFS=','`
would still be active for every later command in the same call (notably
`system_set`'s own word-splitting) — this is exactly what corrupted
`system.json` before the fix.

## Installing (`install_one` in fau-bootstrap / `app_install_one` in fau-install)

- **rsync flags matter**: `-aK --checksum`. `-K` (`--keep-dirlinks`) is
  required for merging multiple packages into one root where `bin`/`sbin`/
  `lib`/`lib64` are symlinks to `usr/*` — plain `cp -a` refuses the merge
  outright ("cannot overwrite non-directory X with directory Y"), and
  `rsync -a` alone *replaces* the destination symlink with a real directory
  instead of merging into its target.
- **`--checksum` is not optional**: without it, rsync's default quick-check
  (same size + same mtime ⇒ skip) silently keeps the *old* file content on
  an upgrade whenever two versions of a file happen to match in both —
  reproduced directly (bumped a test package 1.0→2.0 with same-size files;
  the "upgraded" file kept serving 1.0 content while `system.json` claimed
  2.0). Package archives aren't gigabytes, so hashing every file on install
  is the right trade.
- **Circular `depends=` (A→B→A)** is detected via an ancestor-chain string
  passed as a plain function argument (not a global) — each recursive
  branch gets its own copy with nothing to clean up on return.
- **App wrapper scripts** (`app_wrapper_write`) set `HOME`/`XDG_*_HOME`/
  `LD_LIBRARY_PATH`/`PATH` to redirect an app into its own isolated
  directory. Two real runtime failures this had to account for:
  - **perl's own `libperl.so`** lives nested under
    `usr/lib/perl5/<ver>/core_perl/CORE/`, not flat under `usr/lib/` — a
    flat `LD_LIBRARY_PATH` missed it (`cowsay` installed fine, then failed
    at runtime with "libperl.so: cannot open shared object file"). Fixed by
    computing every directory under the app that actually contains a `.so*`
    file, once at wrapper-write time.
  - **perl's compiled-in `@INC`** points at the *real* system's
    `/usr/lib/perl5/...`, never at an isolated app's own copy — `cowsay`
    found `libperl.so` fine after the fix above, then failed with "Can't
    locate Cwd.pm in @INC" even though `Cwd.pm` existed right there under
    the app dir. Fixed via `PERL5LIB` (perl's own supported override,
    exactly analogous to `LD_LIBRARY_PATH` but for `.pm` modules) — no need
    to patch perl or chroot anything.

## The alpm (Arch/Artix repo) fallback — `lib/alpm.sh` — no `pacman` binary, ever

Reads pacman's own *data formats* directly (sync db, desc files,
mirrorlist, `pacman.conf`'s repo list) — never shells out to the `pacman`
binary. Works both at build time (fast path: reads the build host's own
`/etc/pacman.d/mirrorlist` + `/var/lib/pacman/sync`) and from inside an
already-booted FloraOS system (no pacman, no synced db at all — falls back
to fetching a mirrorlist/db copy FloraOS ships at `/etc/fau/` for exactly
this). Real, disclosed caveat: fetched binaries are built against Artix's
glibc — only ABI-compatible with FloraOS's own from-scratch glibc by
current-version coincidence, not by any guarantee.

**Bugs found doing this for real, not from reading the code:**

- **A single dead mirror used to abort the whole install.** One
  mirrorlist entry's DNS name didn't resolve from inside a QEMU guest
  network, while every other mirror worked fine — `alpm_fetch` now tries
  every configured mirror in order before giving up, matching what real
  `pacman` would do.
- **FloraOS's own compiled glibc got silently overwritten by Arch's
  binary.** Resolving `fastfetch`'s (or any alpm package's) closure also
  resolves `glibc`/`filesystem`/`tzdata`/etc — packages FloraOS already
  built from its own pinned source. Left unguarded, those get
  rsync-merged over `FAU_ROOT` too. Found by comparing `libc.so.6`'s
  sha256 before/after a real build: the shipped one turned out to be
  Arch's, not FloraOS's own. Fixed by skipping any resolved package
  fau's own `system.json` already has an entry for.
- **Arch's `filesystem` package applies unwanted distro tuning at boot.**
  It's Arch/Artix's own base-system bootstrap package, dragged in only
  because Arch's dependency graph implies "a base Arch system" underneath
  everything. Its content outside `etc/`/`usr/include` (already stripped)
  is Arch/Artix distro integration — `/usr/lib/tmpfiles.d/artix.conf`,
  `/usr/lib/sysctl.d/10-artix.conf`, Artix branding pixmaps — and merging
  it in silently applied Artix's own sysctl tuning and threw tmpfiles
  errors for `/etc` files this build deliberately doesn't ship (found on
  a real boot). Skipped by name outright, not by stripping a fifth
  subdirectory.
- **`app_install_one_alpm` skips the `etc/` strip** that
  `install_one_alpm` (bootstrap path) does — an isolated app directory
  never touches the real `/etc`, so there's nothing to guard against
  there. `usr/include` is stripped in both: dev headers are never needed
  at runtime.
- **Some packages ship intentionally unreadable setuid-root helpers**
  (dbus's daemon-launch-helper, for one) as an upstream hardening
  measure — meaningless in an unprivileged, non-system-installed copy,
  but it broke the merge step since fau couldn't even read what it just
  extracted. Fixed with `chmod -R u+rX` on the extracted tree before
  merging.
- **An absolute `DT_NEEDED` entry breaks isolated (but not system-root)
  installs** — see [../fauelf/fauelf.md](../fauelf/fauelf.md). `fauelf` is
  run over every extracted file via process substitution (`< <(find ...)`),
  not a `find | while` pipe — a pipe would run the loop in a subshell,
  where a real `fauelf` failure's `die()` would only exit that subshell,
  not abort the install.
- **`fau remove` couldn't find an alpm-installed app's wrapper scripts**
  without its own recorded `bin=` field in `.pkginfo` — confirmed by a
  real install/remove round-trip where the wrapper in `FAU_APPS_BIN_DIR`
  survived "removal" and failed with "No such file or directory" on next
  use.
- **Extracting multiple packages' full uncompressed trees at once ran a
  real boot out of disk space** — this rootfs is tmpfs/RAM-backed. Fixed
  by fetching every queued package's *compressed* archive in parallel
  first (cheap to hold many of on disk at once), then extracting/merging
  strictly one package at a time. An earlier version fetched *and*
  extracted in parallel and ran out of space partway through copying
  glibc's locale files, even at just 2 packages concurrently.
- **Every freshly-downloaded archive is cached into
  `/var/cache/pacman/pkg/`** (the same well-known path already read from
  first) — this is what lets `florainstall` speculatively prefetch
  `btrfs-progs`/`grub` into a throwaway root while the user is still
  clicking through its TUI, before the real chroot target even exists:
  the later real bootstrap call just finds it already cached. Write is
  tmp-name-then-rename (same atomic pattern as `write_lines`), since a
  background prefetch can race a real install hitting the same
  destination file.

## Version comparison (`alpm_vercmp`) — `lib/alpm.sh`

A from-scratch reimplementation of Arch's own version-comparison algorithm
(rpmvercmp-derived), verified against the real `vercmp` binary across
~300 real package versions from this host's own sync dbs plus hand-picked
edge cases (epoch, pkgrel, git-describe-style `+r37+gHASH` suffixes) — exact
match on all of them. Known divergences are contrived synthetic cases (a
bare alpha suffix directly attached with no separator, tilde pre-release
markers) that essentially never occur in real Arch/Artix version strings —
an accepted, documented simplification, not a full rpmvercmp port.

## Dependency resolution (PROVIDES-aware, no pacman) — `lib/alpm.sh`

- **`alpm_repo_index`**: one `awk` pass over every extracted `desc` file in
  a repo, not a handful of per-package `awk`/forks. A real Arch repo can
  hold ~7300 packages; the naive per-field-per-package approach meant tens
  of thousands of forks and was slow enough to look hung.
- **`alpm_repo_provides_index`**: a second index keyed by *provided*
  (virtual/soname) name, e.g. `libc.so=6-64`. Nearly every real Arch
  dependency spec is a soname/virtual reference, not the package's own
  name — without this second index, `alpm_find_provider`'s PROVIDES
  fallback was a plain bash `while read` linear scan over the *entire*
  by-name index for every such spec. Found resolving `neovim`'s real
  ~50+ package closure taking noticeably long; verified old-code-vs-new
  byte-identical output at 6.9s → 1.1s (~6x) against the same warm cache,
  and a fully cold-cache install still installs and runs correctly.
- **A dependency spec resolving through a virtual alias got
  double-processed.** E.g. a spec referencing `libz.so=1-64` resolves to
  the real package `zlib` — without also tracking the *resolved* name
  (not just the spec name) in the "seen" set, `zlib` got reprocessed (and
  reprinted in the progress line) once per distinct alias it was reached
  through. Found by comparing `cava`'s full closure against real
  `pacman`'s resolution: unique package counts matched exactly, but the
  raw output had ~40 duplicate lines.
- **Index field alignment must match exactly between `alpm_find_provider`'s
  two branches** (by-name vs PROVIDES) — a mismatch here previously
  misaligned every field after it for the caller (filename/sha256 silently
  swapped).
- A failure resolving one dependency spec deep in a tree is logged and
  skipped, not propagated — Arch dependency graphs commonly reference
  optional/soft deps this fallback doesn't need to take literally. Only
  the *exact requested* top-level spec failing to resolve anywhere is a
  hard error.

## `fau backup` (`fau-backup`) — see [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md)'s
fau-backup section for the full design (subvolume layout, the
"root=UUID= doesn't work without an initramfs" and "findmnt's `[/@]`
suffix" bugs a real boot test found). One implementation note worth
keeping close to the code: `backup_with_toplevel`'s transient mountpoint
is created under `/dev/shm`, not plain `mktemp -d`'s default of `/tmp` —
`/tmp` lives on the *currently mounted root*, which is deliberately
read-only when booted into a snapshot (`fau backup-restore`'s own use
case), so plain `mktemp -d` died with "Read-only file system" there.
`/dev/shm` is its own tmpfs, mounted by devfs's own init script
independent of whatever's mounted as `/`.

`backup-restore` isn't atomic (no tool here exposes
`renameat2(RENAME_EXCHANGE)`) — `_backup_restore_do` clears the snapshot's
read-only property *before* touching `@` at all so a failure there never
leaves `@` missing, narrowing the real risk to the two renames themselves.
`backup-repair <name>` (`_backup_repair_do`) completes the interrupted case:
run after booting the still-working "FloraOS (backup: `<name>`)" GRUB entry
(whose subvolume is untouched by the failed rename), it refuses outright if
`@` already exists or if `@snapshots/<name>` is also gone — it only knows
how to complete this one specific, well-understood state, not guess at
others. Verified against real btrfs subvolumes (not just read through): both
the normal-restore path and the induced-crash-then-repair path, plus both
repair-refusal cases, exercised directly (not via `scripts/test-install.sh`,
which doesn't yet inject a crash mid-restore).

## `service-*` (`fau-service`) — a thin front end over OpenRC

`service-list`/`service-status`/`service-enable`/`service-disable`/
`service-start`/`service-stop`/`service-restart` are fau's first step from
"package manager" toward "system manager" beyond packages/backups (see
docs/ARCHITECTURE.md). OpenRC already solves service supervision and
dependency ordering correctly, so this doesn't reimplement any of that:

- **Static facts** (does a service exist, which runlevel(s) is it enabled
  in) are read straight off the filesystem — `/etc/init.d` and
  `/etc/runlevels` — same convention `florainstall` (`/sys/block`) and
  `florauser` (`/etc/passwd`) already use, rather than scraping
  `rc-update show`'s text output.
- **Genuinely dynamic runtime state** (is a service actually running right
  now) is read from `/run/openrc/{started,failed,inactive}/<name>` —
  confirmed against a real boot (`find /run/openrc -maxdepth 2` in a real
  QEMU session), not assumed from OpenRC's general reputation.
- **Starting/stopping** a service is left to the real `rc-service` —
  reimplementing daemon supervision itself is exactly the kind of
  high-blast-radius, PID-1-adjacent work this project decided against.

**A real bug an actual boot caught**: `service_runlevels` (used by both
`service-list` and `service-status`) used to return nothing at all and
exit the whole script under `set -e` — `fau service-list` printed zero
output and exited 1, even though its loop had already computed real
results. The cause is a classic bash gotcha, not a logic error in the
loop itself: a function's *implicit* return status is whatever its
*last executed command* returned, not "did this successfully print what
it was supposed to". The loop's last iteration is whichever runlevel
directory happens to sort last, and its `[ -e ... ] && basename` test is
false for any service not enabled in *that particular* runlevel — so the
function returned 1 for the overwhelmingly common case (a service enabled
in some runlevel other than the alphabetically-last one, or in none at
all), and that 1 propagated straight through `set -e`. Fixed with an
explicit `return 0` after the loop — anywhere a shell function's last
statement is a conditional inside a loop, its implicit exit status is not
to be trusted as "did the loop's real work succeed".

## `seat-*` (`fau-seat`) — a thin front end over floraseat's VT-bound switching

`seat-status`/`seat-switch <vt-number>`, same "friendlier front end, don't
reimplement the daemon" idea as `service-*` above, just for `floraseat`
(tools/floraseat) instead of OpenRC:

- **`seat-switch`** is a plain `chvt <n>` wrapper (from kbd, already a base
  package) — identical to a physical Ctrl+Alt+Fn. There's no seatd-protocol
  opcode involved here at all: this is not a seatd client, it's a
  convenience wrapper around the same kernel VT-switch mechanism floraseat
  already reacts to via its own `VT_PROCESS` release/acquire signal
  handlers (see `floraseat.c`'s header comment). If a real seatd client
  (e.g. a compositor) is active on the outgoing VT, floraseat disables it
  and enables whatever claims the incoming VT, exactly as if the user had
  pressed the key combo directly; if neither VT has ever had a client on
  it, the kernel just switches with no signal to anyone (see
  `floraseat.c`'s own `g_cur_vt` resync comment for why that's correct,
  not a bug).
- **`seat-status`** reads `/sys/class/tty/tty0/active` for the current VT
  (same "read the real kernel-provided data" convention `service-*` and
  `florainstall`/`florauser` already use) and tails
  `/var/log/floraseat.log` for context — no persistent syslog daemon
  exists to capture that log otherwise (see docs/TODO.md).

Verified in a real QEMU boot: `seat-switch 2` / `seat-switch 1` round-trip
correctly (confirmed via `seat-status` before/after each), and
`seat-switch abc` is rejected with a clear error and exit status 1.

## `user-*` (`fau-user`) — a thin front end over florauser

`user-add`/`user-passwd`/`user-rename`/`user-groupadd`/`user-addtogroup`,
same idea again, this time over `florauser` (tools/florauser) instead of
OpenRC or floraseat: each command checks only its own argument *count*
(so a wrong invocation gets fau's own usage line, e.g. `usage: fau
user-rename <old-name> <new-name>`, instead of florauser's) and then execs
the real `florauser <cmd> "$@"` — no argument validation, password
handling, or file editing is duplicated here. `user-passwd`'s interactive
prompt (termios echo off) works unmodified through this front end since
bash doesn't redirect stdio for a plain function call.

Verified in a real QEMU boot: `fau user-add alice seat` + `fau user-passwd
alice` + `fau user-rename alice bob`, confirming the renamed
`passwd`/`shadow`/`group` entries directly and then logging in as `bob`
with `alice`'s original password — `id` still showed the `seat` group
membership, proving the whole chain (florauser's own rename logic, exec'd
through this front end) actually works end-to-end, not just each piece in
isolation.

## `fau help <topic>` / `fau --help <topic>`

The top-level `usage()` is deliberately short — an ever-growing flat
command list stops being scannable. `usage_topic <name>` holds the actual
per-command detail, grouped to match the sections above (`install`,
`repo`, `export`, `backup`, `service`, `seat`, `user`, `bootstrap`), plus
`all` to print
every topic at once. A few aliases (`pkg`/`package`/`packages`/
`packagemanager` all map to `install`) exist purely for discoverability —
someone reaching for `fau help packagemanager` shouldn't hit a dead end.
