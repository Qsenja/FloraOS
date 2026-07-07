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

# See ../fauelf/fauelf.md -- rewrites absolute DT_NEEDED entries for isolated app installs.
FAU_ELF_PATCH="${FAU_ELF_PATCH:-fauelf}"

die() { echo "fau: error: $*" >&2; exit 1; }
log() { echo "fau: $*" >&2; }

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
