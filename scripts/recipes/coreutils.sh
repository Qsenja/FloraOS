PKG_DESCRIPTION="GNU core utilities"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# disables auto-linked optional libs FloraOS doesn't ship (libcap/libgmp/libcrypto)
		./configure --prefix=/usr \
			--disable-libcap \
			--without-libgmp \
			--with-openssl=no
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
