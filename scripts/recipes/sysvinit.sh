# sysvinit: PID1, the companion OpenRC needs. Default paths use a separate
# /bin,/sbin; FloraOS uses a merged /usr (bin/sbin are symlinks to usr/bin),
# so base_bindir/base_sbindir are overridden to land there directly instead
# of creating real top-level bin/sbin directories that would collide with
# the /bin -> usr/bin symlink when packages are merged into one rootfs.
PKG_DESCRIPTION="sysvinit — PID1 for OpenRC"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		make -C src -j"$jobs"
		make -C src ROOT="$files" base_bindir=/usr/bin base_sbindir=/usr/bin install
		# sulogin (single-user-mode emergency shell) needs libcrypt for
		# password checks, but there's no working password-backed login to
		# check against yet (see ARCHITECTURE.md TODO on PAM/login) -- drop
		# it rather than ship a binary that can't load.
		rm -f "$files/usr/bin/sulogin"
	)
}
