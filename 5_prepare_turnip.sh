#!/bin/bash
# Build the host turnip Vulkan driver from source -> turnip/libvulkan_freedreno.so.
# 6_build_apk_prepare.sh stages it into DroidVM-Prebuilt-Root's manual-build so the APK
# ships it to DATA/usr/lib/. gfxstream (crosvm's GPU backend, the vk command proxy) runs
# the guest's Vulkan on this driver; the daemon points it there via
# ANDROID_EMU_VK_LOADER_PATH.
#
# WHY: without turnip, gfxstream falls back to the phone's closed Adreno blob (AHB-only,
# supportsDmaBuf=0) -> host-visible coherent memory fails ("dmabuf not supported",
# VK_ERROR_OUT_OF_DEVICE_MEMORY) -> zink/desktop black-screens. turnip advertises
# VK_EXT_external_memory_dma_buf (supportsDmaBuf=1).
#
# Source: Droid-VM/Banners-Turnip, our fork of The412Banner/Banners-Turnip -- the
# maintained successor of the whitebelyash/mesa-tu8 lineage (archived 2026-04) the old
# adreno-tools-drivers flow built from. Its build_droidvm.sh clones UPSTREAM mesa at the
# commit pinned in the fork's mesa_hash.txt and applies patch files on top: the a8xx gen8
# stack (8 Elite) plus our droidvm_* patches (a750 RB CCU AHB fix, kgsl fixes). One .so
# covers both host SoCs -- a750/8gen3 support is upstream mesa, A8xx comes from the
# patches. Guest-side turnip is a different build from Droid-VM/mesa (kgsl proxy /
# virtio native context), NOT this driver.
#
# The checkout follows this meta repo's branch chain (lib_branch.sh) and is then pinned
# to BANNERS_PIN, so branch + pin fully determine the driver (the fork pins mesa, the
# pin here pins the fork). Bump flow: push to the fork branch, update BANNERS_PIN here.
#
# UNLIKE the old flow, local driver work does NOT live in the build tree: every rebuild
# resets the mesa tree and re-applies the patch stack, so changes belong in the fork's
# patches/ (edit patch, push, bump pin). The mesa checkout under turnip/banners-turnip
# is disposable.
#
# Cached: reuses turnip/libvulkan_freedreno.so if present.
#
#   TURNIP_REBUILD=1   reset the mesa tree, re-apply patches, rebuild (ninja+ccache make
#                      this fast; any local edits in the mesa tree are DISCARDED).
#   TURNIP_CLEAN=1     delete turnip/banners-turnip and re-clone/rebuild from scratch.
#   BANNERS_PIN=...    override the pinned fork commit ("branch" = use branch HEAD).
#   TURNIP_NDK_DIR=... extracted android-ndk-r29 root to symlink into the workdir
#                      instead of downloading 700MB (must be r29 -- other releases
#                      change the toolchain and break "same pin, same driver").
#
# Build deps: git meson ninja patchelf unzip curl pip flex bison zip glslang
# glslangValidator python3 ccache.
set -e
cd "$(dirname "$0")"
source ./lib_branch.sh

BANNERS_URL=${BANNERS_URL:-https://github.com/Droid-VM/Banners-Turnip.git}
BANNERS_PIN=${BANNERS_PIN:-96f7844136e680d4c49d1055722e3d061fdcff8d}
BT_DIR=turnip/banners-turnip
MESA_DIR=$BT_DIR/turnip_workdir/mesa
SO=turnip/libvulkan_freedreno.so
# Install prefix of build_turnip.sh's `build_lib_for_android main`.
BUILT_SO=/tmp/turnip-main/lib/libvulkan_freedreno.so

# The old adreno-tools-drivers flow left a usable NDK behind; hardlink it into the new
# workdir so a fresh clone does not re-download 700MB. No-op once the old tree is gone.
seed_ndk() {
    local old=turnip/adreno-tools-drivers/turnip_workdir/android-ndk-r29
    local new=$BT_DIR/turnip_workdir/android-ndk-r29
    if [ -d "$old" ] && [ ! -d "$new" ]; then
        echo ">>> seeding NDK from $old (hardlinks)"
        mkdir -p "$BT_DIR/turnip_workdir"
        cp -al "$old" "$new"
    fi
}

if [ -n "${TURNIP_CLEAN:-}" ]; then
    echo ">>> TURNIP_CLEAN: removing $BT_DIR and re-cloning"
    rm -rf "$BT_DIR"
fi

if [ ! -d "$BT_DIR" ]; then
    clone_at "$BT_DIR" "$BANNERS_URL"
    if [ "$BANNERS_PIN" != branch ]; then
        git -C "$BT_DIR" -c advice.detachedHead=false checkout -q "$BANNERS_PIN"
    fi
fi
echo ">>> $BT_DIR @ $(git -C "$BT_DIR" rev-parse --short HEAD) (pin ${BANNERS_PIN:0:12})"
[ "$BANNERS_PIN" = branch ] || [ "$(git -C "$BT_DIR" rev-parse HEAD)" = "$BANNERS_PIN" ] || \
    echo ">>>   warning: checkout differs from BANNERS_PIN -- building what is checked out"

if [ ! -d "$MESA_DIR" ]; then
    echo ">>> building turnip from $BANNERS_URL (pinned mesa, ~5 min with seeded NDK)"
    seed_ndk
    ( cd "$BT_DIR" && bash build_droidvm.sh )
elif [ -n "${TURNIP_REBUILD:-}" ] || [ ! -s "$SO" ]; then
    echo ">>> rebuilding turnip (mesa tree reset + patches re-applied)"
    ( cd "$BT_DIR" && SKIP_SOURCE_DOWNLOAD=1 bash build_droidvm.sh )
else
    echo ">>> reusing cached $SO (md5=$(md5sum "$SO" | cut -d' ' -f1))"
    echo ">>>   TURNIP_REBUILD=1 rebuilds; TURNIP_CLEAN=1 re-clones from scratch"
    echo "Done. turnip at $SO — staged into manual-build by 6_build_apk_prepare.sh."
    exit 0
fi

[ -s "$BUILT_SO" ] || { echo "error: build produced no $BUILT_SO" >&2; exit 1; }
cp "$BUILT_SO" "$SO"
echo ">>> built turnip md5=$(md5sum "$SO" | cut -d' ' -f1)"
echo "Done. turnip at $SO — staged into manual-build by 6_build_apk_prepare.sh."
