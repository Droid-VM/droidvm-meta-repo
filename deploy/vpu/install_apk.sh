#!/bin/bash
# VPU dev rig: install a freshly built APK AND put the phone on its code (defect D12).
#
#   install_apk.sh <path/to/app-debug.apk>
#
# `adb install -r` on its own updates neither of the two things this rig actually runs
# (logs/vpu_wp/B3-acceptance.md §3):
#
#   * the native payload under $APP/usr is unpacked by the app's UI -- SplashActivity:72 ->
#     AssetUtils.needsExtractPrebuilt -> ExtractStepFragment.runCheck -- not by the install and
#     not by the daemon, so usr/bin/crosvm stays the OLD binary until the app has been launched
#     once. Hence the `monkey` line and the sha256 poll below;
#   * the daemon is a bare root app_process64 started through su, so the package update does not
#     kill it: it keeps executing the base.apk that was replaced. Hence daemon-restart.
#
# Both halves LOOK fine if you do not check: `pm path` and `droidvm --version` answer, the VM
# starts, and the argv is built by the old code. So every step here is verified rather than
# assumed. Nothing is force-killed: the VMs go down through vm_stop_all first.
#
# PHONE=<host:port> overrides the device (default 172.22.74.2:5566).
set -u
SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SP/lib.sh"

APK=${1:-}
[ -n "$APK" ] || { awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"; exit 2; }
[ -f "$APK" ] || die "no such APK: $APK"

adb_wait
ABI=$(ash "getprop ro.product.cpu.abi")
[ -n "$ABI" ] || die "could not read ro.product.cpu.abi from $PHONE"

# The expected hash comes out of the APK itself: DroidVM-Prebuilt-Root's packing manifest
# assets/prebuilts/prebuilt-<abi>.json is a {"hash": [{file, source, sha256}, ...]} listing of
# every file in the payload tar.xz, and B3 §2 used exactly this entry to prove which crosvm a
# build shipped.
WANT=$(python3 - "$APK" "$ABI" <<'PY'
import json, sys, zipfile
apk, abi = sys.argv[1], sys.argv[2]
name = "assets/prebuilts/prebuilt-%s.json" % abi
with zipfile.ZipFile(apk) as z:
    try:
        manifest = json.loads(z.read(name))
    except KeyError:
        sys.exit("%s carries no %s" % (apk, name))
for entry in manifest.get("hash") or []:
    if entry.get("file") == "usr/bin/crosvm":
        print(entry["sha256"])
        break
else:
    sys.exit("%s lists no usr/bin/crosvm" % name)
PY
) || exit 1
note "apk:      $APK"
note "abi:      $ABI"
note "expected: usr/bin/crosvm sha256 $WANT"

# 1. Every VM down, cleanly -- an install while a VM runs would leave that crosvm on the old
#    payload, and the daemon restart at the end takes them down regardless (Daemon.cleanup).
vm_stop_all || die "install: could not stop the running VMs; nothing was installed"

# 2. The install itself.
adb -s "$PHONE" install -r "$APK" </dev/null || die "install: adb install -r failed"

# 3. Launch the UI once: that is what unpacks the payload.
note "launching the app once so ExtractStepFragment unpacks the payload"
ash "monkey -p cn.classfun.droidvm -c android.intent.category.LAUNCHER 1" >/dev/null

# 4. Wait for the payload on disk to BE the payload in the APK (extraction took ~15 s in B3).
GOT=""
for _ in $(seq 1 30); do
    sleep 2
    GOT=$(asu "sha256sum $APP/usr/bin/crosvm" | awk '{print $1}')
    [ "$GOT" = "$WANT" ] && break
done
[ "$GOT" = "$WANT" ] || die "install: $APP/usr/bin/crosvm is $GOT, not $WANT, 60s after the launch
  -- the app may be waiting on a permission or an extraction prompt; open it on the phone"
note "payload: usr/bin/crosvm matches the APK"

# 5. The daemon, onto the new base.apk.
daemon_restart || die "install: the daemon did not come back"

# 6. What is actually running now.
echo "--- versions"
echo "cli:         $(asu "$APP/bin/droidvm --version")"
ash "dumpsys package cn.classfun.droidvm" | awk '
    /versionCode=/ && !c { sub(/^.*versionCode=/, ""); sub(/ .*/, ""); print "versionCode: " $0; c = 1 }
    /versionName=/ && !n { sub(/^.*versionName=/, ""); print "versionName: " $0; n = 1 }'
echo "crosvm:      $WANT  $APP/usr/bin/crosvm"
daemon_check
