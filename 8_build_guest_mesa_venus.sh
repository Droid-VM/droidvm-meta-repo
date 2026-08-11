#!/bin/bash
# Build the guest mesa for the VENUS route.
#
#   bash 8_build_guest_mesa_venus.sh
#
# Checks out mesa at <this repo's branch>-venus (based on the same 26.0.3 line as the
# gfxstream variant), cross-builds the venus (vn) Vulkan driver + zink, and leaves
# mesa-guest-venus_<ver>_arm64.deb in dist-guest/.
#
# The route: the vn ICD speaks the venus wire protocol to virglrenderer's vkr on the
# host (context-types=venus). Guest-allocated VkDeviceMemory takes the drm2kgsl-style
# HOST3D_GUEST + CREATE_GUEST_HANDLE wire shape (see the vn patch on the venus branch).
#
# Only ONE mesa-guest package can be installed in a guest at a time; see mesa-variants.sh.
set -e
cd "$(dirname "$0")"
source ./lib_mesa_build.sh
mesa_build_variant venus
