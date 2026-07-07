# libxcrypt -- see docs/MANIFEST.md.
PKG_DESCRIPTION="crypt(3) password hashing (glibc dropped it; this is the standard replacement)"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# --disable-werror: this build host's newer gcc raises a warning upstream's CI doesn't hit
		./configure --prefix=/usr --disable-static --disable-werror \
			--enable-obsolete-api=glibc --enable-hashes=strong,glibc
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
