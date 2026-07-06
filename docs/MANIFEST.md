# FloraOS Base Rootfs Manifest

Every package/binary in the base image, and why it's there. Nothing gets added
without a line here. If you can't justify it in one line, it doesn't belong
in the base.

## Build-time only (LFS-style bootstrap toolchain, not present in final image)

| Component | Reason |
|---|---|
| cross gcc | compiles the target toolchain and every runtime package from source |
| cross binutils | assembler/linker for the cross toolchain |
| linux kernel headers | needed to build glibc against the target kernel ABI |
| glibc (pass 1) | bootstrap libc so the final gcc/binutils can build native binaries |

## Runtime (shipped in the base rootfs)

| Package | Reason |
|---|---|
| linux-lts | kernel; LTS branch means fewer breaking changes to track on a from-scratch distro (see ARCHITECTURE.md) |
| glibc | libc; standard pairing with GNU userland, which the target spec mandates |
| ncurses | terminal capabilities (terminfo) library — bash/readline links against libncursesw.so.6 dynamically; without shipping it ourselves bash can't even load |
| bash | required default shell |
| coreutils | required GNU userland (ls, cp, mv, cat, ...) |
| util-linux | required GNU userland (mount, fdisk, losetup, ...) |
| e2fsprogs | mkfs.ext4/fsck.ext4 — minimum filesystem tooling to build and check the rootfs |
| sysvinit | PID1 — OpenRC is a runlevel/dependency manager, not a PID1 implementation itself, and needs one of sysvinit/busybox-init as a companion. sysvinit is the traditional OpenRC pairing (pre-systemd Gentoo/Arch/etc.) and, unlike busybox, isn't a single monolithic binary, keeping with the GNU-userland-only rule |
| openrc | runlevel/service manager, started by sysvinit; explicitly no systemd |
| dhcpcd | DHCP client; base networking as specified in the target spec |
| iproute2 | `ip` command for manual interface/route configuration when dhcpcd isn't enough |
| fau | FloraOS's own package manager (see tools/fau) — installs from the FloraOS package repo and owns the `system.json` reproducibility manifest natively |

## Build-host tooling (not part of FloraOS, not built from source)

| Tool | Reason |
|---|---|
| grub-mkrescue + xorriso | assembles the hybrid BIOS+UEFI bootable ISO. GRUB's own boot images (i386-pc, x86_64-efi) are embedded straight into the ISO's boot catalog by the build host's GRUB install — this runs *before* FloraOS's kernel starts, so it isn't a FloraOS package any more than the host's gcc is. Dropped a from-source syslinux+grub build (would've meant compiling 16-bit real-mode boot code) with no loss of functionality: grub-mkrescue alone covers both boot paths. |

## Explicitly excluded (and why)

| Excluded | Reason |
|---|---|
| systemd | violates the OpenRC-only constraint |
| pacman | would mean vendoring a third-party package manager's codebase; fau is written from scratch instead |
| openssh | keeps default attack surface minimal; add as an optional package later if needed |
| any GUI/desktop/browser | out of scope — base is a headless minimal system |
| syslog daemon | not yet scripted — TODO: add a minimal syslog target once a concrete logging need shows up |
