# lib/recipes.sh -- fetches github.com/Qsenja/fau-recipes as a plain HTTPS
# tarball snapshot, no `git` involved. Requires lib/common.sh already sourced.
# See fau.md.

# Best-effort: a fetch failure is logged and swallowed (return 1), never
# die()'d -- both callers (cmd_build, cmd_update) need to keep working
# offline off of whatever's already in FAU_RECIPES_REMOTE_DIR or the
# ISO-shipped FAU_RECIPES_DIR fallback, not hard-fail a build/update just
# because the network happened to be down at that exact moment. Setting
# FAU_RECIPES_REPO="" explicitly (as opposed to leaving it unset, which
# takes the real default) skips the network call entirely -- for anyone who
# wants fully offline, shipped-recipes-only behavior on purpose.
recipes_sync() {
	[ -n "${FAU_RECIPES_REPO:-}" ] || return 0
	local url="${FAU_RECIPES_REPO%/}/archive/refs/heads/${FAU_RECIPES_BRANCH}.tar.gz"
	local tmp; tmp=$(mktemp)
	if ! curl -sL --fail -o "$tmp" "$url" 2>/dev/null; then
		rm -f "$tmp"
		log "warning: couldn't fetch recipes from $FAU_RECIPES_REPO (offline?) -- using whatever's already cached/shipped"
		return 1
	fi
	# tmp-dir-then-rename: a build/update reading FAU_RECIPES_REMOTE_DIR
	# concurrently (the three-way parallel fetch in fau-build's own
	# cmd_build) must never see a half-extracted directory.
	local work; work=$(mktemp -d)
	if ! tar -xzf "$tmp" -C "$work" --strip-components=1 2>/dev/null; then
		rm -f "$tmp"; rm -rf "$work"
		log "warning: fetched recipes archive from $FAU_RECIPES_REPO but couldn't extract it -- using whatever's already cached/shipped"
		return 1
	fi
	rm -f "$tmp"
	rm -rf "$FAU_RECIPES_REMOTE_DIR"
	mkdir -p "$(dirname "$FAU_RECIPES_REMOTE_DIR")"
	mv "$work" "$FAU_RECIPES_REMOTE_DIR"
	return 0
}

# The remote-synced copy wins over the read-only ISO-shipped fallback when
# both have a same-named recipe -- see fau.md.
recipe_lookup() {
	local name=$1
	if [ -f "$FAU_RECIPES_REMOTE_DIR/$name.fis" ]; then
		echo "$FAU_RECIPES_REMOTE_DIR/$name.fis"
	elif [ -f "$FAU_RECIPES_DIR/$name.fis" ]; then
		echo "$FAU_RECIPES_DIR/$name.fis"
	else
		return 1
	fi
}

recipe_list_names() {
	{
		[ -d "$FAU_RECIPES_REMOTE_DIR" ] && find "$FAU_RECIPES_REMOTE_DIR" -maxdepth 1 -name '*.fis' -printf '%f\n' 2>/dev/null
		[ -d "$FAU_RECIPES_DIR" ] && find "$FAU_RECIPES_DIR" -maxdepth 1 -name '*.fis' -printf '%f\n' 2>/dev/null
	} | sed 's/\.fis$//' | sort -u
}
