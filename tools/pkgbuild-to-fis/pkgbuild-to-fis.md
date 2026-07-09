# pkgbuild-to-fis — implementation notes

Design rationale mined from `pkgbuild-to-fis`'s own comments. Maintainer-side
tool only — never shipped in the ISO, never run on a live FloraOS system
(unlike everything under `tools/fau/`). See
[../fau/fau.md](../fau/fau.md) for the recipe format this scaffolds, and
[github.com/Qsenja/fau-recipes](https://github.com/Qsenja/fau-recipes) for
where a finished recipe actually goes.

## Renamed from aur-to-fis: not just an AUR tool

The AUR RPC lookup was never the interesting part of this tool — every real
piece of work (checksum verification against actual downloaded bytes,
dependency resolution against fau's own alpm lookup, `recipe_build`
translation) works from plain PKGBUILD text, whether or not that PKGBUILD
happens to live on AUR. `--file <path>` reads a local PKGBUILD directly;
`--url <url>` fetches one from anywhere over HTTPS — a private PKGBUILD, one
from Arch's own official-repo tree, or a draft not yet pushed to AUR at all
now scaffold exactly the same way `<aur-pkgname>` always did. Neither mode
has AUR's RPC metadata (name/description/url/depends/makedepends) to draw
on, so those are extracted from the PKGBUILD's own top-level fields instead
(`pkgname=`/`pkgdesc=`/`url=`/`depends=(...)`/`makedepends=(...)`) — the
same `pkgbuild_scalar`/`pkgbuild_array` heuristic this tool already uses for
everything else, not a second code path.

The auto-translation whitelist (see below) also gained `cp` and `chmod` —
both common in real `-bin` packages' `package()` bodies and no more
dangerous than `install`, which was already allowed.

## Comments are stripped before anything else sees the PKGBUILD

`strip_pkgbuild_comments` runs on the fetched text before field extraction
or the "for reference" copy echoed into the draft — the original author's
comments (whole-line or trailing, e.g. `depends=('foo' 'bar')  # why`)
never make it into a generated `.fis`. A `#` inside a quoted string
(`url="https://example.com/page#section"`) is left alone —
`strip_trailing_comment` tracks single/double-quote state char-by-char and
only treats an unquoted `#` as a comment starter. A heredoc body (`install
-Dm755 /dev/stdin "$app_dir/..." <<'EOF' ... EOF`) is passed through
completely untouched regardless of what's inside it: a `#`-starting line in
there is literal DATA (often a real shebang), never a shell comment, and
stripping it would corrupt whatever gets installed. Verified this doesn't
regress anything: re-ran against `mangowm`, `dwm`, and `downgrade` and
confirmed `PKG_SRC_URL`/`PKG_SRC_SHA256` still come out byte-identical to
before this change.

## Why this can only ever be a draft generator

A PKGBUILD is arbitrary, unvetted, AUR-submitted bash — Arch's own docs
disclaim AUR as exactly that, and malicious PKGBUILDs have been caught in
the wild before (a `pkgver()` function or `install=` scriptlet running
arbitrary code well outside the parts a human would think to review). A
real "AUR to fau" converter that sources and executes a PKGBUILD to see
what it does would inherit all of that risk directly onto whoever runs
`fau build`. This tool never does that: it fetches AUR's RPC API (JSON) and
the raw `PKGBUILD` file (plain text, via cgit's own read-only raw-file
endpoint) over HTTPS, then only greps/pattern-matches known field shapes
out of the text — `pkgbuild_scalar`/`pkgbuild_array`/`pkgbuild_func_body`
are a heuristic over real-world PKGBUILD convention (top-level, column-1
`key=value`/`key=(...)`), not a bash parser, and deliberately don't try to
be one. Good enough for a draft a human reviews line-by-line before it's
ever used; wrong for a deliberately obfuscated PKGBUILD, which is an
accepted gap given the draft is never trusted or run automatically.

`recipe_build()` in the output is a stub that `die()`s if actually built
*unless* the whole of `prepare()`/`build()`/`package()` is composed of a
narrow whitelist of safe, unambiguous file operations — see "A real
`recipe_build()`, not just a stub" below. Translating an arbitrary
PKGBUILD's `build()`/`package()` into a working `recipe_build()` in general
needs understanding the actual build system, `fau`'s own `$app_dir`-direct-
install convention (no `fakeroot`, no `$pkgdir`), and whether the package
needs a scenefx-style manual sub-build for an AUR-only dependency — none of
that is safe to guess generically, which is why the whitelist is narrow and
bails (falls back to the stub) rather than guessing the instant it hits
anything outside it. The original `build()`/`package()` bodies are always
carried into the draft as comments too, whether or not translation
succeeded, so a human has the reference material right there either way.

## A real `recipe_build()`, not just a stub

The overwhelming majority of realistic future FloraOS package candidates
are `-bin`-style AUR packages (Electron apps, static Go/Rust/Bun binaries)
whose `package()` is just a handful of `install`/`mkdir`/`rm`/`find -delete`
lines moving already-built files into place — no real build system, nothing
that needs judgment. `try_translate_body` recognizes exactly that shape:
`install`, `mkdir -p`, `ln -s`, `rm -f`/`-rf`, `find ... -delete`, `sed -i`
on a single path, and a quoted-heredoc `install -Dm... /dev/stdin "<dest>"
<<'EOF'` (safe because a quoted heredoc delimiter is byte-for-byte literal
by construction — no variable expansion happens inside one at all, so its
body is DATA, never re-interpreted as a command). Every line still has to
have every `$pkgdir`/`$srcdir`/`$pkgname`/`${var%suffix}`/... reference
already resolved to a literal value (or to `$app_dir`/`$src`) before it's
accepted, and reference `$app_dir` somewhere in its own arguments for the
four destructive verbs (`rm`/`find -delete`, plus implicitly `install`'s own
destination) — this is still never a bash parser, just recognizing a fixed
command shape, exactly the same category of operation
`pkgbuild_scalar`/`pkgbuild_array` already do for top-level fields, just
now also applied to a constrained subset of function-body lines. The
instant ANY line in a function doesn't match, translation aborts for that
WHOLE function and falls back to the stub — a partial, silently-incomplete
`recipe_build()` would be worse than an honest one that still needs a human.

A bare `cd` is deliberately never in the whitelist, even though it's
extremely common (`dwm`/`mangowm`'s own real PKGBUILDs both `cd
"$srcdir/$pkgname-$pkgver"` before doing anything else): fau's own
`build_extract_source` already strips exactly one leading path component,
so `$src` is ALREADY what the PKGBUILD calls `$srcdir/$pkgname-$pkgver` —
but telling that apart from a genuine, still-real subdirectory (a monorepo
tarball with multiple subprojects) would need actually inspecting the
tarball's real layout per-subpath, not just pattern-matching text. Safer to
bail than guess; the generated `recipe_build()` instead opens with an
explicit `cd "$src"` up front, matching makepkg's own default cwd for every
function when nothing explicitly `cd`s elsewhere. None of the three real
`-bin` packages this was built and tested against (`opencode-bin`,
`opencode-desktop-bin`, `vesktop-bin`) `cd` anywhere in `package()` at all.

**Two real gaps found and fixed by actually running this against real
AUR packages, not by inspection:**

- **Arch-keyed `source_x86_64=`/`sha256sums_x86_64=` arrays were never read
  at all** — only the generic `source=`/`sha256sums=`. Real makepkg ADDS
  these to the generic arrays for the matching arch, not a replacement, but
  a `-bin` package overwhelmingly puts its actual payload URL there, not in
  the generic array. Three real, distinct failure modes this caused, each
  confirmed against a live AUR package: `opencode-bin` has NO generic
  `source=` at all (only `source_x86_64=`) — `sources` came back empty and
  the script later crashed outright with `picked_idx: unbound variable`
  trying to reference a variable only ever declared inside the
  now-untaken non-empty branch. `opencode-desktop-bin` has BOTH — the
  generic entry is a bare `LICENSE` download, the arch-specific one the
  real `.deb` — and the old single-array scan picked the `LICENSE` as if it
  were the package payload, checksumming the wrong file entirely.
  `vesktop-bin` has BOTH too (a local `.sh` launcher template genericly,
  the real per-arch `.rpm` download) — the old scan found no `http(s)` entry
  at all in the generic-only array and gave up completely, `PKG_SRC_URL`/
  `PKG_SRC_SHA256` coming back as bare `TODO`s even though the real download
  URL was sitting right there in `source_x86_64=`. Fixed by concatenating
  generic + arch-specific arrays (`FLORAOS_ARCH="x86_64"`, the only arch
  this project ever targets) and preferring an arch-specific `http(s)` entry
  over a generic one when both exist, falling back to the original
  full-scan behavior only when no arch-specific payload exists (dwm/
  mangowm, neither of which has an arch-specific array at all, are
  unaffected — confirmed by re-running the tool against both and comparing
  to their real hand-authored recipes' own pinned `PKG_SRC_SHA256`, which
  still match exactly).
- **A flat (no wrapping directory) release tarball silently produces an
  empty `$src`.** `build_extract_source` (`../fau/lib/build.sh`) always
  runs `tar -xf ... --strip-components=1`, correct for a GitHub-archive-
  style tarball (one shared top-level directory) but not for a release
  asset that's just the built binary itself with no wrapper at all —
  confirmed directly against `opencode-bin`'s own real release asset:
  `--strip-components=1` on that tarball's single top-level file exits 0
  having extracted nothing, no warning printed anywhere. Detected here by
  actually downloading the resolved source (already being done to compute
  its real checksum anyway) and listing its members: any REGULAR file/
  symlink entry with no `/` in its name is the exact "this whole entry gets
  eaten by strip-components=1" signal. Directory entries are explicitly
  excluded from that check, not just slash-free names in general — an
  archive's own wrapping directory is usually listed as one bare entry
  too (e.g. plain `dwm-6.8`, no trailing slash in at least one real tar's
  own listing format), and an earlier version of this check flagged dwm's
  own correctly-wrapped, already-working tarball as flat purely because of
  that entry — a false positive caught by deliberately re-running the
  check against dwm as a regression test, not assumed safe. When flagged,
  the generated `recipe_build()` re-fetches (a cache hit by then) and
  re-extracts the tarball itself without any `--strip-components`, the
  same fix `fau-recipes/recipes/opencode.fis`'s own hand-written recipe
  uses for this identical bug.

`.deb`/`.rpm` sources get their own advisory comment in the draft either
way (whether or not `recipe_build()` fully translates): `.deb` now has real
support in `build_extract_source` (see `../fau/fau.md`'s own section on
this), so `$src` is already the unpacked payload tree, no `bsdtar`/`ar`
needed in a hand-written `recipe_build()` either; `.rpm` has no such
support yet (cpio + its own lead/header format, not a tar archive) and is
flagged as a still-open TODO.

## Verified end-to-end, not just "looks right"

`opencode-bin`'s real `package()` is a single `install -Dm755 ./opencode
"$pkgdir/usr/bin/opencode"` — translation succeeds, and the generated
`recipe_build()` was actually run (a real `build_fetch_source` stub
downloading the real release asset, no other mocking) end to end: it
extracted the real `opencode` binary and installed it at
`$app_dir/usr/bin/opencode`, and the installed binary ran and reported the
correct version. `opencode-desktop-bin`'s `package()` correctly does NOT
auto-translate (it branches on `${CARCH}` and uses `local`, neither of
which is in the whitelist) and `vesktop-bin`'s `prepare()` correctly does
not either (it calls a custom function, `_get_electron_version`, unique to
that PKGBUILD) — both fall back to the stub exactly as designed, not a
regression, since guessing either of those safely isn't possible from text
alone.

## Two things it verifies for real, not from the PKGBUILD's own say-so

- **`PKG_SRC_SHA256` is computed by actually downloading the resolved
  source URL and hashing the real bytes** — never copied from the
  PKGBUILD's own `sha256sums`/`md5sums` (which this tool doesn't even
  trust as an integrity check for itself, only surfaces as a comment for
  the human to cross-reference). A PKGBUILD's declared checksum only
  proves the file matched *whoever last updated the PKGBUILD*'s download,
  not that this tool's own resolved URL points at the same bytes — pinning
  from a checksum you computed yourself, of the URL you're actually about
  to ship, is the only way `PKG_SRC_SHA256` means what `build_fetch_source`
  (`../fau/lib/build.sh`) expects it to mean.
- **Every `depends`/`makedepends` name is checked against fau's own real
  alpm resolution** (`alpm_find_provider`, sourced directly from
  `../fau/lib/alpm.sh`) — not assumed resolvable just because AUR listed
  it. `FAU_ROOT` is overridden to a per-user cache dir before sourcing
  `lib/common.sh` specifically for this: that library's own default
  (`FAU_ROOT=/`) assumes a real FloraOS install and needs root to write
  `/var/cache/fau`, the wrong default for a maintainer running this by
  hand on their own machine. A name that fails to resolve is reported
  separately and left out of `PKG_DEPENDS`/`PKG_BUILD_DEPS` entirely,
  rather than silently included and left to break `fau build` later.

## Verified against a known-good answer, not just plausible-looking output

Run against `mangowm` — a package this project already has a real,
hand-authored `recipes/mangowm.fis` for — the generated draft's
`PKG_SRC_URL`/`PKG_SRC_SHA256` matched the hand-authored recipe's own
pinned values exactly, `libwlroots-0.19.so` resolved correctly through
alpm's soname/PROVIDES lookup, and `scenefx0.4` (mango's one AUR-only
dependency, hand-built inside `recipe_build` in the real recipe) was
correctly flagged as unresolved rather than silently dropped or guessed
at. Also run against `downgrade`, an AUR package whose `source=` uses
`${pkgver//_/-}` (bash parameter-expansion substitution, not a plain
`$var` reference) — confirmed the tool detects it can't safely resolve
that and leaves `PKG_SRC_URL`/`PKG_SRC_SHA256` as explicit `TODO`s instead
of emitting a silently-wrong URL.
