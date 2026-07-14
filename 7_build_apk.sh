#!/bin/bash
# build.sh detects DroidVM-Prebuilt-Root and packs the local prebuilts
# (including our crosvm/EDK2/gunyah from 6_build_apk_prepare.sh) into the APK.
set -e
cd "$(dirname "$0")/DroidVM"
cd DroidVM-Prebuilt-Root
./auto-build.py

cd ..
./build.sh
ls -la app/build/outputs/apk/debug/app-debug.apk
