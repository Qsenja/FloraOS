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

for cmd in curl tar zstd make gcc sha256sum rsync fakeroot autoreconf gperf git; do require_cmd "$cmd"; done

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

	# Read by `fau update` (tools/fau/fau-install) to tell a from-source
	# MANDATORY_ORDER/EXTRA_PACKAGES package apart from one bootstrapped via
	# the alpm fallback below (libgcc, fontconfig, dbus, ...) -- the former
	# has no newer version to fetch at runtime at all (only a rebuild with
	# a bumped config/versions.conf pin produces one), the latter does. See
	# tools/fau/fau.md.
	mkdir -p "$ROOTFS_DIR/etc/fau"
	printf '%s\n' "${BUILD_ORDER[@]}" > "$ROOTFS_DIR/etc/fau/source-built-packages"

	# Baseline for `fau update`'s per-file granular update
	# (tools/fau/lib/selfupdate.sh) -- git's own blob sha for the exact
	# tree this ISO was built from, computed locally with `git
	# hash-object` (confirmed byte-identical to what GitHub's Trees API
	# reports for the same content later -- no network needed at build
	# time). _floraos_tracked_paths is sourced from lib/selfupdate.sh
	# itself so this list has exactly one home, not a second copy here.
	: > "$ROOTFS_DIR/etc/fau/installed-manifest"
	while IFS= read -r trackedpath; do
		[ -f "$FLORA_ROOT/$trackedpath" ] || continue
		printf '%s\t%s\n' "$trackedpath" "$(git -C "$FLORA_ROOT" hash-object "$trackedpath")" \
			>> "$ROOTFS_DIR/etc/fau/installed-manifest"
	done < <(
		export FAU_ROOT=/
		source "$FAU_TOOLS_DIR/lib/selfupdate.sh"
		_floraos_tracked_paths
	)

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

		log "=== base fonts: ttf-dejavu, via fau's alpm fallback ==="
		# FloraOS shipped zero font packages until now -- confirmed on a real
		# `foot` run: "Fontconfig error: Cannot load default config file" (see
		# the FONTCONFIG_FILE fix, lib/common.sh) cascading into "failed to
		# match font" / "failed to load primary fonts" (fatal). Installed at
		# the base-system level, not per-app: fontconfig's own default config
		# points at the real, non-isolated /usr/share/fonts (confirmed:
		# `grep '<dir' /etc/fonts/fonts.conf`), and FloraOS has no chroot, so
		# one shared copy here is visible to every isolated app identically --
		# no per-app duplication needed, unlike the libraries fixed above.
		# ttf-dejavu specifically: covers the "monospace" fontconfig alias any
		# terminal emulator looks for by default, small, no font-specific
		# licensing complications.
		FAU_REPO_DIR="$REPO_DIR" FAU_ROOT="$ROOTFS_DIR" "$FAU_BIN" bootstrap ttf-dejavu

		log "=== base fontconfig, via fau's alpm fallback ==="
		# Also installed at the base-system level, same reasoning as
		# ttf-dejavu above: fontconfig's own hardcoded default config path
		# is /etc/fonts/fonts.conf -- shipping the real package here means
		# EVERY app finds it via that same hardcoded default automatically,
		# no per-app FONTCONFIG_FILE override needed at all (that fix in
		# lib/common.sh stays anyway, as a fallback for whatever an
		# individual app happens to bundle, but this is now the primary,
		# correct path). Confirmed on a real `foot` run that having *a*
		# fontconfig isn't sufficient on its own though: with only
		# ttf-dejavu installed, foot rendered fine but picked
		# "DejaVuMathTeXGyre" (a LaTeX math-symbols font also bundled in
		# that package) for the generic "monospace" family instead of the
		# actual "DejaVu Sans Mono" -- fontconfig's real, unmodified
		# defaults have no deterministic preference between the two absent
		# an explicit alias (verified: no shipped package installs one by
		# default). Fixed below via local.conf, fontconfig's own documented
		# site-override hook (see /etc/fonts/conf.d/51-local.conf).
		FAU_REPO_DIR="$REPO_DIR" FAU_ROOT="$ROOTFS_DIR" "$FAU_BIN" bootstrap fontconfig

		# install_one_alpm (lib/alpm.sh) deliberately strips every package's
		# own /etc before merging into the base system -- confirmed: the
		# bootstrap above reports success, but no fonts.conf lands anywhere
		# (`rm -rf "$extract_dir/etc"`, there to stop random upstream
		# packages from clobbering FloraOS's own hand-authored /etc). That's
		# the right call for most packages, but fontconfig's real config
		# lives nowhere else -- its package's own post-install hook
		# ordinarily symlinks /usr/share/fontconfig/conf.default/*.conf into
		# /etc/fonts/conf.d/, but fau never runs post-install hooks
		# (.INSTALL is deleted, same function) -- so both steps have to
		# happen here explicitly instead. fonts.conf's own content below is
		# fontconfig 2.18.1's real upstream default (verified: exact version
		# match against this build host's own installed copy, not a
		# reconstruction) -- copied, not hand-written, so it can't drift
		# from what the package actually ships.
		mkdir -p "$ROOTFS_DIR/etc/fonts/conf.d"
		cp "$ROOTFS_DIR/usr/share/fontconfig/conf.default/"*.conf "$ROOTFS_DIR/etc/fonts/conf.d/"
		cat > "$ROOTFS_DIR/etc/fonts/fonts.conf" <<-'FONTCONFEOF'
		<?xml version="1.0"?>
		<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
		<!-- /etc/fonts/fonts.conf file to configure system font access -->
		<fontconfig>
			<description>Default configuration file</description>
			<dir>/usr/share/fonts</dir>
			<dir>/usr/local/share/fonts</dir>
			<dir prefix="xdg">fonts</dir>
			<dir>~/.fonts</dir>
			<match target="pattern">
				<test qual="any" name="family">
					<string>mono</string>
				</test>
				<edit name="family" mode="assign" binding="same">
					<string>monospace</string>
				</edit>
			</match>
			<match target="pattern">
				<test qual="any" name="family">
					<string>sans serif</string>
				</test>
				<edit name="family" mode="assign" binding="same">
					<string>sans-serif</string>
				</edit>
			</match>
			<match target="pattern">
				<test qual="any" name="family">
					<string>sans</string>
				</test>
				<edit name="family" mode="assign" binding="same">
					<string>sans-serif</string>
				</edit>
			</match>
			<match target="pattern">
				<test qual="any" name="family">
					<string>system ui</string>
				</test>
				<edit name="family" mode="assign" binding="same">
					<string>system-ui</string>
				</edit>
			</match>
			<include ignore_missing="yes">conf.d</include>
			<cachedir>/var/cache/fontconfig</cachedir>
			<cachedir prefix="xdg">fontconfig</cachedir>
			<cachedir>~/.fontconfig</cachedir>
			<config>
				<rescan>
					<int>30</int>
				</rescan>
			</config>
		</fontconfig>
		FONTCONFEOF
		cat > "$ROOTFS_DIR/etc/fonts/local.conf" <<-'FONTEOF'
		<?xml version="1.0"?>
		<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
		<fontconfig>
			<alias>
				<family>monospace</family>
				<prefer>
					<family>DejaVu Sans Mono</family>
				</prefer>
			</alias>
		</fontconfig>
		FONTEOF

		log "=== dbus: message bus, via fau's alpm fallback ==="
		# Found running `kitty` for real: "[glfw error]: Failed to connect
		# to DBUS session bus. DBUS error: Unable to autolaunch a
		# dbus-daemon without a $DISPLAY for X11" -- FloraOS ran no message
		# bus of any kind, and libdbus's own "autolaunch" fallback (used
		# whenever DBUS_SESSION_BUS_ADDRESS isn't set) is genuinely an X11
		# mechanism (stores/reads the bus address via an X11 root window
		# property), hence failing specifically on the missing $DISPLAY even
		# though this is a pure-Wayland session. Installed at the
		# base-system level, same as fontconfig above -- one shared daemon,
		# not per-app (dbus is inherently a shared service, not a library
		# each app links). The actual daemon is started at boot (inittab,
		# apply-skeleton.sh) with an explicit --address, not --session
		# alone: verified with bwrap masking dbus's own /etc/dbus-1 config
		# entirely (confirmed via install_one_alpm's own /etc-strip that it
		# would be missing anyway) -- `dbus-daemon --session --fork
		# --address=unix:path=...` starts and accepts real client
		# connections (verified with dbus-send) with zero config file
		# present at all, since --address explicitly overrides the one
		# thing session.conf would otherwise supply.
		FAU_REPO_DIR="$REPO_DIR" FAU_ROOT="$ROOTFS_DIR" "$FAU_BIN" bootstrap dbus
	else
		log "no /etc/pacman.d/mirrorlist or /etc/pacman.conf on this build host -- skipping libgcc/fastfetch/fonts/dbus"
	fi

	log "=== generating en_US.UTF-8 locale ==="
	# glibc ships localedef and the raw i18n source data (charmaps,
	# locale definitions) but generates nothing at build time -- confirmed
	# empty: no /usr/lib/locale/ at all until this runs. Every program that
	# checks for a real UTF-8 locale falls back to bare POSIX "C" (not
	# UTF-8) and either degrades silently or, like `foot`, refuses to start
	# at all: "'C' is not a UTF-8 locale, and failed to find a fallback" /
	# "No Compose file for locale 'en_US.UTF-8'" -- confirmed on a real run,
	# not guessed. `LANG` is set in /etc/profile (apply-skeleton.sh) right
	# alongside PATH, so every login shell (and anything spawned from it,
	# including mango's own spawned children) inherits a working locale.
	# Explicit full paths for -i/-f, not bare names: localedef's own
	# compiled-in search path is the real /usr/share/i18n/... (confirmed via
	# `strings` on the binary), which would read the BUILD HOST's i18n data
	# instead of FloraOS's own if given bare names -- this binary is
	# FloraOS's own compiled localedef (same cross-execution pattern as
	# ldconfig -r/depmod -b above), but the source data it reads still needs
	# pointing at $ROOTFS_DIR explicitly.
	# localedef doesn't auto-decompress the shipped charmap (confirmed: fed
	# the raw .gz straight in first, got hundreds of "invalid UTF-8
	# sequence" errors from it reading gzip's own binary bytes as text) --
	# decompress to a temp file first. Also needs usr/lib/locale/ to already
	# exist; localedef won't create it, just fails with "cannot create
	# temporary file" if it's missing.
	mkdir -p "$ROOTFS_DIR/usr/lib/locale"
	utf8_charmap=$(mktemp)
	zcat "$ROOTFS_DIR/usr/share/i18n/charmaps/UTF-8.gz" > "$utf8_charmap"
	"$ROOTFS_DIR/usr/bin/localedef" \
		--prefix "$ROOTFS_DIR" \
		-i "$ROOTFS_DIR/usr/share/i18n/locales/en_US" \
		-f "$utf8_charmap" \
		en_US.UTF-8
	rm -f "$utf8_charmap"
	# usr/share/i18n is localedef's own *source* data (every locale/charmap
	# that exists) -- build-time only, never read again once en_US.UTF-8 is
	# generated above. See fau.md's "fau setlang" section for where a live
	# system gets this data if a different locale is ever needed later.
	rm -rf "$ROOTFS_DIR/usr/share/i18n"

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
