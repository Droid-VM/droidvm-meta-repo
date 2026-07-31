#!/bin/bash
# Build the guest mesa for the GFXSTREAM route.
#
#   bash 8_build_guest_mesa_gfx.sh
#
# Checks out mesa at <this repo's branch>-gfxstream, cross-builds it (native x86 compiler
# emitting aarch64 -- no emulation), and leaves mesa-guest-gfxstream_<ver>_arm64.deb in
# dist-guest/ along with everything else a guest needs.
#
# The route: this variant's ICD talks to the host gfxstream decoder over the vulkan-command
# wire, so the guest ICD and the host decoder are one codebase and must match -- which is why
# it tracks mesa 26.0.3 while the drm2kgsl variant tracks a different upstream entirely.
#
# Only ONE mesa-guest package can be installed in a guest at a time; see mesa-variants.sh.
exec bash "$(dirname "$0")/mesa-cross/build-host.sh" gfxstream
