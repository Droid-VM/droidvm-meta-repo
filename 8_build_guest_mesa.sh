#!/bin/bash
# Build the guest mesa.
#
#   bash 8_build_guest_mesa.sh
#
# Checks out Droid-VM/mesa at this repo's branch, cross-builds it (native x86 compiler emitting
# aarch64 -- no emulation), and leaves mesa-guest_<ver>_arm64.deb in dist-guest/ along with
# everything else a guest needs.
#
# ONE package, all three routes. It used to be three scripts and three packages, because the
# routes lived on three mesa branches sitting on unrelated upstream commits: gfxstream and venus
# on 26.0.3 (the gfxstream guest ICD and the host decoder are one codebase and must match),
# drm2kgsl on 26.3.0-devel (where the tu/virtio work is). Once every route was rebased onto the
# same upstream commit the three trees turned out to touch disjoint files, so they became one
# branch, one build with -Dvulkan-drivers=gfxstream,freedreno,virtio, and one .deb.
#
# The route is chosen at RUN time: the package's VK_DRIVER_FILES names all three ICDs and the
# Vulkan loader keeps whichever one enumerates a device -- a guest sees exactly one virtio-gpu
# capset, so exactly one answers. Nothing has to be swapped to change route any more.
#
# The build recipe lives in mesa-cross/ (Droid-VM/mesa-cross, cloned by step 1 or by this step);
# mesa-cross/mesa-config.sh is where the meson options, package name and ICD list are written down.
set -e
cd "$(dirname "$0")"
source ./lib_mesa_build.sh
mesa_build
