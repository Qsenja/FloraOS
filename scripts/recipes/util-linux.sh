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
		# Shipping them would mean binaries that fail to even load. FloraOS
		# has its own PAM-free login now (floralogin, tools/floralogin --
		# see ARCHITECTURE.md's PAM/login section, DONE) but that's a
		# separate tool entirely, not a rebuild of util-linux's own
		# login/su/etc -- these four stay disabled regardless, since
		# nothing changes the fact that util-linux's own configure.ac still
		# requires PAM headers just to build them at all. agetty itself
		# doesn't need PAM, which is why it's still here.
		# Same class of issue as PAM above, for other auto-detected optional
		# libs this build host happens to have: udev (device enumeration),
		# readline (fdisk/sfdisk interactive editing), cap-ng (setpriv),
		# and sqlite3 (lastlog2, which is moot anyway with login disabled).
		# util-linux ships its own separate sulogin too (confirmed from its
		# own configure.ac: UL_REQUIRES_HAVE([sulogin], [crypt], ...) plus
		# shadow.h -- crypt(3) again, not PAM, same as sysvinit's). Kept
		# disabled anyway, not because it's blocked: sysvinit already ships
		# a sulogin (see scripts/recipes/sysvinit.sh, restored by
		# build-rootfs.sh once libxcrypt exists) that's the one init(8)
		# itself actually falls back to for the "S" runlevel -- enabling a
		# second, independent sulogin implementation here would just be
		# duplication, not a real capability gain.
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
