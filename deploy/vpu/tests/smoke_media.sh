#!/bin/bash
# VPU acceptance smoke test: does the guest actually have a working virtio-media device?
#
#   tests/smoke_media.sh <name|id>
#
# Waits for ssh, then in the guest:
#   1. lsmod | grep virtio_media          -- the driver is loaded
#   2. ls -l /dev/video*                  -- at least one V4L2 node exists
#   3. dmesg | grep -i virtio[-_]media    -- the driver said something
#   4. v4l2-ctl -d <each node> --all      -- first 40 lines per node
#   5. card "simple_device": --stream-mmap --stream-count=30 --stream-to=/tmp/simple.raw,
#      then the byte count of that file (crosvm's --simple-media-device fixed pattern source)
#   6. card "loopback":      --stream-mmap --stream-out-mmap --stream-count=10
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

NAME=${1:-}
[ -n "$NAME" ] || usage

adb_wait
ADDR=$("$SP/vm.sh" wait-ssh "$NAME") || exit 1
echo "guest: $ADDR"

# One guest-side script, one ssh round trip: every step records its own pass/fail into $fail so
# a late failure cannot hide behind an early one.
"$SP/guest.sh" ssh "$NAME" 'bash -s' <<'GUEST'
set -u
fail=0
step() { echo; echo "=== $* ==="; }
bad()  { echo "FAIL: $*"; fail=$((fail+1)); }

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
        echo "captured bytes: $n"
        [ "$n" -gt 0 ] || bad "stream-to wrote 0 bytes"
    else
        bad "capture from $simple failed"
    fi
else
    step "5. skipped -- no device with card 'simple_device'"
fi

if [ -n "$loop" ]; then
    step "6. loopback 10 frames through $loop"
    if v4l2-ctl -d "$loop" --stream-mmap --stream-out-mmap --stream-count=10; then :;
    else bad "loopback stream on $loop failed"; fi
else
    step "6. skipped -- no device with card 'loopback'"
fi

echo; echo "failures: $fail"
[ "$fail" = 0 ]
GUEST
rc=$?
echo
if [ "$rc" = 0 ]; then echo "smoke_media: PASS"; else echo "smoke_media: FAIL (rc=$rc)"; fi
exit "$rc"
