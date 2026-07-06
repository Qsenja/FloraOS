# procps-ng: sysctl, ps, top, kill, free, etc. Needed so OpenRC's
# etc/init.d/sysctl service (`sysctl --system`) actually runs instead of
# failing non-fatally at boot; the rest of the suite (ps/top/kill/free/...)
# comes along for free from the same source tree.
PKG_DESCRIPTION="sysctl/ps/top/kill/free -- /proc-based process and system utilities"
PKG_DEPENDS="glibc,ncurses"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# Upstream only publishes a raw gitlab source-archive tarball (no
		# generated configure) -- autoreconf is required. This build host's
		# gettext is gettext-tiny (reports itself as version "1.0"), which
		# lacks the po-directories autoreconf hook real GNU gettext ships, so
		# autoreconf leaves po/Makefile.in without an "all" target and the
		# build breaks in the po/ subdir. We don't want translations in a
		# minimal base OS anyway (--disable-nls below) -- drop po/po-man from
		# the build entirely instead of fighting the gettext-tiny gap.
		sed -i '/^\tpo-man \\$/d; /^\tpo \\$/d' Makefile.am
		sed -i '/^\s*po-man\/Makefile\s*$/d; /^\s*po\/Makefile\.in\s*$/d' configure.ac
		sed -i '/^AM_GNU_GETTEXT_VERSION/d; /^AM_GNU_GETTEXT(\[external\])/d' configure.ac
		autoreconf -fi
		# Deliberately not hiding PKG_CONFIG_PATH here (unlike iproute2's
		# libtirpc workaround): top/watch link against ncursesw, which
		# FloraOS already ships (bash needs it too), so linking against this
		# build host's copy is exactly what we want, not an unwanted extra.
		./configure --prefix=/usr --disable-nls
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
