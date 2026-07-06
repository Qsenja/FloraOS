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

# Standard /bin/sh -> bash. Without this, every #!/bin/sh script -- openrc's
# own init-early.sh/init.sh included -- fails to exec at all (the kernel
# reports the *script's* path as "No such file or directory" when the real
# problem is its missing shebang interpreter, which makes this easy to miss).
ln -sf bash "$ROOTFS/usr/bin/sh"

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
command -v fastfetch >/dev/null 2>&1 && fastfetch --config /etc/fastfetch/config.jsonc
EOF

# FloraOS branding: custom logo + fastfetch config, run once per login shell
# above. fastfetch itself is fetched via fau's pacman-backed fallback (see
# build-rootfs.sh) rather than built from source -- it's not part of the
# minimal base manifest, just an identity/branding touch.
if [ -f "$FLORA_ROOT/assets/floraos-logo.txt" ]; then
	mkdir -p "$ROOTFS/etc/fastfetch"
	cp "$FLORA_ROOT/assets/floraos-logo.txt" "$ROOTFS/etc/fastfetch/floraos-logo.txt"
	cp "$FLORA_ROOT/assets/fastfetch-config.jsonc" "$ROOTFS/etc/fastfetch/config.jsonc"
fi

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
# then a shell directly on tty1 (physical console) and ttyS0 (serial --
# useful for any VM/headless boot, and what QEMU's -serial capture sees;
# without this the kernel's own dmesg lines still reach ttyS0, but nothing
# userspace-side ever would).
#
# This intentionally bypasses agetty+login: agetty --autologin execs
# login(1), and util-linux's login *requires* PAM to build at all (and this
# build host has PAM, so it would build -- linked against libpam/libaudit/
# libcap-ng, none of which FloraOS ships, so it'd fail to even load). Real
# password-backed login needs either a from-scratch PAM or a PAM-free login
# path -- neither exists yet, so util-linux's login/su/runuser/chfn/chsh are
# disabled at build time (see scripts/recipes/util-linux.sh) and this spawns
# bash directly instead. TODO in ARCHITECTURE.md.
cat > "$ROOTFS/etc/inittab" <<'EOF'
id:3:initdefault:

si::sysinit:/usr/bin/openrc sysinit
rc::bootwait:/usr/bin/openrc boot

l0:0:wait:/usr/bin/openrc shutdown
l1:S1:wait:/usr/bin/openrc single
l3:3:wait:/usr/bin/openrc default
l6:6:wait:/usr/bin/openrc reboot

1:2345:respawn:/usr/bin/bash --login
s0:2345:respawn:/usr/bin/bash --login
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
