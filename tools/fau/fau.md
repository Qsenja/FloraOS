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

Both of those only ever move *already-built* files around (a local
`.fau.tar.zst` or a precompiled alpm binary) — see `build <name>`
(`fau-build`) just below for the third mode: compiling something from
source, on this same live system, on demand.

## `build <name>` (`fau-build`) — compiling from source, on demand, with a disposable sandbox

Closes a real gap the two install modes above don't cover: a package with
no precompiled binary anywhere (`mangowm`, AUR-only — no official
Arch/Artix repo carries it, so the alpm fallback can never resolve it no
matter the exact name) has no path into this project short of someone
rebuilding it by hand on a separate machine. `fau-build` builds it right
here instead, from a recipe shipped inside the image at `FAU_RECIPES_DIR`
(default `/usr/lib/fau/recipes/*.fis`) — a completely separate thing from
`scripts/recipes/*.sh`, which stays exactly as it was: base-rootfs
packages, built once on a separate dev/build host, never touched by fau at
runtime. ".fis" ("fau install script") is just a distinct extension so the
two are never confused for each other — plain bash either way, no special
syntax of its own.

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
- **Disclosed, not fixed**: mango's own compiled-in system config
  fallback path is the literal string `/etc/mango/config.conf`
  (`meson.build`'s own `sysconfdir` handling), which an isolated app has
  no way to redirect — `app_wrapper_write`'s `XDG_CONFIG_HOME` correctly
  covers mango's *user* config search, but the system-wide fallback still
  points at the real host's `/etc/mango`, not this app's own isolated
  copy. Same class of isolation-model rough edge as perl's own
  compiled-in `@INC` (see `app_wrapper_write` above) — not patched here
  since fixing it means patching mango's own source, a bigger
  intervention than this recipe's actual job.

## Manifests (`system.json` / `apps.json`) — `lib/manifest.sh`

Flat schema only: `{"packages":{"name":{"version":"x"}}}`, hand-rolled
grep/sed parsing (`json_get_version`, `json_set`, ...) — fine at this scale,
revisit if the schema ever grows past one level.

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
