#!/bin/bash
# Pull the app + prebuilt-packing repos, then overlay the freshly built crosvm / EDK2 /
# gunyah-host-share / turnip artifacts into the local prebuilt root so 7_build_apk.sh packs
# them into the APK instead of the cloud prebuilts.
set -e
cd "$(dirname "$0")"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

[ -d DroidVM ] || git clone -b "$BRANCH" https://github.com/Droid-VM/DroidVM.git
# Prebuilt root is the exception: always its main branch. The build overlays the
# freshly built crosvm/EDK2/gunyah/turnip on top (below), rather than tracking a dev branch.
[ -d DroidVM/DroidVM-Prebuilt-Root ] || git clone https://github.com/Droid-VM/DroidVM-Prebuilt-Root.git DroidVM/DroidVM-Prebuilt-Root


cd DroidVM/DroidVM-Prebuilt-Root
./auto-build.py
cd ../../.

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

# Host GuestAccept module(s) (built by 4_build_gunyah_host.sh) -> manual-build so the APK
# ships them; the app's Kernel Module tab loads them from usr/lib/modules/<kmi>/.
# manual-build (not auto-build.toml): the .ko is a prebuilt we stage, not a cloned repo.
for kdir in gunyah_host_mod/dist/*/; do
    [ -d "$kdir" ] || continue
    kmi=$(basename "$kdir")
    for ko in "$kdir"*.ko; do
        [ -f "$ko" ] || continue
        mkdir -p "$MB/usr/lib/modules/$kmi"
        cp -f "$ko" "$MB/usr/lib/modules/$kmi/"
    done
done

# Host turnip Vulkan driver (built by 5_prepare_turnip.sh) -> manual-build. gfxstream needs
# it as its real GPU driver (ANDROID_EMU_VK_LOADER_PATH); without it host-visible coherent
# memory fails. -static-libstdc++, so no libc++_shared.so is needed alongside it.
if [ -f turnip/libvulkan_freedreno.so ]; then
    cp -f turnip/libvulkan_freedreno.so "$MB/usr/lib/libvulkan_freedreno.so"
fi
