PKG_DESCRIPTION="GNU core utilities"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure --prefix=/usr
		make -j"$jobs"
		make DESTDIR="$files" install
	)
}
