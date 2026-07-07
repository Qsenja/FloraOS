# eudev: systemd-free udev fork (Gentoo-maintained). Needed because libinput
# (and, later, mesa/wlroots when fetched via fau's alpm fallback) hard-require
# libudev at both build and run time -- there is no supported udev-less
# fallback upstream, so this isn't an optional convenience the way most
# FloraOS packages are justified (see docs/MANIFEST.md). Gives FloraOS
# /dev/input/*, /dev/dri/* device nodes with correct perms and hotplug
# uevents, which is the other real prerequisite (besides floraseat, see
# tools/floraseat) for `fau install <wm>` to actually be able to draw
# anything -- see ARCHITECTURE.md's GUI-readiness section.
#
# kmod support (--enable-kmod, via scripts/recipes/kmod.sh, built just
# before this package -- see build-rootfs.sh's MANDATORY_ORDER): lets
# eudev's own udev rules trigger `modprobe` on a hotplug uevent whose
# MODALIAS matches a built module (real GPU vendor drivers, see
# linux-lts.sh's DRM_AMDGPU/DRM_NOUVEAU as modules). Pointed at kmod's own
# *staged* pkgconfig file ($STAGE_DIR, shared across every recipe -- see
# lib/common.sh), not the build host's ambient one -- same reasoning as
# curl.sh's --with-mbedtls pointing at mbedtls's staged files instead of
# whatever TLS library this build host happens to have installed.
# --disable-blkid/--disable-selinux: both optional upstream (clean
# fallback, not a hard failure), neither needed for device nodes/hotplug --
# blkid support only feeds /dev/disk/by-uuid symlinks (persistent-storage
# udev rules), selinux is irrelevant (FloraOS ships none).
# --disable-manpages: already the configure default; stated explicitly so
# it doesn't silently change if upstream ever flips the default.
PKG_DESCRIPTION="systemd-free udev fork -- device nodes/perms/hotplug for libinput and friends"
PKG_DEPENDS="glibc,kmod"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# gperf: eudev's configure.ac unconditionally AC_PATH_TOOLs for it
		# (not gated behind any --disable flag, unlike blkid/selinux
		# above) to generate lookup tables for hwdb/keyboard-key-name
		# parsing -- dies with "*** gperf not found" otherwise. Confirmed
		# directly against this exact tarball: every other configure check
		# passes with the flags below, gperf is the only real new
		# build-host requirement this package adds (see the required_cmd
		# list in build-rootfs.sh).
		# PKG_CONFIG=pkg-config: this exact tarball's generated `configure`
		# doesn't reliably resolve $PKG_CONFIG on its own in every build
		# environment -- confirmed directly (reproduced: `./configure`
		# with only PKG_CONFIG_LIBDIR/PKG_CONFIG_PATH set still failed
		# "*** kmod support requested, but libraries not found" even
		# though `pkg-config --exists libkmod` against the exact same
		# PKG_CONFIG_LIBDIR succeeds on the command line; setting
		# PKG_CONFIG explicitly makes PKG_CHECK_EXISTS/PKG_CHECK_MODULES
		# find it every time). Harmless/redundant on a build host where
		# the bare AC_PATH_TOOL lookup would have worked anyway.
		PKG_CONFIG=pkg-config \
		PKG_CONFIG_LIBDIR="$STAGE_DIR/kmod/files/usr/lib/pkgconfig" PKG_CONFIG_PATH= \
		./configure --prefix=/usr --exec-prefix=/usr \
			--bindir=/usr/bin --sbindir=/usr/bin \
			--libdir=/usr/lib --sysconfdir=/etc \
			--with-rootprefix=/usr --with-rootlibdir=/usr/lib \
			--enable-kmod \
			--disable-blkid --disable-selinux \
			--disable-manpages --disable-static
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
