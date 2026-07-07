#!/usr/bin/env bash
# End-to-end QEMU disk-boot test for florainstall + `fau backup`/
# `backup-restore` -- see docs/ARCHITECTURE.md's fau-backup entry and "Test
# harness" section for the full scope and the qemu_* helpers this uses.
# Takes several minutes; not part of `floraiso test` (ISO boot only).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

ISO="${1:-$FLORA_ROOT/floraos.iso}"
DISK_IMG="$WORK_DIR/test-install-disk.img"
DISK_SIZE="${TEST_INSTALL_DISK_SIZE:-6G}"
LOGIN_MARKER="floraos-boot-ok"
SNAP_NAME="testsnap"
SNAP_TITLE="FloraOS (backup: $SNAP_NAME)"

require_cmd qemu-system-x86_64
require_cmd qemu-img
require_cmd socat
[ -f "$ISO" ] || die "no ISO at $ISO -- run ./floraiso build first"

log "creating scratch disk image ($DISK_SIZE) at $DISK_IMG"
rm -f "$DISK_IMG"
qemu-img create -f raw "$DISK_IMG" "$DISK_SIZE" >/dev/null

# --- small helpers on top of scripts/lib/common.sh's qemu_* primitives ----

login_and_wait_shell() {
	qemu_wait_for "floraos login:" 60 || { log "FAIL: never reached the login prompt"; return 1; }
	qemu_send $'root\r'
	qemu_wait_for "Password:" 20 || { log "FAIL: never reached the password prompt"; return 1; }
	qemu_send $'\r'
	qemu_wait_for "$LOGIN_MARKER" 30 || { log "FAIL: login didn't reach a shell"; return 1; }
}

# qemu_run <command-line> [timeout] -- waits for a fresh prompt (counting
# $LOGIN_MARKER) rather than a command-echoed sentinel -- see ARCHITECTURE.md,
# the latter races the pty's own input echo and was intermittently flaky.
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

# qemu_run_ok <command-line> [timeout] -- like qemu_run, plus confirms exit
# status 0 via a follow-up `echo "RC=$?"` (safe from the same echo race).
qemu_run_ok() {
	local cmd=$1 timeout=${2:-30}
	qemu_run "$cmd" "$timeout" || return 1
	qemu_run 'echo "RC=$?"' 10 || return 1
	grep -q 'RC=0' "$QEMU_LOG"
}

end_phase() {
	# -no-reboot means a guest `reboot` makes qemu exit rather than reset;
	# qemu_quit's monitor `quit` is a safe no-op if it's already gone.
	qemu_send $'reboot\r' 2>/dev/null || true
	local waited=0
	while kill -0 "$QEMU_PID" 2>/dev/null && [ "$waited" -lt 30 ]; do
		sleep 1; waited=$((waited + 1))
	done
	qemu_quit
}

pass=1
fail() { log "FAIL: $*"; echo "FAIL: $*" >> "$WORK_DIR/test-install-result.txt"; pass=0; }
: > "$WORK_DIR/test-install-result.txt"

# --- phase 1: install onto the scratch disk -------------------------------
log "=== phase 1/4: florainstall onto the scratch disk ==="
qemu_boot_serial install \
	-m 2048 -cdrom "$ISO" -boot d \
	-drive "file=$DISK_IMG,format=raw,if=ide" \
	-nographic -no-reboot -display none

if login_and_wait_shell; then
	qemu_send $'florainstall\r'
	if qemu_wait_for "FloraOS disk installer" 20; then
		# Item 0 ("Target disk") and the picker's one entry are both
		# already highlighted -- a bare Enter picks each.
		qemu_send $'\r'
		qemu_wait_for "Select target disk" 10 || fail "disk picker never appeared"
		qemu_send $'\r'

		# Down x3 reaches "Begin installation". vt100 sends ESC O B for down, not ESC [ B.
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

# --- phase 2: boot the installed disk directly, take a backup ------------
log "=== phase 2/4: first boot off the installed disk, take a backup ==="
qemu_boot_serial boot1 -m 1024 -drive "file=$DISK_IMG,format=raw,if=ide" -nographic -no-reboot -display none

if login_and_wait_shell; then
	if qemu_run 'cat /proc/cmdline' 15; then
		grep -q 'rootflags=subvol=@ ' "$QEMU_LOG" && log "subvolume layout confirmed (rootflags=subvol=@)" \
			|| fail "installed system's /proc/cmdline doesn't show rootflags=subvol=@"
	else
		fail "couldn't read /proc/cmdline on first disk boot"
	fi

	qemu_run_ok 'echo before-backup > /root/marker.txt' 10 \
		|| fail "couldn't write the pre-backup marker file"

	if qemu_run_ok "fau backup $SNAP_NAME" 30; then
		grep -q "backup '$SNAP_NAME' created" "$QEMU_LOG" && log "fau backup created $SNAP_NAME" \
			|| fail "fau backup exited 0 but didn't print its usual success message"
	else
		fail "fau backup didn't report success"
	fi

	if qemu_run "cat /boot/grub/grub.cfg" 10; then
		grep -q "backup: $SNAP_NAME" "$QEMU_LOG" && log "grub.cfg regenerated with the backup entry" \
			|| fail "grub.cfg wasn't regenerated with a $SNAP_NAME entry"
	else
		fail "couldn't read /boot/grub/grub.cfg"
	fi

	qemu_run_ok 'echo after-backup > /root/marker.txt' 10 \
		|| fail "couldn't overwrite the marker file after taking the backup"

	qemu_run_ok "grub-reboot \"$SNAP_TITLE\"" 10 \
		|| fail "grub-reboot into the backup entry failed"
else
	fail "couldn't log in on the first disk boot"
fi
end_phase

# --- phase 3: the one-shot boot into the snapshot -------------------------
log "=== phase 3/4: booting the backup once (grub-reboot), then fau backup-restore ==="
qemu_boot_serial boot2 -m 1024 -drive "file=$DISK_IMG,format=raw,if=ide" -nographic -no-reboot -display none

if login_and_wait_shell; then
	if qemu_run 'cat /proc/cmdline' 15; then
		grep -q "rootflags=subvol=@snapshots/$SNAP_NAME" "$QEMU_LOG" \
			&& log "booted the snapshot's own subvolume, as grub-reboot intended" \
			|| fail "second boot didn't land on rootflags=subvol=@snapshots/$SNAP_NAME"
	else
		fail "couldn't read /proc/cmdline on the snapshot boot"
	fi

	if qemu_run 'cat /root/marker.txt' 10; then
		grep -q 'before-backup' "$QEMU_LOG" \
			&& log "snapshot preserved the pre-backup marker file content" \
			|| fail "snapshot's marker.txt doesn't read 'before-backup' -- snapshot didn't preserve state"
	else
		fail "couldn't read the marker file on the snapshot boot"
	fi

	if qemu_run_ok "fau backup-restore $SNAP_NAME" 30; then
		grep -q "restored '$SNAP_NAME' to @" "$QEMU_LOG" && log "fau backup-restore promoted $SNAP_NAME" \
			|| fail "fau backup-restore exited 0 but didn't print its usual success message"
	else
		fail "fau backup-restore didn't report success"
	fi
else
	fail "couldn't log in on the snapshot boot"
fi
end_phase

# --- phase 4: normal reboot, confirm the promotion stuck ------------------
log "=== phase 4/4: normal boot after backup-restore ==="
qemu_boot_serial boot3 -m 1024 -drive "file=$DISK_IMG,format=raw,if=ide" -nographic -no-reboot -display none

if login_and_wait_shell; then
	if qemu_run 'cat /proc/cmdline' 15; then
		grep -q 'rootflags=subvol=@ ' "$QEMU_LOG" \
			&& log "post-restore default boot is rootflags=subvol=@ again" \
			|| fail "post-restore boot isn't rootflags=subvol=@"
	else
		fail "couldn't read /proc/cmdline on the post-restore boot"
	fi

	if qemu_run 'cat /root/marker.txt' 10; then
		grep -q 'before-backup' "$QEMU_LOG" \
			&& log "promoted @ still reads the pre-backup marker content -- restore stuck" \
			|| fail "promoted @ doesn't read 'before-backup' -- restore didn't actually stick"
	else
		fail "couldn't read the marker file on the post-restore boot"
	fi
else
	fail "couldn't log in on the post-restore boot"
fi
end_phase

# Written to a file, not just stdout -- see docs/ARCHITECTURE.md (captured
# stdout has been observed truncated across nested-backgrounded phases).
if [ "$pass" -eq 1 ]; then
	log "PASS -- florainstall + fau backup/backup-restore verified end-to-end (logs under $WORK_DIR/qemu-*.log)"
	echo "PASS" >> "$WORK_DIR/test-install-result.txt"
	exit 0
else
	log "FAIL -- see $WORK_DIR/qemu-*-boot.log for the failing phase's transcript"
	echo "FAIL" >> "$WORK_DIR/test-install-result.txt"
	exit 1
fi
