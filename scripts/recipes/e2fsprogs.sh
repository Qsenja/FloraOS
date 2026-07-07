PKG_DESCRIPTION="ext2/3/4 filesystem tools (mkfs.ext4, fsck.ext4)"
PKG_DEPENDS="glibc,util-linux"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	local build_dir="$BUILD_DIR/e2fsprogs-build"
	rm -rf "$build_dir"
	mkdir -p "$build_dir"
	(
		cd "$build_dir"
		"$src/configure" --prefix=/usr \
			--enable-elf-shlibs \
			--disable-libblkid \
			--disable-libuuid \
			--disable-fsck \
			--disable-fuse2fs
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install

		# cramfs tools need libz, which FloraOS doesn't ship -- see docs/MANIFEST.md
		rm -f "$files/usr/sbin/fsck.cramfs" "$files/usr/sbin/mkfs.cramfs"
	)
}
