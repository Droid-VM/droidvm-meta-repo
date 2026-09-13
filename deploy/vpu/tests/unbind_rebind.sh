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
#   4. the client must STOP within 15 s and its OUTPUT must name -ENODEV -- not hang (D state)
#      and not zombie (Z state); after it is reaped no v4l2-ctl may linger in D or Z
#   5. dmesg must gain 0 new 'Unable to handle'/'Oops'/'Call trace'/'BUG' lines (the old driver
#      produced two splats during the unbind itself plus the qbuf oops)
#   6. rebind, wait for the node, and stream a fresh 30-frame capture -- the new device works
#
# The capture-only node just streams to /dev/null; the m2m (loopback) node streams through
# --stream-out-mmap from a 10-frame random file with --stream-loop, so the input never runs out
# under the client and the session cannot wander into D5's drain wait instead. Whichever exists
# is used (capture-only preferred: one queue, no input file); neither existing is a FAILURE, not
# a skip.
#
# Defect D75 (logs/vpu_wp/B14-accept-B.md §1.2): this test was written against the synthetic
# `--virtio-media kind=simple` device and carried two of its assumptions into a run against a
# real camera, where it reported 6 failures over 3 rounds while every criterion above was met.
# Both are fixed here:
#
#   * step 4 asserted `rc != 0`. v4l-utils 1.32.0's streaming loop PRINTS the ioctl error and
#     RETURNS -- `v4l2-ctl --stream-mmap` exits 0 on its own ENODEV path, measured directly, so
#     that assertion can never pass with this client. The symptom is what proves the disconnect,
#     so the check is now on the client's captured output: it must name 'No such device' (or
#     ENODEV/POLLERR) and the process must be gone inside the window. The exit code is printed
#     for the record and judged only when it is nonzero without an error line.
#   * step 6 compared the capture against a hard-coded 640x480 RGB3 frame (921600 B), the
#     synthetic device's only format. The camera's default is 1280x720 NV12, so a CORRECT
#     41 472 000 B capture was reported as a failure. The wanted size now comes from the node's
#     own `v4l2-ctl --get-fmt-video` (all planes' `Size Image` added up), so the check follows
#     whatever format the rebound device came up in -- NV12, RGB3 or anything else -- and the
#     m2m input file is sized from `--get-fmt-video-out` the same way. No frame size is hard
#     coded any more.
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

DRIVER=/sys/bus/virtio/drivers/virtio_media

splats() { dmesg | grep -cE 'Unable to handle|Internal error: Oops|Call trace:|BUG:'; }

# Bytes v4l2-ctl reads or writes per frame on one queue of a node, from the node's OWN format:
# every plane's `Size Image` added up, which is exactly what --stream-to writes and
# --stream-from is consumed in. Single-planar formats print one such line, multi-planar one per
# plane, so the sum is right for both. Prints 0 when the node cannot be queried (D75).
#   frame_bytes /dev/videoN --get-fmt-video      -- the CAPTURE side
#   frame_bytes /dev/videoN --get-fmt-video-out  -- the OUTPUT side of an m2m node
frame_bytes() {
    v4l2-ctl -d "$1" "$2" 2>/dev/null | awk -F: '
        /Size Image/ { gsub(/[^0-9]/, "", $2); if ($2 != "") total += $2 }
        END          { print total + 0 }'
}

# What the client's own output says happened to it. The unbind must show up there as -ENODEV --
# v4l2-ctl prints `VIDIOC_DQBUF: failed: No such device`, ffmpeg `Terminating thread with return
# code -19 (No such device)` and `capture POLLERR` -- because the exit code does not (D75).
said_enodev() { grep -qE 'No such device|ENODEV|POLLERR' "$1"; }

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
        # The frame size is the node's own OUTPUT sizeimage, not a constant (D75).
        out=$(frame_bytes "$dev" --get-fmt-video-out)
        [ "$out" -gt 0 ] || { bad "round $round: no OUTPUT format from $dev"; break; }
        head -c "$((10 * out))" /dev/urandom > /tmp/ur_in.raw
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
        # NOT `[ "$rc" != 0 ]`: v4l2-ctl exits 0 on its own ENODEV path (D75). What proves the
        # disconnect is the error the client printed before it stopped.
        if said_enodev /tmp/ur_bg.log; then
            echo "client stopped on -ENODEV, as the disconnect requires"
        else
            bad "round $round: client stopped (rc $rc) with no -ENODEV in its output:"
        fi
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
        # The wanted size is the REBOUND node's own format, whatever it came up in (D75).
        cap=$(frame_bytes "$dev" --get-fmt-video)
        echo "post-rebind capture format: $cap bytes/frame"
        if [ "$cap" -le 0 ]; then
            bad "round $round: no CAPTURE format from $dev after the rebind"
        elif v4l2-ctl -d "$dev" --stream-mmap --stream-count=30 --stream-to=/tmp/ur_cap.raw; then
            n=$(stat -c %s /tmp/ur_cap.raw 2>/dev/null || echo 0)
            echo "captured bytes: $n (want $((30 * cap)))"
            [ "$n" = "$((30 * cap))" ] || bad "round $round: post-rebind capture wrote $n bytes, want $((30 * cap))"
        else
            bad "round $round: post-rebind capture failed"
        fi
    else
        cap=$(frame_bytes "$dev" --get-fmt-video)
        out=$(frame_bytes "$dev" --get-fmt-video-out)
        echo "post-rebind m2m format: in $out, out $cap bytes/frame"
        if [ "$cap" -le 0 ] || [ "$out" -le 0 ]; then
            bad "round $round: no m2m format from $dev after the rebind (in $out, out $cap)"
        else
            head -c "$((30 * out))" /dev/urandom > /tmp/ur_in.raw
            if timeout 120 v4l2-ctl -d "$dev" --stream-mmap --stream-out-mmap --stream-count=30 \
                         --stream-from=/tmp/ur_in.raw --stream-to=/tmp/ur_cap.raw; then
                n=$(stat -c %s /tmp/ur_cap.raw 2>/dev/null || echo 0)
                echo "captured bytes: $n (need at least $cap)"
                [ "$n" -ge "$cap" ] || bad "round $round: post-rebind loopback wrote $n bytes, less than one frame"
            else
                bad "round $round: post-rebind loopback failed (rc $?; 124 is the 120 s timeout)"
            fi
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
