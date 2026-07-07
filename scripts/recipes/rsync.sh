# rsync -- see docs/MANIFEST.md.
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
