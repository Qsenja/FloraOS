PKG_DESCRIPTION="ip/ss/tc — manual interface and routing configuration"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# configure auto-detects libtirpc via pkg-config and links against
		# it (NFSv4 ID-mapping support in `ip`, not something the base
		# needs) -- this build host has it, FloraOS doesn't ship it, so `ip`
		# would fail to load entirely. Hiding pkg-config's search path makes
		# every optional auto-detected lib (libtirpc included) resolve as
		# absent instead of silently linking against a library we can't ship.
		PKG_CONFIG_LIBDIR=/nonexistent PKG_CONFIG_PATH= ./configure
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" PREFIX=/usr install
	)
}
