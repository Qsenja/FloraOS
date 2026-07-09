# mbedtls -- see docs/MANIFEST.md.
PKG_DESCRIPTION="TLS library -- curl's TLS backend (no pacman.d/mirrorlist fetch works without it)"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# Real bug found via a live curl fetch against cdn.kernel.org
		# failing with MBEDTLS_ERR_SSL_ILLEGAL_PARAMETER: mbedTLS lists
		# RSA-PSS signature schemes (rsa_pss_rsae_sha256/384/512) in its
		# own TLS 1.2 default sig_algs preference table, but
		# mbedtls_ssl_tls12_sig_alg_is_supported() decodes every sig_alg
		# as a legacy (hash_byte, sig_byte) pair -- a scheme that doesn't
		# apply to these TLS1.3-style 16-bit codepoints at all, so they
		# always fell through to "unsupported" and mbedTLS silently never
		# offered them. Any TLS 1.2 server that signs ServerKeyExchange
		# with RSA-PSS (increasingly common; confirmed on a real
		# Fastly-fronted host) gets rejected. Confirmed still present in
		# mbedTLS's own development branch -- not fixed upstream, not
		# version-specific. Patches in an explicit codepoint check ahead
		# of the byte-pair decoding.
		awk '
			/\/\* High byte is hash \*\// {
				print "#if defined(MBEDTLS_X509_RSASSA_PSS_SUPPORT)"
				print "    switch (sig_alg) {"
				print "        case MBEDTLS_TLS1_3_SIG_RSA_PSS_RSAE_SHA256:"
				print "        case MBEDTLS_TLS1_3_SIG_RSA_PSS_RSAE_SHA384:"
				print "        case MBEDTLS_TLS1_3_SIG_RSA_PSS_RSAE_SHA512:"
				print "            return 1;"
				print "        default:"
				print "            break;"
				print "    }"
				print "#endif"
			}
			{ print }
		' library/ssl_misc.h > library/ssl_misc.h.tmp
		mv library/ssl_misc.h.tmp library/ssl_misc.h
		# build only "lib", not "install": avoids unconditionally building mbedTLS's example/test/fuzz programs
		make -j"$jobs" SHARED=1 lib
		mkdir -p "$files/usr/include" "$files/usr/lib"
		cp -rp include/mbedtls "$files/usr/include/"
		cp -rp include/psa "$files/usr/include/"
		cp -RP library/libmbedtls.* library/libmbedx509.* library/libmbedcrypto.* "$files/usr/lib/"
	)
}
