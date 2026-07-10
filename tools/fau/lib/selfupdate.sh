# lib/selfupdate.sh -- per-file granular update for FloraOS's own tools/fau
# tree, the 5 compiled C tools, and floragrub-cfg. Each tracked file is
# swapped independently, keyed on its own git blob sha (from GitHub's Trees
# API), not bundled into one version/one rebuild -- see fau.md's "fau
# update also sweeps base system packages" section for why. Requires
# lib/common.sh, lib/alpm.sh, lib/recipes.sh already sourced.

FAU_SELFUPDATE_REPO="${FAU_SELFUPDATE_REPO-https://github.com/Qsenja/FloraOS}"
FAU_SELFUPDATE_BRANCH="${FAU_SELFUPDATE_BRANCH:-main}"
FAU_INSTALLED_MANIFEST="${FAU_INSTALLED_MANIFEST:-${FAU_ROOT%/}/etc/fau/installed-manifest}"

# The one static piece of knowledge this needs: which repo paths are part
# of the running system, and where/how each lands. Versioning itself is
# NOT hardcoded here -- git's own blob sha (floraos_tree_listing) is the
# only signal for "did this file change," so adding a new bash subtool
# under tools/fau/ needs a line here, but never a version bump anywhere.
_floraos_tracked_paths() {
	cat <<-'EOF'
	tools/fau/fau
	tools/fau/fau-backup
	tools/fau/fau-bootstrap
	tools/fau/fau-build
	tools/fau/fau-export
	tools/fau/fau-install
	tools/fau/fau-repo
	tools/fau/fau-seat
	tools/fau/fau-service
	tools/fau/fau-user
	tools/fau/lib/common.sh
	tools/fau/lib/alpm.sh
	tools/fau/lib/build.sh
	tools/fau/lib/manifest.sh
	tools/fau/lib/recipes.sh
	tools/fau/lib/repo.sh
	tools/fau/lib/selfupdate.sh
	tools/fauelf/fauelf.c
	tools/floralogin/floralogin.c
	tools/florauser/florauser.c
	tools/florainstall/florainstall.c
	tools/floraseat/floraseat.c
	tools/floragrub-cfg/floragrub-cfg
	EOF
}

# Destination under FAU_ROOT for a tracked path -- mirrors build-rootfs.sh's
# own layout exactly (usr/lib/fau/ + usr/bin/, see its "fau (dispatcher +
# fau-* tools + lib/*.sh) ships in the OS itself" step).
_floraos_dest_for() {
	case "$1" in
		tools/fau/lib/*.sh) echo "usr/lib/fau/lib/$(basename "$1")" ;;
		tools/fau/fau|tools/fau/fau-*) echo "usr/lib/fau/$(basename "$1")" ;;
		tools/fauelf/fauelf.c) echo "usr/bin/fauelf" ;;
		tools/floralogin/floralogin.c) echo "usr/bin/floralogin" ;;
		tools/florauser/florauser.c) echo "usr/bin/florauser" ;;
		tools/florainstall/florainstall.c) echo "usr/bin/florainstall" ;;
		tools/floraseat/floraseat.c) echo "usr/bin/floraseat" ;;
		tools/floragrub-cfg/floragrub-cfg) echo "usr/bin/floragrub-cfg" ;;
		*) return 1 ;;
	esac
}

# Extra link flags for a .c tracked path, same as build-rootfs.sh's own gcc
# invocations for each -- empty for the plain-copy (bash) paths.
_floraos_compile_libs_for() {
	case "$1" in
		tools/floralogin/floralogin.c) echo "-lcrypt" ;;
		tools/florauser/florauser.c) echo "-lcrypt" ;;
		tools/florainstall/florainstall.c) echo "-lncursesw -lmenuw" ;;
		*) echo "" ;;
	esac
}

# Prints "path<TAB>blob-sha" for every tracked path currently on
# FAU_SELFUPDATE_BRANCH -- one GitHub Trees API request, not one per file.
# Pretty-printed JSON (confirmed against a real response, not assumed):
# path/mode/type/sha/size/url each on their own line, so a stateful
# path-then-type-then-sha awk pass is enough, no real JSON parser needed --
# same "hand-rolled, no jq" convention lib/manifest.sh's json_get_version
# already uses. type=="tree" (a directory entry) is skipped; only
# type=="blob" (an actual file) is emitted.
floraos_tree_listing() {
	[ -n "${FAU_SELFUPDATE_REPO:-}" ] || return 1
	local api_base; api_base=${FAU_SELFUPDATE_REPO/github.com\//api.github.com\/repos\/}
	local tmp; tmp=$(mktemp)
	if ! curl -sL --fail -H 'Accept: application/vnd.github+json' \
		-o "$tmp" "$api_base/git/trees/$FAU_SELFUPDATE_BRANCH?recursive=1" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	awk '
		/"path": "/ {
			path = $0
			sub(/^[[:space:]]*"path": "/, "", path)
			sub(/",?$/, "", path)
			type = ""
			next
		}
		/"type": "/ {
			type = $0
			sub(/^[[:space:]]*"type": "/, "", type)
			sub(/",?$/, "", type)
			next
		}
		/"sha": "/ && path != "" {
			if (type == "blob") {
				sha = $0
				sub(/^[[:space:]]*"sha": "/, "", sha)
				sub(/",?$/, "", sha)
				print path "\t" sha
			}
			path = ""
		}
	' "$tmp"
	rm -f "$tmp"
}

_floraos_manifest_sha_for() {
	[ -f "$FAU_INSTALLED_MANIFEST" ] || return 0
	awk -F'\t' -v p="$1" '$1==p{print $2}' "$FAU_INSTALLED_MANIFEST"
}

# Small (~22 lines), rewritten whole on every call -- not the O(n^2)
# concern lib/manifest.sh's json_set fix addressed, at this scale.
_floraos_manifest_set() {
	local path=$1 sha=$2
	mkdir -p "$(dirname "$FAU_INSTALLED_MANIFEST")"
	touch "$FAU_INSTALLED_MANIFEST"
	local tmp; tmp=$(mktemp)
	awk -F'\t' -v p="$path" '$1!=p' "$FAU_INSTALLED_MANIFEST" > "$tmp"
	printf '%s\t%s\n' "$path" "$sha" >> "$tmp"
	sort -o "$tmp" "$tmp"
	mv "$tmp" "$FAU_INSTALLED_MANIFEST"
}

# Compiles one fetched .c source into its real destination, using a
# throwaway gcc sandbox (same alpm_sandbox_fetch pattern `fau
# build`/`fau bootstrap-build` already use) -- never a permanently
# installed compiler. $sandbox_dir is fetched by the caller once per sweep,
# not once per file.
_floraos_compile_and_install() {
	local path=$1 src_file=$2 dest_abs=$3 sandbox_dir=$4
	local libs; libs=$(_floraos_compile_libs_for "$path")
	local tmp_bin; tmp_bin=$(mktemp)
	# -x c: $src_file is a plain mktemp path with no .c suffix, gcc/ld only
	# infer "this is C source" from the file extension otherwise -- without
	# this, ld gets handed the raw source text as if it were an object file
	# ("file format not recognized; treating as linker script").
	# shellcheck disable=SC2086
	PATH="$sandbox_dir/usr/bin:$PATH" \
	LD_LIBRARY_PATH="$sandbox_dir/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		gcc -Wall -Wextra -O2 \
			-I"${FAU_ROOT%/}/usr/include" -L"${FAU_ROOT%/}/usr/lib" \
			-o "$tmp_bin" -x c "$src_file" $libs \
		|| { rm -f "$tmp_bin"; die "$path: compiling failed (see errors above)"; }
	chmod 755 "$tmp_bin"
	mkdir -p "$(dirname "$dest_abs")"
	mv "$tmp_bin" "$dest_abs"
}

# Split into check/apply (used to be one combined "sweep") so `fau update`
# can show every pending change -- packages and FloraOS's own files alike --
# in one list before asking to proceed, pacman -Syu style. See fau.md.

# Cheap half: fetch the tree listing once, diff every tracked path against
# FAU_INSTALLED_MANIFEST. No file content is fetched and nothing is
# compiled here -- just enough to know *what* would change. Sets
# $FLORAOS_SELFUPDATE_PENDING (array of "path:sha" entries). Returns 0 even
# if nothing changed; 1 if the tree listing itself couldn't be fetched
# (offline).
floraos_selfupdate_check() {
	FLORAOS_SELFUPDATE_PENDING=()
	local listing; listing=$(floraos_tree_listing) || {
		log "warning: couldn't check FloraOS's own repo for updates (offline?)"
		return 1
	}

	local path
	while IFS= read -r path; do
		local remote_sha; remote_sha=$(printf '%s\n' "$listing" | awk -F'\t' -v p="$path" '$1==p{print $2}')
		[ -n "$remote_sha" ] || continue
		local local_sha; local_sha=$(_floraos_manifest_sha_for "$path")
		[ "$remote_sha" = "$local_sha" ] && continue
		FLORAOS_SELFUPDATE_PENDING+=("$path:$remote_sha")
	done < <(_floraos_tracked_paths)
	return 0
}

# Expensive half: actually fetches/compiles/swaps every entry in
# $FLORAOS_SELFUPDATE_PENDING (as left by floraos_selfupdate_check, or set
# directly by a caller). Sets $FLORAOS_SELFUPDATE_CHANGED to how many
# files actually got updated.
floraos_selfupdate_apply() {
	FLORAOS_SELFUPDATE_CHANGED=0
	[ "${#FLORAOS_SELFUPDATE_PENDING[@]}" -gt 0 ] || return 0

	# gcc is only fetched if at least one of the changed paths is a .c
	# source -- a run that only touches bash files never pays for it.
	local need_gcc=0 entry
	for entry in "${FLORAOS_SELFUPDATE_PENDING[@]}"; do
		case "${entry%%:*}" in *.c) need_gcc=1 ;; esac
	done
	# Deliberately NOT `local` -- the EXIT trap below can fire after this
	# function returns (same real bug fau-build/fau-bootstrap's own
	# sandbox_dir comments document; see fau.md).
	sandbox_dir=""
	if [ "$need_gcc" -eq 1 ]; then
		sandbox_dir=$(mktemp -d)
		trap 'rm -rf "$sandbox_dir"' EXIT
		log "fetching gcc into a throwaway sandbox (at least one changed file needs recompiling)"
		alpm_sandbox_fetch "$sandbox_dir" gcc
	fi

	local raw_base; raw_base=${FAU_SELFUPDATE_REPO/github.com/raw.githubusercontent.com}/${FAU_SELFUPDATE_BRANCH}

	local path
	for entry in "${FLORAOS_SELFUPDATE_PENDING[@]}"; do
		path=${entry%%:*}
		local sha=${entry#*:}
		local dest_rel; dest_rel=$(_floraos_dest_for "$path") || { log "warning: no destination mapping for tracked path $path, skipping"; continue; }
		local dest_abs="${FAU_ROOT%/}/$dest_rel"

		local fetched; fetched=$(mktemp)
		if ! curl -sL --fail -o "$fetched" "$raw_base/$path" 2>/dev/null; then
			rm -f "$fetched"
			log "warning: fetching $path from $FAU_SELFUPDATE_REPO failed, skipping this file for now"
			continue
		fi

		case "$path" in
			*.c)
				_floraos_compile_and_install "$path" "$fetched" "$dest_abs" "$sandbox_dir"
				rm -f "$fetched"
				log "$path: recompiled and installed -> $dest_rel"
				;;
			*)
				mkdir -p "$(dirname "$dest_abs")"
				chmod 755 "$fetched"
				mv "$fetched" "$dest_abs"
				log "$path: updated -> $dest_rel"
				;;
		esac

		_floraos_manifest_set "$path" "$sha"
		FLORAOS_SELFUPDATE_CHANGED=$((FLORAOS_SELFUPDATE_CHANGED + 1))
	done

	if [ "$FLORAOS_SELFUPDATE_CHANGED" -gt 0 ]; then
		# Cosmetic only, for `fau list`/fastfetch -- the real per-file
		# state lives in FAU_INSTALLED_MANIFEST, not this one string.
		system_set "fau" "$(date -u +%Y%m%d.%H%M%S)"
	fi
}
