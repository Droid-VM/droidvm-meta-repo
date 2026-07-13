#!/bin/bash
set -e
cd "$(dirname "$0")"
mkdir -p crosvm_out
cd crosvm_build
source build/envsetup.sh
lunch aosp_arm64 trunk_staging eng
ALLOW_MISSING_DEPENDENCIES=true TARGET_BUILD_UNBUNDLED=true m crosvm_device_only -j8 || { echo 'BUILD FAILED'; exit 1; }
../3_collect_crosvm.sh
mv out/crosvm_pkg/* ../crosvm_out/
rm ../crosvm_out/libaaudio.so
rm ../crosvm_out/libbinder_ndk.so
#./3-1_crosvm_out_to_adb.sh
