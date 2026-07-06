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
		# Same class of issue as PAM above, for other auto-detected optional
		# libs this build host happens to have: udev (device enumeration),
		# readline (fdisk/sfdisk interactive editing), cap-ng (setpriv),
		# and sqlite3 (lastlog2, which is moot anyway with login disabled).
		# sulogin needs libcrypt for password checks -- also disabled, since
		# there's no password-backed login to check against yet either.
		./configure --prefix=/usr \
			--without-systemd \
			--without-systemdsystemunitdir \
			--disable-static \
			--disable-login \
			--disable-su \
			--disable-runuser \
			--disable-chfn-chsh \
			--disable-sulogin \
			--disable-liblastlog2 \
			--without-udev \
			--without-readline \
			--without-cap-ng \
			--without-libmagic
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
