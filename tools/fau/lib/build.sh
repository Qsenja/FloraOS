# lib/build.sh -- fau-build's own helpers: source fetch + PKG_DEPENDS merge into app_dir. See fau.md.
# Requires lib/common.sh, lib/manifest.sh, and lib/alpm.sh already sourced.

# Cached under $FAU_CACHE_DIR/build-sources/, never wiped (unlike PKG_BUILD_DEPS) -- see fau.md.
# sha256 empty (not just wrong) means "no pin exists for this download" -- an
# explicit, distinct state from a checksum mismatch, used by `fau build
# <name>=<version>` for a version nobody's pinned a hash for yet (see fau.md's
# "installing a specific version" section). Fetched and used anyway, but
# loudly, not silently -- there's genuinely nothing to verify it against.
build_fetch_source() {
	local url=$1 sha256=$2
	local dir="${FAU_CACHE_DIR%/}/build-sources"
	mkdir -p "$dir"
	local path="$dir/$(basename "$url")"
	if [ ! -f "$path" ]; then
		log "fetching $(basename "$url")"
		curl -sL --fail -o "$path.part" "$url" || die "fetching $url failed"
		mv "$path.part" "$path"
	fi
	local actual; actual=$(sha256sum "$path" | cut -d' ' -f1)
	if [ -n "$sha256" ]; then
		[ "$actual" = "$sha256" ] || { rm -f "$path"; die "checksum mismatch for $(basename "$url"): expected $sha256, got $actual"; }
	else
		log "warning: no pinned checksum for $(basename "$url") -- downloaded UNVERIFIED (sha256: $actual)"
	fi
	echo "$path"
}

# Pulls one member out of a plain `ar` archive by name prefix (the
# extension on a .deb's data.tar.* varies) -- see fau.md.
ar_extract_member_prefix() {
	local archive=$1 prefix=$2 dest=$3
	local offset=8
	local file_size; file_size=$(stat -c%s "$archive")
	while [ "$offset" -lt "$file_size" ]; do
		local header; header=$(dd if="$archive" bs=1M iflag=skip_bytes,count_bytes skip="$offset" count=60 2>/dev/null)
		local name=${header:0:16}
		name=${name%% *}; name=${name%/}
		local size_field=${header:48:10}; size_field=${size_field// /}
		offset=$((offset + 60))
		case "$name" in
			"$prefix"*)
				dd if="$archive" bs=1M iflag=skip_bytes,count_bytes skip="$offset" count="$size_field" of="$dest" 2>/dev/null
				return 0
				;;
		esac
		offset=$((offset + size_field + (size_field % 2)))
	done
	return 1
}

build_extract_source() {
	local name=$1 tarball=$2
	local dest="${FAU_CACHE_DIR%/}/build-sources/extract-$name"
	rm -rf "$dest"
	mkdir -p "$dest"
	case "$tarball" in
		*.deb)
			# Pulls out data.tar.* (dpkg's filesystem payload) and hands it
			# to plain tar -- see fau.md.
			local data_tarball; data_tarball=$(mktemp)
			ar_extract_member_prefix "$tarball" "data.tar" "$data_tarball" \
				|| die "$tarball: no data.tar.* member found inside (not a real .deb?)"
			tar -xf "$data_tarball" -C "$dest"
			rm -f "$data_tarball"
			;;
		*)
			tar -xf "$tarball" -C "$dest" --strip-components=1
			;;
	esac
	echo "$dest"
}

# Merges PKG_DEPENDS' full alpm closure straight into app_dir -- see fau.md for why.
# Near-duplicate of app_install_one_alpm's extract/strip/fauelf/merge loop (lib/alpm.sh),
# not a shared refactor, to avoid touching that proven code path.
build_merge_depends() {
	local app_dir=$1; shift
	[ $# -eq 0 ] && return 0

	local total=0
	local -a pkg_name=() pkg_repo=() pkg_version=() pkg_filename=() pkg_sha256=()
	local -A seen=()
	local repo pkgname pkgversion filename sha256 resolved
	resolved=$(alpm_resolve_many "$@")
	while IFS="$ALPM_FS" read -r repo pkgname pkgversion filename sha256; do
		[ -n "$pkgname" ] || continue
		[ -n "${seen[$pkgname]:-}" ] && continue
		seen[$pkgname]=1
		total=$((total + 1))
		pkg_repo[$total]=$repo; pkg_name[$total]=$pkgname; pkg_version[$total]=$pkgversion
		pkg_filename[$total]=$filename; pkg_sha256[$total]=$sha256
	done <<< "$resolved"

	local jobs_dir; jobs_dir=$(mktemp -d)
	local -a queue=()
	local i; for i in $(seq 1 "$total"); do
		local pkgname_i=${pkg_name[$i]}
		[ "$pkgname_i" = "filesystem" ] && continue
		[ -n "$(system_get_version "$pkgname_i")" ] && continue
		queue+=("$i")
	done
	alpm_parallel_fetch "$jobs_dir" 4 "${queue[@]}"

	for i in "${queue[@]}"; do
		local archive="$jobs_dir/$i.pkg"
		[ -f "$archive" ] || die "fetching ${pkg_name[$i]} failed (see errors above)"
		local extract_dir; extract_dir=$(mktemp -d)
		tar_extract_or_die "$archive" "$extract_dir" "${pkg_name[$i]}"
		rm -f "$archive"
		chmod -R u+rX "$extract_dir"
		rm -f "$extract_dir/.PKGINFO" "$extract_dir/.BUILDINFO" "$extract_dir/.MTREE" "$extract_dir/.INSTALL"
		rm -rf "$extract_dir/usr/include"
		find "$extract_dir" -type f -print0 | xargs -0 -r "$FAU_ELF_PATCH" || die "fauelf failed patching files under $extract_dir"
		cp -a "$extract_dir/." "$app_dir"
		rm -rf "$extract_dir"
	done
	rm -rf "$jobs_dir"
}
