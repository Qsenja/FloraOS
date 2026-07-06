#!/usr/bin/env bash
# Builds a bootable hybrid BIOS+UEFI ISO from the FloraOS rootfs.
# The whole rootfs is packed as the initramfs and the kernel execs /init
# from it directly -- FloraOS boots and runs entirely from RAM (a live
# image; persistent disk installs are a documented future TODO, see
# ARCHITECTURE.md). grub-mkrescue (a build-host tool, not a FloraOS
# package -- see ARCHITECTURE.md) produces both boot paths in one step.
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

if [ ! -d "$ROOTFS_DIR" ] || [ -z "$(ls -A "$ROOTFS_DIR" 2>/dev/null)" ]; then
	log "no rootfs at $ROOTFS_DIR yet -- building it first"
	"$SELF_DIR/build-rootfs.sh"
fi

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

menuentry "${HOSTNAME:-FloraOS}" {
	linux /boot/vmlinuz-floraos console=tty0 console=ttyS0
	initrd /boot/initramfs-floraos.img
}
EOF

log "running grub-mkrescue"
rm -f "$ISO_OUT"
grub-mkrescue -o "$ISO_OUT" "$ISO_STAGE_DIR" >/dev/null 2>&1 || grub-mkrescue -o "$ISO_OUT" "$ISO_STAGE_DIR"

sha256sum "$ISO_OUT" > "$ISO_OUT.sha256"
log "ISO ready: $ISO_OUT ($(du -h "$ISO_OUT" | cut -f1))"
