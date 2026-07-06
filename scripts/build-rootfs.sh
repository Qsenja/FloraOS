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
	bash
	coreutils
	util-linux
	e2fsprogs
	iproute2
	dhcpcd
)
BUILD_ORDER=("${MANDATORY_ORDER[@]}" ${EXTRA_PACKAGES:-})

pinned_kernel=$(version_field linux-lts 1)
[ "${KERNEL_VERSION:-$pinned_kernel}" = "$pinned_kernel" ] || die \
	"floraos.conf requests kernel $KERNEL_VERSION but config/versions.conf pins linux-lts at $pinned_kernel -- update versions.conf (URL + sha256) to change kernel version"

for cmd in curl tar zstd make gcc sha256sum; do require_cmd "$cmd"; done

build_package() {
	local name=$1
	log "=== $name ==="
	# shellcheck source=/dev/null
	source "$SELF_DIR/recipes/$name.sh"

	local tarball src
	tarball=$(fetch_source "$name")
	src=$(extract_source "$name" "$tarball")

	local version files
	version=$(version_field "$name" 1)
	files="$STAGE_DIR/$name/files"
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
	FAU_REPO_DIR="$REPO_DIR" FAU_ROOT="$ROOTFS_DIR" "$FAU_BIN" install "${BUILD_ORDER[@]}"

	log "=== applying /etc skeleton ==="
	"$SELF_DIR/apply-skeleton.sh" "$ROOTFS_DIR" "${HOSTNAME:-floraos}"

	log "=== rebuilding ld.so.cache ==="
	"$ROOTFS_DIR/usr/sbin/ldconfig" -r "$ROOTFS_DIR"

	log "rootfs ready at $ROOTFS_DIR"
}

main "$@"
