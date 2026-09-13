#!/bin/bash
# build.sh detects DroidVM-Prebuilt-Root and packs the local prebuilts
# (including our crosvm/EDK2/gunyah from 6_build_apk_prepare.sh) into the APK.
set -e
# Native prebuilts dominate local APK build time. Keep real compression so the
# packaging/decompression path is exercised, but use its fastest non-zero level
# here. Callers can still override this explicitly when comparing artifacts.
export DROIDVM_PREBUILT_COMPRESSION_LEVEL="${DROIDVM_PREBUILT_COMPRESSION_LEVEL:-1}"

HERE="$(cd "$(dirname "$0")" && pwd)"
# The only ABI 6_build_apk_prepare.sh stages an overlay for.
ABI=arm64-v8a
cd "$HERE/DroidVM"
APP="$PWD"
ASSETS="$APP/app/src/main/assets/prebuilts"

cd DroidVM-Prebuilt-Root
# Regenerate into the assets directory Gradle packs from -- NOT into this repo's own root, which
# is auto-build.py's default and which nothing in this flow reads.
#
# Why by hand at all: app/build.gradle.kts's RegenPrebuiltsTask declares only auto-build/ and
# auto-build.py as its inputs, and marks prebuiltRoot @Internal on purpose ("hashing the whole
# root would drag in manual-build/, which carries hundreds of megabytes of binaries the script
# never reads"). The overlay 6_build_apk_prepare.sh writes lands ONLY in manual-build/, so it
# cannot invalidate the task: B15-build §3.2 shipped an APK carrying the PREVIOUS crosvm exactly
# that way -- byte-for-byte the size of the run before, "Task :app:regenPrebuilts UP-TO-DATE"
# followed by "mergeDebugAssets UP-TO-DATE", and only the sha256 check at the bottom of this
# script said so. Touching the inputs is no fix: Gradle hashes contents, not mtimes.
#
# Running the task's own action here does both halves of the job: the assets are already correct
# before Gradle looks at them, and rewriting the task's @OutputDirectory is itself what puts it
# out of date, so regenPrebuilts and mergeAssets run instead of skipping. ./build.sh keeps its
# own behaviour -- this is the same script with the same destination Gradle would have passed.
python3 ./auto-build.py --out "$ASSETS"

cd "$APP"
APK=app/build/outputs/apk/debug/app-debug.apk
# D13 (logs/vpu_wp/B3-acceptance.md §2): zipflinger repacks an existing APK in place, so a
# changed assets/prebuilts/*.tar.xz is appended and the old one is left behind as a dead entry --
# 214 MB shipped instead of 135 MB from the same inputs, 79 MB of it moved by every adb install.
rm -f "$APK"
./build.sh
ls -la "$APK"

# Did the APK actually get the crosvm this tree built? This is the check B5 and B15-build did by
# hand, and the only thing that catches the staleness described above. The packing manifest
# assets/prebuilts/prebuilt-<abi>.json lists every payload file with its sha256, and
# deploy/vpu/install_apk.sh reads that same entry to decide the phone unpacked the right payload
# -- so a stale APK does not fail there either, it verifies the wrong binary happily.
if [ -f "$HERE/crosvm_out/crosvm" ]; then
    WANT=$(sha256sum "$HERE/crosvm_out/crosvm" | awk '{print $1}')
    GOT=$(python3 - "$APK" "$ABI" <<'PY'
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
    echo "apk  usr/bin/crosvm    sha256 $GOT"
    echo "host crosvm_out/crosvm sha256 $WANT"
    if [ "$GOT" != "$WANT" ]; then
        echo "" >&2
        echo "ERROR: the APK does not carry the crosvm in $HERE/crosvm_out." >&2
        echo "       Do NOT install it: it ships an older payload under a new APK (B15-build §3.2)." >&2
        echo "       Check that 6_build_apk_prepare.sh's overlay ran after the last 2_build_crosvm.sh" >&2
        echo "       (md5sum crosvm_out/crosvm against DroidVM/DroidVM-Prebuilt-Root/manual-build/$ABI/usr/bin/crosvm)," >&2
        echo "       then run this script again." >&2
        exit 1
    fi
    echo "usr/bin/crosvm: MATCH"
else
    echo "no $HERE/crosvm_out/crosvm here -- nothing to check the APK payload against" >&2
fi
