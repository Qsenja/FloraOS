PKG_DESCRIPTION="mount, fdisk, agetty, losetup, and other core Linux utilities"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# login/su/runuser/chfn/chsh require PAM headers to build at all
		# (configure.ac: UL_REQUIRES_HAVE(..., security_pam_appl_h)), and
		# this build host has PAM installed -- so they'd build and link
		# against libpam/libaudit/libcap-ng, none of which FloraOS ships.
		# Shipping them would mean binaries that fail to even load. Disabled
		# until FloraOS has its own PAM (or a PAM-free login) -- see
		# ARCHITECTURE.md TODO. agetty itself doesn't need PAM.
		./configure --prefix=/usr \
			--without-systemd \
			--without-systemdsystemunitdir \
			--disable-static \
			--disable-login \
			--disable-su \
			--disable-runuser \
			--disable-chfn-chsh
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
