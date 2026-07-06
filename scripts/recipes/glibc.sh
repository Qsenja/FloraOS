# glibc: built as a native (non-cross) rebuild against this build host's
# compiler, using the sanitized kernel headers from the linux-lts recipe.
# Must run after linux-lts (needs $LINUX_HEADERS_DIR).
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
		make DESTDIR="$files" install
	)
}
