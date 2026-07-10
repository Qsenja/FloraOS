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

# system.json is fau's reproducibility manifest, not just an installed-list --
# beyond "version", each package can carry origin (fau-repo/alpm/source: where
# its bytes actually came from), src_url/src_sha256 (exactly what was fetched,
# for the alpm and source origins), and recipe_sha256 (the .fis recipe file's
# own content hash, source origin only -- lets a rebuild be pinned to the
# exact recipe text used, not just "whatever fau-recipes has today"). "version"
# is always written first so json_get_version/json_list_names/json_pairs
# (which anchor on {"version" right after the opening brace) keep parsing
# system.json's entries unchanged even though the object now has more keys.
# See fau.md.

json_get_field() {
	local file=$1 name=$2 field=$3
	grep -o "\"$name\"[[:space:]]*:[[:space:]]*{[^}]*\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
		| sed -E "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/" || true
}

system_get_origin()        { json_get_field "$FAU_SYSTEM_JSON" "$1" "origin"; }
system_get_src_url()       { json_get_field "$FAU_SYSTEM_JSON" "$1" "src_url"; }
system_get_src_sha256()    { json_get_field "$FAU_SYSTEM_JSON" "$1" "src_sha256"; }
system_get_recipe_sha256() { json_get_field "$FAU_SYSTEM_JSON" "$1" "recipe_sha256"; }

# name<TAB>version<TAB>origin<TAB>src_url<TAB>src_sha256<TAB>recipe_sha256, one
# line per package -- used internally by system_set_full/system_unset so a
# rewrite preserves every other package's full record instead of only its
# version (which plain json_pairs, used by apps.json, would silently drop).
system_pairs_full() {
	local file=$FAU_SYSTEM_JSON obj name
	# Anchored on {"version" immediately (same discipline as json_pairs/
	# json_get_version above) so the outer {"packages":{...}} wrapper itself
	# -- especially the degenerate {"packages":{}} of a brand new system.json,
	# which otherwise looks just like a package entry named "packages" -- is
	# never mistaken for one. See fau.md.
	grep -o '"[^"]*"[[:space:]]*:[[:space:]]*{[[:space:]]*"version"[^}]*}' "$file" 2>/dev/null | while IFS= read -r obj; do
		name=$(printf '%s' "$obj" | sed -E 's/^"([^"]*)".*/\1/')
		local version origin src_url src_sha256 recipe_sha256
		version=$(printf '%s' "$obj" | sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
		origin=$(printf '%s' "$obj" | sed -nE 's/.*"origin"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
		src_url=$(printf '%s' "$obj" | sed -nE 's/.*"src_url"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
		src_sha256=$(printf '%s' "$obj" | sed -nE 's/.*"src_sha256"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
		recipe_sha256=$(printf '%s' "$obj" | sed -nE 's/.*"recipe_sha256"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$version" "$origin" "$src_url" "$src_sha256" "$recipe_sha256"
	done
}

_system_write_entry() {
	local name=$1 version=$2 origin=$3 src_url=$4 src_sha256=$5 recipe_sha256=$6
	printf '"%s":{"version":"%s"' "$(json_escape "$name")" "$(json_escape "$version")"
	[ -z "$origin" ]        || printf ',"origin":"%s"' "$(json_escape "$origin")"
	[ -z "$src_url" ]       || printf ',"src_url":"%s"' "$(json_escape "$src_url")"
	[ -z "$src_sha256" ]    || printf ',"src_sha256":"%s"' "$(json_escape "$src_sha256")"
	[ -z "$recipe_sha256" ] || printf ',"recipe_sha256":"%s"' "$(json_escape "$recipe_sha256")"
	printf '}'
}

system_set_full() {
	local name=$1 version=$2 origin=${3:-} src_url=${4:-} src_sha256=${5:-} recipe_sha256=${6:-}
	local tmp; tmp=$(mktemp)
	{
		echo '{"packages":{'
		local first=1 n v o su ss rs
		while IFS=$'\t' read -r n v o su ss rs; do
			[ "$n" = "$name" ] && continue
			[ $first -eq 1 ] || echo ','
			first=0
			_system_write_entry "$n" "$v" "$o" "$su" "$ss" "$rs"
		done < <(system_pairs_full)
		[ $first -eq 1 ] || echo ','
		_system_write_entry "$name" "$version" "$origin" "$src_url" "$src_sha256" "$recipe_sha256"
		echo
		echo '}}'
	} > "$tmp"
	mv "$tmp" "$FAU_SYSTEM_JSON"
}

# Back-compat convenience for any caller that only has a version, no
# provenance to record (e.g. an early manual entry) -- prefer system_set_full
# at every real install/build call site instead.
system_set() { system_set_full "$1" "$2" "" "" "" ""; }

system_unset() {
	local name=$1
	local tmp; tmp=$(mktemp)
	{
		echo '{"packages":{'
		local first=1 n v o su ss rs
		while IFS=$'\t' read -r n v o su ss rs; do
			[ "$n" = "$name" ] && continue
			[ $first -eq 1 ] || echo ','
			first=0
			_system_write_entry "$n" "$v" "$o" "$su" "$ss" "$rs"
		done < <(system_pairs_full)
		echo
		echo '}}'
	} > "$tmp"
	mv "$tmp" "$FAU_SYSTEM_JSON"
}

record_files() {
	local name=$1 src=$2
	(cd "$src" && find . \( -type f -o -type l \) -printf '%P\n') > "$FAU_FILES_DIR/$name"
}

# Per-file sha256 of a system package's staged output, recorded before the
# rsync merge (same content that ends up in FAU_ROOT). Symlinks are skipped
# (sha256sum only hashes regular files) -- record_files' plain path list above
# still owns those for removal purposes. Written in `sha256sum -c`'s own
# input shape so 'fau bootstrap-verify' can just hand this file straight back
# to sha256sum instead of re-deriving comparison logic. See fau.md.
record_file_hashes() {
	local name=$1 src=$2
	# lib/modules/<release>/modules.* is excluded: depmod regenerates this
	# whole set as a single shared index spanning every installed kernel
	# module, not content any one package (linux-lts, nvidia, ...) owns on
	# its own -- installing/rebuilding any other module-shipping package
	# afterward legitimately rewrites these same files again, which
	# 'fau bootstrap-verify' would otherwise report as "drift" on a
	# package that never actually changed. depmod's own exit code (see
	# recipe_post_merge) is the real correctness signal for these, not a
	# per-file hash -- confirmed by watching this exact false-positive
	# happen on a real nvidia.fis build/verify pass, not guessed.
	(cd "$src" && find . -type f -not -path './lib/modules/*/modules.*' -exec sha256sum {} +) \
		| sed 's/  \.\//  /' > "$FAU_FILES_DIR/$name.sha256"
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
