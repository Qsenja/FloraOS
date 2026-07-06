# FloraOS Base Rootfs Manifest

Every package/binary in the base image, and why it's there. Nothing gets added
without a line here. If you can't justify it in one line, it doesn't belong
in the base.

## Build-time only (not present in the final image)

| Component | Reason |
|---|---|
| this build host's own gcc/binutils | compiles every package from source. Every FloraOS binary is still built from pristine upstream source (nothing copied from Arch/Artix) -- we just use the compiler already on this machine to do the compiling, rather than *also* bootstrapping our own compiler from scratch first (a deliberate scope call: full LFS-style cross-toolchain bootstrapping adds hours and much more that can break, for no benefit beyond purity) |
| sanitized linux kernel headers | `make headers_install` from the linux-lts source, needed so glibc builds against the right kernel ABI |

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
| libmd | dhcpcd links against this (BSD message-digest routines) with no configure flag to avoid it, unlike most other auto-detected-optional-lib gaps found here |
| attr, acl | gnulib-based tools (sed, and potentially others later) auto-detect and link against libattr/libacl if present on whatever machine builds them, regardless of whether their own configure was told to care about xattrs/ACLs. Shipping these once closes that class of gap instead of chasing it per-package |
| grep | fau's own JSON parsing and package lookup logic uses grep — without it fau is broken *inside the running OS* (it only worked at build time because the build host has it) |
| sed | fau's JSON read/write functions use sed — same reasoning as grep |
| gawk | fau's repo/desc field parsing uses awk — same reasoning as grep |
| findutils | fau's app-install bin-entrypoint detection uses find; dependency-list parsing uses xargs — same reasoning as grep |
| tar | fau's own package format (.fau.tar.zst) is a tar archive; fau extracts/builds these with tar — same reasoning as grep |
| zstd | fau's package format is .fau.tar.zst — fau can't extract or build any package without it — same reasoning as grep |
| rsync | fau's system-package installs merge via `rsync -aK` (needed to merge into the merged-/usr symlinks without replacing them) — same reasoning as grep |
| fau | FloraOS's own package manager (see tools/fau) — installs from the FloraOS package repo and owns the `system.json` reproducibility manifest natively. (Yes, fau needs the row above to function — a small bootstrapping irony worth naming rather than leaving implicit) |

## Branding (not part of the minimal-base philosophy, added deliberately anyway)

| Package | Reason |
|---|---|
| libgcc | fastfetch (C++) needs libgcc_s.so.1 for exception-handling at runtime. Not a declared dependency of fastfetch itself -- Arch/Artix assume it's always present as a base-system package -- so it has to be installed explicitly alongside it |
| fastfetch | requested identity/branding touch — shown at login via /etc/profile, configured with a custom logo (assets/floraos-logo.txt) and a Packages line reading fau's own list instead of a package manager it doesn't know about. Fetched via fau's pacman-backed fallback, not built from source (small, and not core to the OS) |

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
