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

	# GUI-readiness (see ARCHITECTURE.md). Checked directly against the
	# real upstream linux-6.18.y source tree (git.kernel.org), not assumed:
	#
	# - CONFIG_DRM_I915=y and CONFIG_DRM_VIRTIO_GPU=y are ALREADY on in
	#   x86_64 defconfig, built straight into vmlinuz -- real GPU
	#   acceleration for Intel hardware and QEMU's virtio-gpu needs zero
	#   changes here at all. Confirmed by fetching and reading the actual
	#   defconfig file, not inferred.
	# - CONFIG_INPUT_EVDEV, CONFIG_HID (and CONFIG_HID_GENERIC, which
	#   `default HID`s), CONFIG_KEYBOARD_ATKBD, CONFIG_MOUSE_PS2 all
	#   `default y` in their own Kconfig entries (checked directly) and
	#   defconfig doesn't override any of them off -- keyboard/mouse input
	#   was never actually a gap. An earlier version of this recipe forced
	#   these on explicitly out of caution; removed now that it's confirmed
	#   unnecessary.
	# - CONFIG_SYSFB_SIMPLEFB (drivers/firmware/Kconfig) and
	#   CONFIG_DRM_SIMPLEDRM (drivers/gpu/drm/sysfb/Kconfig -- simpledrm
	#   moved out of drivers/gpu/drm/tiny/ at some point, confirmed against
	#   the current tree) are genuinely off by default. Upstream's own
	#   help text for DRM_SIMPLEDRM literally says "you should also select
	#   SYSFB_SIMPLEFB" -- the exact pair enabled below. Together they
	#   bind whatever framebuffer GRUB/firmware already set up as a
	#   generic KMS device, covering any GPU with no vendor driver at all
	#   (enough for a software-rendered/llvmpipe Wayland session).
	# - CONFIG_DRM_AMDGPU and CONFIG_DRM_NOUVEAU are genuinely off by
	#   default too, and are the real remaining gap for non-Intel/non-QEMU
	#   GPUs. Enabled as *modules* (=m, not built-in) -- now that
	#   scripts/recipes/kmod.sh exists and eudev.sh links against it
	#   (--enable-kmod, not --disable-kmod), these can actually be loaded
	#   on demand instead of bloating every boot on hardware that doesn't
	#   have them. `--module` (not `--enable`) is scripts/config's flag
	#   for "set =m", matching that intent explicitly rather than relying
	#   on olddefconfig to pick =m as some default.
	#
	# `depmod` (from kmod, see build-rootfs.sh's own step after fau
	# bootstrap) is what turns these built modules into something
	# modprobe/udev can actually resolve and load -- building the modules
	# here is necessary but not sufficient on its own.
	#
	# Kernel config *symbol names* above are verified against the live
	# linux-6.18.y tree (git.kernel.org), not guessed. What's still not
	# independently verified in this project's own sandbox: an actual full
	# `./floraiso build` (kernel+glibc compile is well beyond what's
	# practical to run here) -- check the real resulting
	# work/build/linux-lts/.config, or boot dmesg for "simple-framebuffer"
	# / a populated /dev/dri/, before relying on this.
	"$src/scripts/config" --file "$src/.config" \
		--enable SYSFB_SIMPLEFB \
		--enable DRM \
		--enable DRM_KMS_HELPER \
		--enable DRM_SIMPLEDRM \
		--module DRM_AMDGPU \
		--module DRM_NOUVEAU
	make -C "$src" ARCH=x86_64 olddefconfig >/dev/null

	log "linux-lts: building (this is the longest single step, -j$jobs)"
	make -C "$src" ARCH=x86_64 -j"$jobs" bzImage modules >/dev/null

	mkdir -p "$files/boot" "$files/lib/modules"
	cp "$src/arch/x86/boot/bzImage" "$files/boot/vmlinuz-floraos"
	cp "$src/System.map" "$files/boot/System.map-floraos"
	cp "$src/.config" "$files/boot/config-floraos"
	make -C "$src" ARCH=x86_64 INSTALL_MOD_PATH="$files" modules_install >/dev/null

	# build-rootfs.sh's depmod step (after fau bootstrap merges both this
	# package's modules and kmod's depmod binary into the same rootfs)
	# needs to know the exact /lib/modules/<release>/ directory name --
	# it can't just run `depmod` with no argument, since that defaults to
	# `uname -r` of whatever's running depmod (this build host's own
	# kernel, not FloraOS's). `make kernelrelease` prints the exact string
	# modules_install just used.
	make -C "$src" ARCH=x86_64 kernelrelease > "$files/boot/kernelrelease"
}
