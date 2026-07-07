# sysvinit -- see docs/MANIFEST.md.
PKG_DESCRIPTION="sysvinit — PID1 for OpenRC"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		make -C src -j"$jobs"
		make -C src ROOT="$files" base_bindir=/usr/bin base_sbindir=/usr/bin install
		# sulogin dropped here (runs before libxcrypt exists); rebuilt correctly-linked by build-rootfs.sh
		rm -f "$files/usr/bin/sulogin"
	)
}
