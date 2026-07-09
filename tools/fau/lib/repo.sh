# lib/repo.sh -- the local .fau.tar.zst repo (repo_json/repo_index/...). See fau.md.
# Requires lib/common.sh already sourced (die/log/json_escape/pkginfo_field).

repo_json() { echo "${FAU_REPO_DIR%/}/repo.json"; }

repo_index() {
	local repo; repo=$(repo_json)
	mkdir -p "$FAU_REPO_DIR"
	local tmp; tmp=$(mktemp)
	{
		echo '{"packages":{'
		local first=1
		shopt -s nullglob
		for archive in "$FAU_REPO_DIR"/*.fau.tar.zst; do
			local work; work=$(mktemp -d)
			tar -I zstd -xf "$archive" -C "$work" pkginfo
			local name version sha
			name=$(pkginfo_field "$work/pkginfo" name)
			version=$(pkginfo_field "$work/pkginfo" version)
			sha=$(sha256sum "$archive" | cut -d' ' -f1)
			rm -rf "$work"
			[ $first -eq 1 ] || echo ','
			first=0
			printf '"%s":{"version":"%s","file":"%s","sha256":"%s"}' \
				"$(json_escape "$name")" "$(json_escape "$version")" \
				"$(json_escape "$(basename "$archive")")" "$sha"
		done
		echo
		echo '}}'
	} > "$tmp"
	mv "$tmp" "$repo"
	log "indexed $(basename "$FAU_REPO_DIR")"
}

repo_lookup_file() {
	local name=$1 repo; repo=$(repo_json)
	[ -f "$repo" ] || return 0
	awk -v n="\"$name\"" '
		index($0, n":{") { in_pkg=1 }
		in_pkg && match($0, /"file":"[^"]*"/) {
			s = substr($0, RSTART, RLENGTH)
			sub(/"file":"/, "", s); sub(/"$/, "", s)
			print s; exit
		}
	' "$repo"
}

repo_lookup_version() {
	local name=$1 repo; repo=$(repo_json)
	[ -f "$repo" ] || return 0
	awk -v n="\"$name\"" '
		index($0, n":{") { in_pkg=1 }
		in_pkg && match($0, /"version":"[^"]*"/) {
			s = substr($0, RSTART, RLENGTH)
			sub(/"version":"/, "", s); sub(/"$/, "", s)
			print s; exit
		}
	' "$repo"
}

repo_lookup_depends() {
	local archive=$1
	local work; work=$(mktemp -d)
	tar -I zstd -xf "$archive" -C "$work" pkginfo
	pkginfo_field "$work/pkginfo" depends
	rm -rf "$work"
}

# name<TAB>version<TAB>file<TAB>sha256 for every entry in one grep+sed pass --
# used by repo_set instead of extracting pkginfo from every OTHER archive on
# disk just to add or replace one. See fau.md.
repo_pairs() {
	local file=$1
	[ -f "$file" ] || return 0
	grep -oE '"[^"]*":\{"version":"[^"]*","file":"[^"]*","sha256":"[^"]*"\}' "$file" 2>/dev/null \
		| sed -E 's/^"([^"]*)":\{"version":"([^"]*)","file":"([^"]*)","sha256":"([^"]*)"\}/\1\t\2\t\3\t\4/'
}

repo_set() {
	local file=$1 name=$2 version=$3 pkgfile=$4 sha=$5
	local tmp; tmp=$(mktemp)
	{
		echo '{"packages":{'
		local first=1 n v f s
		while IFS=$'\t' read -r n v f s; do
			[ "$n" = "$name" ] && continue
			[ $first -eq 1 ] || echo ','
			first=0
			printf '"%s":{"version":"%s","file":"%s","sha256":"%s"}' \
				"$(json_escape "$n")" "$(json_escape "$v")" "$(json_escape "$f")" "$(json_escape "$s")"
		done < <(repo_pairs "$file")
		[ $first -eq 1 ] || echo ','
		printf '"%s":{"version":"%s","file":"%s","sha256":"%s"}' \
			"$(json_escape "$name")" "$(json_escape "$version")" "$(json_escape "$pkgfile")" "$(json_escape "$sha")"
		echo
		echo '}}'
	} > "$tmp"
	mv "$tmp" "$file"
}

repo_add() {
	local archive=$1
	[ -f "$archive" ] || die "no such archive: $archive"
	mkdir -p "$FAU_REPO_DIR"

	local work; work=$(mktemp -d)
	tar -I zstd -xf "$archive" -C "$work" pkginfo
	local incoming_name incoming_version
	incoming_name=$(pkginfo_field "$work/pkginfo" name)
	incoming_version=$(pkginfo_field "$work/pkginfo" version)
	rm -rf "$work"

	# At most one archive per package name is kept -- see fau.md's Repo
	# section. The old archive's filename comes from the existing repo.json
	# (already indexed by name) instead of re-extracting pkginfo from every
	# other archive on disk just to find it.
	local repo; repo=$(repo_json)
	if [ -n "$incoming_name" ] && [ -f "$repo" ]; then
		local old_file; old_file=$(repo_lookup_file "$incoming_name")
		if [ -n "$old_file" ] && [ "$old_file" != "$(basename "$archive")" ]; then
			rm -f "${FAU_REPO_DIR%/}/$old_file"
		fi
	fi

	cp "$archive" "$FAU_REPO_DIR/"
	local sha; sha=$(sha256sum "$archive" | cut -d' ' -f1)
	[ -f "$repo" ] || printf '{"packages":{\n}}\n' > "$repo"
	repo_set "$repo" "$incoming_name" "$incoming_version" "$(basename "$archive")" "$sha"
	log "added $(basename "$archive") to $(basename "$FAU_REPO_DIR")"
}
