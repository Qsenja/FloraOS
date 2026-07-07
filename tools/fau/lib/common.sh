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

# Recipes fau-build compiles from source directly on a live system (see
# lib/build.sh/fau-build) -- shipped inside the image at this fixed path by
# build-rootfs.sh as *.fis files (its own recipes/ dir, scripts/recipes/*.sh,
# is a completely separate, build-host-only thing: base-rootfs packages
# built once ahead of time, never touched by fau at runtime). Overridable
# the same way FAU_REPO_DIR/FAU_APPS_DIR are, for testing against a scratch
# recipes dir without needing a real installed image.
FAU_RECIPES_DIR="${FAU_RECIPES_DIR:-/usr/lib/fau/recipes}"

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

# relabel_run <fau-subcommand> <real-tool-name> <cmd...> -- runs <cmd...>,
# rewriting <real-tool-name>'s own mentions of itself in its stdout/stderr
# to fau's own naming. End users only ever type `fau <fau-subcommand>`,
# never the wrapped binary's own name (florauser, ...), so its own
# printf/fprintf messages should say so too -- otherwise "fau user-add"
# fails with a message about "florauser", a command that was never run, or
# tells the user to fix it by running "florauser passwd" themselves, which
# isn't even on PATH under that name outside of fau. Two substitutions:
# "<real-tool-name>: " at line start (its own message prefix) becomes
# "fau <fau-subcommand>: "; a bare "<real-tool-name> " anywhere (it
# referencing one of its own other subcommands, e.g. florauser's "run:
# florauser passwd alice" advice) becomes "fau <family>-" so the verb that
# follows turns into fau's actual subcommand name, e.g. "fau user-passwd" --
# <fau-subcommand>'s own family prefix (the part before its first "-") is
# reused here since every fau-user subcommand follows exactly that
# "<family>-<verb>" shape.
# Each stream is rewritten independently via its own process substitution
# (not one pipe merging both) so stdout/stderr stay on their original
# streams, exactly as <cmd...> itself would leave them uncaptured. <cmd...>
# is run directly as this function's own foreground job (the process
# substitutions are its stdout/stderr, not a pipeline it's part of), so its
# real exit status lands straight in $? -- no PIPESTATUS juggling needed.
# The trailing `wait` blocks until both sed's have flushed, so this
# function's caller never races ahead of output that's still in flight.
#
# NOT safe for a command whose stdout/stderr includes an interactive
# prompt with no trailing newline (e.g. florauser's "New password: ", left
# unterminated so the cursor stays put for input on the same line): sed
# only ever emits a *complete* line, so that prompt would sit stuck in its
# buffer, invisible, until some later newline happened to flush it out --
# confirmed with a throwaway reproducer (see fau-user's cmd_user_passwd,
# which deliberately skips this function for exactly that reason).
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

# app_wrapper_write <name> <app-dir> <relbin> -- writes a PATH-visible
# wrapper at $FAU_APPS_BIN_DIR/<basename of relbin> that redirects an
# isolated app into its own directory (HOME/XDG_*_HOME/LD_LIBRARY_PATH/PATH)
# before exec'ing the real binary. Moved here from fau-install (where this
# originated) once fau-build (lib/build.sh) needed the exact same thing for
# an on-device-compiled app's own binaries -- a shared, generic utility any
# isolated-app-populating code path needs, not something specific to
# installing from a repo/alpm.
app_wrapper_write() {
	local name=$1 app_dir=$2 relbin=$3
	local cmd_name; cmd_name=$(basename "$relbin")
	local wrapper="$FAU_APPS_BIN_DIR/$cmd_name"
	# Flat usr/lib:lib covers most packages, but some (perl, for one) ship
	# their real runtime .so nested well below that -- perl's own
	# libperl.so lives at usr/lib/perl5/<ver>/core_perl/CORE/libperl.so,
	# not directly under usr/lib/, so cowsay (a perl script) failed at
	# runtime with "libperl.so: cannot open shared object file" despite
	# installing fine. Computed once here (at wrapper-write time, not on
	# every invocation) by finding every directory under the app that
	# actually contains a shared library, so this covers that case and any
	# other package with a similarly nested private lib directory.
	local nested_libdirs; nested_libdirs=$(find "$app_dir" -iname '*.so*' -exec dirname {} \; 2>/dev/null | sort -u | tr '\n' ':')
	local app_libdir="$app_dir/usr/lib:$app_dir/lib:${nested_libdirs%:}"
	app_libdir=${app_libdir%:}
	# Same problem, one level up: perl itself is compiled with @INC pointing
	# at the real /usr/lib/perl5/..., not this app's own isolated copy, so a
	# perl script here (cowsay, for one) found libperl.so fine but then
	# failed with "Can't locate Cwd.pm in @INC" -- Cwd.pm existed, just under
	# $app_dir, which perl's compiled-in search path never looks at. PERL5LIB
	# is perl's own supported override for exactly this (like
	# LD_LIBRARY_PATH, but for .pm modules instead of .so libraries) -- no
	# need to patch perl or chroot anything.
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
