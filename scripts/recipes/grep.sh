# GNU grep -- see docs/MANIFEST.md.
PKG_DESCRIPTION="GNU grep"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# --disable-perl-regexp: avoids libpcre2; fau only ever uses grep -oE, never -P
		./configure --prefix=/usr --disable-perl-regexp
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
