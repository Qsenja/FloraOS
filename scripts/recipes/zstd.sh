# zstd -- see docs/MANIFEST.md.
PKG_DESCRIPTION="Zstandard compression (zstd)"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		make -j"$jobs" HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0
		fakeroot -- make DESTDIR="$files" PREFIX=/usr HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 install
	)
}
