# kmod: modprobe/depmod/insmod/rmmod/lsmod/modinfo, all one multi-call binary
# dispatching on argv[0] (see tools/kmod.c's own --help: "kmod also handles
# gracefully if called from following symlinks"). Needed so a kernel module
# that isn't built into vmlinuz can actually be loaded -- without this,
# eudev's --enable-kmod (scripts/recipes/eudev.sh) would have nothing to
# link against, and real GPU vendor drivers (amdgpu/nouveau, see
# linux-lts.sh's DRM_AMDGPU/DRM_NOUVEAU as modules) could be built but
# never loaded. Real i915 already ships built into the kernel by defconfig
# itself (CONFIG_DRM_I915=y, confirmed directly against the actual
# linux-6.18.y source tree, not assumed) so it never needed module loading
# in the first place -- kmod is what unlocks the *rest* of the GPU vendor
# matrix, plus general hotplug module autoload for anything else not built
# in.
#
# Still autotools, not meson -- checked directly against the actual kmod
# release history: v29 through at least v31 all ship a real configure.ac
# (upstream migrated kmod's own build to meson later than that). Pinned at
# v31 specifically because it's the newest release confirmed to still be
# autotools-based, keeping this project's existing "no cmake/meson" bias
# intact (same reasoning that led to writing floraseat from scratch instead
# of building real seatd, which never had an autotools option at all).
#
# --with-zstd/xz/zlib all deliberately left at their default (disabled):
# module compression support is only useful if the kernel actually ships
# compressed .ko.zst/.ko.xz/.ko.gz files, which depends on
# CONFIG_MODULE_COMPRESS_* -- linux-lts.sh doesn't touch that, so it stays
# at defconfig's own default (uncompressed modules on x86_64), meaning kmod
# needs none of these to load anything FloraOS actually ships. Confirmed by
# a real end-to-end build+install+run of this exact recipe (configure,
# make, make install, then manually exercising depmod/modprobe/etc through
# their argv[0]-dispatch symlinks) before adding it here, not just reading
# the configure script.
PKG_DESCRIPTION="modprobe/depmod/insmod/rmmod/lsmod/modinfo -- loads kernel modules eudev can't autoload without it"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure --prefix=/usr --sysconfdir=/etc \
			--disable-manpages --disable-test-modules
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install

		# make install only installs the single "kmod" multi-call binary
		# (confirmed directly -- Makefile.am's bin_PROGRAMS is just
		# tools/kmod, no install-time symlink rule exists in this
		# autotools-era version, unlike the newer meson build which adds
		# them via install scripts). Without these, `depmod`/`modprobe`/
		# etc simply don't exist as commands even though the dispatch
		# logic to handle them is compiled in and working.
		for tool in depmod insmod rmmod lsmod modinfo modprobe; do
			ln -sf kmod "$files/usr/bin/$tool"
		done
	)
}
