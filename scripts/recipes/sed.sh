# GNU sed. Not just a general-purpose tool here -- fau's own JSON
# read/write functions (json_get_version, json_list_names) use sed, so
# without shipping it, fau itself is broken inside the running OS (it only
# worked during the rootfs build because the *build host* has sed).
PKG_DESCRIPTION="GNU sed"
PKG_DEPENDS="glibc,attr,acl"

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)
	(
		cd "$src"
		./configure --prefix=/usr
		make -j"$jobs"
		fakeroot -- make DESTDIR="$files" install
	)
}
