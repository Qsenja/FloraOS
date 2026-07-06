# GNU tar. fau's own package format (.fau.tar.zst) is a tar archive --
# fau extracts and builds these with tar, so without shipping tar, fau
# can't install or package anything inside the running OS.
PKG_DESCRIPTION="GNU tar"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# ACL support pulls in gnulib's xattrs.c, which declares its own
		# compat acl_*_at() functions -- conflicting with this build host's
		# newer libacl/glibc <sys/acl.h>, which already declares them with
		# a different signature. Not needed for fau's own tar usage.
		FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr --disable-acl --without-posix-acls
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
