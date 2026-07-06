# GNU grep. Used extensively by fau's own JSON parsing and package lookup
# logic -- without this, fau is broken inside the running OS (it only
# worked during the rootfs build because the build host has grep).
PKG_DESCRIPTION="GNU grep"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# --disable-perl-regexp avoids the libpcre2 dependency -- fau only
		# ever uses grep -oE (POSIX extended regex, grep's own builtin
		# engine), never -P, so PCRE support isn't needed.
		./configure --prefix=/usr --disable-perl-regexp
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
