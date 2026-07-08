# aur-to-fis — implementation notes

Design rationale mined from `aur-to-fis`'s own comments. Maintainer-side
tool only — never shipped in the ISO, never run on a live FloraOS system
(unlike everything under `tools/fau/`). See
[../fau/fau.md](../fau/fau.md) for the recipe format this scaffolds, and
[github.com/Qsenja/fau-recipes](https://github.com/Qsenja/fau-recipes) for
where a finished recipe actually goes.

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

`recipe_build()` in the output is always a stub that `die()`s if actually
built — translating a PKGBUILD's `build()`/`package()` into a working
`recipe_build()` needs understanding the actual build system, `fau`'s own
`$app_dir`-direct-install convention (no `fakeroot`, no `$pkgdir`), and
whether the package needs a scenefx-style manual sub-build for an AUR-only
dependency — none of that is safe to guess generically. The original
`build()`/`package()` bodies are carried into the draft as comments so a
human has the reference material right there instead of needing to look
it up separately.

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
