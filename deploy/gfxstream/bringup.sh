#!/bin/bash
# Re-establish the phone-side test environment after a reboot. Runtime state only --
# nothing here writes a persistent setting. Every wait is bounded.
set -u
DEV=172.22.74.2:5568
A="adb -s $DEV shell"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="$(cd "$(dirname "$0")" && pwd)"
MODS=/data/data/cn.classfun.droidvm/usr/lib/modules/android15-6.6

step() { echo "--- $* ---"; }

step "wait for adb (max 120s)"
ok=no
for i in $(seq 1 24); do
    if adb -s $DEV shell true >/dev/null 2>&1; then ok=yes; break; fi
    sleep 5
done
[ "$ok" = yes ] || { echo "adb 沒回來"; exit 1; }
$A 'uptime' 2>/dev/null | tr -d '\r'

step "kernel modules"
$A "su -c 'insmod $MODS/gh-unmovable-gki-6.6.ko; insmod $MODS/gunyah-host-share-gki-6.6.ko; lsmod | grep -cE \"unmovable|host_share\"'" 2>/dev/null | tr -d '\r'

step "qvirtservice keeper (runtime only, self-expires in 45 min)"
if ! $A 'su -c "ps -A -o args | grep -c \"[c]tl.stop vendor.qvirtservice\""' 2>/dev/null | grep -qv '^0'; then
    $A 'su -c "setsid sh -c \"i=0; while [ \\\$i -lt 1350 ]; do setprop ctl.stop vendor.qvirtservice_rs; sleep 2; i=\\\$((i+1)); done\" >/dev/null 2>&1 &"' 2>/dev/null
fi

step "br-wifi via app"
if ! $A 'su -c "ip link show br-wifi"' 2>/dev/null | grep -q br-wifi; then
    $A 'am start -n cn.classfun.droidvm/.ui.SplashActivity' >/dev/null 2>&1
    for i in $(seq 1 15); do
        sleep 4
        $A 'su -c "ip link show br-wifi"' 2>/dev/null | grep -q br-wifi && break
    done
fi
$A 'su -c "ip -br link | grep br-wifi"' 2>/dev/null | tr -d '\r'

step "binaries (push + md5 verify -- a hard reset zeroes recently written files)"
# libvirglrenderer.so is DT_NEEDED by the crosvm binary, so a stale one on the phone is not a
# kgsl-only problem: crosvm fails at exec and ALL FIVE configurations die. Verify it alongside
# the other two even when the run under test is gfxstream.
for f in crosvm libgfxstream_backend.so libvirglrenderer.so; do
    want=$(md5sum "$REPO/crosvm_out/$f" | awk '{print $1}')
    for dir in /data/local/tmp/crosvm_gfx /data/local/tmp/crosvm_kgsl /data/local/tmp/crosvm_out; do
        got=$($A "su -c 'md5sum $dir/$f 2>/dev/null'" 2>/dev/null | tr -d '\r' | awk '{print $1}')
        if [ "$got" != "$want" ]; then
            adb -s $DEV push "$REPO/crosvm_out/$f" "$dir/" >/dev/null 2>&1
            got=$($A "su -c 'md5sum $dir/$f'" 2>/dev/null | tr -d '\r' | awk '{print $1}')
            echo "  repushed $dir/$f -> $got"
        fi
        [ "$got" = "$want" ] && echo "  ok $dir/$f" || echo "  !! MISMATCH $dir/$f ($got != $want)"
    done
done
adb -s $DEV push "$SCRATCH/run_stream_trace.sh" /data/local/tmp/ >/dev/null 2>&1
$A 'su -c "chmod 755 /data/local/tmp/run_stream_trace.sh /data/local/tmp/crosvm_gfx/crosvm /data/local/tmp/crosvm_gfx/libgfxstream_backend.so; sync"' 2>/dev/null

echo "=== 環境就緒。用 run_stream_trace.sh 開 VM ==="
