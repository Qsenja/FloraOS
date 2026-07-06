PKG_DESCRIPTION="GNU Bourne Again Shell"
PKG_DEPENDS="glibc,ncurses"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure --prefix=/usr --without-bash-malloc
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
