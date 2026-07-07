# mangowm: a dwl fork (wlroots-based tiling Wayland compositor, "dwm but
# wayland" -- upstream's own binary is named "mango", AUR package name is
# "mangowm"), closing the actual `fau install mangowm` request this recipe
# exists to satisfy. AUR-only -- confirmed directly against
# https://aur.archlinux.org/packages/mangowm, no official Arch/Artix repo
# carries it -- so fau's alpm fallback (lib/alpm.sh, official sync-dbs
# only, no AUR support by design) can never resolve it no matter the exact
# name. This is a `fau install`-only package (meant to land in an end
# user's own FAU_APPS_DIR/mangowm/, same as fastfetch/kitty/cowsay, see
# build-rootfs.sh's own fastfetch step), not part of MANDATORY_ORDER --
# add it to config/floraos.conf's EXTRA_PACKAGES only if you want it merged
# straight into the base image instead; the normal path is building it into
# the local repo and letting `fau install mangowm` pick it up from there.
#
# Meson, deliberately, as a one-off exception: this project avoids
# cmake/meson everywhere else it has a choice (mbedtls picked over OpenSSL,
# real seatd skipped for a from-scratch reimplementation specifically
# because "seatd is meson/ninja-only upstream", kmod pinned to its last
# autotools release before upstream itself moved to meson -- see each of
# those recipes/ARCHITECTURE.md). mangowm's upstream ships meson.build only,
# no Makefile, and neither it nor its own hard dependency below offers one --
# unlike every prior case, there's no non-meson alternative to pick instead.
# New build-host requirements this recipe adds: meson, ninja,
# wayland-protocols (none needed by any MANDATORY_ORDER package, so they're
# checked here rather than added to build-rootfs.sh's own preflight loop).
#
# scenefx (wlrfx/scenefx, the wlroots scene-API effects renderer mango's
# own meson.build hard-requires -- no build option disables it): also
# AUR-only, and fetched/built right here inside this recipe_build rather
# than as its own top-level fau package. Reason: fau-install's own
# dependency handling (app_install_one, tools/fau/fau-install) installs
# every `depends=` entry into its OWN separate FAU_APPS_DIR/<name>/
# directory -- fine for fau-bootstrap's MANDATORY_ORDER packages, which all
# merge into one shared FAU_ROOT, but fatal for an isolated `fau install`
# app: a standalone "scenefx" package would sit in a directory mango's own
# app_wrapper_write-generated LD_LIBRARY_PATH never looks at, so mango
# would fail at runtime with "libscenefx-0.4.so: cannot open shared object
# file" the moment it needed it -- read directly off app_install_one's
# dependency-install loop, not assumed. Building scenefx privately here and
# copying its .so straight into $files/usr/lib (this function's last step)
# sidesteps that instead of teaching fau-install's isolation model to merge
# dependency directories, a much bigger change for one library nothing else
# in this project's recipe set needs. config/versions.conf carries
# scenefx's own pin for provenance even though it's never an independently
# installable fau package.
#
# wlroots0.19: both scenefx and mango hard-pin it exactly (scenefx's
# `dependency('wlroots-0.19', version: '>=0.19.0')`) -- never built by this
# project (see ARCHITECTURE.md's GUI-readiness section: `fau install <wm>`
# fetches wlroots precompiled via the alpm fallback), so this recipe links
# both against *this build host's own* wlroots0.19 package instead. Real,
# disclosed risk, one layer closer to home than usual: this is only
# ABI-correct for whatever wlroots version alpm's own resolver actually
# fetches onto an end user's system at `fau install mangowm` time, by
# version coincidence -- the same class of risk this project already
# accepts for every alpm-fetched binary, just now affecting this build's
# own output too, not only a fetched one.
#
# xorg-xwayland: mango links wlroots' xwayland support (wlr_xwayland_create,
# confirmed directly in src/mango.c), which execs the real `Xwayland`
# binary at runtime rather than linking it -- doesn't show up in `ldd`, but
# is a genuine runtime dependency for that feature to work, so it's listed
# in PKG_DEPENDS anyway (same "document the non-obvious runtime need"
# reasoning as kbd depending on gzip).
#
# Disclosed, not fixed: mango's own compiled-in system config fallback
# path is the literal string "/etc/mango/config.conf" (meson.build's own
# sysconfdir handling), which an isolated fau-install app has no way to
# redirect -- app_wrapper_write's XDG_CONFIG_HOME covers mango's *user*
# config search correctly, but the system-wide fallback still points at
# the real host's /etc/mango, not this app's own isolated copy at
# $app_dir/etc/mango/config.conf. Same class of isolation-model rough edge
# as perl's own compiled-in @INC (see ARCHITECTURE.md/fau.md's
# app_wrapper_write section) -- not patched here for the same reason:
# fixing it means patching mango's own source, a bigger intervention than
# this recipe's actual job.
#
# PKG_BIN (see lib/common.sh's package_stage and build-rootfs.sh's
# build_package): this is the first recipe in this project actually meant
# for fau-install's isolated app path rather than fau-bootstrap's shared
# FAU_ROOT merge, so it's also the first to need this at all -- every
# --prefix=/usr recipe before this one only ever needed
# fau-bootstrap's shared root, where a system-wide bin -> usr/bin symlink
# already exists; fau-install's own bin= auto-detect only ever looks at a
# bare <app_dir>/bin, which --prefix=/usr never produces.
PKG_DESCRIPTION="dwl-fork Wayland compositor (AUR-only, wlroots-0.19-based) -- fau install-only, see this file's own header"
PKG_DEPENDS="glibc,wlroots0.19,wayland,libxkbcommon,libinput,libdrm,libxcb,xcb-util-wm,pcre2,pixman,cjson,pango,xorg-xwayland"
PKG_BIN="usr/bin/mango,usr/bin/mmsg"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	require_cmd meson
	require_cmd ninja

	local scenefx_tarball scenefx_src
	scenefx_tarball=$(fetch_source scenefx)
	scenefx_src=$(extract_source scenefx "$scenefx_tarball")

	local scenefx_build scenefx_install mango_build
	scenefx_build=$(mktemp -d)
	scenefx_install=$(mktemp -d)
	mango_build="$BUILD_DIR/mangowm-build"
	rm -rf "$mango_build"

	(
		cd "$scenefx_src"
		meson setup --prefix=/usr --buildtype=release "$scenefx_build" "$scenefx_src"
		ninja -C "$scenefx_build" -j"$jobs"
		DESTDIR="$scenefx_install" ninja -C "$scenefx_build" install
	)

	(
		cd "$src"
		PKG_CONFIG_PATH="$scenefx_install/usr/lib/pkgconfig" \
			meson setup --prefix=/usr --sysconfdir=/etc --buildtype=release "$mango_build" "$src"
		ninja -C "$mango_build" -j"$jobs"
		DESTDIR="$files" ninja -C "$mango_build" install
	)
	# Cosmetic, not fixed: `mango -v`'s version banner embeds a git commit
	# hash (meson.build's own `git rev-parse` at configure time) -- since
	# $src lives under this project's own work/build/, itself inside
	# FloraOS's git working tree, `git rev-parse --is-inside-work-tree`
	# succeeds and picks up *FloraOS's own* commit, not mango's (confirmed:
	# ran the built binary, saw this project's own short hash in the
	# output). Harmless -- it's one banner string, not used for anything
	# this project's own tooling reads -- so left alone rather than
	# fighting meson's git-detection for a cosmetic string.

	# Bundle scenefx's own .so straight into mango's package tree -- see
	# this file's header comment for why it isn't a separate fau package.
	# app_wrapper_write's LD_LIBRARY_PATH already covers $app_dir/usr/lib,
	# so nothing else needs to be wired up for mango to find it. mkdir
	# first: mango's own meson install never creates usr/lib itself (it
	# installs no library of its own, only usr/bin/usr/share/etc), so
	# plain `cp` into it fails otherwise -- found by actually running this,
	# not by inspection.
	mkdir -p "$files/usr/lib"
	cp -a "$scenefx_install/usr/lib/libscenefx-0.4.so" "$files/usr/lib/"

	rm -rf "$scenefx_build" "$scenefx_install" "$mango_build"
}
