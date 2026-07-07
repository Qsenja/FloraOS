# GNU tar -- see docs/MANIFEST.md.
PKG_DESCRIPTION="GNU tar"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# --disable-acl avoids a gnulib/libacl symbol conflict -- see docs/MANIFEST.md
		FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr --disable-acl --without-posix-acls
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
