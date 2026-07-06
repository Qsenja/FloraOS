# openrc: runlevel/service manager, run by sysvinit's inittab. PKG_PREFIX
# defaults to /usr on Linux already, matching FloraOS's merged-/usr layout.
PKG_DESCRIPTION="OpenRC — dependency-based service/runlevel manager"
PKG_DEPENDS="glibc,sysvinit"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		make -j"$jobs"
		make DESTDIR="$files" install
	)
}
