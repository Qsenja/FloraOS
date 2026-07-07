# hostname (Debian's small standalone implementation) -- see docs/MANIFEST.md.
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
