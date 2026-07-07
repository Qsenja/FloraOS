# lib/repo.sh -- fau's own local package repo (FAU_REPO_DIR: .fau.tar.zst
# archives + repo.json index), sourced by fau-repo (repo-add/repo-index
# themselves) and by fau-bootstrap/fau-install (both need to check the
# local repo before falling back to lib/alpm.sh's Arch/Artix path).
#
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
	# repo_lookup_file <name> -> prints archive filename, or nothing if
	# there's no repo index yet or the name isn't in it (not an error here --
	# callers that need a system package to exist check for an empty result
	# themselves; app_install_one falls back to the alpm (Arch/Artix repo) path on an empty result)
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

repo_lookup_depends() {
	local archive=$1
	local work; work=$(mktemp -d)
	tar -I zstd -xf "$archive" -C "$work" pkginfo
	pkginfo_field "$work/pkginfo" depends
	rm -rf "$work"
}

repo_add() {
	local archive=$1
	[ -f "$archive" ] || die "no such archive: $archive"
	mkdir -p "$FAU_REPO_DIR"

	# A repo directory must hold at most one archive per package name --
	# without this, repo_index (which just globs every *.fau.tar.zst) ends up
	# with duplicate keys for the same name after a version bump (the old
	# archive never gets removed on its own), and which one repo_lookup_file
	# resolves to then depends on filesystem glob order, not on which
	# version was actually just added.
	local work; work=$(mktemp -d)
	tar -I zstd -xf "$archive" -C "$work" pkginfo
	local incoming_name; incoming_name=$(pkginfo_field "$work/pkginfo" name)
	rm -rf "$work"
	if [ -n "$incoming_name" ]; then
		local existing existing_name w2
		shopt -s nullglob
		for existing in "$FAU_REPO_DIR"/*.fau.tar.zst; do
			[ "$(basename "$existing")" = "$(basename "$archive")" ] && continue
			w2=$(mktemp -d)
			tar -I zstd -xf "$existing" -C "$w2" pkginfo 2>/dev/null
			existing_name=$(pkginfo_field "$w2/pkginfo" name)
			rm -rf "$w2"
			[ "$existing_name" = "$incoming_name" ] && rm -f "$existing"
		done
		shopt -u nullglob
	fi

	cp "$archive" "$FAU_REPO_DIR/"
	repo_index
}
