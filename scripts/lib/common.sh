# Shared helpers for FloraOS build scripts. Sourced, not executed directly.

FLORA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${WORK_DIR:-$FLORA_ROOT/work}"
SOURCES_DIR="$WORK_DIR/sources"
BUILD_DIR="$WORK_DIR/build"
STAGE_DIR="$WORK_DIR/stage"
REPO_DIR="$WORK_DIR/repo"
ROOTFS_DIR="$WORK_DIR/rootfs"
VERSIONS_CONF="$FLORA_ROOT/config/versions.conf"
FAU_BIN="$FLORA_ROOT/tools/fau/fau"
FLORAGRUB_CFG_BIN="$FLORA_ROOT/tools/floragrub-cfg/floragrub-cfg"
# glibc needs this at build time (see scripts/recipes/glibc.sh). Defined here
# rather than as a side effect of sourcing linux-lts.sh: build_package()
# skips sourcing a package's recipe entirely once it's already cached, so if
# only glibc needs a rebuild (e.g. a version bump) while linux-lts stays
# cached, glibc's recipe would otherwise reference an unset variable ("set
# -u" makes that a hard crash) even though the headers are still on disk
# from the last time linux-lts actually built.
LINUX_HEADERS_DIR="$BUILD_DIR/linux-headers/include"

log()  { echo "[floraos] $*" >&2; }
die()  { echo "[floraos] error: $*" >&2; exit 1; }

# version_entry <name> -> prints "version|url|sha256" or dies
version_entry() {
	local name=$1
	local line
	line=$(grep -E "^${name}\|" "$VERSIONS_CONF" || true)
	[ -n "$line" ] || die "no entry for '$name' in $VERSIONS_CONF"
	echo "$line" | cut -d'|' -f2-
}

version_field() { version_entry "$1" | cut -d'|' -f"$2"; }

# fetch_source <name> -> downloads (if missing) and verifies checksum,
# prints the path to the verified tarball
fetch_source() {
	local name=$1
	local version url sha256 fname path
	version=$(version_field "$name" 1)
	url=$(version_field "$name" 2)
	sha256=$(version_field "$name" 3)
	fname=$(basename "$url")
	path="$SOURCES_DIR/$fname"

	mkdir -p "$SOURCES_DIR"
	if [ ! -f "$path" ]; then
		log "fetching $name $version"
		curl -sL --fail -o "$path.part" "$url"
		mv "$path.part" "$path"
	fi

	local actual
	actual=$(sha256sum "$path" | cut -d' ' -f1)
	[ "$actual" = "$sha256" ] || die "checksum mismatch for $fname: expected $sha256, got $actual"

	echo "$path"
}

# extract_source <name> <tarball-path> -> extracts to $BUILD_DIR/<name>,
# returns the path to the extracted top-level directory
extract_source() {
	local name=$1 tarball=$2
	local dest="$BUILD_DIR/$name"
	rm -rf "$dest"
	mkdir -p "$dest"
	tar -xf "$tarball" -C "$dest" --strip-components=1
	echo "$dest"
}

# package_stage <name> <version> <description> <depends> <stage-files-dir>
# -> builds a .fau.tar.zst from a populated $STAGE_DIR/<name>/files tree and
# adds it to the local fau repo
package_stage() {
	local name=$1 version=$2 description=$3 depends=$4 files_dir=$5
	local pkg_dir="$STAGE_DIR/$name"
	rm -rf "$pkg_dir"
	mkdir -p "$pkg_dir"
	cp -a "$files_dir" "$pkg_dir/files"
	cat > "$pkg_dir/pkginfo" <<-EOF
	name=$name
	version=$version
	description=$description
	depends=$depends
	EOF

	# Built outside $REPO_DIR -- repo-add copies its argument *into* $REPO_DIR,
	# so building the archive there directly makes that copy a no-op self-copy.
	local archive="$STAGE_DIR/${name}-${version}.fau.tar.zst"
	(cd "$pkg_dir" && tar -I zstd -cf "$archive" pkginfo files)
	FAU_REPO_DIR="$REPO_DIR" "$FAU_BIN" repo-add "$archive"
	rm -f "$archive"
	log "packaged $name $version"
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1 (install it on the build host first)"
}
