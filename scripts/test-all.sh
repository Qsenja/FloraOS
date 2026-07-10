#!/usr/bin/env bash
# test-all.sh -- runs every scripts/test-*.sh test in one pass and prints a
# summary table. Always sequential, never parallel: two QEMU VMs competing
# for the same host's CPU/network caused real, reproducible failures this
# project hit directly (slirp networking inside a VM degrading badly under
# CPU contention from another heavy VM -- confirmed by watching real
# mirror-fetch retries fail 100% of the time under load, succeed instantly
# once the other VM finished). See docs/ARCHITECTURE.md's "Test harness"
# section for the qemu_* helpers every one of these tests shares.
set -uo pipefail
# Not `set -e`: one test failing must not abort the rest of the suite --
# the whole point of this script is a full report, not a first-failure exit.

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

ISO="$FLORA_ROOT/floraos.iso"
LOG_DIR="$WORK_DIR/test-all-logs"

# name:script:tier  -- tier is "fast" (default set, a few minutes total) or
# "slow" (opt-in via --all, tens of minutes -- a real kernel rebuild).
TESTS=(
	"iso:$SELF_DIR/test-iso.sh:fast"
	"install:$SELF_DIR/test-install.sh:fast"
	"install-uefi:$SELF_DIR/test-install-uefi.sh:fast"
	"kernel-update:$SELF_DIR/test-kernel-update.sh:slow"
)

usage() {
	cat <<'EOF'
usage: test-all.sh [--all] [--only NAME[,NAME...]] [--list]

  (no args)          run every "fast"-tier test (iso, install, install-uefi
                       -- a few minutes total)
  --all              also run "slow"-tier tests (kernel-update -- a real
                       kernel rebuild, tens of minutes, needs network)
  --only NAME[,...]  run just these tests by name, regardless of tier
  --list             print available test names and their tier, do nothing else

Always sequential -- see this script's own header comment for why.
Per-test full output is saved to work/test-all-logs/<name>.log.
EOF
}

list_tests() {
	local entry name script tier
	for entry in "${TESTS[@]}"; do
		IFS=: read -r name script tier <<<"$entry"
		printf '%-16s %-6s %s\n' "$name" "$tier" "$script"
	done
}

only_filter=""
run_slow=0
while [ $# -gt 0 ]; do
	case "$1" in
		--all) run_slow=1; shift ;;
		--only) only_filter=${2:?--only needs a NAME[,NAME...] argument}; shift 2 ;;
		--list) list_tests; exit 0 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1 (see --help)" ;;
	esac
done

[ -f "$ISO" ] || die "no ISO at $ISO -- run ./floraiso build first"
require_cmd qemu-system-x86_64
mkdir -p "$LOG_DIR"

# Resolve which tests actually run this pass.
selected=()
if [ -n "$only_filter" ]; then
	IFS=, read -r -a wanted <<<"$only_filter"
	for entry in "${TESTS[@]}"; do
		IFS=: read -r name script tier <<<"$entry"
		for w in "${wanted[@]}"; do
			[ "$w" = "$name" ] && selected+=("$entry")
		done
	done
	[ "${#selected[@]}" -gt 0 ] || die "--only matched nothing (see --list for valid names)"
else
	for entry in "${TESTS[@]}"; do
		IFS=: read -r name script tier <<<"$entry"
		if [ "$tier" = "fast" ] || [ "$run_slow" -eq 1 ]; then
			selected+=("$entry")
		fi
	done
fi

log "running ${#selected[@]} test(s): $(for e in "${selected[@]}"; do printf '%s ' "${e%%:*}"; done)"
[ "$run_slow" -eq 1 ] || log "slow-tier tests (kernel-update) skipped -- pass --all to include them"

names=() results=() durations=()
overall_pass=1

for entry in "${selected[@]}"; do
	IFS=: read -r name script _tier <<<"$entry"
	logfile="$LOG_DIR/$name.log"
	log "=== $name: starting (log: $logfile) ==="
	start=$(date +%s)
	if "$script" "$ISO" > "$logfile" 2>&1; then
		rc=0
	else
		rc=$?
	fi
	elapsed=$(( $(date +%s) - start ))
	names+=("$name")
	durations+=("$elapsed")
	if [ "$rc" -eq 0 ]; then
		results+=("PASS")
		log "=== $name: PASS (${elapsed}s) ==="
	else
		results+=("FAIL")
		overall_pass=0
		log "=== $name: FAIL (${elapsed}s, exit $rc) -- see $logfile ==="
	fi
done

echo
log "=== summary ==="
i=0
while [ "$i" -lt "${#names[@]}" ]; do
	printf '  %-16s %-4s (%ds)\n' "${names[$i]}" "${results[$i]}" "${durations[$i]}"
	i=$((i + 1))
done

if [ "$overall_pass" -eq 1 ]; then
	log "ALL PASS"
	exit 0
else
	log "FAIL -- see work/test-all-logs/<name>.log for the failing test(s)"
	exit 1
fi
