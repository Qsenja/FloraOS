#!/usr/bin/env bash
# Applies the FloraOS /etc skeleton, identity files, and the sysvinit/openrc
# glue (inittab + dhcpcd service) on top of an already fau-installed rootfs.
# Run after `fau bootstrap`, before ldconfig.
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

# OpenRC's own etc/init.d/hostname service ignores /etc/hostname entirely --
# it reads the hostname= var from etc/conf.d/hostname, which upstream ships
# defaulted to "localhost". Without this, config/floraos.conf's HOSTNAME=
# silently never took effect at boot (booted system always came up as
# "localhost" regardless of what /etc/hostname said).
mkdir -p "$ROOTFS/etc/conf.d"
echo "hostname=\"$FLORA_HOSTNAME\"" > "$ROOTFS/etc/conf.d/hostname"

cat > "$ROOTFS/etc/motd" <<'EOF'

  FloraOS — minimal, from-scratch, no systemd.

EOF

# agetty prints this before the login prompt -- the one place a first-time
# user actually sees it before being asked for credentials. root's shadow
# entry ships with an empty password field (traditional Unix for "no
# password required"), intentional for this live, RAM-resident image: there
# is no persistent install yet (see README.md) and no passwd(1) built yet to
# change it either.
cat > "$ROOTFS/etc/issue" <<'EOF'
FloraOS \n \l
login: root (just press Enter at the password prompt)

EOF

cat > "$ROOTFS/etc/fstab" <<'EOF'
# <fs>          <mountpoint>    <type>          <opts>          <dump/pass>
proc            /proc           proc            defaults        0 0
sysfs           /sys            sysfs           defaults        0 0
devtmpfs        /dev            devtmpfs        defaults        0 0
EOF

cat > "$ROOTFS/etc/profile" <<'EOF'
export PS1='floraos-boot-ok # '
# $HOME/apps/.bin: fau install's wrapper scripts (see tools/fau/fau,
# FAU_APPS_BIN_DIR) -- without this every login otherwise printed "note:
# .../apps/.bin is not on your PATH yet" after the very first `fau
# install`, which is exactly the state a fresh boot should already be in
# for the default (unoverridden) FAU_APPS_DIR.
export PATH=/usr/bin:$HOME/apps/.bin
command -v fastfetch >/dev/null 2>&1 && fastfetch --config "$HOME/apps/fastfetch/config/fastfetch/config.jsonc"
EOF

# FloraOS branding: custom logo + fastfetch config, run once per login shell
# above. fastfetch itself is installed as an isolated app (fau install
# fastfetch, see build-rootfs.sh), not merged into the system root -- so its
# config lives inside that same app's own directory (its XDG_CONFIG_HOME,
# per the app wrapper -- see app_wrapper_write in tools/fau/fau), not /etc,
# matching fau's own "fau remove fastfetch deletes exactly that directory"
# promise. Only applies if the fastfetch app install above actually
# happened (skipped entirely on a build host with no pacman mirrorlist).
if [ -f "$FLORA_ROOT/assets/floraos-logo.txt" ] && [ -d "$ROOTFS/root/apps/fastfetch" ]; then
	mkdir -p "$ROOTFS/root/apps/fastfetch/config/fastfetch"
	cp "$FLORA_ROOT/assets/floraos-logo.txt" "$ROOTFS/root/apps/fastfetch/config/fastfetch/floraos-logo.txt"
	cp "$FLORA_ROOT/assets/fastfetch-config.jsonc" "$ROOTFS/root/apps/fastfetch/config/fastfetch/config.jsonc"
fi

# kbd's loadkeys shells out to `gzip` (via /bin/sh -c) to decompress .gz
# keymaps and falls back to its own internal decompression when that fails --
# FloraOS deliberately doesn't ship gzip (see docs/MANIFEST.md), so every
# boot printed "sh: line 1: gzip: command not found" to the console even
# though the keymap loads fine. Silencing just that one call's stderr (openrc
# already reports success/failure via ebegin/eend, so nothing informational
# is lost) instead of adding a whole package back just to suppress cosmetic
# noise.
if [ -f "$ROOTFS/etc/init.d/keymaps" ]; then
	sed -i '/^[[:space:]]*loadkeys /s/$/ 2>\/dev\/null/' "$ROOTFS/etc/init.d/keymaps"
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
uucp:x:10:
seat:x:11:
EOF

cat > "$ROOTFS/etc/shadow" <<'EOF'
root::19000:0:99999:7:::
EOF
chmod 600 "$ROOTFS/etc/shadow"

# sysvinit + openrc glue: PID1 runs openrc's sysinit/boot/default stages,
# then a real getty (agetty) on tty1 (physical console) and ttyS0 (serial --
# useful for any VM/headless boot, and what QEMU's -serial capture sees;
# without this the kernel's own dmesg lines still reach ttyS0, but nothing
# userspace-side ever would), which execs floralogin.
#
# util-linux's own login *requires* PAM to build at all (this build host has
# PAM, so it would build -- linked against libpam/libaudit/libcap-ng, none
# of which FloraOS ships, so it'd fail to even load), which is why
# login/su/runuser/chfn/chsh are disabled at build time (see
# scripts/recipes/util-linux.sh). floralogin (tools/floralogin) is FloraOS's
# own from-scratch, PAM-free replacement -- crypt(3)-verified against
# /etc/shadow via libxcrypt, since glibc dropped crypt() itself. agetty
# itself doesn't need PAM and needed no changes; using it instead of
# spawning bash directly is also what actually fixes job control ("cannot
# set terminal process group") -- agetty opens/attaches the tty as session
# leader before exec'ing floralogin, which bash spawned directly never did.
cat > "$ROOTFS/etc/inittab" <<'EOF'
id:3:initdefault:

si::sysinit:/usr/bin/openrc sysinit
rc::bootwait:/usr/bin/openrc boot

l0:0:wait:/usr/bin/openrc shutdown
l1:S1:wait:/usr/bin/openrc single
l3:3:wait:/usr/bin/openrc default
l6:6:wait:/usr/bin/openrc reboot

# dhcpcd itself is NOT run through openrc's own default-runlevel dependency
# resolution (etc/init.d/dhcpcd still exists and works fine for manual
# `rc-service dhcpcd start/stop`) -- a custom-authored openrc-run script
# symlinked into etc/runlevels/default never actually got scheduled by
# openrc at boot, full stop: confirmed across several from-scratch
# rebuilds and fresh boots, with and without `provide net` in its depend(),
# with and without openrc's own legacy etc/init.d/network and
# etc/init.d/staticroute (both of which unconditionally/conditionally
# `provide net` too) still present -- rc-status default only ever showed
# netmount+local, dhcpcd never appeared at all (not started, not crashed),
# while running the exact same script by hand
# (`/etc/init.d/dhcpcd start`) always worked immediately. Rather than
# chase further into openrc's dependency-cache internals, driving it
# directly from inittab -- the same pattern already used below for
# floralogin -- sidesteps whatever that is entirely and just guarantees it
# runs once per boot.
#
# Output redirected to /dev/null: sysvinit starts this "once" entry
# concurrently with the "respawn" agetty entries below rather than
# sequentially, so its ebegin/eend/dhcpcd-privsep-warning output otherwise
# races the login prompt on the same console and garbles both (seen
# directly: "floraos login:  * Starting dhcpcd ..." interleaved
# mid-prompt). The startup itself doesn't depend on anything in that
# output -- dhcpcd's own actual failures (lease errors etc) still exit
# non-zero and are visible via `rc-service dhcpcd status`.
dh:2345:once:/etc/init.d/dhcpcd start >/dev/null 2>&1

# GUI-readiness (see ARCHITECTURE.md): udevd needs to be up, and an initial
# coldplug pass (trigger + settle) run, before anything -- floraseat
# included -- tries to open /dev/dri or /dev/input nodes for devices that
# were already present at boot (hotplug uevents alone only cover devices
# that appear *after* udevd starts listening). udevd forks itself into the
# background with --daemon (same "once, self-backgrounds" shape as dhcpcd
# above, same reason it's driven directly from inittab rather than through
# openrc's own runlevel dependency resolution -- see the dhcpcd comment
# above, which applies identically here: a custom-authored openrc-run
# script in etc/runlevels/default never actually got scheduled in this
# project's own testing).
ud:2345:once:/usr/bin/udevd --daemon && /usr/bin/udevadm trigger --action=add --type=subsystems && /usr/bin/udevadm trigger --action=add --type=devices && /usr/bin/udevadm settle >/dev/null 2>&1

# floraseat (tools/floraseat, see ARCHITECTURE.md): FloraOS's own
# seatd-wire-protocol-compatible seat daemon -- runs in the foreground
# (unlike udevd/dhcpcd above, it does not background itself), so it needs
# "respawn" like the agetty lines below, not "once". Started before login
# so the socket exists by the time anything tries to connect to it.
fs:2345:respawn:/usr/bin/floraseat >/dev/null 2>&1

1:2345:respawn:/usr/sbin/agetty --skip-login --login-program /usr/bin/floralogin --noclear tty1 linux
s0:2345:respawn:/usr/sbin/agetty --skip-login --login-program /usr/bin/floralogin ttyS0 115200 vt100
EOF

# init.d script for dhcpcd, kept for manual `rc-service dhcpcd
# start/stop/restart` -- upstream dhcpcd ships no OpenRC integration of its
# own. NOT symlinked into etc/runlevels/default/: a custom-authored
# openrc-run script placed there never actually got scheduled by openrc's
# own dependency resolution at boot, with or without `provide net`, with or
# without openrc's own legacy etc/init.d/network+staticroute (both of which
# also `provide net`) present -- confirmed across several full
# from-scratch rebuilds and fresh boots, rc-status default only ever
# showed netmount+local, dhcpcd never appeared at all (not started, not
# crashed), while running the exact same script by hand always worked
# immediately. Rather than chase further into openrc's dependency-cache
# internals, it's invoked directly from inittab above instead (see the
# comment there) -- this file just makes it independently
# start/stop-able.
cat > "$ROOTFS/etc/init.d/dhcpcd" <<'EOF'
#!/usr/bin/openrc-run
description="DHCP client"
command=/usr/sbin/dhcpcd
command_args="--quiet"
pidfile="/run/dhcpcd.pid"

depend() {
	need localmount
	after bootmisc
}
EOF
chmod 755 "$ROOTFS/etc/init.d/dhcpcd"

# init.d scripts for udevd/floraseat, same "manual rc-service start/stop
# only, actual boot-time start driven from inittab" reasoning as dhcpcd's
# own script above -- not symlinked into etc/runlevels/default/.
cat > "$ROOTFS/etc/init.d/udevd" <<'EOF'
#!/usr/bin/openrc-run
description="Device manager (eudev)"
command=/usr/bin/udevd
command_args="--daemon"
pidfile="/run/udevd.pid"

depend() {
	need sysfs
}
EOF
chmod 755 "$ROOTFS/etc/init.d/udevd"

cat > "$ROOTFS/etc/init.d/floraseat" <<'EOF'
#!/usr/bin/openrc-run
description="Seat management daemon (floraseat, seatd-protocol-compatible)"
command=/usr/bin/floraseat
pidfile="/run/floraseat.pid"
# No command_background here, unlike a self-daemonizing command -- floraseat
# stays in the foreground (see tools/floraseat/floraseat.c), so openrc-run's
# own default start-stop-daemon --background handles backgrounding it.

depend() {
	need udevd
}
EOF
chmod 755 "$ROOTFS/etc/init.d/floraseat"

# openrc's own baselayout ships etc/init.d/network (generic static
# ifconfig/ip-file interface bringup) and etc/init.d/staticroute enabled in
# the boot runlevel by default. FloraOS has no /etc/ifconfig.*/etc/ip.*
# files or /etc/route.conf -- it relies entirely on dhcpcd -- so both
# scripts' start() do nothing at all here. Removed as dead weight (and
# ruled out, not confirmed, as the dhcpcd-scheduling cause above: removing
# both still left dhcpcd unscheduled by openrc, which is why it's driven
# from inittab instead).
rm -f "$ROOTFS/etc/runlevels/boot/network"
rm -f "$ROOTFS/etc/runlevels/boot/staticroute"
