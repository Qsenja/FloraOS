# GNU sed -- see docs/MANIFEST.md.
PKG_DESCRIPTION="GNU sed"
PKG_DEPENDS="glibc,attr,acl"

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
