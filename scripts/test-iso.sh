#!/usr/bin/env bash
# Boots the built FloraOS ISO in QEMU and checks for two markers in the boot
# log: the kernel starting, and the login shell being reached. Drives the
# actual root/empty-password login over the serial socket to get there --
# see docs/ARCHITECTURE.md's "Test harness" section for the fifo/socat
# synchronization details this shares with scripts/lib/common.sh's qemu_*.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

FLORAOS_CONF="$FLORA_ROOT/config/floraos.conf"
# shellcheck source=/dev/null
[ -f "$FLORAOS_CONF" ] && source "$FLORAOS_CONF"

ISO="${1:-$FLORA_ROOT/${ISO_NAME:-floraos.iso}}"
TIMEOUT_SECS="${TEST_ISO_TIMEOUT:-90}"
BOOT_LOG="$WORK_DIR/qemu-boot.log"

require_cmd qemu-system-x86_64
require_cmd timeout
require_cmd socat
[ -f "$ISO" ] || die "no ISO at $ISO -- run floraiso build first"

SERIAL_SOCK="$WORK_DIR/qemu-serial.sock"
INPUT_FIFO="$WORK_DIR/qemu-serial-input.fifo"
rm -f "$SERIAL_SOCK" "$INPUT_FIFO" "$BOOT_LOG"
mkfifo "$INPUT_FIFO"

log "booting $ISO in QEMU (up to ${TIMEOUT_SECS}s)"
# -m 2048, not 1024: see docs/ARCHITECTURE.md (a real out-of-disk-space boot
# failure under `fau install`, even though this test itself only checks login).
timeout "$TIMEOUT_SECS" qemu-system-x86_64 \
	-m 2048 \
	-cdrom "$ISO" \
	-boot d \
	-nographic \
	-no-reboot \
	-serial "unix:$SERIAL_SOCK,server,nowait" \
	-display none \
	>/dev/null 2>&1 &
QEMU_PID=$!

for _ in $(seq 1 100); do
	[ -S "$SERIAL_SOCK" ] && break
	sleep 0.1
done

SOCAT_PID=""
# <> not >: write-only open() would deadlock waiting for socat's reader
# (see docs/ARCHITECTURE.md's "Test harness" section).
exec 9<>"$INPUT_FIFO"
if [ -S "$SERIAL_SOCK" ]; then
	# socat's address must be "-" (stdio), NOT the fifo path -- see ARCHITECTURE.md.
	socat -T"$TIMEOUT_SECS" - "UNIX-CONNECT:$SERIAL_SOCK" < "$INPUT_FIFO" > "$BOOT_LOG" 2>&1 &
	SOCAT_PID=$!

	wait_for() {
		local marker=$1 deadline=$(( $(date +%s) + TIMEOUT_SECS ))
		while [ "$(date +%s)" -lt "$deadline" ]; do
			grep -q "$marker" "$BOOT_LOG" 2>/dev/null && return 0
			sleep 0.3
		done
		return 1
	}

	# \r, not \n: a real terminal sends carriage return on Enter; the tty
	# line discipline's ICRNL translates it to \n for floralogin's fgets.
	if wait_for "floraos login:"; then
		printf 'root\r' >&9
		wait_for "Password:" && printf '\r' >&9
	fi
fi

wait "$QEMU_PID" 2>/dev/null || true
exec 9>&-
[ -n "$SOCAT_PID" ] && kill "$SOCAT_PID" 2>/dev/null || true
rm -f "$SERIAL_SOCK" "$INPUT_FIFO"

[ -f "$BOOT_LOG" ] || die "qemu produced no boot log at all -- it likely failed to start"

kernel_ok=0
shell_ok=0
grep -q "Linux version ${KERNEL_VERSION:-}" "$BOOT_LOG" 2>/dev/null && kernel_ok=1
grep -q "floraos-boot-ok" "$BOOT_LOG" 2>/dev/null && shell_ok=1

log "kernel booted: $([ $kernel_ok -eq 1 ] && echo yes || echo no)"
log "reached login shell: $([ $shell_ok -eq 1 ] && echo yes || echo no)"

if [ $kernel_ok -eq 1 ] && [ $shell_ok -eq 1 ]; then
	log "PASS -- see $BOOT_LOG for the full boot transcript"
	exit 0
else
	log "FAIL -- see $BOOT_LOG for the full boot transcript"
	exit 1
fi
