# libacl. Same reasoning as attr.sh: gnulib-based tools (sed here) auto-link
# against this if present on the build host, regardless of whether their
# own build was asked to care about ACLs.
PKG_DESCRIPTION="POSIX ACL library (libacl) — auto-linked by gnulib-based tools"
PKG_DEPENDS="glibc,attr"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure --prefix=/usr --disable-static
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
