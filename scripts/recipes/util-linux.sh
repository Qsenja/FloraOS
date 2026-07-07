PKG_DESCRIPTION="mount, fdisk, agetty, losetup, and other core Linux utilities"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# login/su/runuser/chfn/chsh/sulogin disabled (PAM-requiring, or duplicate of
		# sysvinit's own sulogin) -- see docs/MANIFEST.md
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
