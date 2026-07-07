# kmod -- see docs/MANIFEST.md. Must build before eudev (scripts/recipes/eudev.sh).
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

		# this autotools-era version's install doesn't create the argv[0]-dispatch symlinks itself
		for tool in depmod insmod rmmod lsmod modinfo modprobe; do
			ln -sf kmod "$files/usr/bin/$tool"
		done
	)
}
