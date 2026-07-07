PKG_DESCRIPTION="ip/ss/tc — manual interface and routing configuration"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# hides pkg-config search path so auto-detected libtirpc (unshipped) doesn't get linked
		PKG_CONFIG_LIBDIR=/nonexistent PKG_CONFIG_PATH= ./configure
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" PREFIX=/usr install
	)
}
