# FloraOS Base Filesystem Layout

Standard FHS layout, nothing exotic. Only the parts worth calling out:

```
/
├── bin -> usr/bin          # symlinked, single /usr/bin per modern FHS practice
├── sbin -> usr/bin
├── lib -> usr/lib
├── lib64 -> usr/lib
├── usr/
│   ├── bin/                # coreutils, bash, util-linux, dhcpcd, ip, fau, floralogin, ...
│   ├── sbin -> bin          # autotools' default --sbindir merges in too
│   ├── lib/
│   └── share/
├── etc/
│   ├── os-release           # FloraOS identity (see below)
│   ├── hostname              # "floraos" default
│   ├── motd                  # FloraOS banner
│   ├── issue                  # shown by agetty before the login prompt
│   ├── fstab
│   ├── fau/
│   │   └── repo.conf         # points fau at the FloraOS package repo
│   ├── init.d/                # OpenRC service scripts
│   ├── conf.d/                 # OpenRC service config
│   └── runlevels/              # OpenRC runlevel symlinks (sysinit/boot/default)
├── var/
│   ├── log/
│   ├── lib/
│   │   └── fau/
│   │       └── system.json    # fau's installed-package manifest (see tools/fau)
│   └── cache/fau/pkg/          # downloaded/built package archives
├── boot/                        # kernel, initramfs, bootloader files
├── home/
├── root/
├── proc/, sys/, dev/, run/, tmp/  # created empty, populated at boot by the kernel/openrc
```

## Identity defaults

- `/etc/os-release`: `NAME="FloraOS"`, `ID=floraos`, `PRETTY_NAME="FloraOS"` (version fields filled in by the rootfs build script from the manifest/build date)
- `/etc/hostname`: `floraos`
- `/etc/motd`: short FloraOS banner, printed on login
- `/etc/issue`: login prompt banner (agetty prints it before asking for
  credentials) — documents that root's password is intentionally empty,
  see ARCHITECTURE.md

## /etc skeleton

Minimal set only: `passwd`, `group`, `shadow`, `fstab`, `hostname`, `os-release`,
`motd`, `issue`, `resolv.conf` (populated by dhcpcd), `init.d/`, `conf.d/`,
`runlevels/`. No cron, no PAM (floralogin is PAM-free, see ARCHITECTURE.md),
no extra service config for packages that aren't in the manifest. `/etc/group`
has one non-root entry, `uucp` — openrc's own upstream `init.sh` runs
`checkpath -o root:uucp /run/lock` unconditionally; without the group it just
logged "owner not found" every boot.
