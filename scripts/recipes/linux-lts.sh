# linux-lts -- see docs/MANIFEST.md.
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

	# GUI-readiness config -- see docs/MANIFEST.md. BTRFS_FS must be =y (built-in), not
	# a module, since florainstall boots the target disk directly with no initramfs.
	"$src/scripts/config" --file "$src/.config" \
		--enable SYSFB_SIMPLEFB \
		--enable DRM \
		--enable DRM_KMS_HELPER \
		--enable DRM_SIMPLEDRM \
		--module DRM_AMDGPU \
		--module DRM_NOUVEAU \
		--enable BTRFS_FS
	make -C "$src" ARCH=x86_64 olddefconfig >/dev/null

	log "linux-lts: building (this is the longest single step, -j$jobs)"
	make -C "$src" ARCH=x86_64 -j"$jobs" bzImage modules >/dev/null

	mkdir -p "$files/boot" "$files/lib/modules"
	cp "$src/arch/x86/boot/bzImage" "$files/boot/vmlinuz-floraos"
	cp "$src/System.map" "$files/boot/System.map-floraos"
	cp "$src/.config" "$files/boot/config-floraos"
	make -C "$src" ARCH=x86_64 INSTALL_MOD_PATH="$files" modules_install >/dev/null

	# --no-print-directory is required: without it, -C's Entering/Leaving-directory
	# lines corrupt this captured single-line file and depmod rejects it
	make --no-print-directory -C "$src" ARCH=x86_64 kernelrelease > "$files/boot/kernelrelease"
}
