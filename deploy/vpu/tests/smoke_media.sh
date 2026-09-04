#!/bin/bash
# VPU acceptance smoke test: does the guest actually have a working virtio-media device?
#
#   tests/smoke_media.sh [--mode output|none|all] <name|id>
#
# Waits for ssh, then in the guest:
#   0. --mode <m>                         -- reload the driver with driver_owned_queues=<m>
#                                            (and pool_debug=1) before anything else; without
#                                            --mode the module is left exactly as it is
#   1. lsmod | grep virtio_media          -- the driver is loaded
#   2. ls -l /dev/video*                  -- at least one V4L2 node exists
#   3. dmesg | grep -i virtio[-_]media    -- the driver said something
#   4. v4l2-ctl -d <each node> --all      -- first 40 lines per node
#   5. card "simple_device": --stream-mmap --stream-count=30 --stream-to=/tmp/simple.raw, then
#      exactly 30 x 921600 bytes (640x480 RGB3) and at least two frames that differ -- the
#      device paints a changing uniform colour, so 30 identical frames means nothing arrived
#   6. card "loopback": 460800 random bytes (640x480 NV12) in through --stream-from,
#      --stream-to out, and `cmp` on the first frame. This is the only step that proves bytes
#      cross the queues rather than that an ioctl returned 0
#   7. dmesg | grep -i virtio[-_]media    -- again, so the run's own pool_debug lines are visible
#
# Exits non-zero if any step fails. Steps 5 and 6 are skipped, not failed, when no device
# advertises that card name -- which of the two exists depends on how crosvm was launched.
#
# Needs v4l-utils in the guest: run `guest.sh install-tools <name>` once first.
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

MODE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode) MODE=${2:-}; shift 2 || usage ;;
        --mode=*) MODE=${1#--mode=}; shift ;;
        -*) usage ;;
        *) break ;;
    esac
done
case "$MODE" in ""|output|none|all) ;; *) die "--mode takes output, none or all (got '$MODE')" ;; esac

NAME=${1:-}
[ -n "$NAME" ] || usage

adb_wait
ADDR=$("$SP/vm.sh" wait-ssh "$NAME") || exit 1
echo "guest: $ADDR"

# One guest-side script, one ssh round trip: every step records its own pass/fail into $fail so
# a late failure cannot hide behind an early one. MODE is validated above, so interpolating it
# into the remote command line is safe.
"$SP/guest.sh" ssh "$NAME" "MODE='$MODE' bash -s" <<'GUEST'
set -u
fail=0
step() { echo; echo "=== $* ==="; }
bad()  { echo "FAIL: $*"; fail=$((fail+1)); }

NV12=460800    # 640x480 NV12, the loopback device's default format
RGB3=921600    # 640x480 RGB3, the simple device's only format

if [ -n "$MODE" ]; then
    step "0. reload virtio-media with driver_owned_queues=$MODE pool_debug=1"
    # Reloading is safe here and only here: this is the guest VM, never the phone.
    if modprobe -r virtio-media && modprobe virtio-media "driver_owned_queues=$MODE" pool_debug=1; then
        cat /sys/module/virtio_media/parameters/driver_owned_queues 2>/dev/null
        sleep 1   # let udev create the nodes again
    else
        bad "reloading virtio-media with driver_owned_queues=$MODE failed"
    fi
fi

step "1. virtio_media module"
if lsmod | grep virtio_media; then :; else bad "virtio_media is not in lsmod"; fi

step "2. V4L2 nodes"
if ls -l /dev/video* 2>/dev/null; then :; else bad "no /dev/video* node"; fi

step "3. dmesg"
if dmesg | grep -i 'virtio[-_]media'; then :; else bad "dmesg says nothing about virtio-media"; fi

if ! command -v v4l2-ctl >/dev/null 2>&1; then
    bad "v4l2-ctl is missing -- run: guest.sh install-tools <name>"
    echo; echo "failures: $fail"; exit 1
fi

simple=""; loop=""
for dev in /dev/video*; do
    [ -e "$dev" ] || continue
    step "4. v4l2-ctl -d $dev --all (first 40 lines)"
    if ! v4l2-ctl -d "$dev" --all 2>&1 | head -40; then bad "v4l2-ctl --all failed on $dev"; fi
    card=$(v4l2-ctl -d "$dev" --info 2>/dev/null | sed -n 's/^[[:space:]]*Card type[[:space:]]*:[[:space:]]*//p')
    echo "card: ${card:-<none>}"
    case "$card" in
        *simple_device*) [ -n "$simple" ] || simple=$dev ;;
        *loopback*)      [ -n "$loop" ]   || loop=$dev ;;
    esac
done

if [ -n "$simple" ]; then
    step "5. capture 30 frames from $simple (simple_device)"
    rm -f /tmp/simple.raw
    if v4l2-ctl -d "$simple" --stream-mmap --stream-count=30 --stream-to=/tmp/simple.raw; then
        n=$(stat -c %s /tmp/simple.raw 2>/dev/null || echo 0)
        want=$((30 * RGB3))
        echo "captured bytes: $n (want $want = 30 x $RGB3)"
        if [ "$n" != "$want" ]; then
            bad "stream-to wrote $n bytes, expected $want"
        else
            # The device paints each frame a different uniform colour, so all-identical frames
            # mean the guest saw one buffer over and over (or zeroes).
            distinct=$(i=0; while [ "$i" -lt 30 ]; do
                           dd if=/tmp/simple.raw bs="$RGB3" skip="$i" count=1 status=none | md5sum
                           i=$((i+1))
                       done | sort -u | wc -l)
            echo "distinct frames: $distinct"
            [ "$distinct" -ge 2 ] || bad "all 30 frames are byte-identical"
        fi
    else
        bad "capture from $simple failed"
    fi
else
    step "5. skipped -- no device with card 'simple_device'"
fi

if [ -n "$loop" ]; then
    step "6. loopback 10 frames through $loop, comparing bytes"
    rm -f /tmp/lb_in.raw /tmp/lb_out.raw
    head -c "$NV12" /dev/urandom > /tmp/lb_in.raw
    v4l2-ctl -d "$loop" --get-fmt-video --get-fmt-video-out 2>&1 | sed -n '1,12p'
    if v4l2-ctl -d "$loop" --stream-mmap --stream-out-mmap \
                --stream-from=/tmp/lb_in.raw --stream-to=/tmp/lb_out.raw --stream-count=10; then
        n=$(stat -c %s /tmp/lb_out.raw 2>/dev/null || echo 0)
        echo "captured bytes: $n (need at least $NV12)"
        if [ "$n" -lt "$NV12" ]; then
            bad "loopback wrote $n bytes, less than one $NV12-byte frame"
        elif cmp -n "$NV12" /tmp/lb_in.raw /tmp/lb_out.raw; then
            echo "first frame matches the input byte for byte"
        else
            bad "loopback output differs from the input in the first $NV12 bytes"
        fi
    else
        bad "loopback stream on $loop failed"
    fi
else
    step "6. skipped -- no device with card 'loopback'"
fi

step "7. dmesg after the run"
dmesg | grep -i 'virtio[-_]media' | tail -60

echo; echo "failures: $fail"
[ "$fail" = 0 ]
GUEST
rc=$?
echo
if [ "$rc" = 0 ]; then echo "smoke_media: PASS"; else echo "smoke_media: FAIL (rc=$rc)"; fi
exit "$rc"
