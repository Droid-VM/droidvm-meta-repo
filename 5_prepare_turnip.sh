#!/bin/bash
# Build the host turnip Vulkan driver from source -> turnip/libvulkan_freedreno.so.
# 6_build_apk_prepare.sh stages it into DroidVM-Prebuilt-Root's manual-build so the APK
# ships it to DATA/usr/lib/. gfxstream (crosvm's GPU backend) runs the guest's Vulkan on
# this driver; the daemon points it there via ANDROID_EMU_VK_LOADER_PATH.
#
# WHY: without turnip, gfxstream falls back to the phone's closed Adreno blob (AHB-only,
# supportsDmaBuf=0) -> host-visible coherent memory fails ("dmabuf not supported",
# VK_ERROR_OUT_OF_DEVICE_MEMORY) -> zink/desktop black-screens. turnip advertises
# VK_EXT_external_memory_dma_buf (supportsDmaBuf=1).
#
# Built via StevenMXZ/Adreno-Tools-Drivers build_turnip.sh: mesa-tu8 `gen8` branch (Adreno
# A8xx), KGSL backend, -Dplatforms=android -> a hwvulkan HAL (exports `HMI`),
# -static-libstdc++ (needs NO libc++_shared.so). Self-contained (pulls its own NDK r29 +
# mesa fork), so it does NOT touch the crosvm soong tree.
#
# This step ONLY clones + builds. Cached: reuses turnip/libvulkan_freedreno.so if present;
# TURNIP_REBUILD=1 forces a fresh build. Build deps: git meson ninja patchelf unzip curl pip
# flex bison zip glslangValidator python3 ccache.
set -e
cd "$(dirname "$0")"

ATD_REPO="${ATD_REPO:-https://github.com/StevenMXZ/Adreno-Tools-Drivers.git}"
ATD_DIR=turnip/adreno-tools-drivers
SO=turnip/libvulkan_freedreno.so

if [ -n "${TURNIP_REBUILD:-}" ] || [ ! -s "$SO" ]; then
    echo ">>> building turnip from $ATD_REPO (NDK r29 + mesa-tu8 gen8, ~4 min)"
    rm -rf "$ATD_DIR"
    git clone --depth 1 "$ATD_REPO" "$ATD_DIR"
    ( cd "$ATD_DIR" && bash build_turnip.sh )
    zip=$(ls -t "$ATD_DIR"/turnip_workdir/a8xx-gen8-V*.zip 2>/dev/null | head -1)
    [ -n "$zip" ] || { echo "error: turnip build produced no a8xx zip" >&2; exit 1; }
    unzip -o -j "$zip" libvulkan_freedreno.so -d turnip/
    echo ">>> built turnip md5=$(md5sum "$SO" | cut -d' ' -f1)"
else
    echo ">>> reusing cached $SO (md5=$(md5sum "$SO" | cut -d' ' -f1); TURNIP_REBUILD=1 to rebuild)"
fi
echo "Done. turnip at $SO — staged into manual-build by 6_build_apk_prepare.sh."
