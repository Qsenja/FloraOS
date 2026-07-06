#!/usr/bin/env bash
# Boots the built FloraOS ISO in QEMU (serial console, no graphics) and
# checks for two markers in the boot log: the kernel actually starting, and
# the login shell actually being reached (see /etc/profile's PS1 -- a
# deliberate, unambiguous marker rather than guessing at bash's default
# prompt). Exits non-zero if either marker is missing within the timeout.
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
[ -f "$ISO" ] || die "no ISO at $ISO -- run floraiso build first"

log "booting $ISO in QEMU (up to ${TIMEOUT_SECS}s)"
rm -f "$BOOT_LOG"
timeout "$TIMEOUT_SECS" qemu-system-x86_64 \
	-m 1024 \
	-cdrom "$ISO" \
	-boot d \
	-nographic \
	-no-reboot \
	-serial "file:$BOOT_LOG" \
	-display none \
	>/dev/null 2>&1 || true

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
