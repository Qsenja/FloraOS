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
tools/fau/lib/build.sh    fau-build/bootstrap-build's own source fetch + sandbox helpers
tools/fau/lib/recipes.sh  fetches .fis recipes from fau-recipes (app + system namespaces)
tools/fau/lib/selfupdate.sh   per-file granular update for fau's own tree (see below)
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

Both of those only ever move *already-built* files around (a local
`.fau.tar.zst` or a precompiled alpm binary) — see `build <name>`
(`fau-build`) just below for the third mode: compiling something from
source, on this same live system, on demand.

## `update [pkg ...]` (`fau-install`'s own third command) — checking against a fresh mirror fetch, not a cached one

Lives in `fau-install` rather than its own `fau-update` tool (unlike
`build`/`repo`/`export`/... each getting their own file) because it's really
just `app_install_one`/`app_install_one_alpm` called again per already-
installed name once a newer version is confirmed to exist — no new
bookkeeping shape of its own to justify a separate file, unlike (say)
`fau-backup`'s subvolume-snapshot logic.

**The one thing this command cannot get wrong: it must never answer "up to
date" based on a stale or shortcut-taken index.** Every other alpm-fallback
caller (`fau install`, `fau build`) is fine reusing whatever's already
cached at `$FAU_CACHE_DIR/alpm-db/*.db` indefinitely (`alpm_fetch_repo_db`'s
normal `[ ! -s "$dest" ]` skip) — a package that doesn't resolve yet still
resolves once *some* copy of the db exists, cached or not, and re-fetching
on every single invocation would make an unrelated `fau install foo` pay a
multi-second db-fetch tax it doesn't need. `fau update`'s entire purpose is
the opposite: notice a version that showed up on the mirrors *since* that
cache was last written. Calling the normal install path unmodified would
silently reuse however-old a cached `.db`/`.index`/`.provides.index` already
sitting in `$FAU_CACHE_DIR` and just never see anything new.

Worse than merely stale on this project's own dev/build host specifically:
`alpm_fetch_repo_db` also has a *build-host* fast path — `cp
/var/lib/pacman/sync/$repo.db` straight off the local machine instead of
fetching over the network at all, deliberately, so `fau build`/`fau install`
run from this repo during development don't re-download a multi-hundred-MB
sync db that's already sitting right there. That shortcut is exactly wrong
for `update`: this project's own dev/build host's local pacman sync db was
last refreshed whenever someone there last ran `pacman -Sy`, completely
unrelated to what's actually live on the real mirrors right now — checking
against it would answer "up to date" based on this machine's own history,
not the actual upstream state `update` is supposed to be reporting on. (On
a real deployed FloraOS box this exact path is dead code anyway — no
`pacman`/`/var/lib/pacman` ever exists there per the alpm-fallback's own
"no `pacman` binary, ever" design below — but `fau update` needs to be
correct when run from here too, not just once installed.)

Fixed with an explicit `force` argument threaded through
`alpm_fetch_repo_db`, and a new `alpm_refresh_dbs` (`lib/alpm.sh`) that
deletes every configured repo's cached `.db` *and* its two derived
`.index`/`.provides.index` files (`alpm_repo_index`/
`alpm_repo_provides_index` have that exact same indefinite-cache shape, so
deleting only `.db` would rebuild nothing) before calling
`alpm_fetch_repo_db ... force`, which skips both the cache-skip check and
the local-pacman-db shortcut unconditionally. `cmd_update` calls this
**once**, up front, before checking any individual package — not once per
package — both because the refreshed db already answers every package's
question and because re-fetching it per package would make `fau update`
with several installed apps needlessly slow.

Two source kinds get genuinely different treatment, matching how
`app_install_one` itself branches on `repo_lookup_file`:

- **Local-repo apps** (`repo_lookup_file` finds a `.fau.tar.zst`): compares
  `repo_lookup_version` (new — same awk-over-`repo.json` shape
  `repo_lookup_file` already uses, just matching the `"version"` key
  instead of `"file"`) against the installed version. This path never
  touches the network at all — the local repo is just files already present
  under `FAU_REPO_DIR`, refreshed independently by whoever runs
  `fau repo-add`, not something `update` fetches.
- **alpm-only apps**: re-resolves the single name via `alpm_resolve` (now
  against the just-refreshed db) and compares its top-level resolved
  version — same "last line of the resolved closure is the requested
  package itself" contract `install_one_alpm`/`app_install_one_alpm`
  already rely on (see the dependency-resolution section below) — against
  the installed version.

Either way, "newer" is decided with `alpm_vercmp` (already used for real
Arch/Artix version strings elsewhere in this file), not a plain string
inequality — a `.pc`/rebuild artifact or a differently-formatted-but-equal
version string comparing as "different" would otherwise trigger a pointless
reinstall.

A **third** kind gets checked when a name resolves through neither path
above (no local-repo entry, and either `alpm_resolve` fails or no
mirrorlist/repo-list is configured at all) — anything only ever installed
via `fau build` (`mangowm` being the only one so far). Its own version is
whatever's hardcoded in its `.fis` as `PKG_VERSION`, a static pin a person
bumps by hand when they update the recipe (e.g. to a newer upstream mango
tag) — not something resolvable against alpm at all, and not something
`update` can discover by polling anything remote (that would mean hitting
each recipe's own upstream host's release API, a different and much bigger
feature than what was asked for here). So "newer available" for this kind
means something narrower but still real: *the recipe file shipped on this
system is now pinned ahead of what's actually installed* — sourced in a
subshell (`$(source "$recipe"; echo "$PKG_VERSION")`, discarding the
`recipe_build`/`PKG_*` it defines on exit rather than leaking them into the
next loop iteration's different recipe) purely to read that one variable,
then `fau build <name>` is shelled out to for real (matching this project's
existing "call the tool, don't inline its logic" convention, same as
`fau-export`'s `import` calling `fau-install` as a subprocess) if the pin
moved forward. A name matching none of the three kinds at all — not in the
local repo, not resolvable via alpm, no recipe either — is reported and
skipped, same as an individual rebuild failure: nothing here aborts the
rest of a multi-package `update` run.

## `fau update` also sweeps base system packages, not just apps

`cmd_update` used to only ever touch `FAU_APPS_JSON`. Extended to also walk
`FAU_SYSTEM_JSON` (every base package, whether typed explicitly or swept by
default when no names are given), but **not** with the same logic apps get
— a naive "check alpm, reinstall if newer" pass over every system package
would silently replace FloraOS's own from-source `glibc`/`bash`/
`coreutils`/... with Arch's prebuilt binary the moment Arch ships a
"newer" version, exactly the bug this file already documents as found and
fixed once (see the "FloraOS's own compiled glibc got silently overwritten
by Arch's binary" entry above) — just reached through a new code path
instead of the old one.

The real distinction isn't visible from `system.json` alone (it only ever
records `name`/`version`, no provenance), and `repo_lookup_file` can't help
either: `FAU_REPO_DIR` doesn't exist at all on a live booted system (it's
build-host-only, gitignored, never shipped into the ISO), so it returns
empty for every package regardless of how it actually got there.
`build-rootfs.sh` now writes `etc/fau/source-built-packages` (one name per
line, exactly `${BUILD_ORDER[@]}`, i.e. `MANDATORY_ORDER` +
`EXTRA_PACKAGES`) right after the main bootstrap call and before any
alpm-fallback bootstrap (`libgcc`, `ttf-dejavu`, `fontconfig`, `dbus`) —
`cmd_update` reads that file and skips anything listed in it, reporting
"pinned from source, rebuild the ISO to update" instead. Everything else in
`system.json` (the alpm-fallback packages above, or anything a user later
runs `fau bootstrap <name>` for themselves) gets the same alpm-resolve/
`alpm_vercmp`/`install_one_alpm` treatment apps already get.

Verified against the real rootfs this project builds: all 30
`MANDATORY_ORDER` packages correctly reported as pinned, `libgcc`/
`ttf-dejavu`/`fontconfig`/`dbus` correctly checked against the mirrors and
reported up to date, both for the default no-args sweep and for explicit
`fau update <name>` calls naming a mix of both kinds.

### Rolling updates for real: `fau bootstrap-build` + system recipes

"Pinned from source, rebuild the ISO" doesn't have to be the end of the
story for a `source-built-packages` entry. `fau build` already has a
working disposable-sandbox mechanism (fetch a compiler + build-only deps
on demand, build one package from source, discard the sandbox) — reused
here instead of inventing a prebuilt-binary repo, since the only thing
that then needs publishing is a recipe (a small text file with a pinned
version/URL/sha256), not a built binary. Every live machine does its own
compiling, on demand, exactly like `fau build mangowm` already does today
— this fits "not Arch/Artix-based, everything from pinned source" far
better than shipping binaries would have.

- **`fau-recipes/system/<name>.fis`** + **`fau-recipes/system-recipes.db`**:
  same `.fis` shape `fau build` already parses, same fetch/fallback
  mechanics, kept in a separate namespace from the app recipes
  (`recipes.db`/`recipes/`) so `fau build-list` doesn't get cluttered with
  base-system entries no isolated-app user asked for.
  `tools/fau/lib/recipes.sh`'s `recipe_lookup`/`recipes_sync` were
  generalized into `_recipe_lookup`/`_recipes_sync` (parametrized over
  repo/branch/remote-dir/db-name/subdir/shipped-dir) precisely so this
  second namespace (`system_recipe_lookup`/`system_recipes_sync`) could
  reuse the exact same fetch-fresh/fall-back-to-last-known-good logic
  without touching the original app-recipe behavior at all — verified: the
  existing `recipe_lookup mangowm` path still resolves identically after
  the refactor.
- **`fau bootstrap-build <name>[=<version>]`** (`tools/fau/fau-bootstrap`):
  mirrors `fau-build`'s `cmd_build` almost exactly (same
  `build_fetch_source`/`build_extract_source`/`alpm_sandbox_fetch`, same
  sandbox `mktemp -d` + `trap ... EXIT` pattern — deliberately not `local`,
  same reason as `fau-build`'s own `sandbox_dir`) with one real difference:
  the merge tail is `rsync -aK --checksum <built-files>/ "$FAU_ROOT/"` +
  `record_files` + `system_set`, matching `install_one_alpm`/`install_one`,
  not `cp -a` into an isolated app dir. `PKG_DEPENDS` here means "must
  already be part of the running system" (checked via `system_get_version`,
  `die()`s if missing) rather than something to merge in — a system
  package shares the real `FAU_ROOT` with everything else already
  installed. `strip_unreachable_docs` runs on the build output before
  merging, same as every other merge point (a real gap found while testing
  this: the first `zstd` rebuild shipped 5 man pages right back in before
  this line was added).
- **`cmd_update`'s "pinned from source" branch**: now checks
  `system_recipe_lookup` before giving up. A system recipe with a newer
  `PKG_VERSION` triggers `fau bootstrap-build <name>` (same `alpm_vercmp`
  comparison the app-recipe tier already uses); no recipe yet still falls
  back to "rebuild the ISO," unchanged.

Verified end to end, including over a real QEMU-equivalent (`FAU_ROOT`
pointed at a real copy of this project's own built rootfs, not a fresh
empty one — so `glibc` and every other real `PKG_DEPENDS` check actually
has something to check against): `fau bootstrap-build zstd` rebuilds from
real upstream source, merges, and the resulting `zstd` binary correctly
decompresses a real `.fau.tar.zst` archive (load-bearing: this is the
compressor `fau`'s own package format itself uses). `gzip`/`hostname`/
`tar`/`libmd` (the first five system recipes, translated from
`scripts/recipes/*.sh`) each verified functionally too (round-trip
compress/decompress, binary+symlinks in place, archive create/list,
shared library present) — see fau-recipes' own `system/*.fis` files.
`fau update zstd` against a deliberately downgraded installed version
correctly detects, rebuilds, and reports up to date on a second run; a
package with no system recipe yet (`glibc`) still correctly falls through
to "rebuild the ISO," confirming the new tier doesn't accidentally widen
what's alpm-fallback-eligible.

**A real bug caught by this same testing discipline, not assumed away**:
the first five system recipes shipped with no `PKG_BUILD_DEPS` at all.
Building on this project's own dev host "worked" purely because `gcc`/
`make` already happen to be on that machine's `PATH` — exactly the
"dev host already has X" masking bug class `dwm.fis` documents elsewhere
in this file. A real FloraOS system ships neither. Caught by re-testing
with `gcc`/`make` shadowed by scripts that print a clear error and exit
127 if invoked, placed early in `PATH`: the original five failed exactly
that way, confirming the gap was real, not hypothetical. Fixed by adding
`PKG_BUILD_DEPS="gcc,make"` to all five, re-verified the same way (now
succeeds, since `alpm_sandbox_fetch`'s copy in the sandbox is found first
in `PATH`, ahead of the blocked host copies).

18 more `MANDATORY_ORDER` packages have since been converted the same
way, `PKG_BUILD_DEPS` included from the start: `ncurses`, `bash`,
`coreutils`, `util-linux`, `e2fsprogs`, `iproute2`, `dhcpcd`, `attr`,
`acl`, `grep`, `sed`, `gawk`, `findutils`, `procps-ng`, `kbd`,
`libxcrypt`, `mbedtls`, `kmod` — 23 system recipes total. Spot-verified
(not all 23, but the structurally distinct ones): `procps-ng` (the one
recipe needing the full autotools chain, `autoreconf -fi`, not just
`gcc,make` — `PKG_BUILD_DEPS="gcc,make,autoconf,automake,libtool,
pkgconf,m4"`) rebuilds and its `ps`/`free` both work; `e2fsprogs` (the
one out-of-tree build, using a throwaway `mktemp -d` in place of the
original recipe's build-host-only `$BUILD_DIR/e2fsprogs-build`) rebuilds
and `mkfs.ext4` works; `mbedtls` (the one recipe that only builds a
`lib` target, never `install`, copying headers/`.so` files by hand)
rebuilds and a real `curl` HTTPS request against the freshly-built
libraries succeeds.

Only 6 `MANDATORY_ORDER` packages remain genuinely blocked:
`glibc`/`linux-lts`/`eudev`/`curl`/`sysvinit`/`openrc`. See
[docs/TODO.md](../../docs/TODO.md) for the specific reason each one isn't
convertible yet.

### FloraOS's own files: per-file granular update, not one lump

`fau`'s own dispatcher/subtools/`lib/*.sh`, the 5 compiled C tools
(`fauelf`, `floralogin`, `florauser`, `florainstall`, `floraseat`), and
`floragrub-cfg` needed a genuinely different mechanism from either apps or
system packages: `tools/fau/` alone is ~16 independent files, and neither
a monolithic "fau self-update" nor a hand-authored `.fis` recipe per file
is right — hand-bumping ~22 separate version numbers every time one file
changes is exactly the upkeep burden this feature should avoid adding.

Instead (`tools/fau/lib/selfupdate.sh`), each tracked file is tracked
individually by **git's own blob sha**, which already exists, is already
accurate, and needs no manifest hand-authored anywhere:

- **`floraos_tree_listing`**: one GitHub Trees API request
  (`git/trees/main?recursive=1`) returns `path`+blob-`sha` for every file
  in the repo at once. The response is pretty-printed JSON — confirmed
  against a real response, not assumed — with `path`/`mode`/`type`/`sha`
  each on their own line, so a stateful path-then-type-then-sha `awk` pass
  (the same "hand-rolled, no `jq`" convention `lib/manifest.sh`'s
  `json_get_version` already uses) is enough; `type=="tree"` (a directory
  entry, which the recursive listing also includes) is filtered out,
  leaving only `type=="blob"` (real files).
- **`etc/fau/installed-manifest`** (`path<TAB>blob-sha`, one line per
  tracked file): `build-rootfs.sh` writes the baseline at ISO-build time
  using `git hash-object` locally (confirmed byte-identical to what the
  Trees API reports for the same content — git blob shas are just
  `sha1("blob <size>\0<content>")`, computed identically either way, no
  network needed at build time), reading the tracked-path list from
  `_floraos_tracked_paths` itself (sourced, not duplicated) so build time
  and runtime never disagree about which files are tracked.
- **`floraos_selfupdate_sweep`**: fetches the tree listing once, diffs
  every tracked path's blob sha against `installed-manifest`, and only
  fetches+swaps the ones that actually changed. A bash file is staged to a
  temp path then atomically `mv`'d into place; a `.c` source is recompiled
  first (`gcc -x c` — the fetched file is a plain `mktemp` path with no
  `.c` suffix, and gcc/`ld` only infer "this is C source" from the
  extension otherwise, confirmed by hitting exactly this failure first:
  `ld` treating raw C source text as an unrecognized object/linker
  script). `gcc` itself is only fetched into a throwaway sandbox
  (`alpm_sandbox_fetch`, same mechanism as `fau build`/`bootstrap-build`)
  if at least one changed path is a `.c` file that run — a sweep that only
  touches bash files never pays for it. A cosmetic `system.json` entry
  (`fau`, a date stamp) exists for `fau list`/fastfetch's package count;
  the real per-file state lives in `installed-manifest`, never encoded
  into `system.json`'s one-version-string-per-package shape.
- Safe to run at any point relative to the rest of `cmd_update` (it runs
  last): a changed `tools/fau/fau-install` would replace *the very file
  currently executing `cmd_update`*, but only via a staged atomic `mv`,
  which just repoints the path to a new inode — the already-running
  process keeps reading its own already-open copy of the old file until it
  exits, standard Unix rename semantics, not something that needed new
  protection.

Verified end to end against this project's own real rootfs, including
through the actual `fau` binary (not just the sourced function): a no-op
run (manifest matching the real current remote tree) touches zero files;
staging one stale bash-file entry (`fau-seat`) causes exactly that one
file to be fetched and swapped, confirmed via `md5sum` that every other
tracked file's content is byte-identical before and after; staging one
stale `.c` entry (`floraseat.c`) causes a real recompile (confirmed:
resulting binary is valid ELF, actually executes) while every other file
including the *other* compiled tool (`fauelf`) stays untouched.

### Auto-backup before any `fau update`, and `PKG_NEEDS_DISK` for the packages that actually can't run on a live system

`cmd_update` runs `fau backup "pre-update-<timestamp>"` unconditionally,
once, before any checking/updating happens — not just before a
system-package rebuild. `fau backup` itself already refuses a non-block-
device root (the live RAM image) with its own clear message; that refusal
is expected and non-fatal here (`|| backup_rc=$?`, same pattern
`recipes_sync || true` already uses elsewhere in this file), because most
packages update just fine on a live system — they simply have no snapshot
to fall back to if something goes wrong, same as any package rebuild that
fails for another reason (disk full, etc.). An earlier version of this
feature refused to run `fau update` *at all* on a live system, on the
reasoning that no rollback net means no update — wrong scope: that's a
property of specific packages (the kernel, see below), not of `fau
update` as a whole.

For the rare package where a live-system rebuild isn't just unsafe but
structurally pointless, its own system recipe opts out for itself via
`PKG_NEEDS_DISK="1"`, checked in `fau bootstrap-build`
(`cmd_bootstrap_build`, `tools/fau/fau-bootstrap`) right after sourcing
the recipe: if set and `root_is_block_device` is false, that one
package's rebuild refuses with a clear message, while every other
package in the same `fau update` run proceeds normally (the existing
"rebuild failed, skipping" handling in `cmd_update`'s system-package loop
already treats a failed `bootstrap-build` as non-fatal to the rest of the
run). `fau-recipes/system/linux-lts.fis` is the one recipe that sets it
so far: the live image's actual running kernel is loaded straight off the
boot media, never from any path a live rebuild would touch, so running it
there would burn a long build for zero effect, not just an unsafe one.
Verified directly: sourcing `linux-lts.fis` with a faked non-block-device
root correctly trips the check, while `rsync.fis` (no `PKG_NEEDS_DISK`)
correctly doesn't.

## `build <name>[=<version>]` — installing a specific version, not just the recipe's pinned default

`PKG_SRC_URL`/`PKG_SRC_SHA256`/`PKG_VERSION` are one fixed triple per
recipe by original design — supply-chain safety via a pinned checksum, the
same reasoning every other fetch path in this project pins a hash. An
explicit `=<version>` on the command line (`fau build mangowm=0.14.3`) needs
the recipe's own cooperation to even know what URL corresponds to an
arbitrary version string, since URL shape varies per upstream (some tag
paths, some releases, some with a `v` prefix) — there's no generic template
that would work project-wide. Recipes opt in by defining
`recipe_source_for_version <version>`, printing exactly two lines: the
source URL, then a pinned sha256 for that exact version if the recipe
author has one, or an empty second line if not. `cmd_build` only calls it
at all when the requested version differs from the recipe's own default
(the default path is completely untouched, still fully pinned exactly as
before); a recipe that doesn't define the function fails the request with a
clear "doesn't support installing a specific version" instead of silently
falling through to the default.

The empty-second-line case is the actual hard problem: there is no
checksum to pin for a version nobody's added to the recipe yet, so
`build_fetch_source` (`lib/build.sh`) grew a genuine third state, not just
its existing match/mismatch pair — empty `sha256` skips verification
entirely and fetches anyway, but with a loud `warning: ... downloaded
UNVERIFIED` line, never silently. `mangowm.fis`'s own
`recipe_source_for_version` currently has no per-version pins at all
(mango's tag names are exactly its version strings, confirmed against
https://github.com/mangowm/mango/tags, so the URL is a plain template) —
every non-default mango version is fetched unverified today. Adding a pin
for a specific version later (a `case` branch printing that version's real
sha256 as the second line instead of the empty default) is meant to be
cheap precisely so this stays an easy thing to tighten over time rather
than a permanent gap.

## `install <name>[=<version>]` — version pinning, and a real bug it surfaced

Same `name=version` syntax as `build`, but the *meaning* differs by
install source, and unlike `build` (which only ever has one path — a
recipe), `install` has three (local repo, alpm, recipe-via-`offer_build`),
so getting this right meant threading `version` through
`app_install_one` → `app_install_one_alpm` → `offer_build` correctly:

- **Local repo**: `repo_lookup_version` must match `version` exactly, or
  it's a hard die — a local repo holds one archive per package name (see
  the Repo section below), so there's nothing to negotiate.
- **alpm-resolved**: `app_install_one_alpm` calls `alpm_resolve` *first*,
  unconditionally — only *after* that succeeds does it check `version`
  against the one real (latest) version the mirrors actually have,
  dying if they don't match. This ordering matters: a name
  `alpm_resolve` can't find at all (any AUR-only package, e.g. `dwm`)
  must still fall through to `offer_build` below, not die early just
  because a version was requested and alpm-fallback happens to be
  configured. An earlier version of this fix got the ordering backwards
  — checked "is alpm-fallback available at all" before ever attempting
  resolution, so `fau install dwm=6.8` died with "version pinning isn't
  supported" even though `dwm` was never going to resolve via alpm in the
  first place and should have reached the recipe path below.
- **Recipe, via `offer_build`**: passed straight through to
  `fau build name=version` (see above) once reached.

**A real, independently-serious bug found while fixing this, unrelated to
version pinning itself**: `offer_build` (`lib/common.sh`) still checked
`[ -f "$FAU_RECIPES_DIR/$name.fis" ]` — the flat, ISO-shipped-only check
that predates `recipes_sync`/`recipe_lookup` (`lib/recipes.sh`) entirely.
Since `fau install <name>`'s only path to "build it from source" runs
through `offer_build`, this meant `fau install` could only ever offer to
build a recipe that happened to already be baked into the *current* ISO —
completely bypassing the whole point of splitting recipes into their own
synced-over-HTTPS repo. `fau build <name>` itself was never affected (its
own `cmd_build` already used `recipe_lookup` directly, not this stale
check) — only the `install`-time offer was silently stuck on
whatever-shipped. Caught for real, not by inspection: `dwm` was added to
`fau-recipes` *after* the currently-booted test ISO was built, and `fau
install dwm` on that real system never even reached the "build it from
source?" prompt. Fixed by having `offer_build` call `recipes_sync` +
`recipe_lookup` itself before deciding whether a recipe exists.

## `build <name>` (`fau-build`) — compiling from source, on demand, with a disposable sandbox

Closes a real gap the two install modes above don't cover: a package with
no precompiled binary anywhere (`mangowm`, AUR-only — no official
Arch/Artix repo carries it, so the alpm fallback can never resolve it no
matter the exact name) has no path into this project short of someone
rebuilding it by hand on a separate machine. `fau-build` builds it right
here instead, from a recipe — a completely separate thing from
`scripts/recipes/*.sh`, which stays exactly as it was: base-rootfs
packages, built once on a separate dev/build host, never touched by fau at
runtime. ".fis" ("fau install script") is just a distinct extension so the
two are never confused for each other — plain bash either way, no special
syntax of its own.

### Where a recipe actually comes from: `FAU_RECIPES_REPO`, synced over HTTPS, not baked into the ISO

Recipes used to live only at `FAU_RECIPES_DIR` (default
`/usr/lib/fau/recipes/*.fis`), copied verbatim into the image at ISO-build
time same as the rest of `tools/fau/` (see Staging above). That means a new
recipe, or a version bump to an existing one's `PKG_VERSION`/`PKG_SRC_SHA256`
pin, only ever reached an already-installed FloraOS machine via a whole new
ISO — not an acceptable turnaround for something as small as "someone
pinned a newer mango tag." Recipes now live in their own repo,
[`github.com/Qsenja/fau-recipes`](https://github.com/Qsenja/fau-recipes)
(`FAU_RECIPES_REPO`), split out of this one specifically so pushing there is
enough on its own — no FloraOS release involved.

**Fetched as a plain HTTPS tarball (`lib/recipes.sh`'s `recipes_sync`), never
via `git clone`** — FloraOS ships no `git` binary on the live system at all
(confirmed directly: meson's own optional `git`-version-probe during a real
`mango` build reported "Program git found: NO"), so a runtime `git clone`
was never actually an option here. `git` only needs to exist on whoever's
*maintaining* fau-recipes' own machine, to commit and push to it — the same
"read the real data format directly, don't shell out to the heavyweight
tool" principle the whole alpm fallback below is already built on, just
applied to GitHub's own `codeload`-style
`archive/refs/heads/<branch>.tar.gz` endpoint instead of pacman's sync-db
format.

`recipes_sync` runs automatically as a side effect of `fau build <name>`,
`fau build-list`, and `fau update` alike — every path that needs to know
what recipes/versions actually exist right now triggers a sync first,
**always best-effort, never fatal**: a
failed fetch (offline, DNS hiccup, GitHub down) is logged as a warning and
swallowed, falling back to whatever `FAU_RECIPES_REMOTE_DIR` already has
from a previous successful sync, and beneath that, to the read-only
`FAU_RECIPES_DIR` copy still shipped in the ISO as a baseline — a build
that would have worked offline yesterday must keep working offline today
just because this network call happened to fail. `recipe_lookup` checks the
synced copy first, the shipped one second, so a synced update always wins
when present. Setting `FAU_RECIPES_REPO=""` explicitly (distinct from
leaving it unset, which takes the real default via `${VAR-default}` instead
of `${VAR:-default}`) opts out of network syncing entirely, for anyone who
wants strictly offline, shipped-recipes-only behavior on purpose. An
explicit `fau recipes-update` also exists for triggering a sync on its own,
without also doing a build or a full dependency-version check.

### `recipe_lookup` re-fetches a `.fis` fresh on every call, not just the first

Used to check `[ ! -f "$cached" ]` and skip the network fetch entirely once
any copy of a given `recipes/<name>.fis` already existed locally, trusting
whatever was downloaded the very first time as permanently correct forever
after. That directly fights this whole system's own stated purpose above (a
recipe fix reaching every machine as soon as it's pushed, no new ISO
needed): a machine that built a package once, before a recipe bug was fixed
upstream, would never see that fix on its own. Found live: a FloraOS box
that had already fetched a buggy `cursor.fis` (`PKG_DEPENDS` listing a
nonexistent `eudev` package) kept failing with the exact same already-fixed
error on every retry, since nothing ever re-checked GitHub for that one file
again — only deleting the cached copy by hand made the fix visible. This
also silently affected `fau update`'s own version check for build-installed
packages, which reads `PKG_VERSION` straight out of this same cached file.

Now always attempts a fresh fetch first (same as `recipes.db` itself),
falling back to the last successfully fetched copy only if the network call
fails — offline resilience preserved, staleness-by-default removed.

A recipe here declares two independent dependency lists, not one, because
they have genuinely different lifetimes:

- `PKG_DEPENDS` — real runtime shared-library/CLI dependencies. Resolved
  via alpm and merged **straight into the built app's own directory**
  (`build_merge_depends`, `lib/build.sh`) — deliberately *not* installed the
  way `fau-install`'s own `depends=` works (each dependency in its own
  separate `FAU_APPS_DIR/<dep>/`). Tracing that path down while designing
  this surfaced a real, pre-existing bug: a wrapper script's
  `LD_LIBRARY_PATH` (`app_wrapper_write`, `lib/common.sh`) only ever covers
  its *own* app's directory, so a real `.so` dependency installed as a
  separate app is never found at runtime. Merging the whole resolved
  closure into the same directory as the binary that needs it is the
  actual fix — `fau-install`'s own `depends=` mechanism still has this bug
  today; it just hasn't been hit yet because nothing installed through it
  so far has had a real shared-library dependency beyond glibc.
  `build_merge_depends` skips `filesystem` and any package fau's own
  `system.json` already has an entry for, the same guard
  `install_one_alpm`/`app_install_one_alpm` (`lib/alpm.sh`) apply for the
  glibc-overwrite bug documented below — a stale comment in `lib/build.sh`
  used to claim the opposite (that this path deliberately does *not* skip
  them, reasoning that an isolated `app_dir` has no access to `FAU_ROOT`'s
  search path); the code has always actually skipped them, so treat the
  code as ground truth here, not that comment.
- `PKG_BUILD_DEPS` — build-only tools (a compiler, `meson`, `ninja`, ...).
  Resolved via alpm into a throwaway sandbox directory, **with dev headers
  kept** (`alpm_sandbox_fetch`, `lib/alpm.sh` — every other alpm-fetching
  path in this project strips `usr/include` unconditionally, confirmed no
  existing bypass), `PATH`/`LD_LIBRARY_PATH`/`PKG_CONFIG_PATH` pointed at it
  for the build, then removed unconditionally once the build finishes or
  fails (a `trap ... EXIT` in `fau-build`'s own `cmd_build`) — this system
  never permanently carries a compiler just because it built one thing
  once.

**A real, non-obvious wrinkle found while building the first recipe
(`mangowm`) this way**: `meson` is a Python script with a hardcoded
`#!/usr/bin/python` shebang, not `#!/usr/bin/env python`. FloraOS ships no
Python at all, and a shebang bypasses `PATH` entirely — so a plain
relocated copy of `meson` in the sandbox would try (and fail) to exec the
*real* system's Python, which doesn't exist. `alpm_sandbox_fetch` rewrites
any absolute-interpreter shebang it finds to point at that same sandbox's
own relocated copy instead (a `#!/usr/bin/env foo` shebang needs no fix —
`env` already resolves `foo` via the sandbox-prefixed `PATH`). Verified for
real, not just reasoned about: extracted `meson`+`python` this way, used
`bwrap` to mask the real system's own Python out entirely (without
touching this actual build host), and a trivial C project still
configured/built/ran correctly through the rewritten, fully relocated
copy. Plain ELF build tools (`ninja`, `gcc`, `glslang`) need no such fix —
their own `PT_INTERP` (`/lib64/ld-linux-x86-64.so.2`) is the same
ABI-by-coincidence bet every alpm-fetched binary in this project already
makes, not a new risk.

`fau install <name>` does **not** automatically fall back to this on a
resolve failure — it only hints at `'fau build <name>'` in its own error
message. Building is much heavier (fetches a whole compiler, can take
minutes); a typo in a package name shouldn't silently trigger that.
`fau remove <name>` needs no code of its own here — a built app is a
completely ordinary isolated app once `fau-build` finishes (same
`.pkginfo`/app-directory/`.fau-apps.json` shape `fau-install` itself
produces), so its existing `cmd_remove` already handles it.

Disclosed, not solved: a live (un-installed, RAM-only) boot has no
persistent disk, so compiling something sizeable could exhaust RAM — same
accepted-but-undetected risk class as the alpm fallback's own documented
disk-space caveats below, no live-vs-installed detection added. Also,
`PKG_BUILD_DEPS` is never cached between separate `fau build` runs — every
one re-fetches its own compiler/build tools from scratch, the direct,
intended cost of "wiped every time," not an oversight.

**A real bug found by actually running `fau build mangowm` end to end, not
by inspection**: `cmd_build`'s sandbox cleanup is an `EXIT` trap
(`trap 'rm -rf "$sandbox_dir"' EXIT`), and that trap can fire *after*
`cmd_build` itself has already returned — control falls through the
dispatch `case` statement back to the script's natural end, at which point
`cmd_build`'s stack frame (and anything `local` inside it) no longer
exists. A `local sandbox_dir` crashed with "sandbox_dir: unbound variable"
the instant the trap fired on exactly that path: the build itself had
succeeded completely, only the trap's own cleanup failed, leaving the
sandbox behind — exactly the opposite of "wiped every time" this is
supposed to guarantee. Fixed by making `sandbox_dir` a plain script-global
instead of `local`; safe because `cmd_build` only ever runs once per
process (called directly from this file's own dispatch case, nothing after
it).

## The `mangowm` recipe (`recipes/mangowm.fis`)

`mango` (upstream binary name; AUR package name `mangowm`) is a `dwl` fork
— a wlroots-based tiling Wayland compositor, "dwm but Wayland". Confirmed
directly against https://aur.archlinux.org/packages/mangowm: AUR-only, no
official Arch/Artix repo carries it, so this is the first (and so far
only) real user of `fau build`.

- **Meson is a deliberate one-off exception.** This project avoids
  cmake/meson everywhere else it has a choice (mbedtls picked over OpenSSL,
  a from-scratch seatd reimplementation specifically to dodge "seatd is
  meson/ninja-only upstream", kmod pinned to its last autotools release
  before upstream itself moved to meson — see those recipes/
  docs/ARCHITECTURE.md). mango's upstream ships `meson.build` only, no
  Makefile, and neither it nor its hard dependency `scenefx` offers one —
  unlike every prior case, there's no non-meson alternative to pick here.
- **`scenefx`** (wlrfx/scenefx, the wlroots scene-API effects renderer
  mango's own `meson.build` hard-requires with no build option to disable
  it) is also AUR-only, so it's fetched and built directly inside
  `recipe_build` rather than declared as its own `PKG_DEPENDS` entry —
  `build_merge_depends` needs a real alpm package name to resolve, and
  scenefx has none. It's built straight into the shared `$sandbox_dir`
  (not a separate prefix): the sandbox already carries every header/lib
  scenefx itself needs (mirrored into `PKG_BUILD_DEPS` for that reason,
  not just mango's own build requirements), and installing scenefx's
  output back into that same sandbox means mango's own meson setup finds
  it via the sandbox's already-exported `PKG_CONFIG_PATH` with no second
  prefix to track. Its `.so` is then bundled straight into
  `$app_dir/usr/lib` as `recipe_build`'s last step, since it's a private,
  unnamed runtime dependency mango's own alpm closure has no way to
  express.
- **`wlroots0.19`** is hard-pinned exactly by both scenefx
  (`dependency('wlroots-0.19', version: '>=0.19.0')`) and mango — never
  built by this project itself (`fau install <wm>` fetches wlroots
  precompiled via the alpm fallback, see docs/ARCHITECTURE.md's
  GUI-readiness section), so this recipe builds and links against
  whatever `wlroots0.19` alpm resolves at `fau build` time. Real,
  disclosed risk: only ABI-correct by version coincidence, the same class
  of risk this project already accepts for every alpm-fetched binary, now
  also affecting this recipe's own build output.
- **`mesa`/`libglvnd`/`glslang`** aren't in mango's own `meson.build`
  dependency list at all — they're scenefx's own build requirements
  (egl/gbm/glesv2/glslang), found by actually configuring scenefx and
  reading what meson reported, then running `pacman -Qo` against the
  resulting `.so`s on a real build host (not guessed):
  `libEGL.so.1`/`libGLESv2.so.2` come from `libglvnd`, `libgbm.so.1` from
  `mesa`, and `glslang` (the shader-compiler *program*, not a linked
  library — it never appears in `ldd`) from the `glslang` package. `mesa`
  and `libglvnd` are needed in both `PKG_BUILD_DEPS` (scenefx links them)
  and `PKG_DEPENDS` (mango's own `ldd` shows them as direct runtime deps
  via the bundled `scenefx.so`); `glslang` is build-only.
- **scenefx's own `.pc` file needs the same absolute-path rewrite alpm-fetched
  packages get, but `recipe_build` builds it directly instead of going
  through `alpm_sandbox_fetch`, so nothing did that rewrite for it.**
  scenefx's `meson setup --prefix=/usr` bakes `prefix=/usr` into the `.pc` it
  generates; installing it with `DESTDIR="$sandbox_dir"` relocates the files
  but not that baked-in string, so `scenefx.pc`'s `includedir` still resolves
  to the real host's `/usr/include`. `PKG_CONFIG_PATH` already points mango's
  `meson setup` at the sandbox's `pkgconfig` dir, so it finds the `.pc` file
  and configures successfully — the failure only shows up one step later, at
  `ninja` compile time, as `fatal error:
  scenefx/render/fx_renderer/fx_renderer.h: No such file or directory`,
  which reads like a missing dependency rather than a wrong path. Fixed by
  pulling the `.pc`-rewrite loop out of `alpm_sandbox_fetch` into its own
  `alpm_rewrite_pc_paths <dest> <dir>` (`lib/alpm.sh`). **First version of
  this fix regressed the build it was meant to fix**: it called
  `alpm_rewrite_pc_paths "$sandbox_dir" "$sandbox_dir"` straight after
  `DESTDIR="$sandbox_dir" ninja install`, which re-scans *every* `.pc` file
  already in the sandbox — including the ones `alpm_sandbox_fetch` already
  rewrote while fetching `PKG_BUILD_DEPS` (e.g. `wayland-protocols.pc`'s
  `pkgdatadir` already pointing at `$sandbox_dir/usr/share/wayland-protocols`).
  Since that value still matches `key=/absolute/path`, the rewrite fired a
  second time and prepended `$sandbox_dir` again, producing a doubled path
  (`/tmp/tmp.XXX/tmp/tmp.XXX/usr/...`) that then failed mango's own
  `meson.build` with `ERROR: File //tmp/tmp.XXX/tmp/tmp.XXX/us...` — found by
  actually running `fau install mangowm` after the first fix, not by
  inspection. Fixed for real by installing scenefx with
  `DESTDIR="$scenefx_stage"` (its own fresh `mktemp -d`, touched by nothing
  else), rewriting only *that* directory's `.pc` file, then merging the
  already-correct result into `$sandbox_dir` with `cp -a` — same
  extract-then-rewrite-then-merge shape `alpm_sandbox_fetch` itself already
  uses per-package, just applied to a locally-built package instead of an
  alpm-fetched one.
- **`xorg-xwayland`** is a genuine runtime dependency that never shows up
  in `ldd`: mango links wlroots' xwayland support
  (`wlr_xwayland_create`, confirmed directly in `src/mango.c`), which
  `exec`s the real `Xwayland` binary at runtime instead of linking it. It
  still needs to be listed in `PKG_DEPENDS` for that feature to work —
  same "document the non-obvious runtime need" reasoning as `kbd`
  depending on `gzip`.
- DONE (was: disclosed, not fixed): mango's own compiled-in system config
  fallback path is the literal string `/etc/mango/config.conf`
  (`meson.build`'s own `sysconfdir` handling), which pointed at the real
  host's `/etc/mango`, not this app's own isolated copy, when mango's
  primary lookup failed. Originally assumed this needed patching mango's
  own source to fix — wrong, found by actually reading
  `src/config/parse_config.h`'s real lookup order instead of guessing from
  the error message alone: mango checks `$HOME/.config/mango/config.conf`
  **first**, and only falls back to the compiled-in `/etc/mango/config.conf`
  if that's missing. `app_wrapper_write` already sets `HOME="$app_dir"` for
  every isolated app, so mango's primary lookup already lands somewhere
  real per-app — it was just empty, since mango's own meson install only
  ever populates the fallback path. Fixed entirely in the recipe (no
  mango source patch needed after all): `recipe_build` now also drops the
  same default `config.conf` at `$app_dir/.config/mango/config.conf`,
  matching what mango actually checks first. Found on a real `mango` run
  ("[ERROR]: Failed to open config file: /etc/mango/config.conf" even
  though a `config.conf` demonstrably existed under the app's own `etc/`),
  not by inspection.

## Non-tarball sources: `.deb`-sourced recipes (`vesktop`, `opencode-desktop`) — `build_extract_source`'s `.deb` branch

`build_extract_source` (`lib/build.sh`) used to unconditionally run `tar -xf
"$tarball" -C "$dest" --strip-components=1`, on the assumption every
`PKG_SRC_URL` is a plain tarball with one wrapping "repo-tag/" directory
(true for dwm/mangowm's GitHub-archive tarballs). Neither Electron app
recipe fits that: `vesktop` ships a flat generic-Linux `tar.gz` (no wrapping
directory at all — `--strip-components=1` on a single-path-component member
silently strips it down to nothing, confirmed directly: exit 0, zero files
extracted, no warning printed), and `opencode-desktop` ships no Linux
tarball whatsoever, only `.deb`/`.rpm`/`.AppImage` — confirmed across
several tagged releases, not a one-off gap. `vesktop.fis` works around its
flat-tarball problem entirely inside its own `recipe_build` (re-fetches via
`build_fetch_source` — a cache hit by then — and re-extracts without any
`--strip-components`, ignoring the `$src` fau-build already handed it).
`opencode-desktop` couldn't be worked around the same way: the extraction
that produces (or fails to produce) `$src` runs *before* `recipe_build` ever
gets control, so a recipe has no way to intervene if `tar -xf` itself can't
open the source format at all — and none of `.deb`/`.rpm`/`.AppImage` are
tar archives (`.deb` is `ar`, `.rpm` is cpio+its own lead/header, `.AppImage`
is an ELF stub over squashfs), confirmed directly: `tar -xf` on a real
`.deb` exits 2 ("This does not look like a tar archive").

Of the three, only `.deb`'s container format (`ar`: an 8-byte `"!<arch>\n"`
magic, then a flat sequence of 60-byte member headers each immediately
followed by that member's data, padded to an even byte boundary) is simple
enough to parse without a new dedicated tool — `.rpm`/`.AppImage` would each
need one (`rpm2cpio`+`cpio`, or squashfs tooling/actually executing the
AppImage). `build_extract_source` now special-cases a `*.deb` source: pulls
the `data.tar.*` member (dpkg's actual filesystem payload — `control.tar.*`
is its install-script/metadata half, never wanted here) out of the `ar`
container via a new `ar_extract_member_prefix` helper, then hands that inner
tarball to plain `tar -xf` same as any other source. Prefix-matched, not
exact-matched, because the extension varies by how the `.deb` was built
(`.xz`/`.gz`/`.zst`) — `opencode-desktop`'s happens to be `.xz`.

**Parsed directly via `dd` (byte-precise `skip`/`count` in bytes via
`iflag=skip_bytes,count_bytes`), not shelled out to `ar`/`binutils`** — same
"read the real data format directly, don't shell out to the heavyweight
tool" principle as `lib/alpm.sh`'s own sync-db reader and `recipes_sync`
fetching a raw HTTPS tarball instead of `git clone`. Verified byte-for-byte
identical to a real `ar x` extraction of the same file (a live
`opencode-desktop` release `.deb`) before relying on it, and fast: ~50ms end
to end against that real 119MB file, since `dd`'s block-size + byte-offset
`iflag`s let it `lseek` straight to each member instead of reading through
the file byte by byte.

**A real ordering wrinkle found while wiring this in**: `fau-build`'s
`cmd_build` only ever exported the `$sandbox_dir`-prefixed
`PATH`/`LD_LIBRARY_PATH`/`PKG_CONFIG_PATH` around the `recipe_build` call,
never around `build_extract_source` — harmless for every prior recipe,
since a plain tarball needs nothing from the sandbox to extract (gzip/zstd
are already base-system tools). `opencode-desktop`'s `data.tar` happens to
be `xz`-compressed, though, and `xz`/liblzma isn't a base-system tool here —
so a recipe declaring `PKG_BUILD_DEPS="xz"` had it fetched into
`$sandbox_dir` correctly, but `build_extract_source` still ran with the
*original* `$PATH`, unable to find it. Fixed by exporting that same
sandbox-prefixed environment around the `build_extract_source` call too,
not just `recipe_build` — a plain env-var scoped to that one command
substitution, not a permanent `$PATH` change for the rest of `cmd_build`.

## The `vesktop`/`opencode`/`opencode-desktop`/`cursor` recipes — prebuilt binaries, not from-source builds

All four are proprietary or Electron/Bun-runtime apps where "build from
source" would mean re-deriving the exact same prebuilt runtime upstream's
own CI already publishes (Electron/Chromium isn't actually compiled by
anyone who ships it, and Bun-compiled binaries have no separate source
form at all) — so each recipe pins upstream's own official release asset
directly as `PKG_SRC_URL`, same as any other recipe's source tarball, just
not source code.

- **`vesktop`**: upstream's generic-Linux `.tar.gz` is a flat, self-
  contained Electron bundle with no wrapping directory at all. Two
  consequences: `recipe_build` copies the whole extracted tree verbatim
  (Electron resolves `resources/`/`locales/`/its own bundled `.so`s
  relative to its own executable's directory, so nothing can be split
  out), and — because the tarball is flat — `build_extract_source`'s
  default `--strip-components=1` would silently empty `$src` (see
  `opencode`, below, for the same bug hit again and fixed generically).
  `PKG_BIN` is a shell shim, not the real ELF: Chromium's sandbox needs
  `chrome-sandbox` owned by root with the setuid bit, which `fau build`'s
  unprivileged per-app model has no way to set up, so the shim always
  launches with `--no-sandbox` instead.
- **`opencode`**: a single Bun-compiled binary (`readelf -d` shows only
  glibc). Its release tarball is exactly the flat-file case above —
  `recipe_build` re-fetches (a cache hit) and re-extracts it itself
  without `--strip-components`, rather than changing
  `build_extract_source`'s shared behavior for every other recipe.
- **`opencode-desktop`**: same Electron/`--no-sandbox` shape as `vesktop`,
  but upstream ships no Linux tarball at all, only `.deb`/`.rpm`/
  `.AppImage` — see the `.deb` section above for why `.deb` was the one
  worth supporting. `PKG_BUILD_DEPS="xz"` because this `.deb`'s
  `data.tar` happens to be xz-compressed.
- **`cursor`**: deliberately *not* a port of AUR's own `cursor-bin`
  PKGBUILD, which strips Electron out of the `.deb` and depends on a
  system `electron40` package — an AUR-side disk-sharing optimization
  (Arch packages a handful of pinned Electron versions, shared across
  many Electron apps), not a property of the upstream `.deb` itself.
  Confirmed by extracting the real upstream `.deb` directly: it's fully
  self-contained, same shape as `vesktop`/`opencode-desktop` (even bundles
  its own `rg` ripgrep binary). `PKG_DEPENDS` was verified via `readelf -d`
  on the real bundled binary, not copied from the AUR package's own
  `electron40`-shaped list. No `recipe_source_for_version`: Cursor's own
  CDN path embeds a git commit sha that isn't derivable from the version
  string alone, so `fau build cursor=<other version>` correctly refuses
  rather than guessing a URL that would 404.
- **`libudev.so.1` is deliberately absent from all three Electron
  recipes' `PKG_DEPENDS`.** FloraOS builds its own `eudev` from source,
  unconditionally, as part of every base rootfs (`scripts/recipes/
  eudev.sh`) — already there on every system these recipes could ever run
  on. Listing `"eudev"` isn't just redundant, it's actively fatal: it
  isn't a real Arch/Artix package name at all (Artix's own package for
  this is `udev`, an Artix-only split-out of systemd's udev component,
  unrelated to FloraOS's own from-scratch build under that name) — and
  `alpm_resolve_many` fails outright the instant any *one* requested name
  can't be resolved, aborting the merge for every other, genuinely
  resolvable dependency too. Found live: `fau install cursor` on a booted
  FloraOS machine died with "couldn't resolve 'eudev' in any configured
  Arch/Artix repo", having correctly resolved the other 24.

## The `tor-browser` recipe — a different reason to bypass its own AUR PKGBUILD

`tor-browser-bin`'s real PKGBUILD is unusual even among AUR-only prebuilt
packages: its `sha256sums_x86_64` is a live `$(_dist_checksum ...)` shell
function that `curl`s the Tor Project's own published checksum file *at
build time* — never a hardcoded hash — and its `package()` doesn't even
extract the downloaded tarball; it stores the pristine `.tar.xz` itself
under `$pkgdir/opt/tor-browser/` (see its own `noextract=`) for a
template-generated wrapper script to self-extract on first run. None of
that is safe or sensible to mechanically translate. Tor Browser's own
official upstream tarball is already a fully self-contained, ready-to-run
bundle (this is literally how the Tor Project tells every Linux user to
install it) with one common wrapping directory, so `build_extract_source`'s
default path works with no special handling. `PKG_DEPENDS` was verified via
`readelf -d` against the real bundled `Browser/libxul.so` — most of its own
`NEEDED` entries are bundled right there in `Browser/` itself (found via
the same directory search `app_wrapper_write` already does), only the
genuinely-external system libraries are listed. No `--no-sandbox` shim
needed here, unlike the Electron recipes above: Firefox's own sandbox is
seccomp-bpf/namespace-based, not the setuid-helper-binary design Chromium
uses.

## Manifests (`system.json` / `apps.json`) — `lib/manifest.sh`

Flat schema only: `{"packages":{"name":{"version":"x"}}}`, hand-rolled
grep/sed parsing (`json_get_version`, `json_set`, ...) — fine at this scale,
revisit if the schema ever grows past one level.

`json_set`/`json_unset` used to rebuild the file by calling `json_list_names`
(one grep+sed pass) and then `json_get_version` (another grep+sed pair) once
per *existing* name — O(n) forks to re-register n-1 untouched entries every
single call, so registering a full base system's worth of packages was
O(n^2) forking overall. `json_pairs` parses `name<TAB>version` for every
entry in one grep+sed pass instead, used internally by both; measured
building a 30-package registry from scratch (`build-rootfs.sh`'s own
`MANDATORY_ORDER` is close to this size): 0.949s -> 0.420s. Output verified
byte-identical against the original across a 30-entry build-up plus removals
and an overwrite, not just eyeballed. `json_get_version`/`json_list_names`
themselves are untouched — their many single-lookup call sites elsewhere
(`fau-install`, `fau-export`, `fau-bootstrap`) were never the O(n^2) part.

**A real bug found in `fau-bootstrap`'s `cmd_bootstrap_apply`**: it used to
read only the package names out of the manifest via a hand-rolled pass and
silently drop the version each one was pinned to, so `bootstrap-apply` never
actually verified it installed what the manifest recorded — a version
mismatch just passed silently. Fixed by reusing `json_list_names`/
`json_get_version` (the exact same parsing `system.json`'s own read path
already uses) instead of a second hand-rolled regex, and passing the
recorded version through to `install_one` so a mismatch against the repo is
a hard error (see `depends=` version constraints above).

`fau-bootstrap`'s `remove_one_file` only deletes a package's file from
`FAU_ROOT` if no *other* still-installed package's own file list also
claims it — packages legitimately share paths since rsync merges every one
into the same root (e.g. two packages both shipping the same merged-`/usr`
directory). A package installed before fau tracked per-package file lists
(or a transitive alpm dependency never independently tracked in
`system.json` to begin with) has no file list to remove from at all;
`bootstrap-remove` just untracks it from `system.json` in that case, files
left in place.

## `export`/`import` (`fau-export`) — the `system.flora` bundle format

A `system.flora` is a tar+zstd archive, the same format as fau's own
`.fau.tar.zst` packages just under a distinct extension — no zip/unzip
anywhere in FloraOS (would be a new, otherwise-unjustified dependency) when
tar+zstd is already required for fau itself. It contains:

- `system.json` — base packages (`FAU_SYSTEM_JSON`) + installed apps
  (`FAU_APPS_JSON`) + a `configs` map of every config file path found under
  each installed app's own `config/` dir, e.g.
  `"configs":{"kitty":["kitty.conf","startup.conf"]}`.
- `configs/<app>/<relpath>` — the actual config file contents, matching the
  manifest's `configs` entry for `<app>`.

Each of the three top-level keys is written on its own single line with no
embedded newlines, so `manifest_section_get` can pull one out with a plain
grep/sed instead of a real JSON parser — the same hand-rolled approach
`lib/manifest.sh`'s `json_get_version` already takes.

`cmd_import` reinstalls any app the manifest lists that isn't installed
locally yet (so there's somewhere for its config to land), but leaves an
already-installed app as-is — only its config gets restored — rather than
force-reinstalling over a version the user may have deliberately changed
since export. It shells out to the sibling `fau-install` tool for that
reinstall (same "call the tool, don't inline its logic" shape as elsewhere
in this project) rather than sourcing `app_install_one` directly.

## Dead-weight strip: `strip_unreachable_docs` (`lib/common.sh`)

Every package merge point (`install_one_alpm`, `app_install_one_alpm`,
`build_merge_depends`) already stripped `/etc`/`usr/include`; measuring a
real full base-system build found `usr/share/man` (47M, 3546 files across
20 languages), `usr/share/locale` (46M, 91 languages' `.mo` catalogs),
`usr/share/info`, and `usr/share/doc` made up the biggest chunk of rootfs
size that's provably never read at runtime:

- **`man`/`info`**: no `man` or `info` reader binary exists anywhere in
  `usr/bin` on this system — confirmed by grepping the built rootfs, not
  assumed. Not "an unused feature," genuinely unreachable: nothing could
  open these files even if asked to.
- **`locale`**: `/etc/profile` (`apply-skeleton.sh`) hardcodes
  `LANG=en_US.UTF-8` always — gettext only ever consults a `.mo` catalog
  matching the current `LANG`, so the other 90 languages shipped are never
  read. English itself has no catalog to begin with (untranslated strings
  are the built-in default), so stripping all of them costs nothing today.
  A locale switcher that re-fetches the needed language on demand (rather
  than shipping all 91 by default) is proposed but not yet built — see
  docs/TODO.md.
- **`doc`**: each package's own README/NEWS/ChangeLog — reference-only,
  never opened by a running program.

`strip_unreachable_docs` (`lib/common.sh`) deletes all four from every
`FAU_ROOT`/app-dir merge. `scripts/lib/common.sh`'s `package_stage` (a
separate file — the build pipeline doesn't source `tools/fau/lib/`) strips
the same four from every from-source `MANDATORY_ORDER` package before it's
staged, since those merge into the base system via `fau-bootstrap`'s
plain-rsync `install_one`, not the alpm path `strip_unreachable_docs`
covers. `build-rootfs.sh` additionally deletes `usr/share/i18n` (17M) from
`$ROOTFS_DIR` right after its own `localedef` call — that's localedef's
*source* data (every locale/charmap that exists, from glibc's own
from-source build), needed only to generate `en_US.UTF-8` once at build
time, never read again afterward.

Measured end-to-end on a full rebuild: rootfs 519M -> 392M, ISO 222M ->
192M. Boot-tested (`scripts/test-iso.sh`) and `fastfetch` (which touches
fontconfig/ttf-dejavu, an unrelated codepath) still renders correctly —
this strip only ever touches `usr/share/{man,info,doc,locale}` and
build-time-only `usr/share/i18n`, never fonts, icons, or anything else
under `usr/share`.

## `strip_unusable_tmpfiles` (`lib/common.sh`): audit.conf's tmpfiles.d rules OpenRC can't satisfy

Found on a real boot: `tmpfiles.setup` (OpenRC's own init.d service, running
`/libexec/rc/sh/tmpfiles.sh`) logged `cp: cannot stat '': No such file or
directory` plus failed `chown`/`chgrp` on `/etc/audit/audit-stop.rules`,
`/etc/audit/auditd.conf`, `/etc/libaudit.conf`, every single boot. Traced
to `usr/lib/tmpfiles.d/audit.conf` (shipped by the `audit` package, dragged
in as a transitive dependency of `dbus`/`pam` — FloraOS never runs
`auditd`, no runlevel entry exists for it) and OpenRC's own `_C()`
tmpfiles handler (`libexec/rc/sh/tmpfiles.sh`):

```
_C() {
	# recursively copy a file or directory
	local path=$1 mode=$2 uid=$3 gid=$4 age=$5 arg=$6
	if [ ! -e "$path" ]; then
		dryrun_or_real cp -r "$arg" "$path"
```

`audit.conf`'s own `C` lines all use the standard systemd-tmpfiles
shorthand for "no explicit source, copy from the factory-default path"
(`C /etc/audit/audit-stop.rules - - - - -`) — every field including the
source is `-`. Real systemd `tmpfiles-setup` special-cases an empty source
to mean `/usr/share/factory/<path>`; this OpenRC reimplementation doesn't
implement that fallback at all, so `$arg` reaches `cp -r` as a literal
empty string, always failing, regardless of whether `/usr/share/factory`
exists. Not fixable by providing the missing factory-default files —
OpenRC's own script never looks there in the first place.

Since nothing in FloraOS actually consumes this config (no `auditd`
running), the fix mirrors the existing "Arch's `filesystem` package
applies unwanted distro tuning" precedent above: delete the one specific
noise-generating file rather than work around a tmpfiles.d fallback
mechanism that would only ever matter if `audit` were actually a service
this project ran. `strip_unusable_tmpfiles` runs alongside
`strip_unreachable_docs` at every merge point (`install_one_alpm`,
`app_install_one_alpm`, `build_merge_depends`, `cmd_bootstrap_build`).

## Repo (`repo_add`/`repo_index`) — `lib/repo.sh`

- A repo directory holds **at most one archive per package name**.
  `repo_index` just globs every `*.fau.tar.zst`; without `repo_add` deleting
  the old archive on a version bump first, you get duplicate keys for the
  same name and which one `repo_lookup_file` resolves to depends on
  filesystem glob order, not on what was actually just added.
- **`repo_add` used to call full `repo_index` after every single add**,
  which re-extracts pkginfo (a `tar` + `mktemp -d` + `sha256sum`) from
  *every* archive in the repo dir, not just the new one — and its own
  duplicate-name check separately re-extracted pkginfo from every other
  archive too. Building a full base system calls `repo_add` once per
  package (`package_stage`, `scripts/lib/common.sh`), so both were O(n)
  work per call, O(n^2) real tar extractions overall for n packages.
  `repo_set`/`repo_pairs` (mirroring `lib/manifest.sh`'s `json_set`/
  `json_pairs` fix) rebuild repo.json from a single grep+sed pass over the
  *existing* repo.json instead of the archives themselves, and the
  duplicate check now looks up the old filename via `repo_lookup_file`
  (already-indexed data) rather than re-extracting every archive. Measured
  against this project's own real 31-package repo, added in build order:
  16.9s -> 1.59s. Verified against the original: repo dir contents
  identical, and `repo_lookup_file`/`repo_lookup_version` return identical
  answers for every package, including the version-bump/archive-replace
  path. `repo_index` itself (the explicit `fau repo-index` full-rebuild
  command) is untouched — rebuilding from the archives on disk from
  scratch is exactly what that command is for.

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

Each `fau-install`ed app lives entirely under `FAU_APPS_DIR/<name>/`: its own
files plus `config`/`cache`/`data`/`logs` subdirs. The wrapper scripts in
`FAU_APPS_BIN_DIR` work by setting `HOME`/`XDG_*_HOME` to redirect an app
into its own directory before exec'ing the real binary, which works for any
app that follows the XDG Base Directory spec (most modern Linux software
does). Disclosed limit, not a bug: an app that hardcodes absolute paths
instead of respecting `XDG_*_HOME`/`HOME` won't cooperate with this
isolation.

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
  - **libxkbcommon's own compiled-in default XKB data root** (e.g.
    `/usr/share/xkeyboard-config-2`, confirmed via `strings` on the real
    alpm-fetched `libxkbcommon.so.0`) is a real absolute host path, same
    class of bug as perl's `@INC` above — the `xkeyboard-config` package's
    own data merges correctly into the isolated app, but libxkbcommon never
    looks there. Found running mango for real: "Couldn't find file
    'rules/evdev' in include paths" even with `xkeyboard-config` correctly
    in `PKG_DEPENDS` and correctly merged into the app. Fixed via
    `XKB_CONFIG_ROOT` (libxkbcommon's own supported override) — set
    whenever a `rules/evdev` marker file is found anywhere under the app
    (present at `<root>/rules/evdev` in every real `xkeyboard-config`
    install, so this only ever fires for an app that actually bundles the
    data). Verified for real with `bwrap` masking the actual system path
    first: fails identically to the real error without this override
    (down to the exact same "1 include paths searched" message), succeeds
    with it — both through the real generated wrapper script, not just the
    override in isolation.
  - **libglvnd's EGL vendor ICD search path** is hardcoded to
    `/etc/glvnd/egl_vendor.d` and `/usr/share/glvnd/egl_vendor.d` — mesa's
    own `50_mesa.json` (the file that tells glvnd's `libEGL.so.1` dispatcher
    where mesa's actual `libEGL_mesa.so.0` lives) merges correctly into the
    isolated app at `$app_dir/usr/share/glvnd/egl_vendor.d/50_mesa.json`
    (confirmed via `pacman -Ql mesa`), but glvnd never looks there — same
    bug class as the two above, just one library further down the chain.
    Symptom: mango's `render/fx_renderer/fx_renderer.c:282` "Could not
    initialize EGL", preceded by "EGL_EXT_platform_base not supported" and
    "Failed to create EGL context" — glvnd silently finds zero vendor ICDs
    and EGL init fails outright, even with a working KMS driver underneath
    and mesa's real `.so` sitting right there in `LD_LIBRARY_PATH`. Fixed
    via `__EGL_VENDOR_LIBRARY_DIRS` (libglvnd's own documented override,
    see `icd_enumeration.md` in the libglvnd repo) — set whenever a
    `glvnd/egl_vendor.d` marker directory is found anywhere under the app.
    Verified for real with `bwrap` masking the real `/usr/share/glvnd` path
    first: `eglinfo` fails identically to the real symptom (empty EGL
    client-extensions string, `eglInitialize failed`) without the
    override, and `EGL_EXT_platform_base` reappears in the extensions list
    once `__EGL_VENDOR_LIBRARY_DIRS` points at a copy of the vendor JSON,
    even with the real path still masked.
  - **mesa's own `libgbm.so` backend loader** has a THIRD, separate
    hardcoded search path (`$libdir/gbm`, i.e. `/usr/lib/gbm`) for
    dlopen'ing its actual backend (`dri_gbm.so`, confirmed via
    `pacman -Ql mesa`: merges correctly into
    `$app_dir/usr/lib/gbm/dri_gbm.so`) — one library deeper than the
    `__EGL_VENDOR_LIBRARY_DIRS` fix above, same bug class again. Symptom,
    confirmed byte-for-byte against a real `mango` run via a live
    screenshot (not guessed): `fx_renderer.c:282] Could not initialize EGL
    object file: No such file or directory (search paths /usr/lib/gbm,
    suffix _gbm)` — the `__EGL_VENDOR_LIBRARY_DIRS` fix gets glvnd to find
    mesa's EGL driver, which then fails one step further in trying to load
    its GBM backend. Fixed via `GBM_BACKENDS_PATH` (mesa's own documented
    override, `src/gbm/main/backend.c`). Verified for real with `bwrap`
    masking the real `/usr/lib/gbm` path first: `eglinfo -p gbm` fails with
    the exact same "search paths /usr/lib/gbm, suffix _gbm" text without
    the override, and succeeds end-to-end (full EGL/GL context creation)
    once `GBM_BACKENDS_PATH` points at a copy of the backend `.so`, even
    with the real path still masked.
  - **wlroots' own Xwayland integration** checks a hardcoded absolute
    `/usr/bin/Xwayland` rather than searching `PATH` (which already
    includes `$app_dir/usr/bin`) — `xorg-xwayland` (already in mango's
    `PKG_DEPENDS`) merges its real binary in at
    `$app_dir/usr/bin/Xwayland` fine (confirmed via `pacman -Ql
    xorg-xwayland`), wlroots just never looks there. Symptom, confirmed
    against a real `mango` run (over a working serial console, once the
    interactive graphical session hit the seat-freeze below):
    `[xwayland/server.c:472] Cannot find Xwayland binary
    "/usr/bin/Xwayland"` — non-fatal, mango continues without X11 app
    support, but still a real isolation gap. Fixed via `WLR_XWAYLAND`,
    wlroots' own documented override (`docs/env_vars.md`) — exists
    specifically so a caller can swap in an alternate Xwayland without a
    global system change, which is exactly this situation.
  - **libinput's own device-quirks loader** is hardcoded to
    `/usr/share/libinput` — `libinput` (already in mango's `PKG_DEPENDS`)
    merges its real quirks files in at
    `$app_dir/usr/share/libinput/*.quirks` fine (confirmed via `pacman -Ql
    libinput`), libinput just never looks there. Symptom, confirmed
    against the same real `mango` run: `libinput error:
    /usr/share/libinput: failed to find data files` — non-fatal (degraded
    device behavior, not a crash), same isolation gap as everything else
    here. Fixed via `LIBINPUT_QUIRKS_DIR` — not documented in any man
    page, but confirmed directly via `strings` on the real alpm-fetched
    `libinput.so.10`: the literal env var name sits right next to
    `../libinput/src/quirks.c` and the `/usr/share/libinput` default,
    unambiguously the same lookup (same standard of evidence used for
    `XKB_CONFIG_ROOT` above — a synthetic CLI-based `bwrap` check wasn't
    possible this time, `libinput-tools` isn't installed and installing it
    needs a root password this session doesn't have, so this one is
    pending the next real `mango` run for final confirmation instead).
  - **The actual freeze that motivated finding these two**: once EGL/GBM
    init succeeded (the three fixes above), `mango` stopped crashing but
    the interactive graphical QEMU session it ran in still hung completely
    — no display update, no response to input, not even VT-switch
    (`Ctrl+Alt+F2`) getting through. Root cause found and fixed —
    `floraseat` (`tools/floraseat/floraseat.c`) opened every device fd
    (DRM, evdev, hidraw) without `O_NONBLOCK`, so libinput's device-add
    sync did a plain `read()` that genuinely blocked forever on whatever
    device it enumerated first. See docs/ARCHITECTURE.md for the full
    diagnosis (`/proc/<pid>/stack`, `/proc/bus/input/devices`) and fix.
  - **`rofi -show drun` listed no apps at all.** Same isolation gap as
    everything above, one layer further out: each isolated app's own
    `usr/share/applications/*.desktop` (if it ships one at all — `foot`'s
    real alpm package ships none, confirmed via `pacman -Ql foot`; `kitty`
    does) merges into that app's own `$app_dir` fine, but `XDG_DATA_HOME`
    is set to that same private `$app_dir/data` per app (by design, for
    isolation) — no app can ever see *another* app's `.desktop` entries,
    so a launcher has nothing to scan regardless of its own config. Fixed
    via `app_desktop_merge` (`lib/common.sh`), called right after
    `app_wrapper_write` from both `fau-install` and
    `app_install_one_alpm` (`lib/alpm.sh`): copies an app's own
    `.desktop` files into a new shared, XDG-shaped tree
    (`FAU_APPS_DIR/.data/applications`, mirroring the existing
    `FAU_APPS_BIN_DIR`/`.bin` convention exactly), rewriting each
    `Exec=` line's command token to the real `FAU_APPS_BIN_DIR` wrapper
    (verified against both `Exec=kitty` and `Exec=/usr/bin/kitty --flag
    %U`-style lines — trailing arguments preserved, leading path
    stripped) so launching from `rofi` actually runs the same isolated
    binary a shell's own `kitty` would. Every app's own wrapper now also
    exports `XDG_DATA_DIRS` including that shared tree unconditionally
    (not just apps that happen to ship their own `.desktop` file) — a
    launcher like `rofi` needs it on *its own* wrapper to find everyone
    else's entries, not just its own. `fau remove` mirrors the merge in
    reverse, deleting the same basenames from the shared tree before the
    app's own directory (the merge's source list) is gone.

## The alpm (Arch/Artix repo) fallback — `lib/alpm.sh` — no `pacman` binary, ever

Reads pacman's own *data formats* directly (sync db, desc files,
mirrorlist, `pacman.conf`'s repo list) — never shells out to the `pacman`
binary. Works both at build time (fast path: reads the build host's own
`/etc/pacman.d/mirrorlist` + `/var/lib/pacman/sync`) and from inside an
already-booted FloraOS system (no pacman, no synced db at all — falls back
to fetching a mirrorlist/db copy FloraOS ships at `/etc/fau/` for exactly
this). Real, disclosed caveat: fetched binaries are built against Artix's
glibc — only ABI-compatible with FloraOS's own from-scratch glibc by
current-version coincidence, not by any guarantee. GUI apps fetched this
way also have no display server to draw on yet (see docs/ARCHITECTURE.md)
— this gets the files installed, not a running X11/Wayland session.

**Bugs found doing this for real, not from reading the code:**

- **A single dead mirror used to abort the whole install.** One
  mirrorlist entry's DNS name didn't resolve from inside a QEMU guest
  network, while every other mirror worked fine — `alpm_fetch` now tries
  every configured mirror in order before giving up, matching what real
  `pacman` would do.
- **A handful of specific packages burned tens of seconds retrying mirrors
  that were never going to work**, on top of the fix above — a real `fau
  install mangowm` showed `libxfont2`/`xorg-server-common`/
  `xorg-xwayland`/`python` each 404ing on *nearly every* mirror in Artix's
  full list, in the same consistent order, before one near the end finally
  had the package (mirror sync lag: fau resolved a version newer than most
  mirrors had caught up to yet), while every other package in the same
  closure resolved on the first or second try. Each failed attempt still
  paid a real ~2s connection-setup cost, so a few stale-everywhere packages
  could dominate total install time. Fixed by having `alpm_fetch`
  stable-sort each fetch's mirror list by that host's own recorded past-
  failure count before trying it — every mirror is still eventually tried
  (a chronically-laggy mirror can still be the only one with a given
  package), this only changes the order, converging over repeated real
  `fau` runs toward trying the reliable mirrors first. Counts persist to
  `$FAU_CACHE_DIR/mirror-fail-counts`, written only on failure (zero extra
  I/O on the common all-succeeds-immediately path), no locking (a lost
  update under `alpm_parallel_fetch`'s own concurrent fetch jobs just means
  one less data point for a soft ranking heuristic, not a correctness bug).
  One real bug caught only by testing: the very first failure ever
  recorded was silently dropped, because `awk` exits before its `END`
  block when given a nonexistent input file — fixed by touching the stats
  file into existence first, verified with 4 local `python3 -m
  http.server` mirrors (3 dead, 1 live, live one placed last) showing the
  second fetch against the same dead mirrors succeeds on the first attempt
  once their failures are on record, with zero retries logged. See
  ARCHITECTURE.md's own "Not yet scripted" section for the full writeup.
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
- **A tab-delimited resolution record silently corrupted the instant a
  middle field was empty.** `alpm_repo_index`/`alpm_resolve`'s own records
  originally used a literal tab as the field separator, but bash's `read`
  collapses *consecutive* IFS-whitespace separators (a tab counts as
  whitespace regardless of what `IFS` is set to) — the moment a field in
  the middle was empty (e.g. a package with no `depends` or no
  `provides`), every field after it silently shifted by one position.
  Found by tracing a real resolution: `linux-api-headers` (empty
  depends+provides) ended up looking like it "depended on" its own
  filename. Fixed by switching every such record to `$ALPM_FS` (`\x1f`,
  ASCII unit separator) — not whitespace, so `read` preserves empty
  fields correctly; verified directly before relying on it project-wide.
- **The "skip a package fau's own system.json already provides" guard
  silently never fired for a request resolving through a PROVIDES alias.**
  Both `install_one_alpm` and `app_install_one_alpm` guard against
  reinstalling the *actual requested* package over itself by checking
  index `"$i" -ne "$total"` (relying on `alpm_resolve`'s "dependencies
  before dependents" contract, so the requested package's real name is
  always the last resolved entry) rather than `"$pkgname" != "$name"`.
  That distinction matters because the requested package's real name can
  differ from the name the user typed: `fau install man` resolves through
  a virtual/PROVIDES alias to the real package `man-db`, so no `$pkgname`
  in the closure ever literally equals the string `"man"` — a
  name-equality check's "unless it's the actual requested package"
  carve-out silently never applied for that case. Found via a real `fau
  install man` quietly skipping-or-not going wrong, not by inspection.
- **`app_install_one_alpm` crashed with "target_files: unbound variable"
  under `set -u`** before its `local` declaration explicitly initialized
  it to `""`. A `local a b="" c=0` line only implicitly empties the names
  that get an explicit `=value`; a bare name alongside them (`a` here)
  is genuinely unbound, not `""`, on this bash — confirmed by reproducing
  the exact crash in isolation. This is also what made the `man`/`man-db`
  alias bug above easy to hit in practice: with the wrong guard,
  `target_files` was never reached by the assignment that would have set
  it, so `fau install man` crashed on the unbound variable before even
  getting to the guard's own wrong consequence.
- **`fau install fastfetch` produced a 75MB app directory for a small
  login-banner tool** before `app_install_one_alpm` skipped
  already-system-provided packages the same way `install_one_alpm` does.
  `fastfetch`'s own real dependency closure includes `glibc` — headers,
  static libs, locale/zoneinfo data, glibc's own utility binaries — even
  though FloraOS's from-source glibc is already on the system's default
  library search path (`app_wrapper_write`'s `LD_LIBRARY_PATH` is
  additive, not exclusive). Measured directly: ~14MB of that 75MB was
  glibc's headers alone. Fixed by mirroring `install_one_alpm`'s
  already-provided-package skip in the app-install path too.

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
- **`alpm_find_provider` itself re-scanned an entire repo's index file via
  `awk` on every single call** — once per dependency *edge* in the whole
  transitive closure, not once per unique package. Measured against
  `mangowm`'s real PKG_DEPENDS+PKG_BUILD_DEPS closure (176 resolved
  packages, indexes already warm): 4.1s of pure resolution time. Fixed the
  same way as `alpm_repo_provides_index` above — each repo's index/
  provides-index now loads into a plain bash associative array once per
  process (`ALPM_NAME_CACHE`/`ALPM_PROVIDES_CACHE`, lazily, guarded by
  `ALPM_INDEX_LOADED`/`ALPM_PROVIDES_LOADED`), turning every subsequent
  lookup into an in-memory hash hit: 2.1s for the same closure, byte-
  identical resolved output verified before/after. `ALPM_REPO_NAMES_CACHE`
  gets the same treatment for the repo-name list itself.
- **A subshell silently defeated an earlier version of that same cache.**
  `_alpm_resolve_one` called `alpm_find_provider` via
  `found=$(alpm_find_provider ...)` — a command substitution forks a
  subshell, so every cache write the function made was discarded the
  instant it returned. That version came out *slower* (23s) than the
  original despite every lookup being a hash hit in principle — the whole
  cache was rebuilt from scratch inside a fresh, doomed subshell on nearly
  every call. Fixed by having `alpm_find_provider` set a global
  (`ALPM_FOUND_PROVIDER_RESULT`) instead of printing to stdout, and calling
  it directly rather than through `$(...)` — the repo-name-list cache had
  fallen into the identical trap on its own call site and needed the same fix.
- **`_rpmvercmp`'s leading-zero strip** (`sed 's/^0*//'`) is plain bash
  parameter expansion now, not a `sed` subprocess spawned twice per numeric
  segment compared on every version check during resolution. Verified
  byte-identical output against the original across 27 real version-string
  pairs, including a real trailing-segment quirk (`0.000` vercmp `0` == 1,
  not 0) confirmed to be pre-existing algorithm behavior, not something
  either version changed.
- **`app_wrapper_write`'s 8 separate `find $app_dir` traversals were
  consolidated into 1.** An earlier pass measured this against a synthetic
  21,000-file tree and concluded it wasn't worth touching (0.2s total) —
  that number only counted the tree walks themselves. Measured for real
  against `fastfetch`'s actual installed app dir plus a real 23,000-file
  rootfs standing in for a large Electron-scale app, the dominant cost
  turned out to be the per-match `dirname` *subprocess fork* the `.so`/`.pm`
  collectors run once per match (646 of them on that rootfs), not the
  traversal — 0.451s down to 0.056s (~8x) once one `find` (emitting
  `%y %p\0`, classified in a single bash loop, `dirname` done via `${x%/*}`
  parameter expansion instead of a subshell per match) replaced both the
  8 walks and the per-match forks. Wrapper output verified byte-identical
  against the original on a real installed app dir, not just eyeballed.

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
user-rename <old-name> <new-name>`, instead of florauser's) and then runs
the real `florauser <cmd> "$@"` — no argument validation, password
handling, or file editing is duplicated here. `user-add`/`user-rename`/
`user-groupadd`/`user-addtogroup` route through `lib/common.sh`'s
`relabel_run`, which rewrites florauser's own "florauser: ..." messages to
say "fau user-add: ..." (etc.) instead, including any inline mention of
running `florauser <verb>` (e.g. `add`'s own "run: florauser passwd
alice" advice becomes "run: fau user-passwd alice") — end users only ever
type `fau user-*`, so florauser's messages should say so too.
`user-passwd` deliberately skips `relabel_run`: its interactive prompt
(termios echo off, no trailing newline so the cursor stays on the same
line) would sit stuck, invisible, in `relabel_run`'s line-oriented sed
until some later newline flushed it out — confirmed with a throwaway C
reproducer (printf, fflush, sleep, more printf) piped through the same
`relabel_run`: the prompt and everything printed after it arrived in the
same instant, well after the `fflush`, instead of the prompt appearing
immediately. It execs `florauser passwd` directly instead, working
unmodified since bash doesn't redirect stdio for a plain function call —
its "florauser: password updated for ..." confirmation and error messages
keep florauser's own naming as the tradeoff for a live prompt.

Verified in a real QEMU boot (before `relabel_run` existed): `fau user-add
alice seat` + `fau user-passwd alice` + `fau user-rename alice bob`,
confirming the renamed `passwd`/`shadow`/`group` entries directly and then
logging in as `bob` with `alice`'s original password — `id` still showed
the `seat` group membership, proving the whole chain (florauser's own
rename logic, exec'd through this front end) actually works end-to-end,
not just each piece in isolation. `relabel_run` itself is verified only
against a throwaway stub standing in for florauser (matching its exact
message shapes, including the unterminated `user-passwd` prompt) in this
sandbox, not yet against the real compiled florauser on a real boot.

## `fau help <topic>` / `fau --help <topic>`

The top-level `usage()` is deliberately short — an ever-growing flat
command list stops being scannable. `usage_topic <name>` holds the actual
per-command detail, grouped to match the sections above (`install`,
`repo`, `export`, `backup`, `service`, `seat`, `user`, `bootstrap`), plus
`all` to print
every topic at once. A few aliases (`pkg`/`package`/`packages`/
`packagemanager` all map to `install`) exist purely for discoverability —
someone reaching for `fau help packagemanager` shouldn't hit a dead end.
