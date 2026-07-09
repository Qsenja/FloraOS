# lib/common.sh -- sourced by every fau-* tool: env var defaults, die()/log(). See fau.md.

FAU_ROOT="${FAU_ROOT:-/}"
FAU_REPO_DIR="${FAU_REPO_DIR:-/etc/fau/repo}"
FAU_STATE_DIR="${FAU_ROOT%/}/var/lib/fau"
FAU_CACHE_DIR="${FAU_ROOT%/}/var/cache/fau/pkg"
FAU_SYSTEM_JSON="${FAU_STATE_DIR}/system.json"
FAU_FILES_DIR="${FAU_STATE_DIR}/files"

FAU_APPS_DIR="${FAU_APPS_DIR:-$HOME/apps}"
FAU_APPS_BIN_DIR="${FAU_APPS_DIR}/.bin"
FAU_APPS_JSON="${FAU_APPS_DIR}/.fau-apps.json"

FAU_RECIPES_DIR="${FAU_RECIPES_DIR:-/usr/lib/fau/recipes}"
# Synced from FAU_RECIPES_REPO at runtime (recipes_sync, lib/recipes.sh) --
# takes priority over the read-only, ISO-build-time copy above when present.
FAU_RECIPES_REMOTE_DIR="${FAU_RECIPES_REMOTE_DIR:-${FAU_CACHE_DIR}/recipes-remote}"
FAU_RECIPES_REPO="${FAU_RECIPES_REPO-https://github.com/Qsenja/fau-recipes}"
FAU_RECIPES_BRANCH="${FAU_RECIPES_BRANCH:-main}"
# Same repo as above, separate index/subdir (system-recipes.db/system/) --
# used by `fau bootstrap-build` for base-system packages. No ISO-shipped
# fallback dir; this is purely a live-update feature. See fau.md.
FAU_SYSTEM_RECIPES_REMOTE_DIR="${FAU_SYSTEM_RECIPES_REMOTE_DIR:-${FAU_CACHE_DIR}/system-recipes-remote}"

# See ../fauelf/fauelf.md -- rewrites absolute DT_NEEDED entries for isolated app installs.
FAU_ELF_PATCH="${FAU_ELF_PATCH:-fauelf}"

die() { echo "fau: error: $*" >&2; exit 1; }
log() { echo "fau: $*" >&2; }

# tar_extract_or_die <archive> <dest-dir> <label> -- extracts a .pkg
# archive, turning tar's own per-file failure spam (e.g. hundreds of
# "Cannot write: No space left on device" lines when a RAM-backed live
# root fills up mid-extraction) into one clean message instead.
tar_extract_or_die() {
	local archive=$1 dest=$2 label=$3
	local tar_err; tar_err=$(mktemp)
	if ! tar --zstd -xf "$archive" -C "$dest" 2>"$tar_err"; then
		if grep -q "No space left on device" "$tar_err"; then
			rm -f "$tar_err"
			die "ran out of space extracting $label -- this system's root may be RAM-backed with limited capacity; free up space/RAM, or build/install fewer things at once"
		fi
		local firstline; firstline=$(head -n1 "$tar_err")
		rm -f "$tar_err"
		die "extracting $label failed: $firstline"
	fi
	rm -f "$tar_err"
}

# strip_unreachable_docs <extracted-package-dir> -- deletes man/info/doc/
# locale from a package about to be merged. See fau.md's "Dead-weight
# strip" section: no reader for man/info exists anywhere in FloraOS, doc/
# is reference-only, and locale's .mo catalogs are only ever consulted for
# a LANG this project doesn't set by default (see 'fau setlang').
strip_unreachable_docs() {
	local dir=$1
	rm -rf "$dir/usr/share/man" "$dir/usr/share/info" "$dir/usr/share/doc" "$dir/usr/share/locale"
}

# offer_build <name> [version] -- if a fau-build recipe exists for <name>
# (checked via recipe_lookup, lib/recipes.sh -- a fresh recipes_sync first,
# so this sees a recipe pushed to FAU_RECIPES_REPO after this ISO was built,
# not just whatever shipped in it), asks the user whether to build it from
# source instead, exec'ing `fau-build build <name>[=<version>]` if they say
# yes. Two distinct failure states, distinguished by exit status so the
# caller's own error message doesn't lie about which one happened -- a name
# with no recipe anywhere is genuinely a different situation from a name
# that DOES have one, just not built this time:
#   1 -- no recipe exists for <name> at all (nothing to offer)
#   2 -- a recipe exists, but nothing came of it: no controlling terminal to
#        ask on (e.g. a non-interactive invocation), or the user declined
# Only ever called from fau-install, which already sources lib/recipes.sh
# before running any command -- if a future caller doesn't, the declare -F
# guard below makes that a clean "no recipe available" (1) instead of an
# unbound-function error.
offer_build() {
	local name=$1 version=${2:-}
	declare -F recipe_lookup >/dev/null && declare -F recipes_sync >/dev/null || return 1
	recipes_sync || true
	recipe_lookup "$name" >/dev/null 2>&1 || return 1
	[ -t 0 ] || return 2
	local reply
	printf '"%s" isn'"'"'t available as a precompiled package, but a fau-build recipe exists for it. Build it from source now? [y/N] ' "$name" > /dev/tty 2>/dev/null || return 2
	read -r reply < /dev/tty 2>/dev/null || return 2
	case "$reply" in
		[Yy]|[Yy][Ee][Ss]) exec "$SELF_DIR/fau-build" build "${name}${version:+=$version}" ;;
		*) return 2 ;;
	esac
}

# Rewrites <real-tool-name>'s self-mentions in stdout/stderr to fau's own naming. See fau.md.
# NOT safe for a command with an unterminated interactive prompt (see fau-user's cmd_user_passwd).
relabel_run() {
	local subcmd=$1 realtool=$2; shift 2
	local family=${subcmd%%-*}
	local status
	"$@" \
		1> >(sed -u -e "s/^${realtool}: /fau ${subcmd}: /" -e "s/\b${realtool} /fau ${family}-/g") \
		2> >(sed -u -e "s/^${realtool}: /fau ${subcmd}: /" -e "s/\b${realtool} /fau ${family}-/g" >&2)
	status=$?
	wait
	return "$status"
}

json_escape() {
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	printf '%s' "$s"
}

pkginfo_field() {
	grep "^$2=" "$1" 2>/dev/null | head -n1 | cut -d'=' -f2- || true
}

# Writes a PATH-visible wrapper redirecting an isolated app into its own directory. See fau.md.
app_wrapper_write() {
	local name=$1 app_dir=$2 relbin=$3
	local cmd_name; cmd_name=$(basename "$relbin")
	local wrapper="$FAU_APPS_BIN_DIR/$cmd_name"

	# One traversal of $app_dir feeding every classification below, not one
	# find per env var -- see fau.md. dirname is done via parameter
	# expansion, not a subshell per match, since a large app dir can have
	# hundreds of matches.
	local nested_libdirs="" perl5lib="" xkb_config_root="" egl_vendor_dir="" \
		gbm_backends_dir="" wlr_xwayland="" libinput_quirks_dir="" fontconfig_file=""
	local -a libdir_list=() perldir_list=()
	local ftype fpath entry d
	shopt -s nocasematch
	while IFS= read -r -d '' entry; do
		ftype=${entry%% *}; fpath=${entry#* }
		case "$fpath" in
			*/rules/evdev)
				if [ "$ftype" = f ] && [ -z "$xkb_config_root" ]; then
					d=${fpath%/*}; [ "$d" = "$fpath" ] && d=.
					xkb_config_root=${d%/*}
					[ "$xkb_config_root" = "$d" ] && xkb_config_root=.
				fi ;;
			*/glvnd/egl_vendor.d)
				if [ "$ftype" = d ] && [ -z "$egl_vendor_dir" ]; then
					egl_vendor_dir=$fpath
				fi ;;
			*_gbm.so)
				if [ "$ftype" = f ] && [ -z "$gbm_backends_dir" ]; then
					gbm_backends_dir=${fpath%/*}; [ "$gbm_backends_dir" = "$fpath" ] && gbm_backends_dir=.
				fi ;;
			*/bin/Xwayland)
				if [ "$ftype" = f ] && [ -z "$wlr_xwayland" ]; then
					wlr_xwayland=$fpath
				fi ;;
			*/libinput/*.quirks)
				if [ "$ftype" = f ] && [ -z "$libinput_quirks_dir" ]; then
					libinput_quirks_dir=${fpath%/*}; [ "$libinput_quirks_dir" = "$fpath" ] && libinput_quirks_dir=.
				fi ;;
			*/etc/fonts/fonts.conf)
				if [ "$ftype" = f ] && [ -z "$fontconfig_file" ]; then
					fontconfig_file=$fpath
				fi ;;
		esac
		case "$fpath" in
			*.so*)
				d=${fpath%/*}; [ "$d" = "$fpath" ] && d=.
				libdir_list+=("$d") ;;
		esac
		case "$fpath" in
			*.pm)
				d=${fpath%/*}; [ "$d" = "$fpath" ] && d=.
				perldir_list+=("$d") ;;
		esac
	done < <(find "$app_dir" \( \
			-iname '*.so*' -o -iname '*.pm' -o \
			-path '*/rules/evdev' -o -path '*/glvnd/egl_vendor.d' -o \
			-name '*_gbm.so' -o -path '*/bin/Xwayland' -o \
			-path '*/libinput/*.quirks' -o -path '*/etc/fonts/fonts.conf' \
		\) -printf '%y %p\0' 2>/dev/null)
	shopt -u nocasematch
	# Nested lib dirs (e.g. perl's libperl.so) are found explicitly, not just usr/lib:lib -- see fau.md.
	if [ "${#libdir_list[@]}" -gt 0 ]; then
		nested_libdirs=$(printf '%s\n' "${libdir_list[@]}" | sort -u | tr '\n' ':')
	fi
	local app_libdir="$app_dir/usr/lib:$app_dir/lib:${nested_libdirs%:}"
	app_libdir=${app_libdir%:}
	# PERL5LIB covers perl's own compiled-in @INC, which LD_LIBRARY_PATH alone doesn't fix -- see fau.md.
	if [ "${#perldir_list[@]}" -gt 0 ]; then
		perl5lib=$(printf '%s\n' "${perldir_list[@]}" | sort -u | tr '\n' ':')
	fi
	perl5lib=${perl5lib%:}
	# XKB_CONFIG_ROOT: libxkbcommon has its own compiled-in default XKB data
	# root (a real absolute host path, e.g. /usr/share/xkeyboard-config-2 --
	# confirmed directly via `strings` on the real alpm-fetched
	# libxkbcommon.so.0), completely unaware of $app_dir -- the xkeyboard-
	# config package's own data merges correctly into the isolated app, but
	# libxkbcommon never looks there, so it fails with "Couldn't find file
	# 'rules/evdev' in include paths" regardless. Same class of bug as
	# mango's own $HOME-based config.conf gap, just baked into a shared
	# library instead of one specific app's own source. Verified for real
	# with bwrap masking the actual system path first: fails identically to
	# the real error without this override, succeeds with it (see fau.md).
	# Found via the "rules/evdev" marker file -- present at
	# <XKB_CONFIG_ROOT>/rules/evdev in every real xkeyboard-config install --
	# so this only ever fires for an app that actually bundles the data.
	# __EGL_VENDOR_LIBRARY_DIRS: libglvnd's libEGL.so.1 dispatcher (mesa's
	# EGL is loaded through it, not directly) only ever scans its own
	# compiled-in vendor config dirs -- /etc/glvnd/egl_vendor.d and
	# /usr/share/glvnd/egl_vendor.d -- for *.json ICD descriptors, never
	# $app_dir, even though the mesa package's own 50_mesa.json lands at
	# $app_dir/usr/share/glvnd/egl_vendor.d/50_mesa.json same as any other
	# alpm-fetched file (confirmed: `pacman -Ql mesa` lists that exact
	# path). With zero vendor JSON visible, glvnd finds no ICD at all --
	# "EGL_EXT_platform_base not supported" / "Failed to create EGL
	# context" / "Could not initialize EGL" (mango's own
	# fx_renderer.c:282), even with a working KMS driver underneath and
	# even though the real mesa EGL driver .so is sitting right there in
	# LD_LIBRARY_PATH. Same bug class as XKB_CONFIG_ROOT above, this time
	# in libglvnd's loader instead of libxkbcommon. Confirmed via
	# libglvnd's own icd_enumeration.md: __EGL_VENDOR_LIBRARY_DIRS is a
	# colon-separated list of directories scanned for *.json ICD files,
	# explicitly documented as the override for the default search path.
	# Found via the "glvnd/egl_vendor.d" marker directory -- only ever
	# fires for an app that actually bundles mesa/libglvnd.
	# GBM_BACKENDS_PATH: even with libEGL correctly finding mesa via the
	# __EGL_VENDOR_LIBRARY_DIRS fix above, mesa's own libgbm.so has a THIRD,
	# separate hardcoded search path of its own -- defaults to
	# "$libdir/gbm" -- for dlopen'ing its actual backend (`dri_gbm.so`,
	# confirmed via `pacman -Ql mesa`: lands at
	# $app_dir/usr/lib/gbm/dri_gbm.so, alpm-fetched same as everything
	# else). Symptom, one step further than the glvnd fix: mango's
	# fx_renderer.c:282 "Could not initialize EGL object file: No such
	# file or directory (search paths /usr/lib/gbm, suffix _gbm)" --
	# confirmed as an exact byte-for-byte match against a real mango run,
	# not just a plausible guess. Same bug class as XKB_CONFIG_ROOT and
	# __EGL_VENDOR_LIBRARY_DIRS above, one library deeper in the same EGL
	# init chain each time. Fixed via GBM_BACKENDS_PATH (mesa's own
	# documented override, src/gbm/main/backend.c). Verified for real with
	# bwrap masking the real /usr/lib/gbm path first: eglinfo -p gbm fails
	# with the exact same "search paths /usr/lib/gbm, suffix _gbm" text
	# without the override, and succeeds end-to-end (full EGL/GL context
	# creation) once GBM_BACKENDS_PATH points at a copy of the backend .so,
	# even with the real path still masked.
	# WLR_XWAYLAND: wlroots' own Xwayland integration checks a hardcoded
	# absolute "/usr/bin/Xwayland" rather than searching PATH, even though
	# PATH is already set to include $app_dir/usr/bin above -- xorg-xwayland
	# (already in mango's PKG_DEPENDS) merges its real binary in at
	# $app_dir/usr/bin/Xwayland fine (confirmed via `pacman -Ql
	# xorg-xwayland`), wlroots just never looks there. Symptom, confirmed
	# against a real mango run: "[xwayland/server.c:472] Cannot find
	# Xwayland binary '/usr/bin/Xwayland'" -- non-fatal (mango continues
	# without X11 app support) but still a real isolation gap, same class
	# as every other fix in this function. Fixed via WLR_XWAYLAND, wlroots'
	# own documented override (see wlroots' docs/env_vars.md) -- exists
	# specifically so a caller can swap in an alternate Xwayland without a
	# global system change, which is exactly this situation.
	# LIBINPUT_QUIRKS_DIR: libinput's own device-quirks loader is hardcoded
	# to /usr/share/libinput -- libinput (already in mango's PKG_DEPENDS)
	# merges its real quirks files in at
	# $app_dir/usr/share/libinput/*.quirks fine (confirmed via `pacman -Ql
	# libinput`), libinput just never looks there. Symptom, confirmed
	# against a real mango run: "libinput error: /usr/share/libinput:
	# failed to find data files" -- non-fatal (libinput continues with
	# degraded device behavior) but same isolation gap as everything else
	# here. Fixed via LIBINPUT_QUIRKS_DIR -- not documented in any man
	# page, but confirmed directly via `strings` on the real alpm-fetched
	# libinput.so.10: the literal string sits right next to
	# "../libinput/src/quirks.c" and the "/usr/share/libinput" default,
	# unambiguously the env var backing this exact lookup (same standard
	# of evidence used for XKB_CONFIG_ROOT above).
	# FONTCONFIG_FILE: fontconfig's own default config path is hardcoded to
	# /etc/fonts/fonts.conf -- any app that bundles fontconfig as a
	# dependency (e.g. foot, kitty) merges its own copy in at
	# $app_dir/etc/fonts/fonts.conf fine, fontconfig just never looks
	# there. Symptom, confirmed against a real `foot` run: "Fontconfig
	# error: Cannot load default config file: File not found", cascading
	# into "failed to match font" and a fatal "failed to load primary
	# fonts" crash. Fixed via FONTCONFIG_FILE (confirmed via `strings` on
	# the real alpm-fetched libfontconfig.so, alongside FONTCONFIG_PATH/
	# FONTCONFIG_SYSROOT -- fontconfig's own documented overrides). The
	# per-app fonts.conf itself points at the real, non-isolated
	# /usr/share/fonts (confirmed: FloraOS has no chroot, so a real,
	# shared /usr/share/fonts works identically for every isolated app --
	# see docs/ARCHITECTURE.md for where that directory's actual contents
	# come from).
	# XDG_DATA_DIRS: every isolated app's own XDG_DATA_HOME is its private
	# $app_dir/data -- fine for that app's own state, but it means no app
	# can ever see another app's .desktop entries, icons, etc. (each app is
	# its own island, same root cause as everything above). Set
	# unconditionally, not just when this app happens to have its own data
	# to contribute: a launcher like rofi needs this on ITS OWN wrapper to
	# find *other* apps' entries, merged in by app_desktop_merge below.
	# FAU_APPS_DIR/.data mirrors the existing FAU_APPS_BIN_DIR/.bin
	# convention (see fau.md) -- one shared, XDG-shaped tree instead of yet
	# another bespoke isolated-app workaround.
	local shared_data_dir="${FAU_APPS_DIR%/}/.data"
	cat > "$wrapper" <<-EOF
	#!/bin/sh
	export HOME="$app_dir"
	export XDG_CONFIG_HOME="$app_dir/config"
	export XDG_CACHE_HOME="$app_dir/cache"
	export XDG_DATA_HOME="$app_dir/data"
	export XDG_STATE_HOME="$app_dir/logs"
	export XDG_DATA_DIRS="$shared_data_dir:/usr/local/share:/usr/share"
	export LD_LIBRARY_PATH="$app_libdir\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
	export PATH="$app_dir/usr/bin:$app_dir/bin\${PATH:+:\$PATH}"
	${perl5lib:+export PERL5LIB="$perl5lib\${PERL5LIB:+:\$PERL5LIB}"}
	${xkb_config_root:+export XKB_CONFIG_ROOT="$xkb_config_root"}
	${egl_vendor_dir:+export __EGL_VENDOR_LIBRARY_DIRS="$egl_vendor_dir"}
	${gbm_backends_dir:+export GBM_BACKENDS_PATH="$gbm_backends_dir"}
	${wlr_xwayland:+export WLR_XWAYLAND="$wlr_xwayland"}
	${libinput_quirks_dir:+export LIBINPUT_QUIRKS_DIR="$libinput_quirks_dir"}
	${fontconfig_file:+export FONTCONFIG_FILE="$fontconfig_file"}
	exec "$app_dir/$relbin" "\$@"
	EOF
	chmod 755 "$wrapper"
}

# Merges an app's own .desktop entries into the shared XDG_DATA_DIRS tree
# (FAU_APPS_DIR/.data/applications) so launchers like rofi can actually find
# them -- same reasoning and same shared-collection pattern as
# app_wrapper_write's own PATH merge into FAU_APPS_BIN_DIR. Confirmed on a
# real rofi run: kitty's own kitty.desktop merges fine into its own
# isolated $app_dir/usr/share/applications/, but rofi's -show drun only
# ever scans XDG_DATA_DIRS/XDG_DATA_HOME, so it saw nothing without this.
# Exec= lines reference the app's own bundled binary name/path, which
# doesn't exist outside $app_dir -- rewritten to the actual PATH-visible
# wrapper app_wrapper_write itself already generates, so launching from
# rofi executes the same isolated app a shell's `kitty` would.
app_desktop_merge() {
	local app_dir=$1
	local src_dir="$app_dir/usr/share/applications"
	[ -d "$src_dir" ] || return 0
	local dest_dir="${FAU_APPS_DIR%/}/.data/applications"
	mkdir -p "$dest_dir"
	local f base
	for f in "$src_dir"/*.desktop; do
		[ -f "$f" ] || continue
		base=$(basename "$f")
		sed -E "s|^Exec=([^ ]*/)?([^ ]+)|Exec=$FAU_APPS_BIN_DIR/\\2|" "$f" > "$dest_dir/$base"
	done
}
