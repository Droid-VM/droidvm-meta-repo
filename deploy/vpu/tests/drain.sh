#!/bin/bash
# VPU acceptance: reproduce defect D5 -- an m2m drain that never completes.
#
#   tests/drain.sh <name|id> [/dev/videoN]
#
# Feeds the m2m device ONE frame of 640x480 NV12 and asks v4l2-ctl for --stream-count=10. Having
# run out of input, v4l2-ctl issues V4L2_DEC_CMD_STOP and waits for a buffer flagged
# V4L2_BUF_FLAG_LAST. The host `loopback_device` never sends one, so the command hangs until it
# is killed (logs/vpu_wp/B2-acceptance.md §12 D5, F2-driver §6).
#
#   PASS -- the drain completed inside the timeout: D5 is fixed.
#   FAIL -- v4l2-ctl was still waiting when the timeout fired (rc 124): D5 reproduced.
#
# After the kill the device must still answer, so the test also runs `v4l2-ctl --info` at the end:
# B2 showed the device is not wedged by the hang, and a change that makes it wedged is worse than
# D5 itself.
DRAIN_TIMEOUT=${DRAIN_TIMEOUT:-60}
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
case "$DRAIN_TIMEOUT" in ''|*[!0-9]*) die "DRAIN_TIMEOUT must be a number of seconds (got '$DRAIN_TIMEOUT')" ;; esac

adb_wait
ADDR=$("$SP/vm.sh" wait-ssh "$NAME") || exit 1
echo "guest: $ADDR"

# Both interpolated values are validated above.
{ cat "$SP/tests/pick_device.sh"; cat <<'GUEST'
set -u
NV12=460800    # 640x480 NV12, one frame

if ! command -v v4l2-ctl >/dev/null 2>&1; then
    echo "FAIL: v4l2-ctl is missing -- run: guest.sh install-tools <name>"; exit 1
fi

dev=$DEV
if [ -z "$dev" ]; then
    echo "=== picking a device by capability ==="
    pick_devices
    dev=$loop
fi
[ -n "$dev" ] || { echo "FAIL: no m2m device to drain"; exit 1; }
[ -e "$dev" ] || { echo "FAIL: $dev does not exist"; exit 1; }
echo "device: $dev"

echo; echo "=== one frame in, --stream-count=10, ${TMO}s timeout ==="
rm -f /tmp/drain_in.raw /tmp/drain_out.raw
head -c "$NV12" /dev/urandom > /tmp/drain_in.raw
timeout "$TMO" v4l2-ctl -d "$dev" --stream-mmap --stream-out-mmap \
    --stream-from=/tmp/drain_in.raw --stream-to=/tmp/drain_out.raw --stream-count=10
rc=$?
echo "stream rc=$rc"
echo "output bytes: $(stat -c %s /tmp/drain_out.raw 2>/dev/null || echo 0)"

echo; echo "=== the device still answers after the drain ==="
if v4l2-ctl -d "$dev" --info >/dev/null 2>&1; then
    echo "v4l2-ctl --info: rc 0 -- the device is not wedged"
    wedged=0
else
    echo "FAIL: v4l2-ctl --info fails after the drain -- the device IS wedged"
    wedged=1
fi

echo
case "$rc" in
    0)   echo "drain: PASS -- the drain completed (D5 is fixed)" ;;
    124) echo "drain: FAIL -- v4l2-ctl was still waiting after ${TMO}s (D5 reproduced: no V4L2_BUF_FLAG_LAST for V4L2_DEC_CMD_STOP)" ;;
    *)   echo "drain: FAIL -- v4l2-ctl exited $rc, which is neither a completed drain nor the timeout" ;;
esac
[ "$rc" = 0 ] && [ "$wedged" = 0 ]
GUEST
} | "$SP/guest.sh" ssh "$NAME" "DEV='$DEV' TMO='$DRAIN_TIMEOUT' bash -s"
rc=$?
echo
if [ "$rc" = 0 ]; then echo "drain: PASS"; else echo "drain: FAIL (rc=$rc)"; fi
exit "$rc"
