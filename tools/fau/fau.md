# fau — implementation notes

Design rationale and gotchas mined from `fau`'s own comments — the "why" and
the bugs found along the way, not a restatement of what the code does (read
the code for that). See [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md)
for the higher-level design decisions; this file is the lower-level
implementation detail that didn't belong there.

## Two install modes, one package format

`install`/`remove`/`list` merge into an isolated `FAU_APPS_DIR/<name>/`;
`bootstrap`/`bootstrap-remove`/`bootstrap-list` merge straight into
`FAU_ROOT` (build-time only, not for end users — this is how
`build-rootfs.sh` builds the base rootfs itself). Both share most of the
same install/dependency-resolution code, parameterized by target directory.

## Manifests (`system.json` / `apps.json`)

Flat schema only: `{"packages":{"name":{"version":"x"}}}`, hand-rolled
grep/sed parsing (`json_get_version`, `json_set`, ...) — fine at this scale,
revisit if the schema ever grows past one level.

## Repo (`repo_add`/`repo_index`)

- A repo directory holds **at most one archive per package name**.
  `repo_index` just globs every `*.fau.tar.zst`; without `repo_add` deleting
  the old archive on a version bump first, you get duplicate keys for the
  same name and which one `repo_lookup_file` resolves to depends on
  filesystem glob order, not on what was actually just added.

## Dependency version constraints

`depends=` entries may carry `name`, `name>=1.2`, or `name==1.2`
(comma-separated). Deliberately just these two operators, compared via
`sort -V`/a small rpmvercmp reimplementation — full range solving is out of
scope. `dep_parse`'s IFS handling: **`tr ','` then loop, not `local
IFS=','`** — IFS is function-scoped, not block-scoped, so a `local IFS=','`
would still be active for every later command in the same call (notably
`system_set`'s own word-splitting) — this is exactly what corrupted
`system.json` before the fix.

## Installing (`install_one` / `app_install_one`)

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

## The alpm (Arch/Artix repo) fallback — no `pacman` binary, ever

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

## Version comparison (`alpm_vercmp`)

A from-scratch reimplementation of Arch's own version-comparison algorithm
(rpmvercmp-derived), verified against the real `vercmp` binary across
~300 real package versions from this host's own sync dbs plus hand-picked
edge cases (epoch, pkgrel, git-describe-style `+r37+gHASH` suffixes) — exact
match on all of them. Known divergences are contrived synthetic cases (a
bare alpha suffix directly attached with no separator, tilde pre-release
markers) that essentially never occur in real Arch/Artix version strings —
an accepted, documented simplification, not a full rpmvercmp port.

## Dependency resolution (PROVIDES-aware, no pacman)

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

## `fau backup` — see [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md)'s
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

## `service-*` — a thin front end over OpenRC

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

## `fau help <topic>` / `fau --help <topic>`

The top-level `usage()` is deliberately short — an ever-growing flat
command list stops being scannable. `usage_topic <name>` holds the actual
per-command detail, grouped to match the sections above (`install`,
`repo`, `export`, `backup`, `service`, `bootstrap`), plus `all` to print
every topic at once. A few aliases (`pkg`/`package`/`packages`/
`packagemanager` all map to `install`) exist purely for discoverability —
someone reaching for `fau help packagemanager` shouldn't hit a dead end.
