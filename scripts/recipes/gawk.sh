# GNU awk. fau's repo/desc parsing (repo_lookup_file, pacman_desc_field)
# uses awk -- without this, fau is broken inside the running OS.
PKG_DESCRIPTION="GNU awk"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# --disable-mpfr also skips gmp (mpfr requires it); --without-readline
		# skips gawk's optional interactive-mode command history. Same
		# auto-detected-optional-lib class of issue as elsewhere.
		./configure --prefix=/usr --disable-mpfr --without-readline
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
