#!/bin/bash
# Pull the app + prebuilt-packing repos, then overlay the freshly built crosvm
# artifacts into the local prebuilt root so 5_build_apk.sh packs them into the
# APK instead of the cloud prebuilts.
set -e
cd "$(dirname "$0")"

[ -d DroidVM ] || git clone -b 3d-accel-gfxstream https://github.com/Droid-VM/DroidVM.git
[ -d DroidVM/DroidVM-Prebuilt-Root ] || git clone https://github.com/Droid-VM/DroidVM-Prebuilt-Root.git DroidVM/DroidVM-Prebuilt-Root

MB=DroidVM/DroidVM-Prebuilt-Root/manual-build/arm64-v8a
mkdir -p "$MB/usr/bin" "$MB/usr/lib" "$MB/usr/share/droidvm"

# crosvm + its runtime libs (from 2_build_crosvm.sh)
if [ -f crosvm_out/crosvm ]; then
    cp -f crosvm_out/crosvm "$MB/usr/bin/crosvm"
    for so in crosvm_out/*.so; do cp -f "$so" "$MB/usr/lib/"; done
fi

# EDK2 firmware (built separately in edk2-gunyah: ./build.sh -DPCI_CAM_MODE=FALSE)
if [ -f edk2-gunyah/edk2-gunyah.fd ]; then
    cp -f edk2-gunyah/edk2-gunyah.fd      "$MB/usr/share/droidvm/edk2-gunyah.fd"
    cp -f edk2-gunyah/edk2-gunyah.vars.fd "$MB/usr/share/droidvm/edk2-gunyah.vars.fd"
fi
