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
		# sulogin (single-user-mode emergency shell) needs crypt(3) for
		# password checks -- no PAM at all (confirmed by reading its actual
		# source, not assumed). Dropped from *this* build specifically: this
		# recipe runs early (position 3 in MANDATORY_ORDER, well before
		# libxcrypt exists anywhere in this rootfs), so linking here would
		# bake in whatever libcrypt SONAME the *build host* happens to
		# provide, which the shipped image doesn't actually have -- the same
		# class of bug floralogin's own -I/-L$ROOTFS_DIR linkage avoids (see
		# build-rootfs.sh). Not left unshipped, though: build-rootfs.sh
		# recompiles it from this same pinned tarball right after libxcrypt
		# is staged, correctly linked -- see that script's own "restoring
		# sulogin" step.
		rm -f "$files/usr/bin/sulogin"
	)
}
