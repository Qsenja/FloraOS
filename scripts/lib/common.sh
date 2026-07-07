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

# --- QEMU serial-console automation (used by test-iso.sh and
# test-install.sh) --------------------------------------------------------
# A background QEMU instance is driven entirely over a single serial line:
# a Unix-socket chardev (so it can be both written to and read from), fed
# by socat from one end of a long-lived fifo into a growing log file that
# qemu_wait_for greps. One "session" = one qemu_boot_serial/.../qemu_quit
# bracket around exactly one QEMU process. Only one session may be open at
# a time per shell (the globals below are session-wide, not stacked) --
# multi-phase tests call qemu_quit before opening the next one.

# qemu_boot_serial <tag> <qemu-args...> -> starts qemu in the background
# with a unix-socket serial chardev and a unix-socket monitor (so qemu_quit
# can shut it down cleanly later), then bridges the serial socket to a
# growing log file via socat. <tag> namespaces this session's socket/fifo/
# log paths under $WORK_DIR so sequential sessions in one script (e.g.
# "install" then "boot1") don't collide. Sets QEMU_PID, QEMU_LOG, QEMU_FD
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

	# <> (read-write), not plain write-only: opening a fifo write-only
	# blocks until some *other* process has it open for reading, but socat
	# (the intended reader) only starts on the next line -- this is the
	# standard trick to open a fifo without deadlocking against yourself,
	# and it also keeps the fifo open for the whole session (a fifo's read
	# end otherwise sees EOF the instant any single write completes).
	exec {QEMU_FD}<>"$QEMU_FIFO"
	# "-" (stdio), not the fifo path, as socat's own address: giving it the
	# fifo path directly as one of its two endpoints makes socat copy the
	# socket's OUTPUT back into that same fifo too (a fifo is one shared
	# queue, not two independent lanes) -- confirmed by testing this exact
	# construct in isolation (see test-iso.sh's own history). Redirecting
	# stdin from the fifo and stdout to $QEMU_LOG keeps the two directions
	# properly separate.
	socat -T"${QEMU_SERIAL_TIMEOUT:-900}" - "UNIX-CONNECT:$QEMU_SOCK" < "$QEMU_FIFO" > "$QEMU_LOG" 2>&1 &
	QEMU_SOCAT_PID=$!
}

# qemu_wait_for <marker> [timeout-secs] -> polls $QEMU_LOG for a literal
# substring. Whatever is on the other end of the serial line (agetty, a
# shell, florainstall's own log_msg output) can flush a backlog before it's
# actually at the point this test cares about, so this waits for the
# marker to actually appear instead of guessing at timing with a sleep.
qemu_wait_for() {
	local marker=$1 timeout=${2:-60}
	local deadline=$(( $(date +%s) + timeout ))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		grep -qF "$marker" "$QEMU_LOG" 2>/dev/null && return 0
		sleep 0.3
	done
	return 1
}

# qemu_send <raw-bytes> -> writes to the serial line (no implicit newline --
# callers pass \r themselves, since a real terminal sends carriage return on
# Enter, which the tty line discipline's ICRNL then turns into \n for
# whatever's reading on the other end).
qemu_send() { printf '%s' "$1" >&"$QEMU_FD"; }

# qemu_quit -> shuts the session's QEMU down via its monitor's `quit`
# command rather than SIGTERM/SIGKILL, so a virtual disk's own write-back
# cache gets flushed to the backing file cleanly instead of racing a signal
# against in-flight writes -- this matters here specifically because
# test-install.sh reuses the same disk image across several qemu_boot_serial
# sessions (install, then boot, then backup/restore).
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
