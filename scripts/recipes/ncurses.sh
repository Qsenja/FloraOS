# ncurses -- see docs/MANIFEST.md.
PKG_DESCRIPTION="terminal capabilities library (terminfo, libncursesw)"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# --with-versioned-syms required -- see docs/MANIFEST.md
		./configure --prefix=/usr \
			--with-shared \
			--enable-widec \
			--enable-pc-files \
			--with-versioned-syms \
			--without-debug \
			--without-ada \
			--without-tests
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install

		# symlink plain (non-w-suffixed) names to widec libs -- most software still asks for those
		cd "$files/usr/lib"
		for lib in ncurses form panel menu tinfo; do
			[ -e "lib${lib}w.so" ] || continue
			ln -sf "lib${lib}w.so" "lib${lib}.so"
		done
	)
}
