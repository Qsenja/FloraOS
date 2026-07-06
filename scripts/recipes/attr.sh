# libattr. Several gnulib-based tools (sed, tar, coreutils, ...) auto-detect
# and link against this if it's present on the build host, whether or not
# their own configure was told to care about xattrs. Ship it so those
# binaries actually load inside the running OS.
PKG_DESCRIPTION="extended attributes library (libattr) — auto-linked by gnulib-based tools"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure --prefix=/usr --disable-static
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
