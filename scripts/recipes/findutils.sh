# GNU findutils (find, xargs). fau's app-install bin-entrypoint detection
# uses find; its dependency-list parsing uses xargs -- without these, fau
# is broken inside the running OS.
PKG_DESCRIPTION="GNU findutils (find, xargs)"
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
