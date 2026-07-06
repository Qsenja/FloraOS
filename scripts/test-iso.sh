#!/usr/bin/env bash
# Boots the built FloraOS ISO in QEMU (serial console, no graphics) and
# checks for two markers in the boot log: the kernel actually starting, and
# the login shell actually being reached (see /etc/profile's PS1 -- a
# deliberate, unambiguous marker rather than guessing at bash's default
# prompt). Since floralogin now gates the console, this also drives the
# actual login (root, empty password -- see /etc/issue) through the serial
# socket rather than just watching output; the shell marker only appears if
# that login genuinely succeeds. Exits non-zero if either marker is missing
# within the timeout.
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

# floralogin now gates the console (see ARCHITECTURE.md/apply-skeleton.sh)
# -- a plain read-only `-serial file:` redirect (the old approach) can watch
# boot output but can't answer the login prompt, so the shell would never
# actually be reached by this automated test anymore. A Unix-socket serial
# device lets `socat` do both: feed the documented root/empty-password
# login (see /etc/issue) and capture everything QEMU writes, in one stream.
SERIAL_SOCK="$WORK_DIR/qemu-serial.sock"
INPUT_FIFO="$WORK_DIR/qemu-serial-input.fifo"
rm -f "$SERIAL_SOCK" "$INPUT_FIFO" "$BOOT_LOG"
mkfifo "$INPUT_FIFO"

log "booting $ISO in QEMU (up to ${TIMEOUT_SECS}s)"
timeout "$TIMEOUT_SECS" qemu-system-x86_64 \
	-m 1024 \
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
# fd 9 holds the fifo open for the whole test -- opened read-write (<>),
# not write-only (>): a plain write-only open() on a fifo blocks until some
# reader also has it open, but socat (the intended reader) only starts on
# the next line, so opening write-only here first would deadlock the
# script against itself. <> is the standard trick to open a fifo without
# waiting for a peer. It also then holds the fifo open for the whole test --
# a fifo's read end otherwise sees EOF the instant any single write
# completes, which would end the socat session after the first thing sent.
exec 9<>"$INPUT_FIFO"
if [ -S "$SERIAL_SOCK" ]; then
	# "-" (stdio), not the fifo path, as socat's own address: giving it the
	# fifo path directly as one of its two endpoints makes socat copy the
	# socket's OUTPUT back into that same fifo too (a fifo is one shared
	# queue, not two independent lanes), so the boot log never actually
	# received the socket's data and the whole thing looked hung (found by
	# testing this exact construct in isolation before touching the real
	# script). Redirecting stdin from the fifo and stdout to BOOT_LOG keeps
	# the two directions properly separate.
	socat -T"$TIMEOUT_SECS" - "UNIX-CONNECT:$SERIAL_SOCK" < "$INPUT_FIFO" > "$BOOT_LOG" 2>&1 &
	SOCAT_PID=$!

	# agetty flushes whatever arrived on the line before it actually starts
	# prompting (reproduced directly: sending the login+password blindly
	# right after QEMU starts, well before boot reaches the prompt, got
	# silently discarded and the login never happened) -- wait for each
	# actual prompt string to show up in the growing log before answering
	# it, instead of guessing at timing.
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
