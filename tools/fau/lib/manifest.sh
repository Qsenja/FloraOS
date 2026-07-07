# lib/manifest.sh -- sourced by fau-bootstrap/fau-install/fau-export.
# system.json (FAU_ROOT-side packages) and apps.json (FAU_APPS_DIR-side
# isolated apps) share one flat schema:
# {"packages":{"name":{"version":"x"},...}} -- these functions are
# parameterized by which file to operate on, plus record_files (per-package
# owned-file lists, used by both bootstrap-remove and alpm installs) and
# the local-repo dependency-constraint helpers (dep_parse/version_satisfies)
# every install path needs regardless of whether the package came from
# fau's own repo or the alpm fallback.
#
# Requires lib/common.sh already sourced (die/log/FAU_* env vars).

state_init() {
	mkdir -p "$FAU_STATE_DIR" "$FAU_CACHE_DIR" "$FAU_FILES_DIR"
	[ -f "$FAU_SYSTEM_JSON" ] || printf '{"packages":{}}\n' > "$FAU_SYSTEM_JSON"
}

apps_state_init() {
	mkdir -p "$FAU_APPS_DIR" "$FAU_APPS_BIN_DIR"
	[ -f "$FAU_APPS_JSON" ] || printf '{"packages":{}}\n' > "$FAU_APPS_JSON"
}

json_get_version() {
	# json_get_version <file> <name>  -> prints version or nothing
	local file=$1 name=$2
	grep -o "\"$name\"[[:space:]]*:[[:space:]]*{[[:space:]]*\"version\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
		| sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true
}

json_list_names() {
	local file=$1
	grep -oE '"[^"]+"[[:space:]]*:[[:space:]]*\{[[:space:]]*"version"' "$file" 2>/dev/null \
		| sed -E 's/^"([^"]+)".*/\1/' || true
}

json_set() {
	# json_set <file> <name> <version>  — add or update an entry
	local file=$1 name=$2 version=$3
	local tmp; tmp=$(mktemp)
	{
		echo '{"packages":{'
		local first=1
		for n in $(json_list_names "$file"); do
			[ "$n" = "$name" ] && continue
			local v; v=$(json_get_version "$file" "$n")
			[ $first -eq 1 ] || echo ','
			first=0
			printf '"%s":{"version":"%s"}' "$(json_escape "$n")" "$(json_escape "$v")"
		done
		[ $first -eq 1 ] || echo ','
		printf '"%s":{"version":"%s"}' "$(json_escape "$name")" "$(json_escape "$version")"
		echo
		echo '}}'
	} > "$tmp"
	mv "$tmp" "$file"
}

json_unset() {
	local file=$1 name=$2
	local tmp; tmp=$(mktemp)
	{
		echo '{"packages":{'
		local first=1
		for n in $(json_list_names "$file"); do
			[ "$n" = "$name" ] && continue
			local v; v=$(json_get_version "$file" "$n")
			[ $first -eq 1 ] || echo ','
			first=0
			printf '"%s":{"version":"%s"}' "$(json_escape "$n")" "$(json_escape "$v")"
		done
		echo
		echo '}}'
	} > "$tmp"
	mv "$tmp" "$file"
}

system_get_version() { json_get_version "$FAU_SYSTEM_JSON" "$1"; }
system_list_names() { json_list_names "$FAU_SYSTEM_JSON"; }
system_set() { json_set "$FAU_SYSTEM_JSON" "$1" "$2"; }
system_unset() { json_unset "$FAU_SYSTEM_JSON" "$1"; }

record_files() {
	# record_files <name> <source-dir> -- <source-dir> is a package's
	# fully-assembled payload right before it gets rsync'd into FAU_ROOT;
	# recording its relative paths here (relative to FAU_ROOT once merged)
	# is what lets `bootstrap-remove` actually delete a package's own files
	# instead of only untracking it from system.json.
	local name=$1 src=$2
	(cd "$src" && find . \( -type f -o -type l \) -printf '%P\n') > "$FAU_FILES_DIR/$name"
}

# --- dependency version constraints (fau's own local repo, NOT the alpm
# fallback -- see lib/alpm.sh's own alpm_dep_parse/version_satisfies_alpm
# for that separate, Arch-version-string-aware pair) -----------------------
# depends= entries may optionally carry a constraint: "name", "name>=1.2", or
# "name==1.2" (comma-separated, same as always). Deliberately just these two
# operators, both string-compared via `sort -V` (coreutils, already a base
# package) rather than a hand-rolled semver parser -- full range solving was
# already scoped out in ARCHITECTURE.md as more than this tool needs.

dep_parse() {
	# dep_parse <dep-token> -> prints "name<TAB>op<TAB>version" (op/version
	# empty if the token is a bare name)
	local dep=$1
	case "$dep" in
		*'>='*) printf '%s\t%s\t%s\n' "${dep%%>=*}" '>=' "${dep#*>=}" ;;
		*'=='*) printf '%s\t%s\t%s\n' "${dep%%==*}" '==' "${dep#*==}" ;;
		*) printf '%s\t\t\n' "$dep" ;;
	esac
}

version_satisfies() {
	# version_satisfies <installed> <op> <required> -- op may be empty (any
	# installed version satisfies an unconstrained dependency)
	local installed=$1 op=$2 required=$3
	case "$op" in
		'') return 0 ;;
		'==') [ "$installed" = "$required" ] ;;
		'>=')
			[ "$installed" = "$required" ] && return 0
			[ "$(printf '%s\n%s\n' "$installed" "$required" | sort -V | tail -n1)" = "$installed" ]
			;;
		*) die "unknown version constraint operator: $op" ;;
	esac
}
