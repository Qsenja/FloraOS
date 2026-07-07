# GNU gzip. kbd's loadkeys/dumpkeys shell out to gzip to decompress
# .gz-compressed keymaps/fonts, falling back to its own internal
# decompression when it's missing -- which FloraOS didn't ship, producing
# cosmetic stderr noise on every boot (see docs/TODO.md). Plain autotools
# build, no optional deps to turn off.
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
