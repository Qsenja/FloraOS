# kbd -- see docs/MANIFEST.md.
PKG_DESCRIPTION="loadkeys/dumpkeys/setfont -- console keymap and font tools"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# vlock requires PAM (unshipped); zlib/bzip2/lzma unshipped; zstd kept (fau needs it)
		./configure --prefix=/usr --disable-vlock --disable-tests --disable-xkb \
			--without-zlib --without-bzip2 --without-lzma
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
