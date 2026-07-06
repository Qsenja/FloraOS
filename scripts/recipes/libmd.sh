# libmd (BSD message-digest routines). dhcpcd links against this for its
# DUID/hashing needs, with no configure flag to avoid it -- unlike most
# other gaps found here, this one has to be shipped rather than disabled.
PKG_DESCRIPTION="BSD message-digest library — dhcpcd links against it, no way to disable"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure --prefix=/usr
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
