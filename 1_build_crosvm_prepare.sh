#!/bin/bash
# Pull the crosvm soong tree via the stable manifest (its main branch), then check
# the Droid-VM forks out to whatever branch THIS meta repo is on. That way every dev
# branch reuses the same manifest instead of re-pinning it per branch.
set -e
cd "$(dirname "$0")"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

mkdir -p crosvm_build
cd crosvm_build
repo init -u https://github.com/Droid-VM/crosvm-minimal-manifest.git -b main -m crosvm-minimal.xml --depth 1
repo sync -c
cd ..

# Convenience entries: one folder per Droid-VM org repo. The soong-tree repos
# must physically live inside crosvm_build (the build sandbox can't follow
# out-of-tree symlinks), so these just point in.
ln -sfn crosvm_build/external/crosvm                 crosvm
ln -sfn crosvm_build/hardware/google/gfxstream       gfxstream
ln -sfn crosvm_build/external/virglrenderer          virglrenderer
ln -sfn crosvm_build/packages/modules/Virtualization Virtualization

# Check each Droid-VM fork out to this meta repo's branch. The manifest only pins a
# stable base; the dev work lives on $BRANCH (e.g. wip/3d-accel-gfxstream). Add the
# droidvm remote if the manifest tracked a different one for that project.
for p in external/crosvm hardware/google/gfxstream external/virglrenderer packages/modules/Virtualization; do
    d="crosvm_build/$p"
    git -C "$d" remote get-url droidvm >/dev/null 2>&1 \
        || git -C "$d" remote add droidvm "https://github.com/Droid-VM/$(basename "$p").git"
    git -C "$d" fetch --depth 1 droidvm "$BRANCH"
    git -C "$d" checkout -B "$BRANCH" FETCH_HEAD
done


[ -d crosvm-minimal-manifest ] || git clone -b "$BRANCH" https://github.com/Droid-VM/crosvm-minimal-manifest.git

