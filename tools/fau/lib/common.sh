# lib/common.sh -- sourced (not executed) by every fau-* tool. The bare
# minimum every one of them needs regardless of what it actually does:
# FAU_ROOT/FAU_REPO_DIR/FAU_APPS_DIR-family env var defaults, and
# die()/log(). Env vars are set here (not just left to each tool) so a
# variable's default lives in exactly one place -- `fau-backup` sourcing
# this and never touching FAU_ROOT is harmless, not wasteful; duplicating
# the defaults per-tool instead would be the real risk (one tool's default
# silently drifting from another's).
#
# Not itself executable, and not meant to be -- `set -euo pipefail` here
# only takes effect because every caller already has it set too (sourcing
# doesn't create a new shell option scope); each fau-* tool still sets it
# again itself at the top, same as this project's other scripts, so this
# file also behaves correctly if ever sourced on its own for testing.

FAU_ROOT="${FAU_ROOT:-/}"
FAU_REPO_DIR="${FAU_REPO_DIR:-/etc/fau/repo}"
FAU_STATE_DIR="${FAU_ROOT%/}/var/lib/fau"
FAU_CACHE_DIR="${FAU_ROOT%/}/var/cache/fau/pkg"
FAU_SYSTEM_JSON="${FAU_STATE_DIR}/system.json"
FAU_FILES_DIR="${FAU_STATE_DIR}/files"

FAU_APPS_DIR="${FAU_APPS_DIR:-$HOME/apps}"
FAU_APPS_BIN_DIR="${FAU_APPS_DIR}/.bin"
FAU_APPS_JSON="${FAU_APPS_DIR}/.fau-apps.json"

# fauelf (tools/fauelf, see its own header comment): rewrites absolute-path
# DT_NEEDED entries to bare basenames in an isolated app's own binaries --
# needed because those paths bypass LD_LIBRARY_PATH/RPATH entirely and only
# happen to resolve for a system-root (FAU_ROOT="/") merge, not an isolated
# app directory. Plain command name by default (found via PATH once shipped
# at /usr/bin/fauelf); build-rootfs.sh overrides this to a build-host path
# since fauelf's app-install call happens before the compiled binary is
# anywhere on this build host's own PATH. Only fau-install actually uses
# this, but it costs nothing to set here alongside everything else.
FAU_ELF_PATCH="${FAU_ELF_PATCH:-fauelf}"

die() { echo "fau: error: $*" >&2; exit 1; }
log() { echo "fau: $*" >&2; }

json_escape() {
	# minimal JSON string escaping for the fields we actually emit (no control chars expected)
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	printf '%s' "$s"
}

pkginfo_field() {
	# pkginfo_field <pkginfo-file> <key>
	grep "^$2=" "$1" 2>/dev/null | head -n1 | cut -d'=' -f2- || true
}
