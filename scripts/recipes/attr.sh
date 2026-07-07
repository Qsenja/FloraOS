# libattr (extended attributes) -- see docs/MANIFEST.md.
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
