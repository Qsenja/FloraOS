PKG_DESCRIPTION="GNU core utilities"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# All three below are optional features coreutils auto-detects and
		# links against if present on the build host, regardless of the
		# base actually needing them -- ls's capability display (libcap),
		# expr/factor's bignum support (libgmp), and a faster sha*sum via
		# libcrypto. None of these are shipped, so coreutils would fail to
		# even load without disabling them.
		./configure --prefix=/usr \
			--disable-libcap \
			--without-libgmp \
			--with-openssl=no
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
