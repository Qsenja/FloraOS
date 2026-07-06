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

		# fsck.cramfs/mkfs.cramfs link against libz, which FloraOS doesn't
		# ship -- broken inside the running OS ("cannot open shared object
		# file: libz.so.1"). Pruned rather than adding libz for a legacy
		# filesystem FloraOS doesn't use (ext4 only, via mkfs.ext4/fsck.ext4
		# above, both of which don't need libz).
		rm -f "$files/usr/sbin/fsck.cramfs" "$files/usr/sbin/mkfs.cramfs"
	)
}
