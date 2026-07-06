#!/usr/bin/env bash
# Builds the FloraOS base rootfs from source into $WORK_DIR/rootfs.
# Every package is compiled from its pinned upstream source (config/versions.conf),
# staged, packaged as a .fau.tar.zst, and installed via fau — nothing here
# touches the real host system; everything lives under work/ (gitignored).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

FLORAOS_CONF="$FLORA_ROOT/config/floraos.conf"
[ -f "$FLORAOS_CONF" ] || die "missing config file: $FLORAOS_CONF"
# shellcheck source=/dev/null
source "$FLORAOS_CONF"

MANDATORY_ORDER=(
	linux-lts
	glibc
	sysvinit
	openrc
	ncurses
	bash
	coreutils
	util-linux
	e2fsprogs
	iproute2
	libmd
	dhcpcd
	# The rest of these exist for one reason: fau itself needs them at
	# runtime (grep/sed/gawk/find+xargs/tar/zstd/rsync — see each recipe's
	# own comment for exactly which fau code path uses it). They only
	# "worked" during the build because the build host has them; without
	# shipping them, fau is broken inside the actual booted OS.
	attr
	acl
	grep
	sed
	gawk
	findutils
	tar
	zstd
	rsync
	# sysctl/hostname/loadkeys+dumpkeys: OpenRC's sysinit services for these
	# fail non-fatally without them (see docs/MANIFEST.md for each package's
	# one-line reason).
	procps-ng
	hostname
	kbd
	# libxcrypt: glibc itself dropped crypt() -- floralogin (compiled below,
	# not a fau package itself) needs it to verify /etc/shadow hashes. See
	# scripts/recipes/libxcrypt.sh and tools/floralogin.
	libxcrypt
	# mbedtls/curl: fau's pacman-backed fallback (tools/fau/fau) needs an
	# HTTP client to fetch anything once running inside a booted FloraOS
	# system (no pacman there to shell out to) -- found by actually running
	# `fau install` after boot: it failed immediately with "curl: command
	# not found". mbedtls is curl's TLS backend (mirrors are HTTPS-only);
	# order matters here, mbedtls must build first (curl.sh links against
	# its staged files directly, see scripts/recipes/curl.sh).
	mbedtls
	curl
)
BUILD_ORDER=("${MANDATORY_ORDER[@]}" ${EXTRA_PACKAGES:-})

pinned_kernel=$(version_field linux-lts 1)
[ "${KERNEL_VERSION:-$pinned_kernel}" = "$pinned_kernel" ] || die \
	"floraos.conf requests kernel $KERNEL_VERSION but config/versions.conf pins linux-lts at $pinned_kernel -- update versions.conf (URL + sha256) to change kernel version"

# autoreconf: procps-ng only publishes a raw source-archive tarball (no
# generated configure), unlike every other package here -- see its recipe.
for cmd in curl tar zstd make gcc sha256sum rsync fakeroot autoreconf; do require_cmd "$cmd"; done

already_built() {
	# already_built <name> -- true if the repo already has this exact
	# pinned version packaged. Lets a retry after a downstream failure skip
	# expensive earlier steps (kernel, glibc) instead of rebuilding them --
	# extract_source always wipes and re-extracts, so without this check
	# every retry redoes the whole pipeline from package #1.
	local name=$1 version; version=$(version_field "$name" 1)
	local repo="$REPO_DIR/repo.json"
	[ -f "$repo" ] || return 1
	grep -q "\"${name}\":{\"version\":\"${version}\"" "$repo"
}

build_package() {
	local name=$1
	if already_built "$name"; then
		log "=== $name (already built, skipping -- rm work/repo to force a rebuild) ==="
		return
	fi
	log "=== $name ==="
	# shellcheck source=/dev/null
	source "$SELF_DIR/recipes/$name.sh"

	local tarball src
	tarball=$(fetch_source "$name")
	src=$(extract_source "$name" "$tarball")

	local version files
	version=$(version_field "$name" 1)
	# Must be distinct from $STAGE_DIR/$name/files -- package_stage rm -rf's
	# and recreates that path, which would delete this out from under itself.
	files="$BUILD_DIR/$name-install"
	rm -rf "$files"
	mkdir -p "$files"

	recipe_build "$src" "$files"
	package_stage "$name" "$version" "$PKG_DESCRIPTION" "$PKG_DEPENDS" "$files"
}

main() {
	mkdir -p "$SOURCES_DIR" "$BUILD_DIR" "$STAGE_DIR" "$REPO_DIR"

	for name in "${BUILD_ORDER[@]}"; do
		build_package "$name"
	done

	log "=== assembling rootfs ==="
	rm -rf "$ROOTFS_DIR"
	mkdir -p "$ROOTFS_DIR/usr/bin" "$ROOTFS_DIR/usr/lib"
	# Pre-seed the merged-/usr symlinks *before* installing any package, so
	# every package's own bin/sbin/lib/lib64 output merges straight into
	# usr/bin and usr/lib instead of creating separate real directories.
	ln -s usr/bin "$ROOTFS_DIR/bin"
	ln -s usr/bin "$ROOTFS_DIR/sbin"
	ln -s usr/lib "$ROOTFS_DIR/lib"
	ln -s usr/lib "$ROOTFS_DIR/lib64"
	# autotools' default sbindir is a separate ${prefix}/sbin; merge it into
	# usr/bin too so every package lands in one place regardless of flags.
	ln -s bin "$ROOTFS_DIR/usr/sbin"

	# fau itself: a portable bash script, nothing to compile -- but it must
	# actually ship in the OS, not just be a build-host tool, since it's
	# FloraOS's own package manager and the whole point is for the running
	# system to use it (fastfetch's Packages line depends on this too).
	cp "$FAU_BIN" "$ROOTFS_DIR/usr/bin/fau"
	chmod 755 "$ROOTFS_DIR/usr/bin/fau"

	FAU_REPO_DIR="$REPO_DIR" FAU_ROOT="$ROOTFS_DIR" "$FAU_BIN" install "${BUILD_ORDER[@]}"

	log "=== shipping a pacman mirrorlist/repo-list for fau's own use ==="
	# fau's pacman-backed fallback (tools/fau/fau) never shells out to the
	# `pacman` binary -- it reads the mirrorlist and sync-db formats
	# directly -- but it still needs to know which mirror and which repos
	# to ask, and /etc/pacman.d/mirrorlist + /etc/pacman.conf don't exist
	# inside a booted FloraOS system. Shipping a copy here is what makes
	# `fau install <pkg>` work after boot, not just during this build.
	if [ -f /etc/pacman.d/mirrorlist ] && [ -f /etc/pacman.conf ]; then
		mkdir -p "$ROOTFS_DIR/etc/fau"
		cp /etc/pacman.d/mirrorlist "$ROOTFS_DIR/etc/fau/pacman-mirrorlist"
		grep -oE '^\[[a-zA-Z0-9_.-]+\]' /etc/pacman.conf | tr -d '[]' | grep -vx options \
			> "$ROOTFS_DIR/etc/fau/pacman-repos"
	else
		log "no /etc/pacman.d/mirrorlist or /etc/pacman.conf on this build host -- fau's pacman fallback won't work after boot"
	fi

	log "=== installing the CA certificate bundle (curl needs it for HTTPS) ==="
	# Not a compiled package -- see config/versions.conf's comment. Reuses
	# fetch_source (format-agnostic: download + sha256-verify + return the
	# path) directly rather than going through the normal recipe pipeline,
	# since extract_source assumes every pinned download is a tarball and
	# this is a single PEM file.
	local ca_bundle; ca_bundle=$(fetch_source ca-certificates)
	mkdir -p "$ROOTFS_DIR/etc/ssl/certs"
	cp "$ca_bundle" "$ROOTFS_DIR/etc/ssl/certs/ca-certificates.crt"

	log "=== compiling floralogin (FloraOS's own PAM-free login) ==="
	# Not a fau package: it's FloraOS-authored source, not a fetched upstream
	# tarball (same reasoning as fau itself not going through the recipe
	# pipeline). Compiled here, after the install above, specifically
	# against *this rootfs's own* just-installed crypt.h/libcrypt.so.1 (via
	# -I/-L pointed at $ROOTFS_DIR) rather than whatever libcrypt the build
	# host happens to have -- linking against the host's copy would bake in
	# a mismatched SONAME the shipped image doesn't actually provide (the
	# same class of bug found and fixed in fau's pacman fallback, see
	# ARCHITECTURE.md).
	gcc -Wall -Wextra -O2 \
		-I"$ROOTFS_DIR/usr/include" -L"$ROOTFS_DIR/usr/lib" \
		-o "$ROOTFS_DIR/usr/bin/floralogin" \
		"$FLORA_ROOT/tools/floralogin/floralogin.c" -lcrypt
	chmod 755 "$ROOTFS_DIR/usr/bin/floralogin"

	log "=== branding: fastfetch (via fau's pacman fallback, not the minimal base) ==="
	# kitty was deliberately left out here: its dependency closure (Python3 +
	# Mesa + X11/Wayland) is ~773MB, and none of it does anything without a
	# display server FloraOS doesn't have yet (see ARCHITECTURE.md). Install
	# it yourself later with: fau app-install kitty
	if command -v pacman >/dev/null 2>&1; then
		# libgcc (libgcc_s.so.1, C++ exception-handling runtime) isn't a
		# declared dependency of fastfetch -- Arch/Artix assume it's always
		# present as a base-system package, so pacman's own dependency
		# resolution never lists it explicitly for anything that needs it.
		FAU_REPO_DIR="$REPO_DIR" FAU_ROOT="$ROOTFS_DIR" "$FAU_BIN" install libgcc fastfetch
	else
		log "pacman not available on this build host -- skipping fastfetch"
	fi

	log "=== applying /etc skeleton ==="
	"$SELF_DIR/apply-skeleton.sh" "$ROOTFS_DIR" "${HOSTNAME:-floraos}"

	log "=== rebuilding ld.so.cache ==="
	"$ROOTFS_DIR/usr/sbin/ldconfig" -r "$ROOTFS_DIR"

	log "rootfs ready at $ROOTFS_DIR"
}

main "$@"
