#!/bin/bash
# Pull the crosvm soong tree pinned to the 3d-accel-gfxstream branches.
# The manifest branch pins every Droid-VM fork (crosvm, gfxstream,
# virglrenderer, Virtualization) to its 3d-accel-gfxstream branch.
set -e
cd "$(dirname "$0")"

mkdir -p crosvm_build
cd crosvm_build
repo init -u https://github.com/Droid-VM/crosvm-minimal-manifest.git -b 3d-accel-gfxstream -m crosvm-minimal.xml --depth 1
repo sync -c
cd ..

# Convenience entries: one folder per Droid-VM org repo. The soong-tree repos
# must physically live inside crosvm_build (the build sandbox can't follow
# out-of-tree symlinks), so these just point in.
ln -sfn crosvm_build/external/crosvm                 crosvm
ln -sfn crosvm_build/hardware/google/gfxstream       gfxstream
ln -sfn crosvm_build/external/virglrenderer          virglrenderer
