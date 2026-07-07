# glibc: must build after linux-lts (needs $LINUX_HEADERS_DIR).
PKG_DESCRIPTION="GNU C library"
PKG_DEPENDS="linux-lts"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)

	[ -d "$LINUX_HEADERS_DIR" ] || die "glibc: kernel headers not found at $LINUX_HEADERS_DIR (build linux-lts first)"

	local build_dir="$BUILD_DIR/glibc-build"
	rm -rf "$build_dir"
	mkdir -p "$build_dir"

	(
		cd "$build_dir"
		"$src/configure" \
			--prefix=/usr \
			--with-headers="$LINUX_HEADERS_DIR" \
			--disable-werror \
			--enable-kernel=5.4 \
			libc_cv_slibdir=/usr/lib
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install

		# memusagestat needs libgd, which FloraOS doesn't ship -- see docs/MANIFEST.md
		rm -f "$files/usr/bin/memusagestat"
	)
}
