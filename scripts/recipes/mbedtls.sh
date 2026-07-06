# mbedTLS: TLS backend for curl (see curl.sh) -- fau's alpm (Arch/Artix repo) fallback
# needs an HTTP client to actually fetch anything once running inside a
# booted FloraOS system (no pacman there to shell out to), and the mirrors
# are HTTPS-only. Picked over OpenSSL: purpose-built for small/embedded
# systems, a plain Makefile build (no cmake, which this project doesn't use
# anywhere else), and a much smaller dependency/build footprint.
PKG_DESCRIPTION="TLS library -- curl's TLS backend (no pacman.d/mirrorlist fetch works without it)"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# `make install` unconditionally builds and installs mbedTLS's own
		# example/test/fuzz programs too (it depends on the "programs"
		# target, which pulls in a large unused test-framework build) --
		# only the shared libraries and headers are ever needed here, so
		# build just "lib" and stage those two ourselves instead.
		make -j"$jobs" SHARED=1 lib
		mkdir -p "$files/usr/include" "$files/usr/lib"
		cp -rp include/mbedtls "$files/usr/include/"
		cp -rp include/psa "$files/usr/include/"
		cp -RP library/libmbedtls.* library/libmbedx509.* library/libmbedcrypto.* "$files/usr/lib/"
	)
}
