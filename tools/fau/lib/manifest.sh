# lib/manifest.sh -- system.json/apps.json read-write, dep_parse/version_satisfies. See fau.md.
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
	local file=$1 name=$2
	grep -o "\"$name\"[[:space:]]*:[[:space:]]*{[[:space:]]*\"version\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
		| sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true
}

json_list_names() {
	local file=$1
	grep -oE '"[^"]+"[[:space:]]*:[[:space:]]*\{[[:space:]]*"version"' "$file" 2>/dev/null \
		| sed -E 's/^"([^"]+)".*/\1/' || true
}

# name<TAB>version for every entry in one grep+sed pass -- used internally by
# json_set/json_unset instead of json_list_names plus one json_get_version
# (its own grep+sed pair) per name. See fau.md.
json_pairs() {
	grep -o '"[^"]*"[[:space:]]*:[[:space:]]*{[[:space:]]*"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" 2>/dev/null \
		| sed -E 's/^"([^"]*)"[[:space:]]*:[[:space:]]*\{[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1\t\2/'
}

json_set() {
	local file=$1 name=$2 version=$3
	local tmp; tmp=$(mktemp)
	{
		echo '{"packages":{'
		local first=1 n v
		while IFS=$'\t' read -r n v; do
			[ "$n" = "$name" ] && continue
			[ $first -eq 1 ] || echo ','
			first=0
			printf '"%s":{"version":"%s"}' "$(json_escape "$n")" "$(json_escape "$v")"
		done < <(json_pairs "$file")
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
		local first=1 n v
		while IFS=$'\t' read -r n v; do
			[ "$n" = "$name" ] && continue
			[ $first -eq 1 ] || echo ','
			first=0
			printf '"%s":{"version":"%s"}' "$(json_escape "$n")" "$(json_escape "$v")"
		done < <(json_pairs "$file")
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
	local name=$1 src=$2
	(cd "$src" && find . \( -type f -o -type l \) -printf '%P\n') > "$FAU_FILES_DIR/$name"
}

# Dependency version constraints for fau's own local repo -- NOT the alpm fallback's
# separate alpm_dep_parse/version_satisfies_alpm (lib/alpm.sh). See fau.md.

dep_parse() {
	local dep=$1
	case "$dep" in
		*'>='*) printf '%s\t%s\t%s\n' "${dep%%>=*}" '>=' "${dep#*>=}" ;;
		*'=='*) printf '%s\t%s\t%s\n' "${dep%%==*}" '==' "${dep#*==}" ;;
		*) printf '%s\t\t\n' "$dep" ;;
	esac
}

version_satisfies() {
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
