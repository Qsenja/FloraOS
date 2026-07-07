# curl -- see docs/MANIFEST.md.
PKG_DESCRIPTION="HTTP client -- fau's alpm (Arch/Artix repo) fallback needs it to fetch anything after boot"
PKG_DEPENDS="glibc,mbedtls,zstd"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# --with-mbedtls points at mbedtls's own staged files ($STAGE_DIR), not the build host's
		./configure --prefix=/usr \
			--with-mbedtls="$STAGE_DIR/mbedtls/files/usr" \
			--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
			--disable-static \
			--disable-ldap --disable-ldaps \
			--disable-ftp --disable-file --disable-ipfs --disable-rtsp --disable-dict \
			--disable-telnet --disable-tftp --disable-pop3 --disable-imap --disable-smtp \
			--disable-gopher --disable-mqtt \
			--without-zlib --without-brotli --without-libpsl --without-libidn2 --without-nghttp2
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
