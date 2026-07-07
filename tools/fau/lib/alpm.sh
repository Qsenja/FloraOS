# lib/alpm.sh -- the Arch/Artix repo fallback, no pacman binary. Sourced by
# fau-bootstrap and fau-install, the two tools whose install path falls back
# to this when a package isn't in fau's own local repo (lib/repo.sh).
#
# Until FloraOS has its own curated app catalog, install/bootstrap fall back
# to pulling from Arch/Artix's own repos when a package isn't in the local
# fau repo. This never shells out to the `pacman` binary at all --
# only its *data formats* (sync db, desc files, mirrorlist, pacman.conf's
# repo list) are read directly, using fau's own fetch/resolve/verify code.
# That means this fallback works both at build time (reading this build
# host's own /etc/pacman.d/mirrorlist and /var/lib/pacman/sync as a fast
# path) and from inside an already-booted FloraOS system, which has neither
# pacman nor a synced db -- it falls back to fetching the mirrorlist/db
# fresh from a mirror, using a copy of the mirrorlist/repo-list FloraOS
# ships at /etc/fau/ specifically for this (see build-rootfs.sh).
# Real caveat: fetched binaries are built against Artix's glibc -- this only
# works cleanly as long as that stays ABI-compatible with FloraOS's own
# from-scratch glibc (currently identical versions by coincidence, not by
# any guarantee). GUI apps also won't have a display server to draw on yet
# (see ARCHITECTURE.md) -- this gets you the files, not a running X11.
#
# Requires lib/common.sh and lib/manifest.sh already sourced: uses
# die/log/json_escape/pkginfo_field (common.sh) and
# system_get_version/system_set/record_files (manifest.sh, for
# install_one_alpm's system-side bookkeeping) plus json_set (manifest.sh,
# for app_install_one_alpm's apps.json bookkeeping) and $FAU_ELF_PATCH
# (common.sh, for app_install_one_alpm's absolute-DT_NEEDED fixup).

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
	# Priority order matters: the first repo that has a given name wins,
	# same as pacman.conf's own section ordering.
	local f; f=$(alpm_repo_list_path) || die "no pacman mirrorlist/repo-list available"
	case "$(basename "$f")" in
		pacman.conf) grep -oE '^\[[a-zA-Z0-9_.-]+\]' "$f" | tr -d '[]' | grep -vx options ;;
		*) grep -vE '^[[:space:]]*(#|$)' "$f" ;;
	esac
}

alpm_mirror_urls() {
	# alpm_mirror_urls <repo> <filename> -> every configured mirror's URL for
	# this file, one per line, in mirrorlist order (candidates for
	# alpm_fetch's fallback, not just the first one)
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
	# draw_count_bar <done> <total> <suffix> -- redraws a single-line ASCII
	# progress bar in place ('=' fill, '>' tip -- plain ASCII, not curl's own
	# hardcoded '#' style, and safe on this console's ASCII terminal
	# encoding, not just a UTF-8 one). Caller is responsible for a final
	# newline once done == total.
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
	# curl_fetch_with_bar <url> <dest> -- like `curl -fL -o dest url`, but
	# drawn with draw_count_bar (bytes done/total) instead of curl's own
	# --progress-bar (hardcoded '#' fill, not overridable by any curl flag).
	# Falls back to a plain quiet fetch with no bar if the server doesn't
	# report Content-Length on HEAD (some redirects/mirrors don't) -- an
	# indeterminate spinner isn't worth the complexity here.
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
	# alpm_fetch <repo> <filename> <dest> [quiet] -- tries every configured
	# mirror in order until one succeeds, instead of hard-failing on
	# whatever mirror happens to be first in the list. A single dead/
	# unresolvable mirror (seen for real: a mirrorlist entry whose DNS name
	# didn't resolve from inside the QEMU guest network, while every other
	# mirror worked fine) used to abort the whole install with no retry,
	# exactly like real pacman would keep going instead.
	#
	# `quiet` skips even that bar: callers fetching several packages in
	# parallel (install_one_alpm, app_install_one_alpm) drive their own
	# single combined progress bar instead -- multiple concurrent per-file
	# bars writing '\r' to the same terminal line would just garble each
	# other.
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
	# alpm_fetch_repo_db <repo> -> local path to <repo>.db, downloading if
	# not already cached. Prefers this build host's own already-synced copy
	# (fast path, no network needed) over a fresh mirror fetch -- the fresh
	# fetch is what makes this work from inside a booted FloraOS system,
	# which has neither pacman nor a populated /var/lib/pacman/sync.
	local repo=$1
	local cache_dir; cache_dir=$(alpm_db_cache_dir)
	local dest="$cache_dir/$repo.db"
	if [ ! -s "$dest" ]; then
		if [ -r "/var/lib/pacman/sync/$repo.db" ]; then
			cp "/var/lib/pacman/sync/$repo.db" "$dest"
		else
			log "fetching $repo.db..."
			alpm_fetch "$repo" "$repo.db" "$dest.part"
			mv "$dest.part" "$dest"
		fi
	fi
	echo "$dest"
}

# Field separator for fau's own alpm-resolution records (index lines,
# resolver output) -- NOT a literal tab. bash's `read` silently collapses
# *consecutive* IFS-whitespace separators (tab counts as whitespace no
# matter what IFS is set to), which corrupts parsing the instant a field in
# the middle is empty (e.g. a package with no depends or no provides) --
# every field after it silently shifts by one position. Found by tracing a
# real resolution: linux-api-headers (empty depends+provides) ended up
# looking like it "depended on" its own filename. \x1f (ASCII unit
# separator) isn't whitespace, so bash's read preserves empty fields
# correctly; verified directly (see the fix commit) before relying on it.
ALPM_FS=$'\x1f'

alpm_repo_index() {
	# alpm_repo_index <repo> -> path to a cached index of every package in
	# that repo's sync db, one line each: name<FS>version<FS>depends<FS>provides<FS>filename<FS>sha256
	# (FS = $ALPM_FS). Built once per repo. A real Arch repo can hold
	# thousands of packages (the "world" repo here has ~7300) -- spawning a
	# handful of awk processes per package to pull each field separately
	# (the first version of this) meant tens of thousands of forks and was
	# slow enough to look hung. A single awk invocation reading every
	# extracted desc file as its argument list, tracking one package's
	# fields across FNR==1 boundaries, does the entire repo in one process.
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
	# alpm_repo_provides_index <repo> -> path to a cached index keyed by
	# *provided* (virtual/soname) name, one line per (provided-name,
	# provider-package) pair:
	#   provname<FS>provver<FS>name<FS>version<FS>depends<FS>filename<FS>sha256
	# Exists so alpm_find_provider's PROVIDES fallback can do a single awk
	# lookup instead of a plain bash `while read` linear scan over the
	# *entire* by-name index (thousands of lines) for every dependency spec
	# that isn't a real package name -- which in practice is nearly every
	# real Arch/Artix dependency, since those are mostly soname/virtual
	# specs like "libz.so=1-64" rather than the package's own name. Found
	# resolving a large closure (`fau install neovim`, ~50+ packages)
	# taking noticeably long; this is the same fix alpm_repo_index itself
	# already applied to the equivalent by-name problem (one awk pass
	# instead of per-package forks) -- see that function's own comment.
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

# --- version comparison (alpm's own version-comparison algorithm) ---
# Arch dependency constraints look like "glibc>=2.38-1" or "libfoo=1.2-3".
# Verified against the real `vercmp` binary across ~300 real package
# versions from this host's own sync dbs plus a battery of hand-picked
# cases (epoch, pkgrel, git-describe-style "+r37+gHASH" suffixes) -- exact
# match on all of them. The only known divergences from real vercmp are
# contrived synthetic cases (a bare alpha suffix directly attached with no
# separator, e.g. "1.0a" vs "1.0", and tilde pre-release markers) that
# essentially never occur in real Arch/Artix package version strings, which
# use "-", "+", "." as explicit separators -- an accepted, documented
# simplification rather than a full reimplementation of every rpmvercmp
# edge case.

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
	# alpm_vercmp <v1> <v2> -> -1, 0, or 1. Format: [epoch:]pkgver[-pkgrel]
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
	# version_satisfies_alpm <installed> <op> <required> -- op empty means
	# an unconstrained dependency, always satisfied
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
	# alpm_dep_parse <dep-token> -> "name<FS>op<FS>version" (FS =
	# $ALPM_FS; op/version empty for an unconstrained dependency). Longer
	# operators (>=, <=) must be checked before the bare >/< they contain
	# as a substring.
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
	# alpm_find_provider <name> <op> <ver> -> "repo<FS>name<FS>version<FS>depends<FS>filename<FS>sha256"
	# (FS = $ALPM_FS) for the first package (searched in repo priority
	# order) satisfying it, by exact name first, then by PROVIDES (virtual
	# package) if no repo has a real package by that name.
	local want=$1 op=$2 ver=$3
	local repo index line
	for repo in $(alpm_repo_names); do
		index=$(alpm_repo_index "$repo")
		# Index lines are name/version/depends/provides/filename/sha256 (6
		# fields) -- drop the provides field (unused by callers) so both
		# branches of this function emit the same 6-field shape prefixed
		# with repo; a mismatch here previously misaligned every field
		# after it for the caller (filename/sha256 silently swapped).
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
		# The awk call does the O(repo size) filtering (fast, a compiled
		# loop, not a bash one); the bash loop below only ever walks the
		# handful of rows that actually provide $want, not the whole repo --
		# that's the whole fix. Ordering is preserved: the provides index
		# was built from the same per-repo desc ordering as the by-name
		# index, so "first matching row" here means the same thing it did
		# in the old linear scan.
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
	# Appends "repo\tname\tversion\tfilename\tsha256" lines to out_file for
	# spec and everything it (transitively) depends on, dependencies before
	# dependents, each name resolved at most once (seen_file). Returns 1
	# only if *this exact* spec can't be found anywhere; a failure deeper in
	# the tree is logged and skipped rather than propagated, since Arch
	# dependency graphs commonly reference optional/soft deps this fallback
	# doesn't need to take literally.
	local spec=$1 seen_file=$2 out_file=$3
	local name op ver
	IFS="$ALPM_FS" read -r name op ver <<< "$(alpm_dep_parse "$spec")"

	grep -qxF "$name" "$seen_file" 2>/dev/null && return 0

	local found
	found=$(alpm_find_provider "$name" "$op" "$ver") || return 1
	local repo pname pversion pdepends pfilename psha256
	IFS="$ALPM_FS" read -r repo pname pversion pdepends pfilename psha256 <<< "$found"

	echo "$name" >> "$seen_file"
	# A single line, redrawn in place (not one new line per dependency --
	# that was noisy for a big closure like cowsay's) -- but still real
	# live output, not silence: resolving a large closure for the first
	# time (building the alpm repo index, walking many dependencies) can
	# take several seconds, and with nothing printed at all during that
	# stretch it looked like fau had simply hung.
	printf '\rfau: resolving dependencies... %-40s' "$(wc -l < "$seen_file") found (latest: $pname)" >&2
	# A dependency spec doesn't always name the real package directly -- it
	# can reference a virtual/soname alias (e.g. "libz.so=1-64") that
	# resolves to a differently-named real package (zlib). Without also
	# tracking the *resolved* name, that real package gets reprocessed (and
	# printed) once per distinct alias it's reached through -- found by
	# comparing cava's full closure against real pacman's own resolution (used only to validate correctness, never invoked at runtime):
	# unique package counts matched exactly, but the raw output had ~40
	# duplicate lines.
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
	# alpm_resolve <name> -> prints "repo<FS>name<FS>version<FS>filename<FS>sha256"
	# (FS = $ALPM_FS) lines for name and its full transitive closure, deps before dependents
	local name=$1
	local seen; seen=$(mktemp)
	local out; out=$(mktemp)
	if ! _alpm_resolve_one "$name" "$seen" "$out"; then
		rm -f "$seen" "$out"
		return 1
	fi
	# Ends the \r-redrawn "resolving dependencies..." line from
	# _alpm_resolve_one on its own line, so the caller's next log() line
	# (the "resolved N package(s)..." summary) starts clean instead of
	# overwriting/trailing it.
	echo >&2
	cat "$out"
	rm -f "$seen" "$out"
}

alpm_fetch_job() {
	# alpm_fetch_job <jobs_dir> <idx> <repo> <filename> <sha256> -- meant to
	# run backgrounded (`&`): fetches (quietly -- the caller owns the one
	# combined progress bar) and checksum-verifies a single package's
	# *compressed* archive into "$jobs_dir/$idx.pkg", recording cache-hit vs
	# real fetch in "$jobs_dir/$idx.source". Leaves no .pkg file behind on
	# any failure (checksum mismatch, every mirror failing, etc) -- die()
	# just ends this one background job; the caller's sequential
	# extract+merge pass treats a missing .pkg file as that failure.
	#
	# Deliberately fetch-only, no extraction here: extraction/merge happens
	# later, strictly one package at a time (see install_one_alpm/
	# app_install_one_alpm) -- compressed archives are cheap to hold many
	# of on disk at once, but their extracted, uncompressed form is not, on
	# a RAM-backed (tmpfs) rootfs. An earlier version of this fetched *and*
	# extracted in parallel, which meant several packages' full uncompressed
	# trees existed on disk simultaneously -- ran a real boot out of space
	# partway through copying glibc's locale files, even at just 2 at once.
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
	# Persist every freshly-downloaded archive into the same well-known
	# cache this function already *reads* from above, so a later bootstrap
	# of the same package -- possibly against a different FAU_ROOT
	# entirely -- hits this cache instead of the network. This is what
	# lets florainstall speculatively prefetch btrfs-progs/grub while the
	# user is still clicking through its TUI, before the real chroot
	# target even exists to bootstrap into: the real, later bootstrap call
	# just finds everything already here. Best-effort (mkdir/cp/mv can all
	# silently fail, e.g. a read-only /var) -- a cache write is never
	# allowed to fail the actual install over it. tmp-name-then-rename:
	# same atomic-write pattern write_lines() uses, since multiple
	# concurrent fau invocations (a background prefetch racing the real
	# install) can hit this same destination file at once.
	if [ "$from_cache" -eq 0 ] && mkdir -p /var/cache/pacman/pkg 2>/dev/null; then
		local cache_tmp="/var/cache/pacman/pkg/.fau-fetch.$$.$filename"
		cp "$dest" "$cache_tmp" 2>/dev/null && mv -f "$cache_tmp" "/var/cache/pacman/pkg/$filename" 2>/dev/null
	fi
	mv "$dest" "$jobs_dir/$idx.pkg"
}

alpm_parallel_fetch() {
	# alpm_parallel_fetch <jobs_dir> <max_jobs> <idx>... -- fetches every
	# given index's package (see alpm_fetch_job) up to <max_jobs> at once,
	# drawing one combined progress bar, then waits for all of them.
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
	# System-side counterpart to app_install_one_alpm: merges into
	# FAU_ROOT (rsync -aK, same as install_one's own merge) and records into
	# system.json, instead of isolating into FAU_APPS_DIR. Used for base
	# packages fetched straight from Arch/Artix's own repos rather than
	# compiled from source (e.g. fastfetch during rootfs build).
	local name=$1
	local resolved; resolved=$(alpm_resolve "$name") \
		|| die "couldn't resolve '$name' in any configured Arch/Artix repo"

	# Parsed into indexed arrays up front (not streamed straight through a
	# single `while read` loop) so the merge-as-each-job-finishes loop below
	# can look a package's own repo/name/version/filename/sha256 back up by
	# index in whatever order jobs actually complete in, not just top to
	# bottom.
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
		# alpm_resolve's closure for a package like fastfetch/libgcc also
		# includes glibc, filesystem, tzdata, etc: things FloraOS already
		# built from its own pinned source. Without this guard those get
		# rsync-merged over FAU_ROOT too, silently replacing FloraOS's own
		# compiled binaries with Arch's official ones -- found by comparing
		# libc.so.6's sha256 before/after a real build: the shipped one
		# turned out to be Arch's, not FloraOS's own.
		#
		# "$i" -ne "$total", not "$pkgname" != "$name": alpm_resolve's own
		# contract (_alpm_resolve_one's header comment) is "dependencies
		# before dependents", so the actual requested package -- resolved to
		# its *real* name, which can differ from $name when $name is a
		# virtual/PROVIDES alias (e.g. "man" resolving to "man-db") -- is
		# always the very last entry, at index $total. A name-equality check
		# here silently never matches for a request like `fau install man`:
		# no $pkgname ever equals the literal string "man", so this guard's
		# "unless it's the actual requested package" carve-out just never
		# applied -- found via a real `fau install man` skipping-or-not
		# quietly going wrong, not by inspection.
		if [ "$i" -ne "$total" ] && [ -n "$(system_get_version "$pkgname")" ]; then
			skipped=$((skipped + 1))
			continue
		fi
		# "filesystem" is Arch/Artix's own base-system bootstrap package --
		# never something the *requested* package (fastfetch/libgcc) needs
		# to run, only ever dragged in because Arch's dependency graph
		# implies "a base Arch system" underneath everything. Its content
		# outside etc/ and usr/include (already stripped below) is entirely
		# Arch/Artix distro integration -- /usr/lib/tmpfiles.d/artix.conf,
		# /usr/lib/sysctl.d/10-artix.conf, /usr/lib/sysusers.d/artix.conf,
		# Artix branding pixmaps -- and merging it in silently applied
		# Artix's own sysctl tuning at boot and threw tmpfiles errors for
		# /etc files this build deliberately doesn't ship (found on a real
		# boot, not by inspection). Skipped by name rather than stripping a
		# fifth individual subdirectory: none of "filesystem" is ever
		# wanted here, regardless of what FloraOS itself provides.
		if [ "$pkgname" = "filesystem" ]; then
			skipped=$((skipped + 1))
			continue
		fi
		[ -n "${pkg_filename[$i]}" ] && [ -n "${pkg_sha256[$i]}" ] || die "missing metadata for $pkgname in repo ${pkg_repo[$i]}"
		queue+=("$i")
	done

	# Fetch every queued package's *compressed* archive in parallel first
	# (cheap to hold several of on disk at once); extract+strip+merge
	# strictly one at a time after (see alpm_fetch_job's own comment for
	# why: this rootfs is tmpfs/RAM-backed, and holding more than one
	# package's uncompressed extracted tree on disk at once genuinely ran a
	# real boot out of space).
	alpm_parallel_fetch "$jobs_dir" 4 "${queue[@]}"

	for i in "${queue[@]}"; do
		pkgname=${pkg_name[$i]}
		local archive="$jobs_dir/$i.pkg"
		[ -f "$archive" ] || die "fetching $pkgname failed (see errors above)"
		[ "$(cat "$jobs_dir/$i.source" 2>/dev/null)" = cached ] && cached=$((cached + 1)) || fetched=$((fetched + 1))

		local extract_dir; extract_dir=$(mktemp -d)
		tar --zstd -xf "$archive" -C "$extract_dir"
		rm -f "$archive"
		# Some packages (dbus's daemon-launch-helper, for one) ship
		# intentionally unreadable setuid-root helpers as a hardening
		# measure -- meaningless in this unprivileged, non-system-installed
		# copy, but it breaks the merge step below since we can't even read
		# what we just extracted. u+rX ensures we always can.
		chmod -R u+rX "$extract_dir"
		rm -f "$extract_dir/.PKGINFO" "$extract_dir/.BUILDINFO" "$extract_dir/.MTREE" "$extract_dir/.INSTALL"
		rm -rf "$extract_dir/etc" "$extract_dir/usr/include"

		# "$i" -eq "$total", not "$pkgname" = "$name" -- see the queue-build
		# loop's own comment above for why (the requested package's real
		# name can differ from $name, but it's always the last resolved
		# entry).
		[ "$i" -eq "$total" ] && version=${pkg_version[$i]}
		# Only the exact requested package ($name) gets its files recorded,
		# matching system_set below: transitive alpm dependencies pulled in
		# via this closure (e.g. libstdc++ for cmatrix) never get their own
		# system.json entry either, so there'd be nothing sensible for a
		# later `fau remove` to key their file list off of.
		[ "$i" -eq "$total" ] && record_files "$name" "$extract_dir"
		# --checksum: see install_one's own merge for why plain -aK isn't
		# enough on an upgrade. FloraOS's own skeleton (apply-skeleton.sh)
		# is the sole source of truth for /etc, and /usr/include is
		# dev-time-only -- both stripped just above.
		rsync -aK --checksum "$extract_dir/" "$FAU_ROOT/"
		rm -rf "$extract_dir"
	done
	rm -rf "$jobs_dir"

	log "$name: fetched $fetched, used cache for $cached, skipped $skipped (already provided or base-system bootstrap noise) -- merged into $FAU_ROOT"
	system_set "$name" "${version:-unknown (via alpm)}"
	log "installed $name ${version:-(via alpm)} into $FAU_ROOT"
}

app_install_one_alpm() {
	local name=$1
	local resolved; resolved=$(alpm_resolve "$name") \
		|| die "couldn't resolve '$name' in any configured Arch/Artix repo -- if a recipe exists, try 'fau build $name'"

	# See install_one_alpm's own comment on why these get parsed into
	# indexed arrays up front instead of streamed through one `while read`.
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
	# target_files="" explicitly, not just declared bare alongside the
	# others: a `local a b="" c=0` where only some names get a `=value`
	# leaves the bare ones (a here) genuinely unbound under `set -u` on this
	# bash -- confirmed directly (reproduced the exact "target_files:
	# unbound variable" crash in isolation) -- not implicitly "" the way a
	# solitary `local target_files` on its own line would be.
	local target_files="" version="" cached=0 fetched=0 skipped=0
	local -a queue=()
	local i; for i in $(seq 1 "$total"); do
		pkgname=${pkg_name[$i]}
		# Same two guards install_one_alpm applies to a system bootstrap
		# merge, mirrored here: without them, an app whose real dependency
		# closure includes glibc (fastfetch does) ends up with a full
		# *second* copy of it -- headers, static libs, locale/zoneinfo data,
		# glibc's own utility binaries -- duplicated into its own directory
		# even though FloraOS's own from-source glibc is already on the
		# system's default library search path (see app_wrapper_write's
		# LD_LIBRARY_PATH, which is additive, not exclusive). Found by
		# actually measuring `fau install fastfetch`'s own app dir: 75MB for
		# what should be a small login-banner tool, ~14MB of it glibc's own
		# headers alone. "filesystem" is Arch/Artix's own base-bootstrap
		# noise (see install_one_alpm's own comment) -- never wanted in an
		# app dir any more than in FAU_ROOT.
		#
		# "$i" -ne "$total", not "$pkgname" != "$name": see install_one_alpm's
		# own identical comment -- the requested package's real name (last
		# resolved entry, $total) can differ from $name when $name is a
		# virtual/PROVIDES alias (e.g. "man" resolving to "man-db"), and a
		# name-equality check here silently never matches in that case. This
		# is the bug `fau install man` actually hit: with target_files never
		# reaching the assignment below (same root cause, see this
		# function's own bin-wrapper loop further down), it crashed on the
		# unbound variable before ever getting to this guard's own
		# consequence, but the guard was equally wrong underneath that.
		if { [ "$i" -ne "$total" ] && [ -n "$(system_get_version "$pkgname")" ]; } || [ "$pkgname" = "filesystem" ]; then
			skipped=$((skipped + 1))
			continue
		fi
		[ -n "${pkg_filename[$i]}" ] && [ -n "${pkg_sha256[$i]}" ] || die "missing metadata for $pkgname in repo ${pkg_repo[$i]}"
		queue+=("$i")
	done

	# Fetch every queued package's *compressed* archive in parallel first;
	# extract+merge strictly one at a time after -- see install_one_alpm's
	# own comment (and alpm_fetch_job's) for why. No etc/ strip here (unlike
	# install_one_alpm): an isolated app directory never touches the real
	# /etc, so there's nothing to guard against there. usr/include *is*
	# stripped, same as install_one_alpm -- dev headers are never needed by
	# an app at runtime, isolated or not.
	alpm_parallel_fetch "$jobs_dir" 4 "${queue[@]}"

	for i in "${queue[@]}"; do
		local archive="$jobs_dir/$i.pkg"
		[ -f "$archive" ] || die "fetching ${pkg_name[$i]} failed (see errors above)"
		[ "$(cat "$jobs_dir/$i.source" 2>/dev/null)" = cached ] && cached=$((cached + 1)) || fetched=$((fetched + 1))

		local extract_dir; extract_dir=$(mktemp -d)
		tar --zstd -xf "$archive" -C "$extract_dir"
		rm -f "$archive"
		# Some packages (dbus's daemon-launch-helper, for one) ship
		# intentionally unreadable setuid-root helpers as a hardening
		# measure -- meaningless in this unprivileged, non-system-installed
		# copy, but it breaks the merge step below since we can't even read
		# what we just extracted. u+rX ensures we always can.
		chmod -R u+rX "$extract_dir"
		rm -f "$extract_dir/.PKGINFO" "$extract_dir/.BUILDINFO" "$extract_dir/.MTREE" "$extract_dir/.INSTALL"
		rm -rf "$extract_dir/usr/include"
		# Some Arch/Artix packages (found via neovim's lua51-lpeg dependency)
		# bake an absolute path into a DT_NEEDED entry (e.g.
		# "/usr/lib/lua/5.1/lpeg.so") instead of a bare soname. That's
		# invisible for a system-root merge (FAU_ROOT really is "/") but
		# breaks an isolated app outright: the dynamic linker only consults
		# LD_LIBRARY_PATH/RPATH for a *bare* soname, so an absolute
		# DT_NEEDED bypasses the app wrapper's own LD_LIBRARY_PATH entirely
		# and fails with "cannot open shared object file" even though the
		# dependency is correctly bundled right here -- confirmed by
		# reproducing it in a real chroot of the built rootfs, not just by
		# reading the code. fauelf (tools/fauelf) rewrites it to a bare
		# basename in place; process substitution (not a `find | while`
		# pipe) keeps this loop in the current shell so a real fauelf
		# failure's die() actually aborts the install instead of just
		# exiting an unrelated pipe subshell.
		while IFS= read -r -d '' f; do
			"$FAU_ELF_PATCH" "$f" || die "fauelf failed patching $f"
		done < <(find "$extract_dir" -type f -print0)
		# "$i" -eq "$total", not "${pkg_name[$i]}" = "$name" -- same reasoning
		# as this function's queue-build loop above and install_one_alpm's
		# identical fix: the requested package's real name is always the
		# last resolved entry, and can differ from $name (a virtual/PROVIDES
		# alias like "man" resolving to "man-db"). With the old
		# name-equality check, `fau install man` never matched this branch
		# at all, so target_files was never assigned -- crashing on the
		# unbound variable at the wrapper-generation loop below before this
		# fix (target_files="" above) would even let it silently fall
		# through empty instead.
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

	# Without this, `fau remove` can't find which wrapper scripts belong to
	# this app (it reads bin= from .pkginfo, same as the repo-based
	# app_install_one does) -- confirmed by a real install/remove
	# round-trip: the wrapper in FAU_APPS_BIN_DIR survived "removal" and
	# failed with "No such file or directory" on next use.
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

# alpm_sandbox_fetch <dest-dir> <name...> -- resolves the combined alpm
# closure of every given name and extracts it *with usr/include kept* into
# <dest-dir>, merged flat (no per-package subdirs, no per-name isolation).
# Used by fau-build (lib/build.sh) for a recipe's PKG_BUILD_DEPS: a
# disposable compile-time sandbox that needs real dev headers to build
# against, unlike install_one_alpm/app_install_one_alpm just above, which
# both unconditionally `rm -rf` usr/include with no bypass -- confirmed by
# reading both, not assumed. This is a separate function rather than a flag
# on those two specifically to avoid touching proven, already-tested code
# for a need neither of them originally had. Never touches FAU_ROOT, any
# FAU_APPS_DIR/<app>, system.json, or .fau-apps.json -- purely a scratch
# extraction; the caller (fau-build) is expected to rm -rf <dest-dir> once
# the build using it is done.
#
# Reuses alpm_resolve/alpm_parallel_fetch/alpm_fetch_job as-is -- the
# resolve/fetch machinery is identical to the other two paths above; only
# the extract/merge tail differs. Skips "filesystem" (Arch/Artix's own
# base-bootstrap noise, same reasoning as the other two paths) for speed,
# but deliberately does NOT skip packages fau's own system.json already
# provides: that skip exists elsewhere to avoid a second copy of something
# already on FAU_ROOT's real library search path, which doesn't apply
# here since a sandbox is never merged into FAU_ROOT at all. Also more
# self-consistent: a recipe_build linking against a mix of FloraOS's own
# from-source glibc and Arch's other fetched libraries would be a strictly
# worse ABI bet than linking against one coherent Arch closure end to end
# (the same ABI-by-coincidence caveat this whole fallback already accepts
# elsewhere, not a new risk introduced here).
alpm_sandbox_fetch() {
	local dest=$1; shift
	local total=0
	local -a pkg_repo=() pkg_name=() pkg_version=() pkg_filename=() pkg_sha256=()
	local -A seen=()
	local name repo pkgname pkgversion filename sha256 resolved
	for name in "$@"; do
		resolved=$(alpm_resolve "$name") \
			|| die "couldn't resolve '$name' in any configured Arch/Artix repo"
		# A build-dep list can legitimately name overlapping closures (e.g.
		# two build deps both pulling in glibc) -- seen[] skips a package
		# already queued from an earlier name in "$@" rather than fetching
		# and extracting it twice.
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
		[ "${pkg_name[$i]}" = "filesystem" ] && continue
		queue+=("$i")
	done
	alpm_parallel_fetch "$jobs_dir" 4 "${queue[@]}"

	mkdir -p "$dest"
	for i in "${queue[@]}"; do
		local archive="$jobs_dir/$i.pkg"
		[ -f "$archive" ] || die "fetching ${pkg_name[$i]} failed (see errors above)"
		local extract_dir; extract_dir=$(mktemp -d)
		tar --zstd -xf "$archive" -C "$extract_dir"
		rm -f "$archive"
		# Same two reasons as install_one_alpm/app_install_one_alpm above:
		# some packages ship unreadable setuid-root helpers (harmless here,
		# unprivileged sandbox), and neither pacman's own bookkeeping files
		# nor a bind-mounted-into-nothing .INSTALL script belong in one.
		chmod -R u+rX "$extract_dir"
		rm -f "$extract_dir/.PKGINFO" "$extract_dir/.BUILDINFO" "$extract_dir/.MTREE" "$extract_dir/.INSTALL"
		# No usr/include strip here -- see this function's own header
		# comment; keeping headers is the entire reason it exists.
		#
		# fauelf, same reasoning as app_install_one_alpm: a sandboxed
		# build tool (meson, a compiler, ...) gets its own deps found via
		# PATH/LD_LIBRARY_PATH pointed at this same <dest-dir>, exactly
		# like an isolated app's wrapper -- an absolute DT_NEEDED entry
		# would bypass that the same way it would for an app.
		while IFS= read -r -d '' f; do
			"$FAU_ELF_PATCH" "$f" || die "fauelf failed patching $f"
		done < <(find "$extract_dir" -type f -print0)
		# Some build tools are interpreted scripts with an absolute
		# interpreter path baked into their own shebang at build time --
		# meson's real Arch package ships literally "#!/usr/bin/python",
		# not "#!/usr/bin/env python". A "#!/usr/bin/env foo" shebang
		# needs no fix (env itself resolves "foo" via PATH, already
		# pointed at this sandbox by the caller), but a direct absolute
		# path bypasses PATH entirely and would try to exec the *real*
		# system's copy -- which doesn't exist at all on FloraOS (no
		# Python ships anywhere, see fau-build's own header comment).
		# Rewriting every such shebang to be <dest>-prefixed instead
		# fixes this regardless of which order this loop happens to
		# process packages in: the interpreter (e.g. python, also part
		# of meson's own resolved closure) is guaranteed to land
		# somewhere under <dest> by the time this whole function
		# returns, even if not yet at the exact moment this specific
		# package's shebang gets rewritten. Verified for real: extracted
		# meson+python this way, masked the real system's own python out
		# entirely (bwrap, so as to not touch this actual build host),
		# and a trivial C project still configured/built/ran correctly
		# through the rewritten, fully relocated copy.
		local f shebang interp
		while IFS= read -r -d '' f; do
			shebang=$(head -c 256 "$f" 2>/dev/null | head -n1)
			case "$shebang" in
				'#!/'*)
					interp=${shebang#\#!}
					interp=${interp%% *}
					sed -i "1s|^#!${interp}|#!${dest}${interp}|" "$f"
					;;
			esac
		done < <(find "$extract_dir" -type f -print0)
		cp -a "$extract_dir/." "$dest"
		rm -rf "$extract_dir"
	done
	rm -rf "$jobs_dir"
}
