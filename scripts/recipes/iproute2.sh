PKG_DESCRIPTION="ip/ss/tc — manual interface and routing configuration"
PKG_DEPENDS="glibc"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure
		make -j"$jobs"
		make DESTDIR="$files" PREFIX=/usr install
	)
}
