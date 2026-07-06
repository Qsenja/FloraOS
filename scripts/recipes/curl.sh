# curl: HTTP client -- fau's pacman-backed fallback (tools/fau/fau) needs
# this to fetch mirror sync dbs and packages once running inside a booted
# FloraOS system, which has no pacman to shell out to. Without it,
# `fau install <pkg>` fails immediately with "curl: command not found"
# (found by actually running it after boot, not by inspection).
PKG_DESCRIPTION="HTTP client -- fau's pacman-backed fallback needs it to fetch anything after boot"
PKG_DEPENDS="glibc,mbedtls,zstd"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# mbedtls: TLS backend (see mbedtls.sh) -- the mirrors are
		# HTTPS-only. Pointed at mbedtls's own *staged* files
		# ($STAGE_DIR, set by lib/common.sh, shared with every recipe),
		# not the build host's ambient paths -- mbedtls is never actually
		# installed on the build host itself, only packaged by this
		# project's own build (same reasoning as glibc.sh's
		# LINUX_HEADERS_DIR). ca-bundle path matches where the
		# ca-certificates "package" (a direct fetch in build-rootfs.sh, not
		# a from-source build -- see config/versions.conf) actually lands.
		#
		# Trimmed to what fau's own fetches actually need (HTTP/HTTPS to a
		# handful of known mirror hostnames) rather than the default
		# kitchen-sink build: no FTP/telnet/gopher/mqtt/etc, no libpsl
		# (public suffix list -- irrelevant, fau never handles
		# user-supplied URLs), no libidn2 (IDN hostnames -- mirror
		# hostnames are plain ASCII), no nghttp2 (HTTP/2 -- HTTP/1.1 is
		# fine for one-shot file fetches), no zlib/brotli (not shipped;
		# zstd is, and is left enabled).
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
