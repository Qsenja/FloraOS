PKG_DESCRIPTION="mount, fdisk, agetty, losetup, and other core Linux utilities"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure --prefix=/usr \
			--without-systemd \
			--without-systemdsystemunitdir \
			--disable-static
		make -j"$jobs"
		make DESTDIR="$files" install
	)
}
