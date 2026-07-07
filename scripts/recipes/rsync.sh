# rsync. fau's system install merges packages via `rsync -aK` (needed to
# merge into the merged-/usr symlinks correctly, see tools/fau/fau-bootstrap
# and tools/fau/lib/alpm.sh) --
# without shipping rsync, fau can't install anything inside the running OS.
# Optional network-transfer compression/crypto backends (openssl, zstd,
# lz4, xxhash) are disabled: irrelevant for fau's purely-local usage, and
# each is a dependency FloraOS would otherwise need to ship just for this.
PKG_DESCRIPTION="rsync — used by fau to merge package installs"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure --prefix=/usr \
			--disable-openssl \
			--disable-zstd \
			--disable-lz4 \
			--disable-xxhash \
			--disable-md2man \
			--with-included-popt
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
