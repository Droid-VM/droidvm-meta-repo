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

    # Local fixes on top of the upstream fork, applied after build_turnip.sh has cloned mesa and
    # done its own source edits -- which is why they cannot be applied before it runs.
    #
    # These have to be re-applied and rebuilt every time, and the rebuild is incremental (the build
    # directory already exists), so it costs seconds. Skipping it is how three of them ended up
    # living in the working tree for a week without ever reaching the shipped driver: the cached-.so
    # branch below never rebuilds, and TURNIP_REBUILD=1 wipes the tree. The KHR_display string is
    # still present in the shipped binary and absent from a patched one, which is how that was
    # eventually noticed.
    if ls turnip/patches/*.patch >/dev/null 2>&1; then
        mesa_dir="$ATD_DIR/turnip_workdir/mesa"
        for p in "$PWD"/turnip/patches/*.patch; do
            echo ">>> applying $(basename "$p")"
            git -C "$mesa_dir" apply "$p" || { echo "error: $p did not apply" >&2; exit 1; }
        done
        ndk="$PWD/$ATD_DIR/turnip_workdir/android-ndk-r29/toolchains/llvm/prebuilt/linux-x86_64/bin"
        ( cd "$mesa_dir" && PATH="$PWD/../bin:$ndk:$PATH" ninja -C build-android-aarch64 install ) \
            || { echo "error: patched rebuild failed" >&2; exit 1; }
        cp /tmp/turnip-gen8/lib/libvulkan_freedreno.so "$SO"
    fi

    echo ">>> built turnip md5=$(md5sum "$SO" | cut -d' ' -f1)"
else
    echo ">>> reusing cached $SO (md5=$(md5sum "$SO" | cut -d' ' -f1); TURNIP_REBUILD=1 to rebuild)"
fi
echo "Done. turnip at $SO — staged into manual-build by 6_build_apk_prepare.sh."
