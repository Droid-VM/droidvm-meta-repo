#!/bin/bash
# VPU acceptance: run v4l2-compliance's streaming suite against a guest media device.
#
#   tests/compliance.sh <name|id> [/dev/videoN]
#
# Without a device it picks the m2m node by capability (tests/pick_device.sh, defect D8) and
# falls back to the capture-only node when there is no m2m one. In the guest it runs
#
#   v4l2-compliance -d <dev> -s
#
# installing v4l-utils first if `v4l2-compliance` is not on PATH, then prints the "Total for"
# line and every failed subtest, and exits non-zero if anything failed.
#
# This is the test for defect D6 (logs/vpu_wp/B2-acceptance.md §12): the loopback device fails
# 11 of 59 subtests, 8 of them cascading from an unimplemented VIDIOC_PREPARE_BUF. Recorded
# baseline on the B2 build, crosvm 22d14c5 / fork 2ae6bc0: `59, Succeeded: 48, Failed: 11`.
# So a non-zero exit is expected until the host-side fix lands -- read the totals, do not just
# look at the exit code.
#
# -s is the streaming suite (the whole point); it takes ~40 s and needs no restart afterwards.
set -u
SP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib.sh
. "$SP/lib.sh"

USAGE_RC=2
usage() {  # print the file's own header comment, up to the first line of code
    awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"
    exit "$USAGE_RC"
}

NAME=${1:-}
DEV=${2:-}
[ -n "$NAME" ] || usage
case "$DEV" in ""|/dev/video[0-9]*) ;; *) die "second argument must be a /dev/videoN node (got '$DEV')" ;; esac

adb_wait
ADDR=$("$SP/vm.sh" wait-ssh "$NAME") || exit 1
echo "guest: $ADDR"

# DEV is checked against /dev/videoN above, so interpolating it is safe.
{ cat "$SP/tests/pick_device.sh"; cat <<'GUEST'
set -u

if ! command -v v4l2-compliance >/dev/null 2>&1; then
    echo "=== installing v4l-utils (v4l2-compliance is missing) ==="
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y v4l-utils || { apt-get update && apt-get install -y v4l-utils; } || {
        echo "FAIL: could not install v4l-utils"; exit 1; }
fi
v4l2-compliance --version 2>&1 | head -1

dev=$DEV
if [ -z "$dev" ]; then
    echo; echo "=== picking a device by capability ==="
    pick_devices
    dev=${loop:-$simple}
fi
[ -n "$dev" ] || { echo "FAIL: no V4L2 device to test"; exit 1; }
[ -e "$dev" ] || { echo "FAIL: $dev does not exist"; exit 1; }
echo "device: $dev"

echo; echo "=== v4l2-compliance -d $dev -s ==="
out=/tmp/compliance.txt
timeout 300 v4l2-compliance -d "$dev" -s > "$out" 2>&1
rc=$?
tail -5 "$out"

echo; echo "=== failed subtests ==="
grep -n 'FAIL' "$out" || echo "(none)"

echo; echo "=== totals ==="
grep 'Total for' "$out" || echo "(no 'Total for' line -- v4l2-compliance did not finish; rc=$rc)"

# v4l2-compliance exits non-zero on any failure, and 124 if the timeout above killed it.
echo; echo "v4l2-compliance rc: $rc"
[ "$rc" = 0 ]
GUEST
} | "$SP/guest.sh" ssh "$NAME" "DEV='$DEV' bash -s"
rc=$?
echo
if [ "$rc" = 0 ]; then echo "compliance: PASS"; else echo "compliance: FAIL (rc=$rc) -- see the totals above"; fi
exit "$rc"
