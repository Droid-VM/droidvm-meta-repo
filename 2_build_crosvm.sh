#!/bin/bash
set -e
cd "$(dirname "$0")"
# The boot shim first: crosvm embeds it with include_bytes!, and soong sees the dependency
# through rustc's depfile, so a changed shim rebuilds crosvm on its own -- but only if something
# has built it. Nothing else will.
./2-0_build_shim.sh
mkdir -p crosvm_out
cd crosvm_build
source build/envsetup.sh
lunch aosp_arm64 trunk_staging eng
ALLOW_MISSING_DEPENDENCIES=true TARGET_BUILD_UNBUNDLED=true m crosvm_device_only -j8 || { echo 'BUILD FAILED'; exit 1; }
../2-1_collect_crosvm.sh
mv out/crosvm_pkg/* ../crosvm_out/
rm ../crosvm_out/libaaudio.so
rm ../crosvm_out/libbinder_ndk.so
#./2-2_crosvm_out_to_adb.sh
