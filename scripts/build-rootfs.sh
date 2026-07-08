#!/usr/bin/env bash
# Builds the FloraOS base rootfs from source into $WORK_DIR/rootfs. See
# docs/ARCHITECTURE.md's "Build pipeline" section for the full reasoning.
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
	# Below this point: runtime deps only (fau, OpenRC services, floralogin,
	# floraseat) -- see docs/ARCHITECTURE.md's "Build pipeline" section and
	# docs/MANIFEST.md for why each is here.
	attr
	acl
	grep
	sed
	gawk
	findutils
	tar
	zstd
	rsync
	procps-ng
	hostname
	kbd
	gzip
	libxcrypt
	# mbedtls must build before curl -- curl.sh links against its staged files.
	mbedtls
	curl
	# kmod must build before eudev -- eudev's configure links its pkgconfig file.
	kmod
	eudev
)
BUILD_ORDER=("${MANDATORY_ORDER[@]}" ${EXTRA_PACKAGES:-})

pinned_kernel=$(version_field linux-lts 1)
[ "${KERNEL_VERSION:-$pinned_kernel}" = "$pinned_kernel" ] || die \
	"floraos.conf requests kernel $KERNEL_VERSION but config/versions.conf pins linux-lts at $pinned_kernel -- update versions.conf (URL + sha256) to change kernel version"

for cmd in curl tar zstd make gcc sha256sum rsync fakeroot autoreconf gperf; do require_cmd "$cmd"; done

# already_built <name> -- true if this exact pinned version is already packaged.
already_built() {
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
	# Reset each iteration -- see docs/ARCHITECTURE.md ("Build pipeline").
	PKG_BIN=""
	# shellcheck source=/dev/null
	source "$SELF_DIR/recipes/$name.sh"

	local tarball src
	tarball=$(fetch_source "$name")
	src=$(extract_source "$name" "$tarball")

	local version files
	version=$(version_field "$name" 1)
	# Must differ from $STAGE_DIR/$name/files -- package_stage rm -rf's that path.
	files="$BUILD_DIR/$name-install"
	rm -rf "$files"
	mkdir -p "$files"

	recipe_build "$src" "$files"
	package_stage "$name" "$version" "$PKG_DESCRIPTION" "$PKG_DEPENDS" "$files" "${PKG_BIN:-}"
}

main() {
	mkdir -p "$SOURCES_DIR" "$BUILD_DIR" "$STAGE_DIR" "$REPO_DIR"

	for name in "${BUILD_ORDER[@]}"; do
		build_package "$name"
	done

	log "=== assembling rootfs ==="
	rm -rf "$ROOTFS_DIR"
	mkdir -p "$ROOTFS_DIR/usr/bin" "$ROOTFS_DIR/usr/lib"
	# Pre-seed merged-/usr symlinks before installing any package.
	ln -s usr/bin "$ROOTFS_DIR/bin"
	ln -s usr/bin "$ROOTFS_DIR/sbin"
	ln -s usr/lib "$ROOTFS_DIR/lib"
	ln -s usr/lib "$ROOTFS_DIR/lib64"
	ln -s bin "$ROOTFS_DIR/usr/sbin"

	# fau (dispatcher + fau-* tools + lib/*.sh) ships in the OS itself, not
	# just as a build-host tool -- see docs/ARCHITECTURE.md's fau section.
	# usr/lib/fau/recipes/ (FAU_RECIPES_DIR) is deliberately left EMPTY here,
	# not pre-populated from fau-recipes/ -- recipes come from
	# FAU_RECIPES_REPO over the network (fau-build's own recipes_sync), on
	# purpose, so a new/updated recipe reaches every machine the moment it's
	# pushed there, with no ISO rebuild involved at all. FAU_RECIPES_DIR
	# still exists as a directory (and fau still consults it) purely as a
	# manual local-override spot, e.g. someone's own private, unpublished
	# recipe -- never auto-filled by this build. See tools/fau/fau.md.
	mkdir -p "$ROOTFS_DIR/usr/lib/fau/lib" "$ROOTFS_DIR/usr/lib/fau/recipes"
	for f in "$FAU_TOOLS_DIR"/fau "$FAU_TOOLS_DIR"/fau-*; do
		[ -f "$f" ] || continue
		cp "$f" "$ROOTFS_DIR/usr/lib/fau/"
		chmod 755 "$ROOTFS_DIR/usr/lib/fau/$(basename "$f")"
	done
	cp "$FAU_TOOLS_DIR"/lib/*.sh "$ROOTFS_DIR/usr/lib/fau/lib/"
	ln -s ../lib/fau/fau "$ROOTFS_DIR/usr/bin/fau"

	# floragrub-cfg ships in the running OS: florainstall and `fau backup`
	# both exec it by bare name to (re)generate /boot/grub/grub.cfg.
	cp "$FLORAGRUB_CFG_BIN" "$ROOTFS_DIR/usr/bin/floragrub-cfg"
	chmod 755 "$ROOTFS_DIR/usr/bin/floragrub-cfg"

	FAU_REPO_DIR="$REPO_DIR" FAU_ROOT="$ROOTFS_DIR" "$FAU_BIN" bootstrap "${BUILD_ORDER[@]}"

	log "=== staging the kernel image for florainstall (tools/florainstall) ==="
	# build-iso.sh excludes ./boot from the live image, so florainstall needs
	# its own copy of the kernel elsewhere to install onto a real disk.
	mkdir -p "$ROOTFS_DIR/usr/lib/floraos"
	cp "$ROOTFS_DIR/boot/vmlinuz-floraos" "$ROOTFS_DIR/usr/lib/floraos/vmlinuz-floraos"

	log "=== shipping a pacman mirrorlist/repo-list for fau's own use ==="
	if [ -f /etc/pacman.d/mirrorlist ] && [ -f /etc/pacman.conf ]; then
		mkdir -p "$ROOTFS_DIR/etc/fau"
		cp /etc/pacman.d/mirrorlist "$ROOTFS_DIR/etc/fau/pacman-mirrorlist"
		grep -oE '^\[[a-zA-Z0-9_.-]+\]' /etc/pacman.conf | tr -d '[]' | grep -vx options \
			> "$ROOTFS_DIR/etc/fau/pacman-repos"
	else
		log "no /etc/pacman.d/mirrorlist or /etc/pacman.conf on this build host -- fau's alpm fallback won't work after boot"
	fi

	log "=== installing the CA certificate bundle (curl needs it for HTTPS) ==="
	local ca_bundle; ca_bundle=$(fetch_source ca-certificates)
	mkdir -p "$ROOTFS_DIR/etc/ssl/certs"
	cp "$ca_bundle" "$ROOTFS_DIR/etc/ssl/certs/ca-certificates.crt"

	log "=== compiling floralogin (FloraOS's own PAM-free login) ==="
	gcc -Wall -Wextra -O2 \
		-I"$ROOTFS_DIR/usr/include" -L"$ROOTFS_DIR/usr/lib" \
		-o "$ROOTFS_DIR/usr/bin/floralogin" \
		"$FLORA_ROOT/tools/floralogin/floralogin.c" -lcrypt
	chmod 755 "$ROOTFS_DIR/usr/bin/floralogin"

	log "=== restoring sulogin (sysvinit's own emergency single-user-mode shell) ==="
	# Rebuilt from a fresh extraction, now that libxcrypt is staged -- see
	# docs/ARCHITECTURE.md for why scripts/recipes/sysvinit.sh drops it.
	{
		sulogin_tarball=$(fetch_source sysvinit)
		sulogin_src=$(extract_source sysvinit-sulogin "$sulogin_tarball")
		gcc -Wall -Wextra -O2 -D_GNU_SOURCE -D_XOPEN_SOURCE \
			-I"$sulogin_src/src" -I"$ROOTFS_DIR/usr/include" -L"$ROOTFS_DIR/usr/lib" \
			-o "$ROOTFS_DIR/usr/bin/sulogin" \
			"$sulogin_src/src/sulogin.c" "$sulogin_src/src/consoles.c" -lcrypt
		chmod 755 "$ROOTFS_DIR/usr/bin/sulogin"
	}

	log "=== compiling fauelf (fau's own absolute-DT_NEEDED fixup tool) ==="
	gcc -Wall -Wextra -O2 \
		-o "$ROOTFS_DIR/usr/bin/fauelf" \
		"$FLORA_ROOT/tools/fauelf/fauelf.c"
	chmod 755 "$ROOTFS_DIR/usr/bin/fauelf"

	log "=== compiling floraseat (FloraOS's own seatd-protocol-compatible seat daemon) ==="
	gcc -Wall -Wextra -O2 \
		-o "$ROOTFS_DIR/usr/bin/floraseat" \
		"$FLORA_ROOT/tools/floraseat/floraseat.c"
	chmod 755 "$ROOTFS_DIR/usr/bin/floraseat"

	log "=== compiling florauser (FloraOS's own useradd/passwd/groupadd) ==="
	gcc -Wall -Wextra -O2 \
		-I"$ROOTFS_DIR/usr/include" -L"$ROOTFS_DIR/usr/lib" \
		-o "$ROOTFS_DIR/usr/bin/florauser" \
		"$FLORA_ROOT/tools/florauser/florauser.c" -lcrypt
	chmod 755 "$ROOTFS_DIR/usr/bin/florauser"

	log "=== compiling florainstall (FloraOS's own TUI disk installer) ==="
	# -lncursesw/-lmenuw (widec): the real build output; -lncurses/-lmenu are
	# just compatibility symlinks for other software, not needed here.
	gcc -Wall -Wextra -O2 \
		-I"$ROOTFS_DIR/usr/include" -L"$ROOTFS_DIR/usr/lib" \
		-o "$ROOTFS_DIR/usr/bin/florainstall" \
		"$FLORA_ROOT/tools/florainstall/florainstall.c" -lncursesw -lmenuw
	chmod 755 "$ROOTFS_DIR/usr/bin/florainstall"

	log "=== libgcc: base C++ runtime (libgcc_s.so.1), via fau's alpm fallback ==="
	# kitty is left out deliberately -- see docs/ARCHITECTURE.md.
	if [ -f /etc/pacman.d/mirrorlist ] && [ -f /etc/pacman.conf ]; then
		FAU_REPO_DIR="$REPO_DIR" FAU_ROOT="$ROOTFS_DIR" "$FAU_BIN" bootstrap libgcc

		log "=== branding: fastfetch, installed as an isolated app under root's own ~/apps/ ==="
		# FAU_ELF_PATCH: fauelf isn't on the build host's PATH -- point at the
		# copy just compiled above instead.
		FAU_REPO_DIR="$REPO_DIR" FAU_ROOT="$ROOTFS_DIR" FAU_APPS_DIR="$ROOTFS_DIR/root/apps" \
			FAU_ELF_PATCH="$ROOTFS_DIR/usr/bin/fauelf" "$FAU_BIN" install fastfetch

		# Rewrite out the build-host staging-root prefix the wrapper baked in
		# (see docs/ARCHITECTURE.md) -- otherwise its exec line fails at login.
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
	kernel_release=$(cat "$ROOTFS_DIR/boot/kernelrelease")
	"$ROOTFS_DIR/usr/bin/depmod" -b "$ROOTFS_DIR" "$kernel_release"

	log "rootfs ready at $ROOTFS_DIR"
}

main "$@"
