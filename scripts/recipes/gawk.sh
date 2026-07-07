# GNU awk -- see docs/MANIFEST.md.
PKG_DESCRIPTION="GNU awk"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# disables auto-linked optional libs FloraOS doesn't ship (gmp/mpfr, readline)
		./configure --prefix=/usr --disable-mpfr --without-readline
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
