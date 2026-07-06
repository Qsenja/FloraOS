# hostname (Debian's small standalone implementation: hostname,
# dnsdomainname, domainname). Deliberately not inetutils -- that bundles
# telnet/ftp/rsh/talk/etc alongside the one command we actually need; this
# package is exactly hostname.c + a Makefile. Needed so OpenRC's
# etc/init.d/hostname service (`hostname "$hostname"`) actually runs instead
# of failing non-fatally at boot.
PKG_DESCRIPTION="hostname/dnsdomainname -- sets/prints the system hostname"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	(
		cd "$src"
		make
		fakeroot -- make DESTDIR="$files" install
	)
}
