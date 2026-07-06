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
| glibc | libc; standard pairing with GNU userland, which the target spec mandates. `memusagestat` pruned post-install (needs libgd, which FloraOS doesn't ship) |
| ncurses | terminal capabilities (terminfo) library — bash/readline links against libncursesw.so.6 dynamically; without shipping it ourselves bash can't even load. Built with `--with-versioned-syms`: without it, every single invocation of anything linking against it warned "no version information available" (bash etc. are built against this build host's own *versioned* ncurses, so they request a version node ours didn't define) — cosmetic, but found on every line of a real interactive boot |
| bash | required default shell |
| coreutils | required GNU userland (ls, cp, mv, cat, ...) |
| util-linux | required GNU userland (mount, fdisk, losetup, ...) |
| e2fsprogs | mkfs.ext4/fsck.ext4 — minimum filesystem tooling to build and check the rootfs. `fsck.cramfs`/`mkfs.cramfs` pruned post-install (legacy filesystem FloraOS doesn't use, needs libz, which FloraOS doesn't ship) |
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
| procps-ng | `sysctl` — OpenRC's `etc/init.d/sysctl` service (`sysctl --system`) failed non-fatally without it; the rest of the suite (ps/top/kill/free/watch/...) comes along for free from the same source tree. Only upstream package here without a generated `configure` in its release artifact (raw gitlab source archive) — needs `autoreconf` on the build host |
| hostname | `hostname`/`dnsdomainname` — OpenRC's `etc/init.d/hostname` service failed non-fatally without it. Deliberately the small standalone package (Debian's `hostname.c` + Makefile), not inetutils, which bundles telnet/ftp/rsh/talk/etc for the one command actually needed here |
| kbd | `loadkeys`/`dumpkeys`/`setfont` — OpenRC's `etc/init.d/keymaps` service failed non-fatally without it. Built with vlock/zlib/bzip2/lzma/xkb off (PAM, and libs FloraOS doesn't ship); zstd left on since fau already needs libzstd. Known minor gap: loadkeys shells out to `gzip` to decompress `.gz` keymaps and falls back to its own internal decompression when that's missing (FloraOS doesn't ship gzip) — cosmetic stderr noise, keymap still loads |
| libxcrypt | glibc itself dropped `crypt()`/`crypt.h` a few versions back — floralogin (see below) needs it to verify `/etc/shadow` hashes. Built with `--enable-obsolete-api=glibc` for the traditional crypt(3) ABI (SONAME `libcrypt.so.1`) |
| mbedtls | TLS backend for curl (below) — the pacman mirrors are HTTPS-only. Picked over OpenSSL: a plain-Makefile build (no cmake, which this project uses nowhere else) and a smaller footprint. Only the shared libs + headers are staged (`make lib`, not `make install`, which unconditionally also builds mbedTLS's own example/test/fuzz programs) |
| curl | fau's pacman-backed fallback needs an HTTP client to fetch anything once running inside a booted FloraOS system (no pacman there to shell out to) — confirmed by literally running `fau install` after boot: "curl: command not found". Trimmed to HTTP/HTTPS only (no FTP/telnet/gopher/mqtt/etc, no libpsl, no libidn2, no nghttp2) — none of that is needed to fetch from a fixed set of mirror hostnames |
| ca-certificates | curl needs a trust store to validate the mirrors' HTTPS certs. Not a compiled package — Mozilla's root CA list, maintained and republished by the curl project specifically for systems without their own CA infrastructure. Fetched directly in build-rootfs.sh (a plain data file, not a tarball) rather than through the recipe pipeline |

## FloraOS-authored (not a fetched upstream package, compiled directly)

| Tool | Reason |
|---|---|
| floralogin (`tools/floralogin`) | FloraOS's own ~100-line, from-scratch, PAM-free login — util-linux's own login unconditionally requires PAM to build at all (no fallback exists upstream), and PAM isn't part of FloraOS. Verifies against `/etc/shadow` via crypt(3)/libxcrypt, execs the shell on success. `/etc/inittab` runs it via `agetty --skip-login --login-program`, same as `fau` itself, not tracked in fau's own package manifest since it's compiled straight from FloraOS's own source, not fetched from anywhere (see build-rootfs.sh) |

## Branding (not part of the minimal-base philosophy, added deliberately anyway)

| Package | Reason |
|---|---|
| libgcc | fastfetch (C++) needs libgcc_s.so.1 for exception-handling at runtime. Not a declared dependency of fastfetch itself -- Arch/Artix assume it's always present as a base-system package -- so it has to be installed explicitly alongside it |
| fastfetch | requested identity/branding touch — shown at login via /etc/profile, configured with a custom logo (assets/floraos-logo.txt) and a Packages line reading fau's own list instead of a package manager it doesn't know about. Fetched via fau's pacman-backed fallback, not built from source (small, and not core to the OS). Resolving it pulls in Arch's full dependency closure (glibc, filesystem, tzdata, iana-etc, linux-api-headers) -- `fau` now skips anything it already built itself and strips `etc/`+`usr/include` from the rest (see ARCHITECTURE.md's fau section for why) |

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
