# linux-lts -- see docs/MANIFEST.md.
PKG_DESCRIPTION="Linux LTS kernel"
PKG_DEPENDS=""

recipe_build() {
	local src=$1 files=$2
	local jobs; jobs=$(nproc)

	# kbuild's own host tools (fixdep, unifdef, kconfig's conf, objtool,
	# ...) compile against glibc's real <limits.h>/<errno.h>/etc, which
	# transitively #include their linux/*.h counterparts -- never an
	# issue here since a real dev machine already has its own
	# linux-api-headers, but the equivalent live-system rebuild
	# (fau-recipes/system/linux-lts.fis, via `fau bootstrap-build`) has no
	# such fallback and needs its own real fix (points HOSTCFLAGS at the
	# linux-api-headers package already sandbox-fetched as one of gcc's
	# own build deps -- see that file for why the obvious-looking fixes
	# here, like headers_install's own output, don't actually work).
	log "linux-lts: installing sanitized headers for glibc"
	rm -rf "$BUILD_DIR/linux-headers"
	mkdir -p "$BUILD_DIR/linux-headers"
	make -C "$src" ARCH=x86_64 INSTALL_HDR_PATH="$BUILD_DIR/linux-headers" headers_install >/dev/null

	log "linux-lts: configuring (defconfig)"
	make -C "$src" ARCH=x86_64 defconfig >/dev/null

	# GUI-readiness config -- see docs/MANIFEST.md. BTRFS_FS must be =y (built-in), not
	# a module, since florainstall boots the target disk directly with no initramfs.
	#
	# DRM_FBDEV_EMULATION/FRAMEBUFFER_CONSOLE: without these, /dev/dri/card0
	# exists and simpledrm initializes fine (confirmed via dmesg on a real
	# boot), but nothing actually renders TEXT through it -- GRUB's own
	# gfxpayload=keep switch (scripts/build-iso.sh) takes the console out of
	# legacy VGA text mode, and with no fbcon bound to the new framebuffer,
	# the kernel falls back to CONFIG_DUMMY_CONSOLE for tty0: it accepts
	# output and renders none of it. Result: a real black screen on a real
	# monitor/QEMU window, even though the underlying GPU device is
	# genuinely working. Found on a real boot, not by inspection.
	# FRAMEBUFFER_CONSOLE depends on FB_CORE, which DRM's own Kconfig
	# `select`s automatically once DRM_FBDEV_EMULATION is on (confirmed
	# directly against drivers/gpu/drm/Kconfig's `select FB_CORE if
	# DRM_FBDEV_EMULATION` lines) -- no need to enable FB/FB_CORE by hand.
	#
	# DRM_BOCHS: SIMPLEDRM alone gets text rendering working (see above) but
	# is a dumb, no-modeset, no-GEM/GBM framebuffer wrapper -- Mesa's EGL
	# can't get a real context through it. Found running an actual Wayland
	# compositor (mango) under QEMU: "Could not initialize EGL". DRM_BOCHS
	# is the real KMS driver for QEMU's std-vga (Bochs dispi) device --
	# its own Kconfig help text literally says "Choose this option for
	# qemu" -- and brings real GEM/SHMEM buffer + atomic-KMS support that
	# EGL/GBM need. Built in, not a module, matching every other DRM_*
	# option here (no kmod autoload, see eudev's --disable-kmod above).
	"$src/scripts/config" --file "$src/.config" \
		--enable SYSFB_SIMPLEFB \
		--enable DRM \
		--enable DRM_KMS_HELPER \
		--enable DRM_SIMPLEDRM \
		--enable DRM_FBDEV_EMULATION \
		--enable FRAMEBUFFER_CONSOLE \
		--enable DRM_BOCHS \
		--module DRM_AMDGPU \
		--module DRM_NOUVEAU \
		--enable BTRFS_FS \
		--disable PCMCIA \
		--module SND_HDA_INTEL
	# PCMCIA: dead laptop card bus, nothing built after the mid-2000s has one --
	# checked the actual generated .config for real prunable bloat rather than
	# guessed, most of defconfig's other legacy protocol/hardware options were
	# already off. SND_HDA_INTEL: unlike DRM_BOCHS/DRM_SIMPLEDRM above, audio
	# isn't needed before userspace is up, so it doesn't need to be built in --
	# eudev's real --enable-kmod (not the DRM case's deliberate no-autoload)
	# loads it via modalias the same as any other PCI device driver module.
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
