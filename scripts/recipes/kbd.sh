# kbd: loadkeys, dumpkeys, setfont, and friends. Needed so OpenRC's
# etc/init.d/keymaps service (loadkeys/dumpkeys) actually runs instead of
# failing non-fatally at boot.
PKG_DESCRIPTION="loadkeys/dumpkeys/setfont -- console keymap and font tools"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# vlock auto-detects this build host's PAM and fails configure
		# outright if it's missing -- FloraOS has no PAM at all (see
		# ARCHITECTURE.md), so vlock has to be off regardless of host state.
		# zlib/bzip2/lzma are auto-detected the same way iproute2's libtirpc
		# was (present on this build host, not part of FloraOS) -- explicitly
		# off so kbd doesn't end up needing libraries we don't ship. zstd is
		# left on: FloraOS already ships libzstd for fau itself. xkb needs
		# libxkbcommon, which only matters with a display server (not built
		# yet, see ARCHITECTURE.md).
		./configure --prefix=/usr --disable-vlock --disable-tests --disable-xkb \
			--without-zlib --without-bzip2 --without-lzma
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
