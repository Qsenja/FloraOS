# mbedtls -- see docs/MANIFEST.md.
PKG_DESCRIPTION="TLS library -- curl's TLS backend (no pacman.d/mirrorlist fetch works without it)"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# build only "lib", not "install": avoids unconditionally building mbedTLS's example/test/fuzz programs
		make -j"$jobs" SHARED=1 lib
		mkdir -p "$files/usr/include" "$files/usr/lib"
		cp -rp include/mbedtls "$files/usr/include/"
		cp -rp include/psa "$files/usr/include/"
		cp -RP library/libmbedtls.* library/libmbedx509.* library/libmbedcrypto.* "$files/usr/lib/"
	)
}
