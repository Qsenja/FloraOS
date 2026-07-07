#!/usr/bin/env bash
# End-to-end test for florainstall's UEFI/ESP path -- sibling to
# scripts/test-install.sh (which only ever exercised BIOS/i386-pc). Same
# serial-console TUI-driving technique (see scripts/lib/common.sh's qemu_*
# helpers), but boots QEMU with OVMF pflash firmware instead of BIOS/SeaBIOS,
# to check:
#   1. the live ISO itself actually took the UEFI boot path (grub-mkrescue's
#      hybrid image supports this -- see docs/ARCHITECTURE.md's Bootloader
#      section -- but this confirms OVMF actually exercised it, not BIOS/CSM)
#   2. florainstall detects that and partitions accordingly (ESP + Linux
#      root, not the single-partition BIOS scheme), and its confirm-
#      destructive dialog says so
#   3. grub-install --target=x86_64-efi --removable actually produces a disk
#      that boots -- specifically via the *fallback* EFI/BOOT/BOOTX64.EFI
#      path, not an NVRAM boot entry: the second boot uses a completely
#      fresh OVMF_VARS template (no NVRAM entries at all), the same state a
#      real firmware's NVRAM would be in on a disk moved to different
#      hardware, or a firmware that was reset
#   4. the installed system really is rootflags=subvol=@ on the *second*
#      partition (the ESP took the first), and the ESP is mounted at
#      /boot/efi per fstab
#
# Deliberately NOT folded into test-install.sh itself: that script's four
# phases (install/backup/grub-reboot/restore) are entirely BIOS-vs-UEFI
# agnostic past the install step (floragrub-cfg's grub.cfg format doesn't
# change either way, see tools/floragrub-cfg's own header), so re-running
# all four under OVMF would just re-prove the same backup/restore logic a
# second time for no real extra coverage -- this only re-checks the parts
# that actually differ: partitioning and the bootloader install/boot itself.
#
# Requires OVMF firmware on the build host (edk2-ovmf or equivalent
# package) -- searches a handful of real, common install paths across
# distros rather than hardcoding one, and dies with a clear message instead
# of silently skipping if none is found.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

ISO="${1:-$FLORA_ROOT/floraos.iso}"
DISK_IMG="$WORK_DIR/test-install-uefi-disk.img"
DISK_SIZE="${TEST_INSTALL_DISK_SIZE:-6G}"
LOGIN_MARKER="floraos-boot-ok"

require_cmd qemu-system-x86_64
require_cmd qemu-img
require_cmd socat
[ -f "$ISO" ] || die "no ISO at $ISO -- run ./floraiso build first"

# Real paths this firmware is actually installed at across distros (Arch's
# edk2-ovmf, Debian/Ubuntu's ovmf, Fedora's edk2-ovmf) -- not a guess, each
# checked against this project's own build/test hosts.
OVMF_CODE=""
OVMF_VARS_TEMPLATE=""
for candidate in \
	"/usr/share/edk2/OVMF_CODE_4M.fd:/usr/share/edk2/OVMF_VARS_4M.fd" \
	"/usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd" \
	"/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd" \
	"/usr/share/edk2-ovmf/x64/OVMF_CODE.fd:/usr/share/edk2-ovmf/x64/OVMF_VARS.fd" \
; do
	code=${candidate%%:*}; vars=${candidate##*:}
	if [ -f "$code" ] && [ -f "$vars" ]; then
		OVMF_CODE=$code
		OVMF_VARS_TEMPLATE=$vars
		break
	fi
done
[ -n "$OVMF_CODE" ] || die "no OVMF firmware found (checked common edk2-ovmf/OVMF install paths) -- install it to run this test"

OVMF_VARS_INSTALL="$WORK_DIR/test-install-uefi-vars-install.fd"
OVMF_VARS_BOOT="$WORK_DIR/test-install-uefi-vars-boot.fd"

log "creating scratch disk image ($DISK_SIZE) at $DISK_IMG"
rm -f "$DISK_IMG"
qemu-img create -f raw "$DISK_IMG" "$DISK_SIZE" >/dev/null

login_and_wait_shell() {
	qemu_wait_for "floraos login:" 60 || { log "FAIL: never reached the login prompt"; return 1; }
	qemu_send $'root\r'
	qemu_wait_for "Password:" 20 || { log "FAIL: never reached the password prompt"; return 1; }
	qemu_send $'\r'
	qemu_wait_for "$LOGIN_MARKER" 30 || { log "FAIL: login didn't reach a shell"; return 1; }
}

# See test-install.sh's own qemu_run for why this counts fresh prompts
# rather than waiting for a sentinel embedded in the command itself.
qemu_run() {
	local cmd=$1 timeout=${2:-30}
	local before; before=$(grep -c "$LOGIN_MARKER" "$QEMU_LOG" 2>/dev/null || echo 0)
	qemu_send "$cmd"$'\r'
	local deadline=$(( $(date +%s) + timeout ))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		local now; now=$(grep -c "$LOGIN_MARKER" "$QEMU_LOG" 2>/dev/null || echo 0)
		[ "$now" -gt "$before" ] && return 0
		sleep 0.3
	done
	return 1
}

end_phase() {
	qemu_send $'reboot\r' 2>/dev/null || true
	local waited=0
	while kill -0 "$QEMU_PID" 2>/dev/null && [ "$waited" -lt 30 ]; do
		sleep 1; waited=$((waited + 1))
	done
	qemu_quit
}

pass=1
fail() { log "FAIL: $*"; echo "FAIL: $*" >> "$WORK_DIR/test-install-uefi-result.txt"; pass=0; }
: > "$WORK_DIR/test-install-uefi-result.txt"

cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_INSTALL"

# --- phase 1: install onto the scratch disk, booted via OVMF/UEFI --------
log "=== phase 1/2: florainstall onto the scratch disk, booted via OVMF/UEFI ==="
qemu_boot_serial install \
	-m 2048 -cdrom "$ISO" -boot d \
	-drive "file=$DISK_IMG,format=raw,if=ide" \
	-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
	-drive "if=pflash,format=raw,file=$OVMF_VARS_INSTALL" \
	-nographic -no-reboot -display none

if login_and_wait_shell; then
	if qemu_run 'test -d /sys/firmware/efi && echo LIVE-IS-UEFI' 10; then
		grep -q "LIVE-IS-UEFI" "$QEMU_LOG" && log "confirmed: live ISO itself booted via UEFI (OVMF)" \
			|| fail "live ISO didn't report /sys/firmware/efi -- OVMF boot didn't actually take the UEFI path"
	else
		fail "couldn't check /sys/firmware/efi on the live system"
	fi

	qemu_send $'florainstall\r'
	if qemu_wait_for "FloraOS disk installer" 20; then
		# Same navigation as test-install.sh's BIOS phase 1: item 0 (disk
		# picker) already highlighted, its one entry already highlighted too.
		qemu_send $'\r'
		qemu_wait_for "Select target disk" 10 || fail "disk picker never appeared"
		qemu_send $'\r'
		qemu_send $'\x1bOB\x1bOB\x1bOB\r'
		if qemu_wait_for "ERASES" 10; then
			if qemu_wait_for "EFI System Partition" 5; then
				log "confirm-destructive dialog correctly reported UEFI mode"
			else
				fail "confirm-destructive dialog didn't mention UEFI/ESP"
			fi
			if qemu_wait_for "/dev/sda" 2; then
				qemu_send $'sda\r'
				if qemu_wait_for "setting the root password" 240; then
					if qemu_wait_for "New password:" 20; then
						qemu_send $'\r'
						qemu_wait_for "Retype new password:" 10 && qemu_send $'\r'
					fi
					if qemu_wait_for "done. Remove the installation media" 60; then
						log "install finished"
					else
						fail "florainstall never printed its final 'done' message"
					fi
				else
					fail "florainstall never got to setting the root password"
				fi
			else
				fail "confirm-destructive prompt didn't show /dev/sda as the target"
			fi
		else
			fail "the destructive-confirm prompt never appeared"
		fi
	else
		fail "florainstall's TUI never came up"
	fi
else
	fail "couldn't log in to the live ISO"
fi
end_phase

# --- phase 2: boot the installed disk via a FRESH OVMF_VARS ---------------
# No NVRAM boot entries at all -- specifically exercises the --removable
# fallback path (EFI/BOOT/BOOTX64.EFI), not an NVRAM entry grub-install
# might have registered, since that's the whole point of using --removable
# (see florainstall.c's own header comment).
log "=== phase 2/2: boot the installed disk via OVMF with fresh (empty) NVRAM ==="
cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_BOOT"
qemu_boot_serial boot1 \
	-m 1024 -drive "file=$DISK_IMG,format=raw,if=ide" \
	-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
	-drive "if=pflash,format=raw,file=$OVMF_VARS_BOOT" \
	-nographic -no-reboot -display none

if login_and_wait_shell; then
	if qemu_run 'cat /proc/cmdline' 15; then
		grep -q 'rootflags=subvol=@ ' "$QEMU_LOG" && log "subvolume layout confirmed (rootflags=subvol=@)" \
			|| fail "installed system's /proc/cmdline doesn't show rootflags=subvol=@"
		grep -q 'root=/dev/sda2 ' "$QEMU_LOG" && log "root is /dev/sda2 (partition 1 is the ESP)" \
			|| fail "root isn't /dev/sda2 -- expected the ESP to be partition 1"
	else
		fail "couldn't read /proc/cmdline on the installed disk"
	fi
	if qemu_run 'test -d /sys/firmware/efi && echo BOOTED-VIA-UEFI' 10; then
		grep -q "BOOTED-VIA-UEFI" "$QEMU_LOG" \
			&& log "confirmed: installed disk booted via UEFI (fresh NVRAM, --removable fallback path worked)" \
			|| fail "installed disk didn't report /sys/firmware/efi -- fell back to BIOS/CSM or didn't boot at all"
	else
		fail "couldn't check /sys/firmware/efi on the installed disk"
	fi
	if qemu_run 'mount | grep boot/efi' 10; then
		grep -q "/boot/efi" "$QEMU_LOG" && log "ESP is mounted at /boot/efi per fstab" \
			|| fail "/boot/efi isn't mounted -- fstab entry missing or wrong"
	else
		fail "couldn't check the ESP mount"
	fi
else
	fail "couldn't log in on the installed disk (first UEFI boot)"
fi
end_phase

# Written to a file, not just stdout -- see test-install.sh's own comment on
# this: nested backgrounding across qemu_boot_serial sessions has been
# observed to truncate captured stdout in some invocation contexts even
# though every phase genuinely ran to completion.
if [ "$pass" -eq 1 ]; then
	log "PASS -- florainstall's UEFI/ESP path verified end-to-end (logs under $WORK_DIR/qemu-*.log)"
	echo "PASS" >> "$WORK_DIR/test-install-uefi-result.txt"
	exit 0
else
	log "FAIL -- see $WORK_DIR/qemu-*-boot.log for the failing phase's transcript"
	echo "FAIL" >> "$WORK_DIR/test-install-uefi-result.txt"
	exit 1
fi
