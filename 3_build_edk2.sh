#!/bin/bash
# Pull the crosvm soong tree pinned to the 3d-accel-gfxstream branches.
# The manifest branch pins every Droid-VM fork (crosvm, gfxstream,
# virglrenderer, Virtualization) to its 3d-accel-gfxstream branch.
set -e
cd "$(dirname "$0")"

cd edk2-gunyah
./build.sh -DPCI_CAM_MODE=FALSE
