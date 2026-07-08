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
	# Nested lib dirs (e.g. perl's libperl.so) are found explicitly, not just usr/lib:lib -- see fau.md.
	local nested_libdirs; nested_libdirs=$(find "$app_dir" -iname '*.so*' -exec dirname {} \; 2>/dev/null | sort -u | tr '\n' ':')
	local app_libdir="$app_dir/usr/lib:$app_dir/lib:${nested_libdirs%:}"
	app_libdir=${app_libdir%:}
	# PERL5LIB covers perl's own compiled-in @INC, which LD_LIBRARY_PATH alone doesn't fix -- see fau.md.
	local perl5lib; perl5lib=$(find "$app_dir" -iname '*.pm' -exec dirname {} \; 2>/dev/null | sort -u | tr '\n' ':')
	perl5lib=${perl5lib%:}
	cat > "$wrapper" <<-EOF
	#!/bin/sh
	export HOME="$app_dir"
	export XDG_CONFIG_HOME="$app_dir/config"
	export XDG_CACHE_HOME="$app_dir/cache"
	export XDG_DATA_HOME="$app_dir/data"
	export XDG_STATE_HOME="$app_dir/logs"
	export LD_LIBRARY_PATH="$app_libdir\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
	export PATH="$app_dir/usr/bin:$app_dir/bin\${PATH:+:\$PATH}"
	${perl5lib:+export PERL5LIB="$perl5lib\${PERL5LIB:+:\$PERL5LIB}"}
	exec "$app_dir/$relbin" "\$@"
	EOF
	chmod 755 "$wrapper"
}
