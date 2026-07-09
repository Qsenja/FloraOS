#!/usr/bin/env bash
# Applies the FloraOS /etc skeleton on top of an already fau-bootstrapped
# rootfs. Run after `fau bootstrap`, before ldconfig. See docs/ARCHITECTURE.md.
set -euo pipefail

ROOTFS=${1:?usage: apply-skeleton.sh <rootfs-dir> [hostname]}
FLORA_HOSTNAME=${2:-floraos}
FLORA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DATE=$(date -u +%Y%m%d 2>/dev/null || echo unknown)

mkdir -p "$ROOTFS"/{root,home,proc,sys,dev,run,tmp,mnt}
mkdir -p "$ROOTFS/etc/inittab.d"
mkdir -p "$ROOTFS/etc/runlevels/default"
mkdir -p "$ROOTFS/etc/runlevels/single"
mkdir -p "$ROOTFS/var/log"
chmod 1777 "$ROOTFS/tmp"

ln -sf sbin/init "$ROOTFS/init"

# /bin/sh -> bash: without this, every #!/bin/sh script fails to exec (the
# kernel misreports it as "No such file or directory" -- see ARCHITECTURE.md).
ln -sf bash "$ROOTFS/usr/bin/sh"

cat > "$ROOTFS/etc/os-release" <<EOF
NAME="FloraOS"
ID=floraos
PRETTY_NAME="FloraOS"
VERSION="rolling ($BUILD_DATE)"
HOME_URL="https://github.com/"
EOF

echo "$FLORA_HOSTNAME" > "$ROOTFS/etc/hostname"

# OpenRC's hostname service reads conf.d/hostname, not /etc/hostname -- see ARCHITECTURE.md.
mkdir -p "$ROOTFS/etc/conf.d"
echo "hostname=\"$FLORA_HOSTNAME\"" > "$ROOTFS/etc/conf.d/hostname"

cat > "$ROOTFS/etc/motd" <<'EOF'

  FloraOS — minimal, from-scratch, no systemd.

EOF

# root's password is intentionally empty -- see docs/ARCHITECTURE.md.
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
export PS1='\u@flora # '
export PATH=/usr/bin:$HOME/apps/.bin
# en_US.UTF-8 generated at build time (build-rootfs.sh) -- without a real
# UTF-8 locale, programs fall back to bare POSIX "C" and some (e.g. foot)
# refuse to start at all ("is not a UTF-8 locale, and failed to find a
# fallback"). Confirmed on a real run, not guessed.
export LANG=en_US.UTF-8
# dbus-daemon started at boot (inittab) on a fixed address, not the usual
# per-session dynamic one -- see ARCHITECTURE.md. Without this, apps that
# need a session bus fall through to libdbus's own X11-only "autolaunch"
# fallback and fail outright on a pure-Wayland session (confirmed on a
# real `kitty` run, not guessed).
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/dbus/session_bus_socket
command -v fastfetch >/dev/null 2>&1 && fastfetch --config "$HOME/apps/fastfetch/config/fastfetch/config.jsonc"
EOF

# fastfetch config lives inside its own isolated app dir (see build-rootfs.sh),
# not /etc. Only applies if the fastfetch app install actually happened.
if [ -f "$FLORA_ROOT/assets/floraos-logo.txt" ] && [ -d "$ROOTFS/root/apps/fastfetch" ]; then
	mkdir -p "$ROOTFS/root/apps/fastfetch/config/fastfetch"
	cp "$FLORA_ROOT/assets/floraos-logo.txt" "$ROOTFS/root/apps/fastfetch/config/fastfetch/floraos-logo.txt"
	cp "$FLORA_ROOT/assets/fastfetch-config.jsonc" "$ROOTFS/root/apps/fastfetch/config/fastfetch/config.jsonc"
fi

# Silences loadkeys' cosmetic "gzip: command not found" -- see docs/ARCHITECTURE.md.
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

# sysvinit + openrc glue -- see docs/ARCHITECTURE.md (floralogin/PAM, job control).
cat > "$ROOTFS/etc/inittab" <<'EOF'
id:3:initdefault:

si::sysinit:/usr/bin/openrc sysinit
rc::bootwait:/usr/bin/openrc boot

l0:0:wait:/usr/bin/openrc shutdown
l1:S1:wait:/usr/bin/openrc single
l3:3:wait:/usr/bin/openrc default
l6:6:wait:/usr/bin/openrc reboot

# dhcpcd/udevd run as inittab `once` entries, not via openrc's runlevel
# dependency resolution -- see docs/ARCHITECTURE.md for why (a real,
# unresolved OpenRC scheduling gap, not a stylistic choice).
dh:2345:once:/etc/init.d/dhcpcd start >/dev/null 2>&1

ud:2345:once:/usr/bin/udevd --daemon && /usr/bin/udevadm trigger --action=add --type=subsystems && /usr/bin/udevadm trigger --action=add --type=devices && /usr/bin/udevadm settle >/dev/null 2>&1

# One shared bus for the whole (single-user) system, at a fixed address
# rather than the usual per-session dynamic one -- see ARCHITECTURE.md.
# --address explicitly overrides what /etc/dbus-1/session.conf would
# otherwise supply, so this needs no config file at all (confirmed).
db:2345:once:mkdir -p /run/dbus && /usr/bin/dbus-daemon --session --fork --address=unix:path=/run/dbus/session_bus_socket --nopidfile >/dev/null 2>&1

# floraseat: respawn, not once -- it runs in the foreground (see ARCHITECTURE.md).
fs:2345:respawn:/usr/bin/floraseat >>/var/log/floraseat.log 2>&1

1:2345:respawn:/usr/sbin/agetty --skip-login --login-program /usr/bin/floralogin --noclear tty1 linux
2:2345:respawn:/usr/sbin/agetty --skip-login --login-program /usr/bin/floralogin --noclear tty2 linux
s0:2345:respawn:/usr/sbin/agetty --skip-login --login-program /usr/bin/floralogin ttyS0 115200 vt100
EOF

# All four of this file's own custom services (dhcpcd, udevd, floraseat,
# emergency-shell below) must use the literal shebang "#!/sbin/openrc-run",
# not "#!/usr/bin/openrc-run" -- even though /sbin is symlinked to usr/bin
# and both resolve to the same binary. OpenRC's own dependency-cache
# generator (sh/gendepends.sh) does a plain string comparison against each
# script's first line before sourcing it for depend() info; anything else
# is silently skipped, no error. Found by chasing a real hang: emergency-
# shell's own "need localmount" (below) was being completely ignored,
# traced to it never appearing in /run/openrc/deptree at all.
#
# init.d script for dhcpcd -- manual rc-service only; not symlinked into
# etc/runlevels/default/ (see the inittab comment above).
cat > "$ROOTFS/etc/init.d/dhcpcd" <<'EOF'
#!/sbin/openrc-run
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

# Same "manual rc-service only" reasoning as dhcpcd's script above.
cat > "$ROOTFS/etc/init.d/udevd" <<'EOF'
#!/sbin/openrc-run
description="Device manager (eudev)"
command=/usr/bin/udevd
command_args="--daemon"
pidfile="/run/udevd.pid"

depend() {
	need sysfs
}
EOF
chmod 755 "$ROOTFS/etc/init.d/udevd"

# libinput tries to manage every device udev tags ID_INPUT_KEY, including the
# virtual ACPI "Power Button" device (LNXPWRBN) every machine (real or QEMU)
# exposes -- udev tagging it that way is correct/standard (it does have
# KEY_POWER), but libinput's own device-add sync for it blocks forever on a
# real mango run: confirmed via /proc/<pid>/stack showing evdev_read, and
# /proc/bus/input/devices identifying event0 as exactly this device -- no
# further compositor startup ever happens, no output gets committed, nothing
# renders, yet the process never crashes so it looks like a silent freeze.
# Every desktop environment routes power-button handling through a separate
# ACPI listener, never through libinput/the compositor, so this device was
# never meant to be here in the first place. Fixed via LIBINPUT_IGNORE_DEVICE
# (confirmed via `strings` on the real alpm-fetched libinput.so.10, sitting
# right next to ID_INPUT_KEY/ID_INPUT_KEYBOARD -- libinput's own documented
# udev property for excluding a device outright). Scoped to ATTRS{name} so
# only the power button is excluded -- the real keyboard/mouse devices are
# untouched.
mkdir -p "$ROOTFS/etc/udev/rules.d"
cat > "$ROOTFS/etc/udev/rules.d/71-libinput-ignore-power-button.rules" <<'EOF'
SUBSYSTEM=="input", ATTRS{name}=="Power Button", ENV{LIBINPUT_IGNORE_DEVICE}="1"
EOF

cat > "$ROOTFS/etc/init.d/floraseat" <<'EOF'
#!/sbin/openrc-run
description="Seat management daemon (floraseat, seatd-protocol-compatible)"
command=/usr/bin/floraseat
pidfile="/run/floraseat.pid"
# No command_background: floraseat stays foreground, openrc-run backgrounds it.

depend() {
	need udevd
}
EOF
chmod 755 "$ROOTFS/etc/init.d/floraseat"

# Single-user/emergency mode (inittab's `l1:S1:wait:/usr/bin/openrc single`)
# ran openrc against an empty etc/runlevels/single/ and did nothing at all --
# no shell, no prompt, silently unusable. sulogin exists specifically for
# this (see docs/MANIFEST.md's sysvinit entry) but was never wired in. Not a
# command= service: sulogin is an interactive, blocking session, not a
# daemon start-stop-daemon should background, so start() just runs it
# directly and waits for it to exit (an admin returning to a normal
# runlevel by hand afterwards, standard sysvinit single-user semantics).
#
# depend() need localmount is load-bearing, not decorative: openrc's own
# runlevel-switch code (src/rc/rc.c) explicitly excludes the boot runlevel
# (which owns localmount) when heading to "single", then tears down
# anything not otherwise still "needed" -- confirmed by reading rc.c and by
# a real hang, "openrc single" got stuck forever at "Unmounting
# filesystems" because nothing told it root should stay mounted. Declaring
# "need localmount" here makes openrc's reverse-dependency check
# (do_stop_services' "needsme" pass) see that this about-to-start service
# needs localmount, so it's skipped instead of stopped.
cat > "$ROOTFS/etc/init.d/emergency-shell" <<'EOF'
#!/sbin/openrc-run
description="Single-user emergency shell (sulogin)"

depend() {
	need localmount
}

start() {
	ebegin "Starting single-user shell"
	/usr/bin/sulogin
	eend 0
}
EOF
chmod 755 "$ROOTFS/etc/init.d/emergency-shell"
ln -sf /etc/init.d/emergency-shell "$ROOTFS/etc/runlevels/single/emergency-shell"

# Dead weight removed: FloraOS relies entirely on dhcpcd, not these two
# scripts' static ifconfig/route bringup -- see docs/ARCHITECTURE.md.
rm -f "$ROOTFS/etc/runlevels/boot/network"
rm -f "$ROOTFS/etc/runlevels/boot/staticroute"
