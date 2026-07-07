# GNU gzip -- see docs/MANIFEST.md.
PKG_DESCRIPTION="GNU gzip -- lets kbd's loadkeys/dumpkeys decompress .gz keymaps/fonts directly"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure --prefix=/usr
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
