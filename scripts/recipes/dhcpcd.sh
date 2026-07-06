PKG_DESCRIPTION="DHCP client for base networking"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure --prefix=/usr --sbindir=/usr/sbin \
			--dbdir=/var/lib/dhcpcd --rundir=/run
		make -j"$jobs"
		make DESTDIR="$files" install
	)
}
