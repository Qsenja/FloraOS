#!/usr/bin/env bash
# Builds a bootable hybrid BIOS+UEFI ISO from the FloraOS rootfs. See
# docs/ARCHITECTURE.md's "Build pipeline" and "Bootloader" sections.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

FLORAOS_CONF="$FLORA_ROOT/config/floraos.conf"
[ -f "$FLORAOS_CONF" ] || die "missing config file: $FLORAOS_CONF"
# shellcheck source=/dev/null
source "$FLORAOS_CONF"

ISO_STAGE_DIR="$WORK_DIR/iso"
ISO_OUT="$FLORA_ROOT/${ISO_NAME:-floraos.iso}"

for cmd in grub-mkrescue xorriso cpio gzip; do require_cmd "$cmd"; done

# Always run build-rootfs.sh -- it already skips recompiling any package
# whose pinned version is unchanged (see docs/ARCHITECTURE.md's "Build
# pipeline" section), so this is cheap when nothing changed. Skipping it
# outright whenever $ROOTFS_DIR merely exists shipped a stale rootfs the
# one time it mattered: editing fau/floralogin/florauser/etc. and running
# `./floraiso build` silently packed the old binaries, since only the
# "assembling rootfs" step (which copies those fresh) runs unconditionally
# inside build-rootfs.sh, and this guard was skipping that whole script.
"$SELF_DIR/build-rootfs.sh"

[ -f "$ROOTFS_DIR/boot/vmlinuz-floraos" ] || die "no kernel at $ROOTFS_DIR/boot/vmlinuz-floraos -- rootfs build looks incomplete"
[ -x "$ROOTFS_DIR/sbin/init" ] || die "no /sbin/init in rootfs -- sysvinit didn't install correctly"

log "packing rootfs as initramfs (this reads every file in the rootfs, takes a minute)"
rm -rf "$ISO_STAGE_DIR"
mkdir -p "$ISO_STAGE_DIR/boot/grub"
( cd "$ROOTFS_DIR" && find . -mindepth 1 -not -path './boot*' | cpio -o -H newc 2>/dev/null | gzip -9 ) \
	> "$ISO_STAGE_DIR/boot/initramfs-floraos.img"

cp "$ROOTFS_DIR/boot/vmlinuz-floraos" "$ISO_STAGE_DIR/boot/vmlinuz-floraos"

cat > "$ISO_STAGE_DIR/boot/grub/grub.cfg" <<EOF
set timeout=3
set default=0

# Without this, GRUB hands the kernel off in plain VGA text mode -- the
# kernel's own CONFIG_SYSFB_SIMPLEFB/CONFIG_DRM_SIMPLEDRM
# (scripts/recipes/linux-lts.sh) only ever wraps whatever linear
# framebuffer the firmware/bootloader already set up before boot; with none
# set up, /dev/dri/card0 never exists at all and any Wayland compositor
# (mango) fails to find a GPU, independent of the actual host/VM display
# hardware. insmod all_video covers both legacy BIOS VESA (video_bochs/vbe)
# and UEFI GOP (efi_gop) in this hybrid BIOS+UEFI image; gfxpayload=keep
# hands that mode's framebuffer info to the kernel via the Linux boot
# protocol's screen_info instead of GRUB dropping back to text mode right
# before the linux/initrd handoff -- but "keep" only PRESERVES whatever
# mode GRUB is already in, it doesn't switch into one itself. Confirmed for
# real in a QEMU boot (dmesg): without the terminal_output gfxterm line
# below, GRUB stays on its default text-mode 'console' terminal the entire
# time, so there's nothing graphical for "keep" to preserve -- the Bochs
# VGA PCI device shows up in dmesg (vgaarb claims it as the boot VGA
# device) but no framebuffer driver ever binds to it, and /dev/dri never
# appears. terminal_output gfxterm is what actually makes GRUB switch
# itself into a graphics mode; gfxpayload=keep then carries that same mode
# into the kernel instead of reverting to text right before the jump.
insmod all_video
insmod gfxterm
set gfxmode=auto
set gfxpayload=keep
terminal_output gfxterm

menuentry "${HOSTNAME:-FloraOS}" {
	linux /boot/vmlinuz-floraos console=tty0 console=ttyS0
	initrd /boot/initramfs-floraos.img
}
EOF

log "running grub-mkrescue"
rm -f "$ISO_OUT"
grub-mkrescue -o "$ISO_OUT" "$ISO_STAGE_DIR" >/dev/null 2>&1 || grub-mkrescue -o "$ISO_OUT" "$ISO_STAGE_DIR"

# Relative filename, not the absolute build path -- see ARCHITECTURE.md.
(cd "$FLORA_ROOT" && sha256sum "$(basename "$ISO_OUT")") > "$ISO_OUT.sha256"
log "ISO ready: $ISO_OUT ($(du -h "$ISO_OUT" | cut -f1))"
