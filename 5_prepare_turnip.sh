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
# Built via StevenMXZ/Adreno-Tools-Drivers build_turnip.sh: our Droid-VM/turnip fork's `gen8`
# branch (Adreno A8xx), KGSL backend, -Dplatforms=android -> a hwvulkan HAL (exports `HMI`),
# -static-libstdc++ (needs NO libc++_shared.so). Self-contained (pulls its own NDK r29 +
# mesa fork), so it does NOT touch the crosvm soong tree.
#
# Droid-VM/turnip is our fork of whitebelyash/mesa-tu8 (gen8 branch) with the local kgsl fixes
# committed directly onto it, so build_turnip.sh's clone already has them -- no post-clone patch
# step needed. Local work on the driver happens in that fork (branch/PR there), not by editing
# the tree this script checks out.
#
# Cached: reuses turnip/libvulkan_freedreno.so if present.
#
#   TURNIP_REBUILD=1   rebuild from the tree that is already there, keeping it. Cheap (ninja is
#                      incremental) and, more importantly, non-destructive: the tree is where
#                      local work on the driver lives, so a rebuild must never throw it away.
#   TURNIP_CLEAN=1     re-clone everything from scratch. This DELETES turnip/adreno-tools-drivers,
#                      including any edits made directly in the cloned mesa source. Anything worth
#                      keeping belongs on the Droid-VM/turnip fork first.
#
# Build deps: git meson ninja patchelf unzip curl pip flex bison zip glslangValidator python3
# ccache.
set -e
cd "$(dirname "$0")"

ATD_REPO="${ATD_REPO:-https://github.com/StevenMXZ/Adreno-Tools-Drivers.git}"
TURNIP_FORK="${TURNIP_FORK:-https://github.com/Droid-VM/turnip.git}"
ATD_DIR=turnip/adreno-tools-drivers
SO=turnip/libvulkan_freedreno.so

MESA_DIR="$ATD_DIR/turnip_workdir/mesa"
NDK="$PWD/$ATD_DIR/turnip_workdir/android-ndk-r29/toolchains/llvm/prebuilt/linux-x86_64/bin"

# Point build_turnip.sh's mesa clone at our fork instead of upstream whitebelyash/mesa-tu8. It
# still owns the NDK download, meson cross files, and Android source-stub sed fixes; only the
# mesa source URL changes.
point_at_fork() {
    sed -i "s#^mesasrc=.*#mesasrc=\"$TURNIP_FORK\"#" "$ATD_DIR/build_turnip.sh"
}

# meson/ninja are already configured in the tree; this is seconds, not minutes.
rebuild_in_place() {
    ( cd "$MESA_DIR" && PATH="$PWD/../bin:$NDK:$PATH" ninja -C build-android-aarch64 install ) \
        || { echo "error: rebuild failed" >&2; exit 1; }
    cp /tmp/turnip-gen8/lib/libvulkan_freedreno.so "$SO"
}

if [ -n "${TURNIP_CLEAN:-}" ]; then
    echo ">>> TURNIP_CLEAN: removing $ATD_DIR and re-cloning (local source edits will be lost)"
    rm -rf "$ATD_DIR"
fi

if [ ! -d "$MESA_DIR/build-android-aarch64" ]; then
    echo ">>> building turnip from $ATD_REPO (NDK r29 + $TURNIP_FORK gen8, ~4 min)"
    [ -d "$ATD_DIR" ] || git clone --depth 1 "$ATD_REPO" "$ATD_DIR"
    point_at_fork
    ( cd "$ATD_DIR" && bash build_turnip.sh )
    zip=$(ls -t "$ATD_DIR"/turnip_workdir/a8xx-gen8-V*.zip 2>/dev/null | head -1)
    [ -n "$zip" ] || { echo "error: turnip build produced no a8xx zip" >&2; exit 1; }
    unzip -o -j "$zip" libvulkan_freedreno.so -d turnip/
    rebuild_in_place
    echo ">>> built turnip md5=$(md5sum "$SO" | cut -d' ' -f1)"
elif [ -n "${TURNIP_REBUILD:-}" ] || [ ! -s "$SO" ]; then
    echo ">>> rebuilding turnip in place from $MESA_DIR (tree kept)"
    rebuild_in_place
    echo ">>> built turnip md5=$(md5sum "$SO" | cut -d' ' -f1)"
else
    echo ">>> reusing cached $SO (md5=$(md5sum "$SO" | cut -d' ' -f1))"
    echo ">>>   TURNIP_REBUILD=1 rebuilds in place; TURNIP_CLEAN=1 re-clones from scratch"
fi
echo "Done. turnip at $SO — staged into manual-build by 6_build_apk_prepare.sh."
