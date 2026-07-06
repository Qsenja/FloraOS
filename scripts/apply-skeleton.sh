#!/usr/bin/env bash
# Applies the FloraOS /etc skeleton, identity files, and the sysvinit/openrc
# glue (inittab + dhcpcd service) on top of an already fau-installed rootfs.
# Run after `fau install`, before ldconfig.
set -euo pipefail

ROOTFS=${1:?usage: apply-skeleton.sh <rootfs-dir> [hostname]}
FLORA_HOSTNAME=${2:-floraos}
FLORA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DATE=$(date -u +%Y%m%d 2>/dev/null || echo unknown)

mkdir -p "$ROOTFS"/{root,home,proc,sys,dev,run,tmp,mnt}
mkdir -p "$ROOTFS/etc/inittab.d"
mkdir -p "$ROOTFS/etc/runlevels/default"
chmod 1777 "$ROOTFS/tmp"

# The kernel's initramfs unpacker execs /init directly if present.
ln -sf sbin/init "$ROOTFS/init"

cat > "$ROOTFS/etc/os-release" <<EOF
NAME="FloraOS"
ID=floraos
PRETTY_NAME="FloraOS"
VERSION="rolling ($BUILD_DATE)"
HOME_URL="https://github.com/"
EOF

echo "$FLORA_HOSTNAME" > "$ROOTFS/etc/hostname"

cat > "$ROOTFS/etc/motd" <<'EOF'

  FloraOS — minimal, from-scratch, no systemd.

EOF

cat > "$ROOTFS/etc/fstab" <<'EOF'
# <fs>          <mountpoint>    <type>          <opts>          <dump/pass>
proc            /proc           proc            defaults        0 0
sysfs           /sys            sysfs           defaults        0 0
devtmpfs        /dev            devtmpfs        defaults        0 0
EOF

cat > "$ROOTFS/etc/profile" <<'EOF'
export PS1='floraos-boot-ok # '
export PATH=/usr/bin
EOF

cat > "$ROOTFS/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
EOF

cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/usr/bin/bash
EOF

cat > "$ROOTFS/etc/group" <<'EOF'
root:x:0:
EOF

cat > "$ROOTFS/etc/shadow" <<'EOF'
root::19000:0:99999:7:::
EOF
chmod 600 "$ROOTFS/etc/shadow"

# sysvinit + openrc glue: PID1 runs openrc's sysinit/boot/default stages,
# then a single autologin getty on tty1 (no shadow-backed login wired up yet
# -- see ARCHITECTURE.md TODO).
cat > "$ROOTFS/etc/inittab" <<'EOF'
id:3:initdefault:

si::sysinit:/usr/bin/openrc sysinit
rc::bootwait:/usr/bin/openrc boot

l0:0:wait:/usr/bin/openrc shutdown
l1:S1:wait:/usr/bin/openrc single
l3:3:wait:/usr/bin/openrc default
l6:6:wait:/usr/bin/openrc reboot

1:2345:respawn:/usr/bin/agetty --autologin root 38400 tty1 linux
EOF

# Minimal openrc init.d script for dhcpcd -- upstream dhcpcd ships no OpenRC
# integration of its own.
cat > "$ROOTFS/etc/init.d/dhcpcd" <<'EOF'
#!/usr/bin/openrc-run
description="DHCP client"
command=/usr/sbin/dhcpcd
command_args="--quiet"
pidfile="/run/dhcpcd.pid"

depend() {
	provide net
	need localmount
	after bootmisc
}
EOF
chmod 755 "$ROOTFS/etc/init.d/dhcpcd"
ln -sf ../../init.d/dhcpcd "$ROOTFS/etc/runlevels/default/dhcpcd"
