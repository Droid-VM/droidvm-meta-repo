#!/bin/bash
cd crosvm_build
source build/envsetup.sh
lunch aosp_arm64 trunk_staging eng
ALLOW_MISSING_DEPENDENCIES=true TARGET_BUILD_UNBUNDLED=true m crosvm_device_only -j8 || { echo 'BUILD FAILED'; exit 1; }
../collect_crosvm.sh
mv out/crosvm_pkg/* ../crosvm_out/
rm ../crosvm_out/libaaudio.so
rm ../crosvm_out/libbinder_ndk.so
#./crosvm_out_to_adb.sh
