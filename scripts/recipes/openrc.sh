# openrc: runlevel/service manager, run by sysvinit's inittab. PKG_PREFIX
# defaults to /usr on Linux already, matching FloraOS's merged-/usr layout.
PKG_DESCRIPTION="OpenRC — dependency-based service/runlevel manager"
PKG_DEPENDS="glibc,sysvinit"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# OpenRC 0.13.11's libeinfo.c defines its own static strlcat()
		# whenever __GLIBC__ is set, from a time when glibc didn't provide
		# one. glibc 2.38+ added a real strlcat(), so the static definition
		# now conflicts with glibc's own declaration in <string.h>. Only
		# skip OpenRC's compat copy on glibc versions new enough to have it.
		sed -i 's/^#ifdef __GLIBC__$/#if defined(__GLIBC__) \&\& !__GLIBC_PREREQ(2, 38)/' \
			src/libeinfo/libeinfo.c
		# rc-logger.h declares rc_logger_pid/rc_logger_tty as tentative
		# definitions (no extern) in a header included by multiple .c files
		# -- fine under gcc's pre-10 default of -fcommon, a link-time
		# "multiple definition" error under gcc 10+'s -fno-common default.
		# CFLAGS is passed (not appended) here since mk/cc.mk's own `+=`
		# additions (warnings, -std=c99) still layer on top of whatever
		# CFLAGS arrives as on the command line -- only its own `?=
		# -O2 -g` default is skipped, so it's restated explicitly.
		make -j"$jobs" CFLAGS="-fcommon -O2 -g"
		fakeroot -- make DESTDIR="$files" install
	)
}
