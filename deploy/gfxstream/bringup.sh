#!/bin/bash
# Re-establish the phone-side test environment after a reboot. Runtime state only --
# nothing here writes a persistent setting. Every wait is bounded.
set -u
DEV=10.53.12.1:5568
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
# drm2kgsl-only problem: crosvm fails at exec and ALL FIVE configurations die. Verify it alongside
# the other two even when the run under test is gfxstream.
# crosvm_gfx and crosvm_drm2kgsl are root-owned directories, so `adb push` -- which runs as the
# shell user -- can only overwrite a file that already exists AND is shell-owned. Anything else
# fails while adb still reports "1 file pushed". So stage into /data/local/tmp (shell-writable)
# and `su 0 cp` into place, then verify: the md5 check is what caught this, and without it a
# stale libvirglrenderer.so looks exactly like a code bug.
for f in crosvm libgfxstream_backend.so libvirglrenderer.so; do
    want=$(md5sum "$REPO/crosvm_out/$f" | awk '{print $1}')
    staged=no
    for dir in /data/local/tmp/crosvm_gfx /data/local/tmp/crosvm_drm2kgsl /data/local/tmp/crosvm_out; do
        got=$($A "su -c 'md5sum $dir/$f 2>/dev/null'" 2>/dev/null | tr -d '\r' | awk '{print $1}')
        if [ "$got" != "$want" ]; then
            if [ "$staged" = no ]; then
                adb -s $DEV push "$REPO/crosvm_out/$f" "/data/local/tmp/$f.new" >/dev/null 2>&1
                staged=$($A "su -c 'md5sum /data/local/tmp/$f.new'" 2>/dev/null | tr -d '\r' | awk '{print $1}')
                [ "$staged" = "$want" ] || { echo "  !! staging /data/local/tmp/$f.new is $staged"; continue; }
            fi
            $A "su -c 'cp -f /data/local/tmp/$f.new $dir/$f && chmod 755 $dir/$f && sync'" >/dev/null 2>&1
            got=$($A "su -c 'md5sum $dir/$f'" 2>/dev/null | tr -d '\r' | awk '{print $1}')
            echo "  reinstalled $dir/$f -> $got"
        fi
        [ "$got" = "$want" ] && echo "  ok $dir/$f" || echo "  !! MISMATCH $dir/$f ($got != $want)"
    done
    [ "$staged" = no ] || $A "su -c 'rm -f /data/local/tmp/$f.new'" >/dev/null 2>&1
done
for s in run_stream_trace.sh run_ubuntu_gfx.sh run_ubuntu_gfx_prealloc.sh; do
    adb -s $DEV push "$SCRATCH/$s" /data/local/tmp/ >/dev/null 2>&1
done
adb -s $DEV push "$REPO/deploy/drm2kgsl/run_drm2kgsl_nctx.sh" /data/local/tmp/ >/dev/null 2>&1
$A 'su -c "chmod 755 /data/local/tmp/*.sh; sync"' 2>/dev/null

echo "=== 環境就緒。用 run_stream_trace.sh 開 VM ==="
