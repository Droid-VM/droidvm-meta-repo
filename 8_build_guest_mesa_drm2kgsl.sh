#!/bin/bash
# Build the guest mesa for the DRM2KGSL route.
#
#   bash 8_build_guest_mesa_drm2kgsl.sh
#
# Checks out mesa at <this repo's branch>-drm2kgsl, cross-builds it (native x86 compiler
# emitting aarch64 -- no emulation), and leaves mesa-guest-drm2kgsl_<ver>_arm64.deb in
# dist-guest/ along with everything else a guest needs.
#
# The route: real turnip reaching the GPU through virglrenderer's DRM native context over vdrm.
# The variant is named for the HOST translation, not the guest driver -- turnip here speaks msm
# over vdrm and never touches a KGSL device of its own.
#
# Only ONE mesa-guest package can be installed in a guest at a time; see
# mesa-cross/mesa-variants.sh (Droid-VM/mesa-cross, cloned by step 1 or by this step).
set -e
cd "$(dirname "$0")"
source ./lib_mesa_build.sh
mesa_build_variant drm2kgsl
