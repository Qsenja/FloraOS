# lib/build.sh -- fau-build's own helpers: fetching a recipe's primary
# upstream source, and merging a recipe's PKG_DEPENDS runtime closure
# straight into the app_dir being built (as opposed to lib/alpm.sh's
# alpm_sandbox_fetch, which is for PKG_BUILD_DEPS -- a throwaway compile-time
# sandbox, headers kept, wiped by the caller when done). See fau-build's own
# header comment for the full recipe-format writeup and why these are two
# genuinely different dependency lifetimes.
#
# Requires lib/common.sh, lib/manifest.sh, and lib/alpm.sh already sourced:
# uses die/log/pkginfo_field/app_wrapper_write/$FAU_ELF_PATCH (common.sh),
# json_set (manifest.sh), and alpm_resolve/alpm_parallel_fetch (alpm.sh).

# build_fetch_source <url> <sha256> -> downloads (if missing) and verifies,
# prints the path to the cached tarball. Cached under
# $FAU_CACHE_DIR/build-sources/, never wiped by fau-build itself -- unlike
# PKG_BUILD_DEPS (a whole compiler/build-tool closure, genuinely worth
# throwing away after each build so the live system doesn't carry it
# permanently), re-downloading the same few hundred KB of source code on
# every single `fau build` of the same recipe would just be wasteful, not a
# meaningful bloat/cleanliness win -- same reasoning fau's own alpm fallback
# already applies to /var/cache/pacman/pkg.
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
	[ "$actual" = "$sha256" ] || { rm -f "$path"; die "checksum mismatch for $(basename "$url"): expected $sha256, got $actual"; }
	echo "$path"
}

# build_extract_source <name> <tarball-path> -> extracts to a fresh
# $FAU_CACHE_DIR/build-sources/extract-<name> (wiped first), returns the
# path to the extracted top-level directory. Live-system counterpart of
# scripts/lib/common.sh's extract_source (build-host-only, not shipped).
build_extract_source() {
	local name=$1 tarball=$2
	local dest="${FAU_CACHE_DIR%/}/build-sources/extract-$name"
	rm -rf "$dest"
	mkdir -p "$dest"
	tar -xf "$tarball" -C "$dest" --strip-components=1
	echo "$dest"
}

# build_merge_depends <app_dir> <name...> -- resolves the combined alpm
# closure of every given name (a recipe's PKG_DEPENDS) and merges it
# straight into <app_dir> -- the actual fix for fau-install's isolated-app
# gap found while designing this: app_install_one (lib/repo.sh's
# depends=) and app_install_one_alpm both install each dependency into its
# OWN separate FAU_APPS_DIR/<dep>/ directory, which a wrapper script's
# LD_LIBRARY_PATH (app_wrapper_write, lib/common.sh) never looks at beyond
# its own app's directory -- a real shared-library runtime dependency
# (e.g. mangowm's own wlroots0.19) would install fine and then fail at
# "cannot open shared object file" the moment it's actually run. Merging
# the whole resolved closure into the SAME app_dir as the built binary
# sidesteps that entirely: app_wrapper_write's LD_LIBRARY_PATH already
# covers app_dir/usr/lib, no separate directory to miss.
#
# Deliberately a near-duplicate of app_install_one_alpm's own
# extract/strip/fauelf/merge loop (lib/alpm.sh) rather than a refactor of
# it: that function is proven, exercised code (fastfetch/kitty/cowsay);
# reusing its exact shape here without touching it avoids any risk of
# regressing it for a need it didn't originally have. Worth unifying into
# one shared function later once this path has its own real mileage.
# strips usr/include (real runtime dependency, never needed to run
# anything -- unlike alpm_sandbox_fetch's PKG_BUILD_DEPS, which keeps
# them), fauelf-patches (same absolute-DT_NEEDED concern as any isolated
# merge), and skips "filesystem" for the same reason install_one_alpm and
# app_install_one_alpm both do. Does NOT skip packages fau's own
# system.json already provides -- unlike those two, whose whole point is
# avoiding a duplicate of something already on FAU_ROOT's real search
# path, an isolated app_dir has no access to FAU_ROOT's search path at
# all (that's the isolation model working as intended for everything
# except this specific gap), so every real runtime dependency has to
# land here regardless of what the base system happens to already have.
build_merge_depends() {
	local app_dir=$1; shift
	[ $# -eq 0 ] && return 0

	local total=0
	local -a pkg_name=() pkg_repo=() pkg_version=() pkg_filename=() pkg_sha256=()
	local -A seen=()
	local name repo pkgname pkgversion filename sha256 resolved
	for name in "$@"; do
		resolved=$(alpm_resolve "$name") \
			|| die "couldn't resolve '$name' in any configured Arch/Artix repo"
		while IFS="$ALPM_FS" read -r repo pkgname pkgversion filename sha256; do
			[ -n "$pkgname" ] || continue
			[ -n "${seen[$pkgname]:-}" ] && continue
			seen[$pkgname]=1
			total=$((total + 1))
			pkg_repo[$total]=$repo; pkg_name[$total]=$pkgname; pkg_version[$total]=$pkgversion
			pkg_filename[$total]=$filename; pkg_sha256[$total]=$sha256
		done <<< "$resolved"
	done

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
		tar --zstd -xf "$archive" -C "$extract_dir"
		rm -f "$archive"
		chmod -R u+rX "$extract_dir"
		rm -f "$extract_dir/.PKGINFO" "$extract_dir/.BUILDINFO" "$extract_dir/.MTREE" "$extract_dir/.INSTALL"
		rm -rf "$extract_dir/usr/include"
		while IFS= read -r -d '' f; do
			"$FAU_ELF_PATCH" "$f" || die "fauelf failed patching $f"
		done < <(find "$extract_dir" -type f -print0)
		cp -a "$extract_dir/." "$app_dir"
		rm -rf "$extract_dir"
	done
	rm -rf "$jobs_dir"
}
