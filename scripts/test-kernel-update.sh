#!/usr/bin/env bash
# End-to-end QEMU test for the linux-lts rolling-update safety story: does a
# real `fau bootstrap-build linux-lts` rebuild, merged into a live disk
# install, actually recover via floragrub-cfg's per-snapshot GRUB entry if
# the resulting kernel doesn't boot? See docs/TODO.md's linux-lts entry.
#
# Unlike test-install.sh, this needs real guest networking (the kernel
# recipe is fetched from fau-recipes over HTTPS, same as production) and a
# much longer serial-idle timeout (the kernel build's own output is
# redirected to /dev/null by the recipe, so the guest can go quiet for a
# long stretch while still working -- not a hang).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

ISO="${1:-$FLORA_ROOT/floraos.iso}"
DISK_IMG="$WORK_DIR/test-kernel-disk.img"
DISK_SIZE="${TEST_INSTALL_DISK_SIZE:-8G}"
LOGIN_MARKER="root@flora #"
SNAP_NAME="pre-kernel-test"
SNAP_TITLE="FloraOS (backup: $SNAP_NAME)"
QEMU_SERIAL_TIMEOUT=21600 # kernel build's own output goes to /dev/null; can go quiet for a long time, not a hang

require_cmd qemu-system-x86_64
require_cmd qemu-img
require_cmd socat
[ -f "$ISO" ] || die "no ISO at $ISO -- run ./floraiso build first"

log "creating scratch disk image ($DISK_SIZE) at $DISK_IMG"
rm -f "$DISK_IMG"
qemu-img create -f raw "$DISK_IMG" "$DISK_SIZE" >/dev/null

NET_ARGS=(-netdev user,id=net0 -device virtio-net-pci,netdev=net0)
SMP_ARGS=(-smp 10)

login_and_wait_shell() {
	qemu_wait_for "floraos login:" 60 || { log "FAIL: never reached the login prompt"; return 1; }
	qemu_send $'root\r'
	qemu_wait_for "Password:" 20 || { log "FAIL: never reached the password prompt"; return 1; }
	qemu_send $'\r'
	qemu_wait_for "$LOGIN_MARKER" 30 || { log "FAIL: login didn't reach a shell"; return 1; }
}

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

qemu_run_ok() {
	local cmd=$1 timeout=${2:-30}
	# Scoped to just this command's own output, not the whole cumulative
	# log -- an earlier successful command's "RC=0" would otherwise still
	# be sitting in $QEMU_LOG and produce a false positive for a later
	# failing one (real bug, caught by this exact test run: a stale RC=0
	# from an earlier `fau backup` masked a real `fau bootstrap-build`
	# failure).
	local before; before=$(wc -l < "$QEMU_LOG" 2>/dev/null || echo 0)
	qemu_run "$cmd" "$timeout" || return 1
	qemu_run 'echo "RC=$?"' 10 || return 1
	tail -n "+$((before + 1))" "$QEMU_LOG" | grep -q 'RC=0'
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
fail() { log "FAIL: $*"; echo "FAIL: $*" >> "$WORK_DIR/test-kernel-result.txt"; pass=0; }
: > "$WORK_DIR/test-kernel-result.txt"

# --- phase 1: install onto the scratch disk -------------------------------
log "=== phase 1/3: florainstall onto the scratch disk ==="
qemu_boot_serial install \
	-m 2048 "${SMP_ARGS[@]}" -cdrom "$ISO" -boot d \
	-drive "file=$DISK_IMG,format=raw,if=ide" \
	"${NET_ARGS[@]}" \
	-nographic -no-reboot -display none

if login_and_wait_shell; then
	qemu_send $'florainstall\r'
	if qemu_wait_for "FloraOS disk installer" 20; then
		qemu_send $'\r'
		qemu_wait_for "Select target disk" 10 || fail "disk picker never appeared"
		qemu_send $'\r'
		qemu_send $'\x1bOB\x1bOB\x1bOB\r'
		if qemu_wait_for "ERASES" 10; then
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
[ "$pass" -eq 1 ] || { log "FAIL -- install phase didn't complete, aborting"; exit 1; }

# --- phase 2: boot the install, snapshot, rebuild the kernel, break it ----
log "=== phase 2/3: fau backup, fau bootstrap-build linux-lts, then break the live kernel ==="
qemu_boot_serial update -m 8192 "${SMP_ARGS[@]}" -drive "file=$DISK_IMG,format=raw,if=ide" "${NET_ARGS[@]}" -nographic -no-reboot -display none

old_release=""
if login_and_wait_shell; then
	# dhcpcd is an inittab `once` entry, asynchronous -- it doesn't block
	# boot, so a command run immediately after reaching the shell can
	# race it (confirmed: this is exactly what happened on the first run
	# of this test). The install phase never hit this because its own
	# long interactive TUI flow gave dhcpcd plenty of time regardless.
	# The loop MUST be wrapped in ( ) -- a bare `exit` typed directly at
	# the interactive shell logs the session out entirely instead of
	# just ending the loop (also confirmed the hard way, first run).
	if qemu_run_ok '(for i in $(seq 1 60); do ip addr show 2>/dev/null | grep -q "inet .*scope global" && exit 0; sleep 1; done; exit 1)' 70; then
		log "network is up (some interface has a global address)"
	else
		qemu_run 'ip addr; rc-service dhcpcd status; cat /var/log/dhcpcd.log 2>/dev/null | tail -30' 10 || true
		fail "no interface ever got a global address -- dhcpcd didn't come up in time (see the diagnostic dump just above in the boot log)"
	fi

	if qemu_run 'uname -r' 15; then
		old_release=$(grep -A1 'uname -r' "$QEMU_LOG" | tail -1 | tr -d '\r')
		log "baseline kernel release: $old_release"
	else
		fail "couldn't read baseline uname -r"
	fi

	if qemu_run_ok "fau backup $SNAP_NAME" 30; then
		grep -q "backup '$SNAP_NAME' created" "$QEMU_LOG" && log "fau backup created $SNAP_NAME" \
			|| fail "fau backup exited 0 but didn't print its usual success message"
	else
		fail "fau backup didn't report success"
	fi

	if qemu_run "cat /boot/grub/grub.cfg" 10; then
		grep -q "backup: $SNAP_NAME" "$QEMU_LOG" && log "grub.cfg regenerated with the pre-update snapshot entry" \
			|| fail "grub.cfg wasn't regenerated with a $SNAP_NAME entry"
	else
		fail "couldn't read /boot/grub/grub.cfg"
	fi

	log "running fau bootstrap-build linux-lts for real (this can take a long while, output suppressed by the recipe itself)"
	if qemu_run_ok "fau bootstrap-build linux-lts" 18000; then
		log "fau bootstrap-build linux-lts reported success"
	else
		fail "fau bootstrap-build linux-lts did not report success"
	fi

	if qemu_run 'cat /boot/kernelrelease' 10; then
		log "post-rebuild /boot/kernelrelease: $(grep -A1 'cat /boot/kernelrelease' "$QEMU_LOG" | tail -1 | tr -d '\r')"
	else
		fail "couldn't read /boot/kernelrelease after the rebuild"
	fi

	new_release_modules_ok=0
	if qemu_run_ok 'test -f "/usr/lib/modules/$(cat /boot/kernelrelease)/modules.dep"' 15; then
		log "depmod ran: modules.dep present for the new kernelrelease (recipe_post_merge worked)"
		new_release_modules_ok=1
	else
		fail "modules.dep missing for the new kernelrelease -- recipe_post_merge's depmod didn't run correctly"
	fi
	[ "$new_release_modules_ok" -eq 1 ] || true

	# Simulate "the rebuild produced an unbootable kernel": corrupt the
	# LIVE @'s own vmlinuz-floraos. The pre-update snapshot's copy is a
	# separate, already-frozen btrfs subvolume -- untouched by this.
	if qemu_run_ok 'dd if=/dev/zero of=/boot/vmlinuz-floraos bs=1M count=2 conv=notrunc' 15; then
		log "deliberately corrupted the live kernel to simulate a bad rebuild"
	else
		fail "couldn't corrupt /boot/vmlinuz-floraos for the test"
	fi

	# Arm the fallback for the NEXT boot while the current (good, still
	# running) kernel is still up -- exactly the real recovery action a
	# user takes from the GRUB menu, done here non-interactively the same
	# way test-install.sh's backup-restore test already does.
	if qemu_run_ok "grub-reboot \"$SNAP_TITLE\"" 10; then
		log "armed the pre-update snapshot as the next boot target"
	else
		fail "grub-reboot into the pre-update snapshot entry failed"
	fi
else
	fail "couldn't log in on the update boot"
fi
end_phase
[ "$pass" -eq 1 ] || { log "FAIL -- update phase didn't complete cleanly, but continuing to the recovery boot to see what happens"; }

# --- phase 3: the one-shot recovery boot ----------------------------------
log "=== phase 3/3: booting the pre-update snapshot (grub-reboot), confirming it's the OLD kernel ==="
qemu_boot_serial recover -m 2048 "${SMP_ARGS[@]}" -drive "file=$DISK_IMG,format=raw,if=ide" "${NET_ARGS[@]}" -nographic -no-reboot -display none

if login_and_wait_shell; then
	if qemu_run 'cat /proc/cmdline' 15; then
		grep -q "rootflags=subvol=@snapshots/$SNAP_NAME" "$QEMU_LOG" \
			&& log "booted the pre-update snapshot's own subvolume, as grub-reboot intended" \
			|| fail "recovery boot didn't land on rootflags=subvol=@snapshots/$SNAP_NAME"
	else
		fail "couldn't read /proc/cmdline on the recovery boot"
	fi

	if qemu_run 'uname -r' 15; then
		recovered_release=$(grep -A1 'uname -r' "$QEMU_LOG" | tail -1 | tr -d '\r')
		log "recovered kernel release: $recovered_release (baseline was: $old_release)"
		[ "$recovered_release" = "$old_release" ] \
			&& log "CONFIRMED: recovery boot is running the OLD kernel, not the corrupted one" \
			|| fail "recovered kernel release ($recovered_release) doesn't match the pre-update baseline ($old_release)"
	else
		fail "couldn't read uname -r on the recovery boot"
	fi
else
	fail "couldn't log in on the recovery boot -- the fallback entry itself failed to boot, this is the actual failure mode the whole feature exists to prevent"
fi
end_phase

if [ "$pass" -eq 1 ]; then
	log "PASS -- linux-lts rolling rebuild + GRUB snapshot recovery verified end-to-end (logs under $WORK_DIR/qemu-*.log)"
	echo "PASS" >> "$WORK_DIR/test-kernel-result.txt"
	exit 0
else
	log "FAIL -- see $WORK_DIR/qemu-*-boot.log for the failing phase's transcript"
	echo "FAIL" >> "$WORK_DIR/test-kernel-result.txt"
	exit 1
fi
