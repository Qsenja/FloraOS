# lib/alpm.sh -- the whole Arch/Artix fallback + dependency resolution engine, no pacman binary. See fau.md.
# Requires lib/common.sh and lib/manifest.sh already sourced.

alpm_mirrorlist_path() {
	local candidate
	for candidate in /etc/pacman.d/mirrorlist "${FAU_ROOT%/}/etc/fau/pacman-mirrorlist"; do
		[ -f "$candidate" ] && { echo "$candidate"; return 0; }
	done
	return 1
}

alpm_repo_list_path() {
	local candidate
	for candidate in /etc/pacman.conf "${FAU_ROOT%/}/etc/fau/pacman-repos"; do
		[ -f "$candidate" ] && { echo "$candidate"; return 0; }
	done
	return 1
}

alpm_fallback_available() {
	alpm_mirrorlist_path >/dev/null 2>&1 && alpm_repo_list_path >/dev/null 2>&1
}

alpm_repo_names() {
	# Priority order matters: first repo with a given name wins, same as pacman.conf's section ordering.
	local f; f=$(alpm_repo_list_path) || die "no pacman mirrorlist/repo-list available"
	case "$(basename "$f")" in
		pacman.conf) grep -oE '^\[[a-zA-Z0-9_.-]+\]' "$f" | tr -d '[]' | grep -vx options ;;
		*) grep -vE '^[[:space:]]*(#|$)' "$f" ;;
	esac
}

alpm_mirror_urls() {
	local repo=$1 filename=$2
	local mirrorlist; mirrorlist=$(alpm_mirrorlist_path) || die "no pacman mirrorlist available"
	local arch; arch=$(uname -m)
	local tmpl
	grep '^Server' "$mirrorlist" | sed 's/^Server[[:space:]]*=[[:space:]]*//' | while IFS= read -r tmpl; do
		tmpl=${tmpl//\$repo/$repo}
		tmpl=${tmpl//\$arch/$arch}
		echo "$tmpl/$filename"
	done
}

draw_count_bar() {
	local done=$1 total=$2 suffix=$3 width=30
	local pct=100 filled=$width
	if [ "$total" -gt 0 ]; then
		pct=$(( done * 100 / total ))
		filled=$(( pct * width / 100 ))
	fi
	local bar; bar=$(printf '%*s' "$filled" '' | tr ' ' '=')
	local pad; pad=$(printf '%*s' "$((width - filled))" '')
	printf '\r[%s>%s] %d%% (%d/%d)%s' "$bar" "$pad" "$pct" "$done" "$total" "$suffix" >&2
}

curl_fetch_with_bar() {
	local url=$1 dest=$2
	local total; total=$(curl -fsIL "$url" 2>/dev/null | tr -d '\r' \
		| awk 'tolower($0) ~ /^content-length:/ {print $2; exit}')
	case "$total" in ''|*[!0-9]*|0) curl -fsL -o "$dest" "$url"; return $? ;; esac

	curl -fsL -o "$dest" "$url" &
	local pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		local have; have=$(stat -c%s "$dest" 2>/dev/null || echo 0)
		[ "$have" -gt "$total" ] && have=$total
		draw_count_bar "$have" "$total" ""
		sleep 0.2
	done
	wait "$pid"; local rc=$?
	[ "$rc" -eq 0 ] && draw_count_bar "$total" "$total" ""
	echo >&2
	return "$rc"
}

alpm_fetch() {
	# Tries every configured mirror in order before giving up -- see fau.md for the real dead-mirror bug this fixes.
	local repo=$1 filename=$2 dest=$3 quiet=${4:-}
	local urls; urls=$(alpm_mirror_urls "$repo" "$filename")
	[ -n "$urls" ] || die "no Server= line found in the mirrorlist for $repo/$filename"
	local url
	while IFS= read -r url; do
		if [ -n "$quiet" ]; then
			curl -fsL -o "$dest" "$url" && return 0
		else
			curl_fetch_with_bar "$url" "$dest" && return 0
		fi
		log "mirror failed, trying next one: $url"
	done <<< "$urls"
	die "failed to fetch $filename from every configured mirror for $repo"
}

alpm_db_cache_dir() {
	local d; d="${FAU_CACHE_DIR%/}/alpm-db"
	mkdir -p "$d"
	echo "$d"
}

alpm_fetch_repo_db() {
	# force: skip both the already-cached-skip fast path below AND the
	# build-host-local-pacman-db shortcut -- always a real network fetch from
	# the configured mirrors. Used by alpm_refresh_dbs (`fau update`'s own
	# entry point) -- see fau.md for why a version-check specifically must
	# never take either shortcut, unlike every other alpm_fetch_repo_db caller.
	local repo=$1 force=${2:-}
	local cache_dir; cache_dir=$(alpm_db_cache_dir)
	local dest="$cache_dir/$repo.db"
	if [ -n "$force" ] || [ ! -s "$dest" ]; then
		if [ -z "$force" ] && [ -r "/var/lib/pacman/sync/$repo.db" ]; then
			cp "/var/lib/pacman/sync/$repo.db" "$dest"
		else
			log "fetching $repo.db..."
			alpm_fetch "$repo" "$repo.db" "$dest.part"
			mv "$dest.part" "$dest"
		fi
	fi
	echo "$dest"
}

# Forces a real network re-fetch of every configured repo's sync db (and,
# by deleting the derived indexes too, a rebuild of those against the fresh
# db) -- see alpm_fetch_repo_db's own force path above. `fau update`'s whole
# job is noticing a newer upstream version; resolving against whatever's
# already sitting in the cache (however old, or copied from this build
# host's own /var/lib/pacman/sync at some unrelated earlier point) could
# never show that. See fau.md.
alpm_refresh_dbs() {
	alpm_fallback_available || die "no pacman mirrorlist/repo-list available -- can't check for updates"
	local cache_dir; cache_dir=$(alpm_db_cache_dir)
	local repo
	for repo in $(alpm_repo_names); do
		rm -f "$cache_dir/$repo.db" "$cache_dir/$repo.index" "$cache_dir/$repo.provides.index"
		alpm_fetch_repo_db "$repo" force >/dev/null
	done
}

# Unit separator, not a tab -- a tab-delimited version silently corrupted on empty fields (see fau.md).
ALPM_FS=$'\x1f'

alpm_repo_index() {
	# Index line shape: name<FS>version<FS>depends<FS>provides<FS>filename<FS>sha256 (FS = $ALPM_FS).
	local repo=$1
	local cache_dir; cache_dir=$(alpm_db_cache_dir)
	local index="$cache_dir/$repo.index"
	if [ ! -s "$index" ]; then
		local db; db=$(alpm_fetch_repo_db "$repo")
		log "indexing $repo (first run only, several thousand packages)..."
		local work; work=$(mktemp -d)
		tar -xzf "$db" -C "$work"
		local tmp; tmp=$(mktemp)
		awk -v ofs="$ALPM_FS" '
			function emit() {
				if (name != "") {
					printf "%s%s%s%s%s%s%s%s%s%s%s\n", \
						name, ofs, version, ofs, depends, ofs, provides, ofs, filename, ofs, sha256
				}
			}
			FNR==1 { emit(); name=""; version=""; depends=""; provides=""; filename=""; sha256=""; field="" }
			/^%NAME%$/      { field="NAME"; next }
			/^%VERSION%$/   { field="VERSION"; next }
			/^%FILENAME%$/  { field="FILENAME"; next }
			/^%SHA256SUM%$/ { field="SHA256SUM"; next }
			/^%DEPENDS%$/   { field="DEPENDS"; next }
			/^%PROVIDES%$/  { field="PROVIDES"; next }
			/^%/            { field=""; next }
			/^$/            { field=""; next }
			field=="NAME"      { name=$0 }
			field=="VERSION"   { version=$0 }
			field=="FILENAME"  { filename=$0 }
			field=="SHA256SUM" { sha256=$0 }
			field=="DEPENDS"   { depends = (depends=="" ? $0 : depends","$0) }
			field=="PROVIDES"  { provides = (provides=="" ? $0 : provides","$0) }
			END { emit() }
		' "$work"/*/desc > "$tmp"
		mv "$tmp" "$index"
		rm -rf "$work"
	fi
	echo "$index"
}

alpm_repo_provides_index() {
	# Keyed by provided (virtual/soname) name: provname<FS>provver<FS>name<FS>version<FS>depends<FS>filename<FS>sha256.
	local repo=$1
	local cache_dir; cache_dir=$(alpm_db_cache_dir)
	local index; index=$(alpm_repo_index "$repo")
	local pindex="$cache_dir/$repo.provides.index"
	if [ ! -s "$pindex" ]; then
		local tmp; tmp=$(mktemp)
		awk -F"$ALPM_FS" -v ofs="$ALPM_FS" '
			{
				name=$1; version=$2; depends=$3; provides=$4; filename=$5; sha256=$6
				if (provides == "") next
				n = split(provides, parts, ",")
				for (i = 1; i <= n; i++) {
					p = parts[i]
					if (p == "") continue
					eq = index(p, "=")
					if (eq > 0) { pname = substr(p, 1, eq - 1); pver = substr(p, eq + 1) }
					else        { pname = p; pver = "" }
					if (pname == "") continue
					printf "%s%s%s%s%s%s%s%s%s%s%s%s%s\n", \
						pname, ofs, pver, ofs, name, ofs, version, ofs, depends, ofs, filename, ofs, sha256
				}
			}
		' "$index" > "$tmp"
		mv "$tmp" "$pindex"
	fi
	echo "$pindex"
}

# Version comparison (rpmvercmp-derived) -- verified against real vercmp, see fau.md.

_rpmvercmp() {
	local a=$1 b=$2
	[ "$a" = "$b" ] && { echo 0; return; }

	while [ -n "$a" ] || [ -n "$b" ]; do
		while [ -n "$a" ]; do
			case "${a:0:1}" in
				[A-Za-z0-9~]) break ;;
				*) a=${a:1} ;;
			esac
		done
		while [ -n "$b" ]; do
			case "${b:0:1}" in
				[A-Za-z0-9~]) break ;;
				*) b=${b:1} ;;
			esac
		done

		if [ "${a:0:1}" = "~" ] || [ "${b:0:1}" = "~" ]; then
			if [ "${a:0:1}" != "~" ]; then echo 1; return; fi
			if [ "${b:0:1}" != "~" ]; then echo -1; return; fi
			a=${a:1}; b=${b:1}
			continue
		fi

		if [ -z "$a" ] || [ -z "$b" ]; then break; fi

		local seg_a="" seg_b="" isnum=0
		if [[ "${a:0:1}" =~ [0-9] ]]; then
			isnum=1
			while [[ -n "${a:0:1}" && "${a:0:1}" =~ [0-9] ]]; do seg_a="$seg_a${a:0:1}"; a=${a:1}; done
			while [[ -n "${b:0:1}" && "${b:0:1}" =~ [0-9] ]]; do seg_b="$seg_b${b:0:1}"; b=${b:1}; done
		else
			while [[ -n "${a:0:1}" && "${a:0:1}" =~ [A-Za-z] ]]; do seg_a="$seg_a${a:0:1}"; a=${a:1}; done
			while [[ -n "${b:0:1}" && "${b:0:1}" =~ [A-Za-z] ]]; do seg_b="$seg_b${b:0:1}"; b=${b:1}; done
		fi

		if [ -z "$seg_b" ]; then
			if [ -z "$seg_a" ]; then continue; fi
			if [ "$isnum" -eq 1 ]; then echo 1; else echo -1; fi
			return
		fi
		if [ -z "$seg_a" ]; then echo -1; return; fi

		if [ "$isnum" -eq 1 ]; then
			seg_a=$(printf '%s' "$seg_a" | sed 's/^0*//')
			seg_b=$(printf '%s' "$seg_b" | sed 's/^0*//')
			if [ "${#seg_a}" -gt "${#seg_b}" ]; then echo 1; return; fi
			if [ "${#seg_b}" -gt "${#seg_a}" ]; then echo -1; return; fi
		fi

		if [ "$seg_a" != "$seg_b" ]; then
			if [[ "$seg_a" < "$seg_b" ]]; then echo -1; else echo 1; fi
			return
		fi
	done

	if [ -z "$a" ] && [ -z "$b" ]; then echo 0; return; fi
	if [ -z "$a" ]; then echo -1; else echo 1; fi
}

alpm_vercmp() {
	# Format: [epoch:]pkgver[-pkgrel] -> -1, 0, or 1
	local v1=$1 v2=$2
	[ "$v1" = "$v2" ] && { echo 0; return; }

	local e1 e2 pv1 pv2 pr1 pr2
	case "$v1" in *:*) e1=${v1%%:*}; pv1=${v1#*:} ;; *) e1=0; pv1=$v1 ;; esac
	case "$v2" in *:*) e2=${v2%%:*}; pv2=${v2#*:} ;; *) e2=0; pv2=$v2 ;; esac

	if [ "$e1" != "$e2" ]; then
		if [ "$e1" -gt "$e2" ] 2>/dev/null; then echo 1; else echo -1; fi
		return
	fi

	case "$pv1" in *-*) pr1=${pv1##*-}; pv1=${pv1%-*} ;; *) pr1="" ;; esac
	case "$pv2" in *-*) pr2=${pv2##*-}; pv2=${pv2%-*} ;; *) pr2="" ;; esac

	local cmp; cmp=$(_rpmvercmp "$pv1" "$pv2")
	if [ "$cmp" -ne 0 ]; then echo "$cmp"; return; fi

	if [ -n "$pr1" ] && [ -n "$pr2" ]; then
		_rpmvercmp "$pr1" "$pr2"
		return
	fi
	echo 0
}

version_satisfies_alpm() {
	local installed=$1 op=$2 required=$3
	[ -z "$op" ] && return 0
	local cmp; cmp=$(alpm_vercmp "$installed" "$required")
	case "$op" in
		'<') [ "$cmp" -lt 0 ] ;;
		'<=') [ "$cmp" -le 0 ] ;;
		'='|'==') [ "$cmp" -eq 0 ] ;;
		'>=') [ "$cmp" -ge 0 ] ;;
		'>') [ "$cmp" -gt 0 ] ;;
		*) return 0 ;;
	esac
}

alpm_dep_parse() {
	# Longer operators (>=, <=) must be checked before the bare >/< they contain as a substring.
	local dep=$1
	case "$dep" in
		*'>='*) printf "%s${ALPM_FS}%s${ALPM_FS}%s\n" "${dep%%>=*}" '>=' "${dep#*>=}" ;;
		*'<='*) printf "%s${ALPM_FS}%s${ALPM_FS}%s\n" "${dep%%<=*}" '<=' "${dep#*<=}" ;;
		*'='*)  printf "%s${ALPM_FS}%s${ALPM_FS}%s\n" "${dep%%=*}" '=' "${dep#*=}" ;;
		*'>'*)  printf "%s${ALPM_FS}%s${ALPM_FS}%s\n" "${dep%%>*}" '>' "${dep#*>}" ;;
		*'<'*)  printf "%s${ALPM_FS}%s${ALPM_FS}%s\n" "${dep%%<*}" '<' "${dep#*<}" ;;
		*) printf "%s${ALPM_FS}${ALPM_FS}\n" "$dep" ;;
	esac
}

# --- dependency resolution (PROVIDES + version-aware, no pacman binary) -----

alpm_find_provider() {
	local want=$1 op=$2 ver=$3
	local repo index line
	for repo in $(alpm_repo_names); do
		index=$(alpm_repo_index "$repo")
		# Both branches must emit the same 6-field shape -- a mismatch here misaligns every field for the caller (see fau.md).
		line=$(awk -F"$ALPM_FS" -v n="$want" -v fs="$ALPM_FS" \
			'$1==n{print $1 fs $2 fs $3 fs $5 fs $6; exit}' "$index")
		[ -z "$line" ] && continue
		local pver; pver=$(printf '%s' "$line" | cut -d "$ALPM_FS" -f2)
		if version_satisfies_alpm "$pver" "$op" "$ver"; then
			printf "%s${ALPM_FS}%s\n" "$repo" "$line"
			return 0
		fi
	done
	for repo in $(alpm_repo_names); do
		local pindex; pindex=$(alpm_repo_provides_index "$repo")
		local matches; matches=$(awk -F"$ALPM_FS" -v n="$want" '$1==n' "$pindex")
		[ -z "$matches" ] && continue
		local prov_ver name version depends filename sha256
		while IFS="$ALPM_FS" read -r _ prov_ver name version depends filename sha256; do
			[ -z "$name" ] && continue
			if [ -z "$op" ] && [ -n "$prov_ver" ] || version_satisfies_alpm "$prov_ver" "$op" "$ver"; then
				printf "%s${ALPM_FS}%s${ALPM_FS}%s${ALPM_FS}%s${ALPM_FS}%s${ALPM_FS}%s\n" \
					"$repo" "$name" "$version" "$depends" "$filename" "$sha256"
				return 0
			fi
		done <<< "$matches"
	done
	return 1
}

_alpm_resolve_one() {
	# Dependencies before dependents; a failure deeper in the tree is logged and skipped, not propagated (see fau.md).
	local spec=$1 seen_file=$2 out_file=$3
	local name op ver
	IFS="$ALPM_FS" read -r name op ver <<< "$(alpm_dep_parse "$spec")"

	grep -qxF "$name" "$seen_file" 2>/dev/null && return 0

	local found
	found=$(alpm_find_provider "$name" "$op" "$ver") || return 1
	local repo pname pversion pdepends pfilename psha256
	IFS="$ALPM_FS" read -r repo pname pversion pdepends pfilename psha256 <<< "$found"

	echo "$name" >> "$seen_file"
	printf '\rfau: resolving dependencies... %-40s' "$(wc -l < "$seen_file") found (latest: $pname)" >&2
	# Also track the *resolved* name, not just the spec name -- a virtual alias otherwise gets double-processed (see fau.md).
	if [ "$pname" != "$name" ]; then
		grep -qxF "$pname" "$seen_file" 2>/dev/null && return 0
		echo "$pname" >> "$seen_file"
	fi

	if [ -n "$pdepends" ]; then
		local d
		for d in $(printf '%s' "$pdepends" | tr ',' ' '); do
			[ -z "$d" ] && continue
			_alpm_resolve_one "$d" "$seen_file" "$out_file" \
				|| log "warning: couldn't resolve '$d' (a dependency of $pname) in any repo -- skipping it"
		done
	fi
	printf "%s${ALPM_FS}%s${ALPM_FS}%s${ALPM_FS}%s${ALPM_FS}%s\n" "$repo" "$pname" "$pversion" "$pfilename" "$psha256" >> "$out_file"
	return 0
}

alpm_resolve() {
	local name=$1
	local seen; seen=$(mktemp)
	local out; out=$(mktemp)
	if ! _alpm_resolve_one "$name" "$seen" "$out"; then
		rm -f "$seen" "$out"
		return 1
	fi
	echo >&2
	cat "$out"
	rm -f "$seen" "$out"
}

# alpm_resolve_many <name...> -- like alpm_resolve, but resolves every
# given name's closure into ONE shared "already resolved" cache instead of
# calling alpm_resolve once per name -- a package needed by more than one
# of the given names (mesa, zlib, xcb-util-wm, ...) only gets walked once
# instead of once per name that needs it. Found by actually running `fau
# build mangowm`'s own 15-name PKG_DEPENDS + 19-name PKG_BUILD_DEPS lists:
# the same handful of heavily-shared packages were being fully re-resolved
# dozens of times, each restarting its own "resolving dependencies..."
# counter from scratch -- correct, but slow and confusing to watch. Used
# by build_merge_depends/alpm_sandbox_fetch, whose whole point is
# resolving several overlapping closures together; alpm_resolve itself
# stays single-name for install_one_alpm/app_install_one_alpm, each of
# which only ever resolves one top-level install request at a time.
alpm_resolve_many() {
	local seen; seen=$(mktemp)
	local out; out=$(mktemp)
	local name
	for name in "$@"; do
		_alpm_resolve_one "$name" "$seen" "$out" \
			|| { rm -f "$seen" "$out"; die "couldn't resolve '$name' in any configured Arch/Artix repo"; }
	done
	echo >&2
	cat "$out"
	rm -f "$seen" "$out"
}

alpm_fetch_job() {
	# Fetch-only, no extraction -- extraction happens later, strictly one package at a time (see fau.md).
	local jobs_dir=$1 idx=$2 repo=$3 filename=$4 sha256=$5
	local dest="$jobs_dir/$idx.pkg.tmp"
	local from_cache=0
	if [ -r "/var/cache/pacman/pkg/$filename" ]; then
		cp "/var/cache/pacman/pkg/$filename" "$dest"
		echo cached > "$jobs_dir/$idx.source"
		from_cache=1
	else
		alpm_fetch "$repo" "$filename" "$dest" quiet
		echo fetched > "$jobs_dir/$idx.source"
	fi
	local actual; actual=$(sha256sum "$dest" | cut -d' ' -f1)
	[ "$actual" = "$sha256" ] || die "checksum mismatch: expected $sha256, got $actual"
	# Cached into /var/cache/pacman/pkg/ for later reuse (see fau.md); best-effort, tmp-name-then-rename for concurrent safety.
	if [ "$from_cache" -eq 0 ] && mkdir -p /var/cache/pacman/pkg 2>/dev/null; then
		local cache_tmp="/var/cache/pacman/pkg/.fau-fetch.$$.$filename"
		cp "$dest" "$cache_tmp" 2>/dev/null && mv -f "$cache_tmp" "/var/cache/pacman/pkg/$filename" 2>/dev/null
	fi
	mv "$dest" "$jobs_dir/$idx.pkg"
}

alpm_parallel_fetch() {
	local jobs_dir=$1 max_jobs=$2; shift 2
	local total=$#
	[ "$total" -gt 0 ] || return 0
	local idx
	for idx in "$@"; do
		alpm_fetch_job "$jobs_dir" "$idx" "${pkg_repo[$idx]}" "${pkg_filename[$idx]}" "${pkg_sha256[$idx]}" &
		while [ "$(jobs -rp | wc -l)" -ge "$max_jobs" ]; do
			draw_count_bar "$(find "$jobs_dir" -maxdepth 1 -iname '*.pkg' 2>/dev/null | wc -l)" "$total" " fetching"
			sleep 0.1
		done
	done
	while [ "$(jobs -rp | wc -l)" -gt 0 ]; do
		draw_count_bar "$(find "$jobs_dir" -maxdepth 1 -iname '*.pkg' 2>/dev/null | wc -l)" "$total" " fetching"
		sleep 0.1
	done
	wait
	draw_count_bar "$total" "$total" " fetching"
	echo >&2
}

install_one_alpm() {
	# System-side counterpart to app_install_one_alpm: merges into FAU_ROOT and system.json. See fau.md.
	local name=$1
	local resolved; resolved=$(alpm_resolve "$name") \
		|| die "couldn't resolve '$name' in any configured Arch/Artix repo"

	local -a pkg_repo=() pkg_name=() pkg_version=() pkg_filename=() pkg_sha256=()
	local total=0 repo pkgname pkgversion filename sha256
	while IFS="$ALPM_FS" read -r repo pkgname pkgversion filename sha256; do
		[ -n "$pkgname" ] || continue
		total=$((total + 1))
		pkg_repo[$total]=$repo; pkg_name[$total]=$pkgname; pkg_version[$total]=$pkgversion
		pkg_filename[$total]=$filename; pkg_sha256[$total]=$sha256
	done <<< "$resolved"
	local names=""
	local n; for n in $(seq 1 "$total"); do names="$names${pkg_name[$n]} "; done
	log "resolved ${total} package(s) for $name: ${names% }"

	mkdir -p "$FAU_ROOT"
	local jobs_dir; jobs_dir=$(mktemp -d)
	local version="" skipped=0 cached=0 fetched=0
	local -a queue=()
	local i
	for i in $(seq 1 "$total"); do
		pkgname=${pkg_name[$i]}
		# "$i" -ne "$total", not "$pkgname" != "$name" -- see fau.md's man/man-db alias bug for why.
		if [ "$i" -ne "$total" ] && [ -n "$(system_get_version "$pkgname")" ]; then
			skipped=$((skipped + 1))
			continue
		fi
		if [ "$pkgname" = "filesystem" ]; then
			skipped=$((skipped + 1))
			continue
		fi
		[ -n "${pkg_filename[$i]}" ] && [ -n "${pkg_sha256[$i]}" ] || die "missing metadata for $pkgname in repo ${pkg_repo[$i]}"
		queue+=("$i")
	done

	alpm_parallel_fetch "$jobs_dir" 4 "${queue[@]}"

	for i in "${queue[@]}"; do
		pkgname=${pkg_name[$i]}
		local archive="$jobs_dir/$i.pkg"
		[ -f "$archive" ] || die "fetching $pkgname failed (see errors above)"
		[ "$(cat "$jobs_dir/$i.source" 2>/dev/null)" = cached ] && cached=$((cached + 1)) || fetched=$((fetched + 1))

		local extract_dir; extract_dir=$(mktemp -d)
		tar_extract_or_die "$archive" "$extract_dir" "$pkgname"
		rm -f "$archive"
		chmod -R u+rX "$extract_dir"
		rm -f "$extract_dir/.PKGINFO" "$extract_dir/.BUILDINFO" "$extract_dir/.MTREE" "$extract_dir/.INSTALL"
		rm -rf "$extract_dir/etc" "$extract_dir/usr/include"

		[ "$i" -eq "$total" ] && version=${pkg_version[$i]}
		[ "$i" -eq "$total" ] && record_files "$name" "$extract_dir"
		rsync -aK --checksum "$extract_dir/" "$FAU_ROOT/"
		rm -rf "$extract_dir"
	done
	rm -rf "$jobs_dir"

	log "$name: fetched $fetched, used cache for $cached, skipped $skipped (already provided or base-system bootstrap noise) -- merged into $FAU_ROOT"
	system_set "$name" "${version:-unknown (via alpm)}"
	log "installed $name ${version:-(via alpm)} into $FAU_ROOT"
}

app_install_one_alpm() {
	# version: only meaningful as a *rejection* here -- if alpm_resolve
	# below actually succeeds, the mirrors only ever carry one (the latest)
	# version, so a requested version other than exactly that one is a hard
	# error, not silently ignored. If alpm_resolve instead fails (the name
	# isn't on the mirrors at all, e.g. an AUR-only package like dwm), the
	# version is passed through to offer_build -> `fau build name=version`
	# instead, where it's actually meaningful. See fau.md.
	local name=$1 version=${2:-}
	local resolved
	if ! resolved=$(alpm_resolve "$name"); then
		# offer_build's own exit status distinguishes "no recipe exists at
		# all" (1) from "a recipe exists, but declined/no tty to ask on" (2)
		# -- see lib/common.sh. A name with a real recipe (dwm, mangowm)
		# that just wasn't built this time must not be reported as if it
		# were entirely unknown to FloraOS.
		local rc=0
		offer_build "$name" "$version" || rc=$?
		if [ "$rc" -eq 2 ]; then
			die "$name: not installed (declined to build from source, or no interactive terminal to ask on)"
		elif [ "$rc" -ne 0 ]; then
			die "$name: not found on any configured Arch/Artix mirror, and no fau-build recipe exists for it either"
		fi
	fi
	if [ -n "$version" ]; then
		local resolved_version; resolved_version=$(printf '%s' "$resolved" | tail -n1 | cut -d"$ALPM_FS" -f3)
		[ "$resolved_version" = "$version" ] || die "$name=$version: the Arch/Artix mirrors only have $resolved_version -- mirrors only ever carry the latest version, this can't be pinned to an older/different one. If $name has a 'fau build' recipe supporting a specific version, use 'fau build $name=$version' directly."
	fi

	local -a pkg_repo=() pkg_name=() pkg_version=() pkg_filename=() pkg_sha256=()
	local total=0 repo pkgname pkgversion filename sha256
	while IFS="$ALPM_FS" read -r repo pkgname pkgversion filename sha256; do
		[ -n "$pkgname" ] || continue
		total=$((total + 1))
		pkg_repo[$total]=$repo; pkg_name[$total]=$pkgname; pkg_version[$total]=$pkgversion
		pkg_filename[$total]=$filename; pkg_sha256[$total]=$sha256
	done <<< "$resolved"
	local names=""
	local n; for n in $(seq 1 "$total"); do names="$names${pkg_name[$n]} "; done
	log "resolved ${total} package(s) for $name: ${names% }"

	local app_dir="${FAU_APPS_DIR%/}/${name}"
	rm -rf "$app_dir"
	mkdir -p "$app_dir" "$app_dir/config" "$app_dir/cache" "$app_dir/data" "$app_dir/logs"
	local jobs_dir; jobs_dir=$(mktemp -d)
	# target_files="" explicitly -- a bare `local` name alongside others with `=value` is unbound under set -u (see fau.md).
	local target_files="" version="" cached=0 fetched=0 skipped=0
	local -a queue=()
	local i; for i in $(seq 1 "$total"); do
		pkgname=${pkg_name[$i]}
		# "$i" -ne "$total", not "$pkgname" != "$name" -- see fau.md's man/man-db alias bug.
		if { [ "$i" -ne "$total" ] && [ -n "$(system_get_version "$pkgname")" ]; } || [ "$pkgname" = "filesystem" ]; then
			skipped=$((skipped + 1))
			continue
		fi
		[ -n "${pkg_filename[$i]}" ] && [ -n "${pkg_sha256[$i]}" ] || die "missing metadata for $pkgname in repo ${pkg_repo[$i]}"
		queue+=("$i")
	done

	# No etc/ strip here (unlike install_one_alpm) -- an isolated app dir never touches the real /etc.
	alpm_parallel_fetch "$jobs_dir" 4 "${queue[@]}"

	for i in "${queue[@]}"; do
		local archive="$jobs_dir/$i.pkg"
		[ -f "$archive" ] || die "fetching ${pkg_name[$i]} failed (see errors above)"
		[ "$(cat "$jobs_dir/$i.source" 2>/dev/null)" = cached ] && cached=$((cached + 1)) || fetched=$((fetched + 1))

		local extract_dir; extract_dir=$(mktemp -d)
		tar_extract_or_die "$archive" "$extract_dir" "${pkg_name[$i]}"
		rm -f "$archive"
		chmod -R u+rX "$extract_dir"
		rm -f "$extract_dir/.PKGINFO" "$extract_dir/.BUILDINFO" "$extract_dir/.MTREE" "$extract_dir/.INSTALL"
		rm -rf "$extract_dir/usr/include"
		# fauelf rewrites absolute DT_NEEDED entries to bare basenames -- see fau.md and ../fauelf/fauelf.md.
		while IFS= read -r -d '' f; do
			"$FAU_ELF_PATCH" "$f" || die "fauelf failed patching $f"
		done < <(find "$extract_dir" -type f -print0)
		# "$i" -eq "$total", not "${pkg_name[$i]}" = "$name" -- see fau.md's man/man-db alias bug.
		if [ "$i" -eq "$total" ]; then
			version=${pkg_version[$i]}
			target_files=$(cd "$extract_dir" && find usr/bin bin -maxdepth 1 -type f 2>/dev/null; true)
		fi
		cp -a "$extract_dir/." "$app_dir"
		rm -rf "$extract_dir"
	done
	rm -rf "$jobs_dir"
	log "$name: fetched $fetched, used cache for $cached, skipped $skipped (already provided by the base system or base-system bootstrap noise) -- merged into $app_dir"

	for relbin in $target_files; do
		app_wrapper_write "$name" "$app_dir" "$relbin"
	done
	app_desktop_merge "$app_dir"

	# Without a recorded bin=, `fau remove` can't find this app's wrapper scripts -- see fau.md.
	{
		echo "name=$name"
		echo "version=${version:-unknown (via alpm)}"
		printf 'bin='
		printf '%s' "$target_files" | tr '\n' ','
		echo
	} > "$app_dir/.pkginfo"

	json_set "$FAU_APPS_JSON" "$name" "${version:-unknown (via alpm)}"
	log "installed app $name (via alpm) into $app_dir"
	[ -n "$target_files" ] || log "note: couldn't find any usr/bin or bin entrypoint owned by $name to wrap"
	case ":$PATH:" in
		*":$FAU_APPS_BIN_DIR:"*) ;;
		*) log "note: $FAU_APPS_BIN_DIR is not on your PATH yet — add it to use $name's commands directly" ;;
	esac
}

# Real Arch .pc files (and any locally-built package's own DESTDIR-installed
# .pc files, e.g. mangowm.fis's scenefx step) assume they're installed at the
# real /, so a variable derived from "prefix=/usr" (e.g. wayland-scanner.pc's
# own "wayland_scanner=${bindir}/wayland-scanner") resolves to the literal
# host path "/usr/bin/wayland-scanner" -- which doesn't exist on FloraOS at
# all, only this sandbox's own relocated copy does. Found on a real FloraOS
# boot, not in this dev sandbox: this machine happens to already have the
# real wayland package installed, which masked the bug entirely until tested
# somewhere that doesn't (confirmed for real with bwrap hiding the real
# wayland-scanner). Rewrites ANY "key=/absolute/path" variable assignment
# line, not just prefix=/exec_prefix= -- some real .pc files hardcode other
# variables as literal absolute paths instead of deriving them from ${prefix}
# at all (elogind.pc's own "includedir=/usr/include/elogind"/"libdir=/usr/lib",
# found the same way: scenefx's own build failed with "cc1: error:
# /usr/include/elogind: No such file or directory" the first time prefix-only
# rewriting was tried). Only matches "key=..." lines (pkgconfig's own KEY:
# metadata lines -- Cflags:, Libs:, Requires: -- use a colon, untouched here),
# and only lines starting with the variable name at column 1, so a
# commented-out "# includedir=/usr/include" line is correctly left alone.
# Doesn't catch an absolute path hardcoded directly inside a Cflags:/Libs:
# line rather than via a variable -- a smaller, disclosed gap, same class as
# mango's own /etc/mango/config.conf one -- not fixed here.
alpm_rewrite_pc_paths() {
	local dest=$1 dir=$2
	local f
	while IFS= read -r -d '' f; do
		sed -E -i "s#^([A-Za-z_][A-Za-z0-9_]*)=/#\1=${dest}/#" "$f"
	done < <(find "$dir" -name '*.pc' -type f -print0)
}

# Resolves PKG_BUILD_DEPS' alpm closure with usr/include KEPT into <dest-dir>, flat, for fau-build. See fau.md.
alpm_sandbox_fetch() {
	local dest=$1; shift
	local total=0
	local -a pkg_repo=() pkg_name=() pkg_version=() pkg_filename=() pkg_sha256=()
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
		[ "${pkg_name[$i]}" = "filesystem" ] && continue
		queue+=("$i")
	done
	alpm_parallel_fetch "$jobs_dir" 4 "${queue[@]}"

	mkdir -p "$dest"
	for i in "${queue[@]}"; do
		local archive="$jobs_dir/$i.pkg"
		[ -f "$archive" ] || die "fetching ${pkg_name[$i]} failed (see errors above)"
		local extract_dir; extract_dir=$(mktemp -d)
		tar_extract_or_die "$archive" "$extract_dir" "${pkg_name[$i]}"
		rm -f "$archive"
		chmod -R u+rX "$extract_dir"
		rm -f "$extract_dir/.PKGINFO" "$extract_dir/.BUILDINFO" "$extract_dir/.MTREE" "$extract_dir/.INSTALL"
		# No usr/include strip here -- keeping headers is the entire reason this function exists.
		while IFS= read -r -d '' f; do
			"$FAU_ELF_PATCH" "$f" || die "fauelf failed patching $f"
		done < <(find "$extract_dir" -type f -print0)
		# Rewrites absolute-interpreter shebangs (e.g. meson's own) to this
		# sandbox's copy -- see fau.md. Cheap `read -N 2` magic-byte check
		# first, not just `head -c 256 | head -n1` on every file: the vast
		# majority of files here are ELF binaries, and capturing their raw
		# bytes via command substitution made bash print "ignored null
		# byte in input" once per file (thousands of times on a real
		# closure) -- found by actually running `fau build mangowm`, not
		# by inspection. `read -N 2` reads bytes directly into a variable,
		# no command substitution involved, so it never triggers that
		# warning; the expensive full-line read only runs for the much
		# smaller set of files that already start with literal "#!".
		local f magic shebang interp
		while IFS= read -r -d '' f; do
			# `|| true`: `read -N 2` returns non-zero on any file under 2
			# bytes (real packages ship plenty of empty marker files) --
			# under this script's `set -e`, that bare failure silently
			# killed the whole `fau build` with no error message at all.
			# Found by actually running `fau build mangowm` twice, both
			# times dying at the identical spot with no visible cause,
			# not by inspection.
			IFS= read -r -N 2 magic < "$f" 2>/dev/null || true
			[ "$magic" = "#!" ] || continue
			shebang=$(head -c 256 "$f" 2>/dev/null | head -n1)
			case "$shebang" in
				'#!/'*)
					interp=${shebang#\#!}
					interp=${interp%% *}
					sed -i "1s|^#!${interp}|#!${dest}${interp}|" "$f"
					;;
			esac
		done < <(find "$extract_dir" -type f -print0)
		# See alpm_rewrite_pc_paths below for why this runs.
		alpm_rewrite_pc_paths "$dest" "$extract_dir"
		cp -a "$extract_dir/." "$dest"
		rm -rf "$extract_dir"
	done
	rm -rf "$jobs_dir"
}
