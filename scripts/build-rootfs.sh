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
)
BUILD_ORDER=("${MANDATORY_ORDER[@]}" ${EXTRA_PACKAGES:-})

pinned_kernel=$(version_field linux-lts 1)
[ "${KERNEL_VERSION:-$pinned_kernel}" = "$pinned_kernel" ] || die \
	"floraos.conf requests kernel $KERNEL_VERSION but config/versions.conf pins linux-lts at $pinned_kernel -- update versions.conf (URL + sha256) to change kernel version"

for cmd in curl tar zstd make gcc sha256sum rsync fakeroot; do require_cmd "$cmd"; done

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
