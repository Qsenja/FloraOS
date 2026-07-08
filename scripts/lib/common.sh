# Shared helpers for FloraOS build scripts. Sourced, not executed directly.

FLORA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${WORK_DIR:-$FLORA_ROOT/work}"
SOURCES_DIR="$WORK_DIR/sources"
BUILD_DIR="$WORK_DIR/build"
STAGE_DIR="$WORK_DIR/stage"
REPO_DIR="$WORK_DIR/repo"
ROOTFS_DIR="$WORK_DIR/rootfs"
VERSIONS_CONF="$FLORA_ROOT/config/versions.conf"
FAU_TOOLS_DIR="$FLORA_ROOT/tools/fau"
FAU_BIN="$FAU_TOOLS_DIR/fau"
# fau-recipes/ is its own separate git repo (github.com/Qsenja/fau-recipes),
# not part of tools/fau/ itself, and deliberately NOT staged into the ISO by
# this build -- fau fetches it over the network at runtime (FAU_RECIPES_REPO,
# fau-build's own recipes_sync) so a new/updated recipe reaches every
# machine the moment it's pushed, with no ISO rebuild involved. See
# tools/fau/fau.md.
FLORAGRUB_CFG_BIN="$FLORA_ROOT/tools/floragrub-cfg/floragrub-cfg"
# Defined unconditionally: build_package() skips sourcing a cached package's
# recipe, so referencing this lazily would crash under `set -u`.
LINUX_HEADERS_DIR="$BUILD_DIR/linux-headers/include"

log()  { echo "[floraos] $*" >&2; }
die()  { echo "[floraos] error: $*" >&2; exit 1; }

# Prints "version|url|sha256" from config/versions.conf, or dies.
version_entry() {
	local name=$1
	local line
	line=$(grep -E "^${name}\|" "$VERSIONS_CONF" || true)
	[ -n "$line" ] || die "no entry for '$name' in $VERSIONS_CONF"
	echo "$line" | cut -d'|' -f2-
}

version_field() { version_entry "$1" | cut -d'|' -f"$2"; }

# Downloads <name> if missing, verifies its checksum, prints the local path.
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

# Extracts <tarball> to $BUILD_DIR/<name>, prints that directory's path.
extract_source() {
	local name=$1 tarball=$2
	local dest="$BUILD_DIR/$name"
	rm -rf "$dest"
	mkdir -p "$dest"
	tar -xf "$tarball" -C "$dest" --strip-components=1
	echo "$dest"
}

# package_stage <name> <version> <description> <depends> <stage-files-dir> [bin]
# Builds a .fau.tar.zst from a populated $STAGE_DIR/<name>/files tree and
# adds it to the local fau repo. <bin> is fau-install's optional
# comma-separated relative-path list for the isolated-app path (see
# docs/ARCHITECTURE.md); no current recipe sets it.
package_stage() {
	local name=$1 version=$2 description=$3 depends=$4 files_dir=$5 bin=${6:-}
	local pkg_dir="$STAGE_DIR/$name"
	rm -rf "$pkg_dir"
	mkdir -p "$pkg_dir"
	cp -a "$files_dir" "$pkg_dir/files"
	cat > "$pkg_dir/pkginfo" <<-EOF
	name=$name
	version=$version
	description=$description
	depends=$depends
	bin=$bin
	EOF

	# Built outside $REPO_DIR: repo-add copies its argument INTO $REPO_DIR.
	local archive="$STAGE_DIR/${name}-${version}.fau.tar.zst"
	(cd "$pkg_dir" && tar -I zstd -cf "$archive" pkginfo files)
	FAU_REPO_DIR="$REPO_DIR" "$FAU_BIN" repo-add "$archive"
	rm -f "$archive"
	log "packaged $name $version"
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1 (install it on the build host first)"
}

# QEMU serial-console automation used by test-iso.sh/test-install*.sh --
# see docs/ARCHITECTURE.md's "Test harness" section for the full reasoning
# (fifo open-for-read-write, socat addressing, etc). One session per
# qemu_boot_serial/.../qemu_quit bracket; only one open at a time per shell.

# qemu_boot_serial <tag> <qemu-args...> -- sets QEMU_PID, QEMU_LOG, QEMU_FD
# (write to this fd to type at the guest), and QEMU_MON_SOCK.
qemu_boot_serial() {
	local tag=$1; shift
	QEMU_SOCK="$WORK_DIR/qemu-$tag-serial.sock"
	QEMU_FIFO="$WORK_DIR/qemu-$tag-serial-input.fifo"
	QEMU_LOG="$WORK_DIR/qemu-$tag-boot.log"
	QEMU_MON_SOCK="$WORK_DIR/qemu-$tag-monitor.sock"
	rm -f "$QEMU_SOCK" "$QEMU_FIFO" "$QEMU_LOG" "$QEMU_MON_SOCK"
	mkfifo "$QEMU_FIFO"

	qemu-system-x86_64 "$@" \
		-serial "unix:$QEMU_SOCK,server,nowait" \
		-monitor "unix:$QEMU_MON_SOCK,server,nowait" \
		>/dev/null 2>&1 &
	QEMU_PID=$!

	for _ in $(seq 1 100); do
		[ -S "$QEMU_SOCK" ] && break
		sleep 0.1
	done
	[ -S "$QEMU_SOCK" ] || die "qemu (tag=$tag) never created its serial socket at $QEMU_SOCK"

	# <> not >: a write-only open() here would deadlock waiting for socat's reader.
	exec {QEMU_FD}<>"$QEMU_FIFO"
	# socat's own address must be "-" (stdio), NOT the fifo path -- see ARCHITECTURE.md.
	socat -T"${QEMU_SERIAL_TIMEOUT:-900}" - "UNIX-CONNECT:$QEMU_SOCK" < "$QEMU_FIFO" > "$QEMU_LOG" 2>&1 &
	QEMU_SOCAT_PID=$!
}

# qemu_wait_for <marker> [timeout-secs] -- polls $QEMU_LOG for a literal substring.
qemu_wait_for() {
	local marker=$1 timeout=${2:-60}
	local deadline=$(( $(date +%s) + timeout ))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		grep -qF "$marker" "$QEMU_LOG" 2>/dev/null && return 0
		sleep 0.3
	done
	return 1
}

# qemu_send <raw-bytes> -- callers pass \r themselves (no implicit newline).
qemu_send() { printf '%s' "$1" >&"$QEMU_FD"; }

# qemu_quit -- uses the monitor's `quit` rather than a signal, so a reused
# disk image's write-back cache flushes cleanly first (see ARCHITECTURE.md).
qemu_quit() {
	for _ in $(seq 1 50); do
		[ -S "$QEMU_MON_SOCK" ] && break
		sleep 0.1
	done
	if [ -S "$QEMU_MON_SOCK" ]; then
		printf 'quit\n' | socat - "UNIX-CONNECT:$QEMU_MON_SOCK" >/dev/null 2>&1 || true
	fi
	wait "$QEMU_PID" 2>/dev/null || true
	exec {QEMU_FD}>&- 2>/dev/null || true
	kill "$QEMU_SOCAT_PID" 2>/dev/null || true
	rm -f "$QEMU_SOCK" "$QEMU_FIFO" "$QEMU_MON_SOCK"
}
