# zstd. fau's package format is .fau.tar.zst -- without shipping zstd, fau
# can't extract or build any package inside the running OS.
PKG_DESCRIPTION="Zstandard compression (zstd)"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# HAVE_ZLIB/LZMA/LZ4 auto-probe the build host and, if found, link
		# the zstd CLI against them for optional .gz/.xz/.lz4 passthrough
		# support -- not needed for fau's own .tar.zst usage, and each is a
		# dependency FloraOS would otherwise need to ship just for this.
		make -j"$jobs" HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0
		fakeroot -- make DESTDIR="$files" PREFIX=/usr HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 install
	)
}
