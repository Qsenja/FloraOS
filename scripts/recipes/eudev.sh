# eudev: must build after kmod (scripts/recipes/kmod.sh) -- see docs/MANIFEST.md.
PKG_DESCRIPTION="systemd-free udev fork -- device nodes/perms/hotplug for libinput and friends"
PKG_DEPENDS="glibc,kmod"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# PKG_CONFIG set explicitly: configure doesn't reliably resolve $PKG_CONFIG on its own here
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
