#!/usr/bin/env bash
# Builds the FloraOS base rootfs from source into $WORK_DIR/rootfs.
# Every package is compiled from its pinned upstream source (config/versions.conf),
# staged, packaged as a .fau.tar.zst, and installed via fau — nothing here
# touches the real host system; everything lives under work/ (gitignored).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

FLORAOS_CONF="$FLORA_ROOT/config/floraos.conf"
[ -f "$FLORAOS_CONF" ] || die "missing config file: $FLORAOS_CONF"
# shellcheck source=/dev/null
source "$FLORAOS_CONF"

MANDATORY_ORDER=(
	linux-lts
	glibc
	sysvinit
	openrc
	ncurses
	bash
	coreutils
	util-linux
	e2fsprogs
	iproute2
	libmd
	dhcpcd
	# The rest of these exist for one reason: fau itself needs them at
	# runtime (grep/sed/gawk/find+xargs/tar/zstd/rsync — see each recipe's
	# own comment for exactly which fau code path uses it). They only
	# "worked" during the build because the build host has them; without
	# shipping them, fau is broken inside the actual booted OS.
	attr
	acl
	grep
	sed
	gawk
	findutils
	tar
	zstd
	rsync
	# sysctl/hostname/loadkeys+dumpkeys: OpenRC's sysinit services for these
	# fail non-fatally without them (see docs/MANIFEST.md for each package's
	# one-line reason).
	procps-ng
	hostname
	kbd
	# libxcrypt: glibc itself dropped crypt() -- floralogin (compiled below,
	# not a fau package itself) needs it to verify /etc/shadow hashes. See
	# scripts/recipes/libxcrypt.sh and tools/floralogin.
	libxcrypt
	# mbedtls/curl: fau's alpm (Arch/Artix repo) fallback (tools/fau/fau) needs an
	# HTTP client to fetch anything once running inside a booted FloraOS
	# system (no pacman there to shell out to) -- found by actually running
	# `fau install` after boot: it failed immediately with "curl: command
	# not found". mbedtls is curl's TLS backend (mirrors are HTTPS-only);
	# order matters here, mbedtls must build first (curl.sh links against
	# its staged files directly, see scripts/recipes/curl.sh).
	mbedtls
	curl
	# kmod: must build before eudev -- eudev's own configure links against
	# kmod's staged pkgconfig file (see eudev.sh's PKG_CONFIG_LIBDIR).
	# Real GPU driver modules (amdgpu/nouveau, see linux-lts.sh) and
	# anything else not built into vmlinuz can't be loaded without this.
	kmod
	# eudev: libinput (and mesa/wlroots, fetched later via fau's alpm
	# fallback) hard-require libudev -- see scripts/recipes/eudev.sh and
	# ARCHITECTURE.md's GUI-readiness section.
	eudev
)
BUILD_ORDER=("${MANDATORY_ORDER[@]}" ${EXTRA_PACKAGES:-})

pinned_kernel=$(version_field linux-lts 1)
[ "${KERNEL_VERSION:-$pinned_kernel}" = "$pinned_kernel" ] || die \
	"floraos.conf requests kernel $KERNEL_VERSION but config/versions.conf pins linux-lts at $pinned_kernel -- update versions.conf (URL + sha256) to change kernel version"

# autoreconf: procps-ng only publishes a raw source-archive tarball (no
# generated configure), unlike every other package here -- see its recipe.
# gperf: eudev's configure.ac unconditionally requires it (see
# scripts/recipes/eudev.sh) -- the only new build-host tool this project's
# GUI-readiness work added; everything else needed (blkid, kmod, selinux)
# degrades gracefully when absent instead of failing the build.
for cmd in curl tar zstd make gcc sha256sum rsync fakeroot autoreconf gperf; do require_cmd "$cmd"; done

already_built() {
	# already_built <name> -- true if the repo already has this exact
	# pinned version packaged. Lets a retry after a downstream failure skip
	# expensive earlier steps (kernel, glibc) instead of rebuilding them --
	# extract_source always wipes and re-extracts, so without this check
	# every retry redoes the whole pipeline from package #1.
	local name=$1 version; version=$(version_field "$name" 1)
	local repo="$REPO_DIR/repo.json"
	[ -f "$repo" ] || return 1
	grep -q "\"${name}\":{\"version\":\"${version}\"" "$repo"
}

build_package() {
	local name=$1
	if already_built "$name"; then
		log "=== $name (already built, skipping -- rm work/repo to force a rebuild) ==="
		return
	fi
	log "=== $name ==="
	# shellcheck source=/dev/null
	source "$SELF_DIR/recipes/$name.sh"

	local tarball src
	tarball=$(fetch_source "$name")
	src=$(extract_source "$name" "$tarball")

	local version files
	version=$(version_field "$name" 1)
	# Must be distinct from $STAGE_DIR/$name/files -- package_stage rm -rf's
	# and recreates that path, which would delete this out from under itself.
	files="$BUILD_DIR/$name-install"
	rm -rf "$files"
	mkdir -p "$files"

	recipe_build "$src" "$files"
	package_stage "$name" "$version" "$PKG_DESCRIPTION" "$PKG_DEPENDS" "$files"
}

main() {
	mkdir -p "$SOURCES_DIR" "$BUILD_DIR" "$STAGE_DIR" "$REPO_DIR"

	for name in "${BUILD_ORDER[@]}"; do
		build_package "$name"
	done

	log "=== assembling rootfs ==="
	rm -rf "$ROOTFS_DIR"
	mkdir -p "$ROOTFS_DIR/usr/bin" "$ROOTFS_DIR/usr/lib"
	# Pre-seed the merged-/usr symlinks *before* installing any package, so
	# every package's own bin/sbin/lib/lib64 output merges straight into
	# usr/bin and usr/lib instead of creating separate real directories.
	ln -s usr/bin "$ROOTFS_DIR/bin"
	ln -s usr/bin "$ROOTFS_DIR/sbin"
	ln -s usr/lib "$ROOTFS_DIR/lib"
	ln -s usr/lib "$ROOTFS_DIR/lib64"
	# autotools' default sbindir is a separate ${prefix}/sbin; merge it into
	# usr/bin too so every package lands in one place regardless of flags.
	ln -s bin "$ROOTFS_DIR/usr/sbin"

	# fau itself: a portable bash script, nothing to compile -- but it must
	# actually ship in the OS, not just be a build-host tool, since it's
	# FloraOS's own package manager and the whole point is for the running
	# system to use it (fastfetch's Packages line depends on this too).
	cp "$FAU_BIN" "$ROOTFS_DIR/usr/bin/fau"
	chmod 755 "$ROOTFS_DIR/usr/bin/fau"

	FAU_REPO_DIR="$REPO_DIR" FAU_ROOT="$ROOTFS_DIR" "$FAU_BIN" bootstrap "${BUILD_ORDER[@]}"

	log "=== staging the kernel image for florainstall (tools/florainstall) ==="
	# build-iso.sh's own initramfs-packing step deliberately excludes
	# everything under ./boot from the live image (GRUB reads
	# boot/vmlinuz-floraos directly off the ISO's own boot/ directory --
	# embedding the kernel a second time inside the very initramfs it boots
	# from would be redundant). That means the *running* live system has no
	# /boot/vmlinuz-floraos anywhere in it. florainstall needs the actual
	# kernel image to copy onto a real disk it's installing to, so a copy is
	# staged here at a path that isn't under ./boot and does survive into
	# the live initramfs -- see tools/florainstall/florainstall.c's own
	# header comment for the full reasoning.
	mkdir -p "$ROOTFS_DIR/usr/lib/floraos"
	cp "$ROOTFS_DIR/boot/vmlinuz-floraos" "$ROOTFS_DIR/usr/lib/floraos/vmlinuz-floraos"

	log "=== shipping a pacman mirrorlist/repo-list for fau's own use ==="
	# fau's alpm (Arch/Artix repo) fallback (tools/fau/fau) never shells out to the
	# `pacman` binary -- it reads the mirrorlist and sync-db formats
	# directly -- but it still needs to know which mirror and which repos
	# to ask, and /etc/pacman.d/mirrorlist + /etc/pacman.conf don't exist
	# inside a booted FloraOS system. Shipping a copy here is what makes
	# `fau install <pkg>` work after boot, not just during this build.
	if [ -f /etc/pacman.d/mirrorlist ] && [ -f /etc/pacman.conf ]; then
		mkdir -p "$ROOTFS_DIR/etc/fau"
		cp /etc/pacman.d/mirrorlist "$ROOTFS_DIR/etc/fau/pacman-mirrorlist"
		grep -oE '^\[[a-zA-Z0-9_.-]+\]' /etc/pacman.conf | tr -d '[]' | grep -vx options \
			> "$ROOTFS_DIR/etc/fau/pacman-repos"
	else
		log "no /etc/pacman.d/mirrorlist or /etc/pacman.conf on this build host -- fau's alpm fallback won't work after boot"
	fi

	log "=== installing the CA certificate bundle (curl needs it for HTTPS) ==="
	# Not a compiled package -- see config/versions.conf's comment. Reuses
	# fetch_source (format-agnostic: download + sha256-verify + return the
	# path) directly rather than going through the normal recipe pipeline,
	# since extract_source assumes every pinned download is a tarball and
	# this is a single PEM file.
	local ca_bundle; ca_bundle=$(fetch_source ca-certificates)
	mkdir -p "$ROOTFS_DIR/etc/ssl/certs"
	cp "$ca_bundle" "$ROOTFS_DIR/etc/ssl/certs/ca-certificates.crt"

	log "=== compiling floralogin (FloraOS's own PAM-free login) ==="
	# Not a fau package: it's FloraOS-authored source, not a fetched upstream
	# tarball (same reasoning as fau itself not going through the recipe
	# pipeline). Compiled here, after the install above, specifically
	# against *this rootfs's own* just-installed crypt.h/libcrypt.so.1 (via
	# -I/-L pointed at $ROOTFS_DIR) rather than whatever libcrypt the build
	# host happens to have -- linking against the host's copy would bake in
	# a mismatched SONAME the shipped image doesn't actually provide (the
	# same class of bug found and fixed in fau's alpm fallback, see
	# ARCHITECTURE.md).
	gcc -Wall -Wextra -O2 \
		-I"$ROOTFS_DIR/usr/include" -L"$ROOTFS_DIR/usr/lib" \
		-o "$ROOTFS_DIR/usr/bin/floralogin" \
		"$FLORA_ROOT/tools/floralogin/floralogin.c" -lcrypt
	chmod 755 "$ROOTFS_DIR/usr/bin/floralogin"

	log "=== compiling fauelf (fau's own absolute-DT_NEEDED fixup tool) ==="
	# Not a fau package either, same reasoning as floralogin above. Unlike
	# floralogin, fauelf needs no FloraOS-specific header/lib (just plain
	# libc: stat/open/read/write/malloc/string) and genuinely needs to run
	# in both places: right here on this *build host* (fau's own
	# app_install_one_alpm calls it below, before this rootfs is ever
	# booted) and later inside the booted image itself (an end user running
	# `fau install <pkg>` after boot). One plain build covers both --
	# relies on the same build-host/FloraOS glibc ABI compatibility this
	# project's alpm fallback already depends on everywhere else (see
	# ARCHITECTURE.md).
	gcc -Wall -Wextra -O2 \
		-o "$ROOTFS_DIR/usr/bin/fauelf" \
		"$FLORA_ROOT/tools/fauelf/fauelf.c"
	chmod 755 "$ROOTFS_DIR/usr/bin/fauelf"

	log "=== compiling floraseat (FloraOS's own seatd-protocol-compatible seat daemon) ==="
	# Not a fau package, same reasoning as floralogin/fauelf above: FloraOS-
	# authored source, not a fetched upstream tarball. Plain libc only --
	# no FloraOS-specific header/lib to link against (unlike floralogin's
	# libcrypt), so no -I/-L pointed at $ROOTFS_DIR needed here.
	gcc -Wall -Wextra -O2 \
		-o "$ROOTFS_DIR/usr/bin/floraseat" \
		"$FLORA_ROOT/tools/floraseat/floraseat.c"
	chmod 755 "$ROOTFS_DIR/usr/bin/floraseat"

	log "=== compiling florauser (FloraOS's own useradd/passwd/groupadd) ==="
	# Not a fau package, same reasoning as floralogin/fauelf/floraseat above:
	# FloraOS-authored source, not a fetched upstream tarball. Needs
	# libcrypt for crypt_gensalt()/crypt_r() (its own `florauser passwd`
	# command), so it's linked the same way floralogin is above: against
	# this rootfs's own just-installed crypt.h/libcrypt.so.1 via -I/-L,
	# not whatever libcrypt the build host happens to have.
	gcc -Wall -Wextra -O2 \
		-I"$ROOTFS_DIR/usr/include" -L"$ROOTFS_DIR/usr/lib" \
		-o "$ROOTFS_DIR/usr/bin/florauser" \
		"$FLORA_ROOT/tools/florauser/florauser.c" -lcrypt
	chmod 755 "$ROOTFS_DIR/usr/bin/florauser"

	log "=== compiling florainstall (FloraOS's own TUI disk installer) ==="
	# Not a fau package, same reasoning as floralogin/fauelf/floraseat/
	# florauser above: FloraOS-authored source, not a fetched upstream
	# tarball. Links against this rootfs's own just-installed ncurses/menu
	# libraries (-I/-L pointed at $ROOTFS_DIR, same reasoning as florauser's
	# libcrypt linking above) -- the widec (-w suffixed) library names
	# directly, since that's ncurses.sh's actual build output; the plain
	# (non-w) names are just compatibility symlinks for *other* software
	# that assumes them, not something this project's own compiles need to
	# rely on.
	gcc -Wall -Wextra -O2 \
		-I"$ROOTFS_DIR/usr/include" -L"$ROOTFS_DIR/usr/lib" \
		-o "$ROOTFS_DIR/usr/bin/florainstall" \
		"$FLORA_ROOT/tools/florainstall/florainstall.c" -lncursesw -lmenuw
	chmod 755 "$ROOTFS_DIR/usr/bin/florainstall"

	log "=== libgcc: base C++ runtime (libgcc_s.so.1), via fau's alpm fallback ==="
	# kitty was deliberately left out here: its dependency closure (Python3 +
	# Mesa + X11/Wayland) is ~773MB, and none of it does anything without a
	# display server FloraOS doesn't have yet (see ARCHITECTURE.md). Install
	# it yourself later with: fau install kitty
	#
	# Same condition as the mirrorlist-shipping step above, not `command -v
	# pacman`: fau's alpm fallback never touches the pacman binary, only
	# these two files' data, so that's the real precondition for this to
	# succeed.
	if [ -f /etc/pacman.d/mirrorlist ] && [ -f /etc/pacman.conf ]; then
		# libgcc (libgcc_s.so.1, C++ exception-handling runtime) is real
		# base-system infrastructure -- other C++ binaries can reasonably
		# assume it's already present, the same way Arch/Artix itself
		# assumes it (it's not a declared dependency of fastfetch below,
		# which needs it, for exactly that reason). Stays bootstrapped
		# (merged into FAU_ROOT), unlike fastfetch itself.
		FAU_REPO_DIR="$REPO_DIR" FAU_ROOT="$ROOTFS_DIR" "$FAU_BIN" bootstrap libgcc

		log "=== branding: fastfetch, installed as an isolated app under root's own ~/apps/ ==="
		# Unlike libgcc, fastfetch isn't something the system needs to run --
		# it's a pure cosmetic branding touch, so it goes through the exact
		# `fau install` path any end user would use for an optional app,
		# landing in $HOME/apps/fastfetch/ (root's own apps dir, since root
		# is the only login here -- see README.md/floralogin) instead of
		# being merged into the system root. It still finds libgcc_s.so.1
		# fine despite being isolated: the app wrapper's LD_LIBRARY_PATH
		# (see app_wrapper_write in tools/fau/fau) is additive, prepended in
		# front of the dynamic linker's own default trusted search path
		# (ld.so.cache, rebuilt below) -- it doesn't replace it, so a
		# genuinely base-system library doesn't need to be duplicated into
		# every isolated app's own directory just to be found.
		# FAU_ROOT must still be set here even though `install` never merges
		# into it -- FAU_CACHE_DIR (the alpm sync-db/index cache) derives
		# from it, defaulting to "/" otherwise, which tried to write into
		# this *build host's own* /var/cache/fau (permission denied) instead
		# of staying scoped under work/ like the rest of this script. Reusing
		# the same ROOTFS_DIR as the libgcc bootstrap call above also means
		# this reuses that call's already-fetched sync db instead of
		# re-fetching/re-indexing it a second time.
		# FAU_ELF_PATCH: fauelf isn't on this build host's own PATH (it's
		# only ever installed *inside* the rootfs) -- point fau straight at
		# the copy just compiled above instead.
		FAU_REPO_DIR="$REPO_DIR" FAU_ROOT="$ROOTFS_DIR" FAU_APPS_DIR="$ROOTFS_DIR/root/apps" \
			FAU_ELF_PATCH="$ROOTFS_DIR/usr/bin/fauelf" "$FAU_BIN" install fastfetch

		# app_wrapper_write (tools/fau/fau) bakes the exact $FAU_APPS_DIR path
		# it was given straight into the wrapper script's HOME/XDG_*/exec
		# lines -- correct for the normal case (fau install run on the live
		# system it'll actually execute on), but here $FAU_APPS_DIR was this
		# *build host's* staging path ($ROOTFS_DIR/root/apps), not the path
		# it'll run from once booted (/root/apps). Left alone, the wrapper's
		# `exec` line pointed at a path that only exists on this build
		# machine -- confirmed by an actual boot: "No such file or
		# directory" logging in, from a real ./floraiso test run, not
		# inferred. Rewriting out the staging-root prefix is exactly enough:
		# every path the wrapper references is $ROOTFS_DIR plus the same
		# suffix it'll have at "/" once booted.
		if [ -f "$ROOTFS_DIR/root/apps/.bin/fastfetch" ]; then
			sed -i "s|$ROOTFS_DIR||g" "$ROOTFS_DIR/root/apps/.bin/fastfetch"
		fi
	else
		log "no /etc/pacman.d/mirrorlist or /etc/pacman.conf on this build host -- skipping libgcc/fastfetch"
	fi

	log "=== applying /etc skeleton ==="
	"$SELF_DIR/apply-skeleton.sh" "$ROOTFS_DIR" "${HOSTNAME:-floraos}"

	log "=== rebuilding ld.so.cache ==="
	"$ROOTFS_DIR/usr/sbin/ldconfig" -r "$ROOTFS_DIR"

	log "=== running depmod (modules.dep/modules.alias for kmod/eudev) ==="
	# Baked in at build time, not left for boot: this image is RAM-resident
	# and rebuilt from scratch every time anyway (see README.md), so
	# there's no "the kernel changed since last boot" case depmod would
	# normally exist to handle. Needs the kernel's own release string
	# (linux-lts.sh's own `make kernelrelease` output, written to
	# boot/kernelrelease) -- depmod defaults to `uname -r` of whatever
	# machine runs it otherwise, which is this *build host's* kernel, not
	# FloraOS's. Runs cross-root the same way ldconfig -r just did above:
	# a plain userspace indexing tool over files, no actual module loading
	# involved.
	kernel_release=$(cat "$ROOTFS_DIR/boot/kernelrelease")
	"$ROOTFS_DIR/usr/bin/depmod" -b "$ROOTFS_DIR" "$kernel_release"

	log "rootfs ready at $ROOTFS_DIR"
}

main "$@"
