#!/bin/bash
# VPU acceptance: sysfs unbind under an open streaming session must not oops the guest (D66).
#
#   tests/unbind_rebind.sh [--rounds N] <name|id>
#
# Defect D66 (logs/vpu_wp/B12-acceptance.md §15): `echo virtioN > .../virtio_media/unbind` while
# a session held buffers faulted the guest kernel (level-3 translation fault in
# vmedia_dbuf_buffer_from_host from virtio_media_qbuf) and left the client an unreapable Zl
# zombie that survived the rebind. Fork commit 0a68d3a makes the unbind a DISCONNECT: the node
# disappears, the open handle's further ioctls answer -ENODEV, sleepers are woken, per-device
# memory lives until the last release(), and a rebind probes a fresh device.
#
# Each round (default 3, because the fault was a lifetime bug -- one clean pass proves little):
#   1. pick a streamable node BY CAPABILITY (tests/pick_device.sh, D8) and resolve its virtio
#      device name from sysfs -- re-done every round, the minor moves across rebinds (B12 §15)
#   2. start a long v4l2-ctl --stream-mmap in the background and let it queue buffers (2 s)
#   3. unbind the virtio device from virtio_media while that client streams
#   4. the client must EXIT NONZERO within 15 s -- not hang (D state) and not zombie (Z state);
#      after it is reaped no v4l2-ctl may linger in D or Z
#   5. dmesg must gain 0 new 'Unable to handle'/'Oops'/'Call trace'/'BUG' lines (the old driver
#      produced two splats during the unbind itself plus the qbuf oops)
#   6. rebind, wait for the node, and stream a fresh 30-frame capture -- the new device works
#
# The capture-only node just streams to /dev/null; the m2m (loopback) node streams through
# --stream-out-mmap from a 10-frame random NV12 file with --stream-loop, so the input never runs
# out under the client and the session cannot wander into D5's drain wait instead. Whichever
# exists is used (capture-only preferred: one queue, no input file); neither existing is a
# FAILURE, not a skip.
#
# Needs v4l-utils in the guest (guest.sh install-tools) and guest driver >= r22 to pass; on r21
# this test reproduces D66 and the GUEST WILL OOPS -- run it on a VM you can restart.
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

ROUNDS=3
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rounds) ROUNDS=${2:-}; shift 2 || usage ;;
        --rounds=*) ROUNDS=${1#--rounds=}; shift ;;
        -*) usage ;;
        *) break ;;
    esac
done
case "$ROUNDS" in ''|*[!0-9]*) die "--rounds takes a number (got '$ROUNDS')" ;; esac

NAME=${1:-}
[ -n "$NAME" ] || usage

adb_wait
ADDR=$("$SP/vm.sh" wait-ssh "$NAME") || exit 1
echo "guest: $ADDR"

# One guest-side script, one ssh round trip; the capability picker is prepended from its own
# file. ROUNDS is validated above, so interpolating it into the remote command line is safe.
{ cat "$SP/tests/pick_device.sh"; cat <<'GUEST'
set -u
fail=0
step() { echo; echo "=== $* ==="; }
bad()  { echo "FAIL: $*"; fail=$((fail+1)); }

NV12=460800     # 640x480 NV12, the loopback device's default format
RGB3=921600     # 640x480 RGB3, the simple device's only format
DRIVER=/sys/bus/virtio/drivers/virtio_media

splats() { dmesg | grep -cE 'Unable to handle|Internal error: Oops|Call trace:|BUG:'; }

# Wait up to $1 seconds for some /dev/video* node to answer --info; udev takes a moment after
# probe. Prints nothing; the caller re-picks by capability afterwards.
wait_node() {
    local t=0
    while [ "$t" -lt "$1" ]; do
        for d in /dev/video*; do
            [ -e "$d" ] || continue
            v4l2-ctl -d "$d" --info >/dev/null 2>&1 && return 0
        done
        sleep 1; t=$((t+1))
    done
    return 1
}

command -v v4l2-ctl >/dev/null 2>&1 || { bad "v4l2-ctl is missing -- run: guest.sh install-tools <name>"; echo "failures: $fail"; exit 1; }
lsmod | grep -q virtio_media || { bad "virtio_media is not loaded"; echo "failures: $fail"; exit 1; }

round=1
while [ "$round" -le "$ROUNDS" ]; do
    step "round $round of $ROUNDS: pick a device"
    pick_devices
    dev=${simple:-$loop}
    if [ -z "$dev" ]; then bad "round $round: no streamable virtio-media node"; break; fi
    # /sys/class/video4linux/videoN/device is the virtioX platform device this node hangs off.
    virtio=$(basename "$(readlink -f "/sys/class/video4linux/$(basename "$dev")/device")")
    case "$virtio" in virtio*) ;; *) bad "round $round: $dev resolves to '$virtio', not a virtio device"; break ;; esac
    [ -e "$DRIVER/$virtio" ] || { bad "round $round: $virtio is not bound to virtio_media"; break; }
    echo "device $dev on $virtio"

    step "round $round: stream in the background, then unbind $virtio"
    before=$(splats)
    rm -f /tmp/ur_bg.log
    if [ -n "$simple" ]; then
        v4l2-ctl -d "$dev" --stream-mmap --stream-count=100000 \
                 --stream-to=/dev/null >/tmp/ur_bg.log 2>&1 &
    else
        # m2m: --stream-loop keeps refilling from the 10-frame file, so the input cannot run
        # out before the unbind (a loopback chews 200 plain frames in under the 2 s settle).
        head -c "$((10 * NV12))" /dev/urandom > /tmp/ur_in.raw
        v4l2-ctl -d "$dev" --stream-mmap --stream-out-mmap --stream-count=100000 --stream-loop \
                 --stream-from=/tmp/ur_in.raw --stream-to=/dev/null >/tmp/ur_bg.log 2>&1 &
    fi
    pid=$!
    sleep 2
    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid"; bad "round $round: client died before the unbind (rc $?):"
        cat /tmp/ur_bg.log; round=$((round+1)); continue
    fi
    echo "$virtio" > "$DRIVER/unbind" || bad "round $round: the unbind write itself failed"

    # 4. the client must exit, nonzero, within 15 s -- D66 left it in Z forever.
    t=0; while kill -0 "$pid" 2>/dev/null && [ "$t" -lt 15 ]; do sleep 1; t=$((t+1)); done
    if kill -0 "$pid" 2>/dev/null; then
        st=$(ps -o stat= -p "$pid" 2>/dev/null)
        bad "round $round: client (pid $pid, state '${st:-?}') still alive 15 s after the unbind"
        kill -9 "$pid" 2>/dev/null
    else
        wait "$pid"; rc=$?
        echo "client exit rc=$rc after the unbind"
        [ "$rc" != 0 ] || bad "round $round: client exited 0 -- it should have died on -ENODEV"
        tail -2 /tmp/ur_bg.log
    fi
    left=$(ps axo stat=,comm= | awk '$1 ~ /^[DZ]/ && $2 ~ /v4l2-ctl/')
    [ -z "$left" ] || bad "round $round: v4l2-ctl left in D/Z state after the unbind: $left"

    # 5. zero new splats. dmesg counts, not markers: the B12 ring wrapped under load, but this
    # test writes almost nothing, so before <= after and the difference is the new splats.
    after=$(splats)
    echo "kernel splats: $before before, $after after"
    if [ "$after" -gt "$before" ]; then
        bad "round $round: $((after - before)) new kernel splat line(s) -- dmesg | tail -60:"
        dmesg | tail -60
    fi

    step "round $round: rebind $virtio and stream 30 fresh frames"
    echo "$virtio" > "$DRIVER/bind" || bad "round $round: the bind write failed"
    wait_node 20 || bad "round $round: no answering /dev/video* node 20 s after the rebind"
    pick_devices
    dev=${simple:-$loop}
    if [ -z "$dev" ]; then
        bad "round $round: no streamable node after the rebind"
    elif [ -n "$simple" ]; then
        if v4l2-ctl -d "$dev" --stream-mmap --stream-count=30 --stream-to=/tmp/ur_cap.raw; then
            n=$(stat -c %s /tmp/ur_cap.raw 2>/dev/null || echo 0)
            echo "captured bytes: $n (want $((30 * RGB3)))"
            [ "$n" = "$((30 * RGB3))" ] || bad "round $round: post-rebind capture wrote $n bytes, want $((30 * RGB3))"
        else
            bad "round $round: post-rebind capture failed"
        fi
    else
        head -c "$((30 * NV12))" /dev/urandom > /tmp/ur_in.raw
        if timeout 120 v4l2-ctl -d "$dev" --stream-mmap --stream-out-mmap --stream-count=30 \
                     --stream-from=/tmp/ur_in.raw --stream-to=/tmp/ur_cap.raw; then
            n=$(stat -c %s /tmp/ur_cap.raw 2>/dev/null || echo 0)
            echo "captured bytes: $n (need at least $NV12)"
            [ "$n" -ge "$NV12" ] || bad "round $round: post-rebind loopback wrote $n bytes, less than one frame"
        else
            bad "round $round: post-rebind loopback failed (rc $?; 124 is the 120 s timeout)"
        fi
    fi
    round=$((round+1))
done

step "dmesg tail"
dmesg | grep -iE 'virtio[-_]media|Unable to handle|Oops|Call trace|BUG' | tail -40

echo; echo "failures: $fail"
[ "$fail" = 0 ]
GUEST
} | "$SP/guest.sh" ssh "$NAME" "ROUNDS='$ROUNDS' bash -s"
rc=$?
echo
if [ "$rc" = 0 ]; then echo "unbind_rebind: PASS"; else echo "unbind_rebind: FAIL (rc=$rc)"; fi
exit "$rc"
