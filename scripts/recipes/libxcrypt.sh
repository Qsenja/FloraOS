# libxcrypt: glibc removed crypt()/crypt.h/<shadow.h>'s hashing backend
# entirely (upstream moved it here) -- password-backed login needs crypt()
# to verify /etc/shadow hashes, and this is the standard replacement, not a
# FloraOS-specific choice. --enable-obsolete-api=glibc keeps the traditional
# crypt(3) signature/ABI (SONAME libcrypt.so.1) that floralogin links
# against (see tools/floralogin).
PKG_DESCRIPTION="crypt(3) password hashing (glibc dropped it; this is the standard replacement)"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		# -Werror trips over a warning this build host's newer gcc raises
		# that upstream's CI doesn't see (same class of issue as glibc's own
		# --disable-werror elsewhere in this project).
		./configure --prefix=/usr --disable-static --disable-werror \
			--enable-obsolete-api=glibc --enable-hashes=strong,glibc
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
