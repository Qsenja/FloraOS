# procps-ng -- see docs/MANIFEST.md.
PKG_DESCRIPTION="sysctl/ps/top/kill/free -- /proc-based process and system utilities"
PKG_DEPENDS="glibc,ncurses"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# strips po/po-man before autoreconf -- see docs/MANIFEST.md
		sed -i '/^\tpo-man \\$/d; /^\tpo \\$/d' Makefile.am
		sed -i '/^\s*po-man\/Makefile\s*$/d; /^\s*po\/Makefile\.in\s*$/d' configure.ac
		sed -i '/^AM_GNU_GETTEXT_VERSION/d; /^AM_GNU_GETTEXT(\[external\])/d' configure.ac
		autoreconf -fi
		./configure --prefix=/usr --disable-nls
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
