# openrc -- see docs/MANIFEST.md.
PKG_DESCRIPTION="OpenRC — dependency-based service/runlevel manager"
PKG_DEPENDS="glibc,sysvinit"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# patches glibc 2.38+ strlcat() conflict -- see docs/MANIFEST.md
		sed -i 's/^#ifdef __GLIBC__$/#if defined(__GLIBC__) \&\& !__GLIBC_PREREQ(2, 38)/' \
			src/libeinfo/libeinfo.c
		make -j"$jobs" CFLAGS="-fcommon -O2 -g"
		fakeroot -- make DESTDIR="$files" install
	)
}
