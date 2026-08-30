#!/bin/bash
# build.sh detects DroidVM-Prebuilt-Root and packs the local prebuilts
# (including our crosvm/EDK2/gunyah from 6_build_apk_prepare.sh) into the APK.
set -e
# Native prebuilts dominate local APK build time. Keep real compression so the
# packaging/decompression path is exercised, but use its fastest non-zero level
# here. Callers can still override this explicitly when comparing artifacts.
export DROIDVM_PREBUILT_COMPRESSION_LEVEL="${DROIDVM_PREBUILT_COMPRESSION_LEVEL:-1}"

cd "$(dirname "$0")/DroidVM"
cd DroidVM-Prebuilt-Root
./auto-build.py

cd ..
./build.sh
ls -la app/build/outputs/apk/debug/app-debug.apk
