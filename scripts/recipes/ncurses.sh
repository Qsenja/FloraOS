# ncurses: terminal capabilities library. bash (and anything else using
# readline/terminfo) links against libncursesw.so.6 dynamically -- without
# shipping this ourselves, bash fails to even load ("cannot open shared
# object file") since it's not part of any other package here.
PKG_DESCRIPTION="terminal capabilities library (terminfo, libncursesw)"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure --prefix=/usr \
			--with-shared \
			--enable-widec \
			--enable-pc-files \
			--without-debug \
			--without-ada \
			--without-tests
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install

		# Standard trick (LFS uses the same one): most software still asks
		# for the plain (non-w-suffixed) library/header names. Rather than
		# building narrow and wide ncurses separately, symlink the plain
		# names to their widec equivalents.
		cd "$files/usr/lib"
		for lib in ncurses form panel menu tinfo; do
			[ -e "lib${lib}w.so" ] || continue
			ln -sf "lib${lib}w.so" "lib${lib}.so"
		done
	)
}
