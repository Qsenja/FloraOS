# linux-lts: kernel image + modules, and (as a side effect) the sanitized
# UAPI headers glibc needs to build against. Headers are a build-time-only
# artifact, not part of the shipped package. LINUX_HEADERS_DIR itself is
# defined in lib/common.sh, not here -- see the comment there.
PKG_DESCRIPTION="Linux LTS kernel"
PKG_DEPENDS=""

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)

	log "linux-lts: installing sanitized headers for glibc"
	rm -rf "$BUILD_DIR/linux-headers"
	mkdir -p "$BUILD_DIR/linux-headers"
	make -C "$src" ARCH=x86_64 INSTALL_HDR_PATH="$BUILD_DIR/linux-headers" headers_install >/dev/null

	log "linux-lts: configuring (defconfig)"
	make -C "$src" ARCH=x86_64 defconfig >/dev/null

	log "linux-lts: building (this is the longest single step, -j$jobs)"
	make -C "$src" ARCH=x86_64 -j"$jobs" bzImage modules >/dev/null

	mkdir -p "$files/boot" "$files/lib/modules"
	cp "$src/arch/x86/boot/bzImage" "$files/boot/vmlinuz-floraos"
	cp "$src/System.map" "$files/boot/System.map-floraos"
	cp "$src/.config" "$files/boot/config-floraos"
	make -C "$src" ARCH=x86_64 INSTALL_MOD_PATH="$files" modules_install >/dev/null
}
